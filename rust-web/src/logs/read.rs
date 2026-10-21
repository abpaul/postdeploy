//! Bounded log search and live tail. One SQLite read transaction selects
//! candidate objects and, for batches that are not archived yet, their
//! pending entries. Each object is therefore read exactly once: from the
//! pending snapshot or from its archived R2 object. Batches mix
//! partitions, so every entry is filtered by its own project, source and
//! environment. No tenant handle is held during object reads or for the life
//! of a tail stream.

use std::{sync::Arc, time::Duration};

use futures::{Stream, StreamExt};
use sea_orm::ConnectionTrait;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::{sync::broadcast::error::RecvError, time::Instant};

use crate::{
    admission::QueryPermit,
    domain::{now_micros, Environment, OrgId},
    error::{ApiError, ApiResult},
    identity::access::{authorize, OrgAccess},
    ingest::interfaces::Identifier,
    logs::{
        object::{bloom_contains, decode, LogEntry},
        record::{serialized_bytes, LogBody, LogLevel, LogRecord, ParseLimits},
        storage::{
            cursor_epoch, open_pending, pending_rows, restore_flag, PendingRow, RestoreFlag,
        },
    },
    runtime::{sql, Runtime},
};

pub const OBJECT_END: u32 = u32::MAX;

/// An entry position inside one database lineage: the `log_objects` id and
/// the entry index. Clients only ever see it inside a [`CursorToken`].
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct Cursor {
    pub seq: i64,
    pub entry: u32,
}

/// Identifies the database lineage that issued a cursor. Each completed
/// supported restore picks a fresh random epoch, because a restored database
/// can reissue positions of entries that were lost with the old disk. Zero
/// means no supported restore has completed on this database.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct CursorEpoch(u64);

impl CursorEpoch {
    pub const INITIAL: Self = Self(0);

    pub(crate) fn fresh() -> Self {
        loop {
            let epoch = rand::random::<u64>();
            if epoch != 0 {
                return Self(epoch);
            }
        }
    }

    pub(crate) fn from_stored(value: i64) -> Self {
        Self(value as u64)
    }

    pub(crate) fn stored(self) -> i64 {
        self.0 as i64
    }

    pub fn token(self, at: Cursor) -> CursorToken {
        CursorToken { epoch: self, at }
    }

    pub fn resolve(self, token: CursorToken) -> ApiResult<Cursor> {
        if token.epoch == self {
            Ok(token.at)
        } else {
            Err(ApiError::Conflict("cursor_reset_required"))
        }
    }
}

/// The external cursor: `c1.{seq}.{entry}` at the initial epoch, otherwise
/// `c2.{epoch as 16 lowercase hex digits}.{seq}.{entry}`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct CursorToken {
    pub epoch: CursorEpoch,
    pub at: Cursor,
}

impl CursorToken {
    pub fn parse(value: &str) -> Option<Self> {
        let (epoch, rest) = if let Some(rest) = value.strip_prefix("c1.") {
            (CursorEpoch::INITIAL, rest)
        } else {
            let (hex, rest) = value.strip_prefix("c2.")?.split_once('.')?;
            if hex.len() != 16 || !hex.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f')) {
                return None;
            }
            let epoch = u64::from_str_radix(hex, 16).ok().filter(|e| *e != 0)?;
            (CursorEpoch(epoch), rest)
        };
        let (seq, entry) = rest.split_once('.')?;
        let token = Self {
            epoch,
            at: Cursor {
                seq: seq.parse().ok()?,
                entry: entry.parse().ok()?,
            },
        };
        (token.to_string() == value).then_some(token)
    }
}

impl std::fmt::Display for CursorToken {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self.epoch {
            CursorEpoch(0) => write!(f, "c1.{}.{}", self.at.seq, self.at.entry),
            CursorEpoch(epoch) => write!(f, "c2.{epoch:016x}.{}.{}", self.at.seq, self.at.entry),
        }
    }
}

impl Serialize for CursorToken {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.collect_str(self)
    }
}

fn parse_token(value: &str) -> ApiResult<CursorToken> {
    CursorToken::parse(value).ok_or(ApiError::BadRequest("invalid_cursor"))
}

