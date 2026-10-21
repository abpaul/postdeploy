//! Error events and grouped issues. Full scrubbed payloads live in R2; the
//! tenant database keeps compact issue fields, event identity and usage.

use sea_orm::{ConnectionTrait, TransactionTrait};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::{
    domain::{now_micros, utc_day, Environment, OrgId, ProjectId, SourceId},
    error::{ApiError, ApiResult},
    identity::access::OrgAccess,
    ingest::event::ErrorEvent,
    quota::{add_usage, month_usage},
    runtime::{sql, Runtime},
};

#[derive(Debug, PartialEq, Eq)]
pub enum Committed {
    New { issue: i64, regression: bool },
    Duplicate,
    QuotaExceeded,
    MonthlyQuotaExceeded,
}

/// The only commit failure whose outcome is unknown. Every other error leaves
/// the tenant database unchanged.
pub const COMMIT_UNCERTAIN: &str = "error_commit_uncertain";

pub struct EventSource<'a> {
    pub org: &'a OrgId,
    pub project: ProjectId,
    pub source: SourceId,
    pub environment: &'a Environment,
}

/// Uploads the payload, then records the event, issue and usage in one tenant
/// transaction. A retried event id is detected before the upload and again by
/// the unique constraint.
pub async fn commit(
    rt: &Runtime,
    at: &EventSource<'_>,
    event: ErrorEvent,
    received: i64,
) -> ApiResult<Committed> {
    let existing = {
        let handle = rt.tenant(at.org).await?;
        let row = handle
            .query_one_raw(sql(
                "SELECT 1 AS found FROM events WHERE source_id = ? AND event_id = ?",
                vec![at.source.0.into(), event.event_id.clone().into()],
            ))
            .await?;
        row.is_some()
    };
    if existing {
        return Ok(Committed::Duplicate);
    }
    let day = utc_day(received);
    let key = format!(
        "errors/v1/{}/{}/{}/{}/{}-{}.json.zst",
        at.org,
        at.project.0,
        at.source.0,
        day,
        event.event_id,
        uuid::Uuid::now_v7().simple()
    );
    let payload = event.payload;
    let compressed = tokio::task::spawn_blocking(move || zstd::stream::encode_all(&payload[..], 3))
        .await
        .map_err(|_| ApiError::Internal("payload compression task".into()))?
        .map_err(|_| ApiError::Internal("payload compression".into()))?;
    let payload_bytes = compressed.len() as i64;
    let _pending = rt.store.pending(&key);
    rt.store
        .put(&key, compressed.into())
        .await
        .map_err(|_| ApiError::Unavailable("store_unavailable"))?;

    let recorded = async {
        let _usage_write = rt.quotas.write(at.org).await?;
        let handle = rt.tenant(at.org).await?;
        let txn = handle.begin().await?;
        let issue = txn
            .query_one_raw(sql(
                "INSERT INTO issues (project_id, environment, fingerprint, title, culprit, level, status,
                    first_seen, last_seen, event_count, last_release)
                 VALUES (?, ?, ?, ?, ?, ?, 'open', ?, ?, 0, ?)
                 ON CONFLICT (project_id, environment, fingerprint) DO UPDATE SET event_count = event_count
                 RETURNING id, status, event_count, resolved_at",
                vec![
                    at.project.0.into(),
                    at.environment.as_str().into(),
                    event.fingerprint.clone().into(),
                    event.title.clone().into(),
                    event.culprit.clone().into(),
                    event.level.into(),
                    received.into(),
                    received.into(),
                    event.release.clone().into(),
                ],
            ))
            .await?
            .ok_or(ApiError::Internal("issue upsert".into()))?;
        let issue_id: i64 = issue.try_get("", "id")?;
        let status: String = issue.try_get("", "status")?;
        let resolved_at: Option<i64> = issue.try_get("", "resolved_at")?;
        let new_issue = issue.try_get::<i64>("", "event_count")? == 0;
        let regression = status == "resolved"
            && resolved_at.is_none_or(|fixed| event.occurred_us > fixed);
        let inserted = txn
            .execute_raw(sql(
                "INSERT INTO events (issue_id, project_id, source_id, event_id, level, release, trace_id,
                    request_id, service, regression, occurred_at, received_at, payload_key, payload_bytes)
                 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT (source_id, event_id) DO NOTHING",
                vec![
                    issue_id.into(),
                    at.project.0.into(),
                    at.source.0.into(),
                    event.event_id.clone().into(),
                    event.level.into(),
                    event.release.clone().into(),
                    event.trace_id.clone().into(),
                    event.request_id.clone().into(),
                    event.service.clone().into(),
                    i64::from(regression).into(),
                    event.occurred_us.into(),
                    received.into(),
                    key.clone().into(),
                    payload_bytes.into(),
                ],
            ))
            .await?;
        if inserted.rows_affected() == 0 {
            txn.rollback().await?;
            drop(handle);
            return Ok(Committed::Duplicate);
        }
        let month_errors = month_usage(&txn, &day).await?.errors;
        if month_errors >= crate::billing::MONTHLY_ERRORS {
            txn.rollback().await?;
            drop(handle);
            return Ok(Committed::MonthlyQuotaExceeded);
        }
        let used = txn.query_one_raw(sql("SELECT accepted FROM usage_daily WHERE day = ? AND category = 'error'", vec![day.clone().into()])).await?;
        let accepted = used.map(|row| row.try_get::<i64>("", "accepted")).transpose()?.unwrap_or(0);
        if u64::try_from(accepted).map_err(|error| ApiError::internal("error usage count", error))? >= rt.settings.quotas.daily_errors {
            txn.rollback().await?;
            drop(handle);
            return Ok(Committed::QuotaExceeded);
        }
        txn.execute_raw(sql(
            "UPDATE issues SET event_count = event_count + 1,
                first_seen = MIN(first_seen, ?1), last_seen = MAX(last_seen, ?1),
                last_release = CASE WHEN ?1 >= last_seen THEN COALESCE(?2, last_release) ELSE last_release END,
                title = CASE WHEN ?1 >= last_seen THEN ?3 ELSE title END,
                level = CASE WHEN ?1 >= last_seen THEN ?4 ELSE level END,
                status = CASE WHEN ?5 THEN 'open' ELSE status END,
                regressed_at = CASE WHEN ?5 THEN ?1 ELSE regressed_at END
             WHERE id = ?6",
            vec![
                received.into(),
                event.release.into(),
                event.title.into(),
                event.level.into(),
                regression.into(),
                issue_id.into(),
            ],
        ))
        .await?;
        add_usage(&txn, &day, "error", 1, payload_bytes as u64).await?;
        crate::billing::alerts::record(&txn, &day, crate::billing::alerts::Metric::Errors, month_errors + 1).await?;
        let notice = if new_issue {
            Some(crate::notifications::Notice::NewIssue {
                project: at.project,
                issue: issue_id,
            })
        } else if regression {
            Some(crate::notifications::Notice::Regression {
                project: at.project,
                issue: issue_id,
                at: received,
            })
        } else {
            None
        };
        if let Some(notice) = notice {
            let notifications = rt
                .notifications
                .get()
                .ok_or_else(|| ApiError::Internal("notification service is missing".into()))?;
            notifications.enqueue(&txn, at.org, &notice).await;
        }
        txn.commit().await.map_err(|error| {
            tracing::error!(%error, "error event commit outcome is unknown");
            ApiError::Unavailable(COMMIT_UNCERTAIN)
        })?;
        drop(handle);
        if rt.faults().is_some_and(|faults| crate::store::Faults::take(&faults.fail_error_after_commit)) {
            return Err(ApiError::Unavailable(COMMIT_UNCERTAIN));
        }
        Ok(Committed::New {
            issue: issue_id,
            regression,
        })
    }.await;
    if !matches!(&recorded, Ok(Committed::New { .. })) {
        crate::orphan_retention::discard(
            &rt.control,
            &rt.tenants,
            &rt.store,
            at.org,
            crate::orphan_retention::ObjectKind::Error,
            &key,
        )
        .await;
    }
    recorded
}

