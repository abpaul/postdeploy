//! Complete backup sets. One cycle snapshots control and every active
//! organization, then writes an authenticated manifest last. A set without an
//! authenticated manifest is incomplete; the current set is the newest set that
//! has one, so a failed or interrupted cycle never replaces it.
//!
//! Object layout under the store prefix:
//! `backups/sets/{set}/control.pdbk`, `backups/sets/{set}/org/{org}.pdbk` and
//! `backups/sets/{set}/manifest.pdbk`.

use std::{
    collections::{BTreeMap, HashMap, HashSet},
    fmt, fs,
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, Instant},
};

use bytes::Bytes;
use sea_orm::{ConnectionTrait, DatabaseConnection, TransactionTrait};
use serde::{Deserialize, Serialize};

use crate::{
    backup::{self, Backup, BackupError, Backups, Scope, Source, Worker},
    domain::{now_micros, OrgId},
    logs::{
        object::Partition,
        pending::{PendingCipher, Slot},
        storage::{fetch_batch, ArchiveError},
    },
    orphan_retention::UnreferencedPayloads,
    runtime::{sql, Runtime},
    settings::BackupSettings,
    store::Created,
};

pub const SETS_PREFIX: &str = "backups/sets/";
pub const FORMAT: u8 = 1;
const MAX_MANIFEST_BYTES: usize = 4 << 20;
const DAY_US: i64 = 86_400 * 1_000_000;

/// UUIDv7 set identity. Its timestamp orders sets and drives retention.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct SetId(uuid::Uuid);

impl SetId {
    pub fn generate() -> Self {
        Self(uuid::Uuid::now_v7())
    }

    pub fn created_at_us(self) -> i64 {
        ((self.0.as_u128() >> 80) as i64) * 1_000
    }

    /// Accepts the 32-character lowercase form of a version 7 id only.
    pub fn parse(text: &str) -> Option<Self> {
        let canonical = text.len() == 32
            && text
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b));
        let id = uuid::Uuid::parse_str(text).ok().filter(|_| canonical)?;
        (id.get_version_num() == 7).then_some(Self(id))
    }
}

impl fmt::Display for SetId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0.simple())
    }
}

impl Serialize for SetId {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.collect_str(self)
    }
}

impl<'de> Deserialize<'de> for SetId {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let text = String::deserialize(deserializer)?;
        Self::parse(&text).ok_or_else(|| serde::de::Error::custom("invalid backup set id"))
    }
}

pub fn set_prefix(set: SetId) -> String {
    format!("{SETS_PREFIX}{set}/")
}

pub fn member_key(set: SetId, scope: &Scope) -> String {
    match scope {
        Scope::Control => format!("{}control.pdbk", set_prefix(set)),
        Scope::Organization(org) => format!("{}org/{org}.pdbk", set_prefix(set)),
        Scope::Manifest => manifest_key(set),
    }
}

