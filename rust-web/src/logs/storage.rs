//! Durable log batches. SQLite is the acknowledgement point and R2 is the
//! archive.
//!
//! Each organization database has at most one `open` batch in `log_objects`.
//! An accepted request is encrypted, appended and charged in one FULL
//! synchronous transaction, then acknowledged. Age, entry count, size or a
//! UTC day change turns the batch `sealed`; the archiver writes it once to R2
//! with conditional creation and marks it `archived` after verifying the
//! stored content. Archiving never charges usage again and never republishes
//! entries. Every non-archived row is rebuilt into the in-memory work registry
//! from SQLite, so a restart loses no work.

use std::{
    collections::HashMap,
    sync::{atomic::Ordering, Arc, Mutex},
    time::Duration,
};

use bytes::Bytes;
use sea_orm::{ConnectionTrait, SqliteTransactionMode, TransactionOptions, TransactionTrait};
use serde::Serialize;
use tokio::{sync::Semaphore, time::Instant};
use tokio_util::{sync::CancellationToken, task::TaskTracker};

use crate::{
    billing::alerts::Metric,
    domain::{now_micros, utc_day, OrgId},
    error::ApiError,
    logs::{
        live::Published,
        object::{
            decode_batch, encode_batch, entry_lines, BatchHeader, BatchIdentity, LogEntry,
            Partition, StoredBatch, Summary, BLOOM_BYTES,
        },
        pending::{Slot, OVERHEAD},
        read::{Cursor, CursorEpoch},
        record::LogRecord,
    },
    quota::{add_usage, month_usage, monthly_exceeded, Hold, Usage},
    runtime::{sql, Runtime},
    settings::{LifecycleSettings, LogSettings},
    store::Created,
};

/// Why a log append was refused. Every refusal leaves usage unchanged.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LogFailure {
    QuotaExceeded,
    MonthlyQuotaExceeded,
    BacklogFull,
    RestorePending,
    RestoreConflict,
    Unavailable,
}

impl LogFailure {
    pub fn code(self) -> &'static str {
        match self {
            Self::QuotaExceeded | Self::MonthlyQuotaExceeded => "rate_limited",
            Self::BacklogFull => "log_backlog_full",
            Self::RestorePending => "log_restore_pending",
            Self::RestoreConflict => "log_restore_conflict",
            Self::Unavailable => "ingest_unavailable",
        }
    }
}

impl From<ApiError> for LogFailure {
    fn from(error: ApiError) -> Self {
        tracing::warn!(%error, "log append failed");
        Self::Unavailable
    }
}

impl From<sea_orm::DbErr> for LogFailure {
    fn from(error: sea_orm::DbErr) -> Self {
        ApiError::from(error).into()
    }
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct ArchiveFailure {
    pub reason: &'static str,
    pub at: i64,
    pub attempts: u32,
}

#[derive(Default)]
struct OrgWork {
    open: Option<(i64, i64)>,
    sealed: bool,
    backlog: u64,
    reserved: u64,
    busy: bool,
    retry_at: Option<Instant>,
    failure: Option<ArchiveFailure>,
}

impl OrgWork {
    fn idle(&self) -> bool {
        self.open.is_none()
            && !self.sealed
            && self.backlog == 0
            && self.reserved == 0
            && !self.busy
            && self.failure.is_none()
    }
}

#[derive(Default)]
struct Registry {
    orgs: HashMap<OrgId, OrgWork>,
    backlog: u64,
    closed: bool,
}

/// Process-wide archive scheduling and backlog accounting. SQLite holds the
/// authoritative state; this registry only points the archiver at work.
pub struct LogStorage {
    registry: Mutex<Registry>,
    archives: Arc<Semaphore>,
    tasks: TaskTracker,
    cancel: CancellationToken,
    max_orgs: usize,
}

impl LogStorage {
    pub fn new(settings: &LogSettings) -> Self {
        Self {
            registry: Mutex::default(),
            archives: Arc::new(Semaphore::new(settings.upload_concurrency.max(1))),
            tasks: TaskTracker::new(),
            cancel: CancellationToken::new(),
            max_orgs: settings.max_pending_orgs.max(1),
        }
    }

    fn failure(&self, org: &OrgId) -> Option<ArchiveFailure> {
        self.registry
            .lock()
            .expect("log registry")
            .orgs
            .get(org)
            .and_then(|work| work.failure.clone())
    }

    fn knows_open(&self, org: &OrgId) -> bool {
        self.registry
            .lock()
            .expect("log registry")
            .orgs
            .get(org)
            .is_some_and(|work| work.open.is_some())
    }

    fn reserve(&self, org: &OrgId, bytes: u64, limit: u64) -> Result<Reservation<'_>, LogFailure> {
        let mut registry = self.registry.lock().expect("log registry");
        if !registry.orgs.contains_key(org) && registry.orgs.len() >= self.max_orgs {
            return Err(LogFailure::BacklogFull);
        }
        if registry.backlog.saturating_add(bytes) > limit {
            return Err(LogFailure::BacklogFull);
        }
        registry.backlog += bytes;
        registry.orgs.entry(org.clone()).or_default().reserved += bytes;
        Ok(Reservation {
            storage: self,
            org: org.clone(),
            bytes,
        })
    }

    /// Replaces the organization's entry with the committed SQLite state.
    fn refresh(&self, org: &OrgId, state: Unarchived) {
        let mut registry = self.registry.lock().expect("log registry");
        let Registry { orgs, backlog, .. } = &mut *registry;
        let work = orgs.entry(org.clone()).or_default();
        *backlog = backlog.saturating_sub(work.backlog) + state.backlog;
        work.backlog = state.backlog;
        work.open = state.open;
        work.sealed = state.sealed;
        if work.idle() {
            orgs.remove(org);
        }
    }

    fn finish_job(&self, org: &OrgId, failure: Option<&'static str>) {
        let mut registry = self.registry.lock().expect("log registry");
        let Some(work) = registry.orgs.get_mut(org) else {
            return;
        };
        work.busy = false;
        match failure {
            None => {
                work.failure = None;
                work.retry_at = None;
            }
            Some(reason) => {
                let attempts = work.failure.as_ref().map_or(0, |f| f.attempts) + 1;
                work.failure = Some(ArchiveFailure {
                    reason,
                    at: now_micros(),
                    attempts,
                });
                let backoff = Duration::from_secs(u64::from(attempts.min(5)) * 2);
                work.retry_at = Some(Instant::now() + backoff);
            }
        }
        if work.idle() {
            registry.orgs.remove(org);
        }
    }

    fn forget(&self, org: &OrgId) {
        let mut registry = self.registry.lock().expect("log registry");
        if let Some(work) = registry.orgs.remove(org) {
            registry.backlog = registry
                .backlog
                .saturating_sub(work.backlog + work.reserved);
        }
    }
}

