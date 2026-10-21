use std::collections::BTreeMap;

use axum::{
    body::Bytes,
    extract::Path,
    http::{header, HeaderMap, StatusCode},
    response::IntoResponse,
    Json,
};
use serde_json::{json, Value};

use crate::{
    admission::QueryPermit,
    deployments::{self, Deployment, DeploymentQuery},
    diagnostics::{self, CompareOptions, Count, MatchedBy},
    domain::{OrgId, ProjectId, SourceId},
    error::{ApiError, ApiResult},
    identity::{
        access::OrgAccess,
        projects::{self, Project, Source},
    },
    ingest::{self, TestEvent},
    issues::{self, EventRef, Issue, IssueQuery},
    logs::read::{self, Cursor, CursorToken, LogQuery},
    reports::{Evidence, EvidenceFacts, ReportId, ReportQuery, ReportView},
    runtime::Runtime,
};

use super::{
    org::{agent_setup, grant_rows, revoke_grant_for},
    page::{form_error, project_path, Fields, Flash, OrgCx, Page, Web, WebError, WebResult},
    policy,
};

const ISSUE_SCAN: usize = 1000;
const ISSUE_PAGE: u32 = 50;
const FILTERED_ISSUE_PAGE: u32 = 200;
const LOG_PAGE: usize = 100;

fn query(web: &Web) -> Fields {
    Fields::parse(web.uri.split_once('?').map_or("", |(_, q)| q).as_bytes())
}

fn event_link(issue_path: &str, event_id: &str, source: Option<i64>) -> String {
    let source = source.map(|s| s.to_string()).unwrap_or_default();
    link(issue_path, &[("event", event_id), ("source", &source)])
}

fn link(href: &str, pairs: &[(&str, &str)]) -> String {
    let mut query = url::form_urlencoded::Serializer::new(String::new());
    for (key, value) in pairs.iter().filter(|(_, v)| !v.is_empty()) {
        query.append_pair(key, value);
    }
    let query = query.finish();
    if query.is_empty() {
        href.to_owned()
    } else {
        format!("{href}?{query}")
    }
}

/// Open issues of a project, newest first, at most `ISSUE_SCAN`.
pub async fn open_issues(
    rt: &Runtime,
    access: &OrgAccess,
    project: ProjectId,
) -> ApiResult<Vec<Issue>> {
    let mut out = Vec::new();
    let mut before = None;
    loop {
        let query = IssueQuery {
            project: Some(project.0),
            status: Some("open".into()),
            limit: Some(200),
            before,
        };
        let (page, next) = issues::list(rt, access, query).await?;
        out.extend(page);
        match next {
            Some(next) if out.len() < ISSUE_SCAN => before = Some(next),
            _ => break,
        }
    }
    out.truncate(ISSUE_SCAN);
    Ok(out)
}

pub async fn open_issue_count(
    rt: &Runtime,
    access: &OrgAccess,
    project: ProjectId,
) -> ApiResult<usize> {
    Ok(open_issues(rt, access, project).await?.len())
}

fn level_label(level: &str) -> String {
    let mut chars = level.chars();
    chars
        .next()
        .map_or_else(String::new, |c| c.to_uppercase().chain(chars).collect())
}

fn issue_path(org: &OrgId, project: ProjectId, issue: i64) -> String {
    format!("{}/observe/issues/{issue}", project_path(org, project))
}

fn chart(id: &str, title: &str, span: u8, header: &str, points: Vec<(String, usize)>) -> Value {
    let max = points.iter().map(|(_, v)| *v).max().unwrap_or(0);
    let rows: Vec<Value> = points
        .iter()
        .map(|(label, value)| json!([label, value]))
        .collect();
    json!({
        "id": id,
        "title": title,
        "sentence": "",
        "span": span,
        "points": points.iter().map(|(label, value)| json!({"label": label, "value": value})).collect::<Vec<_>>(),
        "max": max,
        "table": {"caption": title, "headers": [header, "Open issues"], "rows": rows},
    })
}

fn metrics(open: &[Issue]) -> Value {
    let bounded = open.len() >= ISSUE_SCAN;
    let events: i64 = open.iter().map(|i| i.event_count).sum();
    let regressions = open.iter().filter(|i| i.regressed_at.is_some()).count();
    let hint = if bounded {
        "Counted from the newest 1000 open issues."
    } else {
        ""
    };
    let counts = json!([
        {"label": "Open issues", "value": open.len(), "hint": hint},
        {"label": "Events in open issues", "value": events, "hint": hint},
        {"label": "Reopened after a fix", "value": regressions, "hint": hint},
    ]);
    if open.is_empty() {
        return json!({"counts": counts, "charts": []});
    }
    let order = ["fatal", "error", "warning", "info", "debug"];
    let mut by_level: BTreeMap<usize, (String, usize)> = order
        .iter()
        .enumerate()
        .map(|(rank, level)| (rank, (level_label(level), 0)))
        .collect();
    for issue in open {
        let rank = order
            .iter()
            .position(|l| *l == issue.level)
            .unwrap_or(order.len());
        let entry = by_level
            .entry(rank)
            .or_insert_with(|| (level_label(&issue.level), 0));
        if rank == order.len() {
            entry.0 = "Other".into();
        }
        entry.1 += 1;
    }
    let today = chrono::Utc::now().date_naive();
    let days: Vec<(String, usize)> = (0..7)
        .rev()
        .map(|back| {
            let day = today - chrono::Days::new(back);
            let count = open
                .iter()
                .filter(|i| {
                    chrono::DateTime::from_timestamp_micros(i.last_seen)
                        .is_some_and(|t| t.date_naive() == day)
                })
                .count();
            (day.format("%b %-d").to_string(), count)
        })
        .collect();
    json!({
        "counts": counts,
        "charts": [
            chart("open-by-severity", "Open issues by severity", 8, "Severity", by_level.into_values().collect()),
            chart("open-by-day", "Open issues by last seen day", 4, "Day (UTC)", days),
        ],
    })
}

