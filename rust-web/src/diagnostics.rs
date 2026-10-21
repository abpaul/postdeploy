use sea_orm::ConnectionTrait;
use serde::Serialize;
use serde_json::{json, Value};

use crate::{
    admission::QueryPermit,
    deployments::{self, Deployment},
    domain::now_micros,
    error::{ApiError, ApiResult},
    identity::access::OrgAccess,
    ingest::interfaces,
    issues::{self, EventRef, EventSummary, Issue},
    logs::read::{self, Coverage, Cursor, CursorToken, LogQuery, LogRow},
    runtime::{sql, Runtime},
};

pub const MAX_ISSUES: u32 = 200;
pub const MAX_CONTEXT_LOGS: usize = 50;
pub const MAX_CONTEXT_BYTES: usize = 64 * 1024;
const MAX_CONTEXT_FRAMES: usize = 30;
const MAX_STACK_BYTES: usize = 16 * 1024;
const COUNT_BUDGET: i64 = 100_000;
const MAX_LISTED: i64 = 10;
const MINUTE_US: i64 = 60_000_000;

pub const INTERPRETATION: &str = "Counts compare equal time windows around the deployment. A change in errors after a deployment is a correlation, not proof that the deployment caused it.";

/// A count that stops at a scan budget. `lower_bound` means the true count
/// is at least `value`.
#[derive(Clone, Copy, Debug, Serialize, PartialEq, Eq)]
pub struct Count {
    pub value: i64,
    pub lower_bound: bool,
}

async fn count(
    conn: &impl ConnectionTrait,
    rows: &str,
    values: Vec<sea_orm::Value>,
) -> ApiResult<Count> {
    let mut values = values;
    values.push((COUNT_BUDGET + 1).into());
    let row = conn
        .query_one_raw(sql(
            &format!("SELECT COUNT(*) AS n FROM ({rows} LIMIT ?)"),
            values,
        ))
        .await?
        .ok_or(ApiError::Internal("count".into()))?;
    let n: i64 = row.try_get("", "n")?;
    Ok(Count {
        value: n.min(COUNT_BUDGET),
        lower_bound: n > COUNT_BUDGET,
    })
}

#[derive(Debug, Serialize)]
pub struct Window {
    pub start: i64,
    pub end: i64,
    pub events: Count,
    pub issues: Count,
    pub events_per_minute: f64,
}

#[derive(Debug, Serialize)]
pub struct IssueBrief {
    pub id: i64,
    pub title: String,
    pub level: String,
    pub status: String,
    /// The first receive time, in Unix microseconds.
    pub first_seen: i64,
    pub event_count: i64,
    /// Whether an event of this issue in the after window carries the
    /// deployment's version.
    pub seen_in_version: bool,
}

#[derive(Debug, Serialize)]
pub struct IssuePage {
    pub items: Vec<IssueBrief>,
    pub total: Count,
    /// Pass as `new_after` or `regressed_after` for the next page.
    pub next: Option<i64>,
}

#[derive(Debug, Serialize)]
pub struct ComparisonCoverage {
    /// Error events older than this receive time were deleted by retention.
    pub retained_from: i64,
    pub before_truncated_by_retention: bool,
    pub after_truncated_by_retention: bool,
    /// The deployment is recent, so both windows were shortened to the
    /// elapsed time.
    pub shortened_to_elapsed: bool,
    pub overlapping_deployments: Vec<Deployment>,
    pub overlapping_deployments_truncated: bool,
    pub after_events_without_release: Count,
    pub after_events_other_release: Count,
}

#[derive(Debug, Serialize)]
pub struct Comparison {
    pub deployment: Deployment,
    pub previous: Option<Deployment>,
    pub window_secs: i64,
    pub before: Window,
    pub after: Window,
    /// Issues first received in the after window and within receive retention.
    pub newly_observed: IssuePage,
    /// Issues with an event after the window start that reopened them.
    pub regressed: IssuePage,
    pub coverage: ComparisonCoverage,
    pub interpretation: &'static str,
}