#[derive(Debug, Default, Deserialize)]
pub struct LogQuery {
    pub project: Option<i64>,
    pub source: Option<i64>,
    pub environment: Option<String>,
    /// Comma-separated levels.
    pub level: Option<String>,
    pub trace_id: Option<String>,
    /// Exact values of the entry attributes listed in [`Identifier::keys`].
    pub request_id: Option<String>,
    pub service: Option<String>,
    pub release: Option<String>,
    pub q: Option<String>,
    pub since: Option<i64>,
    pub until: Option<i64>,
    pub limit: Option<usize>,
    pub before: Option<String>,
}

#[derive(Serialize)]
pub struct LogRow {
    pub cursor: CursorToken,
    pub ts: i64,
    pub level: LogLevel,
    pub body: LogBody,
    pub trace_id: Option<String>,
    pub span_id: Option<String>,
    pub attributes: Value,
    pub project_id: i64,
    pub source_id: i64,
    pub environment: String,
}

#[derive(Debug, Serialize, Default)]
pub struct Coverage {
    pub objects: usize,
    pub bytes: u64,
    pub truncated_by: Option<&'static str>,
    pub reconciling: bool,
    pub retention_secs: u64,
    /// Indexed batches whose stored object could not be found. Their entries
    /// are absent from `rows`.
    pub missing_objects: usize,
    /// Batches whose stored content failed validation or decryption. Their
    /// entries are absent from `rows`.
    pub corrupt_objects: usize,
}

#[derive(Serialize)]
pub struct SearchPage {
    pub rows: Vec<LogRow>,
    pub next: Option<CursorToken>,
    pub coverage: Coverage,
}

struct Filter {
    project: Option<i64>,
    source: Option<i64>,
    environment: Option<String>,
    levels: u8,
    trace_id: Option<String>,
    identifiers: Vec<(Identifier, String)>,
    needle: Option<String>,
    since: i64,
    until: i64,
    retained_after: i64,
}

impl Filter {
    fn from_query(query: &LogQuery, retention: Duration) -> ApiResult<Self> {
        let retained_after = now_micros() - retention.as_micros() as i64;
        let levels = match &query.level {
            None => u8::MAX,
            Some(list) => {
                list.split(',')
                    .filter(|l| !l.is_empty())
                    .try_fold(0u8, |mask, level| {
                        LogLevel::parse(level)
                            .map(|l| mask | l.bit())
                            .ok_or(ApiError::BadRequest("invalid_level"))
                    })?
            }
        };
        let environment = match &query.environment {
            None => None,
            Some(env) => Some(
                Environment::parse(env)
                    .ok_or(ApiError::BadRequest("invalid_environment"))?
                    .to_string(),
            ),
        };
        let trace_id = match &query.trace_id {
            None => None,
            Some(t) if t.len() == 32 && t.bytes().all(|b| b.is_ascii_hexdigit()) => {
                Some(t.to_ascii_lowercase())
            }
            Some(_) => return Err(ApiError::BadRequest("invalid_trace_id")),
        };
        let needle = query
            .q
            .as_deref()
            .map(str::trim)
            .filter(|q| !q.is_empty())
            .map(str::to_lowercase);
        if needle.as_ref().is_some_and(|n| n.len() > 256) {
            return Err(ApiError::BadRequest("query_too_long"));
        }
        let mut identifiers = Vec::new();
        for (identifier, value) in [
            (Identifier::RequestId, &query.request_id),
            (Identifier::Service, &query.service),
            (Identifier::Release, &query.release),
        ] {
            if let Some(value) = value {
                let value = value.trim();
                if value.is_empty() || value.len() > 200 {
                    return Err(ApiError::BadRequest("invalid_identifier"));
                }
                identifiers.push((identifier, value.to_owned()));
            }
        }
        Ok(Self {
            project: query.project,
            source: query.source,
            environment,
            levels,
            trace_id,
            identifiers,
            needle,
            since: query.since.unwrap_or(i64::MIN),
            until: query.until.unwrap_or(i64::MAX),
            retained_after,
        })
    }

    fn live_only(levels: u8, project: Option<i64>, retention: Duration) -> Self {
        Self {
            project,
            source: None,
            environment: None,
            levels,
            trace_id: None,
            identifiers: Vec::new(),
            needle: None,
            since: i64::MIN,
            until: i64::MAX,
            retained_after: now_micros() - retention.as_micros() as i64,
        }
    }

    fn object_matches(&self, object: &ObjectRow) -> bool {
        object.level_mask & self.levels != 0
            && self
                .trace_id
                .as_ref()
                .is_none_or(|t| bloom_contains(&object.trace_bloom, t))
    }