#[derive(Debug, Serialize)]
pub struct Issue {
    pub id: i64,
    pub project_id: i64,
    pub environment: String,
    pub title: String,
    pub culprit: Option<String>,
    pub level: String,
    pub status: String,
    pub first_seen: i64,
    pub last_seen: i64,
    pub event_count: i64,
    pub last_release: Option<String>,
    pub regressed_at: Option<i64>,
    /// The latest time the issue was set to resolved. Kept after it reopens.
    pub resolved_at: Option<i64>,
}

#[derive(Debug, Serialize)]
pub struct EventSummary {
    pub event_id: String,
    pub source_id: i64,
    pub level: String,
    pub release: Option<String>,
    pub trace_id: Option<String>,
    pub request_id: Option<String>,
    pub service: Option<String>,
    /// Whether this event reopened a resolved issue. Unknown for events
    /// stored before regressions were recorded.
    pub regression: Option<bool>,
    pub occurred_at: i64,
    pub received_at: i64,
}

/// Selects one stored event. `event_id` is unique per source only, so a
/// selector without a source fails with `ambiguous_event` when two sources
/// stored the same ID.
#[derive(Clone, Debug)]
pub struct EventRef {
    pub event_id: String,
    pub source: Option<i64>,
}

#[derive(Debug, Default, Deserialize)]
pub struct IssueQuery {
    pub project: Option<i64>,
    pub status: Option<String>,
    pub limit: Option<u32>,
    pub before: Option<IssueCursor>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct IssueCursor {
    last_seen: i64,
    id: i64,
}

impl IssueCursor {
    pub fn parse(value: &str) -> Option<Self> {
        let mut parts = value.strip_prefix("i1.")?.split('.');
        let last_seen = parts.next()?;
        let id = parts.next()?;
        if parts.next().is_some()
            || last_seen.is_empty()
            || id.is_empty()
            || !last_seen.bytes().all(|b| b.is_ascii_digit())
            || !id.bytes().all(|b| b.is_ascii_digit())
        {
            return None;
        }
        let cursor = Self {
            last_seen: last_seen.parse().ok()?,
            id: id.parse().ok()?,
        };
        (cursor.id > 0).then_some(cursor)
    }
}

impl std::fmt::Display for IssueCursor {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "i1.{}.{}", self.last_seen, self.id)
    }
}

