//! Process-wide services shared by HTTP handlers and in-process background work.
//! One `Runtime` owns the single tenant registry clone used by the application.

use std::{
    collections::{HashMap, HashSet},
    future::Future,
    sync::{atomic::AtomicU64, Arc, Mutex, OnceLock},
    time::Duration,
};

use loco_rs::app::AppContext;
use sea_orm::{DatabaseConnection, DbBackend, Statement};
use tenant_sqlite_loco::{TenantHandle, TenantPools};
use tokio::{sync::Notify, task::JoinSet};
use tokio_util::sync::CancellationToken;

use crate::{
    admission::Admission,
    domain::OrgId,
    error::ApiError,
    logs::{live::LiveHub, pending::PendingCipher, storage::LogStorage},
    quota::Quotas,
    settings::{LifecycleSettings, Settings},
    store::{Faults, ObjectStore},
};

pub struct Runtime {
    pub settings: Settings,
    pub control: DatabaseConnection,
    pub tenants: TenantPools,
    pub store: ObjectStore,
    pub gate: Arc<Gate>,
    pub cancel: CancellationToken,
    pub admission: Admission,
    pub reconciliation: crate::logs::reconcile::Reconciliation,
    pub disk: Arc<crate::disk::DiskAdmission>,
    pub releases: crate::releases::Releases,
    pub error_retention: crate::error_retention::ErrorRetention,
    pub orphan_retention: crate::orphan_retention::OrphanRetention,
    pub organization_lifecycle: crate::organization_lifecycle::OrganizationLifecycle,
    pub password_policy: Arc<crate::password_policy::PasswordPolicy>,
    pub quotas: Quotas,
    pub log_storage: LogStorage,
    pub pending_cipher: Arc<PendingCipher>,
    pub hub: LiveHub,
    pub metrics: Metrics,
    pub notifications: OnceLock<crate::notifications::Notifications>,
    background: Mutex<JoinSet<()>>,
    dirty: Mutex<HashSet<OrgId>>,
    dirty_wake: Notify,
    root_lock: Mutex<Option<crate::app::RootLock>>,
}

#[derive(Debug, Default)]
pub struct Metrics {
    pub envelopes: AtomicU64,
    pub events_accepted: AtomicU64,
    pub events_duplicate: AtomicU64,
    pub events_dropped: AtomicU64,
    pub logs_accepted: AtomicU64,
    pub logs_dropped: AtomicU64,
    pub items_skipped: AtomicU64,
    pub outcome_writes_failed: AtomicU64,
    pub rejected_rate: AtomicU64,
    pub rejected_overload: AtomicU64,
    pub rejected_policy_invalid: AtomicU64,
    policy_refusals: Mutex<HashMap<OrgId, u64>>,
    pub log_batches_failed: AtomicU64,
    pub objects_archived: AtomicU64,
    pub archive_conflicts: AtomicU64,
    pub log_upload_retries: AtomicU64,
    pub objects_adopted: AtomicU64,
    pub logs_adopted: AtomicU64,
    pub objects_expired: AtomicU64,
}

/// Organizations whose invalid-policy refusals are counted apart. One more
/// organization restarts every count, which only adds warnings.
const MAX_REFUSING_ORGS: usize = 1_024;

impl Metrics {
    /// Counts one ingestion refusal for an invalid stored policy and returns
    /// the organization's own count, so one organization's flood cannot hide
    /// another's first refusals.
    pub fn refuse_invalid_policy(&self, org: &OrgId) -> u64 {
        self.rejected_policy_invalid
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let mut counts = self.policy_refusals.lock().expect("policy refusal lock");
        if counts.len() >= MAX_REFUSING_ORGS && !counts.contains_key(org) {
            counts.clear();
        }
        let count = counts.entry(org.clone()).or_default();
        *count += 1;
        *count
    }
}

impl Runtime {
    pub fn new(
        settings: Settings,
        control: DatabaseConnection,
        tenants: TenantPools,
        store: ObjectStore,
        root_lock: crate::app::RootLock,
        password_policy: Arc<crate::password_policy::PasswordPolicy>,
        pending_cipher: PendingCipher,
    ) -> Self {
        Self {
            password_policy,
            organization_lifecycle: crate::organization_lifecycle::OrganizationLifecycle::new(
                control.clone(),
                tenants.clone(),
                store.clone(),
                settings.organization_deletion.clone(),
                crate::backup::scratch_root(&settings.tenants.root),
            ),
            orphan_retention: crate::orphan_retention::OrphanRetention::new(
                control.clone(),
                tenants.clone(),
                store.clone(),
                settings.orphan_retention.clone(),
            ),
            disk: Arc::new(crate::disk::DiskAdmission::new(
                crate::disk::data_root(&settings.tenants.root)
                    .expect("validated tenant data parent"),
                settings.disk.clone(),
            )),
            releases: crate::releases::Releases::new(
                control.clone(),
                tenants.clone(),
                store.clone(),
                settings.releases.clone(),
            ),
            error_retention: crate::error_retention::ErrorRetention::new(
                control.clone(),
                tenants.clone(),
                store.clone(),
                settings.error_retention.clone(),
            ),
            admission: Admission::new(&settings),
            reconciliation: crate::logs::reconcile::Reconciliation::new(
                settings.logs.reconcile_concurrency,
            ),
            log_storage: LogStorage::new(&settings.logs),
            pending_cipher: Arc::new(pending_cipher),
            hub: LiveHub::new(
                settings.logs.tail.channel_capacity,
                settings.lifecycle.max_cached_orgs,
            ),
            quotas: Quotas::new(settings.lifecycle.max_cached_orgs),
            gate: Arc::new(Gate::new(settings.lifecycle.max_active_requests)),
            settings,
            control,
            tenants,
            store,
            cancel: CancellationToken::new(),
            metrics: Metrics::default(),
            notifications: OnceLock::new(),
            background: Mutex::new(JoinSet::new()),
            dirty: Mutex::default(),
            dirty_wake: Notify::new(),
            root_lock: Mutex::new(Some(root_lock)),
        }
    }