    fn partition_matches(&self, entry: &LogEntry) -> bool {
        self.project.is_none_or(|p| p == entry.project.0)
            && self.source.is_none_or(|s| s == entry.source.0)
            && self
                .environment
                .as_ref()
                .is_none_or(|e| *e == entry.environment)
    }

    fn entry_matches(&self, record: &LogRecord) -> bool {
        record.rt >= self.retained_after
            && (self.since..=self.until).contains(&record.ts)
            && record.level.bit() & self.levels != 0
            && self
                .trace_id
                .as_ref()
                .is_none_or(|t| record.trace_id.as_ref() == Some(t))
            && self.identifiers.iter().all(|(identifier, value)| {
                identifier.find(|key| record.attributes.as_map().get(key)?.get("value"))
                    == Some(value.as_str())
            })
            && self
                .needle
                .as_ref()
                .is_none_or(|n| record.body.as_str().to_lowercase().contains(n.as_str()))
    }
}

#[derive(Clone)]
struct ObjectRow {
    id: i64,
    key: String,
    archived: bool,
    open: bool,
    entry_count: u32,
    level_mask: u8,
    trace_bloom: Vec<u8>,
    received_at: i64,
    /// Bytes a read of this object scans: the R2 object once archived,
    /// otherwise the pending ciphertext.
    scan_bytes: u64,
}

const OBJECT_COLUMNS: &str =
    "id, object_key, state, entry_count, level_mask, trace_bloom, received_at, stored_bytes,
    pending_bytes";

fn object_row(row: &sea_orm::QueryResult) -> Result<ObjectRow, sea_orm::DbErr> {
    let state: String = row.try_get("", "state")?;
    let archived = state == "archived";
    Ok(ObjectRow {
        id: row.try_get("", "id")?,
        key: row.try_get("", "object_key")?,
        archived,
        open: state == "open",
        entry_count: row.try_get::<i64>("", "entry_count")? as u32,
        level_mask: row.try_get::<i32>("", "level_mask")? as u8,
        trace_bloom: row.try_get("", "trace_bloom")?,
        received_at: row.try_get("", "received_at")?,
        scan_bytes: row.try_get::<i64>(
            "",
            if archived {
                "stored_bytes"
            } else {
                "pending_bytes"
            },
        )? as u64,
    })
}

fn to_row(
    epoch: CursorEpoch,
    object: &ObjectRow,
    entry: u32,
    item: &LogEntry,
    record: &LogRecord,
) -> LogRow {
    LogRow {
        cursor: epoch.token(Cursor {
            seq: object.id,
            entry,
        }),
        ts: record.ts,
        level: record.level,
        body: record.body.clone(),
        trace_id: record.trace_id.clone(),
        span_id: record.span_id.clone(),
        attributes: Value::Object(record.attributes.as_map().clone()),
        project_id: item.project.0,
        source_id: item.source.0,
        environment: item.environment.clone(),
    }
}

/// The entries of one object as of the read snapshot.
enum Content {
    Entries(Vec<LogEntry>),
    Missing,
    Corrupt,
}

/// Pending rows captured inside the read transaction for non-archived objects.
type Snapshot = std::collections::HashMap<i64, Vec<PendingRow>>;

async fn capture_pending<C: ConnectionTrait>(
    conn: &C,
    objects: &[ObjectRow],
) -> Result<Snapshot, sea_orm::DbErr> {
    let mut snapshot = Snapshot::new();
    for object in objects.iter().filter(|o| !o.archived) {
        snapshot.insert(
            object.id,
            pending_rows(conn, object.id, object.entry_count).await?,
        );
    }
    Ok(snapshot)
}

async fn content(
    rt: &Runtime,
    org: &OrgId,
    object: &ObjectRow,
    pending: Option<Vec<PendingRow>>,
) -> Result<Content, ApiError> {
    let content = match pending {
        Some(rows) => match open_pending(rt, org, object.id, object.entry_count, rows).await {
            Ok(entries) => Content::Entries(entries),
            Err(_) => Content::Corrupt,
        },
        None => read_object(rt, object).await?,
    };
    let Content::Entries(entries) = content else {
        return Ok(content);
    };
    let limits = record_limits(rt);
    let entries = tokio::task::spawn_blocking(move || sanitized(entries, &limits))
        .await
        .map_err(|_| ApiError::Internal("log record redaction task".into()))?;
    Ok(Content::Entries(entries))
}