impl Serialize for IssueCursor {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.collect_str(self)
    }
}

impl<'de> Deserialize<'de> for IssueCursor {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Self::parse(&String::deserialize(deserializer)?)
            .ok_or_else(|| serde::de::Error::custom("invalid issue cursor"))
    }
}

const ISSUE_COLUMNS: &str = "id, project_id, environment, title, culprit, level, status, first_seen, last_seen, event_count, last_release, regressed_at, resolved_at";
pub(crate) const EVENT_COLUMNS: &str = "event_id, source_id, level, release, trace_id, request_id, service, regression, occurred_at, received_at";

fn issue_row(row: &sea_orm::QueryResult) -> Result<Issue, sea_orm::DbErr> {
    Ok(Issue {
        id: row.try_get("", "id")?,
        project_id: row.try_get("", "project_id")?,
        environment: row.try_get("", "environment")?,
        title: row.try_get("", "title")?,
        culprit: row.try_get("", "culprit")?,
        level: row.try_get("", "level")?,
        status: row.try_get("", "status")?,
        first_seen: row.try_get("", "first_seen")?,
        last_seen: row.try_get("", "last_seen")?,
        event_count: row.try_get("", "event_count")?,
        last_release: row.try_get("", "last_release")?,
        regressed_at: row.try_get("", "regressed_at")?,
        resolved_at: row.try_get("", "resolved_at")?,
    })
}

pub(crate) fn event_row(row: &sea_orm::QueryResult) -> Result<EventSummary, sea_orm::DbErr> {
    Ok(EventSummary {
        event_id: row.try_get("", "event_id")?,
        source_id: row.try_get("", "source_id")?,
        level: row.try_get("", "level")?,
        release: row.try_get("", "release")?,
        trace_id: row.try_get("", "trace_id")?,
        request_id: row.try_get("", "request_id")?,
        service: row.try_get("", "service")?,
        regression: row
            .try_get::<Option<i64>>("", "regression")?
            .map(|flag| flag == 1),
        occurred_at: row.try_get("", "occurred_at")?,
        received_at: row.try_get("", "received_at")?,
    })
}

fn valid_status(status: &str) -> ApiResult<&str> {
    matches!(status, "open" | "resolved" | "ignored")
        .then_some(status)
        .ok_or(ApiError::BadRequest("invalid_status"))
}