fn evidence_row(org: &OrgId, project: ProjectId, facts: &EvidenceFacts) -> Value {
    let base = project_path(org, project);
    let (label, href) = match (&facts.evidence, &facts.issue, &facts.log) {
        (Evidence::Issue { issue_id }, issue, _) => (
            issue.as_ref().map_or_else(
                || format!("Issue #{issue_id} (no longer available)"),
                |i| format!("Issue #{}: {}", i.id, i.title),
            ),
            issue_path(org, project, *issue_id),
        ),
        (
            Evidence::Event {
                issue_id,
                event_id,
                source_id,
            },
            issue,
            _,
        ) => (
            issue.as_ref().map_or_else(
                || format!("Event {event_id} (no longer available)"),
                |i| format!("Event {event_id} of issue #{}: {}", i.id, i.title),
            ),
            event_link(&issue_path(org, project, *issue_id), event_id, *source_id),
        ),
        (Evidence::Log { cursor }, _, log) => (
            log.as_ref().map_or_else(
                || "Log entry (expired)".to_owned(),
                |l| {
                    format!(
                        "Log entry between {} and {}",
                        policy::format_micros(l.min_ts),
                        policy::format_micros(l.max_ts)
                    )
                },
            ),
            link(&format!("{base}/logs"), &[("cursor", &cursor.to_string())]),
        ),
    };
    json!({"label": label, "href": href})
}

async fn report_value(web: &Web, cx: &OrgCx, view: &ReportView) -> WebResult<Value> {
    let members = crate::account_settings::team(&web.rt, &cx.access).await?;
    let author = members
        .iter()
        .find(|m| m.user_id == view.report.author_id)
        .map_or_else(
            || "A former member".to_owned(),
            |m| m.name.clone().unwrap_or_else(|| m.email.clone()),
        );
    let document = &view.document;
    let mut paragraphs: Vec<String> = document
        .summary
        .split("\n\n")
        .map(str::trim)
        .filter(|p| !p.is_empty())
        .map(str::to_owned)
        .collect();
    for finding in &document.findings {
        paragraphs.push(format!(
            "{} ({}). {}",
            finding.title,
            finding.severity.as_str(),
            finding.detail
        ));
    }
    let evidence: Vec<Value> = view
        .evidence
        .iter()
        .map(|f| evidence_row(&cx.org.id, view.report.project_id, f))
        .collect();
    Ok(json!({
        "title": document.title,
        "published_at": policy::format_micros(document.created_at),
        "author_name": author,
        "paragraphs": paragraphs,
        "evidence": evidence,
    }))
}

async fn render_report(
    web: &Web,
    cx: &OrgCx,
    project: &Project,
    view: Option<ReportView>,
) -> WebResult {
    let mut page = web.project_page(cx, project, "Report", "report");
    let report = match &view {
        Some(view) => report_value(web, cx, view).await?,
        None => Value::Null,
    };
    let open = open_issues(&web.rt, &cx.access, project.id).await?;
    page.set("report", report)
        .set("metrics", metrics(&open))
        .set("page_heading", false);
    Ok(web.render(page, "projects/report.html"))
}

pub async fn report(web: Web, Path((org, project)): Path<(String, i64)>) -> WebResult {
    let cx = web.member(&org).await?;
    let project = cx.project(project)?;
    let query = ReportQuery {
        project: Some(project.id.0),
        before: None,
        limit: Some(1),
    };
    let latest = web
        .svc
        .reports
        .list(&cx.access, query)
        .await?
        .reports
        .into_iter()
        .next();
    let view = match latest {
        Some(item) => Some(web.svc.reports.get(&cx.access, &item.report.id).await?),
        None => None,
    };
    render_report(&web, &cx, project, view).await
}

pub async fn report_by_id(
    web: Web,
    Path((org, project, report)): Path<(String, i64, String)>,
) -> WebResult {
    let cx = web.member(&org).await?;
    let project = cx.project(project)?;
    let id: ReportId = report.parse().map_err(|_| WebError::NotFound)?;
    let view = web.svc.reports.get(&cx.access, &id).await?;
    if view.report.project_id != project.id {
        return Err(WebError::NotFound);
    }
    render_report(&web, &cx, project, Some(view)).await
}

fn choices(current: &str, options: &[(&str, &str)]) -> Vec<Value> {
    options
        .iter()
        .map(|(id, label)| json!({"id": id, "label": label, "current": *id == current}))
        .collect()
}