/// Applies the current attribute boundary and built-in redaction to stored
/// records, which may predate either. An oversized record stays as stored;
/// reads report it as a gap and never return it.
fn sanitized(mut entries: Vec<LogEntry>, limits: &ParseLimits) -> Vec<LogEntry> {
    for entry in &mut entries {
        if entry.record.approx_bytes() <= limits.max_record_bytes {
            entry.record = entry.record.sanitized(limits);
        }
    }
    entries
}

/// Opens the read transaction with the cursor epoch of its snapshot and
/// refuses reads while a marked restore has not finished its reconciliation.
async fn snapshot_txn(
    handle: &tenant_sqlite_loco::TenantHandle,
) -> ApiResult<(sea_orm::DatabaseTransaction, CursorEpoch)> {
    use sea_orm::TransactionTrait;
    let txn = handle.begin().await?;
    match restore_flag(&txn).await? {
        RestoreFlag::Clear => {}
        RestoreFlag::Required => return Err(ApiError::Unavailable("log_restore_pending")),
        RestoreFlag::Conflict(_) => return Err(ApiError::Unavailable("log_restore_conflict")),
    }
    let epoch = cursor_epoch(&txn).await?;
    Ok((txn, epoch))
}

fn record_limits(rt: &Runtime) -> ParseLimits {
    ParseLimits {
        max_body_bytes: rt.settings.logs.max_body_bytes,
        max_attributes: rt.settings.logs.max_attributes,
        max_attribute_bytes: rt.settings.logs.max_attribute_bytes,
        max_record_bytes: rt.settings.logs.max_record_bytes,
    }
}

async fn read_object(rt: &Runtime, object: &ObjectRow) -> Result<Content, ApiError> {
    let Some(body) = rt
        .store
        .get(&object.key, rt.settings.logs.max_object_bytes)
        .await
        .map_err(|error| ApiError::internal("log object read", error))?
    else {
        return Ok(Content::Missing);
    };
    let max_raw = rt.settings.logs.max_object_bytes + rt.settings.ingest.max_inflated_bytes;
    let decoded = tokio::task::spawn_blocking(move || decode(&body, max_raw))
        .await
        .map_err(|_| ApiError::Internal("log object decode task".into()))?;
    Ok(match decoded {
        Ok((header, entries)) if header.object_id == object.id && header.key == object.key => {
            Content::Entries(entries)
        }
        _ => Content::Corrupt,
    })
}

