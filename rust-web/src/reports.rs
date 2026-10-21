//! Investigation reports written by connected agents. A report is a bounded
//! plain-text narrative whose findings cite issues, events and log entries of
//! the same organization and project. The body can quote logs, so it lives in
//! R2 only; the tenant database keeps identifiers, times, the object key and
//! typed evidence references.

use std::{fmt, str::FromStr};

use futures::{stream, StreamExt};
use sea_orm::{
    ConnectionTrait, DatabaseConnection, SqliteTransactionMode, TransactionOptions,
    TransactionTrait,
};
use serde::{Deserialize, Serialize};

use crate::{
    domain::{now_micros, utc_day, OrgId, ProjectId, UserId},
    error::{ApiError, ApiResult},
    identity::access::OrgAccess,
    ingest::envelope::normalize_event_id,
    logs::{
        read::{Cursor, CursorToken},
        storage::{cursor_epoch, restore_flag, RestoreFlag},
    },
    notifications::{EnqueueOutcome, Notice, Notifications},
    runtime::sql,
    scrub,
    store::ObjectStore,
};
use tenant_sqlite_loco::TenantPools;

const MAX_TITLE_CHARS: usize = 200;
const MAX_SUMMARY_BYTES: usize = 16 << 10;
const MAX_DETAIL_BYTES: usize = 8 << 10;
const MAX_FINDINGS: usize = 20;
const MAX_EVIDENCE_PER_FINDING: usize = 20;
const MAX_EVIDENCE: usize = 50;
/// Upper bound of a serialized document built from the limits above.
pub const MAX_BODY_BYTES: usize = 256 << 10;
const MAX_PAGE: u32 = 25;
const TITLE_FETCH_CONCURRENCY: usize = 4;

/// Public report identifier. Also names the R2 object.
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize)]
#[serde(transparent)]
pub struct ReportId(String);

impl ReportId {
    fn generate() -> Self {
        Self(format!("r{}", uuid::Uuid::now_v7().simple()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl FromStr for ReportId {
    type Err = ();

    fn from_str(value: &str) -> Result<Self, ()> {
        let valid = value.len() == 33
            && value.starts_with('r')
            && value[1..]
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b));
        valid.then(|| Self(value.to_owned())).ok_or(())
    }
}

impl fmt::Display for ReportId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl<'de> Deserialize<'de> for ReportId {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        String::deserialize(deserializer)?
            .parse()
            .map_err(|()| serde::de::Error::custom("invalid report id"))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, rmcp::schemars::JsonSchema)]
#[schemars(crate = "rmcp::schemars")]
#[serde(rename_all = "lowercase")]
pub enum Severity {
    Critical,
    High,
    Medium,
    Low,
    Info,
}

impl Severity {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Critical => "critical",
            Self::High => "high",
            Self::Medium => "medium",
            Self::Low => "low",
            Self::Info => "info",
        }
    }
}

/// A typed reference to tenant data. The server resolves every reference
/// against the report's organization and project before storing it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, rmcp::schemars::JsonSchema)]
#[schemars(crate = "rmcp::schemars")]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum Evidence {
    Issue {
        #[schemars(range(min = 1))]
        issue_id: i64,
    },
    Event {
        #[schemars(range(min = 1))]
        issue_id: i64,
        #[schemars(length(min = 1, max = 64))]
        event_id: String,
        /// Required when two sources sent the same event ID.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[schemars(range(min = 1))]
        source_id: Option<i64>,
    },
    Log {
        #[serde(with = "cursor_text")]
        #[schemars(with = "String", length(min = 1, max = 64))]
        cursor: CursorToken,
    },
}

mod cursor_text {
    use serde::{Deserialize, Deserializer, Serializer};

    use crate::logs::read::CursorToken;

    pub fn serialize<S: Serializer>(
        cursor: &CursorToken,
        serializer: S,
    ) -> Result<S::Ok, S::Error> {
        serializer.collect_str(cursor)
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(
        deserializer: D,
    ) -> Result<CursorToken, D::Error> {
        let value = String::deserialize(deserializer)?;
        CursorToken::parse(&value)
            .filter(|cursor| cursor.at.seq > 0)
            .ok_or_else(|| serde::de::Error::custom("invalid log cursor"))
    }
}

/// Untrusted report submission from the API, MCP or dashboard.
#[derive(Deserialize, rmcp::schemars::JsonSchema)]
#[schemars(crate = "rmcp::schemars")]
#[serde(deny_unknown_fields)]
pub struct ReportInput {
    #[schemars(range(min = 1))]
    pub project_id: i64,
    #[schemars(length(min = 1, max = MAX_TITLE_CHARS))]
    pub title: String,
    /// Plain text. At most 16 KiB in UTF-8.
    #[schemars(length(min = 1, max = MAX_SUMMARY_BYTES))]
    pub summary: String,
    #[schemars(length(min = 1, max = MAX_FINDINGS))]
    pub findings: Vec<FindingInput>,
}

#[derive(Deserialize, rmcp::schemars::JsonSchema)]
#[schemars(crate = "rmcp::schemars")]
#[serde(deny_unknown_fields)]
pub struct FindingInput {
    #[schemars(length(min = 1, max = MAX_TITLE_CHARS))]
    pub title: String,
    pub severity: Severity,
    /// Plain text. At most 8 KiB in UTF-8.
    #[schemars(length(min = 1, max = MAX_DETAIL_BYTES))]
    pub detail: String,
    #[schemars(length(min = 1, max = MAX_EVIDENCE_PER_FINDING))]
    pub evidence: Vec<Evidence>,
}

impl fmt::Debug for ReportInput {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ReportInput")
            .field("project_id", &self.project_id)
            .field("findings", &self.findings.len())
            .finish_non_exhaustive()
    }
}