struct Reservation<'a> {
    storage: &'a LogStorage,
    org: OrgId,
    bytes: u64,
}

impl Reservation<'_> {
    fn commit(mut self, state: Unarchived) {
        {
            let mut registry = self.storage.registry.lock().expect("log registry");
            registry.backlog -= self.bytes;
            if let Some(work) = registry.orgs.get_mut(&self.org) {
                work.reserved -= self.bytes;
            }
        }
        self.bytes = 0;
        self.storage.refresh(&self.org, state);
    }
}

impl Drop for Reservation<'_> {
    fn drop(&mut self) {
        if self.bytes == 0 {
            return;
        }
        let mut registry = self.storage.registry.lock().expect("log registry");
        registry.backlog -= self.bytes;
        if let Some(work) = registry.orgs.get_mut(&self.org) {
            work.reserved -= self.bytes;
            if work.idle() {
                registry.orgs.remove(&self.org);
            }
        }
    }
}

/// Non-archived rows of one organization.
#[derive(Default)]
struct Unarchived {
    open: Option<(i64, i64)>,
    sealed: bool,
    backlog: u64,
}

async fn unarchived<C: ConnectionTrait>(conn: &C) -> Result<Unarchived, sea_orm::DbErr> {
    let rows = conn
        .query_all_raw(sql(
            "SELECT id, state, opened_at, pending_bytes FROM log_objects WHERE state != 'archived'",
            vec![],
        ))
        .await?;
    let mut state = Unarchived::default();
    for row in rows {
        let status: String = row.try_get("", "state")?;
        state.backlog += row.try_get::<i64>("", "pending_bytes")? as u64;
        if status == "open" {
            state.open = Some((
                row.try_get("", "id")?,
                row.try_get::<Option<i64>>("", "opened_at")?
                    .unwrap_or_default(),
            ));
        } else {
            state.sealed = true;
        }
    }
    Ok(state)
}

