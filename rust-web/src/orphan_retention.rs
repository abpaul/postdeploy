use std::{collections::HashSet, sync::Arc, time::Duration};

use sea_orm::{ConnectionTrait, DatabaseConnection};
use serde::Deserialize;
use tenant_sqlite_loco::TenantPools;
use tokio_util::sync::CancellationToken;

use crate::{
    domain::{now_micros, OrgId},
    error::{ApiError, ApiResult},
    runtime::{sql, Gate},
    store::ObjectStore,
};

#[derive(Clone, Debug, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct OrphanRetentionSettings {
    pub grace_secs: u64,
    pub page_size: usize,
    pub max_pages: usize,
    pub interval_secs: u64,
}

impl Default for OrphanRetentionSettings {
    fn default() -> Self {
        Self {
            grace_secs: 3_600,
            page_size: 200,
            max_pages: 3,
            interval_secs: 3_600,
        }
    }
}

impl OrphanRetentionSettings {
    pub fn validate(&self) -> bool {
        (3_600..=604_800).contains(&self.grace_secs)
            && (1..=1_000).contains(&self.page_size)
            && (1..=100).contains(&self.max_pages)
            && (1..=86_400).contains(&self.interval_secs)
    }
}

#[derive(Clone, Copy)]
pub(crate) enum ObjectKind {
    Error,
    Release,
    Report,
}

impl ObjectKind {
    pub(crate) const ALL: [Self; 3] = [Self::Error, Self::Release, Self::Report];

    fn prefix(self) -> &'static str {
        match self {
            Self::Error => "errors/v1",
            Self::Release => "releases/v1",
            Self::Report => "reports/v1",
        }
    }

    fn table_column(self) -> (&'static str, &'static str) {
        match self {
            Self::Error => ("events", "payload_key"),
            Self::Release => ("release_artifacts", "object_key"),
            Self::Report => ("reports", "object_key"),
        }
    }

    fn created_at(self, key: &str) -> Option<i64> {
        let file = key.rsplit('/').next()?;
        let raw = match self {
            Self::Error => file.strip_suffix(".json.zst")?.rsplit_once('-')?.1,
            Self::Release => file.strip_prefix('a')?.strip_suffix(".map.zst")?,
            Self::Report => file.strip_prefix('r')?.strip_suffix(".json")?,
        };
        if raw.len() != 32 {
            return None;
        }
        let id = uuid::Uuid::parse_str(raw).ok()?;
        (id.get_version_num() == 7).then(|| ((id.as_u128() >> 80) as i64) * 1_000)
    }
}

async fn known_keys(
    control: &DatabaseConnection,
    tenants: &TenantPools,
    org: &OrgId,
    kind: ObjectKind,
    keys: &[String],
) -> ApiResult<HashSet<String>> {
    if keys.is_empty() {
        return Ok(HashSet::new());
    }
    let handle = crate::organization_lifecycle::active_tenant(control, tenants, org).await?;
    referenced_in(&*handle, kind, keys).await
}

async fn referenced_in(
    db: &impl ConnectionTrait,
    kind: ObjectKind,
    keys: &[String],
) -> ApiResult<HashSet<String>> {
    if keys.is_empty() {
        return Ok(HashSet::new());
    }
    let (table, column) = kind.table_column();
    let placeholders = vec!["?"; keys.len()].join(",");
    let rows = db
        .query_all_raw(sql(
            &format!(
                "SELECT {column} AS object_key FROM {table} WHERE {column} IN ({placeholders})"
            ),
            keys.iter().cloned().map(Into::into).collect(),
        ))
        .await?;
    rows.iter()
        .map(|row| row.try_get("", "object_key").map_err(ApiError::from))
        .collect()
}

/// Unreferenced payloads of one kind, split at the snapshot capture time.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, serde::Serialize)]
pub struct Unreferenced {
    pub after_snapshot: usize,
    pub before_snapshot: usize,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, serde::Serialize)]
pub struct UnreferencedPayloads {
    pub errors: Unreferenced,
    pub releases: Unreferenced,
    pub reports: Unreferenced,
}

impl UnreferencedPayloads {
    fn kind(&mut self, kind: ObjectKind) -> &mut Unreferenced {
        match kind {
            ObjectKind::Error => &mut self.errors,
            ObjectKind::Release => &mut self.releases,
            ObjectKind::Report => &mut self.reports,
        }
    }
}

/// Payload keys are named before their upload and their database commit, so a
/// payload committed after a snapshot can carry a creation time slightly
/// before it. Counting this margin as after the snapshot keeps such payloads
/// in the operator's view.
pub(crate) const COMMIT_SKEW_US: i64 = 120_000_000;