pub async fn issues(web: Web, Path((org, project)): Path<(String, i64)>) -> WebResult {
    let cx = web.member(&org).await?;
    let project = cx.project(project)?;
    let base = project_path(&cx.org.id, project.id);
    let observe = format!("{base}/observe");
    let query = query(&web);
    let q = query.get("q").trim().to_owned();
    let level = query.get("level").to_owned();
    let status = match query.get("status") {
        "" => "open",
        other => other,
    }
    .to_owned();
    let before = match query.get("before") {
        "" => None,
        raw => Some(issues::IssueCursor::parse(raw).ok_or(WebError::NotFound)?),
    };
    let mut page = web.project_page(&cx, project, "Issues", "issues");
    let sources = projects::sources(&web.rt, &cx.access, project.id).await?;
    let filtered = !q.is_empty() || !level.is_empty();
    let (rows, next) = if sources.is_empty() {
        (Vec::new(), None)
    } else {
        let list = IssueQuery {
            project: Some(project.id.0),
            status: (status != "all").then(|| status.clone()),
            limit: Some(if filtered {
                FILTERED_ISSUE_PAGE
            } else {
                ISSUE_PAGE
            }),
            before,
        };
        match issues::list(&web.rt, &cx.access, list).await {
            Ok(result) => result,
            Err(ApiError::BadRequest(_)) => return Err(WebError::NotFound),
            Err(error) => return Err(error.into()),
        }
    };
    let needle = q.to_lowercase();
    let rows: Vec<Value> = rows
        .iter()
        .filter(|i| level.is_empty() || i.level == level)
        .filter(|i| {
            needle.is_empty()
                || i.title.to_lowercase().contains(&needle)
                || i.culprit
                    .as_deref()
                    .is_some_and(|c| c.to_lowercase().contains(&needle))
        })
        .map(|i| {
            let context = [Some(i.environment.as_str()), i.last_release.as_deref()]
                .into_iter()
                .flatten()
                .collect::<Vec<_>>()
                .join(" · ");
            json!({
                "title": i.title,
                "href": issue_path(&cx.org.id, project.id, i.id),
                "level_label": level_label(&i.level),
                "status_label": level_label(&i.status),
                "context": context,
                "event_count": i.event_count,
                "last_seen": policy::relative_micros(i.last_seen),
                "last_seen_iso": policy::format_micros_iso(i.last_seen),
                "last_seen_title": policy::format_micros(i.last_seen),
            })
        })
        .collect();
    let filters = [
        ("q", q.as_str()),
        ("level", level.as_str()),
        (
            "status",
            if status == "open" {
                ""
            } else {
                status.as_str()
            },
        ),
    ];
    let next_href = next.map(|n| {
        let mut pairs = filters.to_vec();
        let n = n.to_string();
        pairs.push(("before", &n));
        link(&observe, &pairs)
    });
    let resolved_href = if rows.is_empty() && !filtered && status == "open" && !sources.is_empty() {
        let probe = IssueQuery {
            project: Some(project.id.0),
            status: Some("resolved".into()),
            limit: Some(1),
            before: None,
        };
        let (resolved, _) = issues::list(&web.rt, &cx.access, probe).await?;
        (!resolved.is_empty()).then(|| link(&observe, &[("status", "resolved")]))
    } else {
        None
    };
    page.set("form_action", observe.as_str())
        .set("heading", "Issues")
        .set("sources", sources.iter().map(|s| json!({"name": s.name})).collect::<Vec<_>>())
        .set("issue_query", json!({"q": q, "level": level, "status": status}))
        .set("issue_levels", choices(&level, &[("", "All severities"), ("fatal", "Fatal"), ("error", "Error"), ("warning", "Warning"), ("info", "Info"), ("debug", "Debug")]))
        .set("issue_statuses", choices(&status, &[("open", "Open"), ("resolved", "Resolved"), ("ignored", "Ignored"), ("all", "All")]))
        .set("filters_active", filtered || status != "open")
        .set("filter_reset_href", observe.as_str())
        .set("resolved_href", resolved_href.clone().unwrap_or_default())
        .set("resolved_label", if resolved_href.is_some() { "Show resolved issues" } else { "" })
        .set("show_status_column", status == "all")
        .set("issues", rows)
        .set("issue_page", json!({
            "next_href": next_href.unwrap_or_default(),
            "prev_href": if before.is_some() { link(&observe, &filters) } else { String::new() },
        }));
    Ok(web.render(page, "observe/index.html"))
}

fn count_label(count: Count) -> String {
    if count.lower_bound {
        format!("at least {}", count.value)
    } else {
        count.value.to_string()
    }
}

fn short_commit(deployment: &Deployment) -> String {
    deployment
        .commit_sha
        .as_deref()
        .map(|sha| sha[..12].to_owned())
        .unwrap_or_default()
}

fn window_label(secs: i64) -> String {
    if secs >= 120 && secs % 60 == 0 {
        format!("{} minutes", secs / 60)
    } else {
        format!("{secs} seconds")
    }
}

fn comparison_view(org: &OrgId, project: ProjectId, c: &diagnostics::Comparison) -> Value {
    let issues = |page: &diagnostics::IssuePage| -> Vec<Value> {
        page.items
            .iter()
            .map(|i| {
                json!({
                    "title": i.title,
                    "href": issue_path(org, project, i.id),
                    "first_seen": policy::format_micros(i.first_seen),
                    "in_version": i.seen_in_version,
                })
            })
            .collect()
    };
    let window = |w: &diagnostics::Window| {
        json!({
            "events": count_label(w.events),
            "issues": count_label(w.issues),
            "rate": format!("{:.2} per minute", w.events_per_minute),
        })
    };
    let mut notes = Vec::new();
    if c.coverage.shortened_to_elapsed {
        notes.push(
            "This deployment is recent, so both windows cover only the time since it.".to_owned(),
        );
    }
    if !c.coverage.overlapping_deployments.is_empty() {
        let versions: Vec<&str> = c
            .coverage
            .overlapping_deployments
            .iter()
            .map(|d| d.version.as_str())
            .collect();
        notes.push(format!(
            "Other deployments of this environment fall inside these windows: {}.",
            versions.join(", ")
        ));
    }
    if c.coverage.overlapping_deployments_truncated {
        notes.push("Only the first 10 overlapping deployments are shown.".to_owned());
    }
    if c.coverage.after_events_without_release.value > 0 {
        notes.push(format!(
            "{} events after the deployment have no release.",
            count_label(c.coverage.after_events_without_release)
        ));
    }
    if c.coverage.after_events_other_release.value > 0 {
        notes.push(format!(
            "{} events after the deployment report a different release.",
            count_label(c.coverage.after_events_other_release)
        ));
    }
    if c.coverage.before_truncated_by_retention {
        notes.push(
            "Some or all of the earlier window is past error retention, so its count is incomplete."
                .to_owned(),
        );
    }
    if c.coverage.after_truncated_by_retention {
        notes.push(
            "Some or all of the later window is past error retention, so its count is incomplete."
                .to_owned(),
        );
    }
    json!({
        "version": c.deployment.version,
        "environment": c.deployment.environment,
        "commit": short_commit(&c.deployment),
        "deployed_at": policy::format_micros(c.deployment.deployed_at),
        "previous": c.previous.as_ref().map(|p| format!("{} at {}", p.version, policy::format_micros(p.deployed_at))),
        "window": window_label(c.window_secs),
        "before": window(&c.before),
        "after": window(&c.after),
        "new_issues": issues(&c.newly_observed),
        "new_total": count_label(c.newly_observed.total),
        "regressed": issues(&c.regressed),
        "regressed_total": count_label(c.regressed.total),
        "notes": notes,
        "interpretation": "A change after a deployment shows when errors happened. It does not prove the deployment caused them.",
    })
}