pub struct CompareOptions {
    pub window_secs: Option<i64>,
    pub limit: Option<u32>,
    pub new_after: Option<i64>,
    pub regressed_after: Option<i64>,
}

async fn deployment(conn: &impl ConnectionTrait, id: i64) -> ApiResult<Deployment> {
    let row = conn
        .query_one_raw(sql(
            &format!(
                "SELECT {} FROM deployments WHERE id = ?",
                deployments::COLUMNS
            ),
            vec![id.into()],
        ))
        .await?
        .ok_or(ApiError::NotFound)?;
    Ok(deployments::row(&row)?)
}

async fn deployments_where(
    conn: &impl ConnectionTrait,
    condition: &str,
    values: Vec<sea_orm::Value>,
) -> ApiResult<Vec<Deployment>> {
    let rows = conn
        .query_all_raw(sql(
            &format!(
                "SELECT {} FROM deployments WHERE {condition}",
                deployments::COLUMNS
            ),
            values,
        ))
        .await?;
    Ok(rows
        .iter()
        .map(deployments::row)
        .collect::<Result<_, _>>()?)
}

const WINDOW_EVENTS: &str = "SELECT e.issue_id FROM events e JOIN issues i ON i.id = e.issue_id
    WHERE e.project_id = ? AND i.environment = ? AND e.occurred_at >= ? AND e.occurred_at < ? AND e.received_at >= ?";

async fn window(
    conn: &impl ConnectionTrait,
    at: &Deployment,
    start: i64,
    end: i64,
    cutoff: i64,
) -> ApiResult<Window> {
    let values = || -> Vec<sea_orm::Value> {
        vec![
            at.project_id.into(),
            at.environment.clone().into(),
            start.into(),
            end.into(),
            cutoff.into(),
        ]
    };
    let events = count(conn, WINDOW_EVENTS, values()).await?;
    let issues = count(
        conn,
        &format!("SELECT DISTINCT issue_id FROM ({WINDOW_EVENTS})"),
        values(),
    )
    .await?;
    let minutes = (end - start) as f64 / MINUTE_US as f64;
    let per_minute = if minutes > 0.0 {
        (events.value as f64 / minutes * 1000.0).round() / 1000.0
    } else {
        0.0
    };
    Ok(Window {
        start,
        end,
        events,
        issues,
        events_per_minute: per_minute,
    })
}

struct ReleaseWindow<'a> {
    version: &'a str,
    start: i64,
    end: i64,
    retained_from: i64,
}

async fn issue_page(
    conn: &impl ConnectionTrait,
    matching: &str,
    values: Vec<sea_orm::Value>,
    release: &ReleaseWindow<'_>,
    after: Option<i64>,
    limit: u32,
) -> ApiResult<IssuePage> {
    let total = count(
        conn,
        &format!("SELECT i.id FROM issues i WHERE {matching}"),
        values.clone(),
    )
    .await?;
    let mut page_values = vec![
        release.version.into(),
        release.start.into(),
        release.end.into(),
        release.retained_from.into(),
    ];
    page_values.extend(values);
    page_values.push(after.unwrap_or(0).into());
    page_values.push((i64::from(limit) + 1).into());
    let rows = conn
        .query_all_raw(sql(
            &format!(
                "SELECT i.id, i.title, i.level, i.status, i.first_seen, i.event_count,
                    EXISTS (SELECT 1 FROM events v WHERE v.issue_id = i.id AND v.release = ?
                        AND v.occurred_at >= ? AND v.occurred_at < ? AND v.received_at >= ?) AS seen_in_version
                 FROM issues i WHERE {matching} AND i.id > ? ORDER BY i.id LIMIT ?"
            ),
            page_values,
        ))
        .await?;
    let mut items = rows
        .iter()
        .map(|row| -> Result<IssueBrief, sea_orm::DbErr> {
            Ok(IssueBrief {
                id: row.try_get("", "id")?,
                title: row.try_get("", "title")?,
                level: row.try_get("", "level")?,
                status: row.try_get("", "status")?,
                first_seen: row.try_get("", "first_seen")?,
                event_count: row.try_get("", "event_count")?,
                seen_in_version: row.try_get::<i64>("", "seen_in_version")? == 1,
            })
        })
        .collect::<Result<Vec<_>, _>>()?;
    let next = (items.len() > limit as usize).then(|| {
        items.truncate(limit as usize);
        items.last().map(|i| i.id)
    });
    Ok(IssuePage {
        items,
        total,
        next: next.flatten(),
    })
}

