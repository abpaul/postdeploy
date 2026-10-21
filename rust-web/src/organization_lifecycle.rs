use std::{
    collections::HashSet,
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};

use sea_orm::{
    ConnectionTrait, DatabaseConnection, SqliteTransactionMode, TransactionOptions,
    TransactionTrait,
};
use serde::Deserialize;
use tenant_sqlite_loco::TenantPools;
use tokio::sync::Mutex;
use tokio_util::sync::CancellationToken;

use crate::{
    domain::{now_secs, OrgId, Role},
    error::{ApiError, ApiResult},
    identity::access::OrgAccess,
    runtime::{sql, Gate},
    store::ObjectStore,
};

pub(crate) async fn active_tenant(
    control: &DatabaseConnection,
    tenants: &TenantPools,
    org: &OrgId,
) -> ApiResult<tenant_sqlite_loco::TenantHandle> {
    require_active(control, org).await?;
    let handle = tenants.registry().open_existing(&org.tenant()).await?;
    require_active(control, org).await?;
    Ok(handle)
}

async fn require_active(control: &DatabaseConnection, org: &OrgId) -> ApiResult<()> {
    control
        .query_one_raw(sql(
            "SELECT 1 AS found FROM organizations WHERE id = ? AND lifecycle = 'active'",
            vec![org.as_str().into()],
        ))
        .await?
        .map(|_| ())
        .ok_or(ApiError::NotFound)
}

#[derive(Clone, Debug, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct DeleteSettings {
    pub page_size: usize,
    pub max_pages: usize,
    pub max_jobs: usize,
    pub interval_secs: u64,
    pub close_timeout_ms: u64,
    pub max_local_deletions_per_process: usize,
}

impl Default for DeleteSettings {
    fn default() -> Self {
        Self {
            page_size: 100,
            max_pages: 5,
            max_jobs: 10,
            interval_secs: 30,
            close_timeout_ms: 5_000,
            max_local_deletions_per_process: 16_384,
        }
    }
}

