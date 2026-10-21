//! Per-organization admission against the monthly plan limits and the daily
//! technical limits. Committed usage lives in the tenant `usage_daily` table,
//! written in the same transaction as the accepted data; a month is the sum of
//! its days. This ledger caches the current day and month and adds in-memory
//! holds for work still in flight. Unknown committed usage is never treated as
//! zero: the first admission for an organization prepares its log storage
//! (sealing batches of an earlier process, or finishing a marked restore
//! reconciliation) and then loads the committed counts.

use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};

use sea_orm::ConnectionTrait;

use crate::{
    domain::{now_micros, utc_day, OrgId},
    error::ApiError,
    logs::storage::{restore_flag, RestoreFlag},
    runtime::{sql, Runtime},
    settings::QuotaSettings,
};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Usage {
    pub errors: u64,
    pub logs: u64,
    pub log_bytes: u64,
}

impl Usage {
    fn add(&mut self, other: Usage) {
        self.errors += other.errors;
        self.logs += other.logs;
        self.log_bytes += other.log_bytes;
    }

    fn sub(&mut self, other: Usage) {
        self.errors = self.errors.saturating_sub(other.errors);
        self.logs = self.logs.saturating_sub(other.logs);
        self.log_bytes = self.log_bytes.saturating_sub(other.log_bytes);
    }
}

pub struct Quotas {
    inner: Arc<Inner>,
}

struct Inner {
    entries: Mutex<HashMap<OrgId, Arc<QuotaEntry>>>,
    capacity: usize,
}

#[derive(Default)]
struct QuotaEntry {
    state: Mutex<EntryState>,
    loading: Arc<tokio::sync::Mutex<()>>,
    readiness: tokio::sync::Mutex<()>,
}

#[derive(Default)]
struct EntryState {
    generation: u64,
    ready_generation: Option<u64>,
    ledger: Option<Ledger>,
}

struct Ledger {
    day: String,
    generation: u64,
    committed: Usage,
    month_committed: Usage,
    held: Usage,
}

pub struct Hold {
    entry: Arc<QuotaEntry>,
    day: String,
    usage: Usage,
}

impl Hold {
    pub(crate) fn split_categories(mut self) -> (Self, Self) {
        let errors = Self {
            entry: self.entry.clone(),
            day: self.day.clone(),
            usage: Usage {
                errors: self.usage.errors,
                ..Usage::default()
            },
        };
        self.usage.errors = 0;
        (errors, self)
    }

    pub fn settle(&mut self, usage: Usage, committed: bool) {
        let mut state = self.entry.state.lock().expect("quota lock");
        assert!(
            usage.errors <= self.usage.errors
                && usage.logs <= self.usage.logs
                && usage.log_bytes <= self.usage.log_bytes,
            "settled usage exceeds its reservation"
        );
        if let Some(ledger) = state.ledger.as_mut() {
            if ledger.day == self.day {
                ledger.held.sub(usage);
                if committed {
                    ledger.committed.add(usage);
                    ledger.month_committed.add(usage);
                }
            }
        }
        self.usage.sub(usage);
    }

    pub fn settle_all(&mut self) {
        self.settle(self.usage, true);
    }
}

impl Drop for Hold {
    fn drop(&mut self) {
        let mut state = self.entry.state.lock().expect("quota lock");
        if let Some(ledger) = state.ledger.as_mut() {
            if ledger.day == self.day {
                ledger.held.sub(self.usage);
            }
        }
    }
}

struct RepairTicket {
    entry: Arc<QuotaEntry>,
    generation: u64,
}

pub struct UsageWrite {
    _entry: Arc<QuotaEntry>,
    _guard: tokio::sync::OwnedMutexGuard<()>,
}