/// Compares equal windows before and after one deployment. A window ends at
/// the next deployment of the same environment only in the coverage notes;
/// the counts always use equal elapsed time on both sides.
pub async fn compare(
    rt: &Runtime,
    access: &OrgAccess,
    _admitted: &QueryPermit,
    id: i64,
    options: CompareOptions,
) -> ApiResult<Comparison> {
    let requested = options.window_secs.unwrap_or(3_600);
    if !(60..=86_400).contains(&requested) {
        return Err(ApiError::BadRequest("invalid_window"));
    }
    let limit = options.limit.unwrap_or(50).clamp(1, MAX_ISSUES);
    let now = now_micros();
    let cutoff = rt.error_retention.event_cutoff(now);
    let handle = rt.tenant(&access.org).await?;
    let conn = &*handle;
    let at = deployment(conn, id).await?;
    let elapsed = (now - at.deployed_at).max(0);
    let width = (requested * 1_000_000).min(elapsed);
    let (start, end) = (at.deployed_at - width, at.deployed_at + width);
    let previous = deployments_where(
        conn,
        "project_id = ? AND environment = ? AND (deployed_at < ? OR (deployed_at = ? AND id < ?))
         ORDER BY deployed_at DESC, id DESC LIMIT 1",
        vec![
            at.project_id.into(),
            at.environment.clone().into(),
            at.deployed_at.into(),
            at.deployed_at.into(),
            at.id.into(),
        ],
    )
    .await?
    .pop();
    let mut overlapping = deployments_where(
        conn,
        "project_id = ? AND environment = ? AND id != ? AND deployed_at > ? AND deployed_at < ?
         ORDER BY deployed_at LIMIT ?",
        vec![
            at.project_id.into(),
            at.environment.clone().into(),
            at.id.into(),
            start.into(),
            end.into(),
            (MAX_LISTED + 1).into(),
        ],
    )
    .await?;
    let overlapping_deployments_truncated = overlapping.len() > MAX_LISTED as usize;
    overlapping.truncate(MAX_LISTED as usize);
    let before = window(conn, &at, start, at.deployed_at, cutoff).await?;
    let after = window(conn, &at, at.deployed_at, end, cutoff).await?;
    let after_values = || -> Vec<sea_orm::Value> {
        vec![
            at.project_id.into(),
            at.environment.clone().into(),
            at.deployed_at.into(),
            end.into(),
            cutoff.into(),
        ]
    };
    let without_release = count(
        conn,
        &format!("{WINDOW_EVENTS} AND e.release IS NULL"),
        after_values(),
    )
    .await?;
    let mut other_values = after_values();
    other_values.push(at.version.clone().into());
    let other_release = count(
        conn,
        &format!("{WINDOW_EVENTS} AND e.release != ?"),
        other_values,
    )
    .await?;
    let scope = || -> Vec<sea_orm::Value> {
        vec![
            at.project_id.into(),
            at.environment.clone().into(),
            at.deployed_at.into(),
            end.into(),
        ]
    };
    let release_window = ReleaseWindow {
        version: &at.version,
        start: at.deployed_at,
        end,
        retained_from: cutoff,
    };
    let mut retained_scope = scope();
    retained_scope.push(cutoff.into());
    let newly_observed = issue_page(
        conn,
        "i.project_id = ? AND i.environment = ? AND i.first_seen >= ? AND i.first_seen < ? AND i.first_seen >= ?",
        retained_scope.clone(),
        &release_window,
        options.new_after,
        limit,
    )
    .await?;
    let regressed = issue_page(
        conn,
        "i.project_id = ? AND i.environment = ? AND EXISTS (SELECT 1 FROM events r
            WHERE r.issue_id = i.id AND r.regression = 1 AND r.occurred_at >= ? AND r.occurred_at < ? AND r.received_at >= ?)",
        retained_scope,
        &release_window,
        options.regressed_after,
        limit,
    )
    .await?;
    drop(handle);
    Ok(Comparison {
        window_secs: width / 1_000_000,
        before,
        after,
        newly_observed,
        regressed,
        coverage: ComparisonCoverage {
            retained_from: cutoff,
            before_truncated_by_retention: start < cutoff,
            after_truncated_by_retention: at.deployed_at < cutoff,
            shortened_to_elapsed: width < requested * 1_000_000,
            overlapping_deployments: overlapping,
            overlapping_deployments_truncated,
            after_events_without_release: without_release,
            after_events_other_release: other_release,
        },
        deployment: at,
        previous,
        interpretation: INTERPRETATION,
    })
}