pub async fn deployments(web: Web, Path((org, project)): Path<(String, i64)>) -> WebResult {
    let cx = web.member(&org).await?;
    let project = cx.project(project)?;
    let base = format!("{}/deployments", project_path(&cx.org.id, project.id));
    let query = query(&web);
    let before = query.get("before");
    let (list, next) = deployments::list(
        &web.rt,
        &cx.access,
        project.id,
        DeploymentQuery {
            environment: None,
            limit: Some(20),
            before: (!before.is_empty()).then(|| before.to_owned()),
        },
    )
    .await?;
    let selected = query
        .get("deployment")
        .parse::<i64>()
        .ok()
        .or_else(|| list.first().map(|d| d.id));
    let mut page = web.project_page(&cx, project, "Deployments", "deployments");
    let comparison = match selected {
        None => Value::Null,
        Some(id) => match web.admit_query(&cx.access.org)? {
            Err(busy) => {
                page.busy(&busy).set("query_busy", busy.message());
                Value::Null
            }
            Ok(admitted) => match diagnostics::compare(
                &web.rt,
                &cx.access,
                &admitted,
                id,
                CompareOptions {
                    window_secs: None,
                    limit: Some(20),
                    new_after: None,
                    regressed_after: None,
                },
            )
            .await
            {
                Ok(c) if c.deployment.project_id == project.id.0 => {
                    comparison_view(&cx.org.id, project.id, &c)
                }
                Ok(_) | Err(ApiError::NotFound) => return Err(WebError::NotFound),
                Err(error) => return Err(error.into()),
            },
        },
    };
    let rows: Vec<Value> = list
        .iter()
        .map(|d| {
            json!({
                "version": d.version,
                "environment": d.environment,
                "commit": short_commit(d),
                "deployed_at": policy::format_micros(d.deployed_at),
                "href": link(&base, &[("deployment", &d.id.to_string()), ("before", before)]),
                "current": Some(d.id) == selected,
            })
        })
        .collect();
    page.set("deployments", rows)
        .set("comparison", comparison)
        .set(
            "record_path",
            format!(
                "/api/orgs/{}/projects/{}/deployments",
                cx.org.id, project.id.0
            ),
        )
        .set(
            "next_href",
            next.map(|n| link(&base, &[("before", &n)]))
                .unwrap_or_default(),
        )
        .set(
            "prev_href",
            if before.is_empty() {
                String::new()
            } else {
                base.clone()
            },
        );
    Ok(web.render(page, "deployments/index.html"))
}