/// Counts every payload of `org` in the store that the database `db` does not
/// reference. Deletes nothing. A key created within [`COMMIT_SKEW_US`] before
/// the snapshot counts as after it; a key without a creation time counts as
/// before.
pub(crate) async fn unreferenced(
    store: &ObjectStore,
    db: &impl ConnectionTrait,
    org: &OrgId,
    snapshot_captured_at_us: i64,
) -> ApiResult<UnreferencedPayloads> {
    let mut counts = UnreferencedPayloads::default();
    for kind in ObjectKind::ALL {
        let prefix = format!("{}/{org}/", kind.prefix());
        let mut after: Option<String> = None;
        loop {
            let page = store
                .list_page(&prefix, after.as_deref(), 1_000)
                .await
                .map_err(|error| ApiError::internal("unreferenced payload list", error))?;
            let known = referenced_in(db, kind, &page.keys).await?;
            for key in page.keys.iter().filter(|key| !known.contains(*key)) {
                let count = counts.kind(kind);
                match kind.created_at(key) {
                    Some(created) if created >= snapshot_captured_at_us - COMMIT_SKEW_US => {
                        count.after_snapshot += 1
                    }
                    _ => count.before_snapshot += 1,
                }
            }
            after = page.next;
            if after.is_none() {
                break;
            }
        }
    }
    Ok(counts)
}

pub(crate) async fn discard(
    control: &DatabaseConnection,
    tenants: &TenantPools,
    store: &ObjectStore,
    org: &OrgId,
    kind: ObjectKind,
    key: &str,
) {
    match known_keys(control, tenants, org, kind, &[key.to_owned()]).await {
        Ok(known) if known.is_empty() => {
            if let Err(error) = store.delete(key).await {
                tracing::warn!(org = %org, %error, "unreferenced payload remains for orphan sweep");
            }
        }
        Ok(_) => {}
        Err(error) => {
            tracing::warn!(org = %org, %error, "payload reference check deferred to orphan sweep")
        }
    }
}

#[derive(Debug, Default, PartialEq, Eq)]
pub struct SweepReport {
    pub listed: usize,
    pub deleted: usize,
    pub delete_failures: usize,
    pub protected: usize,
    pub invalid: usize,
    /// The organization database was restored from a backup; payloads it
    /// does not know may belong to newer data, so nothing is deleted.
    pub held: bool,
    /// Under a hold: listed payloads the restored database does not reference
    /// and that were created at or after the snapshot capture time.
    pub unreferenced_after_snapshot: usize,
}

pub struct OrphanRetention {
    control: DatabaseConnection,
    tenants: TenantPools,
    store: ObjectStore,
    settings: OrphanRetentionSettings,
}

impl OrphanRetention {
    pub fn new(
        control: DatabaseConnection,
        tenants: TenantPools,
        store: ObjectStore,
        settings: OrphanRetentionSettings,
    ) -> Self {
        Self {
            control,
            tenants,
            store,
            settings,
        }
    }

    pub async fn sweep_org(&self, org: &OrgId, now_us: i64) -> ApiResult<SweepReport> {
        let cutoff = now_us.saturating_sub(self.settings.grace_secs as i64 * 1_000_000);
        let mut report = SweepReport::default();
        let hold = {
            let handle =
                crate::organization_lifecycle::active_tenant(&self.control, &self.tenants, org)
                    .await?;
            let row = handle
                .query_one_raw(sql(
                    "SELECT orphan_cleanup_held, snapshot_captured_at, marked_at FROM restore_state WHERE id = 1",
                    vec![],
                ))
                .await?;
            match row {
                Some(row) if row.try_get::<i64>("", "orphan_cleanup_held")? == 1 => Some((
                    row.try_get::<Option<i64>>("", "snapshot_captured_at")?,
                    row.try_get::<Option<i64>>("", "marked_at")?,
                )),
                _ => None,
            }
        };
        if let Some((captured, marked)) = hold {
            report.held = true;
            self.count_held(
                org,
                captured.map_or(i64::MIN, |at| at - COMMIT_SKEW_US),
                &mut report,
            )
            .await?;
            tracing::warn!(
                org = %org,
                snapshot_captured_at_us = ?captured,
                marked_at_us = ?marked,
                listed = report.listed,
                unreferenced_after_snapshot = report.unreferenced_after_snapshot,
                "orphan cleanup held after restore; unreferenced payloads newer than the snapshot need an operator decision"
            );
            return Ok(report);
        }
        for kind in ObjectKind::ALL {
            let prefix = format!("{}/{org}/", kind.prefix());
            let mut after = self.cursor(org, kind).await?;
            for _ in 0..self.settings.max_pages {
                let page = self
                    .store
                    .list_page(&prefix, after.as_deref(), self.settings.page_size)
                    .await
                    .map_err(|error| ApiError::internal("orphan list", error))?;
                report.listed += page.keys.len();
                let pending: HashSet<&str> = page
                    .keys
                    .iter()
                    .filter(|key| self.store.is_pending(key))
                    .map(String::as_str)
                    .collect();
                let known = known_keys(&self.control, &self.tenants, org, kind, &page.keys).await?;
                for key in &page.keys {
                    if pending.contains(key.as_str())
                        || known.contains(key)
                        || self.store.is_pending(key)
                    {
                        report.protected += 1;
                        continue;
                    }
                    match kind.created_at(key) {
                        Some(created) if created < cutoff => {}
                        Some(_) => {
                            report.protected += 1;
                            continue;
                        }
                        None => {
                            report.invalid += 1;
                            continue;
                        }
                    }
                    match self.store.delete(key).await {
                        Ok(()) => report.deleted += 1,
                        Err(error) => {
                            report.delete_failures += 1;
                            tracing::warn!(org = %org, %error, "orphan payload deletion deferred");
                        }
                    }
                }
                self.save_cursor(org, kind, page.next.as_deref()).await?;
                after = page.next;
                if after.is_none() {
                    break;
                }
            }
        }
        Ok(report)
    }