#[derive(Debug, Serialize)]
pub struct ReleaseCount {
    pub release: Option<String>,
    pub events: i64,
}

#[derive(Debug, Serialize)]
pub struct Recurrence {
    pub issue: Issue,
    /// The latest time the issue was resolved. Null when it was never
    /// resolved or was resolved before resolution times were recorded.
    pub resolved_at: Option<i64>,
    pub events_after_fix: Count,
    pub regression_events: Count,
    pub first_after_fix: Option<i64>,
    pub last_after_fix: Option<i64>,
    /// At most ten releases, most events first.
    pub releases_after_fix: Vec<ReleaseCount>,
    pub releases_truncated: bool,
    /// The deployment active when the issue was resolved.
    pub deployment_at_fix: Option<Deployment>,
    /// At most ten deployments after the fix, oldest first.
    pub deployments_since_fix: Vec<Deployment>,
    pub deployments_truncated: bool,
    pub retained_from: i64,
}

const RECURRENCE_SPAN: &str =
    "SELECT MIN(occurred_at) AS first, MAX(occurred_at) AS last FROM events
     WHERE issue_id = ? AND occurred_at > ? AND received_at >= ?";
const RECURRENCE_RELEASES: &str = "SELECT release, COUNT(*) AS n FROM events
     WHERE issue_id = ? AND occurred_at > ? AND received_at >= ?
     GROUP BY release ORDER BY n DESC, release LIMIT ?";

