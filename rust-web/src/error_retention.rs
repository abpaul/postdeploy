use std::{sync::Arc, time::Duration};

use futures::{stream, StreamExt};
use sea_orm::{ConnectionTrait, DatabaseConnection};
use serde::{Deserialize, Serialize};
use tenant_sqlite_loco::{TenantHandle, TenantPools};
use tokio_util::sync::CancellationToken;

use crate::{
    domain::{utc_day, OrgId},
    error::{ApiError, ApiResult},
    runtime::sql,
    store::ObjectStore,
};

pub const TENANT_RUN_ON_START: &str = "PRAGMA auto_vacuum = INCREMENTAL;";

pub async fn initialize_tenant(db: &DatabaseConnection) -> Result<(), sea_orm::DbErr> {
    let mode = db
        .query_one_raw(sql("PRAGMA auto_vacuum", vec![]))
        .await?
        .ok_or_else(|| sea_orm::DbErr::Custom("tenant vacuum pragma is missing".into()))?
        .try_get_by_index::<i64>(0)?;
    if mode == 2 {
        return Ok(());
    }
    let tables = db
        .query_one_raw(sql(
            "SELECT COUNT(*) FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
            vec![],
        ))
        .await?
        .ok_or_else(|| sea_orm::DbErr::Custom("tenant schema count is missing".into()))?
        .try_get_by_index::<i64>(0)?;
    if tables != 0 {
        return Err(sea_orm::DbErr::Custom(
            "tenant requires offline incremental vacuum migration".into(),
        ));
    }
    db.execute_unprepared("PRAGMA auto_vacuum = INCREMENTAL; VACUUM;")
        .await?;
    Ok(())
}

const MICROS_PER_DAY: i64 = 86_400_000_000;

#[derive(Clone, Debug, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct ErrorRetentionSettings {
    pub event_days: u32,
    pub usage_days: u32,
    pub batch: usize,
    /// Batches per organization per sweep, so one organization cannot hold
    /// the sweep.
    pub max_batches: usize,
    pub delete_concurrency: usize,
    /// Free pages returned to the file system per organization per sweep.
    pub vacuum_pages: u32,
    pub interval_secs: u64,
}

impl Default for ErrorRetentionSettings {
    fn default() -> Self {
        Self {
            event_days: 90,
            usage_days: 400,
            batch: 500,
            max_batches: 20,
            delete_concurrency: 8,
            vacuum_pages: 1_024,
            interval_secs: 3_600,
        }
    }
}

impl ErrorRetentionSettings {
    pub fn validate(&self) -> bool {
        (1..=3_650).contains(&self.event_days)
            && (62..=3_650).contains(&self.usage_days)
            && (1..=1_000).contains(&self.batch)
            && (1..=100).contains(&self.max_batches)
            && (1..=16).contains(&self.delete_concurrency)
            && self.vacuum_pages <= 4_096
            && (1..=86_400).contains(&self.interval_secs)
    }
}

#[derive(Debug, Default, PartialEq, Eq, Serialize)]
pub struct SweepReport {
    pub events_deleted: u64,
    pub payload_failures: u64,
    pub issues_deleted: u64,
    pub usage_rows_deleted: u64,
    pub pages_reclaimed: u64,
    /// False when expired rows remain for the next sweep.
    pub complete: bool,
}

pub struct ErrorRetention {
    control: DatabaseConnection,
    tenants: TenantPools,
    store: ObjectStore,
    settings: ErrorRetentionSettings,
}

impl ErrorRetention {
    pub fn new(
        control: DatabaseConnection,
        tenants: TenantPools,
        store: ObjectStore,
        settings: ErrorRetentionSettings,
    ) -> Self {
        Self {
            control,
            tenants,
            store,
            settings,
        }
    }

    /// Events received before this time are expired. Reads can filter on it
    /// before the sweep removes them.
    pub fn event_cutoff(&self, now_us: i64) -> i64 {
        now_us - i64::from(self.settings.event_days) * MICROS_PER_DAY
    }