/// The R2 object. It is the only place report text is stored.
#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ReportDocument {
    pub version: u8,
    pub id: ReportId,
    pub org_id: OrgId,
    pub project_id: ProjectId,
    pub author_id: UserId,
    pub created_at: i64,
    pub title: String,
    pub summary: String,
    pub findings: Vec<Finding>,
}

#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Finding {
    pub title: String,
    pub severity: Severity,
    pub detail: String,
    pub evidence: Vec<Evidence>,
}

impl fmt::Debug for ReportDocument {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ReportDocument")
            .field("id", &self.id)
            .field("findings", &self.findings.len())
            .finish_non_exhaustive()
    }
}

impl ReportDocument {
    pub fn evidence(&self) -> impl Iterator<Item = (usize, &Evidence)> {
        self.findings
            .iter()
            .enumerate()
            .flat_map(|(index, finding)| finding.evidence.iter().map(move |e| (index, e)))
    }
}

struct Draft {
    project: ProjectId,
    title: String,
    summary: String,
    findings: Vec<Finding>,
}

fn clean_text(
    value: &str,
    max_bytes: usize,
    multiline: bool,
    code: &'static str,
) -> ApiResult<String> {
    let value = scrub::BUILT_IN.text(value.trim()).into_owned();
    let allowed = |c: char| !c.is_control() || (multiline && (c == '\n' || c == '\t'));
    let value = value.replace("\r\n", "\n");
    if value.is_empty() || value.len() > max_bytes || !value.chars().all(allowed) {
        return Err(ApiError::BadRequest(code));
    }
    Ok(value)
}

fn clean_title(value: &str) -> ApiResult<String> {
    let title = clean_text(value, MAX_TITLE_CHARS * 4, false, "invalid_title")?;
    if title.chars().count() > MAX_TITLE_CHARS {
        return Err(ApiError::BadRequest("invalid_title"));
    }
    Ok(title)
}

fn parse(input: ReportInput) -> ApiResult<Draft> {
    let findings = input.findings;
    if findings.is_empty() || findings.len() > MAX_FINDINGS {
        return Err(ApiError::BadRequest("invalid_findings"));
    }
    let total: usize = findings.iter().map(|f| f.evidence.len()).sum();
    if total > MAX_EVIDENCE {
        return Err(ApiError::BadRequest("too_much_evidence"));
    }
    let findings = findings
        .into_iter()
        .map(|finding| {
            if finding.evidence.is_empty() || finding.evidence.len() > MAX_EVIDENCE_PER_FINDING {
                return Err(ApiError::BadRequest("finding_needs_evidence"));
            }
            let evidence = finding
                .evidence
                .into_iter()
                .map(|evidence| match evidence {
                    Evidence::Event {
                        issue_id,
                        event_id,
                        source_id,
                    } => normalize_event_id(&event_id)
                        .map(|event_id| Evidence::Event {
                            issue_id,
                            event_id,
                            source_id,
                        })
                        .ok_or(ApiError::BadRequest("invalid_evidence")),
                    other => Ok(other),
                })
                .collect::<ApiResult<Vec<_>>>()?;
            Ok(Finding {
                title: clean_title(&finding.title)?,
                severity: finding.severity,
                detail: clean_text(&finding.detail, MAX_DETAIL_BYTES, true, "invalid_detail")?,
                evidence,
            })
        })
        .collect::<ApiResult<Vec<_>>>()?;
    Ok(Draft {
        project: ProjectId(input.project_id),
        title: clean_title(&input.title)?,
        summary: clean_text(&input.summary, MAX_SUMMARY_BYTES, true, "invalid_summary")?,
        findings,
    })
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct ReportMeta {
    pub id: ReportId,
    pub project_id: ProjectId,
    pub author_id: UserId,
    pub created_at: i64,
    pub finding_count: u32,
    pub evidence_count: u32,
    pub body_bytes: u64,
}

#[derive(Debug, Serialize)]
pub struct Published {
    pub report: ReportMeta,
    pub notifications: EnqueueOutcome,
}

/// Current facts for an issue, read from tenant metadata at request time.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct IssueFacts {
    pub id: i64,
    pub title: String,
    pub culprit: Option<String>,
    pub level: String,
    pub status: String,
    pub environment: String,
    pub event_count: i64,
    pub first_seen: i64,
    pub last_seen: i64,
}

/// Current facts for a cited log entry: the entry's contiguous run in the
/// report's project.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct LogFacts {
    pub object_id: i64,
    pub min_ts: i64,
    pub max_ts: i64,
    pub entry_count: i64,
    pub level_mask: i64,
}

/// One cited reference with server-derived facts. `None` facts mean the data
/// has since expired or been deleted.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct EvidenceFacts {
    pub finding: u32,
    pub evidence: Evidence,
    pub issue: Option<IssueFacts>,
    pub log: Option<LogFacts>,
}

#[derive(Debug, Serialize)]
pub struct ReportView {
    pub report: ReportMeta,
    pub document: ReportDocument,
    pub evidence: Vec<EvidenceFacts>,
}