pub(crate) fn immediate() -> TransactionOptions {
    TransactionOptions {
        sqlite_transaction_mode: Some(SqliteTransactionMode::Immediate),
        ..TransactionOptions::default()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum RestoreFlag {
    Clear,
    Required,
    Conflict(String),
}

pub(crate) async fn restore_flag<C: ConnectionTrait>(
    conn: &C,
) -> Result<RestoreFlag, sea_orm::DbErr> {
    let row = conn
        .query_one_raw(sql(
            "SELECT logs_reconcile_required, conflict FROM restore_state WHERE id = 1",
            vec![],
        ))
        .await?;
    Ok(match row {
        None => RestoreFlag::Clear,
        Some(row) => match (
            row.try_get::<i64>("", "logs_reconcile_required")?,
            row.try_get::<Option<String>>("", "conflict")?,
        ) {
            (0, _) => RestoreFlag::Clear,
            (_, Some(conflict)) => RestoreFlag::Conflict(conflict),
            (_, None) => RestoreFlag::Required,
        },
    })
}

/// The cursor epoch of this database. A missing row is the initial epoch.
pub(crate) async fn cursor_epoch<C: ConnectionTrait>(
    conn: &C,
) -> Result<CursorEpoch, sea_orm::DbErr> {
    Ok(conn
        .query_one_raw(sql(
            "SELECT cursor_epoch FROM restore_state WHERE id = 1",
            vec![],
        ))
        .await?
        .map(|row| row.try_get::<i64>("", "cursor_epoch"))
        .transpose()?
        .map_or(CursorEpoch::INITIAL, CursorEpoch::from_stored))
}

struct OpenRow {
    id: i64,
    entries: u32,
    raw_bytes: u64,
    pending_bytes: u64,
    usage_day: String,
    opened_at: i64,
    summary: Summary,
}

async fn open_row<C: ConnectionTrait>(conn: &C) -> Result<Option<OpenRow>, sea_orm::DbErr> {
    let Some(row) = conn
        .query_one_raw(sql(
            "SELECT id, entry_count, raw_bytes, pending_bytes, usage_day, opened_at, min_ts, max_ts,
                received_at, level_mask, trace_bloom FROM log_objects WHERE state = 'open'",
            vec![],
        ))
        .await?
    else {
        return Ok(None);
    };
    Ok(Some(OpenRow {
        id: row.try_get("", "id")?,
        entries: row.try_get::<i64>("", "entry_count")? as u32,
        raw_bytes: row.try_get::<i64>("", "raw_bytes")? as u64,
        pending_bytes: row.try_get::<i64>("", "pending_bytes")? as u64,
        usage_day: row
            .try_get::<Option<String>>("", "usage_day")?
            .unwrap_or_default(),
        opened_at: row
            .try_get::<Option<i64>>("", "opened_at")?
            .unwrap_or_default(),
        summary: Summary {
            min_ts: row.try_get("", "min_ts")?,
            max_ts: row.try_get("", "max_ts")?,
            received_at: row.try_get("", "received_at")?,
            level_mask: row.try_get::<i32>("", "level_mask")? as u8,
            raw_bytes: row.try_get::<i64>("", "raw_bytes")? as u64,
            bloom: row.try_get("", "trace_bloom")?,
        },
    }))
}

fn merge(mut left: Summary, right: &Summary) -> Summary {
    left.min_ts = left.min_ts.min(right.min_ts);
    left.max_ts = left.max_ts.max(right.max_ts);
    left.received_at = left.received_at.max(right.received_at);
    left.level_mask |= right.level_mask;
    left.raw_bytes = left.raw_bytes.saturating_add(right.raw_bytes);
    left.bloom.resize(BLOOM_BYTES, 0);
    for (byte, other) in left.bloom.iter_mut().zip(&right.bloom) {
        *byte |= other;
    }
    left
}

async fn seal_row<C: ConnectionTrait>(conn: &C, id: i64) -> Result<(), sea_orm::DbErr> {
    conn.execute_raw(sql(
        "UPDATE log_objects SET state = 'sealed' WHERE id = ? AND state = 'open'",
        vec![id.into()],
    ))
    .await?;
    Ok(())
}

/// Inserts contiguous same-partition runs for `entries` starting at `first`,
/// extending the object's last run when the partition continues.
pub(crate) async fn insert_runs<C: ConnectionTrait>(
    conn: &C,
    object_id: i64,
    first: u32,
    entries: &[LogEntry],
) -> Result<(), sea_orm::DbErr> {
    let mut start = 0usize;
    while start < entries.len() {
        let head = &entries[start];
        let mut end = start + 1;
        while end < entries.len()
            && entries[end].project == head.project
            && entries[end].source == head.source
            && entries[end].environment == head.environment
        {
            end += 1;
        }
        let run = &entries[start..end];
        let summary = Summary::of(run.iter().map(|e| (&e.record, e.billable_bytes)));
        let first_entry = first + start as u32;
        let last_entry = first + end as u32 - 1;
        let extended = if start == 0 && first > 0 {
            conn.execute_raw(sql(
                "UPDATE log_entry_runs SET last_entry = ?, min_ts = MIN(min_ts, ?), max_ts = MAX(max_ts, ?),
                    level_mask = level_mask | ?
                 WHERE object_id = ? AND last_entry = ? AND project_id = ? AND source_id = ? AND environment = ?",
                vec![
                    i64::from(last_entry).into(),
                    summary.min_ts.into(),
                    summary.max_ts.into(),
                    i32::from(summary.level_mask).into(),
                    object_id.into(),
                    i64::from(first - 1).into(),
                    head.project.0.into(),
                    head.source.0.into(),
                    head.environment.clone().into(),
                ],
            ))
            .await?
            .rows_affected()
                == 1
        } else {
            false
        };
        if !extended {
            conn.execute_raw(sql(
                "INSERT INTO log_entry_runs (object_id, first_entry, last_entry, project_id, source_id,
                    environment, min_ts, max_ts, level_mask) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                vec![
                    object_id.into(),
                    i64::from(first_entry).into(),
                    i64::from(last_entry).into(),
                    head.project.0.into(),
                    head.source.0.into(),
                    head.environment.clone().into(),
                    summary.min_ts.into(),
                    summary.max_ts.into(),
                    i32::from(summary.level_mask).into(),
                ],
            ))
            .await?;
        }
        start = end;
    }
    Ok(())
}

/// Appends one accepted request and returns the cursor of its last entry
/// after the transaction commits.
pub async fn append(
    rt: &Arc<Runtime>,
    partition: &Partition,
    records: Vec<LogRecord>,
    mut hold: Hold,
) -> Result<Cursor, LogFailure> {
    let org = &partition.org;
    let settings = &rt.settings.logs;
    let received = records
        .iter()
        .map(|r| r.rt)
        .max()
        .unwrap_or_else(now_micros);
    let day = utc_day(received);
    let billable: Vec<u64> = records.iter().map(|r| r.approx_bytes() as u64).collect();
    let jsons = records
        .iter()
        .map(serde_json::to_vec)
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| ApiError::internal("log record encode", error))?;
    let cipher_bytes: u64 = jsons.iter().map(|j| (j.len() + OVERHEAD) as u64).sum();
    let count = records.len() as u32;
    let entries: Vec<LogEntry> = records
        .into_iter()
        .zip(&billable)
        .map(|(record, billable)| LogEntry {
            project: partition.project,
            source: partition.source,
            environment: partition.environment.to_string(),
            billable_bytes: *billable,
            record,
        })
        .collect();
    let added = Summary::of(entries.iter().map(|e| (&e.record, e.billable_bytes)));

    let _write = rt.quotas.write(org).await?;
    let reservation = rt
        .log_storage
        .reserve(org, cipher_bytes, settings.backlog_bytes as u64)?;
    let handle = rt.tenant(org).await?;
    let txn = handle.begin_with_options(immediate()).await?;
    match restore_flag(&txn).await? {
        RestoreFlag::Clear => {}
        RestoreFlag::Required => return Err(LogFailure::RestorePending),
        RestoreFlag::Conflict(_) => return Err(LogFailure::RestoreConflict),
    }
    let state = unarchived(&txn).await?;
    if state.backlog + cipher_bytes > settings.org_backlog_bytes as u64 {
        return Err(LogFailure::BacklogFull);
    }
    let today = txn
        .query_one_raw(sql(
            "SELECT accepted, bytes FROM usage_daily WHERE day = ? AND category = 'log'",
            vec![day.clone().into()],
        ))
        .await?;
    let (accepted, bytes) = match today {
        Some(row) => (
            row.try_get::<i64>("", "accepted")? as u64,
            row.try_get::<i64>("", "bytes")? as u64,
        ),
        None => (0, 0),
    };
    let want = Usage {
        errors: 0,
        logs: u64::from(count),
        log_bytes: added.raw_bytes,
    };
    let mut month = month_usage(&txn, &day).await?;
    month.log_bytes = month.log_bytes.saturating_add(added.raw_bytes);
    if monthly_exceeded(&month, &want).is_some() {
        return Err(LogFailure::MonthlyQuotaExceeded);
    }
    if accepted + u64::from(count) > rt.settings.quotas.daily_logs
        || bytes + added.raw_bytes > rt.settings.quotas.daily_log_bytes
    {
        return Err(LogFailure::QuotaExceeded);
    }

    let now = now_micros();
    let seal_age = settings.batch_max_age().as_micros() as i64;
    let open = match open_row(&txn).await? {
        Some(open)
            if open.usage_day == day
                && open.entries + count <= settings.batch_max_entries as u32
                && open.raw_bytes + added.raw_bytes <= settings.batch_max_bytes as u64
                && now - open.opened_at < seal_age =>
        {
            Some(open)
        }
        Some(open) => {
            seal_row(&txn, open.id).await?;
            None
        }
        None => None,
    };
    let open = match open {
        Some(open) => open,
        None => {
            let key = Partition::batch_key(org, now);
            let row = txn
                .query_one_raw(sql(
                    "INSERT INTO log_objects (object_key, project_id, source_id, environment, min_ts, max_ts,
                        received_at, entry_count, level_mask, trace_bloom, raw_bytes, stored_bytes, adopted,
                        format, state, opened_at, usage_day, pending_bytes)
                     VALUES (?, 0, 0, '', ?, ?, ?, 0, 0, ?, 0, 0, 0, 2, 'open', ?, ?, 0) RETURNING id",
                    vec![
                        key.into(),
                        added.min_ts.into(),
                        added.max_ts.into(),
                        added.received_at.into(),
                        vec![0u8; BLOOM_BYTES].into(),
                        now.into(),
                        day.clone().into(),
                    ],
                ))
                .await?
                .ok_or_else(|| ApiError::Internal("log batch insert returned no id".into()))?;
            OpenRow {
                id: row.try_get("", "id")?,
                entries: 0,
                raw_bytes: 0,
                pending_bytes: 0,
                usage_day: day.clone(),
                opened_at: now,
                summary: Summary {
                    min_ts: added.min_ts,
                    max_ts: added.max_ts,
                    received_at: added.received_at,
                    level_mask: 0,
                    raw_bytes: 0,
                    bloom: vec![0; BLOOM_BYTES],
                },
            }
        }
    };

    let cipher = rt.pending_cipher.clone();
    let sealed = {
        let org = org.clone();
        let object_id = open.id;
        let first = open.entries;
        let partition = partition.clone();
        let billable = billable.clone();
        tokio::task::spawn_blocking(move || {
            jsons
                .iter()
                .zip(billable)
                .enumerate()
                .map(|(index, (json, billable_bytes))| {
                    cipher.seal(
                        &Slot {
                            org: &org,
                            object_id,
                            entry: first + index as u32,
                            project: partition.project.0,
                            source: partition.source.0,
                            environment: partition.environment.as_str(),
                            billable_bytes,
                        },
                        json,
                    )
                })
                .collect::<Vec<_>>()
        })
        .await
        .map_err(|_| ApiError::Internal("log seal task".into()))?
    };
    for (chunk_index, chunk) in sealed.chunks(256).enumerate() {
        let mut values: Vec<sea_orm::Value> = Vec::with_capacity(chunk.len() * 7);
        for (offset, blob) in chunk.iter().enumerate() {
            let index = chunk_index * 256 + offset;
            values.extend([
                open.id.into(),
                i64::from(open.entries + index as u32).into(),
                partition.project.0.into(),
                partition.source.0.into(),
                partition.environment.to_string().into(),
                (billable[index] as i64).into(),
                blob.clone().into(),
            ]);
        }
        let placeholders = vec!["(?, ?, ?, ?, ?, ?, ?)"; chunk.len()].join(", ");
        txn.execute_raw(sql(
            &format!(
                "INSERT INTO log_entries_pending (object_id, entry, project_id, source_id, environment,
                    billable_bytes, sealed) VALUES {placeholders}"
            ),
            values,
        ))
        .await?;
    }
    insert_runs(&txn, open.id, open.entries, &entries).await?;
    let summary = merge(open.summary, &added);
    let entry_count = open.entries + count;
    let raw_bytes = open.raw_bytes + added.raw_bytes;
    txn.execute_raw(sql(
        "UPDATE log_objects SET entry_count = ?, raw_bytes = ?, pending_bytes = ?, min_ts = ?, max_ts = ?,
            received_at = ?, level_mask = ?, trace_bloom = ? WHERE id = ?",
        vec![
            i64::from(entry_count).into(),
            (raw_bytes as i64).into(),
            ((open.pending_bytes + cipher_bytes) as i64).into(),
            summary.min_ts.into(),
            summary.max_ts.into(),
            summary.received_at.into(),
            i32::from(summary.level_mask).into(),
            summary.bloom.into(),
            open.id.into(),
        ],
    ))
    .await?;
    add_usage(&txn, &day, "log", u64::from(count), added.raw_bytes).await?;
    crate::billing::alerts::record(&txn, &day, Metric::LogBytes, month.log_bytes).await?;
    if entry_count >= settings.batch_max_entries as u32
        || raw_bytes >= settings.batch_max_bytes as u64
    {
        seal_row(&txn, open.id).await?;
    }
    let after = unarchived(&txn).await?;
    txn.commit().await?;
    drop(handle);

    hold.settle_all();
    reservation.commit(after);
    rt.metrics
        .logs_accepted
        .fetch_add(u64::from(count), Ordering::Relaxed);
    let cursor = Cursor {
        seq: open.id,
        entry: entry_count - 1,
    };
    if let Some(channel) = rt.hub.existing(org) {
        let _ = channel.tx.send(Arc::new(Published { cursor }));
    }
    Ok(cursor)
}

