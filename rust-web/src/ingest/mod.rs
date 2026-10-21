//! Sentry envelope ingestion. A DSN key authorizes writes for one source only.

pub mod envelope;
pub mod event;
pub mod interfaces;
pub mod native;
pub mod policy;
pub mod receipt;

use std::{
    sync::{atomic::Ordering, Arc},
    time::Duration,
};

use axum::{
    body::Body,
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use sea_orm::ConnectionTrait;
use serde_json::json;

use self::receipt::{Category, Reason, Receipt};
use crate::{
    billing::{
        alerts::{self, Metric},
        Entitlement, Refusal,
    },
    domain::{now_micros, now_secs, utc_day, Environment, OrgId, ProjectId, SourceId},
    error::ApiError,
    identity::token_hash,
    issues::{self, Committed, EventSource},
    logs::{
        object::Partition,
        record::{parse_item, ParseLimits},
        storage::{self, LogFailure},
    },
    quota::{Hold, QuotaError, Usage},
    runtime::{sql, Runtime},
};

/// Write-only principal resolved from a DSN key. It has no conversion to a read principal.
#[derive(Debug, Clone)]
pub struct IngestGrant {
    pub org: OrgId,
    pub project: ProjectId,
    pub source: SourceId,
    pub environment: Environment,
    pub entitlement: Entitlement,
    pub legacy: bool,
    pub policy: policy::IngestionPolicy,
}

fn sentry_key<'a>(headers: &'a HeaderMap, query: Option<&'a str>) -> Option<&'a str> {
    let from_header = headers
        .get("x-sentry-auth")
        .and_then(|v| v.to_str().ok())
        .and_then(|auth| {
            auth.split([',', ' '])
                .map(str::trim)
                .find_map(|part| part.strip_prefix("sentry_key="))
        });
    from_header.or_else(|| {
        query?
            .split('&')
            .find_map(|pair| pair.strip_prefix("sentry_key="))
    })
}

fn legacy_key(key: &str) -> bool {
    key.strip_prefix("obs_").is_some_and(|rest| {
        rest.len() == 43
            && rest
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    })
}

const GRANT_QUERY: &str = "SELECT k.org_id, k.project_id, k.source_id, s.environment, o.created_at,
        b.paid_until, p.policy
     FROM ingest_keys k
     JOIN sources s ON s.id = k.source_id JOIN organizations o ON o.id = k.org_id
     LEFT JOIN billing_accounts b ON b.org_id = o.id
     LEFT JOIN ingestion_policies p ON p.org_id = o.id
     WHERE k.revoked_at IS NULL AND o.lifecycle = 'active' AND ";

pub async fn resolve_grant(rt: &Runtime, key: &str) -> Result<IngestGrant, ApiError> {
    let valid = (key.len() == 32 && key.bytes().all(|b| b.is_ascii_hexdigit())) || legacy_key(key);
    let row = if valid {
        rt.control
            .query_one_raw(sql(
                &format!("{GRANT_QUERY}k.key_hash = ?"),
                vec![token_hash(key).into()],
            ))
            .await?
    } else {
        None
    };
    grant(rt, row.ok_or(ApiError::InvalidKey)?, legacy_key(key))
}

/// The grant of an active key of `source`, for writes made from the dashboard.
async fn source_grant(
    rt: &Runtime,
    org: &OrgId,
    source: SourceId,
) -> Result<IngestGrant, ApiError> {
    let row = rt
        .control
        .query_one_raw(sql(
            &format!("{GRANT_QUERY}k.source_id = ? AND k.org_id = ? LIMIT 1"),
            vec![source.0.into(), org.as_str().into()],
        ))
        .await?;
    grant(rt, row.ok_or(ApiError::NotFound)?, false)
}

fn grant(rt: &Runtime, row: sea_orm::QueryResult, legacy: bool) -> Result<IngestGrant, ApiError> {
    let org: OrgId = row
        .try_get::<String>("", "org_id")?
        .parse()
        .map_err(|()| ApiError::Internal("stored organization id".into()))?;
    let environment: String = row.try_get("", "environment")?;
    let stored: Option<String> = row.try_get("", "policy")?;
    let policy = policy::IngestionPolicy::from_stored(stored.as_deref()).map_err(|_| {
        let refused = rt.metrics.refuse_invalid_policy(&org);
        // Powers of two keep a refusal flood visible in the log but bounded.
        if refused.is_power_of_two() {
            tracing::warn!(%org, refused, "ingestion refused: the stored ingestion policy is invalid");
        }
        ApiError::Unavailable(policy::INVALID)
    })?;
    Ok(IngestGrant {
        org,
        project: ProjectId(row.try_get("", "project_id")?),
        source: SourceId(row.try_get("", "source_id")?),
        environment: Environment::parse(&environment)
            .ok_or(ApiError::Internal("stored environment".into()))?,
        entitlement: Entitlement::at(
            row.try_get("", "created_at")?,
            row.try_get("", "paid_until")?,
            now_secs(),
        ),
        legacy,
        policy,
    })
}

pub const TEST_EVENT_MESSAGE: &str = "PostDeploy test event";

/// Result of a dashboard test event. `Refused` carries the refusal code an
/// SDK would get for the same event.
#[derive(Debug, PartialEq, Eq)]
pub enum TestEvent {
    Stored,
    Refused(&'static str),
}

/// Stores one fixed error event for `source` through the entitlement, rate,
/// policy, quota and commit path of an SDK envelope.
pub async fn test_event(
    rt: &Arc<Runtime>,
    org: &OrgId,
    source: SourceId,
) -> Result<TestEvent, ApiError> {
    let grant = source_grant(rt, org, source).await?;
    let refused = |rejection: Rejection| match rejection {
        Rejection::Refusal(Refusal::SubscriptionRequired) => {
            Ok(TestEvent::Refused("subscription_required"))
        }
        Rejection::Refusal(Refusal::MonthlyQuota { .. }) => {
            Ok(TestEvent::Refused("monthly_quota_exceeded"))
        }
        Rejection::Api(ApiError::RateLimited { .. }) => Ok(TestEvent::Refused("rate_limited")),
        Rejection::Api(error) => Err(error),
    };
    if let Err(rejection) = entitled(rt, &grant) {
        return refused(rejection);
    }
    let raw = json!({
        "event_id": uuid::Uuid::new_v4().simple().to_string(),
        "level": "error",
        "platform": "other",
        "message": TEST_EVENT_MESSAGE,
    })
    .to_string();
    let received = now_micros();
    let event = match event::map(
        raw.as_bytes(),
        None,
        grant.project,
        &grant.environment,
        received,
        rt.settings.ingest.max_event_bytes,
        &grant.policy,
    ) {
        Ok(event) => event,
        Err(reason) => return Ok(TestEvent::Refused(reason.code())),
    };
    let mut receipt = Receipt::default();
    match store(rt, &grant, vec![event], Vec::new(), received, &mut receipt).await {
        Ok(()) => Ok(TestEvent::Stored),
        Err(rejection) => refused(rejection),
    }
}

/// Whether a source has stored any error event and any log entry.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
pub struct Arrival {
    pub errors_received: bool,
    pub logs_received: bool,
}

const ARRIVAL: &str = "SELECT EXISTS (SELECT 1 FROM events WHERE source_id = ?) AS errors,
    EXISTS (SELECT 1 FROM log_entry_runs WHERE project_id = ? AND source_id = ?)
    OR EXISTS (SELECT 1 FROM log_objects WHERE project_id = ? AND source_id = ?) AS logs";

pub async fn arrival(
    rt: &Runtime,
    org: &OrgId,
    project: ProjectId,
    source: SourceId,
) -> Result<Arrival, ApiError> {
    let handle = rt.tenant(org).await?;
    let row = handle
        .query_one_raw(sql(
            ARRIVAL,
            vec![
                source.0.into(),
                project.0.into(),
                source.0.into(),
                project.0.into(),
                source.0.into(),
            ],
        ))
        .await?
        .ok_or_else(|| ApiError::Internal("arrival query returned no row".into()))?;
    Ok(Arrival {
        errors_received: row.try_get::<bool>("", "errors")?,
        logs_received: row.try_get::<bool>("", "logs")?,
    })
}

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug)]
enum Outcome {
    Ok,
    RateLimited,
    MonthlyLimited,
    /// 503 with the stated reason.
    Unavailable(&'static str),
}

enum Rejection {
    Api(ApiError),
    Refusal(Refusal),
}

impl From<ApiError> for Rejection {
    fn from(error: ApiError) -> Self {
        Self::Api(error)
    }
}

impl IntoResponse for Rejection {
    fn into_response(self) -> Response {
        match self {
            Self::Api(error) => error.into_response(),
            Self::Refusal(refusal) => refusal.into_response(),
        }
    }
}

/// Handles one envelope. Returns 200 only when every supported item is durable.
pub async fn envelope(
    rt: &Arc<Runtime>,
    path_project: &str,
    headers: &HeaderMap,
    query: Option<&str>,
    body: Body,
) -> Response {
    match envelope_inner(rt, path_project, headers, query, body).await {
        Ok(response) => response,
        Err(rejection) => rejection.into_response(),
    }
}

async fn envelope_inner(
    rt: &Arc<Runtime>,
    path_project: &str,
    headers: &HeaderMap,
    query: Option<&str>,
    body: Body,
) -> Result<Response, Rejection> {
    let settings = &rt.settings.ingest;
    rt.metrics.envelopes.fetch_add(1, Ordering::Relaxed);
    let grant = authenticate(rt, sentry_key(headers, query)).await?;
    // `obs_` DSNs end in `/1` for every project.
    let path_matches = path_project.parse::<i64>().ok() == Some(grant.project.0)
        || (grant.legacy && path_project == "1");
    if !path_matches {
        return Err(ApiError::Forbidden.into());
    }
    entitled(rt, &grant)?;
    let (inflated, _body_permit) = receive(rt, headers, body).await?;
    let limits = envelope::Limits {
        max_inflated_bytes: settings.max_inflated_bytes,
        max_items: settings.max_items,
        max_events: settings.max_events,
    };
    let decoded = tokio::task::spawn_blocking(move || envelope::parse(&inflated, &limits))
        .await
        .map_err(|_| ApiError::Internal("envelope decode task".into()))?;
    let parsed = decoded.map_err(decode_error)?;
    rt.metrics
        .items_skipped
        .fetch_add(u64::from(parsed.skipped), Ordering::Relaxed);
    let mut receipt = Receipt::default();
    receipt.record(
        Category::Other,
        Reason::UnsupportedItemType,
        u64::from(parsed.skipped),
    );

    let received = now_micros();
    let log_limits = ParseLimits {
        max_body_bytes: rt.settings.logs.max_body_bytes,
        max_attributes: rt.settings.logs.max_attributes,
        max_attribute_bytes: rt.settings.logs.max_attribute_bytes,
        max_record_bytes: rt.settings.logs.record_byte_limit(),
    };
    let max_logs = settings.max_logs;
    let (records, events, first_event_id, mut receipt) = tokio::task::spawn_blocking({
        let (rt, grant) = (Arc::clone(rt), grant.clone());
        move || {
            let mut records = Vec::new();
            for item in &parsed.logs {
                let mut items =
                    parse_item(item, received, &log_limits, &grant.policy, &mut receipt)
                        .map_err(|_| ApiError::BadRequest("invalid_log_item"))?;
                records.append(&mut items);
            }
            if records.len() > max_logs {
                return Err(ApiError::BadRequest("too_many_logs"));
            }
            let events = map_events(
                &rt,
                &grant,
                &parsed.events,
                parsed.event_id.as_deref(),
                received,
                &mut receipt,
            );
            let first_event_id = events
                .first()
                .map(|e| e.event_id.clone())
                .or(parsed.event_id);
            Ok((records, events, first_event_id, receipt))
        }
    })
    .await
    .map_err(|_| ApiError::Internal("envelope item task".into()))??;
    rt.metrics
        .logs_dropped
        .fetch_add(receipt.invalid(Category::Log), Ordering::Relaxed);
    store(rt, &grant, events, records, received, &mut receipt).await?;
    Ok((
        StatusCode::OK,
        Json(json!({ "id": first_event_id, "receipt": receipt.response() })),
    )
        .into_response())
}

/// `POST /e/errors` from the PostDeploy SDKs, authenticated by
/// `Authorization: Bearer <key>`. Returns 202 when every converted event is durable.
pub async fn native_errors(rt: &Arc<Runtime>, headers: &HeaderMap, body: Body) -> Response {
    match native_errors_inner(rt, headers, body).await {
        Ok(response) => response,
        Err(rejection) => rejection.into_response(),
    }
}

async fn native_errors_inner(
    rt: &Arc<Runtime>,
    headers: &HeaderMap,
    body: Body,
) -> Result<Response, Rejection> {
    rt.metrics.envelopes.fetch_add(1, Ordering::Relaxed);
    let key = headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .map(str::trim);
    let grant = authenticate(rt, key).await?;
    entitled(rt, &grant)?;
    let (inflated, _body_permit) = receive(rt, headers, body).await?;
    let parsed = tokio::task::spawn_blocking(move || native::parse(&inflated))
        .await
        .map_err(|_| ApiError::Internal("envelope decode task".into()))?
        .map_err(|_| ApiError::BadRequest("invalid_envelope"))?;
    if parsed
        .header_key
        .as_deref()
        .is_some_and(|header_key| Some(header_key) != key)
    {
        return Err(ApiError::BadRequest("key_mismatch").into());
    }
    let received = now_micros();
    let mut receipt = Receipt::default();
    receipt.record(
        Category::Error,
        Reason::Malformed,
        u64::from(parsed.dropped),
    );
    let (events, mut receipt) = tokio::task::spawn_blocking({
        let (rt, grant) = (Arc::clone(rt), grant.clone());
        move || {
            let events = map_events(&rt, &grant, &parsed.events, None, received, &mut receipt);
            (events, receipt)
        }
    })
    .await
    .map_err(|_| ApiError::Internal("envelope item task".into()))?;
    let event_ids: Vec<String> = events.iter().map(|e| e.event_id.clone()).collect();
    store(rt, &grant, events, Vec::new(), received, &mut receipt).await?;
    Ok((
        StatusCode::ACCEPTED,
        Json(json!({
            "accepted": event_ids.len(),
            "dropped": receipt.invalid(Category::Error),
            "event_ids": event_ids,
            "receipt": receipt.response(),
        })),
    )
        .into_response())
}

async fn authenticate(rt: &Runtime, key: Option<&str>) -> Result<IngestGrant, Rejection> {
    let grant = match key {
        Some(key) => resolve_grant(rt, key).await,
        None => Err(ApiError::InvalidKey),
    };
    let grant = match grant {
        Ok(grant) => grant,
        Err(ApiError::InvalidKey) => {
            tokio::time::sleep(Duration::from_millis(
                rt.settings.ingest.invalid_key_delay_ms,
            ))
            .await;
            return Err(ApiError::InvalidKey.into());
        }
        Err(other) => return Err(other.into()),
    };
    Ok(grant)
}

/// The subscription check, then the organization's request rate gate. Both
/// run before the body is read.
fn entitled(rt: &Runtime, grant: &IngestGrant) -> Result<(), Rejection> {
    if !grant.entitlement.accepts_telemetry() {
        rt.metrics.rejected_rate.fetch_add(1, Ordering::Relaxed);
        return Err(Rejection::Refusal(Refusal::SubscriptionRequired));
    }
    rt.admission.ingest_rate.admit(&grant.org).map_err(|error| {
        match error {
            ApiError::RateLimited { .. } => &rt.metrics.rejected_rate,
            _ => &rt.metrics.rejected_overload,
        }
        .fetch_add(1, Ordering::Relaxed);
        Rejection::from(error)
    })
}

async fn receive(
    rt: &Runtime,
    headers: &HeaderMap,
    body: Body,
) -> Result<(bytes::Bytes, tokio::sync::OwnedSemaphorePermit), ApiError> {
    let settings = &rt.settings.ingest;
    let declared = headers
        .get(header::CONTENT_LENGTH)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.parse::<usize>().ok());
    if declared.is_some_and(|len| len > settings.max_wire_bytes) {
        return Err(ApiError::TooLarge);
    }
    let encoding = headers
        .get(header::CONTENT_ENCODING)
        .and_then(|v| v.to_str().ok())
        .map(str::to_owned);
    let reserve = if encoding
        .as_deref()
        .is_some_and(|e| !matches!(e.trim(), "" | "identity"))
    {
        settings.max_inflated_bytes
    } else {
        declared.unwrap_or(settings.max_wire_bytes)
    };
    let Some(mut permit) = rt.admission.body(reserve) else {
        rt.metrics.rejected_overload.fetch_add(1, Ordering::Relaxed);
        return Err(ApiError::Unavailable("ingest_overloaded"));
    };
    let wire = axum::body::to_bytes(body, settings.max_wire_bytes)
        .await
        .map_err(|_| ApiError::TooLarge)?;
    let max_inflated = settings.max_inflated_bytes;
    let inflated = tokio::task::spawn_blocking(move || {
        envelope::inflate(encoding.as_deref(), wire, max_inflated)
    })
    .await
    .map_err(|_| ApiError::Internal("envelope decode task".into()))?
    .map_err(decode_error)?;
    drop(permit.split(permit.num_permits().saturating_sub(inflated.len())));
    Ok((inflated, permit))
}