#[derive(Debug, Default, Deserialize)]
pub struct ReportQuery {
    pub project: Option<i64>,
    pub before: Option<ReportId>,
    pub limit: Option<u32>,
}

#[derive(Debug, Serialize)]
pub struct ReportListItem {
    #[serde(flatten)]
    pub report: ReportMeta,
    /// `None` when the R2 body could not be read for this page.
    pub title: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct ReportPage {
    pub reports: Vec<ReportListItem>,
    pub next: Option<ReportId>,
}

/// Report service shared by the HTTP API, MCP tools and dashboard. Callers
/// authorize with [`OrgAccess`]; the MCP adapter also checks `reports:write`.
#[derive(Clone)]
pub struct Reports {
    control: DatabaseConnection,
    tenants: TenantPools,
    store: ObjectStore,
    notifications: Notifications,
}

impl Reports {
    pub fn new(
        control: DatabaseConnection,
        tenants: TenantPools,
        store: ObjectStore,
        notifications: Notifications,
    ) -> Self {
        Self {
            control,
            tenants,
            store,
            notifications,
        }
    }

    /// Uploads the scrubbed body, then records metadata, evidence and
    /// notification work in one short tenant transaction. Evidence that does
    /// not exist in this organization and project rejects the report.
    pub async fn publish(&self, access: &OrgAccess, input: ReportInput) -> ApiResult<Published> {
        let draft = parse(input)?;
        project_in_org(&self.control, &access.org, draft.project).await?;

        let created_at = now_micros();
        let document = ReportDocument {
            version: 1,
            id: ReportId::generate(),
            org_id: access.org.clone(),
            project_id: draft.project,
            author_id: access.user,
            created_at,
            title: draft.title,
            summary: draft.summary,
            findings: draft.findings,
        };
        let body =
            serde_json::to_vec(&document).map_err(|e| ApiError::internal("report encode", e))?;
        if body.len() > MAX_BODY_BYTES {
            return Err(ApiError::TooLarge);
        }
        let key = format!(
            "reports/v1/{}/{}/{}.json",
            access.org,
            utc_day(created_at),
            document.id
        );
        let meta = ReportMeta {
            id: document.id.clone(),
            project_id: document.project_id,
            author_id: access.user,
            created_at,
            finding_count: document.findings.len() as u32,
            evidence_count: document.evidence().count() as u32,
            body_bytes: body.len() as u64,
        };
        let _pending = self.store.pending(&key);
        self.store
            .put(&key, body.into())
            .await
            .map_err(|_| ApiError::Unavailable("store_unavailable"))?;

        match self.record(&access.org, &document, &meta, &key).await {
            Ok(notifications) => Ok(Published {
                report: meta,
                notifications,
            }),
            Err(error) => {
                crate::orphan_retention::discard(
                    &self.control,
                    &self.tenants,
                    &self.store,
                    &access.org,
                    crate::orphan_retention::ObjectKind::Report,
                    &key,
                )
                .await;
                Err(error)
            }
        }
    }