pub async fn issue(web: Web, Path((org, project, issue)): Path<(String, i64, i64)>) -> WebResult {
    let cx = web.member(&org).await?;
    let project = cx.project(project)?;
    let (issue, latest) = issues::get(&web.rt, &cx.access, issue).await?;
    if issue.project_id != project.id.0 {
        return Err(WebError::NotFound);
    }
    let query = query(&web);
    let path = issue_path(&cx.org.id, project.id, issue.id);
    let raw = query.get("stack") == "raw";
    let selected = match query.get("event") {
        "" => latest.map(|e| EventRef {
            event_id: e.event_id,
            source: Some(e.source_id),
        }),
        id => Some(EventRef {
            event_id: id.to_owned(),
            source: query.get("source").parse().ok(),
        }),
    };
    let admitted = web.admit_query(&cx.access.org)?;
    let mut page = web.project_page(&cx, project, &issue.title, "issues");
    let mut release = issue.last_release.clone();
    let mut unhandled = false;
    if let Some(selector) = &selected {
        match issues::event_payload(&web.rt, &cx.access, issue.id, selector).await {
            Ok((event, payload)) => {
                let view = policy::map_event(&payload);
                release = event.release.clone().or(release);
                for key in [
                    "frames",
                    "event_breadcrumbs",
                    "request",
                    "stack_summary",
                    "raw_stack",
                ] {
                    page.set(key, view[key].clone());
                }
                unhandled = view["unhandled"] == true;
                if let Some(deployment) =
                    diagnostics::deployment_at(&web.rt, &cx.access, &issue, event.occurred_at)
                        .await?
                {
                    page.set(
                        "event_deployment",
                        format!(
                            "Deployment {} at {} was the latest before this event.",
                            deployment.version,
                            policy::format_micros(deployment.deployed_at)
                        ),
                    );
                }
                let logs = match &admitted {
                    Ok(admitted) => {
                        related_logs(
                            &web,
                            &cx.access,
                            admitted,
                            &issue,
                            &event,
                            &project_path(&cx.org.id, project.id),
                        )
                        .await?
                    }
                    Err(busy) => json!({"summary": busy.message(), "unread": true}),
                };
                page.set("related_logs", logs);
            }
            Err(ApiError::NotFound) => {
                page.set("load_error", "That event is not stored for this issue.");
            }
            Err(ApiError::Conflict("ambiguous_event")) => {
                page.set(
                    "load_error",
                    "Two sources sent an event with this ID. Choose the event from the occurrence list.",
                );
            }
            Err(ApiError::Unavailable(_)) => {
                page.set("load_error", "Event details could not be read. Try again.");
            }
            Err(error) => return Err(error.into()),
        }
        let source = selector.source.map(|s| s.to_string()).unwrap_or_default();
        let event_query = |stack: &str| {
            link(
                &path,
                &[
                    ("event", &selector.event_id),
                    ("source", &source),
                    ("stack", stack),
                ],
            )
        };
        page.set(
            "stack_links",
            json!([
                {"label": "Full", "href": event_query(""), "current": !raw},
                {"label": "Raw", "href": event_query("raw"), "current": raw},
            ]),
        );
    }
    let occurrences: Vec<Value> = issues::events(&web.rt, &cx.access, issue.id, Some(10))
        .await?
        .iter()
        .map(|e| {
            json!({
                "label": policy::format_micros(e.received_at),
                "href": event_link(&path, &e.event_id, Some(e.source_id)),
                "current": selected.as_ref().is_some_and(|s| {
                    s.event_id == e.event_id && s.source.is_none_or(|source| source == e.source_id)
                }),
            })
        })
        .collect();
    match &admitted {
        Err(busy) => {
            if let Some(fixed) = issue.resolved_at {
                page.set(
                    "recurrence",
                    json!({
                        "resolved": format!("Last resolved {}.", policy::format_micros(fixed)),
                        "summary": busy.message(),
                    }),
                );
            }
            page.busy(busy);
        }
        Ok(admitted) => {
            let recurrence =
                diagnostics::recurrence(&web.rt, &cx.access, admitted, issue.id).await?;
            if let Some(fixed) = recurrence.resolved_at {
                let after = recurrence.events_after_fix;
                page.set(
                    "recurrence",
                    json!({
                        "resolved": format!("Last resolved {}.", policy::format_micros(fixed)),
                        "summary": match after.value {
                            0 => "No events occurred after the fix.".to_owned(),
                            1 if !after.lower_bound => "1 event occurred after the fix.".to_owned(),
                            _ => format!("{} events occurred after the fix.", count_label(after)),
                        },
                        "releases": recurrence.releases_after_fix.iter().map(|r| json!({
                            "release": r.release.clone().unwrap_or_else(|| "No release".to_owned()),
                            "events": r.events,
                        })).collect::<Vec<_>>(),
                        "deployments": recurrence.deployments_since_fix.iter().map(|d| format!(
                            "{} at {}", d.version, policy::format_micros(d.deployed_at)
                        )).collect::<Vec<_>>(),
                        "releases_truncated": recurrence.releases_truncated,
                        "deployments_truncated": recurrence.deployments_truncated,
                    }),
                );
            }
        }
    }
    let action = |allowed: bool, verb: &str| {
        if allowed {
            format!("{path}/{verb}")
        } else {
            String::new()
        }
    };
    page.set("issue", json!({
            "heading": issue.title,
            "level_label": level_label(&issue.level),
            "status_label": level_label(&issue.status),
            "unhandled": unhandled,
            "culprit": issue.culprit,
            "impact": format!("{} {}", issue.event_count, if issue.event_count == 1 { "event" } else { "events" }),
            "first_seen": policy::format_micros(issue.first_seen),
            "last_seen": policy::format_micros(issue.last_seen),
            "release": release,
        }))
        .set("merged_parent", Value::Null)
        .set("issue_tab", "event")
        .set("issue_tabs", Vec::<Value>::new())
        .set("occurrences", occurrences)
        .set("stack_view", if raw { "raw" } else { "full" })
        .set("resolve_action", action(issue.status != "resolved", "resolve"))
        .set("reopen_action", action(issue.status != "open", "reopen"))
        .set("ignore_action", action(issue.status == "open", "ignore"));
    Ok(web.render(page, "observe/show.html"))
}

async fn related_logs(
    web: &Web,
    access: &OrgAccess,
    admitted: &QueryPermit,
    issue: &Issue,
    event: &issues::EventSummary,
    project_base: &str,
) -> Result<Value, WebError> {
    const WINDOW_SECS: i64 = 300;
    let logs = match diagnostics::correlated_logs(
        &web.rt,
        access,
        admitted,
        issue,
        event,
        WINDOW_SECS,
        10,
    )
    .await
    {
        Ok(logs) => logs,
        Err(ApiError::Unavailable(_)) => {
            return Ok(
                json!({"summary": "Related log lines could not be read. Try again.", "unread": true}),
            );
        }
        Err(error) => return Err(error.into()),
    };
    let mut summary = match logs.matched_by {
        MatchedBy::TraceId => {
            "Log lines with this event's trace ID, within 5 minutes of it.".to_owned()
        }
        MatchedBy::RequestId => {
            "Log lines with this event's request ID, within 5 minutes of it.".to_owned()
        }
        MatchedBy::Time => {
            let mut text = "Log lines within 5 minutes of this event".to_owned();
            if let Some(service) = &logs.filters.service {
                text.push_str(&format!(" from service {service}"));
            }
            if let Some(release) = &logs.filters.release {
                text.push_str(&format!(" with release {release}"));
            }
            text.push('.');
            text
        }
    };
    if logs.coverage.missing_objects > 0 {
        summary.push_str(&format!(
            " {} stored log batches could not be read.",
            logs.coverage.missing_objects
        ));
    }
    if logs.coverage.truncated_by.is_some() {
        summary.push_str(" More lines may match.");
    }
    let href = match (&logs.filters.trace_id, &logs.filters.request_id) {
        (Some(trace), _) => link(&format!("{project_base}/logs"), &[("trace_id", trace)]),
        (None, Some(request)) => link(&format!("{project_base}/logs"), &[("request_id", request)]),
        (None, None) => String::new(),
    };
    let rows: Vec<Value> = logs
        .rows
        .iter()
        .map(|row| {
            json!({
                "at": policy::format_micros(row.ts),
                "level": row.level,
                "message": row.body,
            })
        })
        .collect();
    Ok(json!({"summary": summary, "rows": rows, "href": href}))
}