    /// The bounded listing pass of a normal sweep that only counts. Nothing is
    /// deleted while the restore hold stands.
    async fn count_held(
        &self,
        org: &OrgId,
        captured_at_us: i64,
        report: &mut SweepReport,
    ) -> ApiResult<()> {
        for kind in ObjectKind::ALL {
            let prefix = format!("{}/{org}/", kind.prefix());
            let mut after = self.cursor(org, kind).await?;
            for _ in 0..self.settings.max_pages {
                let page = self
                    .store
                    .list_page(&prefix, after.as_deref(), self.settings.page_size)
                    .await
                    .map_err(|error| ApiError::internal("orphan list", error))?;
                report.listed += page.keys.len();
                let known = known_keys(&self.control, &self.tenants, org, kind, &page.keys).await?;
                report.unreferenced_after_snapshot += page
                    .keys
                    .iter()
                    .filter(|key| !known.contains(*key) && !self.store.is_pending(key))
                    .filter(|key| {
                        kind.created_at(key)
                            .is_some_and(|created| created >= captured_at_us)
                    })
                    .count();
                self.save_cursor(org, kind, page.next.as_deref()).await?;
                after = page.next;
                if after.is_none() {
                    break;
                }
            }
        }
        Ok(())
    }

    async fn cursor(&self, org: &OrgId, kind: ObjectKind) -> ApiResult<Option<String>> {
        let handle =
            crate::organization_lifecycle::active_tenant(&self.control, &self.tenants, org).await?;
        let row = handle
            .query_one_raw(sql(
                "SELECT after_key FROM orphan_scan_cursors WHERE kind = ?",
                vec![kind.prefix().into()],
            ))
            .await?;
        Ok(row
            .map(|row| row.try_get("", "after_key"))
            .transpose()?
            .flatten())
    }

    async fn save_cursor(
        &self,
        org: &OrgId,
        kind: ObjectKind,
        after: Option<&str>,
    ) -> ApiResult<()> {
        let handle =
            crate::organization_lifecycle::active_tenant(&self.control, &self.tenants, org).await?;
        handle.execute_raw(sql(
            "INSERT INTO orphan_scan_cursors (kind, after_key) VALUES (?, ?) ON CONFLICT (kind) DO UPDATE SET after_key = excluded.after_key",
            vec![kind.prefix().into(), after.map(str::to_owned).into()],
        )).await?;
        Ok(())
    }

    pub async fn run(&self, cancel: CancellationToken, gate: Arc<Gate>) {
        let mut ticker = tokio::time::interval(Duration::from_secs(self.settings.interval_secs));
        loop {
            tokio::select! { () = cancel.cancelled() => return, _ = ticker.tick() => {} }
            let mut after = String::new();
            'pages: loop {
                let rows = match self
                    .control
                    .query_all_raw(sql(
                        "SELECT id FROM organizations WHERE id > ? AND lifecycle = 'active' ORDER BY id LIMIT 100",
                        vec![after.clone().into()],
                    ))
                    .await
                {
                    Ok(rows) => rows,
                    Err(error) => {
                        tracing::warn!(%error, "orphan sweep could not list organizations");
                        break;
                    }
                };
                if rows.is_empty() {
                    break;
                }
                for row in rows {
                    let Ok(id) = row.try_get::<String>("", "id") else {
                        tracing::warn!("orphan sweep could not read organization ids");
                        break 'pages;
                    };
                    after.clone_from(&id);
                    let Ok(org) = id.parse::<OrgId>() else {
                        tracing::warn!("orphan sweep skipped invalid organization id");
                        continue;
                    };
                    let Some(_guard) = gate.enter() else {
                        if gate.is_open() {
                            continue;
                        }
                        return;
                    };
                    let swept = tokio::select! {
                        () = cancel.cancelled() => return,
                        swept = self.sweep_org(&org, now_micros()) => swept,
                    };
                    if let Err(error) = swept {
                        tracing::warn!(org = %org, %error, "orphan payload sweep failed");
                    }
                }
            }
        }
    }
}