    async fn tenant(&self, org: &OrgId) -> ApiResult<TenantHandle> {
        crate::organization_lifecycle::active_tenant(&self.control, &self.tenants, org).await
    }

    pub async fn sweep_org(&self, org: &OrgId, now_us: i64) -> ApiResult<SweepReport> {
        let cutoff = self.event_cutoff(now_us);
        let batch = self.settings.batch.max(1);
        let mut report = SweepReport::default();
        let mut events_done = false;
        for _ in 0..self.settings.max_batches.max(1) {
            let (deleted, failures, selected) = self.expire_events(org, cutoff, batch).await?;
            report.events_deleted += deleted;
            report.payload_failures += failures;
            if failures > 0 {
                break;
            }
            if selected < batch {
                events_done = true;
                break;
            }
        }
        let mut issues_done = false;
        for _ in 0..self.settings.max_batches.max(1) {
            let deleted = self.expire_issues(org, cutoff, batch).await?;
            report.issues_deleted += deleted;
            if (deleted as usize) < batch {
                issues_done = true;
                break;
            }
        }
        let usage_cutoff = utc_day(now_us - i64::from(self.settings.usage_days) * MICROS_PER_DAY);
        let handle = self.tenant(org).await?;
        report.usage_rows_deleted = handle
            .execute_raw(sql(
                "DELETE FROM usage_daily WHERE rowid IN
                    (SELECT rowid FROM usage_daily WHERE day < ? ORDER BY day LIMIT ?)",
                vec![usage_cutoff.clone().into(), (batch as i64).into()],
            ))
            .await?
            .rows_affected();
        let outcome_rows_deleted = handle
            .execute_raw(sql(
                "DELETE FROM ingest_outcomes_daily WHERE rowid IN
                    (SELECT rowid FROM ingest_outcomes_daily WHERE day < ? ORDER BY day LIMIT ?)",
                vec![usage_cutoff.into(), (batch as i64).into()],
            ))
            .await?
            .rows_affected();
        report.pages_reclaimed = reclaim(&handle, self.settings.vacuum_pages).await?;
        drop(handle);
        report.complete = events_done
            && issues_done
            && (report.usage_rows_deleted as usize) < batch
            && (outcome_rows_deleted as usize) < batch;
        Ok(report)
    }

    async fn expire_events(
        &self,
        org: &OrgId,
        cutoff: i64,
        batch: usize,
    ) -> ApiResult<(u64, u64, usize)> {
        let rows = {
            let handle = self.tenant(org).await?;
            handle
                .query_all_raw(sql(
                    "SELECT id, payload_key FROM events WHERE received_at < ?
                     ORDER BY received_at LIMIT ?",
                    vec![cutoff.into(), (batch as i64).into()],
                ))
                .await?
        };
        let expired: Vec<(i64, String)> = rows
            .iter()
            .map(|row| Ok((row.try_get("", "id")?, row.try_get("", "payload_key")?)))
            .collect::<Result<_, sea_orm::DbErr>>()?;
        let selected = expired.len();
        if selected == 0 {
            return Ok((0, 0, 0));
        }
        let prefix = format!("errors/v1/{org}/");
        let results: Vec<Option<i64>> = stream::iter(expired)
            .map(|(id, key)| {
                let owned = key.starts_with(&prefix);
                async move {
                    if !owned {
                        tracing::error!(org = %org, "event payload key is outside the organization prefix");
                        return None;
                    }
                    match self.store.delete(&key).await {
                        Ok(()) => Some(id),
                        Err(error) => {
                            tracing::warn!(org = %org, %error, "expired event payload was not deleted");
                            None
                        }
                    }
                }
            })
            .buffer_unordered(self.settings.delete_concurrency.max(1))
            .collect()
            .await;
        let deleted: Vec<i64> = results.iter().flatten().copied().collect();
        let failures = (selected - deleted.len()) as u64;
        if deleted.is_empty() {
            return Ok((0, failures, selected));
        }
        let placeholders = vec!["?"; deleted.len()].join(",");
        let mut values: Vec<sea_orm::Value> = deleted.iter().map(|id| (*id).into()).collect();
        values.push(cutoff.into());
        let handle = self.tenant(org).await?;
        let removed = handle
            .execute_raw(sql(
                &format!("DELETE FROM events WHERE id IN ({placeholders}) AND received_at < ?"),
                values,
            ))
            .await?
            .rows_affected();
        Ok((removed, failures, selected))
    }