/// Makes an organization ready for log admission in this process. A marked
/// restore must finish its R2 reconciliation first. Otherwise this seals
/// open batches left by an earlier process, which needs no R2 access.
pub async fn prepare(rt: &Runtime, org: &OrgId) -> Result<(), ApiError> {
    let flag = {
        let handle = rt.tenant(org).await?;
        restore_flag(&*handle).await?
    };
    match flag {
        RestoreFlag::Clear => {}
        RestoreFlag::Conflict(_) => return Err(ApiError::Unavailable("log_restore_conflict")),
        RestoreFlag::Required => match crate::logs::reconcile::restore(rt, org).await? {
            crate::logs::reconcile::Outcome::Complete => {}
            crate::logs::reconcile::Outcome::Incomplete => {
                return Err(ApiError::Unavailable("log_restore_pending"))
            }
            crate::logs::reconcile::Outcome::Conflict(_) => {
                return Err(ApiError::Unavailable("log_restore_conflict"))
            }
        },
    }
    resync(rt, org).await
}

/// Rebuilds the organization's registry entry from SQLite. An open batch this
/// process did not create belongs to an earlier process and is sealed first,
/// so new entries never join a batch that predates this process.
pub(crate) async fn resync(rt: &Runtime, org: &OrgId) -> Result<(), ApiError> {
    let _write = rt.quotas.write(org).await?;
    let handle = rt.tenant(org).await?;
    if !rt.log_storage.knows_open(org) {
        handle
            .execute_raw(sql(
                "UPDATE log_objects SET state = 'sealed' WHERE state = 'open'",
                vec![],
            ))
            .await?;
    }
    let state = unarchived(&*handle).await?;
    drop(handle);
    rt.log_storage.refresh(org, state);
    Ok(())
}

/// A pending row read from SQLite before decryption.
pub(crate) struct PendingRow {
    pub entry: u32,
    pub project: i64,
    pub source: i64,
    pub environment: String,
    pub billable_bytes: u64,
    pub sealed: Vec<u8>,
}

/// Reads the first `count` pending rows of `object_id` in entry order.
pub(crate) async fn pending_rows<C: ConnectionTrait>(
    conn: &C,
    object_id: i64,
    count: u32,
) -> Result<Vec<PendingRow>, sea_orm::DbErr> {
    conn.query_all_raw(sql(
        "SELECT entry, project_id, source_id, environment, billable_bytes, sealed
         FROM log_entries_pending WHERE object_id = ? AND entry < ? ORDER BY entry",
        vec![object_id.into(), i64::from(count).into()],
    ))
    .await?
    .iter()
    .map(|row| {
        Ok(PendingRow {
            entry: row.try_get::<i64>("", "entry")? as u32,
            project: row.try_get("", "project_id")?,
            source: row.try_get("", "source_id")?,
            environment: row.try_get("", "environment")?,
            billable_bytes: row.try_get::<i64>("", "billable_bytes")? as u64,
            sealed: row.try_get("", "sealed")?,
        })
    })
    .collect()
}

/// Decrypts a complete pending snapshot. A gap or an unauthenticated row
/// fails the whole object, so no reader sees a partial batch as complete.
pub(crate) async fn open_pending(
    rt: &Runtime,
    org: &OrgId,
    object_id: i64,
    count: u32,
    rows: Vec<PendingRow>,
) -> Result<Vec<LogEntry>, crate::logs::pending::Corrupt> {
    let cipher = rt.pending_cipher.clone();
    let org = org.clone();
    tokio::task::spawn_blocking(move || {
        if rows.len() != count as usize {
            return Err(crate::logs::pending::Corrupt);
        }
        rows.iter()
            .enumerate()
            .map(|(index, row)| {
                if row.entry != index as u32 {
                    return Err(crate::logs::pending::Corrupt);
                }
                cipher.open(
                    &Slot {
                        org: &org,
                        object_id,
                        entry: row.entry,
                        project: row.project,
                        source: row.source,
                        environment: &row.environment,
                        billable_bytes: row.billable_bytes,
                    },
                    &row.sealed,
                )
            })
            .collect()
    })
    .await
    .unwrap_or(Err(crate::logs::pending::Corrupt))
}