/// Whether an issue occurred again after its latest resolution. Event times
/// are SDK times; events received after retention removed older events are
/// not counted.
pub async fn recurrence(
    rt: &Runtime,
    access: &OrgAccess,
    _admitted: &QueryPermit,
    issue_id: i64,
) -> ApiResult<Recurrence> {
    let (issue, _) = issues::get(rt, access, issue_id).await?;
    let cutoff = rt.error_retention.event_cutoff(now_micros());
    let empty = Count {
        value: 0,
        lower_bound: false,
    };
    let Some(fixed) = issue.resolved_at else {
        return Ok(Recurrence {
            issue,
            resolved_at: None,
            events_after_fix: empty,
            regression_events: empty,
            first_after_fix: None,
            last_after_fix: None,
            releases_after_fix: Vec::new(),
            releases_truncated: false,
            deployment_at_fix: None,
            deployments_since_fix: Vec::new(),
            deployments_truncated: false,
            retained_from: cutoff,
        });
    };
    let handle = rt.tenant(&access.org).await?;
    let conn = &*handle;
    let after = || -> Vec<sea_orm::Value> { vec![issue.id.into(), fixed.into(), cutoff.into()] };
    let after_fix =
        "SELECT id FROM events WHERE issue_id = ? AND occurred_at > ? AND received_at >= ?";
    let events_after_fix = count(conn, after_fix, after()).await?;
    let regression_events =
        count(conn, &format!("{after_fix} AND regression = 1"), after()).await?;
    let span = conn
        .query_one_raw(sql(RECURRENCE_SPAN, after()))
        .await?
        .ok_or(ApiError::Internal("recurrence span".into()))?;
    let mut release_values = after();
    release_values.push((MAX_LISTED + 1).into());
    let mut releases = conn
        .query_all_raw(sql(RECURRENCE_RELEASES, release_values))
        .await?
        .iter()
        .map(|row| -> Result<ReleaseCount, sea_orm::DbErr> {
            Ok(ReleaseCount {
                release: row.try_get("", "release")?,
                events: row.try_get("", "n")?,
            })
        })
        .collect::<Result<Vec<_>, _>>()?;
    let releases_truncated = releases.len() > MAX_LISTED as usize;
    releases.truncate(MAX_LISTED as usize);
    let environment = || -> Vec<sea_orm::Value> {
        vec![
            issue.project_id.into(),
            issue.environment.clone().into(),
            fixed.into(),
        ]
    };
    let deployment_at_fix = deployments_where(
        conn,
        "project_id = ? AND environment = ? AND deployed_at <= ? ORDER BY deployed_at DESC, id DESC LIMIT 1",
        environment(),
    )
    .await?
    .pop();
    let mut since_values = environment();
    since_values.push((MAX_LISTED + 1).into());
    let mut deployments_since_fix = deployments_where(
        conn,
        "project_id = ? AND environment = ? AND deployed_at > ? ORDER BY deployed_at, id LIMIT ?",
        since_values,
    )
    .await?;
    let deployments_truncated = deployments_since_fix.len() > MAX_LISTED as usize;
    deployments_since_fix.truncate(MAX_LISTED as usize);
    drop(handle);
    Ok(Recurrence {
        resolved_at: Some(fixed),
        events_after_fix,
        regression_events,
        first_after_fix: span.try_get("", "first")?,
        last_after_fix: span.try_get("", "last")?,
        releases_after_fix: releases,
        releases_truncated,
        deployment_at_fix,
        deployments_since_fix,
        deployments_truncated,
        retained_from: cutoff,
        issue,
    })
}

#[derive(Clone, Copy, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum MatchedBy {
    TraceId,
    RequestId,
    Time,
}