fn decode_error(error: envelope::DecodeError) -> ApiError {
    match error {
        envelope::DecodeError::UnsupportedEncoding => ApiError::UnsupportedEncoding,
        envelope::DecodeError::TooLarge => ApiError::TooLarge,
        envelope::DecodeError::InvalidCompression => ApiError::BadRequest("invalid_compression"),
        envelope::DecodeError::Invalid => ApiError::BadRequest("invalid_envelope"),
        envelope::DecodeError::TooManyItems => ApiError::BadRequest("too_many_items"),
    }
}

fn map_events(
    rt: &Runtime,
    grant: &IngestGrant,
    raw: &[impl AsRef<[u8]>],
    envelope_event_id: Option<&str>,
    received: i64,
    receipt: &mut Receipt,
) -> Vec<event::ErrorEvent> {
    raw.iter()
        .filter_map(|raw| {
            match event::map(
                raw.as_ref(),
                envelope_event_id,
                grant.project,
                &grant.environment,
                received,
                rt.settings.ingest.max_event_bytes,
                &grant.policy,
            ) {
                Ok(event) => Some(event),
                Err(reason) => {
                    if reason.outcome() == receipt::Outcome::Invalid {
                        rt.metrics.events_dropped.fetch_add(1, Ordering::Relaxed);
                    }
                    receipt.record(Category::Error, reason, 1);
                    None
                }
            }
        })
        .collect()
}