pub async fn set_issue_status(
    web: Web,
    Path((org, project, issue, action)): Path<(String, i64, i64, String)>,
    body: Bytes,
) -> WebResult {
    let fields = Fields::parse(&body);
    let cx = web.member_form(&org, &fields).await?;
    let project = cx.project(project)?;
    let (status, message) = match action.as_str() {
        "resolve" => ("resolved", "Issue resolved."),
        "ignore" => ("ignored", "Issue ignored."),
        "reopen" => ("open", "Issue reopened."),
        _ => return Err(WebError::NotFound),
    };
    let (current, _) = issues::get(&web.rt, &cx.access, issue).await?;
    if current.project_id != project.id.0 {
        return Err(WebError::NotFound);
    }
    issues::set_status(&web.rt, &cx.access, issue, status).await?;
    Ok(web.redirect_flash(
        &issue_path(&cx.org.id, project.id, issue),
        Flash::Info,
        message,
    ))
}

pub async fn logs(web: Web, Path((org, project)): Path<(String, i64)>) -> WebResult {
    let cx = web.member(&org).await?;
    let project = cx.project(project)?;
    let logs_path = format!("{}/logs", project_path(&cx.org.id, project.id));
    let query = query(&web);
    let (q, level, from, to, trace, request) = (
        query.get("q").trim(),
        query.get("level"),
        query.get("from").trim(),
        query.get("to").trim(),
        query.get("trace_id").trim(),
        query.get("request_id").trim(),
    );
    let mut page = web.project_page(&cx, project, "Logs", "logs");
    let mut problems = Vec::new();
    let mut time = |value: &str, end: bool, label: &str| {
        if value.is_empty() {
            return None;
        }
        let parsed = policy::parse_form_time(value, end);
        if parsed.is_none() {
            problems.push(format!(
                "{label} must look like 2026-10-16 or 2026-10-16 14:30 (UTC)."
            ));
        }
        parsed
    };
    let since = time(from, false, "From");
    let until = time(to, true, "To");
    let before = match query.get("cursor") {
        "" => query.get("before").to_owned(),
        cursor => CursorToken::parse(cursor)
            .map(|token| {
                token
                    .epoch
                    .token(Cursor {
                        seq: token.at.seq,
                        entry: token.at.entry.saturating_add(1),
                    })
                    .to_string()
            })
            .unwrap_or_default(),
    };
    let level_filter = if level.is_empty() || level == "all" {
        None
    } else {
        Some(level.to_owned())
    };
    let search = LogQuery {
        project: Some(project.id.0),
        level: level_filter.clone(),
        trace_id: (!trace.is_empty()).then(|| trace.to_owned()),
        request_id: (!request.is_empty()).then(|| request.to_owned()),
        q: (!q.is_empty()).then(|| q.to_owned()),
        since,
        until,
        limit: Some(LOG_PAGE),
        before: (!before.is_empty()).then_some(before.clone()),
        ..LogQuery::default()
    };
    let filters = [
        ("q", q),
        ("level", level_filter.as_deref().unwrap_or("")),
        ("from", from),
        ("to", to),
        ("trace_id", trace),
        ("request_id", request),
    ];
    let searched = match web.admit_query(&cx.access.org)? {
        Ok(admitted) => Ok(read::search(&web.rt, &cx.access, &admitted, search).await),
        Err(busy) => Err(busy),
    };
    let no_page = json!({"next_href": "", "prev_href": "", "incomplete": false, "gap": false, "gap_message": "", "coverage_message": ""});
    let (rows, page_data) = match searched {
        Err(busy) => {
            page.busy(&busy).set("query_busy", busy.message());
            (Vec::new(), no_page)
        }
        Ok(Ok(result)) => {
            let rows: Vec<Value> = result
                .rows
                .iter()
                .map(|row| {
                    json!({
                        "id": row.cursor,
                        "at": policy::format_micros(row.ts),
                        "level": row.level,
                        "message": row.body,
                        "trace_id": row.trace_id,
                        "issue_href": "",
                    })
                })
                .collect();
            let coverage = &result.coverage;
            let mut message = format!("Searched {} stored log batches.", coverage.objects);
            if coverage.reconciling {
                message.push_str(" Recent logs are still being indexed.");
            }
            if coverage.missing_objects > 0 {
                message.push_str(&format!(
                    " {} stored log batches could not be read, so their lines are missing.",
                    coverage.missing_objects
                ));
            }
            let next_href = result.next.map(|n| {
                let n = n.to_string();
                let mut pairs = filters.to_vec();
                pairs.push(("before", &n));
                link(&logs_path, &pairs)
            });
            (
                rows,
                json!({
                    "next_href": next_href.unwrap_or_default(),
                    "prev_href": if before.is_empty() { String::new() } else { link(&logs_path, &filters) },
                    "incomplete": coverage.truncated_by.is_some() || coverage.missing_objects > 0,
                    "gap": false,
                    "gap_message": "",
                    "coverage_message": message,
                }),
            )
        }
        Ok(Err(
            ApiError::BadRequest(code) | ApiError::Conflict(code @ "cursor_reset_required"),
        )) => {
            problems.push(match code {
                "invalid_level" => "Choose a level from the list.".into(),
                "invalid_trace_id" => "A trace id has 32 hexadecimal characters.".into(),
                "invalid_identifier" => "A request id has at most 200 characters.".into(),
                "invalid_cursor" | "cursor_reset_required" => {
                    "That page link is no longer valid. Search again.".into()
                }
                _ => "Check the search fields.".into(),
            });
            (Vec::new(), no_page)
        }
        Ok(Err(error)) => return Err(error.into()),
    };
    if let Some(problem) = problems.first() {
        page.notice(Flash::Error, problem);
    }
    let tail = link(
        &format!("/api/orgs/{}/logs/tail", cx.org.id),
        &[
            ("project", &project.id.0.to_string()),
            ("level", level_filter.as_deref().unwrap_or("")),
        ],
    );
    page.set("form_action", logs_path.as_str())
        .set(
            "log_query",
            json!({"q": q, "level": level, "from": from, "to": to, "trace_id": trace, "request_id": request}),
        )
        .set(
            "log_levels",
            choices(
                level_filter.as_deref().unwrap_or("all"),
                &[
                    ("all", "All levels"),
                    ("trace", "Trace"),
                    ("debug", "Debug"),
                    ("info", "Info"),
                    ("warn", "Warn"),
                    ("error", "Error"),
                    ("fatal", "Fatal"),
                ],
            ),
        )
        .set("log_events", rows)
        .set("log_page", page_data)
        .set("filters_active", filters.iter().any(|(_, v)| !v.is_empty()))
        .set("tail_url", tail)
        .set("tail_unavailable", false);
    Ok(web.render(page, "logs/index.html"))
}