impl DeleteSettings {
    pub fn validate(&self) -> bool {
        (1..=1_000).contains(&self.page_size)
            && (1..=100).contains(&self.max_pages)
            && (1..=100).contains(&self.max_jobs)
            && (1..=86_400).contains(&self.interval_secs)
            && (1..=60_000).contains(&self.close_timeout_ms)
            && (1..=65_536).contains(&self.max_local_deletions_per_process)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Phase {
    Logs,
    Errors,
    Releases,
    Reports,
    Backups,
    Database,
}

impl Phase {
    fn parse(value: i64) -> ApiResult<Self> {
        match value {
            0 => Ok(Self::Logs),
            1 => Ok(Self::Errors),
            2 => Ok(Self::Releases),
            3 => Ok(Self::Reports),
            4 => Ok(Self::Backups),
            5 => Ok(Self::Database),
            _ => Err(ApiError::Internal("organization deletion phase".into())),
        }
    }

    fn number(self) -> i64 {
        match self {
            Self::Logs => 0,
            Self::Errors => 1,
            Self::Releases => 2,
            Self::Reports => 3,
            Self::Backups => 4,
            Self::Database => 5,
        }
    }

    fn prefix(self, org: &OrgId) -> Option<String> {
        let kind = match self {
            Self::Logs => "logs/v1",
            Self::Errors => "errors/v1",
            Self::Releases => "releases/v1",
            Self::Reports => "reports/v1",
            Self::Backups => "backups/org",
            Self::Database => return None,
        };
        Some(format!("{kind}/{org}/"))
    }
}

#[derive(Debug, Default, PartialEq, Eq)]
pub struct DeleteReport {
    pub listed: usize,
    pub deleted: usize,
    pub local_removed: usize,
    pub deferred: usize,
}

pub struct OrganizationLifecycle {
    control: DatabaseConnection,
    tenants: TenantPools,
    store: ObjectStore,
    settings: DeleteSettings,
    backup_scratch: Option<PathBuf>,
    sweep_lock: Mutex<()>,
    closed_orgs: Mutex<HashSet<OrgId>>,
}

impl OrganizationLifecycle {
    pub fn new(
        control: DatabaseConnection,
        tenants: TenantPools,
        store: ObjectStore,
        settings: DeleteSettings,
        backup_scratch: Option<PathBuf>,
    ) -> Self {
        Self {
            control,
            tenants,
            store,
            settings,
            backup_scratch,
            sweep_lock: Mutex::new(()),
            closed_orgs: Mutex::new(HashSet::new()),
        }
    }

    pub async fn request(
        &self,
        rt: &crate::runtime::Runtime,
        billing: &crate::billing::Billing,
        access: &OrgAccess,
        confirmed_name: &str,
    ) -> ApiResult<()> {
        let _billing = billing.deletion_guard(rt, access).await?;
        let txn = self
            .control
            .begin_with_options(TransactionOptions {
                sqlite_transaction_mode: Some(SqliteTransactionMode::Immediate),
                ..TransactionOptions::default()
            })
            .await?;
        let row = txn
            .query_one_raw(sql(
                "SELECT o.name, m.role FROM organizations o JOIN memberships m ON m.org_id = o.id
             WHERE o.id = ? AND m.user_id = ? AND o.lifecycle = 'active'",
                vec![access.org.as_str().into(), access.user.0.into()],
            ))
            .await?
            .ok_or(ApiError::NotFound)?;
        let role: String = row.try_get("", "role")?;
        if Role::parse(&role) != Some(Role::Owner) {
            return Err(ApiError::Forbidden);
        }
        let name: String = row.try_get("", "name")?;
        if name != confirmed_name {
            return Err(ApiError::BadRequest("organization_name_confirmation"));
        }
        let renewing = txn.query_one_raw(sql(
            "SELECT 1 FROM billing_accounts WHERE org_id = ? AND stripe_subscription_id IS NOT NULL
             AND COALESCE(subscription_status, '') NOT IN ('canceled', 'incomplete_expired')
             AND cancel_at_period_end = 0",
            vec![access.org.as_str().into()],
        )).await?;
        if renewing.is_some() {
            return Err(ApiError::Conflict("billing_subscription_renewing"));
        }
        let barrier =
            self.store
                .reserve_org_write_barrier(&access.org)
                .map_err(|error| match error {
                    crate::store::StoreError::WriteBarrierCapacity => {
                        ApiError::Unavailable("organization_deletion_capacity")
                    }
                    other => ApiError::internal("organization deletion write barrier", other),
                })?;
        txn.execute_raw(sql(
            "UPDATE organizations SET lifecycle = 'deleting' WHERE id = ? AND lifecycle = 'active'",
            vec![access.org.as_str().into()],
        ))
        .await?;
        txn.execute_raw(sql(
            "INSERT INTO organization_deletions (org_id, requested_at) VALUES (?, ?)",
            vec![access.org.as_str().into(), now_secs().into()],
        ))
        .await?;
        for table in [
            "oauth_codes",
            "oauth_grants",
            "agent_api_keys",
            "memberships",
            "projects",
        ] {
            txn.execute_raw(sql(
                &format!("DELETE FROM {table} WHERE org_id = ?"),
                vec![access.org.as_str().into()],
            ))
            .await?;
        }
        txn.commit().await?;
        barrier.commit();
        Ok(())
    }

    pub async fn sweep(&self) -> ApiResult<DeleteReport> {
        let Ok(_lock) = self.sweep_lock.try_lock() else {
            return Err(ApiError::Unavailable("organization_deletion_busy"));
        };
        let rows = self
            .control
            .query_all_raw(sql(
                "SELECT org_id, phase, after_key, local_removed FROM organization_deletions
                 ORDER BY attempted_at, requested_at, org_id LIMIT ?",
                vec![(self.settings.max_jobs as i64).into()],
            ))
            .await?;
        let mut report = DeleteReport::default();
        for row in rows {
            let raw: String = row.try_get("", "org_id")?;
            let org = raw
                .parse::<OrgId>()
                .map_err(|()| ApiError::Internal("organization deletion id".into()))?;
            let phase = Phase::parse(row.try_get("", "phase")?)?;
            let after = row.try_get::<Option<String>>("", "after_key")?;
            let local_removed = row.try_get::<i64>("", "local_removed")? == 1;
            self.control
                .execute_raw(sql(
                    "UPDATE organization_deletions SET attempted_at = ? WHERE org_id = ?",
                    vec![crate::domain::now_micros().into(), org.as_str().into()],
                ))
                .await?;
            if !local_removed {
                if let Err(error) = self.store.block_org_writes(&org) {
                    report.deferred += 1;
                    tracing::warn!(org = %org, %error, "organization deletion write barrier unavailable");
                    continue;
                }
                if self.store.org_writes_pending(&org) {
                    report.deferred += 1;
                    continue;
                }
            }
            if let Err(error) = self
                .sweep_job(&org, phase, after, local_removed, &mut report)
                .await
            {
                report.deferred += 1;
                tracing::warn!(org = %org, %error, "organization deletion deferred");
            }
        }
        Ok(report)
    }

    async fn sweep_job(
        &self,
        org: &OrgId,
        mut phase: Phase,
        mut after: Option<String>,
        local_removed: bool,
        report: &mut DeleteReport,
    ) -> ApiResult<()> {
        for _ in 0..self.settings.max_pages {
            let Some(prefix) = phase.prefix(org) else {
                if local_removed {
                    self.save_cursor(org, Phase::Logs, None).await?;
                    return Ok(());
                }
                self.delete_database(org).await?;
                report.local_removed += 1;
                return Ok(());
            };
            if after.as_ref().is_some_and(|key| !key.starts_with(&prefix)) {
                return Err(ApiError::Internal("organization deletion cursor".into()));
            }
            let page = self
                .store
                .list_page(&prefix, after.as_deref(), self.settings.page_size)
                .await
                .map_err(|error| ApiError::internal("organization deletion list", error))?;
            report.listed += page.keys.len();
            for key in &page.keys {
                if !key.starts_with(&prefix) {
                    return Err(ApiError::Internal(
                        "organization deletion object scope".into(),
                    ));
                }
                self.store
                    .delete(key)
                    .await
                    .map_err(|error| ApiError::internal("organization deletion object", error))?;
                report.deleted += 1;
            }
            after = page.next;
            if after.is_none() {
                phase = Phase::parse(phase.number() + 1)?;
            }
            self.save_cursor(org, phase, after.as_deref()).await?;
        }
        Ok(())
    }

    async fn save_cursor(&self, org: &OrgId, phase: Phase, after: Option<&str>) -> ApiResult<()> {
        self.control
            .execute_raw(sql(
                "UPDATE organization_deletions SET phase = ?, after_key = ? WHERE org_id = ?",
                vec![
                    phase.number().into(),
                    after.map(str::to_owned).into(),
                    org.as_str().into(),
                ],
            ))
            .await?;
        Ok(())
    }

    async fn delete_database(&self, org: &OrgId) -> ApiResult<()> {
        for phase in [
            Phase::Logs,
            Phase::Errors,
            Phase::Releases,
            Phase::Reports,
            Phase::Backups,
        ] {
            let prefix = phase.prefix(org).expect("object phase");
            if !self
                .store
                .list_page(&prefix, None, 1)
                .await
                .map_err(|error| ApiError::internal("organization deletion verification", error))?
                .keys
                .is_empty()
            {
                self.control.execute_raw(sql(
                    "UPDATE organization_deletions SET phase = 0, after_key = NULL WHERE org_id = ?",
                    vec![org.as_str().into()],
                )).await?;
                return Err(ApiError::Unavailable(
                    "organization_deletion_objects_remain",
                ));
            }
        }
        self.tenants.registry().evict(&org.tenant()).await?;
        {
            let mut closed = self.closed_orgs.lock().await;
            if !closed.contains(org)
                && closed.len() >= self.settings.max_local_deletions_per_process
            {
                return Err(ApiError::Unavailable(
                    "organization_deletion_restart_required",
                ));
            }
            closed.insert(org.clone());
        }
        let path = tokio::time::timeout(
            Duration::from_millis(self.settings.close_timeout_ms),
            self.tenants.registry().close_for_deletion(&org.tenant()),
        )
        .await
        .map_err(|_| ApiError::Unavailable("organization_deletion_drain"))??;
        for suffix in ["-wal", "-shm", ""] {
            let mut file = path.as_os_str().to_owned();
            file.push(suffix);
            remove_database_file(Path::new(&file)).await?;
        }
        if let Some(scratch) = &self.backup_scratch {
            crate::backup::remove_organization_scratch(scratch, org).map_err(|error| {
                ApiError::internal("organization backup scratch removal", error)
            })?;
        }
        let txn = self.control.begin().await?;
        txn.execute_raw(sql(
            "DELETE FROM organizations WHERE id = ? AND lifecycle = 'deleting'",
            vec![org.as_str().into()],
        ))
        .await?;
        txn.execute_raw(sql(
            "UPDATE organization_deletions SET local_removed = 1, phase = 0, after_key = NULL WHERE org_id = ?",
            vec![org.as_str().into()],
        )).await?;
        txn.commit().await?;
        self.store.release_org_write_barrier(org);
        Ok(())
    }

    pub async fn run(&self, cancel: CancellationToken, gate: Arc<Gate>) {
        let mut ticker = tokio::time::interval(Duration::from_secs(self.settings.interval_secs));
        loop {
            tokio::select! { () = cancel.cancelled() => return, _ = ticker.tick() => {} }
            let Some(_guard) = gate.enter() else {
                if gate.is_open() {
                    continue;
                }
                return;
            };
            let result = tokio::select! { () = cancel.cancelled() => return, result = self.sweep() => result };
            if let Err(error) = result {
                tracing::warn!(%error, "organization deletion sweep failed");
            }
        }
    }
}

async fn remove_database_file(path: &Path) -> ApiResult<()> {
    match tokio::fs::symlink_metadata(path).await {
        Ok(metadata) if metadata.is_file() && !metadata.file_type().is_symlink() => {
            tokio::fs::remove_file(path)
                .await
                .map_err(|error| ApiError::internal("organization database removal", error))
        }
        Ok(_) => Err(ApiError::Internal(
            "unsafe organization database path".into(),
        )),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(ApiError::internal(
            "organization database inspection",
            error,
        )),
    }
}