async fn store(
    rt: &Arc<Runtime>,
    grant: &IngestGrant,
    events: Vec<event::ErrorEvent>,
    records: Vec<crate::logs::record::LogRecord>,
    received: i64,
    receipt: &mut Receipt,
) -> Result<(), Rejection> {
    let (events, retries) = without_retries(rt, grant, events).await.map_err(|error| {
        tracing::error!(%error, "error retry lookup failed");
        ApiError::Unavailable("ingest_unavailable")
    })?;
    let log_count = records.len() as u64;
    let want = Usage {
        errors: events.len() as u64,
        logs: records.len() as u64,
        log_bytes: records
            .iter()
            .map(crate::logs::record::LogRecord::approx_bytes)
            .sum::<usize>() as u64,
    };
    let hold = match rt.quotas.reserve_at(rt, &grant.org, want, received).await {
        Ok(hold) => hold,
        Err(QuotaError::Exceeded(category)) => {
            rt.metrics.rejected_rate.fetch_add(1, Ordering::Relaxed);
            return Err(ApiError::RateLimited {
                retry: Duration::from_secs(60),
                categories: category,
            }
            .into());
        }
        Err(QuotaError::MonthlyExceeded(categories)) => {
            let metric = if categories == "error" {
                Metric::Errors
            } else {
                Metric::LogBytes
            };
            alerts::record_exhausted(rt, &grant.org, received, metric).await;
            rt.metrics.rejected_rate.fetch_add(1, Ordering::Relaxed);
            return Err(Rejection::Refusal(Refusal::MonthlyQuota { categories }));
        }
        Err(QuotaError::Unavailable(ApiError::Unavailable(
            code @ ("log_restore_pending" | "log_restore_conflict"),
        ))) => {
            return Err(ApiError::Unavailable(code).into());
        }
        Err(QuotaError::Unavailable(error)) => {
            tracing::error!(%error, "envelope quota admission failed");
            return Err(ApiError::Unavailable("ingest_unavailable").into());
        }
    };
    let (errors_hold, logs_hold) = hold.split_categories();
    let (error_outcome, error_category, committed) =
        commit_errors(rt, grant, events, received, errors_hold).await;
    let (log_outcome, log_category) = if let Outcome::Unavailable(_) = error_outcome {
        (Outcome::Ok, None)
    } else {
        submit_logs(rt, grant, records, logs_hold).await
    };
    for (outcome, metric) in [
        (error_outcome, Metric::Errors),
        (log_outcome, Metric::LogBytes),
    ] {
        if outcome == Outcome::MonthlyLimited {
            alerts::record_exhausted(rt, &grant.org, received, metric).await;
        }
    }
    let worst = error_outcome.max(log_outcome);
    match worst {
        Outcome::Ok => {
            receipt.record(
                Category::Error,
                Reason::DuplicateEventId,
                retries + committed.duplicate,
            );
            receipt.accept(Category::Error, committed.new);
            receipt.accept(Category::Log, log_count);
            if let Err(error) = receipt.persist(rt, &grant.org, &utc_day(received)).await {
                rt.metrics
                    .outcome_writes_failed
                    .fetch_add(1, Ordering::Relaxed);
                tracing::error!(%error, "ingestion outcome counters were not recorded");
            }
            Ok(())
        }
        Outcome::RateLimited | Outcome::MonthlyLimited => {
            rt.metrics.rejected_rate.fetch_add(1, Ordering::Relaxed);
            let categories: &'static str = match (error_category, log_category) {
                (Some(_), Some(_)) => "error;log_item",
                (Some(c), None) | (None, Some(c)) => c,
                (None, None) => "default",
            };
            if worst == Outcome::MonthlyLimited {
                return Err(Rejection::Refusal(Refusal::MonthlyQuota { categories }));
            }
            Err(ApiError::RateLimited {
                retry: Duration::from_secs(60),
                categories,
            }
            .into())
        }
        Outcome::Unavailable(code) => Err(ApiError::Unavailable(code).into()),
    }
}