    async fn expire_issues(&self, org: &OrgId, cutoff: i64, batch: usize) -> ApiResult<u64> {
        let handle = self.tenant(org).await?;
        Ok(handle
            .execute_raw(sql(
                "DELETE FROM issues WHERE id IN (
                    SELECT i.id FROM issues i WHERE i.last_seen < ?
                      AND NOT EXISTS (SELECT 1 FROM events e WHERE e.issue_id = i.id)
                    ORDER BY i.last_seen LIMIT ?)",
                vec![cutoff.into(), (batch as i64).into()],
            ))
            .await?
            .rows_affected())
    }

    /// Sweeps every organization, then waits `interval_secs`. Returns when
    /// `cancel` fires.
    pub async fn run(&self, cancel: CancellationToken, gate: Arc<crate::runtime::Gate>) {
        let period = Duration::from_secs(self.settings.interval_secs.max(1));
        let mut ticker = tokio::time::interval(period);
        loop {
            tokio::select! {
                () = cancel.cancelled() => return,
                _ = ticker.tick() => {}
            }
            let mut after = None;
            loop {
                let orgs = match self.organizations(after.as_ref()).await {
                    Ok(orgs) => orgs,
                    Err(error) => {
                        tracing::error!(%error, "error retention could not list organizations");
                        break;
                    }
                };
                if orgs.is_empty() {
                    break;
                }
                after = orgs.last().cloned();
                for org in orgs {
                    if cancel.is_cancelled() {
                        return;
                    }
                    let Some(_guard) = gate.enter() else {
                        break;
                    };
                    let swept = tokio::select! {
                        () = cancel.cancelled() => return,
                        swept = self.sweep_org(&org, crate::domain::now_micros()) => swept,
                    };
                    match swept {
                        Ok(report) if !report.complete || report.payload_failures > 0 => {
                            tracing::info!(org = %org, ?report, "error retention left work for the next sweep");
                        }
                        Ok(_) => {}
                        Err(error) => {
                            tracing::warn!(org = %org, %error, "error retention sweep failed")
                        }
                    }
                }
            }
        }
    }

    async fn organizations(&self, after: Option<&OrgId>) -> ApiResult<Vec<OrgId>> {
        let rows = self
            .control
            .query_all_raw(sql(
                "SELECT id FROM organizations WHERE id > ? AND lifecycle = 'active' ORDER BY id LIMIT 100",
                vec![after.map_or("", OrgId::as_str).into()],
            ))
            .await?;
        rows.iter()
            .map(|row| {
                let id: String = row.try_get("", "id")?;
                id.parse()
                    .map_err(|()| ApiError::Internal("stored organization id".into()))
            })
            .collect()
    }
}

async fn reclaim(handle: &TenantHandle, pages: u32) -> ApiResult<u64> {
    let mode = pragma(handle, "PRAGMA auto_vacuum").await?;
    if mode != 2 || pages == 0 {
        return Ok(0);
    }
    let before = pragma(handle, "PRAGMA freelist_count").await?;
    handle
        .execute_unprepared(&format!("PRAGMA incremental_vacuum({pages})"))
        .await?;
    let after = pragma(handle, "PRAGMA freelist_count").await?;
    Ok(before.saturating_sub(after) as u64)
}

async fn pragma(handle: &TenantHandle, statement: &str) -> ApiResult<i64> {
    let row = handle
        .query_one_raw(sql(statement, vec![]))
        .await?
        .ok_or(ApiError::Internal("pragma returned no row".into()))?;
    Ok(row.try_get_by_index::<i64>(0)?)
}