fn active_keys(source: &Source) -> impl Iterator<Item = &projects::KeyInfo> {
    source.keys.iter().filter(|k| !k.revoked)
}

fn source_row(org: &OrgId, project: ProjectId, source: &Source) -> Value {
    let active = active_keys(source).next().is_some();
    json!({
        "name": source.name,
        "href": format!("{}/sources/{}", project_path(org, project), source.id.0),
        "environment": source.environment.as_str(),
        "status_label": if active { "Active" } else { "Revoked" },
    })
}

async fn sources_page(web: &Web, cx: &OrgCx, project: &Project) -> WebResult<Page> {
    let mut page = web.project_page(cx, project, "Sources", "source");
    let sources = projects::sources(&web.rt, &cx.access, project.id).await?;
    page.set(
        "sources",
        sources
            .iter()
            .map(|s| source_row(&cx.org.id, project.id, s))
            .collect::<Vec<_>>(),
    )
    .set(
        "form_action",
        format!("{}/sources", project_path(&cx.org.id, project.id)),
    );
    Ok(page)
}

pub async fn sources(web: Web, Path((org, project)): Path<(String, i64)>) -> WebResult {
    let cx = web.member(&org).await?;
    let project = cx.project(project)?;
    let page = sources_page(&web, &cx, project).await?;
    Ok(web.render(page, "sources/index.html"))
}

async fn source_page(web: &Web, cx: &OrgCx, project: &Project, source: &Source) -> WebResult<Page> {
    let mut page = web.project_page(cx, project, &source.name, "source");
    let active = active_keys(source).last();
    let path = format!(
        "{}/sources/{}",
        project_path(&cx.org.id, project.id),
        source.id.0
    );
    let arrival = ingest::arrival(&web.rt, &cx.org.id, project.id, source.id).await?;
    let manage = cx.access.role.can_manage() && active.is_some();
    let recent = IssueQuery {
        project: Some(project.id.0),
        status: None,
        limit: Some(50),
        before: None,
    };
    let (recent, _) = issues::list(&web.rt, &cx.access, recent).await?;
    let release = recent
        .iter()
        .filter(|i| i.environment == source.environment.as_str())
        .find_map(|i| i.last_release.as_deref())
        .map(|r| format!("Latest release seen in {} errors: {r}", source.environment));
    page.set(
        "source",
        json!({
            "name": source.name,
            "environment": source.environment.as_str(),
            "status": if active.is_some() { "active" } else { "revoked" },
            "status_label": if active.is_some() { "Status" } else { "Revoked" },
            "answer": match (active.is_some(), arrival.errors_received || arrival.logs_received) {
                (false, _) => "Not accepting events",
                (true, false) => "No event received yet",
                (true, true) => "Events received",
            },
            "secret_prefix": active.map(|k| k.hint.clone()),
        }),
    )
    .set("arrival", json!(arrival))
    .set("source_path", path.as_str())
    .set("status_url", format!("{path}/status"))
    .set(
        "test_event_action",
        if manage {
            format!("{path}/test-event")
        } else {
            String::new()
        },
    )
    .set("mcp_endpoint", web.rt.settings.oauth.resource.as_str())
    .set("release_note", release.unwrap_or_default())
    .set(
        "rotate_action",
        if manage {
            format!("{path}/rotate")
        } else {
            String::new()
        },
    )
    .set(
        "revoke_action",
        if manage {
            format!("{path}/revoke")
        } else {
            String::new()
        },
    );
    Ok(page)
}

async fn find_source(web: &Web, cx: &OrgCx, project: &Project, id: i64) -> WebResult<Source> {
    projects::sources(&web.rt, &cx.access, project.id)
        .await?
        .into_iter()
        .find(|s| s.id.0 == id)
        .ok_or(WebError::NotFound)
}

fn with_dsn(web: &Web, mut page: Page, dsn: &str) -> axum::response::Response {
    page.set("dsn", dsn).status(StatusCode::CREATED);
    web.render(page, "sources/show.html")
}

pub async fn source(web: Web, Path((org, project, source)): Path<(String, i64, i64)>) -> WebResult {
    let cx = web.member(&org).await?;
    let project = cx.project(project)?;
    let source = find_source(&web, &cx, project, source).await?;
    let page = source_page(&web, &cx, project, &source).await?;
    Ok(web.render(page, "sources/show.html"))
}

pub async fn source_status(
    web: Web,
    Path((org, project, source)): Path<(String, i64, i64)>,
) -> WebResult {
    let cx = web.member(&org).await?;
    let project = cx.project(project)?;
    let source = find_source(&web, &cx, project, source).await?;
    let arrival = ingest::arrival(&web.rt, &cx.org.id, project.id, source.id).await?;
    Ok(([(header::CACHE_CONTROL, "no-store")], Json(arrival)).into_response())
}