    async fn record(
        &self,
        org: &OrgId,
        document: &ReportDocument,
        meta: &ReportMeta,
        key: &str,
    ) -> ApiResult<EnqueueOutcome> {
        let handle =
            crate::organization_lifecycle::active_tenant(&self.control, &self.tenants, org).await?;
        let txn = handle
            .begin_with_options(TransactionOptions {
                sqlite_transaction_mode: Some(SqliteTransactionMode::Immediate),
                ..TransactionOptions::default()
            })
            .await?;
        let epoch = cursor_epoch(&txn).await?;
        let mut sources = Vec::new();
        for (_, evidence) in document.evidence() {
            if let Evidence::Log { cursor } = evidence {
                match restore_flag(&txn).await? {
                    RestoreFlag::Clear => {}
                    RestoreFlag::Required => {
                        return Err(ApiError::Unavailable("log_restore_pending"));
                    }
                    RestoreFlag::Conflict(_) => {
                        return Err(ApiError::Unavailable("log_restore_conflict"));
                    }
                }
                epoch.resolve(*cursor)?;
            }
            sources.push(resolve_evidence(&txn, document.project_id, evidence).await?);
        }
        txn.execute_raw(sql(
            "INSERT INTO reports (id, project_id, author_id, created_at, object_key, body_bytes,
                finding_count, evidence_count) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            vec![
                meta.id.as_str().into(),
                meta.project_id.0.into(),
                meta.author_id.0.into(),
                meta.created_at.into(),
                key.into(),
                (meta.body_bytes as i64).into(),
                i64::from(meta.finding_count).into(),
                i64::from(meta.evidence_count).into(),
            ],
        ))
        .await?;
        for (ordinal, ((finding, evidence), source)) in document.evidence().zip(sources).enumerate()
        {
            let (kind, issue, event, object, entry): (
                &str,
                Option<i64>,
                Option<String>,
                Option<i64>,
                Option<i64>,
            ) = match evidence {
                Evidence::Issue { issue_id } => ("issue", Some(*issue_id), None, None, None),
                Evidence::Event {
                    issue_id, event_id, ..
                } => ("event", Some(*issue_id), Some(event_id.clone()), None, None),
                Evidence::Log { cursor } => (
                    "log",
                    None,
                    None,
                    Some(cursor.at.seq),
                    Some(i64::from(cursor.at.entry)),
                ),
            };
            txn.execute_raw(sql(
                "INSERT INTO report_evidence (report_id, ordinal, finding, kind, issue_id, event_id,
                    source_id, log_object_id, log_entry) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                vec![
                    meta.id.as_str().into(),
                    (ordinal as i64).into(),
                    (finding as i64).into(),
                    kind.into(),
                    issue.into(),
                    event.into(),
                    source.into(),
                    object.into(),
                    entry.into(),
                ],
            ))
            .await?;
        }
        let notice = Notice::Report {
            project: meta.project_id,
            report: meta.id.clone(),
        };
        let outcome = self.notifications.enqueue(&txn, org, &notice).await;
        txn.commit().await?;
        drop(handle);
        Ok(outcome)
    }

    /// Reads one report: metadata and live evidence facts from SQLite, then the
    /// body from R2 with no tenant handle held.
    pub async fn get(&self, access: &OrgAccess, id: &ReportId) -> ApiResult<ReportView> {
        let (report, key, evidence) = {
            let handle = crate::organization_lifecycle::active_tenant(
                &self.control,
                &self.tenants,
                &access.org,
            )
            .await?;
            load(&*handle, id).await?.ok_or(ApiError::NotFound)?
        };
        let document = read_document(&self.store, &access.org, &report, &key).await?;
        Ok(ReportView {
            report,
            document,
            evidence,
        })
    }

    /// Newest first. Titles are read from R2 with bounded concurrency.
    pub async fn list(&self, access: &OrgAccess, query: ReportQuery) -> ApiResult<ReportPage> {
        let limit = query.limit.unwrap_or(MAX_PAGE).clamp(1, MAX_PAGE);
        let rows = {
            let handle = crate::organization_lifecycle::active_tenant(
                &self.control,
                &self.tenants,
                &access.org,
            )
            .await?;
            handle
                .query_all_raw(sql(
                    "SELECT id, project_id, author_id, created_at, object_key, body_bytes, finding_count,
                        evidence_count FROM reports
                     WHERE (? IS NULL OR project_id = ?) AND (? IS NULL OR id < ?)
                     ORDER BY id DESC LIMIT ?",
                    vec![
                        query.project.into(),
                        query.project.into(),
                        query.before.as_ref().map(ReportId::as_str).into(),
                        query.before.as_ref().map(ReportId::as_str).into(),
                        i64::from(limit + 1).into(),
                    ],
                ))
                .await?
                .iter()
                .map(meta_row)
                .collect::<Result<Vec<_>, _>>()?
        };
        let next = (rows.len() > limit as usize).then(|| rows[limit as usize - 1].0.id.clone());
        let reports = stream::iter(rows.into_iter().take(limit as usize))
            .map(|(report, key)| async move {
                let title = read_document(&self.store, &access.org, &report, &key)
                    .await
                    .ok()
                    .map(|d| d.title);
                ReportListItem { report, title }
            })
            .buffered(TITLE_FETCH_CONCURRENCY)
            .collect()
            .await;
        Ok(ReportPage { reports, next })
    }
}

pub(crate) async fn read_document(
    store: &ObjectStore,
    org: &OrgId,
    report: &ReportMeta,
    key: &str,
) -> ApiResult<ReportDocument> {
    let body = store
        .get(key, MAX_BODY_BYTES)
        .await
        .map_err(|_| ApiError::Unavailable("store_unavailable"))?
        .ok_or(ApiError::Unavailable("report_body_missing"))?;
    let document: ReportDocument =
        serde_json::from_slice(&body).map_err(|e| ApiError::internal("report decode", e))?;
    if document.id != report.id || &document.org_id != org {
        return Err(ApiError::Internal(
            "report object does not match its metadata".into(),
        ));
    }
    Ok(document)
}

pub(crate) async fn project_in_org(
    control: &DatabaseConnection,
    org: &OrgId,
    project: ProjectId,
) -> ApiResult<()> {
    control
        .query_one_raw(sql(
            "SELECT 1 AS found FROM projects WHERE id = ? AND org_id = ?",
            vec![project.0.into(), org.as_str().into()],
        ))
        .await?
        .map(|_| ())
        .ok_or(ApiError::NotFound)
}

async fn resolve_evidence(
    conn: &impl ConnectionTrait,
    project: ProjectId,
    evidence: &Evidence,
) -> ApiResult<Option<i64>> {
    let statement = match evidence {
        Evidence::Issue { issue_id } => sql(
            "SELECT NULL AS source_id FROM issues WHERE id = ? AND project_id = ?",
            vec![(*issue_id).into(), project.0.into()],
        ),
        Evidence::Event {
            issue_id,
            event_id,
            source_id,
        } => {
            let mut values: Vec<sea_orm::Value> = vec![
                (*issue_id).into(),
                event_id.clone().into(),
                project.0.into(),
            ];
            let source = source_id.map_or("", |source| {
                values.push(source.into());
                " AND source_id = ?"
            });
            sql(
                &format!("SELECT source_id FROM events WHERE issue_id = ? AND event_id = ? AND project_id = ?{source} LIMIT 2"),
                values,
            )
        }
        Evidence::Log { cursor } => sql(
            "SELECT NULL AS source_id FROM log_objects o
             WHERE o.id = ? AND o.entry_count > ? AND EXISTS (SELECT 1 FROM log_entry_runs r
                WHERE r.object_id = o.id AND r.first_entry <= ? AND r.last_entry >= ? AND r.project_id = ?)",
            vec![
                cursor.at.seq.into(),
                i64::from(cursor.at.entry).into(),
                i64::from(cursor.at.entry).into(),
                i64::from(cursor.at.entry).into(),
                project.0.into(),
            ],
        ),
    };
    let rows = conn.query_all_raw(statement).await?;
    match rows.as_slice() {
        [] => Err(ApiError::BadRequest("unknown_evidence")),
        [row] => Ok(row.try_get("", "source_id")?),
        _ => Err(ApiError::Conflict("ambiguous_event")),
    }
}