#[derive(Debug)]
pub enum QuotaError {
    /// The daily technical limit for this category.
    Exceeded(&'static str),
    /// The monthly plan limit for this category.
    MonthlyExceeded(&'static str),
    Unavailable(ApiError),
}

impl Default for Quotas {
    fn default() -> Self {
        Self::new(4_096)
    }
}

impl Quotas {
    pub fn new(capacity: usize) -> Self {
        Self {
            inner: Arc::new(Inner {
                entries: Mutex::default(),
                capacity: capacity.max(1),
            }),
        }
    }

    fn entry(&self, org: &OrgId) -> Result<Arc<QuotaEntry>, ApiError> {
        let mut entries = self.inner.entries.lock().expect("quota lock");
        if let Some(entry) = entries.get(org) {
            return Ok(entry.clone());
        }
        if entries.len() >= self.inner.capacity {
            let idle = entries
                .iter()
                .find(|(_, entry)| Arc::strong_count(entry) == 1)
                .map(|(org, _)| org.clone())
                .ok_or(ApiError::Unavailable("org_cache_overloaded"))?;
            entries.remove(&idle);
        }
        let entry = Arc::new(QuotaEntry::default());
        entries.insert(org.clone(), entry.clone());
        Ok(entry)
    }

    pub fn cached_orgs(&self) -> usize {
        self.inner.entries.lock().expect("quota lock").len()
    }

    pub(crate) fn dirty(&self, org: &OrgId) {
        if let Some(entry) = self.inner.entries.lock().expect("quota lock").get(org) {
            let mut state = entry.state.lock().expect("quota lock");
            state.generation = state.generation.wrapping_add(1);
            state.ready_generation = None;
        }
    }

    pub fn is_ready(&self, org: &OrgId) -> bool {
        self.inner
            .entries
            .lock()
            .expect("quota lock")
            .get(org)
            .is_some_and(|entry| {
                let state = entry.state.lock().expect("quota lock");
                state.ready_generation == Some(state.generation)
            })
    }

    pub async fn reserve(
        &self,
        rt: &Runtime,
        org: &OrgId,
        want: Usage,
    ) -> Result<Hold, QuotaError> {
        self.reserve_at(rt, org, want, now_micros()).await
    }

    pub async fn reserve_at(
        &self,
        rt: &Runtime,
        org: &OrgId,
        want: Usage,
        received: i64,
    ) -> Result<Hold, QuotaError> {
        let entry = self.entry(org).map_err(QuotaError::Unavailable)?;
        self.ensure_entry(rt, org, &entry)
            .await
            .map_err(QuotaError::Unavailable)?;
        let day = utc_day(received);
        let _loading = entry.loading.lock().await;
        if let Some(result) = reserve_cached(&entry, &day, want, &rt.settings.quotas) {
            return result;
        }
        let generation = {
            let state = entry.state.lock().expect("quota lock");
            if state
                .ledger
                .as_ref()
                .is_some_and(|ledger| ledger.held != Usage::default())
            {
                return Err(QuotaError::Unavailable(ApiError::Unavailable(
                    "reconciling",
                )));
            }
            state.generation
        };
        let (committed, month_committed) = load_usage(rt, org, &day)
            .await
            .map_err(QuotaError::Unavailable)?;
        let mut state = entry.state.lock().expect("quota lock");
        if state.generation != generation || state.ready_generation != Some(generation) {
            return Err(QuotaError::Unavailable(ApiError::Unavailable(
                "reconciling",
            )));
        }
        let held = state
            .ledger
            .as_ref()
            .filter(|ledger| ledger.day == day)
            .map(|ledger| ledger.held)
            .unwrap_or_default();
        state.ledger = Some(Ledger {
            day: day.clone(),
            generation,
            committed,
            month_committed,
            held,
        });
        drop(state);
        reserve_cached(&entry, &day, want, &rt.settings.quotas).unwrap_or_else(|| {
            Err(QuotaError::Unavailable(ApiError::Unavailable(
                "reconciling",
            )))
        })
    }

    pub async fn write(&self, org: &OrgId) -> Result<UsageWrite, ApiError> {
        let entry = self.entry(org)?;
        let guard = entry.loading.clone().lock_owned().await;
        Ok(UsageWrite {
            _entry: entry,
            _guard: guard,
        })
    }

    pub fn committed(&self, org: &OrgId, day: &str, usage: Usage) {
        let entries = self.inner.entries.lock().expect("quota lock");
        if let Some(entry) = entries.get(org) {
            let mut state = entry.state.lock().expect("quota lock");
            if let Some(ledger) = state.ledger.as_mut() {
                if ledger.day == day {
                    ledger.committed.add(usage);
                    ledger.month_committed.add(usage);
                } else if ledger.day[..6] == day[..6] {
                    ledger.month_committed.add(usage);
                }
            }
        }
    }

    fn reconciled(&self, ticket: RepairTicket) -> bool {
        let mut state = ticket.entry.state.lock().expect("quota lock");
        if state.generation != ticket.generation {
            return false;
        }
        state.ready_generation = Some(ticket.generation);
        true
    }

    pub async fn ensure_ready(&self, rt: &Runtime, org: &OrgId) -> Result<(), ApiError> {
        let entry = self.entry(org)?;
        self.ensure_entry(rt, org, &entry).await
    }

    async fn ensure_entry(
        &self,
        rt: &Runtime,
        org: &OrgId,
        entry: &Arc<QuotaEntry>,
    ) -> Result<(), ApiError> {
        {
            let state = entry.state.lock().expect("quota lock");
            if state.ready_generation == Some(state.generation) {
                return Ok(());
            }
        }
        let _readiness = match tokio::time::timeout(
            std::time::Duration::from_millis(rt.settings.logs.reconcile_timeout_ms),
            entry.readiness.lock(),
        )
        .await
        {
            Ok(guard) => guard,
            Err(_) => {
                let handle = rt.tenant(org).await?;
                return Err(ApiError::Unavailable(
                    match restore_flag(&*handle).await? {
                        RestoreFlag::Required => "log_restore_pending",
                        RestoreFlag::Conflict(_) => "log_restore_conflict",
                        RestoreFlag::Clear => "reconciling",
                    },
                ));
            }
        };
        {
            let state = entry.state.lock().expect("quota lock");
            if state.ready_generation == Some(state.generation) {
                return Ok(());
            }
        }
        let ticket = RepairTicket {
            entry: entry.clone(),
            generation: entry.state.lock().expect("quota lock").generation,
        };
        crate::logs::storage::prepare(rt, org).await?;
        if !self.reconciled(ticket) {
            return Err(ApiError::Unavailable("reconciling"));
        }
        Ok(())
    }
}

fn reserve_cached(
    entry: &Arc<QuotaEntry>,
    day: &str,
    want: Usage,
    limits: &QuotaSettings,
) -> Option<Result<Hold, QuotaError>> {
    let mut state = entry.state.lock().expect("quota lock");
    if state.ready_generation != Some(state.generation) {
        return Some(Err(QuotaError::Unavailable(ApiError::Unavailable(
            "reconciling",
        ))));
    }
    let generation = state.generation;
    let ledger = state
        .ledger
        .as_mut()
        .filter(|ledger| ledger.day == day && ledger.generation == generation)?;
    let mut month = ledger.month_committed;
    month.add(ledger.held);
    month.add(want);
    if let Some(category) = monthly_exceeded(&month, &want) {
        return Some(Err(QuotaError::MonthlyExceeded(category)));
    }
    let mut total = ledger.committed;
    total.add(ledger.held);
    total.add(want);
    if let Some(category) = exceeded(&total, &want, limits) {
        return Some(Err(QuotaError::Exceeded(category)));
    }
    ledger.held.add(want);
    Some(Ok(Hold {
        entry: entry.clone(),
        day: day.to_owned(),
        usage: want,
    }))
}

fn exceeded(total: &Usage, want: &Usage, limits: &QuotaSettings) -> Option<&'static str> {
    if want.errors > 0 && total.errors > limits.daily_errors {
        return Some("error");
    }
    if want.logs > 0 && (total.logs > limits.daily_logs || total.log_bytes > limits.daily_log_bytes)
    {
        return Some("log_item");
    }
    None
}

/// Plan limits apply per UTC month. Only the categories a plan counts are
/// checked, so a log-only request never fails on the error allowance.
pub(crate) fn monthly_exceeded(total: &Usage, want: &Usage) -> Option<&'static str> {
    if want.errors > 0 && total.errors > crate::billing::MONTHLY_ERRORS {
        return Some("error");
    }
    if want.logs > 0 && total.log_bytes > crate::billing::MONTHLY_LOG_BYTES {
        return Some("log_item");
    }
    None
}