async fn commit_errors(
    rt: &Runtime,
    grant: &IngestGrant,
    events: Vec<event::ErrorEvent>,
    received: i64,
    mut hold: Hold,
) -> (Outcome, Option<&'static str>, ErrorCommits) {
    let mut committed = ErrorCommits::default();
    if events.is_empty() {
        return (Outcome::Ok, None, committed);
    }
    let Some(_lane) = rt.admission.error_lane() else {
        rt.metrics.rejected_overload.fetch_add(1, Ordering::Relaxed);
        return (Outcome::Unavailable("ingest_unavailable"), None, committed);
    };
    let at = EventSource {
        org: &grant.org,
        project: grant.project,
        source: grant.source,
        environment: &grant.environment,
    };
    for event in events {
        match issues::commit(rt, &at, event, received).await {
            Ok(Committed::New { .. }) => {
                hold.settle(
                    Usage {
                        errors: 1,
                        ..Usage::default()
                    },
                    true,
                );
                rt.metrics.events_accepted.fetch_add(1, Ordering::Relaxed);
                committed.new += 1;
            }
            Ok(Committed::Duplicate) => {
                hold.settle(
                    Usage {
                        errors: 1,
                        ..Usage::default()
                    },
                    false,
                );
                rt.metrics.events_duplicate.fetch_add(1, Ordering::Relaxed);
                committed.duplicate += 1;
            }
            Ok(Committed::QuotaExceeded) => {
                return (Outcome::RateLimited, Some("error"), committed);
            }
            Ok(Committed::MonthlyQuotaExceeded) => {
                return (Outcome::MonthlyLimited, Some("error"), committed);
            }
            Err(error) => {
                drop(hold);
                if matches!(error, ApiError::Unavailable(issues::COMMIT_UNCERTAIN)) {
                    rt.mark_dirty(&grant.org);
                }
                tracing::error!(%error, "error event commit failed");
                return (Outcome::Unavailable("ingest_unavailable"), None, committed);
            }
        }
        if let Some(faults) = rt.faults() {
            if faults
                .pause_after_error_settle
                .swap(false, Ordering::SeqCst)
            {
                faults.error_settled.notify_one();
                tokio::select! {
                    () = rt.cancel.cancelled() => {}
                    () = faults.error_resume.notified() => {}
                }
            }
        }
    }
    (Outcome::Ok, None, committed)
}