/// Searches retained logs. `_admitted` is the caller's admission for this
/// organization; a nested read reuses its caller's permit.
pub async fn search(
    rt: &Runtime,
    access: &OrgAccess,
    _admitted: &QueryPermit,
    query: LogQuery,
) -> ApiResult<SearchPage> {
    let budget = &rt.settings.logs.search;
    let filter = Filter::from_query(&query, rt.settings.logs.retention())?;
    let limit = query.limit.unwrap_or(100).clamp(1, budget.max_rows);
    let before_token = query.before.as_deref().map(parse_token).transpose()?;
    let mut conditions = vec![
        "received_at >= ?".to_owned(),
        "max_ts >= ?".to_owned(),
        "min_ts <= ?".to_owned(),
        "(level_mask & ?) != 0".to_owned(),
    ];
    let mut values: Vec<sea_orm::Value> = vec![
        filter.retained_after.into(),
        filter.since.into(),
        filter.until.into(),
        i32::from(filter.levels).into(),
    ];
    for (column, value) in [
        ("project_id", filter.project.map(sea_orm::Value::from)),
        ("source_id", filter.source.map(sea_orm::Value::from)),
        (
            "environment",
            filter.environment.clone().map(sea_orm::Value::from),
        ),
    ] {
        if let Some(value) = value {
            conditions.push(format!(
                "EXISTS (SELECT 1 FROM log_entry_runs r
                    WHERE r.object_id = log_objects.id AND r.{column} = ?)"
            ));
            values.push(value);
        }
    }

    let mut coverage = Coverage {
        reconciling: !rt.quotas.is_ready(&access.org),
        retention_secs: rt.settings.logs.retention_secs,
        ..Coverage::default()
    };
    let mut next: Option<Cursor> = None;
    let mut planned = Vec::new();
    let (snapshot, epoch, before) = {
        let handle = rt.tenant(&access.org).await?;
        let (txn, epoch) = snapshot_txn(&handle).await?;
        let before = before_token.map(|token| epoch.resolve(token)).transpose()?;
        if let Some(before) = before {
            conditions.push("id <= ?".to_owned());
            values.push(before.seq.into());
        }
        values.push((budget.max_objects as i64 + 1).into());
        let rows = txn
            .query_all_raw(sql(
                &format!(
                    "SELECT {OBJECT_COLUMNS} FROM log_objects WHERE {} ORDER BY id DESC LIMIT ?",
                    conditions.join(" AND ")
                ),
                values,
            ))
            .await?;
        let mut objects: Vec<ObjectRow> = rows.iter().map(object_row).collect::<Result<_, _>>()?;
        if objects.len() > budget.max_objects {
            let first_unscanned = objects.remove(budget.max_objects);
            next = Some(Cursor {
                seq: first_unscanned.id,
                entry: OBJECT_END,
            });
            coverage.truncated_by = Some("objects");
        }
        let mut planned_bytes = 0u64;
        for object in objects.into_iter().filter(|o| filter.object_matches(o)) {
            if planned_bytes + object.scan_bytes > budget.max_scan_bytes {
                next = Some(Cursor {
                    seq: object.id,
                    entry: OBJECT_END,
                });
                coverage.truncated_by = Some("bytes");
                break;
            }
            planned_bytes += object.scan_bytes;
            planned.push(object);
        }
        let snapshot = capture_pending(&txn, &planned).await?;
        txn.commit().await?;
        (snapshot, epoch, before)
    };
    let snapshot = std::sync::Mutex::new(snapshot);

    let deadline = Instant::now() + Duration::from_millis(budget.timeout_ms);
    let org = &access.org;
    let mut results = futures::stream::iter(planned.clone())
        .map(|object| {
            let pending = snapshot.lock().expect("snapshot lock").remove(&object.id);
            async move { (content(rt, org, &object, pending).await, object) }
        })
        .buffered(budget.concurrency.max(1));
    let mut out = Vec::new();
    let limits = record_limits(rt);
    let mut output_bytes = 512usize;
    let mut frontier = None;
    loop {
        let item = match tokio::time::timeout_at(deadline, results.next()).await {
            Ok(Some(item)) => item,
            Ok(None) => break,
            Err(_) => {
                coverage.truncated_by = Some("timeout");
                break;
            }
        };
        let (content, object) = item;
        coverage.objects += 1;
        coverage.bytes += object.scan_bytes;
        let entries = match content? {
            Content::Entries(entries) => entries,
            Content::Missing => {
                coverage.missing_objects += 1;
                continue;
            }
            Content::Corrupt => {
                coverage.corrupt_objects += 1;
                continue;
            }
        };
        let mut full = None;
        for (index, item) in entries.iter().enumerate().rev() {
            let cursor = Cursor {
                seq: object.id,
                entry: index as u32,
            };
            if before.is_some_and(|b| cursor >= b) {
                continue;
            }
            if !filter.partition_matches(item) {
                continue;
            }
            let record = &item.record;
            if record.approx_bytes() > limits.max_record_bytes {
                coverage.truncated_by.get_or_insert("record_too_large");
                frontier = Some(cursor);
                continue;
            }
            if !filter.entry_matches(record) {
                frontier = Some(cursor);
                continue;
            }
            if out.len() == limit {
                full = Some("rows");
                break;
            }
            let row = to_row(epoch, &object, index as u32, item, record);
            let size = serialized_bytes(&row).saturating_add(1);
            if size.saturating_add(512) > budget.max_output_bytes {
                coverage.truncated_by.get_or_insert("record_too_large");
                frontier = Some(cursor);
                continue;
            }
            if output_bytes.saturating_add(size) > budget.max_output_bytes {
                full = Some("output_bytes");
                break;
            }
            output_bytes += size;
            out.push(row);
            frontier = Some(cursor);
        }
        if let Some(reason) = full {
            next = frontier;
            coverage.truncated_by = Some(reason);
            break;
        }
    }
    if coverage.truncated_by == Some("timeout") {
        next = planned
            .get(coverage.objects)
            .map(|object| {
                let frontier = Cursor {
                    seq: object.id,
                    entry: OBJECT_END,
                };
                before
                    .filter(|cursor| cursor.seq == object.id)
                    .map_or(frontier, |cursor| cursor.min(frontier))
            })
            .or(next);
    }
    Ok(SearchPage {
        rows: out,
        next: next.map(|cursor| epoch.token(cursor)),
        coverage,
    })
}

#[derive(Debug, Default, Deserialize)]
pub struct TailRequest {
    pub after: Option<String>,
    pub project: Option<i64>,
    pub level: Option<String>,
}