async fn load_usage(rt: &Runtime, org: &OrgId, day: &str) -> Result<(Usage, Usage), ApiError> {
    let handle = rt.tenant(org).await?;
    let today = usage_between(&*handle, day, day).await?;
    let month = month_usage(&*handle, day).await?;
    drop(handle);
    Ok((today, month))
}

/// Committed usage of the UTC month containing `day`. `log_adopted` rows
/// repeat adopted `log` usage for metrics and are not summed again.
pub async fn month_usage<C: ConnectionTrait>(conn: &C, day: &str) -> Result<Usage, sea_orm::DbErr> {
    let (first, last) = crate::billing::month_days(day);
    usage_between(conn, &first, &last).await
}

async fn usage_between<C: ConnectionTrait>(
    conn: &C,
    first: &str,
    last: &str,
) -> Result<Usage, sea_orm::DbErr> {
    let rows = conn
        .query_all_raw(sql(
            "SELECT category, SUM(accepted) AS accepted, SUM(bytes) AS bytes FROM usage_daily
             WHERE day BETWEEN ? AND ? AND category IN ('error', 'log') GROUP BY category",
            vec![first.into(), last.into()],
        ))
        .await?;
    let mut usage = Usage::default();
    for row in rows {
        let category: String = row.try_get("", "category")?;
        let accepted = u64::try_from(row.try_get::<i64>("", "accepted")?).unwrap_or(0);
        let bytes = u64::try_from(row.try_get::<i64>("", "bytes")?).unwrap_or(0);
        match category.as_str() {
            "error" => usage.errors = accepted,
            "log" => {
                usage.logs = accepted;
                usage.log_bytes = bytes;
            }
            _ => {}
        }
    }
    Ok(usage)
}

/// Adds accepted work to the tenant usage table inside the caller's transaction.
pub async fn add_usage<C: ConnectionTrait>(
    conn: &C,
    day: &str,
    category: &str,
    accepted: u64,
    bytes: u64,
) -> Result<(), sea_orm::DbErr> {
    conn.execute_raw(sql(
        "INSERT INTO usage_daily (day, category, accepted, bytes) VALUES (?, ?, ?, ?)
         ON CONFLICT (day, category) DO UPDATE SET accepted = accepted + excluded.accepted, bytes = bytes + excluded.bytes",
        vec![day.into(), category.into(), (accepted as i64).into(), (bytes as i64).into()],
    ))
    .await?;
    Ok(())
}