#[derive(Default)]
struct ErrorCommits {
    new: u64,
    duplicate: u64,
}

/// Drops events this source already stored, so a client retry of an accepted
/// event succeeds without reserving or counting usage again, even at a limit.
async fn without_retries(
    rt: &Runtime,
    grant: &IngestGrant,
    events: Vec<event::ErrorEvent>,
) -> Result<(Vec<event::ErrorEvent>, u64), ApiError> {
    if events.is_empty() {
        return Ok((events, 0));
    }
    let placeholders = vec!["?"; events.len()].join(",");
    let mut values: Vec<sea_orm::Value> = vec![grant.source.0.into()];
    values.extend(events.iter().map(|event| event.event_id.clone().into()));
    let handle = rt.tenant(&grant.org).await?;
    let rows = handle
        .query_all_raw(sql(
            &format!(
                "SELECT event_id FROM events WHERE source_id = ? AND event_id IN ({placeholders})"
            ),
            values,
        ))
        .await?;
    drop(handle);
    let mut stored = rows
        .iter()
        .map(|row| row.try_get::<String>("", "event_id"))
        .collect::<Result<std::collections::HashSet<_>, _>>()?;
    let (retries, fresh): (Vec<_>, Vec<_>) = events
        .into_iter()
        .partition(|event| !stored.insert(event.event_id.clone()));
    rt.metrics
        .events_duplicate
        .fetch_add(retries.len() as u64, Ordering::Relaxed);
    Ok((fresh, retries.len() as u64))
}