/// One sealed batch decrypted from SQLite.
pub(crate) struct SealedBatch {
    pub identity: BatchIdentity,
    pub entries: Vec<LogEntry>,
}

pub(crate) enum Loaded {
    Batch(SealedBatch),
    Gone,
    Corrupt,
}

pub(crate) async fn load_sealed(rt: &Runtime, org: &OrgId, id: i64) -> Result<Loaded, ApiError> {
    let (identity, count, rows) = {
        let handle = rt.tenant(org).await?;
        let txn = handle.begin().await?;
        let Some(row) = txn
            .query_one_raw(sql(
                "SELECT object_key, usage_day, opened_at, entry_count FROM log_objects
                 WHERE id = ? AND state = 'sealed' AND format = 2",
                vec![id.into()],
            ))
            .await?
        else {
            txn.rollback().await?;
            return Ok(Loaded::Gone);
        };
        let count = row.try_get::<i64>("", "entry_count")? as u32;
        let identity = BatchIdentity {
            org: org.clone(),
            object_id: id,
            key: row.try_get("", "object_key")?,
            usage_day: row
                .try_get::<Option<String>>("", "usage_day")?
                .unwrap_or_default(),
            opened_at: row
                .try_get::<Option<i64>>("", "opened_at")?
                .unwrap_or_default(),
        };
        let rows = pending_rows(&txn, id, count).await?;
        txn.commit().await?;
        (identity, count, rows)
    };
    Ok(match open_pending(rt, org, id, count, rows).await {
        Ok(entries) => Loaded::Batch(SealedBatch { identity, entries }),
        Err(_) => Loaded::Corrupt,
    })
}

/// How a remote object relates to the local sealed batch.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Verdict {
    Same,
    Extends,
    Conflict(&'static str),
}

/// Compares the canonical entry lines of the local batch with the stored
/// lines of a remote object at the same key. Only identical bytes or a strict
/// extension of them is accepted; equal counts or a larger object prove
/// nothing by themselves. Bytes are compared, not parsed values, because a
/// JSON number does not always survive a parse and re-serialization intact.
pub(crate) fn compare(
    identity: &BatchIdentity,
    local: &[u8],
    local_count: usize,
    remote: &StoredBatch,
) -> Verdict {
    if !identity.matches(&remote.header) {
        return Verdict::Conflict("remote_identity_mismatch");
    }
    if remote.entries.len() < local_count {
        return Verdict::Conflict("remote_shorter");
    }
    if !remote.lines.starts_with(local) {
        return Verdict::Conflict("remote_prefix_mismatch");
    }
    if remote.entries.len() == local_count {
        Verdict::Same
    } else {
        Verdict::Extends
    }
}

/// Marks a sealed batch archived after its R2 object was verified. With a
/// verified extension the metadata, runs and usage follow the remote object;
/// only the extra suffix is charged, without admission limits. Returns false
/// when the row is not sealed or its entry count differs from `batch`.
pub(crate) async fn commit_archive(
    rt: &Runtime,
    batch: &SealedBatch,
    header: &BatchHeader,
    remote: Option<&[LogEntry]>,
    stored_bytes: u64,
) -> Result<bool, ApiError> {
    let org = &batch.identity.org;
    let id = batch.identity.object_id;
    let day = &batch.identity.usage_day;
    let _write = rt.quotas.write(org).await?;
    let handle = rt.tenant(org).await?;
    let txn = handle.begin_with_options(immediate()).await?;
    let current = txn
        .query_one_raw(sql(
            "SELECT entry_count FROM log_objects WHERE id = ? AND state = 'sealed'",
            vec![id.into()],
        ))
        .await?
        .map(|row| row.try_get::<i64>("", "entry_count"))
        .transpose()?;
    if current != Some(batch.entries.len() as i64) {
        txn.rollback().await?;
        return Ok(false);
    }
    txn.execute_raw(sql(
        "UPDATE log_objects SET state = 'archived', archived_at = ?, stored_bytes = ?, pending_bytes = 0,
            content_sha256 = ?, entry_count = ?, raw_bytes = ?, min_ts = ?, max_ts = ?, received_at = ?,
            level_mask = ?, trace_bloom = ? WHERE id = ?",
        vec![
            now_micros().into(),
            (stored_bytes as i64).into(),
            header.digest().into(),
            i64::from(header.count).into(),
            (header.raw_bytes as i64).into(),
            header.min_ts.into(),
            header.max_ts.into(),
            header.received_at.into(),
            i32::from(header.level_mask).into(),
            header.bloom().into(),
            id.into(),
        ],
    ))
    .await?;
    txn.execute_raw(sql(
        "DELETE FROM log_entries_pending WHERE object_id = ?",
        vec![id.into()],
    ))
    .await?;
    let mut repaired = Usage::default();
    if let Some(remote) = remote {
        let suffix = &remote[batch.entries.len()..];
        txn.execute_raw(sql(
            "DELETE FROM log_entry_runs WHERE object_id = ?",
            vec![id.into()],
        ))
        .await?;
        insert_runs(&txn, id, 0, remote).await?;
        repaired.logs = suffix.len() as u64;
        repaired.log_bytes = suffix.iter().map(|e| e.billable_bytes).sum();
        add_usage(&txn, day, "log", repaired.logs, repaired.log_bytes).await?;
        let month = month_usage(&txn, day).await?;
        crate::billing::alerts::record(&txn, day, Metric::LogBytes, month.log_bytes).await?;
    }
    txn.commit().await?;
    drop(handle);
    if repaired != Usage::default() {
        rt.quotas.committed(org, day, repaired);
    }
    Ok(true)
}

#[derive(Debug)]
pub(crate) enum ArchiveError {
    Store,
    Conflict(&'static str),
    Corrupt,
    Database(ApiError),
}

impl ArchiveError {
    fn reason(&self) -> &'static str {
        match self {
            Self::Store => "store_unavailable",
            Self::Conflict(reason) => reason,
            Self::Corrupt => "pending_entry_corrupt",
            Self::Database(_) => "database_unavailable",
        }
    }
}

impl From<ApiError> for ArchiveError {
    fn from(error: ApiError) -> Self {
        Self::Database(error)
    }
}

impl From<sea_orm::DbErr> for ArchiveError {
    fn from(error: sea_orm::DbErr) -> Self {
        Self::Database(error.into())
    }
}

fn max_raw(settings: &crate::settings::Settings) -> usize {
    settings.logs.max_object_bytes + settings.ingest.max_inflated_bytes
}