    pub fn get(ctx: &AppContext) -> Arc<Self> {
        ctx.shared_store
            .get::<Arc<Self>>()
            .expect("runtime is installed in after_context")
    }

    pub(crate) fn faults(&self) -> Option<&Arc<Faults>> {
        self.store.faults()
    }

    /// Opens an existing organization database. Hold the handle only for
    /// database work; never across object storage I/O, waits or streams.
    pub async fn tenant(&self, org: &OrgId) -> Result<TenantHandle, ApiError> {
        crate::organization_lifecycle::active_tenant(&self.control, &self.tenants, org).await
    }

    pub fn spawn_background<F>(&self, task: F)
    where
        F: Future<Output = ()> + Send + 'static,
    {
        self.background
            .lock()
            .expect("background set lock")
            .spawn(task);
    }

    pub fn dirty_orgs(&self) -> usize {
        self.dirty.lock().expect("dirty lock").len()
    }

    pub fn mark_dirty(&self, org: &OrgId) {
        self.quotas.dirty(org);
        self.requeue_dirty(org);
    }

    pub(crate) fn requeue_dirty(&self, org: &OrgId) {
        let mut dirty = self.dirty.lock().expect("dirty lock");
        if dirty.len() < self.settings.lifecycle.max_cached_orgs {
            dirty.insert(org.clone());
        }
        self.dirty_wake.notify_one();
    }

    pub(crate) async fn next_dirty(&self) -> Vec<OrgId> {
        loop {
            let notified = self.dirty_wake.notified();
            let orgs: Vec<OrgId> = self.dirty.lock().expect("dirty lock").drain().collect();
            if !orgs.is_empty() {
                return orgs;
            }
            notified.await;
        }
    }

    /// Stops admission and producers, drains in-flight work within bounded
    /// deadlines, then closes the tenant registry. Every timeout is logged as a
    /// failed shutdown step.
    pub async fn shutdown(&self) {
        let lifecycle = &self.settings.lifecycle;
        self.gate.close();
        self.cancel.cancel();
        let ms = Duration::from_millis;
        crate::logs::storage::close(self, ms(lifecycle.drain_ms)).await;
        if !self.gate.wait_idle(ms(lifecycle.drain_ms)).await {
            tracing::error!("shutdown: requests did not drain before the deadline");
        }
        let mut background =
            std::mem::take(&mut *self.background.lock().expect("background set lock"));
        if tokio::time::timeout(ms(lifecycle.background_ms), async {
            while background.join_next().await.is_some() {}
        })
        .await
        .is_err()
        {
            tracing::error!("shutdown: background tasks aborted at the deadline");
            background.abort_all();
            if tokio::time::timeout(LifecycleSettings::CANCEL_WAIT, async {
                while background.join_next().await.is_some() {}
            })
            .await
            .is_err()
            {
                tracing::error!("shutdown: aborted background tasks are still running");
            }
        }
        let registry_closed = match tokio::time::timeout(
            ms(lifecycle.registry_ms),
            self.tenants.registry().shutdown(),
        )
        .await
        {
            Ok(Ok(())) => true,
            Ok(Err(error)) => {
                tracing::error!(%error, "shutdown failed: tenant registry did not close");
                false
            }
            Err(_) => {
                tracing::error!(
                    "shutdown failed: tenant registry did not close before the deadline"
                );
                false
            }
        };
        if let Err(error) = self.control.close_by_ref().await {
            tracing::error!(%error, "shutdown: control database close failed");
        }
        if registry_closed {
            drop(self.root_lock.lock().expect("root lock").take());
        }
    }
}

/// Request admission gate. `enter` and `close` share one lock, so no request
/// can enter after shutdown begins.
pub struct Gate {
    state: Mutex<GateState>,
    idle: Notify,
    capacity: usize,
}

#[derive(Default)]
struct GateState {
    closed: bool,
    active: usize,
}

pub struct GateGuard(Arc<Gate>);

impl Gate {
    pub fn new(capacity: usize) -> Self {
        Self {
            state: Mutex::default(),
            idle: Notify::new(),
            capacity,
        }
    }

    pub fn enter(self: &Arc<Self>) -> Option<GateGuard> {
        let mut state = self.state.lock().expect("gate lock");
        if state.closed || state.active >= self.capacity {
            return None;
        }
        state.active += 1;
        Some(GateGuard(self.clone()))
    }

    pub fn close(&self) {
        self.state.lock().expect("gate lock").closed = true;
    }

    pub fn is_open(&self) -> bool {
        !self.state.lock().expect("gate lock").closed
    }

    pub async fn wait_idle(&self, deadline: Duration) -> bool {
        tokio::time::timeout(deadline, async {
            loop {
                let notified = self.idle.notified();
                tokio::pin!(notified);
                notified.as_mut().enable();
                if self.state.lock().expect("gate lock").active == 0 {
                    return;
                }
                notified.await;
            }
        })
        .await
        .is_ok()
    }
}

impl Default for Gate {
    fn default() -> Self {
        Self::new(128)
    }
}

impl Drop for GateGuard {
    fn drop(&mut self) {
        let mut state = self.0.state.lock().expect("gate lock");
        state.active -= 1;
        if state.active == 0 {
            self.0.idle.notify_waiters();
        }
    }
}

pub fn sql(sql: &str, values: Vec<sea_orm::Value>) -> Statement {
    Statement::from_sql_and_values(DbBackend::Sqlite, sql, values)
}