pub enum TailEvent {
    Entries {
        rows: Vec<LogRow>,
        cursor: CursorToken,
    },
    Gap {
        reason: &'static str,
        resume: CursorToken,
    },
    Closing {
        resume: CursorToken,
    },
}

/// Starts a tail stream. The caller resolves `after` from the query or
/// `Last-Event-ID`. Without a cursor the stream starts at the newest object.
pub async fn tail(
    rt: Arc<Runtime>,
    access: OrgAccess,
    request: TailRequest,
) -> ApiResult<impl Stream<Item = TailEvent>> {
    let tail = &rt.settings.logs.tail;
    let slot = rt
        .hub
        .viewer(&access.org, tail.max_viewers, tail.org_max_viewers)
        .ok_or(ApiError::RateLimited {
            retry: Duration::from_secs(5),
            categories: "tail",
        })?;
    let guard = rt
        .gate
        .enter()
        .ok_or(ApiError::Unavailable(if rt.gate.is_open() {
            "server_overloaded"
        } else {
            "shutting_down"
        }))?;
    let levels = match &request.level {
        None => u8::MAX,
        Some(list) => {
            Filter::from_query(
                &LogQuery {
                    level: Some(list.clone()),
                    ..LogQuery::default()
                },
                Duration::ZERO,
            )?
            .levels
        }
    };
    let after = request.after.as_deref().map(parse_token).transpose()?;
    let replay = after
        .map(|_| rt.admission.queries.expensive(&access.org))
        .transpose()?;
    let mut receiver = rt.hub.channel(&access.org)?.tx.subscribe();
    let (epoch, mut last) = latest_cursor(&rt, &access.org).await?;
    if let Some(token) = after {
        last = epoch.resolve(token)?;
    }
    let recheck = Duration::from_secs(tail.access_recheck_secs.max(1));
    Ok(async_stream::stream! {
        let _slot = slot;
        let _guard = guard;
        let mut next_check = Instant::now() + recheck;
        let filter = || Filter::live_only(levels, request.project, rt.settings.logs.retention());
        if let Some(admitted) = replay {
            match catch_up(&rt, &access.org, epoch, last, &filter(), admitted).await {
                Ok((events, cursor)) => { last = cursor; for event in events { yield event; } }
                Err(_) => { yield TailEvent::Closing { resume: epoch.token(last) }; return; }
            }
        }
        loop {
            tokio::select! {
                () = rt.cancel.cancelled() => { yield TailEvent::Closing { resume: epoch.token(last) }; return; }
                () = tokio::time::sleep_until(next_check) => {
                    if authorize(&rt, access.user, &access.org).await.is_err() {
                        yield TailEvent::Closing { resume: epoch.token(last) };
                        return;
                    }
                    next_check = Instant::now() + recheck;
                }
                received = receiver.recv() => {
                    let needs_replay = match received {
                        Ok(published) if published.cursor <= last => false,
                        Ok(_) => true,
                        Err(RecvError::Lagged(_)) => true,
                        Err(RecvError::Closed) => { yield TailEvent::Closing { resume: epoch.token(last) }; return; }
                    };
                    if needs_replay {
                        let Ok(admitted) = rt.admission.queries.live() else {
                            yield TailEvent::Closing { resume: epoch.token(last) };
                            return;
                        };
                        match catch_up(&rt, &access.org, epoch, last, &filter(), admitted).await {
                            Ok((events, cursor)) => { last = cursor; for event in events { yield event; } }
                            Err(_) => { yield TailEvent::Closing { resume: epoch.token(last) }; return; }
                        }
                    }
                }
            }
        }
    })
}

fn last_is_complete(cursor: Cursor) -> bool {
    cursor.entry == OBJECT_END
}

const LATEST_SEQ: &str =
    "SELECT COALESCE((SELECT seq FROM sqlite_sequence WHERE name = 'log_objects'), 0) AS seq";

/// The current cursor epoch and the position after the last committed entry:
/// the newest entry of an open batch, otherwise the end of the newest object
/// id.
async fn latest_cursor(rt: &Runtime, org: &OrgId) -> ApiResult<(CursorEpoch, Cursor)> {
    let handle = rt.tenant(org).await?;
    let (txn, epoch) = snapshot_txn(&handle).await?;
    let seq = txn
        .query_one_raw(sql(LATEST_SEQ, vec![]))
        .await?
        .map(|r| r.try_get::<i64>("", "seq"))
        .transpose()?
        .unwrap_or(0);
    let open = txn
        .query_one_raw(sql(
            "SELECT id, entry_count FROM log_objects WHERE state = 'open'",
            vec![],
        ))
        .await?;
    txn.commit().await?;
    let latest = match open {
        Some(row) if row.try_get::<i64>("", "id")? == seq => Cursor {
            seq,
            entry: (row.try_get::<i64>("", "entry_count")? as u32).saturating_sub(1),
        },
        _ => Cursor {
            seq,
            entry: OBJECT_END,
        },
    };
    Ok((epoch, latest))
}