pub(crate) async fn fetch_batch(
    rt: &Runtime,
    key: &str,
) -> Result<Option<(StoredBatch, u64)>, ArchiveError> {
    let Some(body) = rt
        .store
        .get(key, rt.settings.logs.max_object_bytes)
        .await
        .map_err(|_| ArchiveError::Store)?
    else {
        return Ok(None);
    };
    let stored = body.len() as u64;
    let limit = max_raw(&rt.settings);
    match tokio::task::spawn_blocking(move || decode_batch(&body, limit)).await {
        Ok(Ok(batch)) => Ok(Some((batch, stored))),
        _ => Err(ArchiveError::Conflict("remote_invalid")),
    }
}

/// Settles a sealed batch against R2 content that already exists at its key.
/// Returns false when the row is not sealed or its entry count differs from `batch`.
pub(crate) async fn settle_existing(
    rt: &Runtime,
    batch: &SealedBatch,
    remote: &StoredBatch,
    stored: u64,
) -> Result<bool, ArchiveError> {
    let local = entry_lines(&batch.entries).map_err(|_| ArchiveError::Corrupt)?;
    match compare(&batch.identity, &local, batch.entries.len(), remote) {
        Verdict::Same => commit_archive(rt, batch, &remote.header, None, stored)
            .await
            .map_err(ArchiveError::from),
        Verdict::Extends => {
            let archived =
                commit_archive(rt, batch, &remote.header, Some(&remote.entries), stored).await?;
            if archived {
                rt.metrics.logs_adopted.fetch_add(
                    (remote.entries.len() - batch.entries.len()) as u64,
                    Ordering::Relaxed,
                );
            }
            Ok(archived)
        }
        Verdict::Conflict(reason) => {
            rt.metrics.archive_conflicts.fetch_add(1, Ordering::Relaxed);
            tracing::error!(org = %batch.identity.org, object = batch.identity.object_id, reason,
                "log archive conflict: the existing R2 object does not match the sealed batch");
            Err(ArchiveError::Conflict(reason))
        }
    }
}

async fn archive_object(rt: &Runtime, org: &OrgId, id: i64) -> Result<bool, ArchiveError> {
    let batch = match load_sealed(rt, org, id).await? {
        Loaded::Batch(batch) => batch,
        Loaded::Gone => return Ok(true),
        Loaded::Corrupt => return Err(ArchiveError::Corrupt),
    };
    let cutoff = now_micros() - rt.settings.logs.retention().as_micros() as i64;
    if batch.entries.iter().all(|entry| entry.record.rt < cutoff) {
        return Ok(false);
    }
    let identity = batch.identity.clone();
    let entries = batch.entries.clone();
    let encoded = tokio::task::spawn_blocking(move || encode_batch(&identity, &entries))
        .await
        .map_err(|_| ArchiveError::Store)?
        .map_err(|_| ArchiveError::Store)?;
    let settings = &rt.settings.logs;
    let deadline = Instant::now() + settings.upload_deadline();
    let mut attempt = 0;
    let created = loop {
        attempt += 1;
        let result = tokio::time::timeout_at(
            deadline,
            rt.store
                .put_if_absent(&encoded.header.key, Bytes::clone(&encoded.body)),
        )
        .await;
        match result {
            Ok(Ok(created)) => break created,
            Ok(Err(error)) => tracing::warn!(%error, attempt, "log archive upload failed"),
            Err(_) => return Err(ArchiveError::Store),
        }
        if attempt >= settings.upload_attempts {
            return Err(ArchiveError::Store);
        }
        rt.metrics
            .log_upload_retries
            .fetch_add(1, Ordering::Relaxed);
        let backoff =
            Duration::from_millis(100 * (1 << attempt.min(5)) + u64::from(rand::random::<u8>()));
        if Instant::now() + backoff >= deadline {
            return Err(ArchiveError::Store);
        }
        tokio::time::sleep(backoff).await;
    };
    if let Some(faults) = rt.faults() {
        pause_for_test(rt, &faults.pause_after_log_put).await;
    }
    let (archived, header) = match created {
        Created::New => (
            commit_archive(rt, &batch, &encoded.header, None, encoded.body.len() as u64).await?,
            encoded.header,
        ),
        Created::Exists => {
            let (remote, stored) = fetch_batch(rt, &encoded.header.key)
                .await?
                .ok_or(ArchiveError::Store)?;
            (
                settle_existing(rt, &batch, &remote, stored).await?,
                remote.header,
            )
        }
    };
    if archived {
        rt.metrics.objects_archived.fetch_add(1, Ordering::Relaxed);
    } else {
        discard_expired_upload(rt, org, &header).await?;
    }
    Ok(true)
}

/// Deletes an uploaded batch whose row retention removed while the upload was
/// in flight. Retention deletes the key before the row, so an upload that
/// lands afterwards has no other owner. The object is kept unless no row has
/// its id or key and every entry in it is past retention.
async fn discard_expired_upload(
    rt: &Runtime,
    org: &OrgId,
    header: &BatchHeader,
) -> Result<(), ArchiveError> {
    let cutoff = now_micros() - rt.settings.logs.retention().as_micros() as i64;
    let _write = rt.quotas.write(org).await?;
    let handle = rt.tenant(org).await?;
    let known: i64 = handle
        .query_one_raw(sql(
            "SELECT COUNT(*) AS n FROM log_objects WHERE id = ? OR object_key = ?",
            vec![header.object_id.into(), header.key.clone().into()],
        ))
        .await?
        .map(|row| row.try_get("", "n"))
        .transpose()?
        .unwrap_or(0);
    drop(handle);
    if known > 0 {
        return Ok(());
    }
    if header.received_at >= cutoff {
        tracing::error!(org = %org, object = header.object_id, key = %header.key,
            "log archive row disappeared before retention; the uploaded object is kept");
        return Ok(());
    }
    rt.store
        .delete(&header.key)
        .await
        .map_err(|_| ArchiveError::Store)?;
    Ok(())
}

async fn pause_for_test(rt: &Runtime, pause: &std::sync::atomic::AtomicBool) {
    if pause.swap(false, Ordering::SeqCst) {
        if let Some(faults) = rt.faults() {
            faults.log_paused.notify_one();
            tokio::select! {
                () = rt.log_storage.cancel.cancelled() => {}
                () = faults.log_resume.notified() => {}
            }
        }
    }
}

async fn seal_aged(rt: &Runtime, org: &OrgId, id: i64) -> Result<(), ApiError> {
    let cutoff = now_micros() - rt.settings.logs.batch_max_age().as_micros() as i64;
    let _write = rt.quotas.write(org).await?;
    let handle = rt.tenant(org).await?;
    handle
        .execute_raw(sql(
            "UPDATE log_objects SET state = 'sealed' WHERE id = ? AND state = 'open' AND opened_at <= ?",
            vec![id.into(), cutoff.into()],
        ))
        .await?;
    let state = unarchived(&*handle).await?;
    drop(handle);
    rt.log_storage.refresh(org, state);
    Ok(())
}