async fn submit_logs(
    rt: &Arc<Runtime>,
    grant: &IngestGrant,
    records: Vec<crate::logs::record::LogRecord>,
    hold: Hold,
) -> (Outcome, Option<&'static str>) {
    if records.is_empty() {
        return (Outcome::Ok, None);
    }
    let partition = Partition {
        org: grant.org.clone(),
        project: grant.project,
        source: grant.source,
        environment: grant.environment.clone(),
    };
    match storage::append(rt, &partition, records, hold).await {
        Ok(_) => (Outcome::Ok, None),
        Err(LogFailure::QuotaExceeded) => (Outcome::RateLimited, Some("log_item")),
        Err(LogFailure::MonthlyQuotaExceeded) => (Outcome::MonthlyLimited, Some("log_item")),
        Err(failure) => {
            if failure == LogFailure::BacklogFull {
                rt.metrics.rejected_overload.fetch_add(1, Ordering::Relaxed);
            }
            (Outcome::Unavailable(failure.code()), None)
        }
    }
}

#[cfg(test)]
mod tests {
    use migration::MigratorTrait;
    use sea_orm::ConnectionTrait;

    use crate::runtime::sql;

    #[tokio::test]
    async fn arrival_checks_seek_the_source_in_every_table() {
        let db = sea_orm::Database::connect("sqlite::memory:").await.unwrap();
        migration::OrgMigrator::up(&db, None).await.unwrap();
        let plan: Vec<String> = db
            .query_all_raw(sql(
                &format!("EXPLAIN QUERY PLAN {}", super::ARRIVAL),
                vec![7.into(), 3.into(), 7.into(), 3.into(), 7.into()],
            ))
            .await
            .unwrap()
            .iter()
            .map(|row| row.try_get::<String>("", "detail").unwrap())
            .filter(|detail| detail.starts_with("SEARCH") || detail.starts_with("SCAN"))
            .collect();
        assert_eq!(
            plan,
            [
                "SCAN CONSTANT ROW",
                "SEARCH events USING COVERING INDEX sqlite_autoindex_events_1 (source_id=?)",
                "SEARCH log_entry_runs USING COVERING INDEX log_entry_runs_source (project_id=? AND source_id=?)",
                "SEARCH log_objects USING COVERING INDEX log_objects_source (project_id=? AND source_id=?)",
            ]
        );
    }
}