fn meta_row(row: &sea_orm::QueryResult) -> Result<(ReportMeta, String), ApiError> {
    let id: String = row.try_get("", "id")?;
    let report = ReportMeta {
        id: id
            .parse()
            .map_err(|()| ApiError::Internal("stored report id".into()))?,
        project_id: ProjectId(row.try_get("", "project_id")?),
        author_id: UserId(row.try_get("", "author_id")?),
        created_at: row.try_get("", "created_at")?,
        finding_count: row.try_get::<i64>("", "finding_count")? as u32,
        evidence_count: row.try_get::<i64>("", "evidence_count")? as u32,
        body_bytes: row.try_get::<i64>("", "body_bytes")? as u64,
    };
    Ok((report, row.try_get("", "object_key")?))
}

pub(crate) async fn load(
    conn: &impl ConnectionTrait,
    id: &ReportId,
) -> ApiResult<Option<(ReportMeta, String, Vec<EvidenceFacts>)>> {
    let Some(row) = conn
        .query_one_raw(sql(
            "SELECT id, project_id, author_id, created_at, object_key, body_bytes, finding_count,
                evidence_count FROM reports WHERE id = ?",
            vec![id.as_str().into()],
        ))
        .await?
    else {
        return Ok(None);
    };
    let (report, key) = meta_row(&row)?;
    let epoch = cursor_epoch(conn).await?;
    let rows = conn
        .query_all_raw(sql(
            "SELECT e.finding, e.kind, e.issue_id, e.event_id, e.source_id, e.log_object_id, e.log_entry,
                i.title, i.culprit, i.level, i.status, i.environment, i.event_count, i.first_seen, i.last_seen,
                r.min_ts, r.max_ts, r.last_entry - r.first_entry + 1 AS entry_count, r.level_mask
             FROM report_evidence e
             LEFT JOIN issues i ON i.id = e.issue_id AND i.project_id = ?
             LEFT JOIN log_entry_runs r ON r.object_id = e.log_object_id AND r.first_entry <= e.log_entry
                AND r.last_entry >= e.log_entry AND r.project_id = ?
             WHERE e.report_id = ? ORDER BY e.ordinal",
            vec![
                report.project_id.0.into(),
                report.project_id.0.into(),
                id.as_str().into(),
            ],
        ))
        .await?;
    let evidence = rows
        .iter()
        .map(|row| -> ApiResult<EvidenceFacts> {
            let kind: String = row.try_get("", "kind")?;
            let issue_id: Option<i64> = row.try_get("", "issue_id")?;
            let evidence = match kind.as_str() {
                "issue" => Evidence::Issue {
                    issue_id: issue_id.unwrap_or_default(),
                },
                "event" => Evidence::Event {
                    issue_id: issue_id.unwrap_or_default(),
                    event_id: row.try_get("", "event_id")?,
                    source_id: row.try_get("", "source_id")?,
                },
                _ => Evidence::Log {
                    cursor: epoch.token(Cursor {
                        seq: row.try_get("", "log_object_id")?,
                        entry: row.try_get::<i64>("", "log_entry")? as u32,
                    }),
                },
            };
            let title: Option<String> = row.try_get("", "title")?;
            let issue = match (issue_id, title) {
                (Some(id), Some(title)) => Some(IssueFacts {
                    id,
                    title,
                    culprit: row.try_get("", "culprit")?,
                    level: row.try_get("", "level")?,
                    status: row.try_get("", "status")?,
                    environment: row.try_get("", "environment")?,
                    event_count: row.try_get("", "event_count")?,
                    first_seen: row.try_get("", "first_seen")?,
                    last_seen: row.try_get("", "last_seen")?,
                }),
                _ => None,
            };
            let min_ts: Option<i64> = row.try_get("", "min_ts")?;
            let log = match (&evidence, min_ts) {
                (Evidence::Log { cursor }, Some(min_ts)) => Some(LogFacts {
                    object_id: cursor.at.seq,
                    min_ts,
                    max_ts: row.try_get("", "max_ts")?,
                    entry_count: row.try_get("", "entry_count")?,
                    level_mask: row.try_get("", "level_mask")?,
                }),
                _ => None,
            };
            Ok(EvidenceFacts {
                finding: row.try_get::<i64>("", "finding")? as u32,
                evidence,
                issue,
                log,
            })
        })
        .collect::<ApiResult<Vec<_>>>()?;
    Ok(Some((report, key, evidence)))
}

#[cfg(test)]
mod tests {
    use serde_json::{json, Value};

    use super::*;
    use crate::notifications::{testkit::*, EmailSubscription, EventKind};

    const MARKER: &str = "NARRATIVE-7f3a9c";

    fn input(value: Value) -> ReportInput {
        serde_json::from_value(value).unwrap()
    }