/// Seals the organization's aged open batch and archives every sealed batch
/// in id order. Stops at the first failure, keeping the row sealed for retry,
/// or at an expired batch, leaving it to retention.
async fn run_job(rt: &Runtime, org: &OrgId, aged: Option<i64>) -> Result<(), ArchiveError> {
    if let Some(id) = aged {
        seal_aged(rt, org, id).await?;
    }
    loop {
        let next = {
            let handle = rt.tenant(org).await?;
            if restore_flag(&*handle).await? != RestoreFlag::Clear {
                return Ok(());
            }
            handle
                .query_one_raw(sql(
                    "SELECT id FROM log_objects WHERE state = 'sealed' ORDER BY id LIMIT 1",
                    vec![],
                ))
                .await?
                .map(|row| row.try_get::<i64>("", "id"))
                .transpose()?
        };
        let Some(id) = next else {
            break;
        };
        let _permit = rt
            .log_storage
            .archives
            .clone()
            .acquire_owned()
            .await
            .map_err(|_| ArchiveError::Store)?;
        if !archive_object(rt, org, id).await? {
            break;
        }
    }
    let _write = rt.quotas.write(org).await?;
    let handle = rt.tenant(org).await?;
    let state = unarchived(&*handle).await?;
    drop(handle);
    rt.log_storage.refresh(org, state);
    Ok(())
}

/// Ticks at most every `archive_tick_ms`, seals aged batches and starts one
/// archive job per organization with sealed work.
pub async fn run(rt: Arc<Runtime>) {
    let tick = Duration::from_millis(rt.settings.logs.archive_tick_ms.max(1));
    let mut ticker = tokio::time::interval(tick);
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        tokio::select! {
            () = rt.cancel.cancelled() => return,
            _ = ticker.tick() => {}
        }
        let seal_before = now_micros() - rt.settings.logs.batch_max_age().as_micros() as i64;
        let jobs: Vec<(OrgId, Option<i64>)> = {
            let mut registry = rt.log_storage.registry.lock().expect("log registry");
            if registry.closed {
                return;
            }
            let now = Instant::now();
            registry
                .orgs
                .iter_mut()
                .filter_map(|(org, work)| {
                    let aged = work.open.filter(|(_, opened)| *opened <= seal_before);
                    let due = work.retry_at.is_none_or(|at| at <= now);
                    if work.busy || !due || (aged.is_none() && !work.sealed) {
                        return None;
                    }
                    work.busy = true;
                    Some((org.clone(), aged.map(|(id, _)| id)))
                })
                .collect()
        };
        for (org, aged) in jobs {
            let task_rt = rt.clone();
            rt.log_storage.tasks.spawn(async move {
                let result = tokio::select! {
                    () = task_rt.log_storage.cancel.cancelled() => Err(ArchiveError::Store),
                    result = run_job(&task_rt, &org, aged) => result,
                };
                match result {
                    Ok(()) => task_rt.log_storage.finish_job(&org, None),
                    Err(ArchiveError::Database(ApiError::NotFound)) => {
                        task_rt.log_storage.forget(&org)
                    }
                    Err(error) => {
                        if matches!(error, ArchiveError::Database(_)) {
                            tracing::warn!(org = %org, ?error, "log archive job failed");
                        }
                        task_rt
                            .metrics
                            .log_batches_failed
                            .fetch_add(1, Ordering::Relaxed);
                        task_rt.log_storage.finish_job(&org, Some(error.reason()));
                    }
                }
            });
        }
    }
}

/// Stops scheduling and waits for running archive jobs within `deadline`,
/// then cancels them and waits at most `LifecycleSettings::CANCEL_WAIT`.
/// Acknowledged entries stay in SQLite; the next start archives them.
pub async fn close(rt: &Runtime, deadline: Duration) {
    rt.log_storage.registry.lock().expect("log registry").closed = true;
    rt.log_storage.tasks.close();
    if tokio::time::timeout(deadline, rt.log_storage.tasks.wait())
        .await
        .is_err()
    {
        tracing::error!("shutdown: log archive jobs did not finish before the deadline");
        rt.log_storage.cancel.cancel();
        let cancelled = rt.log_storage.tasks.wait();
        if tokio::time::timeout(LifecycleSettings::CANCEL_WAIT, cancelled)
            .await
            .is_err()
        {
            tracing::error!("shutdown: cancelled log archive jobs are still running");
        }
    }
}

#[derive(Debug, Serialize, PartialEq)]
pub struct LastArchive {
    pub object: i64,
    pub key: String,
    pub entries: i64,
    pub raw_bytes: i64,
    pub stored_bytes: i64,
    pub opened_at: i64,
    pub archived_at: i64,
    pub delay_secs: f64,
}

#[derive(Debug, Serialize, PartialEq)]
pub struct StorageStatus {
    pub restore_required: bool,
    pub restore_conflict: Option<String>,
    pub orphan_cleanup_held: bool,
    pub open_object: Option<i64>,
    pub open_entries: Option<i64>,
    pub sealed_objects: i64,
    pub pending_entries: i64,
    pub pending_billable_bytes: i64,
    pub pending_ciphertext_bytes: i64,
    pub backlog_limit_bytes: u64,
    pub oldest_pending_age_secs: Option<f64>,
    pub archived_objects: i64,
    pub last_archive: Option<LastArchive>,
    pub archive_failure: Option<ArchiveFailure>,
    pub deadline_secs: u64,
}