fn test_event_message(outcome: &TestEvent) -> String {
    match outcome {
        TestEvent::Stored => format!(
            "Test event stored. It is in Issues as \"{}\".",
            ingest::TEST_EVENT_MESSAGE
        ),
        TestEvent::Refused("subscription_required") => {
            "The trial has ended. Subscribe on the billing page to accept events again.".into()
        }
        TestEvent::Refused("monthly_quota_exceeded") => {
            "This month's error allowance is used up. Events are accepted again next month.".into()
        }
        TestEvent::Refused("rate_limited") => {
            "This organization is over its request rate. Try again in a minute.".into()
        }
        TestEvent::Refused(code) => {
            format!("The organization's data controls refused the test event ({code}).")
        }
    }
}

/// Answers JSON to the page script and redirects a plain form post, so the
/// one-time DSN page stays open when scripts run.
pub async fn send_test_event(
    web: Web,
    Path((org, project, source)): Path<(String, i64, i64)>,
    headers: HeaderMap,
    body: Bytes,
) -> WebResult {
    let fields = Fields::parse(&body);
    let cx = web.member_form(&org, &fields).await?;
    cx.access.require_manage()?;
    let project = cx.project(project)?;
    let source = find_source(&web, &cx, project, source).await?;
    let outcome = ingest::test_event(&web.rt, &cx.org.id, source.id).await?;
    let message = test_event_message(&outcome);
    let stored = outcome == TestEvent::Stored;
    let json = headers
        .get(header::ACCEPT)
        .and_then(|v| v.to_str().ok())
        .is_some_and(|v| v.contains("application/json"));
    if json {
        return Ok((
            [(header::CACHE_CONTROL, "no-store")],
            Json(json!({"stored": stored, "message": message})),
        )
            .into_response());
    }
    let target = format!(
        "{}/sources/{}",
        project_path(&cx.org.id, project.id),
        source.id.0
    );
    let kind = if stored { Flash::Info } else { Flash::Error };
    Ok(web.redirect_flash(&target, kind, &message))
}

pub async fn create_source(
    web: Web,
    Path((org, project)): Path<(String, i64)>,
    body: Bytes,
) -> WebResult {
    let fields = Fields::parse(&body);
    let cx = web.member_form(&org, &fields).await?;
    let project = cx.project(project)?;
    match projects::create_source(
        &web.rt,
        &cx.access,
        project.id,
        fields.get("name"),
        fields.get("environment"),
    )
    .await
    {
        Ok((source, key)) => {
            let page = source_page(&web, &cx, project, &source).await?;
            Ok(with_dsn(&web, page, &key.dsn))
        }
        Err(error) => {
            let (field, message) = form_error(error)?;
            let mut page = sources_page(&web, &cx, project).await?;
            page.invalid(
                field,
                message,
                json!({"name": fields.get("name"), "environment": fields.get("environment")}),
            );
            Ok(web.render(page, "sources/index.html"))
        }
    }
}

/// Mints a new key, then revokes the older active keys of the source.
pub async fn rotate_source(
    web: Web,
    Path((org, project, source)): Path<(String, i64, i64)>,
    body: Bytes,
) -> WebResult {
    let fields = Fields::parse(&body);
    let cx = web.member_form(&org, &fields).await?;
    let project = cx.project(project)?;
    let before = find_source(&web, &cx, project, source).await?;
    if active_keys(&before).next().is_none() {
        return Err(WebError::NotFound);
    }
    let key = projects::create_key(&web.rt, &cx.access, SourceId(source)).await?;
    let mut failed = false;
    for old in active_keys(&before) {
        failed |= projects::revoke_key(&web.rt, &cx.access, SourceId(source), old.id)
            .await
            .is_err();
    }
    let after = find_source(&web, &cx, project, source).await?;
    let mut page = source_page(&web, &cx, project, &after).await?;
    if failed {
        page.notice(Flash::Error, "The new key works. An older key could not be revoked and still accepts events. Rotate again to retry.");
    }
    Ok(with_dsn(&web, page, &key.dsn))
}

pub async fn revoke_source(
    web: Web,
    Path((org, project, source)): Path<(String, i64, i64)>,
    body: Bytes,
) -> WebResult {
    let fields = Fields::parse(&body);
    let cx = web.member_form(&org, &fields).await?;
    let project = cx.project(project)?;
    let found = find_source(&web, &cx, project, source).await?;
    for key in active_keys(&found) {
        projects::revoke_key(&web.rt, &cx.access, found.id, key.id).await?;
    }
    let target = format!(
        "{}/sources/{}",
        project_path(&cx.org.id, project.id),
        source
    );
    Ok(web.redirect_flash(
        &target,
        Flash::Info,
        "Source revoked. It no longer accepts events.",
    ))
}

pub async fn access(web: Web, Path((org, project)): Path<(String, i64)>) -> WebResult {
    let cx = web.member(&org).await?;
    let project = cx.project(project)?;
    let mut page = web.project_page(&cx, project, "Agent access", "access");
    let revoke_base = format!("{}/access/grants", project_path(&cx.org.id, project.id));
    page.set("grants", grant_rows(&web, &cx, &revoke_base).await?);
    agent_setup(&web, &mut page);
    Ok(web.render(page, "oauth/grants.html"))
}

pub async fn revoke_grant(
    web: Web,
    Path((org, project, grant)): Path<(String, i64, i64)>,
    body: Bytes,
) -> WebResult {
    let fields = Fields::parse(&body);
    let cx = web.member_form(&org, &fields).await?;
    let project = cx.project(project)?;
    let target = format!("{}/access", project_path(&cx.org.id, project.id));
    revoke_grant_for(&web, &cx, grant, &target).await
}