    fn report(project: ProjectId, title: &str, evidence: Value) -> ReportInput {
        input(json!({
            "project_id": project.0,
            "title": title,
            "summary": format!("Checkout fails after deploy. {MARKER}\nLog quote: user password=hunter2 rejected"),
            "findings": [{
                "title": "Cart total is undefined",
                "severity": "high",
                "detail": format!("Stack points at src/cart.ts. {MARKER}"),
                "evidence": evidence,
            }],
        }))
    }

    #[tokio::test]
    async fn report_body_lives_only_in_the_object_store_and_is_emailed() {
        let smtp_receiver = SmtpReceiver::start().await;
        let env = open(
            &data_dir("report-body"),
            Options {
                smtp: Some(smtp(smtp_receiver.port)),
                ..Options::default()
            },
        )
        .await;
        let (owner, project) = env.org("owner@example.test").await;
        env.notifications
            .subscribe_email(
                &owner,
                EmailSubscription {
                    events: vec![EventKind::ReportPublished],
                    project_id: None,
                },
            )
            .await
            .unwrap();
        let issue = env
            .issue(&owner.org, project, "TypeError: cart is undefined", 3)
            .await;
        env.event(
            &owner.org,
            project,
            issue,
            "0123456789abcdef0123456789abcdef",
        )
        .await;
        let object = env.log_object(&owner.org, project, 10).await;
        let evidence = json!([
            {"kind": "issue", "issue_id": issue},
            {"kind": "event", "issue_id": issue, "event_id": "01234567-89ab-cdef-0123-456789abcdef"},
            {"kind": "log", "cursor": format!("c1.{object}.9")},
        ]);

        let published = env
            .reports
            .publish(&owner, report(project, "Checkout regression", evidence))
            .await
            .unwrap();
        assert_eq!(
            (
                published.report.finding_count,
                published.report.evidence_count
            ),
            (1, 3)
        );
        assert_eq!(published.notifications.queued, 1);

        let view = env.reports.get(&owner, &published.report.id).await.unwrap();
        assert_eq!(view.document.title, "Checkout regression");
        assert_eq!(
            view.document.summary,
            format!("Checkout fails after deploy. {MARKER}\nLog quote: user password=[Filtered] rejected")
        );
        assert_eq!(
            view.document.findings[0].evidence[1],
            Evidence::Event {
                issue_id: issue,
                event_id: "0123456789abcdef0123456789abcdef".to_owned(),
                source_id: None,
            }
        );
        let issue_facts = view.evidence[0].issue.as_ref().unwrap();
        assert_eq!(
            (issue_facts.title.as_str(), issue_facts.event_count),
            ("TypeError: cart is undefined", 3)
        );
        assert_eq!(view.evidence[2].log.as_ref().unwrap().entry_count, 10);

        let keys = env
            .store
            .list_page(&format!("reports/v1/{}/", owner.org), None, 10)
            .await
            .unwrap()
            .keys;
        assert_eq!(keys.len(), 1);
        let stored = env
            .store
            .get(&keys[0], MAX_BODY_BYTES)
            .await
            .unwrap()
            .unwrap();
        assert!(stored.windows(MARKER.len()).any(|w| w == MARKER.as_bytes()));
        assert!(
            !env.files_contain(MARKER.as_bytes()),
            "report text must not reach SQLite"
        );
        assert!(
            !env.files_contain(b"Cart total is undefined"),
            "finding text must not reach SQLite"
        );

        assert_eq!(
            env.notifications
                .run_pending_for_org(&owner.org)
                .await
                .unwrap()
                .delivered,
            1
        );
        let messages = smtp_receiver.messages.lock().unwrap().clone();
        assert_eq!(messages.len(), 1);
        assert!(messages[0].contains("Subject: [PostDeploy] Report: Checkout regression"));
        assert!(messages[0].contains(MARKER), "email carries the narrative");
        assert!(messages[0].contains(&format!(
            "https://postdeploy.test/dashboard/orgs/{}/projects/{}/logs?cursor=c1.{object}.9",
            owner.org, project.0
        )));
        assert!(
            messages[0].contains("Issue #1: TypeError: cart is undefined (error, open, 3 events")
        );
        assert!(
            !env.files_contain(MARKER.as_bytes()),
            "delivery stores no message body"
        );
        env.shutdown().await;
    }