pub fn manifest_key(set: SetId) -> String {
    format!("{}manifest.pdbk", set_prefix(set))
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Manifest {
    pub format: u8,
    pub set: SetId,
    pub started_at_us: i64,
    pub completed_at_us: i64,
    /// Control structural revision, equal before and after collection.
    pub revision: i64,
    pub control: Member,
    /// Exactly the organizations active at `revision`.
    pub organizations: BTreeMap<OrgId, Member>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Member {
    pub key: String,
    /// Time just before the snapshot read began.
    pub captured_at_us: i64,
    pub snapshot_bytes: u64,
    pub object_bytes: u64,
    pub snapshot_sha256: String,
    pub object_sha256: String,
}

impl From<Backup> for Member {
    fn from(backup: Backup) -> Self {
        Self {
            key: backup.key,
            captured_at_us: backup.captured_at_us,
            snapshot_bytes: backup.snapshot_bytes,
            object_bytes: backup.object_bytes,
            snapshot_sha256: backup.snapshot_sha256,
            object_sha256: backup.object_sha256,
        }
    }
}

impl Manifest {
    pub fn raw_bytes(&self) -> u64 {
        self.control.snapshot_bytes
            + self
                .organizations
                .values()
                .map(|member| member.snapshot_bytes)
                .sum::<u64>()
    }

    pub fn sealed_bytes(&self) -> u64 {
        self.control.object_bytes
            + self
                .organizations
                .values()
                .map(|member| member.object_bytes)
                .sum::<u64>()
    }

    pub fn seal(&self, backups: &Backups) -> Result<Bytes, BackupError> {
        let json = serde_json::to_vec(self).map_err(|_| BackupError::Malformed)?;
        backups.seal_bytes(&Scope::Manifest, &manifest_key(self.set), &json)
    }

    /// Authenticates the manifest of `set` and checks that it describes that
    /// set in the current format with every member at its own key.
    pub fn open(backups: &Backups, set: SetId, body: Bytes) -> Result<Self, BackupError> {
        let json = backups.unseal_bytes(
            &Scope::Manifest,
            &manifest_key(set),
            body,
            MAX_MANIFEST_BYTES,
        )?;
        let manifest: Self = serde_json::from_slice(&json).map_err(|_| BackupError::Malformed)?;
        let keys_match = manifest.control.key == member_key(set, &Scope::Control)
            && manifest.organizations.iter().all(|(org, member)| {
                member.key == member_key(set, &Scope::Organization(org.clone()))
            });
        if manifest.format != FORMAT || manifest.set != set || !keys_match {
            return Err(BackupError::Malformed);
        }
        Ok(manifest)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Stage {
    Control,
    Organization(OrgId),
    Manifest,
    Retention,
}

impl fmt::Display for Stage {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Control => f.write_str("control"),
            Self::Organization(org) => write!(f, "organization({org})"),
            Self::Manifest => f.write_str("manifest"),
            Self::Retention => f.write_str("retention"),
        }
    }
}

/// Outcome of one cycle. Stored as one `backup_cycles` row.
#[derive(Debug)]
pub enum Cycle {
    Complete(Manifest),
    Failed { stage: Stage, error: BackupError },
    Busy,
    Changed { attempts: u32 },
}

impl Cycle {
    pub fn outcome(&self) -> &'static str {
        match self {
            Self::Complete(_) => "complete",
            Self::Failed { .. } => "failed",
            Self::Busy => "busy",
            Self::Changed { .. } => "changed",
        }
    }
}

enum Collect {
    Changed,
    Failed(Stage, BackupError),
}

#[derive(Debug, PartialEq, Eq, Serialize)]
pub struct RestoredOrganization {
    pub org: OrgId,
    pub path: PathBuf,
    pub snapshot_captured_at_us: i64,
    pub marked_at_us: i64,
    pub unreferenced: UnreferencedPayloads,
}

/// What an operator needs before activating a restored set.
#[derive(Debug, PartialEq, Eq, Serialize)]
pub struct RestoreReport {
    pub set: SetId,
    pub control: PathBuf,
    pub control_captured_at_us: i64,
    /// Credentials revoked at or after this time are active again in the restored control.
    pub security_interval_from_us: i64,
    /// Organizations whose billing must be refreshed from Stripe before activation.
    pub billing_refresh_required: Vec<OrgId>,
    /// The restored control issues project and source ids above these, so no
    /// id that live control or R2 logs reference is reused.
    pub project_id_floor: i64,
    pub source_id_floor: i64,
    pub organizations: Vec<RestoredOrganization>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum HealthState {
    Ok,
    /// No complete set within the staleness window.
    Stale,
    /// The newest finished cycle failed or exhausted its revision attempts.
    Failing,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
pub struct BackupHealth {
    pub state: HealthState,
    pub last_complete_age_secs: Option<u64>,
}

impl BackupHealth {
    /// Stale means no complete set within two intervals plus the initial
    /// delay and one member deadline, counted from the last complete set or,
    /// before the first one, from process start.
    pub fn classify(
        settings: &BackupSettings,
        now_us: i64,
        process_started_us: i64,
        last_complete_us: Option<i64>,
        last_finished_outcome: Option<&str>,
    ) -> Self {
        let window_us = i64::try_from(
            2 * settings.interval_secs + settings.initial_delay_secs + settings.deadline_secs,
        )
        .unwrap_or(i64::MAX / 1_000_000)
            * 1_000_000;
        let since = last_complete_us.unwrap_or(process_started_us);
        let state = if matches!(last_finished_outcome, Some("failed" | "changed")) {
            HealthState::Failing
        } else if now_us.saturating_sub(since) > window_us {
            HealthState::Stale
        } else {
            HealthState::Ok
        };
        Self {
            state,
            last_complete_age_secs: last_complete_us
                .map(|at| (now_us.saturating_sub(at).max(0) / 1_000_000) as u64),
        }
    }
}

pub struct BackupSets {
    backups: Backups,
    settings: BackupSettings,
    started_at_us: i64,
}

impl BackupSets {
    pub fn new(backups: Backups, settings: BackupSettings) -> Self {
        Self {
            backups,
            settings,
            started_at_us: now_micros(),
        }
    }

    pub fn backups(&self) -> &Backups {
        &self.backups
    }

    /// Hourly loop owned by the server. One cycle at a time; shutdown drops
    /// the running cycle, which cancels an attempt that has not started its
    /// upload. An upload already in flight may still land without a manifest.
    pub async fn run(self: Arc<Self>, rt: Arc<Runtime>) {
        if let Err(error) = self.recover(&rt).await {
            tracing::warn!(%error, "backup cycles left by the previous process could not be closed");
        }
        tokio::select! {
            () = rt.cancel.cancelled() => return,
            () = tokio::time::sleep(Duration::from_secs(self.settings.initial_delay_secs)) => {}
        }
        let mut ticker = tokio::time::interval(Duration::from_secs(self.settings.interval_secs));
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            tokio::select! {
                () = rt.cancel.cancelled() => return,
                _ = ticker.tick() => {}
            }
            tokio::select! {
                () = rt.cancel.cancelled() => return,
                _ = self.run_once(&rt) => {}
            }
        }
    }

    /// Marks cycles that a previous process left open as `abandoned` and
    /// deletes the scratch directories their attempts left behind.
    pub async fn recover(&self, rt: &Runtime) -> Result<(), BackupError> {
        let Some(since) = abandon_open_cycles(&rt.control).await? else {
            return Ok(());
        };
        let worker = self.backups.lease()?;
        let removed = self.backups.discard_scratch_since(&worker, since)?;
        tracing::info!(removed, "scratch of abandoned backup cycles deleted");
        Ok(())
    }

    pub async fn health(&self, rt: &Runtime) -> BackupHealth {
        let row = rt
            .control
            .query_one_raw(sql(
                "SELECT (SELECT MAX(finished_at) FROM backup_cycles WHERE outcome = 'complete') AS complete_at,
                    (SELECT outcome FROM backup_cycles WHERE outcome IN ('complete', 'failed', 'changed')
                     ORDER BY finished_at DESC LIMIT 1) AS outcome",
                vec![],
            ))
            .await;
        let read = row.and_then(|row| {
            let row = row.ok_or_else(|| sea_orm::DbErr::RecordNotFound("backup health".into()))?;
            Ok((
                row.try_get::<Option<i64>>("", "complete_at")?,
                row.try_get::<Option<String>>("", "outcome")?,
            ))
        });
        let (complete_at, outcome) = match read {
            Ok(values) => values,
            Err(error) => {
                tracing::warn!(%error, "backup health could not be read");
                (None, Some("failed".to_owned()))
            }
        };
        BackupHealth::classify(
            &self.settings,
            now_micros(),
            self.started_at_us,
            complete_at,
            outcome.as_deref(),
        )
    }

    pub async fn run_once(&self, rt: &Runtime) -> Cycle {
        let started = Instant::now();
        let started_at = now_micros();
        let first = SetId::generate();
        let Ok(worker) = self.backups.lease() else {
            if let Err(error) = record_busy(&rt.control, first, started_at).await {
                tracing::warn!(%error, "backup cycle row could not be written");
            }
            tracing::warn!("backup cycle skipped; the previous attempt still holds the worker");
            return Cycle::Busy;
        };
        if let Err(error) = rt
            .control
            .execute_raw(sql(
                "INSERT INTO backup_cycles (set_id, started_at, attempts) VALUES (?, ?, 0)",
                vec![first.to_string().into(), started_at.into()],
            ))
            .await
        {
            tracing::warn!(%error, "backup cycle row could not be written");
            return Cycle::Failed {
                stage: Stage::Control,
                error: BackupError::Database(error),
            };
        }
        let mut set = first;
        let mut attempts = 0;
        let cycle = loop {
            attempts += 1;
            match self.collect(rt, &worker, set, started_at).await {
                Ok(manifest) => break Cycle::Complete(manifest),
                Err(Collect::Changed) if attempts < self.settings.revision_attempts => {
                    tracing::info!(set = %set, attempts, "backup set abandoned; control structure changed");
                    set = SetId::generate();
                }
                Err(Collect::Changed) => break Cycle::Changed { attempts },
                Err(Collect::Failed(stage, error)) => break Cycle::Failed { stage, error },
            }
        };
        drop(worker);
        let elapsed_ms = started.elapsed().as_millis() as i64;
        let (stage, detail, raw, sealed) = match &cycle {
            Cycle::Complete(manifest) => (
                None,
                None,
                Some(manifest.raw_bytes() as i64),
                Some(manifest.sealed_bytes() as i64),
            ),
            Cycle::Failed { stage, error } => {
                (Some(stage.to_string()), Some(error.to_string()), None, None)
            }
            _ => (None, None, None, None),
        };
        let finished = rt
            .control
            .execute_raw(sql(
                "UPDATE backup_cycles SET set_id = ?, finished_at = ?, outcome = ?, stage = ?, detail = ?,
                    attempts = ?, raw_bytes = ?, sealed_bytes = ?, elapsed_ms = ? WHERE set_id = ?",
                vec![
                    set.to_string().into(),
                    now_micros().into(),
                    cycle.outcome().into(),
                    stage.into(),
                    detail.into(),
                    i64::from(attempts).into(),
                    raw.into(),
                    sealed.into(),
                    elapsed_ms.into(),
                    first.to_string().into(),
                ],
            ))
            .await;
        if let Err(error) = finished {
            tracing::warn!(%error, "backup cycle row could not be finished");
        }
        match &cycle {
            Cycle::Complete(manifest) => {
                tracing::info!(
                    set = %manifest.set,
                    organizations = manifest.organizations.len(),
                    raw_bytes = manifest.raw_bytes(),
                    sealed_bytes = manifest.sealed_bytes(),
                    elapsed_ms,
                    "backup set complete"
                );
                if let Err(error) = self.retain(rt, manifest.set, now_micros()).await {
                    tracing::warn!(%error, "backup retention failed; the completed set stays current");
                    let _ = rt
                        .control
                        .execute_raw(sql(
                            "UPDATE backup_cycles SET stage = 'retention', detail = ? WHERE set_id = ?",
                            vec![error.to_string().into(), manifest.set.to_string().into()],
                        ))
                        .await;
                }
            }
            Cycle::Failed { stage, error } => {
                tracing::warn!(set = %set, %stage, %error, "backup set failed; the previous complete set stays current");
            }
            Cycle::Changed { attempts } => {
                tracing::warn!(
                    attempts,
                    "backup set not written; control structure changed on every attempt"
                );
            }
            Cycle::Busy => {}
        }
        cycle
    }

    async fn collect(
        &self,
        rt: &Runtime,
        worker: &Worker,
        set: SetId,
        started_at_us: i64,
    ) -> Result<Manifest, Collect> {
        let (revision, orgs) = structure(&rt.control)
            .await
            .map_err(|error| Collect::Failed(Stage::Control, error))?;
        let control = match self
            .backups
            .backup(
                worker,
                Source::Control(rt.control.clone()),
                &rt.store,
                member_key(set, &Scope::Control),
            )
            .await
        {
            Ok(backup) => Member::from(backup),
            Err(error) => return Err(classify(rt, revision, Stage::Control, error).await),
        };
        if let Some(faults) = rt.faults() {
            if faults
                .pause_after_backup_member
                .swap(false, std::sync::atomic::Ordering::SeqCst)
            {
                faults.backup_paused.notify_one();
                faults.backup_resume.notified().await;
            }
        }
        let mut organizations = BTreeMap::new();
        for org in orgs {
            let result = async {
                let lease =
                    crate::organization_lifecycle::active_tenant(&rt.control, &rt.tenants, &org)
                        .await
                        .map_err(|error| BackupError::Organization {
                            org: org.clone(),
                            detail: error.to_string(),
                        })?;
                drop(lease);
                self.backups
                    .backup(
                        worker,
                        Source::Organization {
                            pools: rt.tenants.clone(),
                            org: org.clone(),
                        },
                        &rt.store,
                        member_key(set, &Scope::Organization(org.clone())),
                    )
                    .await
            }
            .await;
            match result {
                Ok(backup) => {
                    organizations.insert(org, Member::from(backup));
                }
                Err(error) => {
                    return Err(classify(rt, revision, Stage::Organization(org), error).await)
                }
            }
        }
        let after = read_revision(&rt.control)
            .await
            .map_err(|error| Collect::Failed(Stage::Manifest, error))?;
        if after != revision {
            return Err(Collect::Changed);
        }
        let manifest = Manifest {
            format: FORMAT,
            set,
            started_at_us,
            completed_at_us: now_micros(),
            revision,
            control,
            organizations,
        };
        let failed = |error| Collect::Failed(Stage::Manifest, error);
        let body = manifest.seal(&self.backups).map_err(failed)?;
        let key = manifest_key(set);
        match rt
            .store
            .with_timeout(self.backups.limits().deadline)
            .put_if_absent(&key, body)
            .await
        {
            Ok(Created::New) => Ok(manifest),
            Ok(Created::Exists) => Err(failed(BackupError::Exists(key))),
            Err(error) => Err(failed(error.into())),
        }
    }

    /// Deletes every set under `backups/sets/` older than the retention period
    /// except `keep`, the set just completed. Each manifest goes first, so an
    /// interrupted pass leaves incomplete sets that the next pass deletes.
    pub async fn retain(
        &self,
        rt: &Runtime,
        keep: SetId,
        now_us: i64,
    ) -> Result<usize, BackupError> {
        let cutoff = now_us - i64::from(self.settings.retention_days) * DAY_US;
        let mut deleted = 0;
        for (set, mut keys) in stored_sets(rt).await? {
            if set == keep || set.created_at_us() >= cutoff {
                continue;
            }
            let manifest = manifest_key(set);
            keys.sort_by_key(|key| *key != manifest);
            for key in keys {
                rt.store.delete(&key).await?;
                deleted += 1;
            }
        }
        rt.control
            .execute_raw(sql(
                "DELETE FROM backup_cycles WHERE started_at < ?",
                vec![cutoff.into()],
            ))
            .await?;
        Ok(deleted)
    }

    /// Every set under `backups/sets/`, newest first. A set is complete when
    /// its manifest authenticates. Reads nothing from the control database.
    pub async fn list(&self, rt: &Runtime) -> Result<Vec<ListedSet>, BackupError> {
        let store = rt.store.with_timeout(self.backups.limits().deadline);
        let mut listed = Vec::new();
        for (set, keys) in stored_sets(rt).await?.into_iter().rev() {
            let key = manifest_key(set);
            let body = if keys.contains(&key) {
                store.get(&key, MAX_MANIFEST_BYTES).await?
            } else {
                None
            };
            let (manifest, manifest_error) =
                match body.map(|body| Manifest::open(&self.backups, set, body)) {
                    Some(Ok(manifest)) => (Some(manifest), None),
                    Some(Err(error)) => (None, Some(error.to_string())),
                    None => (None, None),
                };
            listed.push(ListedSet {
                set,
                created_at_us: set.created_at_us(),
                objects: keys.len(),
                complete: manifest.is_some(),
                organizations: manifest.as_ref().map(|m| m.organizations.len()),
                sealed_bytes: manifest.as_ref().map(Manifest::sealed_bytes),
                manifest_error,
            });
        }
        Ok(listed)
    }

    /// Authenticates the manifest of `set` and every member, compares sizes
    /// and SHA-256 values and checks each snapshot's integrity in a scratch
    /// directory that is deleted afterwards. Reads nothing from the control
    /// database and checks no ownership against it.
    pub async fn verify(&self, rt: &Runtime, set: SetId) -> Result<Manifest, BackupError> {
        let store = rt.store.with_timeout(self.backups.limits().deadline);
        let key = manifest_key(set);
        let body = store
            .get(&key, MAX_MANIFEST_BYTES)
            .await?
            .ok_or_else(|| BackupError::Missing(key.clone()))?;
        let manifest = Manifest::open(&self.backups, set, body)?;
        let dir = self
            .backups
            .scratch_root()
            .join(format!("verify-{}", uuid::Uuid::now_v7().simple()));
        create_private_dir(&dir)?;
        let members = std::iter::once((Scope::Control, &manifest.control)).chain(
            manifest
                .organizations
                .iter()
                .map(|(org, member)| (Scope::Organization(org.clone()), member)),
        );
        let mut result = Ok(());
        for (index, (scope, member)) in members.enumerate() {
            let path = dir.join(format!("{index}.sqlite"));
            result = async {
                self.member(rt, &scope, member, &path).await?;
                backup::validate(&path).await
            }
            .await;
            let _ = fs::remove_file(&path);
            if result.is_err() {
                break;
            }
        }
        fs::remove_dir_all(&dir).map_err(backup::io_at(&dir))?;
        result.map(|()| manifest)
    }

    /// Restores the complete set `set` into `destination`, a new offline
    /// directory: `control.sqlite` and `tenants/<file>` per organization. Every
    /// member is authenticated, hashed, integrity checked, ownership checked
    /// and its keys opened before any file appears at `destination`. A
    /// rejected set leaves `<destination>.partial` for diagnosis.
    pub async fn restore(
        &self,
        rt: &Runtime,
        set: SetId,
        destination: &Path,
    ) -> Result<RestoreReport, BackupError> {
        let staging = backup::sidecar(destination, ".partial");
        for path in [destination, staging.as_path()] {
            if fs::symlink_metadata(path).is_ok() {
                return Err(BackupError::DestinationExists(path.to_path_buf()));
            }
        }
        create_private_dir(&staging)?;
        create_private_dir(&staging.join("tenants"))?;
        let staged = self.stage(rt, set, &staging).await?;
        create_private_dir(destination).map_err(|error| match error {
            BackupError::Io { source, .. }
                if source.kind() == std::io::ErrorKind::AlreadyExists =>
            {
                BackupError::DestinationExists(destination.to_path_buf())
            }
            other => other,
        })?;
        let moved =
            |path: &Path| destination.join(path.strip_prefix(&staging).expect("staged path"));
        let mut files = vec![staged.control.clone()];
        files.extend(staged.organizations.iter().map(|org| org.path.clone()));
        let linked = files.iter().try_for_each(|file| {
            let target = moved(file);
            if let Some(parent) = target.parent() {
                fs::create_dir_all(parent).map_err(backup::io_at(parent))?;
            }
            fs::hard_link(file, &target).map_err(backup::io_at(&target))
        });
        if let Err(error) = linked {
            let _ = fs::remove_dir_all(destination);
            return Err(error);
        }
        fs::remove_dir_all(&staging).map_err(backup::io_at(&staging))?;
        Ok(RestoreReport {
            control: moved(&staged.control),
            organizations: staged
                .organizations
                .into_iter()
                .map(|org| RestoredOrganization {
                    path: moved(&org.path),
                    ..org
                })
                .collect(),
            ..staged
        })
    }

    async fn stage(
        &self,
        rt: &Runtime,
        set: SetId,
        staging: &Path,
    ) -> Result<RestoreReport, BackupError> {
        let store = rt.store.with_timeout(self.backups.limits().deadline);
        let key = manifest_key(set);
        let body = store
            .get(&key, MAX_MANIFEST_BYTES)
            .await?
            .ok_or_else(|| BackupError::Missing(key.clone()))?;
        let manifest = Manifest::open(&self.backups, set, body)?;

        let control_path = staging.join("control.sqlite");
        self.member(rt, &Scope::Control, &manifest.control, &control_path)
            .await?;
        backup::validate(&control_path).await?;
        let owners = Owners::read(&control_path, &manifest).await?;
        let tombstoned = deleted_in_live_control(&rt.control, &manifest).await?;
        if let Some(org) = tombstoned.first() {
            return Err(BackupError::Invalid(format!(
                "organization {org} is deleted in the live control database"
            )));
        }

        let mut organizations = Vec::with_capacity(manifest.organizations.len());
        let mut floor = live_id_floor(&rt.control).await?;
        for (org, member) in &manifest.organizations {
            let live = rt.tenants.registry().path(&org.tenant());
            let relative = live.strip_prefix(&rt.settings.tenants.root).map_err(|_| {
                BackupError::Invalid(format!("tenant path of {org} is outside the tenant root"))
            })?;
            let path = staging.join("tenants").join(relative);
            if let Some(parent) = path.parent() {
                fs::create_dir_all(parent).map_err(backup::io_at(parent))?;
            }
            self.member(rt, &Scope::Organization(org.clone()), member, &path)
                .await?;
            backup::validate(&path).await?;
            check_tenant(&path, org, &owners, &rt.pending_cipher).await?;
            let db = backup::open_read_only(&path).await?;
            let archived = archived_log_keys(&db).await;
            db.close().await?;
            let logged = unarchived_log_ids(rt, org, &archived?).await?;
            floor = (floor.0.max(logged.0), floor.1.max(logged.1));
            let marked_at_us =
                backup::mark_restored_organization(&path, member.captured_at_us).await?;
            backup::validate(&path).await?;
            let db = backup::open_read_only(&path).await?;
            let unreferenced =
                crate::orphan_retention::unreferenced(&rt.store, &db, org, member.captured_at_us)
                    .await;
            db.close().await?;
            let unreferenced = unreferenced.map_err(|error| BackupError::Organization {
                org: org.clone(),
                detail: format!("unrecovered payload report: {error}"),
            })?;
            organizations.push(RestoredOrganization {
                org: org.clone(),
                path,
                snapshot_captured_at_us: member.captured_at_us,
                marked_at_us,
                unreferenced,
            });
        }
        let (project_id_floor, source_id_floor) =
            raise_id_floor(&control_path, floor, manifest.organizations.keys()).await?;
        backup::validate(&control_path).await?;
        Ok(RestoreReport {
            set,
            control: control_path,
            control_captured_at_us: manifest.control.captured_at_us,
            security_interval_from_us: manifest.control.captured_at_us,
            billing_refresh_required: manifest.organizations.keys().cloned().collect(),
            project_id_floor,
            source_id_floor,
            organizations,
        })
    }

    async fn member(
        &self,
        rt: &Runtime,
        scope: &Scope,
        member: &Member,
        path: &Path,
    ) -> Result<(), BackupError> {
        let restored = self
            .backups
            .restore(&rt.store, scope, &member.key, path)
            .await?;
        if restored.object_sha256 != member.object_sha256
            || restored.snapshot_sha256 != member.snapshot_sha256
            || restored.snapshot_bytes != member.snapshot_bytes
        {
            return Err(BackupError::Invalid(format!(
                "member {} does not match the manifest",
                member.key
            )));
        }
        Ok(())
    }
}

#[derive(Debug, PartialEq, Eq, Serialize)]
pub struct ListedSet {
    pub set: SetId,
    pub created_at_us: i64,
    pub objects: usize,
    pub complete: bool,
    pub organizations: Option<usize>,
    pub sealed_bytes: Option<u64>,
    pub manifest_error: Option<String>,
}

async fn stored_sets(rt: &Runtime) -> Result<BTreeMap<SetId, Vec<String>>, BackupError> {
    let mut sets: BTreeMap<SetId, Vec<String>> = BTreeMap::new();
    let mut after: Option<String> = None;
    loop {
        let page = rt
            .store
            .list_page(SETS_PREFIX, after.as_deref(), 1_000)
            .await?;
        for key in page.keys {
            let set = key
                .strip_prefix(SETS_PREFIX)
                .and_then(|rest| rest.split('/').next())
                .and_then(SetId::parse);
            match set {
                Some(set) => sets.entry(set).or_default().push(key),
                None => tracing::warn!(%key, "unrecognized key under backups/sets/ kept"),
            }
        }
        after = page.next;
        if after.is_none() {
            return Ok(sets);
        }
    }
}

/// Marks rows of cycles that a previous process left open and returns the
/// earliest start among them. One process owns the data root, so an open row
/// at startup belongs to a process that ended.
async fn abandon_open_cycles(control: &DatabaseConnection) -> Result<Option<i64>, BackupError> {
    let txn = control.begin().await?;
    let since: Option<i64> = txn
        .query_one_raw(sql(
            "SELECT MIN(started_at) AS since FROM backup_cycles WHERE outcome IS NULL",
            vec![],
        ))
        .await?
        .map(|row| row.try_get("", "since"))
        .transpose()?
        .flatten();
    txn.execute_raw(sql(
        "UPDATE backup_cycles SET outcome = 'abandoned', finished_at = ? WHERE outcome IS NULL",
        vec![now_micros().into()],
    ))
    .await?;
    txn.commit().await?;
    Ok(since)
}

async fn record_busy(
    control: &DatabaseConnection,
    set: SetId,
    started_at: i64,
) -> Result<(), BackupError> {
    control
        .execute_raw(sql(
            "INSERT INTO backup_cycles (set_id, started_at, finished_at, outcome, attempts) VALUES (?, ?, ?, 'busy', 0)",
            vec![set.to_string().into(), started_at.into(), now_micros().into()],
        ))
        .await?;
    Ok(())
}

async fn read_revision(control: &impl ConnectionTrait) -> Result<i64, BackupError> {
    Ok(control
        .query_one_raw(sql(
            "SELECT revision FROM backup_revision WHERE id = 1",
            vec![],
        ))
        .await?
        .ok_or_else(|| BackupError::Invalid("backup revision row is missing".to_owned()))?
        .try_get("", "revision")?)
}

/// The revision and the active organizations, read in one transaction.
async fn structure(control: &DatabaseConnection) -> Result<(i64, Vec<OrgId>), BackupError> {
    let txn = control.begin().await?;
    let revision = read_revision(&txn).await?;
    let rows = txn
        .query_all_raw(sql(
            "SELECT id FROM organizations WHERE lifecycle = 'active' ORDER BY id",
            vec![],
        ))
        .await?;
    txn.commit().await?;
    let orgs = rows
        .iter()
        .map(|row| {
            row.try_get::<String>("", "id")?
                .parse()
                .map_err(|()| sea_orm::DbErr::Custom("stored organization id".into()))
        })
        .collect::<Result<_, sea_orm::DbErr>>()?;
    Ok((revision, orgs))
}

/// A member failure during a structural change retries the set; otherwise the
/// cycle fails. A timed-out or busy attempt may still run, so it always fails
/// the cycle instead of starting another snapshot.
async fn classify(rt: &Runtime, revision: i64, stage: Stage, error: BackupError) -> Collect {
    if matches!(
        error,
        BackupError::Timeout | BackupError::Busy | BackupError::Worker
    ) {
        return Collect::Failed(stage, error);
    }
    match read_revision(&rt.control).await {
        Ok(now) if now != revision => Collect::Changed,
        _ => Collect::Failed(stage, error),
    }
}

fn create_private_dir(path: &Path) -> Result<(), BackupError> {
    let mut builder = fs::DirBuilder::new();
    #[cfg(unix)]
    std::os::unix::fs::DirBuilderExt::mode(&mut builder, 0o700);
    builder.create(path).map_err(backup::io_at(path))
}

/// Project and source ownership in a restored control database.
struct Owners {
    projects: HashMap<OrgId, HashSet<i64>>,
    sources: HashMap<OrgId, HashSet<i64>>,
}

impl Owners {
    async fn read(control: &Path, manifest: &Manifest) -> Result<Self, BackupError> {
        let db = backup::open_read_only(control).await?;
        let result = Self::query(&db, manifest).await;
        db.close().await?;
        result
    }

    async fn query(db: &DatabaseConnection, manifest: &Manifest) -> Result<Self, BackupError> {
        let revision = read_revision(db).await?;
        if revision != manifest.revision {
            return Err(BackupError::Invalid(format!(
                "control revision {revision} does not match manifest revision {}",
                manifest.revision
            )));
        }
        let active: Vec<String> = db
            .query_all_raw(sql(
                "SELECT id FROM organizations WHERE lifecycle = 'active' ORDER BY id",
                vec![],
            ))
            .await?
            .iter()
            .map(|row| row.try_get("", "id"))
            .collect::<Result<_, _>>()?;
        let expected: Vec<String> = manifest
            .organizations
            .keys()
            .map(|org| org.to_string())
            .collect();
        if active != expected {
            return Err(BackupError::Invalid(
                "control active organizations do not match the manifest".to_owned(),
            ));
        }
        let mut owners = Self {
            projects: HashMap::new(),
            sources: HashMap::new(),
        };
        for (table, map) in [
            ("projects", &mut owners.projects),
            ("sources", &mut owners.sources),
        ] {
            for row in db
                .query_all_raw(sql(&format!("SELECT id, org_id FROM {table}"), vec![]))
                .await?
            {
                let org: String = row.try_get("", "org_id")?;
                if let Ok(org) = org.parse::<OrgId>() {
                    map.entry(org).or_default().insert(row.try_get("", "id")?);
                }
            }
        }
        Ok(owners)
    }
}

/// Every non-zero `project_id` and `source_id` in every table belongs to `org`,
/// and every pending log entry opens with the data key.
async fn check_tenant(
    path: &Path,
    org: &OrgId,
    owners: &Owners,
    cipher: &PendingCipher,
) -> Result<(), BackupError> {
    let db = backup::open_read_only(path).await?;
    let result = check_tenant_rows(&db, org, owners, cipher).await;
    db.close().await?;
    result
}

async fn check_tenant_rows(
    db: &DatabaseConnection,
    org: &OrgId,
    owners: &Owners,
    cipher: &PendingCipher,
) -> Result<(), BackupError> {
    let empty = HashSet::new();
    let tables: Vec<String> = db
        .query_all_raw(sql(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
            vec![],
        ))
        .await?
        .iter()
        .map(|row| row.try_get("", "name"))
        .collect::<Result<_, _>>()?;
    for table in tables {
        let columns: Vec<String> = db
            .query_all_raw(sql(
                "SELECT name FROM pragma_table_info(?)",
                vec![table.clone().into()],
            ))
            .await?
            .iter()
            .map(|row| row.try_get("", "name"))
            .collect::<Result<_, _>>()?;
        for (column, allowed) in [
            ("project_id", owners.projects.get(org).unwrap_or(&empty)),
            ("source_id", owners.sources.get(org).unwrap_or(&empty)),
        ] {
            if !columns.iter().any(|name| name == column) {
                continue;
            }
            let quoted = table.replace('"', "\"\"");
            let values = db
                .query_all_raw(sql(
                    &format!(
                        "SELECT DISTINCT {column} AS value FROM \"{quoted}\" WHERE {column} IS NOT NULL AND {column} != 0"
                    ),
                    vec![],
                ))
                .await?;
            for row in values {
                let value: i64 = row.try_get("", "value")?;
                if !allowed.contains(&value) {
                    return Err(BackupError::Invalid(format!(
                        "organization {org} table {table} references {column} {value} outside the organization"
                    )));
                }
            }
        }
    }
    let mut after = (i64::MIN, i64::MIN);
    loop {
        let rows = db
            .query_all_raw(sql(
                "SELECT object_id, entry, project_id, source_id, environment, billable_bytes, sealed
                 FROM log_entries_pending WHERE (object_id, entry) > (?, ?) ORDER BY object_id, entry LIMIT 1000",
                vec![after.0.into(), after.1.into()],
            ))
            .await?;
        let Some(last) = rows.last() else {
            return Ok(());
        };
        after = (last.try_get("", "object_id")?, last.try_get("", "entry")?);
        for row in &rows {
            let object_id: i64 = row.try_get("", "object_id")?;
            let entry: i64 = row.try_get("", "entry")?;
            let environment: String = row.try_get("", "environment")?;
            let sealed: Vec<u8> = row.try_get("", "sealed")?;
            let slot = Slot {
                org,
                object_id,
                entry: u32::try_from(entry).map_err(|_| BackupError::Malformed)?,
                project: row.try_get("", "project_id")?,
                source: row.try_get("", "source_id")?,
                environment: &environment,
                billable_bytes: row.try_get::<i64>("", "billable_bytes")?.max(0) as u64,
            };
            if cipher.open(&slot, &sealed).is_err() {
                return Err(BackupError::Invalid(format!(
                    "organization {org} pending log entry {object_id}/{entry} failed authentication"
                )));
            }
        }
    }
}

async fn max_value(db: &impl ConnectionTrait, query: &str) -> Result<i64, BackupError> {
    Ok(db
        .query_one_raw(sql(query, vec![]))
        .await?
        .map(|row| row.try_get::<Option<i64>>("", "value"))
        .transpose()?
        .flatten()
        .unwrap_or(0))
}

async fn live_id_floor(control: &DatabaseConnection) -> Result<(i64, i64), BackupError> {
    let mut floor = (0, 0);
    for (table, slot) in [("projects", &mut floor.0), ("sources", &mut floor.1)] {
        *slot = max_value(
            control,
            &format!(
                "SELECT MAX((SELECT COALESCE(MAX(id), 0) FROM {table}),
                    (SELECT COALESCE(MAX(floor), 0) FROM id_floor WHERE name = '{table}')) AS value"
            ),
        )
        .await?;
    }
    Ok(floor)
}

async fn archived_log_keys(db: &impl ConnectionTrait) -> Result<HashSet<String>, BackupError> {
    db.query_all_raw(sql(
        "SELECT object_key FROM log_objects WHERE state = 'archived'",
        vec![],
    ))
    .await?
    .iter()
    .map(|row| Ok(row.try_get("", "object_key")?))
    .collect()
}

/// The largest project and source ids in R2 log objects of `org` outside
/// `archived`. Reconciliation adopts those entries with their original ids.
/// An object that does not decode is never adopted.
async fn unarchived_log_ids(
    rt: &Runtime,
    org: &OrgId,
    archived: &HashSet<String>,
) -> Result<(i64, i64), BackupError> {
    let prefix = Partition::org_prefix(org);
    let batches = format!("{prefix}v2/");
    let mut max = (0, 0);
    let mut after: Option<String> = None;
    loop {
        let page = rt.store.list_page(&prefix, after.as_deref(), 1_000).await?;
        for key in page.keys.iter().filter(|key| !archived.contains(*key)) {
            if key.starts_with(&batches) {
                match fetch_batch(rt, key).await {
                    Ok(Some((batch, _))) => {
                        for entry in &batch.entries {
                            max = (max.0.max(entry.project.0), max.1.max(entry.source.0));
                        }
                    }
                    Ok(None) | Err(ArchiveError::Conflict(_)) => {}
                    Err(_) => {
                        return Err(BackupError::Organization {
                            org: org.clone(),
                            detail: format!("log object {key} could not be read"),
                        })
                    }
                }
            } else {
                let mut parts = key[prefix.len()..].split('/');
                if let (Some(Ok(project)), Some(Ok(source))) = (
                    parts.next().map(str::parse::<i64>),
                    parts.next().map(str::parse::<i64>),
                ) {
                    max = (max.0.max(project), max.1.max(source));
                }
            }
        }
        after = page.next;
        if after.is_none() {
            return Ok(max);
        }
    }
}

/// Raises each id floor to `floor` and to the table's own largest id.
async fn raise_floor(db: &impl ConnectionTrait, floor: (i64, i64)) -> Result<(), BackupError> {
    for (table, value) in [("projects", floor.0), ("sources", floor.1)] {
        db.execute_raw(sql(
            &format!(
                "INSERT INTO id_floor (name, floor)
                 VALUES ('{table}', MAX(?, (SELECT COALESCE(MAX(id), 0) FROM {table})))
                 ON CONFLICT (name) DO UPDATE SET floor = MAX(floor, excluded.floor)"
            ),
            vec![value.into()],
        ))
        .await?;
    }
    Ok(())
}

/// Migrates the staged control file, raises its id floor to `floor` and to
/// its own largest ids, and records `organizations` for the scan at
/// activation. Returns the resulting floors.
async fn raise_id_floor(
    control: &Path,
    floor: (i64, i64),
    organizations: impl Iterator<Item = &OrgId>,
) -> Result<(i64, i64), BackupError> {
    let options = sea_orm::sqlx::sqlite::SqliteConnectOptions::new()
        .filename(control)
        .journal_mode(sea_orm::sqlx::sqlite::SqliteJournalMode::Delete)
        .foreign_keys(true);
    let pool = sea_orm::sqlx::sqlite::SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(options)
        .await
        .map_err(|error| BackupError::Invalid(format!("open: {error}")))?;
    let db = sea_orm::SqlxSqliteConnector::from_sqlx_sqlite_pool(pool);
    let result = async {
        loco_rs::db::migrate::<migration::ControlMigrator>(&db)
            .await
            .map_err(|error| BackupError::Invalid(format!("migrate control: {error}")))?;
        raise_floor(&db, floor).await?;
        for org in organizations {
            db.execute_raw(sql(
                "INSERT OR IGNORE INTO id_floor_scan (org_id) VALUES (?)",
                vec![org.as_str().into()],
            ))
            .await?;
        }
        Ok((
            max_value(
                &db,
                "SELECT floor AS value FROM id_floor WHERE name = 'projects'",
            )
            .await?,
            max_value(
                &db,
                "SELECT floor AS value FROM id_floor WHERE name = 'sources'",
            )
            .await?,
        ))
    }
    .await;
    db.close().await?;
    result
}

/// Runs at server start before any route is served. The candidate may have
/// issued project and source ids between the restore task and activation,
/// and their log objects reach R2. For each organization the restore task
/// recorded, raises the floor of the active control above every id in its R2
/// log objects that the active organization file has not archived, then
/// clears the record. For an inactive organization it only clears the
/// record.
pub async fn raise_restored_id_floors(rt: &Runtime) -> Result<(), BackupError> {
    let rows = rt
        .control
        .query_all_raw(sql(
            "SELECT org_id FROM id_floor_scan ORDER BY org_id",
            vec![],
        ))
        .await?;
    for row in rows {
        let stored: String = row.try_get("", "org_id")?;
        let org: OrgId = stored
            .parse()
            .map_err(|()| BackupError::Invalid(format!("id floor scan org {stored}")))?;
        let floor = match rt.tenant(&org).await {
            Ok(handle) => {
                let archived = archived_log_keys(&*handle).await?;
                drop(handle);
                unarchived_log_ids(rt, &org, &archived).await?
            }
            Err(crate::error::ApiError::NotFound) => (0, 0),
            Err(error) => {
                return Err(BackupError::Organization {
                    org,
                    detail: format!("open for the id floor scan: {error}"),
                })
            }
        };
        let txn = rt.control.begin().await?;
        raise_floor(&txn, floor).await?;
        txn.execute_raw(sql(
            "DELETE FROM id_floor_scan WHERE org_id = ?",
            vec![org.as_str().into()],
        ))
        .await?;
        txn.commit().await?;
        tracing::info!(org = %org, projects = floor.0, sources = floor.1,
            "restored organization id floor raised");
    }
    Ok(())
}

async fn deleted_in_live_control(
    control: &DatabaseConnection,
    manifest: &Manifest,
) -> Result<Vec<OrgId>, BackupError> {
    let mut deleted = Vec::new();
    for org in manifest.organizations.keys() {
        let row = control
            .query_one_raw(sql(
                "SELECT 1 AS found FROM organization_deletions WHERE org_id = ?",
                vec![org.as_str().into()],
            ))
            .await?;
        if row.is_some() {
            deleted.push(org.clone());
        }
    }
    Ok(deleted)
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use base64::Engine as _;

    use super::*;
    use crate::backup::Limits;

    fn backups() -> Backups {
        let key = credseal::SecretString::deserialize(serde::de::value::StrDeserializer::<
            serde::de::value::Error,
        >::new(
            &base64::engine::general_purpose::STANDARD.encode([3u8; 32]),
        ))
        .unwrap();
        let scratch = std::env::temp_dir();
        Backups::new(
            scratch,
            Limits {
                max_snapshot_bytes: 1 << 20,
                max_object_bytes: 1 << 20,
                deadline: Duration::from_secs(5),
                max_scratch_dirs: 1,
                retain_failures: Duration::from_secs(3_600),
            },
            &key,
        )
        .unwrap()
    }

    fn member(key: String) -> Member {
        Member {
            key,
            captured_at_us: 10,
            snapshot_bytes: 4096,
            object_bytes: 512,
            snapshot_sha256: "aa".to_owned(),
            object_sha256: "bb".to_owned(),
        }
    }

    #[test]
    fn manifest_round_trips_and_rejects_tamper_unknown_format_and_extra_fields() {
        let set = SetId::parse("01a14789237370e593e2228768ac7597").unwrap();
        let org: OrgId = "o0123456789abcdef0123456789abcdef".parse().unwrap();
        let manifest = Manifest {
            format: 1,
            set,
            started_at_us: 1,
            completed_at_us: 2,
            revision: 5,
            control: member(member_key(set, &Scope::Control)),
            organizations: BTreeMap::from([(
                org.clone(),
                member(member_key(set, &Scope::Organization(org.clone()))),
            )]),
        };
        assert_eq!(
            serde_json::to_string(&manifest).unwrap(),
            r#"{"format":1,"set":"01a14789237370e593e2228768ac7597","started_at_us":1,"completed_at_us":2,"revision":5,"control":{"key":"backups/sets/01a14789237370e593e2228768ac7597/control.pdbk","captured_at_us":10,"snapshot_bytes":4096,"object_bytes":512,"snapshot_sha256":"aa","object_sha256":"bb"},"organizations":{"o0123456789abcdef0123456789abcdef":{"key":"backups/sets/01a14789237370e593e2228768ac7597/org/o0123456789abcdef0123456789abcdef.pdbk","captured_at_us":10,"snapshot_bytes":4096,"object_bytes":512,"snapshot_sha256":"aa","object_sha256":"bb"}}}"#
        );
        let backups = backups();
        let body = manifest.seal(&backups).unwrap();
        assert_eq!(
            Manifest::open(&backups, set, body.clone()).unwrap(),
            manifest
        );

        let mut flipped = body.to_vec();
        let last = flipped.len() - 1;
        flipped[last] ^= 1;
        assert!(matches!(
            Manifest::open(&backups, set, Bytes::from(flipped)),
            Err(BackupError::Authentication)
        ));
        let other = SetId::parse("01a14789237370e593e2228768ac7598").unwrap();
        assert!(matches!(
            Manifest::open(&backups, other, body),
            Err(BackupError::Authentication)
        ));

        let reseal = |json: serde_json::Value| {
            backups
                .seal_bytes(
                    &Scope::Manifest,
                    &manifest_key(set),
                    json.to_string().as_bytes(),
                )
                .unwrap()
        };
        let mut format_2 = serde_json::to_value(&manifest).unwrap();
        format_2["format"] = serde_json::json!(2);
        assert!(matches!(
            Manifest::open(&backups, set, reseal(format_2)),
            Err(BackupError::Malformed)
        ));
        let mut extra = serde_json::to_value(&manifest).unwrap();
        extra["unexpected"] = serde_json::json!(true);
        assert!(matches!(
            Manifest::open(&backups, set, reseal(extra)),
            Err(BackupError::Malformed)
        ));
        let mut moved = serde_json::to_value(&manifest).unwrap();
        moved["control"]["key"] = serde_json::json!("backups/control/legacy.pdbk");
        assert!(matches!(
            Manifest::open(&backups, set, reseal(moved)),
            Err(BackupError::Malformed)
        ));
    }

    #[test]
    fn health_is_failing_after_a_failed_cycle_and_stale_without_a_recent_complete_set() {
        let settings = BackupSettings::default();
        let s = 1_000_000;
        let window = (2 * 3_600 + 300 + 180) * s;
        let started = 10 * s;
        let health = |now, complete, outcome| {
            let h = BackupHealth::classify(&settings, now, started, complete, outcome);
            (h.state, h.last_complete_age_secs)
        };
        assert_eq!(
            health(started + window, None, None),
            (HealthState::Ok, None)
        );
        assert_eq!(
            health(started + window + 1, None, None),
            (HealthState::Stale, None)
        );
        assert_eq!(
            health(started + 5 * s, None, Some("failed")),
            (HealthState::Failing, None)
        );
        let complete = started + 100 * s;
        assert_eq!(
            health(complete + 42 * s, Some(complete), Some("complete")),
            (HealthState::Ok, Some(42))
        );
        assert_eq!(
            health(complete + 42 * s, Some(complete), Some("changed")),
            (HealthState::Failing, Some(42))
        );
        assert_eq!(
            health(complete + window + s, Some(complete), Some("complete")),
            (HealthState::Stale, Some(7_681))
        );
        assert_eq!(
            serde_json::to_value(BackupHealth::classify(
                &settings,
                complete + 3 * s,
                started,
                Some(complete),
                Some("complete")
            ))
            .unwrap(),
            serde_json::json!({"state": "ok", "last_complete_age_secs": 3})
        );
    }

    #[test]
    fn set_ids_parse_only_canonical_version_7_and_order_by_time() {
        let id = SetId::generate();
        assert_eq!(SetId::parse(&id.to_string()), Some(id));
        assert_eq!(SetId::parse("01A14789237370E593E2228768AC7597"), None);
        assert_eq!(SetId::parse("01a14789-2373-70e5-93e2-228768ac7597"), None);
        assert_eq!(SetId::parse("01a14789237340e593e2228768ac7597"), None);
        let set = SetId::parse("01a14789237370e593e2228768ac7597").unwrap();
        assert_eq!(set.created_at_us(), 0x01a1_4789_2373 * 1_000);
        assert_eq!(
            member_key(set, &Scope::Organization("o0123456789abcdef0123456789abcdef".parse().unwrap())),
            "backups/sets/01a14789237370e593e2228768ac7597/org/o0123456789abcdef0123456789abcdef.pdbk"
        );
        assert!(SetId::generate() > set);
    }
}