/// Replays entries after `from`. A stream is bound to the epoch it started
/// in; once a restore changes the epoch its positions mean nothing.
async fn catch_up(
    rt: &Runtime,
    org: &OrgId,
    epoch: CursorEpoch,
    from: Cursor,
    filter: &Filter,
    _admitted: QueryPermit,
) -> ApiResult<(Vec<TailEvent>, Cursor)> {
    let tail = &rt.settings.logs.tail;
    let (latest, mut objects, over_budget, snapshot) = {
        let handle = rt.tenant(org).await?;
        let (txn, current) = snapshot_txn(&handle).await?;
        if current != epoch {
            return Err(ApiError::Conflict("cursor_reset_required"));
        }
        let latest = txn
            .query_one_raw(sql(LATEST_SEQ, vec![]))
            .await?
            .map(|r| r.try_get::<i64>("", "seq"))
            .transpose()?
            .unwrap_or(0);
        let rows = txn
            .query_all_raw(sql(
                &format!(
                    "SELECT {OBJECT_COLUMNS} FROM log_objects WHERE id >= ? ORDER BY id LIMIT ?"
                ),
                vec![from.seq.into(), (tail.replay_max_objects as i64 + 1).into()],
            ))
            .await?;
        let mut objects: Vec<ObjectRow> = rows.iter().map(object_row).collect::<Result<_, _>>()?;
        let over_budget = objects.len() > tail.replay_max_objects;
        objects.truncate(tail.replay_max_objects);
        let snapshot = capture_pending(&txn, &objects).await?;
        txn.commit().await?;
        (latest, objects, over_budget, snapshot)
    };
    let mut snapshot = snapshot;
    let mut events = Vec::new();
    let mut last = from;
    let mut expected = if last_is_complete(from) {
        from.seq + 1
    } else {
        from.seq
    };
    let mut bytes = 0u64;
    let mut output_bytes = 256usize;
    let limits = record_limits(rt);
    let mut budget_hit = over_budget;
    for object in objects.drain(..) {
        if output_bytes.saturating_add(256) > tail.replay_max_output_bytes {
            budget_hit = true;
            break;
        }
        if object.id == from.seq && last_is_complete(from) {
            continue;
        }
        if object.id > expected {
            last = Cursor {
                seq: object.id - 1,
                entry: OBJECT_END,
            };
            events.push(TailEvent::Gap {
                reason: "expired",
                resume: epoch.token(last),
            });
            output_bytes += 128;
        }
        expected = object.id + 1;
        if object.received_at < filter.retained_after {
            last = Cursor {
                seq: object.id,
                entry: OBJECT_END,
            };
            events.push(TailEvent::Gap {
                reason: "expired",
                resume: epoch.token(last),
            });
            output_bytes += 128;
            continue;
        }
        if bytes + object.scan_bytes > tail.replay_max_bytes {
            budget_hit = true;
            break;
        }
        bytes += object.scan_bytes;
        let pending = snapshot.remove(&object.id);
        let entries = match content(rt, org, &object, pending).await? {
            Content::Entries(entries) => entries,
            gone => {
                last = Cursor {
                    seq: object.id,
                    entry: OBJECT_END,
                };
                events.push(TailEvent::Gap {
                    reason: if matches!(gone, Content::Corrupt) {
                        "corrupt"
                    } else {
                        "expired"
                    },
                    resume: epoch.token(last),
                });
                output_bytes += 128;
                continue;
            }
        };
        let start = if object.id == from.seq {
            from.entry.saturating_add(1)
        } else {
            0
        };
        let mut rows = Vec::new();
        let mut expired_entries = false;
        let mut complete = true;
        for (index, item) in entries.iter().enumerate().skip(start as usize) {
            let cursor = Cursor {
                seq: object.id,
                entry: index as u32,
            };
            let record = &item.record;
            if record.rt < filter.retained_after {
                expired_entries = true;
                last = cursor;
                continue;
            }
            let oversized = record.approx_bytes() > limits.max_record_bytes;
            if filter.project.is_none_or(|p| p == item.project.0)
                && (oversized || filter.entry_matches(record))
            {
                let row = to_row(epoch, &object, index as u32, item, record);
                let size = serialized_bytes(&row).saturating_add(128);
                if oversized || size.saturating_add(256) > tail.replay_max_output_bytes {
                    if output_bytes.saturating_add(128) > tail.replay_max_output_bytes {
                        budget_hit = true;
                        complete = false;
                        break;
                    }
                    if !rows.is_empty() {
                        events.push(TailEvent::Entries {
                            rows: std::mem::take(&mut rows),
                            cursor: epoch.token(last),
                        });
                    }
                    last = cursor;
                    events.push(TailEvent::Gap {
                        reason: "record_too_large",
                        resume: epoch.token(last),
                    });
                    output_bytes += 128;
                    continue;
                }
                if output_bytes.saturating_add(size) > tail.replay_max_output_bytes {
                    budget_hit = true;
                    complete = false;
                    break;
                }
                output_bytes += size;
                rows.push(row);
            }
            last = cursor;
        }
        if complete {
            last = if object.open {
                match (entries.len() as u32).checked_sub(1) {
                    Some(newest) if newest >= start => Cursor {
                        seq: object.id,
                        entry: newest,
                    },
                    _ => last,
                }
            } else {
                Cursor {
                    seq: object.id,
                    entry: OBJECT_END,
                }
            };
        }
        if !rows.is_empty() {
            events.push(TailEvent::Entries {
                rows,
                cursor: epoch.token(last),
            });
        }
        if expired_entries {
            events.push(TailEvent::Gap {
                reason: "expired",
                resume: epoch.token(last),
            });
            output_bytes += 128;
        }
        if !complete || object.open {
            break;
        }
    }
    if !budget_hit && latest >= expected {
        last = Cursor {
            seq: latest,
            entry: OBJECT_END,
        };
        events.push(TailEvent::Gap {
            reason: "expired",
            resume: epoch.token(last),
        });
    }
    if budget_hit {
        events.push(TailEvent::Gap {
            reason: "replay_budget",
            resume: epoch.token(last),
        });
    }
    Ok((events, last))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(seq: i64, entry: u32) -> Cursor {
        Cursor { seq, entry }
    }

    #[test]
    fn cursor_tokens_carry_their_epoch_and_have_one_text_form() {
        assert_eq!(
            CursorToken::parse("c1.7.3"),
            Some(CursorEpoch::INITIAL.token(at(7, 3)))
        );
        for (epoch, text) in [
            (CursorEpoch::INITIAL, "c1.1.0"),
            (CursorEpoch(255), "c2.00000000000000ff.1.0"),
        ] {
            let token = epoch.token(at(1, 0));
            assert_eq!(token.to_string(), text);
            assert_eq!(CursorToken::parse(text), Some(token));
        }
        for invalid in [
            "c2.0000000000000000.1.0",
            "c2.00000000000000FF.1.0",
            "c2.000000000000ff.1.0",
            "c2.0ff.1.0",
            "c3.1.0",
            "c1.01.0",
            "c1.1",
            "c1.1.0.0",
        ] {
            assert_eq!(CursorToken::parse(invalid), None, "{invalid}");
        }
        let longest = CursorEpoch(u64::MAX)
            .token(at(i64::MAX, OBJECT_END))
            .to_string();
        assert_eq!(
            longest,
            "c2.ffffffffffffffff.9223372036854775807.4294967295"
        );
        assert_eq!(longest.len(), 50);
    }

    #[test]
    fn an_epoch_resolves_only_its_own_tokens() {
        let restored = CursorEpoch(0x1234);
        assert_eq!(
            restored.resolve(restored.token(at(2, 1))).unwrap(),
            at(2, 1)
        );
        assert!(matches!(
            restored.resolve(CursorEpoch::INITIAL.token(at(2, 1))),
            Err(ApiError::Conflict("cursor_reset_required"))
        ));
        assert!(matches!(
            CursorEpoch::INITIAL.resolve(restored.token(at(2, 1))),
            Err(ApiError::Conflict("cursor_reset_required"))
        ));
        assert_ne!(CursorEpoch::fresh(), CursorEpoch::INITIAL);
        assert_eq!(
            CursorEpoch::from_stored(CursorEpoch(u64::MAX).stored()),
            CursorEpoch(u64::MAX)
        );
    }
}