/// Archive progress of one organization for operators and verification.
pub async fn status(rt: &Runtime, org: &OrgId) -> Result<StorageStatus, ApiError> {
    let handle = rt.tenant(org).await?;
    let txn = handle.begin().await?;
    let restore = txn
        .query_one_raw(sql(
            "SELECT logs_reconcile_required, orphan_cleanup_held, conflict FROM restore_state WHERE id = 1",
            vec![],
        ))
        .await?
        .ok_or_else(|| ApiError::Internal("restore state row is missing".into()))?;
    let pending = txn
        .query_one_raw(sql(
            "SELECT
                (SELECT id FROM log_objects WHERE state = 'open') AS open_object,
                (SELECT entry_count FROM log_objects WHERE state = 'open') AS open_entries,
                (SELECT COUNT(*) FROM log_objects WHERE state = 'sealed') AS sealed_objects,
                COALESCE(SUM(entry_count), 0) AS entries, COALESCE(SUM(raw_bytes), 0) AS billable,
                COALESCE(SUM(pending_bytes), 0) AS ciphertext, MIN(opened_at) AS oldest
             FROM log_objects WHERE state != 'archived'",
            vec![],
        ))
        .await?
        .ok_or_else(|| ApiError::Internal("log status returned no row".into()))?;
    let archived: i64 = txn
        .query_one_raw(sql(
            "SELECT COUNT(*) AS n FROM log_objects WHERE state = 'archived'",
            vec![],
        ))
        .await?
        .map(|row| row.try_get("", "n"))
        .transpose()?
        .unwrap_or(0);
    let last = txn
        .query_one_raw(sql(
            "SELECT id, object_key, entry_count, raw_bytes, stored_bytes, opened_at, archived_at
             FROM log_objects WHERE format = 2 AND state = 'archived'
             ORDER BY archived_at DESC, id DESC LIMIT 1",
            vec![],
        ))
        .await?;
    txn.commit().await?;
    drop(handle);
    let now = now_micros();
    let last_archive = match last {
        None => None,
        Some(row) => {
            let opened_at: i64 = row
                .try_get::<Option<i64>>("", "opened_at")?
                .unwrap_or_default();
            let archived_at: i64 = row
                .try_get::<Option<i64>>("", "archived_at")?
                .unwrap_or_default();
            Some(LastArchive {
                object: row.try_get("", "id")?,
                key: row.try_get("", "object_key")?,
                entries: row.try_get("", "entry_count")?,
                raw_bytes: row.try_get("", "raw_bytes")?,
                stored_bytes: row.try_get("", "stored_bytes")?,
                opened_at,
                archived_at,
                delay_secs: (archived_at - opened_at) as f64 / 1e6,
            })
        }
    };
    Ok(StorageStatus {
        restore_required: restore.try_get::<i64>("", "logs_reconcile_required")? == 1,
        restore_conflict: restore.try_get("", "conflict")?,
        orphan_cleanup_held: restore.try_get::<i64>("", "orphan_cleanup_held")? == 1,
        open_object: pending.try_get("", "open_object")?,
        open_entries: pending.try_get("", "open_entries")?,
        sealed_objects: pending.try_get("", "sealed_objects")?,
        pending_entries: pending.try_get("", "entries")?,
        pending_billable_bytes: pending.try_get("", "billable")?,
        pending_ciphertext_bytes: pending.try_get("", "ciphertext")?,
        backlog_limit_bytes: rt.settings.logs.org_backlog_bytes as u64,
        oldest_pending_age_secs: pending
            .try_get::<Option<i64>>("", "oldest")?
            .map(|opened| (now - opened) as f64 / 1e6),
        archived_objects: archived,
        last_archive,
        archive_failure: rt.log_storage.failure(org),
        deadline_secs: 300,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        domain::{ProjectId, SourceId},
        logs::{
            object::bloom_insert,
            record::{LogBody, LogLevel},
        },
    };

    fn entry(project: i64, body: &str) -> LogEntry {
        LogEntry {
            project: ProjectId(project),
            source: SourceId(1),
            environment: "production".into(),
            billable_bytes: 10,
            record: LogRecord {
                ts: 1,
                rt: 2,
                level: LogLevel::Info,
                trace_id: None,
                span_id: None,
                body: serde_json::from_value::<LogBody>(serde_json::json!(body)).unwrap(),
                attributes: Default::default(),
            },
        }
    }

    fn identity() -> BatchIdentity {
        BatchIdentity {
            org: "o0123456789abcdef0123456789abcdef".parse().unwrap(),
            object_id: 4,
            key: "logs/v1/o0123456789abcdef0123456789abcdef/v2/2026101612/k.ndjson.zst".into(),
            usage_day: "20261016".into(),
            opened_at: 99,
        }
    }

    fn stored(entries: &[LogEntry], identity: &BatchIdentity) -> StoredBatch {
        let encoded = encode_batch(identity, entries).unwrap();
        decode_batch(&encoded.body, 1 << 20).unwrap()
    }

    fn verdict(local: &[LogEntry], remote: &StoredBatch) -> Verdict {
        compare(
            &identity(),
            &entry_lines(local).unwrap(),
            local.len(),
            remote,
        )
    }

    #[test]
    fn remote_batches_are_accepted_only_when_identical_or_a_strict_extension() {
        let id = identity();
        let local = vec![entry(1, "a"), entry(2, "b")];
        assert_eq!(verdict(&local, &stored(&local, &id)), Verdict::Same);
        let longer = vec![entry(1, "a"), entry(2, "b"), entry(1, "c")];
        assert_eq!(verdict(&local, &stored(&longer, &id)), Verdict::Extends);
        let changed_middle = vec![entry(1, "a"), entry(2, "B")];
        assert_eq!(
            verdict(&local, &stored(&changed_middle, &id)),
            Verdict::Conflict("remote_prefix_mismatch")
        );
        let longer_changed = vec![entry(1, "x"), entry(2, "b"), entry(1, "c")];
        assert_eq!(
            verdict(&local, &stored(&longer_changed, &id)),
            Verdict::Conflict("remote_prefix_mismatch")
        );
        let shorter = vec![entry(1, "a")];
        assert_eq!(
            verdict(&local, &stored(&shorter, &id)),
            Verdict::Conflict("remote_shorter")
        );
        let other = BatchIdentity {
            object_id: 5,
            ..identity()
        };
        assert_eq!(
            verdict(&local, &stored(&local, &other)),
            Verdict::Conflict("remote_identity_mismatch")
        );
    }

    #[test]
    fn appended_runs_merge_summaries_for_one_partition() {
        let left = Summary::of([(&entry(1, "a").record, 3)]);
        let mut later = entry(1, "b").record;
        later.ts = 7;
        later.level = LogLevel::Error;
        later.trace_id = Some("0123456789abcdef0123456789abcdef".into());
        let right = Summary::of([(&later, 4)]);
        let merged = merge(left, &right);
        assert_eq!(
            (
                merged.min_ts,
                merged.max_ts,
                merged.raw_bytes,
                merged.level_mask
            ),
            (1, 7, 7, LogLevel::Info.bit() | LogLevel::Error.bit())
        );
        let mut probe = vec![0u8; BLOOM_BYTES];
        bloom_insert(&mut probe, "0123456789abcdef0123456789abcdef");
        assert!(probe
            .iter()
            .zip(&merged.bloom)
            .all(|(bit, merged)| bit & merged == *bit));
    }

    #[tokio::test]
    async fn close_returns_when_an_archive_job_ignores_cancellation() {
        let env = crate::testing::TestEnv::new("log-close-bound");
        let boot = env.boot_memory(|_| {}).await.unwrap();
        let rt = Runtime::get(&boot.app_context);
        rt.log_storage.tasks.spawn(std::future::pending::<()>());

        let deadline = Duration::from_millis(100);
        let started = std::time::Instant::now();
        close(&rt, deadline).await;
        let elapsed = started.elapsed();

        assert!(
            elapsed >= deadline + LifecycleSettings::CANCEL_WAIT,
            "close returned after {elapsed:?}, before the job could be waited for"
        );
        assert!(
            elapsed < deadline + LifecycleSettings::CANCEL_WAIT + Duration::from_millis(500),
            "close took {elapsed:?}"
        );
    }
}