/// Newest activity first. `next` is the `before` value for the following page.
pub async fn list(
    rt: &Runtime,
    access: &OrgAccess,
    query: IssueQuery,
) -> ApiResult<(Vec<Issue>, Option<IssueCursor>)> {
    let limit = query.limit.unwrap_or(50).clamp(1, 200);
    let mut conditions = vec!["last_seen >= ?"];
    let mut values: Vec<sea_orm::Value> =
        vec![rt.error_retention.event_cutoff(now_micros()).into()];
    if let Some(cursor) = query.before {
        conditions.push("(last_seen < ? OR (last_seen = ? AND id < ?))");
        values.extend([
            cursor.last_seen.into(),
            cursor.last_seen.into(),
            cursor.id.into(),
        ]);
    }
    if let Some(project) = query.project {
        conditions.push("project_id = ?");
        values.push(project.into());
    }
    if let Some(status) = &query.status {
        conditions.push("status = ?");
        values.push(valid_status(status)?.into());
    }
    values.push((i64::from(limit) + 1).into());
    let handle = rt.tenant(&access.org).await?;
    let rows = handle
        .query_all_raw(sql(
            &format!("SELECT {ISSUE_COLUMNS} FROM issues WHERE {} ORDER BY last_seen DESC, id DESC LIMIT ?", conditions.join(" AND ")),
            values,
        ))
        .await?;
    drop(handle);
    let mut issues: Vec<Issue> = rows.iter().map(issue_row).collect::<Result<_, _>>()?;
    let next = (issues.len() > limit as usize).then(|| {
        issues.truncate(limit as usize);
        issues.last().map(|i| IssueCursor {
            last_seen: i.last_seen,
            id: i.id,
        })
    });
    Ok((issues, next.flatten()))
}

pub async fn get(
    rt: &Runtime,
    access: &OrgAccess,
    id: i64,
) -> ApiResult<(Issue, Option<EventSummary>)> {
    let handle = rt.tenant(&access.org).await?;
    let cutoff = rt.error_retention.event_cutoff(now_micros());
    let issue = handle
        .query_one_raw(sql(
            &format!("SELECT {ISSUE_COLUMNS} FROM issues WHERE id = ? AND last_seen >= ?"),
            vec![id.into(), cutoff.into()],
        ))
        .await?
        .ok_or(ApiError::NotFound)?;
    let latest = handle
        .query_one_raw(sql(
            &format!(
                "SELECT {EVENT_COLUMNS} FROM events
             WHERE issue_id = ? AND received_at >= ? ORDER BY received_at DESC, id DESC LIMIT 1"
            ),
            vec![id.into(), cutoff.into()],
        ))
        .await?;
    drop(handle);
    Ok((
        issue_row(&issue)?,
        latest.as_ref().map(event_row).transpose()?,
    ))
}

pub async fn set_status(
    rt: &Runtime,
    access: &OrgAccess,
    id: i64,
    status: &str,
) -> ApiResult<Issue> {
    access.require_manage()?;
    let status = valid_status(status)?;
    let handle = rt.tenant(&access.org).await?;
    let row = handle
        .query_one_raw(sql(
            &format!(
                "UPDATE issues SET status = ?1,
                    resolved_at = CASE WHEN ?1 = 'resolved' AND status != 'resolved' THEN ?2 ELSE resolved_at END
                 WHERE id = ?3 AND last_seen >= ?4 RETURNING {ISSUE_COLUMNS}"
            ),
            vec![
                status.into(),
                now_micros().into(),
                id.into(),
                rt.error_retention.event_cutoff(now_micros()).into(),
            ],
        ))
        .await?
        .ok_or(ApiError::NotFound)?;
    drop(handle);
    Ok(issue_row(&row)?)
}

pub async fn events(
    rt: &Runtime,
    access: &OrgAccess,
    issue: i64,
    limit: Option<u32>,
) -> ApiResult<Vec<EventSummary>> {
    let handle = rt.tenant(&access.org).await?;
    let rows = handle
        .query_all_raw(sql(
            &format!(
                "SELECT {EVENT_COLUMNS} FROM events
             WHERE issue_id = ? AND received_at >= ? ORDER BY received_at DESC, id DESC LIMIT ?"
            ),
            vec![
                issue.into(),
                rt.error_retention.event_cutoff(now_micros()).into(),
                i64::from(limit.unwrap_or(50).clamp(1, 200)).into(),
            ],
        ))
        .await?;
    drop(handle);
    Ok(rows.iter().map(event_row).collect::<Result<_, _>>()?)
}

fn find_event_query(by_source: bool) -> String {
    let source = if by_source { " AND source_id = ?" } else { "" };
    format!(
        "SELECT {EVENT_COLUMNS}, project_id, payload_key, payload_bytes FROM events
         WHERE issue_id = ? AND event_id = ? AND received_at >= ?{source} LIMIT 2"
    )
}