    #[tokio::test]
    async fn restore_flags_block_log_evidence_but_allow_issue_and_event_reports() {
        let env = open(&data_dir("report-restore-flags"), Options::default()).await;
        let (owner, project) = env.org("owner@example.test").await;
        let issue = env.issue(&owner.org, project, "Restore issue", 1).await;
        let event = "0123456789abcdef0123456789abcdef";
        env.event(&owner.org, project, issue, event).await;
        let object = env.log_object(&owner.org, project, 1).await;
        for (conflict, expected) in [
            (None, "log_restore_pending"),
            (Some("remote_prefix_mismatch"), "log_restore_conflict"),
        ] {
            let tenant = env
                .pools
                .registry()
                .open_existing(&owner.org.tenant())
                .await
                .unwrap();
            tenant.execute_raw(sql(
                "UPDATE restore_state SET logs_reconcile_required = 1, conflict = ? WHERE id = 1",
                vec![conflict.map(str::to_owned).into()],
            )).await.unwrap();
            drop(tenant);
            let refused = env
                .reports
                .publish(
                    &owner,
                    report(
                        project,
                        "Log blocked",
                        json!([
                            {"kind": "issue", "issue_id": issue},
                            {"kind": "log", "cursor": format!("c1.{object}.0")}
                        ]),
                    ),
                )
                .await
                .unwrap_err();
            assert!(matches!(refused, ApiError::Unavailable(reason) if reason == expected));
            let published = env
                .reports
                .publish(
                    &owner,
                    report(
                        project,
                        "Issue and event allowed",
                        json!([
                            {"kind": "issue", "issue_id": issue},
                            {"kind": "event", "issue_id": issue, "event_id": event}
                        ]),
                    ),
                )
                .await
                .unwrap();
            assert_eq!(published.report.evidence_count, 2);
        }
        let tenant = env
            .pools
            .registry()
            .open_existing(&owner.org.tenant())
            .await
            .unwrap();
        let row = tenant.query_one_raw(sql(
            "SELECT (SELECT COUNT(*) FROM reports) AS reports, (SELECT COUNT(*) FROM report_evidence) AS evidence, (SELECT COUNT(*) FROM report_evidence WHERE kind = 'log') AS logs",
            vec![],
        )).await.unwrap().unwrap();
        assert_eq!(row.try_get::<i64>("", "reports").unwrap(), 2);
        assert_eq!(row.try_get::<i64>("", "evidence").unwrap(), 4);
        assert_eq!(row.try_get::<i64>("", "logs").unwrap(), 0);
        drop(tenant);
        env.shutdown().await;
    }

    #[tokio::test]
    async fn event_evidence_links_the_exact_source_of_a_shared_event_id() {
        let smtp_receiver = SmtpReceiver::start().await;
        let env = open(
            &data_dir("report-event-source"),
            Options {
                smtp: Some(smtp(smtp_receiver.port)),
                ..Options::default()
            },
        )
        .await;
        let (owner, project) = env.org("owner@example.test").await;
        env.notifications
            .subscribe_email(
                &owner,
                EmailSubscription {
                    events: vec![EventKind::ReportPublished],
                    project_id: None,
                },
            )
            .await
            .unwrap();
        let issue = env
            .issue(&owner.org, project, "TypeError: cart is undefined", 3)
            .await;
        let shared = "0123456789abcdef0123456789abcdef";
        let single = "fedcba9876543210fedcba9876543210";
        env.event_from(&owner.org, project, issue, 1, shared).await;
        env.event_from(&owner.org, project, issue, 2, shared).await;
        env.event_from(&owner.org, project, issue, 2, single).await;

        let ambiguous = env
            .reports
            .publish(
                &owner,
                report(
                    project,
                    "Ambiguous",
                    json!([{"kind": "event", "issue_id": issue, "event_id": shared}]),
                ),
            )
            .await;
        assert!(matches!(
            ambiguous,
            Err(ApiError::Conflict("ambiguous_event"))
        ));

        let published = env
            .reports
            .publish(
                &owner,
                report(
                    project,
                    "Exact source",
                    json!([
                        {"kind": "event", "issue_id": issue, "event_id": shared, "source_id": 2},
                        {"kind": "event", "issue_id": issue, "event_id": single}
                    ]),
                ),
            )
            .await
            .unwrap();
        let view = env.reports.get(&owner, &published.report.id).await.unwrap();
        let stored: Vec<&Evidence> = view.evidence.iter().map(|facts| &facts.evidence).collect();
        assert_eq!(
            stored,
            [
                &Evidence::Event {
                    issue_id: issue,
                    event_id: shared.to_owned(),
                    source_id: Some(2)
                },
                &Evidence::Event {
                    issue_id: issue,
                    event_id: single.to_owned(),
                    source_id: Some(2)
                },
            ]
        );
        assert_eq!(
            env.notifications
                .run_pending_for_org(&owner.org)
                .await
                .unwrap()
                .delivered,
            1
        );
        let messages = smtp_receiver.messages.lock().unwrap().clone();
        let issue_link = format!(
            "https://postdeploy.test/dashboard/orgs/{}/projects/{}/observe/issues/{issue}",
            owner.org, project.0
        );
        assert!(messages[0].contains(&format!("{issue_link}?event={shared}&source=2")));
        assert!(messages[0].contains(&format!("{issue_link}?event={single}&source=2")));
        assert!(!messages[0].contains(&format!("{issue_link}?event={shared}&source=1")));
        env.shutdown().await;
    }