#[derive(Debug, Serialize)]
pub struct ContextFilters {
    pub project_id: i64,
    pub environment: String,
    pub since: i64,
    pub until: i64,
    pub trace_id: Option<String>,
    pub request_id: Option<String>,
    pub service: Option<String>,
    pub release: Option<String>,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Payload {
    Stored,
    /// The event is indexed but its stored payload could not be found.
    Missing,
}

#[derive(Debug, Serialize)]
pub struct ContextCoverage {
    pub payload: Payload,
    pub stack_truncated: bool,
    /// `truncated_by` is `output_bytes` when entries were left out to keep
    /// the response within 64 KiB.
    pub logs: Coverage,
}

#[derive(Serialize)]
pub struct ErrorContext {
    pub issue: Issue,
    pub event: EventSummary,
    /// Exception type, value and up to 30 frames, innermost call first.
    pub stack: Value,
    /// The latest deployment of this environment at or before the event.
    pub deployment: Option<Deployment>,
    pub matched_by: MatchedBy,
    pub filters: ContextFilters,
    pub logs: Vec<LogRow>,
    /// Pass as `before` to search_logs with the same filters for older entries.
    pub next: Option<CursorToken>,
    pub coverage: ContextCoverage,
}

pub struct ContextOptions {
    pub event: Option<EventRef>,
    pub window_secs: Option<i64>,
    pub limit: Option<usize>,
}

fn stack_text(value: Option<&Value>, max_bytes: usize, truncated: &mut bool) -> Value {
    let Some(text) = value.and_then(Value::as_str) else {
        return Value::Null;
    };
    if text.len() <= max_bytes {
        return Value::String(text.to_owned());
    }
    *truncated = true;
    let mut end = max_bytes;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    Value::String(text[..end].to_owned())
}

fn stack(payload: &Value) -> ApiResult<(Value, bool)> {
    let exceptions = interfaces::values(payload, "exception");
    let outer = exceptions
        .iter()
        .rev()
        .find(|e| !interfaces::frames(e).is_empty())
        .or(exceptions.last());
    let primary = interfaces::primary_frames(payload);
    if outer.is_none() && primary.is_empty() {
        return Ok((Value::Null, false));
    }
    let mut max_text_bytes = 1_024;
    loop {
        let mut truncated = primary.len() > MAX_CONTEXT_FRAMES;
        let frames: Vec<Value> = primary
            .iter()
            .rev()
            .take(MAX_CONTEXT_FRAMES)
            .map(|frame| {
                json!({
                    "function": stack_text(frame.get("function"), max_text_bytes, &mut truncated),
                    "filename": stack_text(frame.get("filename").or_else(|| frame.get("abs_path")), max_text_bytes, &mut truncated),
                    "lineno": frame.get("lineno").and_then(Value::as_u64),
                    "in_app": frame.get("in_app").and_then(Value::as_bool),
                })
            })
            .collect();
        let stack = json!({
            "type": stack_text(outer.and_then(|e| e.get("type")), max_text_bytes, &mut truncated),
            "value": stack_text(outer.and_then(|e| e.get("value")), max_text_bytes, &mut truncated),
            "frames": frames,
        });
        if serde_json::to_vec(&stack)
            .map_err(|error| ApiError::internal("stack encode", error))?
            .len()
            <= MAX_STACK_BYTES
        {
            return Ok((stack, truncated));
        }
        max_text_bytes /= 2;
    }
}

/// Logs selected for one event, with the filters that chose them.
#[derive(Serialize)]
pub struct CorrelatedLogs {
    pub matched_by: MatchedBy,
    pub filters: ContextFilters,
    pub rows: Vec<LogRow>,
    /// Pass as `before` to search_logs with the same filters for older entries.
    pub next: Option<CursorToken>,
    pub coverage: Coverage,
}

/// Logs around `event`, matched by trace ID, else request ID, else by time
/// with the event's service and release. A failed identifier match returns
/// no logs; it never widens to unrelated entries.
pub async fn correlated_logs(
    rt: &Runtime,
    access: &OrgAccess,
    admitted: &QueryPermit,
    issue: &Issue,
    event: &EventSummary,
    window_secs: i64,
    limit: usize,
) -> ApiResult<CorrelatedLogs> {
    let (matched_by, trace_id, request_id, service, release) =
        match (&event.trace_id, &event.request_id) {
            (Some(trace), _) => (MatchedBy::TraceId, Some(trace.clone()), None, None, None),
            (None, Some(request)) => (
                MatchedBy::RequestId,
                None,
                Some(request.clone()),
                None,
                None,
            ),
            (None, None) => (
                MatchedBy::Time,
                None,
                None,
                event.service.clone(),
                event.release.clone(),
            ),
        };
    let filters = ContextFilters {
        project_id: issue.project_id,
        environment: issue.environment.clone(),
        since: event.occurred_at.saturating_sub(window_secs * 1_000_000),
        until: event.occurred_at.saturating_add(window_secs * 1_000_000),
        trace_id,
        request_id,
        service,
        release,
    };
    let page = read::search(
        rt,
        access,
        admitted,
        LogQuery {
            project: Some(filters.project_id),
            environment: Some(filters.environment.clone()),
            trace_id: filters.trace_id.clone(),
            request_id: filters.request_id.clone(),
            service: filters.service.clone(),
            release: filters.release.clone(),
            since: Some(filters.since),
            until: Some(filters.until),
            limit: Some(limit.clamp(1, MAX_CONTEXT_LOGS)),
            ..LogQuery::default()
        },
    )
    .await?;
    Ok(CorrelatedLogs {
        matched_by,
        filters,
        rows: page.rows,
        next: page.next,
        coverage: page.coverage,
    })
}

/// The latest deployment of the issue's environment at or before `at`.
pub async fn deployment_at(
    rt: &Runtime,
    access: &OrgAccess,
    issue: &Issue,
    at: i64,
) -> ApiResult<Option<Deployment>> {
    let handle = rt.tenant(&access.org).await?;
    let found = deployments_where(
        &*handle,
        "project_id = ? AND environment = ? AND deployed_at <= ? ORDER BY deployed_at DESC, id DESC LIMIT 1",
        vec![issue.project_id.into(), issue.environment.clone().into(), at.into()],
    )
    .await?
    .pop();
    drop(handle);
    Ok(found)
}

/// One event with its stack, its deployment and a bounded page of
/// correlated logs, within 64 KiB.
pub async fn error_context(
    rt: &Runtime,
    access: &OrgAccess,
    admitted: &QueryPermit,
    issue_id: i64,
    options: ContextOptions,
) -> ApiResult<ErrorContext> {
    let window = options.window_secs.unwrap_or(300);
    if !(1..=3_600).contains(&window) {
        return Err(ApiError::BadRequest("invalid_window"));
    }
    let limit = options.limit.unwrap_or(MAX_CONTEXT_LOGS);
    let (issue, latest) = issues::get(rt, access, issue_id).await?;
    let selector = match options.event {
        Some(selector) => selector,
        None => {
            let latest = latest.ok_or(ApiError::NotFound)?;
            EventRef {
                event_id: latest.event_id,
                source: Some(latest.source_id),
            }
        }
    };
    let event = issues::event_summary(rt, access, issue.id, &selector).await?;
    let selector = EventRef {
        source: Some(event.source_id),
        ..selector
    };
    let (payload, stack, stack_truncated) =
        match issues::event_payload(rt, access, issue.id, &selector).await {
            Ok((_, payload)) => {
                let (stack, truncated) = stack(&payload)?;
                (Payload::Stored, stack, truncated)
            }
            Err(ApiError::NotFound) => (Payload::Missing, Value::Null, false),
            Err(error) => return Err(error),
        };
    let deployment = deployment_at(rt, access, &issue, event.occurred_at).await?;
    let logs = correlated_logs(rt, access, admitted, &issue, &event, window, limit).await?;
    let mut context = ErrorContext {
        issue,
        event,
        stack,
        deployment,
        matched_by: logs.matched_by,
        filters: logs.filters,
        logs: logs.rows,
        next: logs.next,
        coverage: ContextCoverage {
            payload,
            stack_truncated,
            logs: logs.coverage,
        },
    };
    while serde_json::to_vec(&context)
        .map_err(|error| ApiError::internal("context encode", error))?
        .len()
        > MAX_CONTEXT_BYTES
    {
        let Some(dropped) = context.logs.pop() else {
            return Err(ApiError::Internal(
                "context metadata exceeds output limit".into(),
            ));
        };
        let dropped = dropped.cursor;
        context.next = Some(dropped.epoch.token(Cursor {
            seq: dropped.at.seq,
            entry: dropped.at.entry.saturating_add(1),
        }));
        context.coverage.logs.truncated_by = Some("output_bytes");
    }
    Ok(context)
}

#[cfg(test)]
mod tests {
    use migration::MigratorTrait;
    use sea_orm::ConnectionTrait;

    use crate::runtime::sql;

    #[tokio::test]
    async fn recurrence_queries_seek_events_after_the_fix() {
        let db = sea_orm::Database::connect("sqlite::memory:").await.unwrap();
        migration::OrgMigrator::up(&db, None).await.unwrap();
        let mut plans = Vec::new();
        for (query, values) in [
            (super::RECURRENCE_SPAN, vec![1.into(), 2.into(), 3.into()]),
            (
                super::RECURRENCE_RELEASES,
                vec![1.into(), 2.into(), 3.into(), 11.into()],
            ),
        ] {
            let plan: Vec<String> = db
                .query_all_raw(sql(&format!("EXPLAIN QUERY PLAN {query}"), values))
                .await
                .unwrap()
                .iter()
                .map(|row| row.try_get::<String>("", "detail").unwrap())
                .filter(|detail| detail.starts_with("SEARCH") || detail.starts_with("SCAN"))
                .collect();
            plans.push(plan);
        }
        assert_eq!(
            plans,
            [
                vec!["SEARCH events USING INDEX events_issue_occurred (issue_id=? AND occurred_at>?)"],
                vec!["SEARCH events USING INDEX events_issue_occurred (issue_id=? AND occurred_at>?)"],
            ]
        );
    }
}