pub(crate) async fn find_event(
    conn: &impl ConnectionTrait,
    issue: i64,
    event: &EventRef,
    cutoff: i64,
) -> ApiResult<sea_orm::QueryResult> {
    let event_id =
        crate::ingest::envelope::normalize_event_id(&event.event_id).ok_or(ApiError::NotFound)?;
    let mut values: Vec<sea_orm::Value> = vec![issue.into(), event_id.into(), cutoff.into()];
    if let Some(source) = event.source {
        values.push(source.into());
    }
    let mut rows = conn
        .query_all_raw(sql(&find_event_query(event.source.is_some()), values))
        .await?;
    match rows.len() {
        0 => Err(ApiError::NotFound),
        1 => Ok(rows.remove(0)),
        _ => Err(ApiError::Conflict("ambiguous_event")),
    }
}

pub async fn event_summary(
    rt: &Runtime,
    access: &OrgAccess,
    issue: i64,
    event: &EventRef,
) -> ApiResult<EventSummary> {
    let handle = rt.tenant(&access.org).await?;
    let row = find_event(
        &*handle,
        issue,
        event,
        rt.error_retention.event_cutoff(now_micros()),
    )
    .await?;
    drop(handle);
    Ok(event_row(&row)?)
}

pub async fn event_payload(
    rt: &Runtime,
    access: &OrgAccess,
    issue: i64,
    event: &EventRef,
) -> ApiResult<(EventSummary, Value)> {
    let handle = rt.tenant(&access.org).await?;
    let row = find_event(
        &*handle,
        issue,
        event,
        rt.error_retention.event_cutoff(now_micros()),
    )
    .await?;
    drop(handle);
    let key: String = row.try_get("", "payload_key")?;
    let max = rt.settings.ingest.max_event_bytes;
    let compressed_limit = max.saturating_add(max / 8).saturating_add(1_024);
    let stored_bytes = usize::try_from(row.try_get::<i64>("", "payload_bytes")?)
        .ok()
        .filter(|bytes| *bytes > 0 && *bytes <= compressed_limit)
        .ok_or_else(|| ApiError::Internal("stored payload size failed validation".into()))?;
    let body = rt
        .store
        .get(&key, stored_bytes)
        .await
        .map_err(|_| ApiError::Unavailable("store_unavailable"))?
        .ok_or(ApiError::NotFound)?;
    let payload = tokio::task::spawn_blocking(move || {
        let mut raw = Vec::new();
        std::io::Read::read_to_end(
            &mut std::io::Read::take(zstd::stream::read::Decoder::new(&body[..])?, max as u64 + 1),
            &mut raw,
        )?;
        if raw.len() > max {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "stored payload exceeds limit",
            ));
        }
        Ok::<_, std::io::Error>(raw)
    })
    .await
    .map_err(|_| ApiError::Internal("payload decode task".into()))?
    .map_err(|_| ApiError::Internal("stored payload failed validation".into()))?;
    let mut payload: Value = serde_json::from_slice(&payload)
        .map_err(|_| ApiError::Internal("stored payload failed validation".into()))?;
    let project = ProjectId(row.try_get("", "project_id")?);
    let symbolicated = rt.releases.symbolicate(access, project, &payload).await?;
    if let Some(object) = payload.as_object_mut() {
        object.insert(
            "postdeploy_symbolicated".to_owned(),
            serde_json::to_value(symbolicated)
                .map_err(|error| ApiError::internal("symbolicated event encode", error))?,
        );
    }
    Ok((event_row(&row)?, payload))
}

#[cfg(test)]
mod tests {
    use migration::MigratorTrait;
    use sea_orm::ConnectionTrait;

    use crate::runtime::sql;

    #[tokio::test]
    async fn event_lookup_seeks_the_event_id_with_or_without_a_source() {
        let db = sea_orm::Database::connect("sqlite::memory:").await.unwrap();
        migration::OrgMigrator::up(&db, None).await.unwrap();
        let mut plans = Vec::new();
        for by_source in [false, true] {
            let mut values: Vec<sea_orm::Value> = vec![1.into(), "e".into(), 0.into()];
            if by_source {
                values.push(2.into());
            }
            let plan: Vec<String> = db
                .query_all_raw(sql(
                    &format!("EXPLAIN QUERY PLAN {}", super::find_event_query(by_source)),
                    values,
                ))
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
                vec!["SEARCH events USING INDEX events_issue_event (issue_id=? AND event_id=? AND received_at>?)"],
                vec!["SEARCH events USING INDEX sqlite_autoindex_events_1 (source_id=? AND event_id=?)"],
            ]
        );
    }
}