    #[tokio::test]
    async fn evidence_from_another_organization_or_project_is_rejected() {
        let env = open(&data_dir("report-evidence"), Options::default()).await;
        let (a, project_a) = env.org("a@example.test").await;
        let (b, project_b) = env.org("b@example.test").await;
        let other_project = env.project(&a.org, "billing").await;
        let issue_b = env.issue(&b.org, project_b, "Only in B", 1).await;
        env.event(
            &b.org,
            project_b,
            issue_b,
            "fedcba9876543210fedcba9876543210",
        )
        .await;
        let log_other = env.log_object(&a.org, other_project, 5).await;
        let issue_a = env.issue(&a.org, project_a, "Only in A", 1).await;

        for evidence in [
            json!([{"kind": "event", "issue_id": issue_b, "event_id": "fedcba9876543210fedcba9876543210"}]),
            json!([{"kind": "issue", "issue_id": issue_a + 100}]),
            json!([{"kind": "log", "cursor": format!("c1.{log_other}.0")}]),
            json!([{"kind": "issue", "issue_id": issue_a}, {"kind": "log", "cursor": format!("c1.{log_other}.0")}]),
        ] {
            let error = env
                .reports
                .publish(&a, report(project_a, "Bad", evidence.clone()))
                .await
                .unwrap_err();
            assert!(
                matches!(error, ApiError::BadRequest("unknown_evidence")),
                "{evidence}: {error:?}"
            );
        }
        let error = env
            .reports
            .publish(
                &a,
                report(
                    project_b,
                    "Bad",
                    json!([{"kind": "issue", "issue_id": issue_b}]),
                ),
            )
            .await
            .unwrap_err();
        assert!(matches!(error, ApiError::NotFound));
        let in_a = env
            .store
            .list_page(&format!("reports/v1/{}/", a.org), None, 10)
            .await
            .unwrap();
        assert_eq!(
            in_a.keys,
            Vec::<String>::new(),
            "rejected reports leave no object"
        );
        assert_eq!(
            env.reports
                .list(&a, ReportQuery::default())
                .await
                .unwrap()
                .reports
                .len(),
            0
        );

        let published = env
            .reports
            .publish(
                &a,
                report(
                    project_a,
                    "Good",
                    json!([{"kind": "issue", "issue_id": issue_a}]),
                ),
            )
            .await
            .unwrap();
        assert_eq!(
            env.reports
                .get(&a, &published.report.id)
                .await
                .unwrap()
                .document
                .title,
            "Good"
        );
        let error = env.reports.get(&b, &published.report.id).await.unwrap_err();
        assert!(matches!(error, ApiError::NotFound));
        assert_eq!(
            published.notifications,
            EnqueueOutcome::default(),
            "no destinations configured"
        );
        env.shutdown().await;
    }

    #[test]
    fn input_is_bounded_and_plain_text() {
        let base = |findings: Value| json!({"project_id": 1, "title": "T", "summary": "S", "findings": findings});
        let finding = |evidence: Value| json!([{"title": "F", "severity": "low", "detail": "D", "evidence": evidence}]);
        let issue = json!([{"kind": "issue", "issue_id": 1}]);
        let code = |value: Value| match parse(input(value)) {
            Ok(_) => "ok",
            Err(ApiError::BadRequest(code)) => code,
            Err(other) => panic!("{other:?}"),
        };
        assert_eq!(code(base(finding(issue.clone()))), "ok");
        assert_eq!(code(base(json!([]))), "invalid_findings");
        assert_eq!(code(base(finding(json!([])))), "finding_needs_evidence");
        assert_eq!(
            code(base(finding(
                json!([{"kind": "event", "issue_id": 1, "event_id": "nope"}])
            ))),
            "invalid_evidence"
        );
        let mut control = base(finding(issue.clone()));
        control["title"] = json!("Bell\u{7}");
        assert_eq!(code(control), "invalid_title");
        let mut long = base(finding(issue.clone()));
        long["summary"] = json!("x".repeat(MAX_SUMMARY_BYTES + 1));
        assert_eq!(code(long), "invalid_summary");
        let many: Vec<Value> = (0..21)
            .map(|i| json!({"kind": "issue", "issue_id": i}))
            .collect();
        assert_eq!(code(base(finding(json!(many)))), "finding_needs_evidence");
        let html = base(
            json!([{"title": "<script>alert(1)</script>", "severity": "info", "detail": "D", "evidence": issue}]),
        );
        assert_eq!(
            parse(input(html)).unwrap().findings[0].title,
            "<script>alert(1)</script>"
        );
        assert!(serde_json::from_value::<ReportInput>(base(finding(
            json!([{"kind": "log", "cursor": "c1.0.1"}])
        )))
        .is_err());
        for invalid in ["x", "c2.0000000000000000.1.0"] {
            assert!(serde_json::from_value::<ReportInput>(base(finding(
                json!([{"kind": "log", "cursor": invalid}])
            )))
            .is_err());
        }
        assert!(serde_json::from_value::<ReportInput>(
            json!({"project_id": 1, "title": "T", "summary": "S",
            "findings": [], "html": "<b>"})
        )
        .is_err());
    }

    #[tokio::test]
    async fn list_is_newest_first_with_titles_from_the_object_store() {
        let env = open(&data_dir("report-list"), Options::default()).await;
        let (owner, project) = env.org("owner@example.test").await;
        let issue = env.issue(&owner.org, project, "Flaky", 1).await;
        for title in ["First", "Second", "Third"] {
            env.reports
                .publish(
                    &owner,
                    report(
                        project,
                        title,
                        json!([{"kind": "issue", "issue_id": issue}]),
                    ),
                )
                .await
                .unwrap();
        }
        let page = env
            .reports
            .list(
                &owner,
                ReportQuery {
                    limit: Some(2),
                    ..ReportQuery::default()
                },
            )
            .await
            .unwrap();
        let titles = |page: &ReportPage| {
            page.reports
                .iter()
                .map(|r| r.title.clone().unwrap())
                .collect::<Vec<_>>()
        };
        assert_eq!(titles(&page), ["Third", "Second"]);
        let rest = env
            .reports
            .list(
                &owner,
                ReportQuery {
                    before: page.next.clone(),
                    limit: Some(2),
                    ..ReportQuery::default()
                },
            )
            .await
            .unwrap();
        assert_eq!((titles(&rest), rest.next), (vec!["First".to_owned()], None));
        env.shutdown().await;
    }
}
