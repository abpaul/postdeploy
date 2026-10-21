#[path = "support/mcp.rs"]
mod common;
mod support;

use loco_rs::app::Hooks;
use postdeploy::{
    domain::{now_micros, Environment, OrgId, ProjectId, SourceId},
    testing::TestApp,
};
use reqwest::StatusCode;
use serde_json::{json, Value};

const DAY_US: i64 = 86_400_000_000;

/// Sends `items` as one Sentry log envelope and expects every item stored.
async fn send_logs(f: &common::Fixture, project: i64, dsn: &str, items: Value) {
    let count = items.as_array().unwrap().len() as u64;
    let payload = json!({ "items": items }).to_string();
    let envelope = format!(
        "{}\n{}\n{payload}\n",
        json!({}),
        json!({"type": "log", "item_count": count, "content_type": "application/vnd.sentry.items.log+json", "length": payload.len()})
    );
    let (status, receipt) = support::post_envelope(
        &f.base,
        project,
        &support::dsn_key(dsn),
        envelope.into_bytes(),
        None,
    )
    .await;
    assert_eq!(
        (status, receipt),
        (StatusCode::OK, support::accepted(None, 0, count))
    );
}

fn log_item(ts: i64, level: &str, body: &str, attributes: Value) -> Value {
    json!({"timestamp": ts as f64 / 1e6, "level": level, "body": body, "attributes": attributes})
}

async fn archived_objects(f: &common::Fixture, token: &str, org: &str, expected: i64) {
    support::eventually(std::time::Duration::from_secs(20), || async {
        let (_, status) = get(f, token, &format!("/api/orgs/{org}/logs/storage")).await;
        status["pending_entries"] == 0 && status["archived_objects"] == expected
    })
    .await;
}

fn attr(value: &str) -> Value {
    json!({"type": "string", "value": value})
}

async fn get(f: &common::Fixture, token: &str, path: &str) -> (StatusCode, Value) {
    let response = f
        .http
        .get(format!("{}{path}", f.base))
        .bearer_auth(token)
        .send()
        .await
        .unwrap();
    let status = response.status();
    (status, response.json().await.unwrap_or(Value::Null))
}

fn bodies(page: &Value) -> Vec<String> {
    page["rows"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| row["body"].as_str().unwrap().to_owned())
        .collect()
}

#[tokio::test]
async fn log_filters_use_receive_retention_identifiers_and_report_missing_objects() {
    let f = common::fixture_with("diag-log-filters", |config| {
        support::fast_archive(config.settings.as_mut().unwrap());
    })
    .await;
    let org = f.org("diag-logs@example.invalid", "Logs").await;
    let owner = f.token(org.owner, &org.id, Some(common::FULL)).await;
    let (project, _, dsn) = f.source(&owner, "web").await;
    let now = now_micros();
    let delayed = now - 91 * DAY_US;
    let checkout = |request: &str, release: &str| json!({"request_id": attr(request), "service.name": attr("checkout"), "sentry.release": attr(release)});
    let batches = [
        log_item(
            delayed,
            "error",
            "delayed checkout failure",
            checkout("req-1", "web@2"),
        ),
        log_item(now, "info", "other request", checkout("req-2", "web@1")),
        log_item(
            now,
            "info",
            "lost line",
            json!({"request_id": attr("req-1")}),
        ),
    ];
    for (archived, item) in (1..).zip(batches) {
        send_logs(&f, project, &dsn, json!([item])).await;
        archived_objects(&f, &owner, org.id.as_str(), archived).await;
    }
    let handle = f.rt.tenant(&org.id).await.unwrap();
    let missing: String = sea_orm::ConnectionTrait::query_one_raw(
        &*handle,
        postdeploy::runtime::sql(
            "SELECT object_key FROM log_objects ORDER BY id DESC LIMIT 1",
            vec![],
        ),
    )
    .await
    .unwrap()
    .unwrap()
    .try_get("", "object_key")
    .unwrap();
    drop(handle);
    f.rt.store.delete(&missing).await.unwrap();

    let token = f.token(org.owner, &org.id, Some("logs:read")).await;
    let logs = format!("/api/orgs/{}/logs", org.id);
    let since = now - 100 * DAY_US;
    let (status, page) = get(
        &f,
        &token,
        &format!("{logs}?since={since}&request_id=req-1"),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(bodies(&page), ["delayed checkout failure"]);
    assert_eq!(page["rows"][0]["ts"], delayed);
    assert_eq!(page["coverage"]["missing_objects"], 1);
    assert_eq!(page["coverage"]["objects"], 3);

    let (_, page) = get(
        &f,
        &token,
        &format!("{logs}?since={since}&service=checkout&release=web@1"),
    )
    .await;
    assert_eq!(bodies(&page), ["other request"]);
    let (_, page) = get(
        &f,
        &token,
        &format!("{logs}?since={since}&request_id=req-404"),
    )
    .await;
    assert_eq!(bodies(&page), Vec::<String>::new());
    let (status, page) = get(
        &f,
        &token,
        &format!("{logs}?request_id={}", "x".repeat(201)),
    )
    .await;
    assert_eq!(
        (status, page),
        (
            StatusCode::BAD_REQUEST,
            json!({"error": "invalid_identifier"})
        )
    );

    let other = f.org("diag-logs-other@example.invalid", "Other").await;
    let foreign = f.token(other.owner, &other.id, Some("logs:read")).await;
    let (status, _) = get(&f, &foreign, &format!("{logs}?request_id=req-1")).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    TestApp::on_shutdown(&f.boot.app_context).await;
}

#[tokio::test]
async fn ingested_logs_keep_old_event_times_within_receive_retention() {
    let f = common::fixture("diag-log-ingest").await;
    let org = f.org("diag-ingest@example.invalid", "Ingest").await;
    let owner = f.token(org.owner, &org.id, Some(common::FULL)).await;
    let (project, _, dsn) = f.source(&owner, "web").await;
    let now = now_micros();
    let ten_days = now - 10 * DAY_US;
    let ninety_one_days = now - 91 * DAY_US;
    let item = |ts: i64, body: &str, request: &str| {
        json!({"timestamp": ts as f64 / 1e6, "level": "error", "body": body, "attributes": {
            "request_id": attr(request), "service.name": attr("billing"), "sentry.release": attr("api@7")}})
    };
    let items = json!({"items": [item(ten_days, "ten days old", "req-10"), item(ninety_one_days, "ninety one days old", "req-91")]});
    let payload = items.to_string();
    let envelope = format!(
        "{}\n{}\n{payload}\n",
        json!({}),
        json!({"type": "log", "item_count": 2, "content_type": "application/vnd.sentry.items.log+json", "length": payload.len()})
    );
    let (status, _) = support::post_envelope(
        &f.base,
        project,
        &support::dsn_key(&dsn),
        envelope.into_bytes(),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    let token = f.token(org.owner, &org.id, Some("logs:read")).await;
    let logs = format!("/api/orgs/{}/logs", org.id);
    let mut found = Vec::new();
    for _ in 0..50 {
        let (status, page) = get(
            &f,
            &token,
            &format!(
                "{logs}?since={}&until={}&service=billing&release=api@7",
                ninety_one_days - 1,
                ten_days + 1
            ),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        found = bodies(&page);
        if found.len() == 2 {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
    assert_eq!(
        found,
        ["ninety one days old", "ten days old"],
        "cursor order, newest entry index first"
    );
    let (_, page) = get(
        &f,
        &token,
        &format!(
            "{logs}?since={}&until={}&request_id=req-10",
            ten_days - 1,
            ten_days + 1
        ),
    )
    .await;
    assert_eq!(bodies(&page), ["ten days old"]);
    assert_eq!(page["rows"][0]["ts"], ten_days);
    assert_eq!(page["coverage"]["missing_objects"], 0);
    TestApp::on_shutdown(&f.boot.app_context).await;
}

const MIN_US: i64 = 60_000_000;

fn error_event(
    id: u32,
    fingerprint: &str,
    release: Option<&str>,
    occurred: i64,
) -> postdeploy::ingest::event::ErrorEvent {
    postdeploy::ingest::event::ErrorEvent {
        event_id: format!("{id:032x}"),
        level: "error",
        title: format!("{fingerprint} failed"),
        culprit: None,
        fingerprint: fingerprint.into(),
        release: release.map(str::to_owned),
        trace_id: None,
        request_id: None,
        service: None,
        occurred_us: occurred,
        payload: json!({"event_id": format!("{id:032x}"), "message": fingerprint})
            .to_string()
            .into_bytes(),
    }
}

async fn send(
    f: &common::Fixture,
    method: reqwest::Method,
    token: &str,
    path: &str,
    body: Option<Value>,
) -> (StatusCode, Value) {
    let mut request = f
        .http
        .request(method, format!("{}{path}", f.base))
        .bearer_auth(token);
    if let Some(body) = body {
        request = request.json(&body);
    }
    let response = request.send().await.unwrap();
    let status = response.status();
    (status, response.json().await.unwrap_or(Value::Null))
}

#[tokio::test]
async fn deployment_comparison_uses_equal_windows_and_reports_coverage() {
    use postdeploy::{
        domain::UserId,
        identity::access::authorize,
        issues::{self, Committed, EventSource},
    };
    let f = common::fixture("diag-deployments").await;
    let api = support::Api::signup(&f.base, "diag-deploy@example.invalid").await;
    let (_, session) = api.get("/api/auth/session").await;
    let user = UserId(session["user"]["id"].as_i64().unwrap());
    let (org, project, _) = api.setup_source("Deployments").await;
    let org: OrgId = org.parse().unwrap();
    let token = f.token(user, &org, Some(common::FULL)).await;
    let access = authorize(&f.rt, user, &org).await.unwrap();
    let source = f
        .call(&token, "list_sources", json!({"project_id": project}))
        .await["structuredContent"]["sources"][0]["id"]
        .as_i64()
        .unwrap();
    let now = now_micros();
    let deployed = now - 120 * MIN_US;
    let deployments = format!("/api/orgs/{org}/projects/{project}/deployments");
    let sha = "a".repeat(40);
    let record = |version: &str, environment: &str, at: i64, sha: &str| json!({"version": version, "environment": environment, "deployed_at": at, "commit_sha": sha});
    let (status, created) = send(
        &f,
        reqwest::Method::POST,
        &token,
        &deployments,
        Some(record("web@2", "production", deployed, &sha)),
    )
    .await;
    assert_eq!(
        (status, created["created"].clone()),
        (StatusCode::CREATED, json!(true))
    );
    let id = created["deployment"]["id"].as_i64().unwrap();
    let (status, retried) = send(
        &f,
        reqwest::Method::POST,
        &token,
        &deployments,
        Some(record("web@2", "production", deployed, &sha.to_uppercase())),
    )
    .await;
    assert_eq!(
        (
            status,
            retried["created"].clone(),
            retried["deployment"]["id"].as_i64()
        ),
        (StatusCode::OK, json!(false), Some(id))
    );
    let (status, body) = send(
        &f,
        reqwest::Method::POST,
        &token,
        &deployments,
        Some(record("web@2", "production", deployed, &"b".repeat(40))),
    )
    .await;
    assert_eq!(
        (status, body),
        (StatusCode::CONFLICT, json!({"error": "deployment_exists"}))
    );
    let (status, body) = send(
        &f,
        reqwest::Method::POST,
        &token,
        &deployments,
        Some(record("web@2", "production", deployed, "abc123")),
    )
    .await;
    assert_eq!(
        (status, body),
        (
            StatusCode::BAD_REQUEST,
            json!({"error": "invalid_commit_sha"})
        )
    );
    let (status, staging) = send(
        &f,
        reqwest::Method::POST,
        &token,
        &deployments,
        Some(record("web@2", "staging", deployed, &sha)),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);
    assert_ne!(staging["deployment"]["id"].as_i64(), Some(id));
    for (version, at) in [
        ("web@1", deployed - 180 * MIN_US),
        ("web@2-hotfix", deployed + 30 * MIN_US),
    ] {
        let (status, _) = send(
            &f,
            reqwest::Method::POST,
            &token,
            &deployments,
            Some(record(version, "production", at, &sha)),
        )
        .await;
        assert_eq!(status, StatusCode::CREATED);
    }
    let (status, recent) = send(
        &f,
        reqwest::Method::POST,
        &token,
        &deployments,
        Some(record("web@3", "canary", now - 10 * MIN_US, &sha)),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);

    let production = Environment::parse("production").unwrap();
    let staging_env = Environment::parse("staging").unwrap();
    let at = |environment| EventSource {
        org: &org,
        project: ProjectId(project),
        source: SourceId(source),
        environment,
    };
    let events = [
        (1, "x", Some("web@1"), deployed - 50 * MIN_US),
        (2, "x", Some("web@1"), deployed - 40 * MIN_US),
        (3, "x", Some("web@1"), deployed - 30 * MIN_US),
        (4, "z", Some("web@1"), deployed - 90 * MIN_US),
        (5, "x", Some("web@2"), deployed + 5 * MIN_US),
        (6, "x", None, deployed + 6 * MIN_US),
        (7, "x", Some("web@1"), deployed + 7 * MIN_US),
        (8, "y", Some("web@2"), deployed + 8 * MIN_US),
        (9, "y", Some("web@2"), deployed + 9 * MIN_US),
    ];
    for (n, fingerprint, release, occurred) in events {
        issues::commit(
            &f.rt,
            &at(&production),
            error_event(n, fingerprint, release, occurred),
            occurred,
        )
        .await
        .unwrap();
    }
    issues::commit(
        &f.rt,
        &at(&staging_env),
        error_event(11, "x", Some("web@2"), deployed + 5 * MIN_US),
        deployed + 5 * MIN_US,
    )
    .await
    .unwrap();
    let issue_of = |title: &str| {
        let title = title.to_owned();
        let access = access.clone();
        let rt = f.rt.clone();
        async move {
            let (list, _) = issues::list(&rt, &access, issues::IssueQuery::default())
                .await
                .unwrap();
            list.into_iter()
                .find(|i| i.title == title && i.environment == "production")
                .unwrap()
                .id
        }
    };
    let z = issue_of("z failed").await;
    let handle = f.rt.tenant(&org).await.unwrap();
    sea_orm::ConnectionTrait::execute_raw(
        &*handle,
        postdeploy::runtime::sql(
            "UPDATE issues SET status = 'resolved', resolved_at = ? WHERE id = ?",
            vec![(deployed - 10 * MIN_US).into(), z.into()],
        ),
    )
    .await
    .unwrap();
    drop(handle);
    let regressed = issues::commit(
        &f.rt,
        &at(&production),
        error_event(10, "z", Some("web@2"), deployed + 20 * MIN_US),
        deployed + 20 * MIN_US,
    )
    .await
    .unwrap();
    assert_eq!(
        regressed,
        Committed::New {
            issue: z,
            regression: true
        }
    );
    let y = issue_of("y failed").await;

    let compared = f
        .call(&token, "compare_deployment", json!({"deployment_id": id}))
        .await;
    let c = &compared["structuredContent"];
    assert_eq!(c["window_secs"], 3600);
    assert_eq!(
        (c["before"]["start"].as_i64(), c["after"]["end"].as_i64()),
        (Some(deployed - 60 * MIN_US), Some(deployed + 60 * MIN_US))
    );
    assert_eq!(
        (
            c["before"]["events"].clone(),
            c["before"]["issues"]["value"].clone(),
            c["before"]["events_per_minute"].clone()
        ),
        (
            json!({"value": 3, "lower_bound": false}),
            json!(1),
            json!(0.05)
        )
    );
    assert_eq!(
        (
            c["after"]["events"]["value"].clone(),
            c["after"]["issues"]["value"].clone(),
            c["after"]["events_per_minute"].clone()
        ),
        (json!(6), json!(3), json!(0.1))
    );
    assert_eq!(c["previous"]["version"], "web@1");
    let ids = |page: &Value| {
        page["items"]
            .as_array()
            .unwrap()
            .iter()
            .map(|i| i["id"].as_i64().unwrap())
            .collect::<Vec<_>>()
    };
    assert_eq!(ids(&c["newly_observed"]), [y]);
    assert_eq!(c["newly_observed"]["items"][0]["seen_in_version"], true);
    assert_eq!(ids(&c["regressed"]), [z]);
    let overlapping: Vec<&str> = c["coverage"]["overlapping_deployments"]
        .as_array()
        .unwrap()
        .iter()
        .map(|d| d["version"].as_str().unwrap())
        .collect();
    assert_eq!(overlapping, ["web@2-hotfix"]);
    assert_eq!(c["coverage"]["overlapping_deployments_truncated"], false);
    assert_eq!(c["coverage"]["after_truncated_by_retention"], false);
    assert_eq!(c["coverage"]["after_events_without_release"]["value"], 1);
    assert_eq!(c["coverage"]["after_events_other_release"]["value"], 1);
    assert_eq!(
        (
            c["coverage"]["shortened_to_elapsed"].clone(),
            c["coverage"]["before_truncated_by_retention"].clone()
        ),
        (json!(false), json!(false))
    );

    let recent_id = recent["deployment"]["id"].as_i64().unwrap();
    let (status, shortened) = send(
        &f,
        reqwest::Method::GET,
        &token,
        &format!("/api/orgs/{org}/deployments/{recent_id}/comparison"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        (
            shortened["window_secs"].clone(),
            shortened["coverage"]["shortened_to_elapsed"].clone()
        ),
        (json!(600), json!(true))
    );

    let recurrence = f
        .call(&token, "issue_recurrence", json!({"issue_id": z}))
        .await;
    let r = &recurrence["structuredContent"];
    assert_eq!(r["resolved_at"], deployed - 10 * MIN_US);
    assert_eq!(
        (
            r["events_after_fix"]["value"].clone(),
            r["regression_events"]["value"].clone()
        ),
        (json!(1), json!(1))
    );
    assert_eq!(
        r["releases_after_fix"],
        json!([{"release": "web@2", "events": 1}])
    );
    assert_eq!(r["deployment_at_fix"]["version"], "web@1");
    let since: Vec<&str> = r["deployments_since_fix"]
        .as_array()
        .unwrap()
        .iter()
        .map(|d| d["version"].as_str().unwrap())
        .collect();
    assert_eq!(since, ["web@2", "web@2-hotfix"]);
    assert_eq!(r["releases_truncated"], false);
    assert_eq!(r["deployments_truncated"], false);

    let listed = f
        .call(
            &token,
            "list_deployments",
            json!({"project_id": project, "environment": "production", "limit": 2}),
        )
        .await;
    let listed = &listed["structuredContent"];
    let versions: Vec<&str> = listed["deployments"]
        .as_array()
        .unwrap()
        .iter()
        .map(|d| d["version"].as_str().unwrap())
        .collect();
    assert_eq!(versions, ["web@2-hotfix", "web@2"]);
    let next = listed["next"].as_str().unwrap();
    let older = f
        .call(
            &token,
            "list_deployments",
            json!({"project_id": project, "environment": "production", "before": next}),
        )
        .await;
    assert_eq!(
        older["structuredContent"]["deployments"][0]["version"],
        "web@1"
    );
    assert_eq!(older["structuredContent"]["next"], Value::Null);

    let read_only = f.token(user, &org, Some("issues:read")).await;
    let (status, _) = send(
        &f,
        reqwest::Method::POST,
        &read_only,
        &deployments,
        Some(record("web@4", "production", now, &sha)),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let (status, _) = send(
        &f,
        reqwest::Method::GET,
        &read_only,
        &format!("/api/orgs/{org}/deployments/{id}/comparison"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (status, _) = send(&f, reqwest::Method::GET, &read_only, &deployments, None).await;
    assert_eq!(status, StatusCode::FORBIDDEN, "listing needs projects:read");
    let other = f.org("diag-deploy-other@example.invalid", "Other").await;
    let foreign = f.token(other.owner, &other.id, Some(common::FULL)).await;
    let (status, _) = send(
        &f,
        reqwest::Method::GET,
        &foreign,
        &format!("/api/orgs/{org}/deployments/{id}/comparison"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let foreign_compare = f
        .call(&foreign, "compare_deployment", json!({"deployment_id": id}))
        .await;
    assert_eq!(
        common::error_of(&foreign_compare),
        json!({"error": "not_found"})
    );

    let response = f
        .http
        .get(format!(
            "{}/dashboard/orgs/{org}/projects/{project}/deployments?deployment={id}",
            f.base
        ))
        .header("cookie", api.cookie.as_deref().unwrap())
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let page = response.text().await.unwrap();
    assert!(page.contains(r#"id="deployments-before" class="mt-1 text-data tabular-nums text-text-primary">3 events · 0.05 per minute</dd>"#));
    assert!(page.contains(r#"id="deployments-after" class="mt-1 text-data tabular-nums text-text-primary">6 events · 0.10 per minute</dd>"#));
    assert!(page.contains("Error events in the 60 minutes before and after this deployment."));
    assert!(page.contains(
        "Other deployments of this environment fall inside these windows: web@2-hotfix."
    ));
    assert!(page.contains("1 events after the deployment have no release."));
    assert!(page.contains("It does not prove the deployment caused them."));
    assert!(page.contains(&format!("/observe/issues/{y}\"")));

    let issue_page = f
        .http
        .get(format!(
            "{}/dashboard/orgs/{org}/projects/{project}/observe/issues/{z}",
            f.base
        ))
        .header("cookie", api.cookie.as_deref().unwrap())
        .send()
        .await
        .unwrap()
        .text()
        .await
        .unwrap();
    assert!(issue_page.contains("1 event occurred after the fix."));
    assert!(issue_page.contains("Deployments since the fix: web@2 at "));
    assert!(issue_page.contains("Deployment web@2 at "));
    TestApp::on_shutdown(&f.boot.app_context).await;
}

#[tokio::test]
async fn error_context_matches_by_request_id_within_bounds() {
    let f = common::fixture("diag-context").await;
    let org = f.org("diag-context@example.invalid", "Context").await;
    let owner = f.token(org.owner, &org.id, Some(common::FULL)).await;
    let (project, _, dsn) = f.source(&owner, "web").await;
    let occurred = now_micros() - 60_000_000;
    let event = |id: &str, request: &str| {
        json!({"event_id": id, "level": "error", "timestamp": occurred as f64 / 1e6, "release": "web@5",
            "tags": {"request_id": request},
            "exception": {"values": [{"type": "Boom", "value": format!("failed {request}"), "stacktrace": {"frames": [
                {"function": "outer", "filename": "app/outer.rb", "lineno": 1, "in_app": true},
                {"function": "inner", "filename": format!("app/{request}.rb"), "lineno": 2, "in_app": true}]}}]}})
    };
    for (id, request) in [
        ("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1", "req-ctx"),
        ("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa2", "req-none"),
    ] {
        let body = format!(
            "{}\n{}\n{}\n",
            json!({"event_id": id}),
            json!({"type": "event"}),
            event(id, request)
        );
        let (status, _) = support::post_envelope(
            &f.base,
            project,
            &support::dsn_key(&dsn),
            body.into_bytes(),
            None,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
    }
    let big = "x".repeat(1_500);
    let matching: Vec<Value> = (0..60)
        .map(|n| {
            log_item(
                occurred + n * 1_000,
                "info",
                &format!("ctx {n:02} {big}"),
                json!({"request_id": attr("req-ctx")}),
            )
        })
        .collect();
    send_logs(&f, project, &dsn, Value::Array(matching)).await;
    send_logs(
        &f,
        project,
        &dsn,
        json!([log_item(
            occurred,
            "error",
            "unrelated request",
            json!({"request_id": attr("req-other")})
        )]),
    )
    .await;
    let other = f.org("diag-context-other@example.invalid", "Other").await;
    let other_owner = f.token(other.owner, &other.id, Some(common::FULL)).await;
    let (other_project, _, other_dsn) = f.source(&other_owner, "web").await;
    send_logs(
        &f,
        other_project,
        &other_dsn,
        json!([log_item(
            occurred,
            "error",
            "other org",
            json!({"request_id": attr("req-ctx")})
        )]),
    )
    .await;

    let issues = f.call(&owner, "list_issues", json!({})).await;
    let issue = |value: &str| {
        issues["structuredContent"]["issues"]
            .as_array()
            .unwrap()
            .iter()
            .find(|i| i["title"] == format!("Boom: failed {value}"))
            .unwrap()["id"]
            .as_i64()
            .unwrap()
    };
    let (ctx_issue, none_issue) = (issue("req-ctx"), issue("req-none"));

    let issues_only = f.token(org.owner, &org.id, Some("issues:read")).await;
    let denied = f
        .call(
            &issues_only,
            "get_error_context",
            json!({"issue_id": ctx_issue}),
        )
        .await;
    assert_eq!(
        common::error_of(&denied),
        json!({"error": "insufficient_scope", "required_scope": "logs:read"})
    );
    let (status, _) = get(
        &f,
        &issues_only,
        &format!("/api/orgs/{}/issues/{ctx_issue}/context", org.id),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    let both = f
        .token(org.owner, &org.id, Some("issues:read logs:read"))
        .await;
    let result = f
        .call(&both, "get_error_context", json!({"issue_id": ctx_issue}))
        .await;
    let context = &result["structuredContent"];
    assert_eq!(context["matched_by"], "request_id");
    assert_eq!(context["filters"]["request_id"], "req-ctx");
    assert_eq!(
        (
            context["filters"]["trace_id"].clone(),
            context["filters"]["environment"].clone()
        ),
        (Value::Null, json!("production"))
    );
    assert_eq!(context["event"]["request_id"], "req-ctx");
    assert_eq!(context["stack"]["frames"][0]["function"], "inner");
    assert_eq!(context["coverage"]["payload"], "stored");
    assert_eq!(context["coverage"]["stack_truncated"], false);
    let rows = context["logs"].as_array().unwrap();
    assert_eq!(rows.len(), 37, "64 KiB cap applies before the 50-row cap");
    assert!(rows
        .iter()
        .all(|row| row["body"].as_str().unwrap().starts_with("ctx ")));
    assert_eq!(rows[0]["body"].as_str().unwrap()[..6].to_owned(), "ctx 59");
    assert_eq!(context["coverage"]["logs"]["truncated_by"], "output_bytes");
    assert!(serde_json::to_vec(context).unwrap().len() <= 64 * 1024);
    let next = context["next"].as_str().unwrap();
    let (_, older) = get(
        &f,
        &both,
        &format!(
            "/api/orgs/{}/logs?request_id=req-ctx&since={}&until={}&before={next}&limit=200",
            org.id,
            occurred - 300_000_000,
            occurred + 300_000_000
        ),
    )
    .await;
    assert_eq!(
        older["rows"].as_array().unwrap().len() + rows.len(),
        60,
        "next continues without gaps"
    );

    let (status, small) = get(
        &f,
        &both,
        &format!("/api/orgs/{}/issues/{ctx_issue}/context?limit=5", org.id),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let small_bodies: Vec<String> = small["logs"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["body"].as_str().unwrap()[..6].to_owned())
        .collect();
    assert_eq!(
        small_bodies,
        ["ctx 59", "ctx 58", "ctx 57", "ctx 56", "ctx 55"]
    );

    let none = f
        .call(&both, "get_error_context", json!({"issue_id": none_issue}))
        .await;
    let none = &none["structuredContent"];
    assert_eq!(
        (none["matched_by"].clone(), none["logs"].clone()),
        (json!("request_id"), json!([]))
    );

    let foreign = f
        .token(other.owner, &other.id, Some("issues:read logs:read"))
        .await;
    let (status, _) = get(
        &f,
        &foreign,
        &format!("/api/orgs/{}/issues/{ctx_issue}/context", org.id),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let foreign_call = f
        .call(
            &foreign,
            "get_error_context",
            json!({"issue_id": ctx_issue}),
        )
        .await;
    assert_eq!(
        common::error_of(&foreign_call),
        json!({"error": "not_found"})
    );

    let handle = f.rt.tenant(&org.id).await.unwrap();
    let key: String = sea_orm::ConnectionTrait::query_one_raw(
        &*handle,
        postdeploy::runtime::sql(
            "SELECT payload_key FROM events WHERE issue_id = ?",
            vec![ctx_issue.into()],
        ),
    )
    .await
    .unwrap()
    .unwrap()
    .try_get("", "payload_key")
    .unwrap();
    drop(handle);
    f.rt.store.delete(&key).await.unwrap();
    let missing = f
        .call(
            &both,
            "get_error_context",
            json!({"issue_id": ctx_issue, "limit": 1}),
        )
        .await;
    let missing = &missing["structuredContent"];
    assert_eq!(
        (
            missing["coverage"]["payload"].clone(),
            missing["stack"].clone()
        ),
        (json!("missing"), Value::Null)
    );
    assert_eq!(missing["logs"].as_array().unwrap().len(), 1);

    let usage = f
        .call(
            &f.token(org.owner, &org.id, Some("projects:read")).await,
            "get_usage",
            json!({}),
        )
        .await;
    assert_eq!(usage["structuredContent"]["errors"]["used"], 2);
    assert_eq!(usage["structuredContent"]["errors"]["limit"], 1_000_000);
    TestApp::on_shutdown(&f.boot.app_context).await;
}

async fn comparison_fixture(
    name: &str,
) -> (common::Fixture, common::Org, String, i64, i64, i64, i64) {
    let f = common::fixture(name).await;
    let org = f.org(&format!("{name}@example.invalid"), name).await;
    let token = f.token(org.owner, &org.id, Some(common::FULL)).await;
    let (project, source, _) = f.source(&token, "web").await;
    let deployed = now_micros() - 120 * MIN_US;
    let (status, body) = send(
        &f,
        reqwest::Method::POST,
        &token,
        &format!("/api/orgs/{}/projects/{project}/deployments", org.id),
        Some(json!({"environment": "production", "version": "web@2", "deployed_at": deployed})),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);
    let id = body["deployment"]["id"].as_i64().unwrap();
    (
        f,
        org,
        token,
        project,
        source["id"].as_i64().unwrap(),
        deployed,
        id,
    )
}

async fn dashboard_html(f: &common::Fixture, email: &str, path: &str) -> String {
    let mut api = support::Api::new(&f.base);
    let (status, _) = api.auth("login", email, common::PASSWORD).await;
    assert_eq!(status, StatusCode::OK);
    let response = f
        .http
        .get(format!("{}{path}", f.base))
        .header("cookie", api.cookie.as_deref().unwrap())
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    response.text().await.unwrap()
}

#[tokio::test]
async fn round2_context_keeps_thread_frames_over_http_mcp_and_dashboard() {
    let f = common::fixture("diag-thread-context").await;
    let email = "diag-thread-context@example.invalid";
    let org = f.org(email, "Thread stacks").await;
    let token = f.token(org.owner, &org.id, Some(common::FULL)).await;
    let (project, source, dsn) = f.source(&token, "web").await;
    for (n, arrays, crashed) in [(1, false, false), (2, true, true), (3, false, true)] {
        let event_id = format!("{n:032x}");
        let exception = json!([{"type": "ThreadError", "value": format!("case-{n}")}]);
        let mut threads = vec![json!({"current": true, "stacktrace": {"frames": [
            {"function": "thread_entry", "filename": "app/thread.rs", "lineno": 7, "in_app": true},
            {"function": "thread_failure", "filename": "app/thread.rs", "lineno": 19, "in_app": true}
        ]}})];
        if crashed {
            threads.insert(0, if n == 2 {
                json!({"crashed": true, "stacktrace": {"frames": [{"function": "crashed_failure", "filename": "app/crash.rs", "lineno": 23, "in_app": true}]}})
            } else {
                json!({"crashed": true, "stacktrace": {"frames": []}})
            });
        }
        let payload = json!({"event_id": event_id, "level": "error",
            "exception": if arrays { exception } else { json!({"values": exception}) },
            "threads": if arrays { json!(threads) } else { json!({"values": threads}) }});
        let envelope = format!(
            "{}\n{}\n{payload}\n",
            json!({"event_id": event_id}),
            json!({"type": "event"})
        );
        let (status, _) = support::post_envelope(
            &f.base,
            project,
            &support::dsn_key(&dsn),
            envelope.into_bytes(),
            None,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let listed = f.call(&token, "list_issues", json!({})).await;
        let issue = listed["structuredContent"]["issues"]
            .as_array()
            .unwrap()
            .iter()
            .find(|i| i["title"] == format!("ThreadError: case-{n}"))
            .unwrap()["id"]
            .as_i64()
            .unwrap();
        let expected = if n == 2 {
            "crashed_failure"
        } else {
            "thread_failure"
        };
        let (status, context) = get(
            &f,
            &token,
            &format!(
                "/api/orgs/{}/issues/{issue}/context?event={event_id}&source={}",
                org.id, source["id"]
            ),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        eprintln!("round2 thread case {n}: {}", context["stack"]);
        assert_eq!(context["stack"]["frames"][0]["function"], expected);
        assert_eq!(context["stack"]["type"], "ThreadError");
        assert_eq!(context["stack"]["value"], format!("case-{n}"));
        if n != 2 {
            assert_eq!(context["stack"]["frames"][1]["function"], "thread_entry");
        }
        let mcp = f
            .call(
                &token,
                "get_error_context",
                json!({"issue_id": issue, "event_id": event_id, "source_id": source["id"]}),
            )
            .await;
        assert_eq!(mcp["structuredContent"]["stack"], context["stack"]);
        let html = dashboard_html(
            &f,
            email,
            &format!(
                "/dashboard/orgs/{}/projects/{project}/observe/issues/{issue}",
                org.id
            ),
        )
        .await;
        assert!(html.contains(expected));
    }
    TestApp::on_shutdown(&f.boot.app_context).await;
}

#[tokio::test]
async fn round2_sdk_capture_error_keeps_its_attached_thread_stack() {
    let f = common::fixture("diag-sdk-thread-context").await;
    let email = "diag-sdk-thread-context@example.invalid";
    let org = f.org(email, "SDK thread stack").await;
    let token = f.token(org.owner, &org.id, Some(common::FULL)).await;
    let (project, _, dsn) = f.source(&token, "web").await;
    let dsn = dsn.replace(
        "@127.0.0.1:5167/",
        &format!("@{}/", f.base.trim_start_matches("http://")),
    );
    support::sdk_send(dsn, "diag-sdk-thread-context".to_owned()).await;
    let listed = f.call(&token, "list_issues", json!({})).await;
    let issue = listed["structuredContent"]["issues"][0]["id"]
        .as_i64()
        .unwrap();
    let (status, context) = get(
        &f,
        &token,
        &format!("/api/orgs/{}/issues/{issue}/context", org.id),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(context["stack"]["value"], "card declined");
    assert!(!context["stack"]["frames"].as_array().unwrap().is_empty());
    let mcp = f
        .call(&token, "get_error_context", json!({"issue_id": issue}))
        .await;
    assert_eq!(mcp["structuredContent"]["stack"], context["stack"]);
    let html = dashboard_html(
        &f,
        email,
        &format!(
            "/dashboard/orgs/{}/projects/{project}/observe/issues/{issue}",
            org.id
        ),
    )
    .await;
    assert!(html.contains("observe-issue-stacktrace"));
    assert!(html.contains("card declined"));
    eprintln!(
        "round2 real SDK context frames={}",
        context["stack"]["frames"].as_array().unwrap().len()
    );
    TestApp::on_shutdown(&f.boot.app_context).await;
}

#[tokio::test]
async fn round2_comparison_reports_receive_retention_in_both_windows() {
    use postdeploy::issues::{self, Committed, EventSource};
    let f = common::fixture("diag-retention-windows").await;
    let email = "diag-retention-windows@example.invalid";
    let org = f.org(email, "Retention windows").await;
    let token = f.token(org.owner, &org.id, Some(common::FULL)).await;
    let (project, source, _) = f.source(&token, "web").await;
    let now = now_micros();
    let deployed = now - 90 * DAY_US - 30 * MIN_US;
    let deployments = format!("/api/orgs/{}/projects/{project}/deployments", org.id);
    let (status, created) = send(
        &f,
        reqwest::Method::POST,
        &token,
        &deployments,
        Some(
            json!({"environment": "production", "version": "historical", "deployed_at": deployed}),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);
    let id = created["deployment"]["id"].as_i64().unwrap();
    let environment = Environment::parse("production").unwrap();
    let source = EventSource {
        org: &org.id,
        project: ProjectId(project),
        source: SourceId(source["id"].as_i64().unwrap()),
        environment: &environment,
    };
    let mut retained_regression = 0;
    for (n, fingerprint, minutes) in [(1, "expired-regression", 5), (3, "retained-regression", 40)]
    {
        let committed = issues::commit(
            &f.rt,
            &source,
            error_event(n, fingerprint, Some("old"), deployed - 120 * MIN_US),
            deployed - 120 * MIN_US,
        )
        .await
        .unwrap();
        let Committed::New { issue, .. } = committed else {
            panic!("new issue");
        };
        let handle = f.rt.tenant(&org.id).await.unwrap();
        sea_orm::ConnectionTrait::execute_raw(
            &*handle,
            postdeploy::runtime::sql(
                "UPDATE issues SET status = 'resolved', resolved_at = ? WHERE id = ?",
                vec![(deployed - MIN_US).into(), issue.into()],
            ),
        )
        .await
        .unwrap();
        drop(handle);
        let occurred = deployed + minutes * MIN_US;
        assert_eq!(
            issues::commit(
                &f.rt,
                &source,
                error_event(n + 1, fingerprint, Some("historical"), occurred),
                occurred
            )
            .await
            .unwrap(),
            Committed::New {
                issue,
                regression: true
            }
        );
        if n == 3 {
            retained_regression = issue;
        }
    }
    let mut retained_new = 0;
    for (n, fingerprint, occurred, received) in [
        (
            5,
            "expired-new",
            deployed + 10 * MIN_US,
            deployed + 10 * MIN_US,
        ),
        (
            6,
            "retained-new",
            deployed + 45 * MIN_US,
            deployed + 45 * MIN_US,
        ),
        (7, "delayed-after", deployed + 46 * MIN_US, now),
        (8, "delayed-before", deployed - 10 * MIN_US, now),
    ] {
        let committed = issues::commit(
            &f.rt,
            &source,
            error_event(n, fingerprint, Some("historical"), occurred),
            received,
        )
        .await
        .unwrap();
        if n == 6 {
            let Committed::New { issue, .. } = committed else {
                panic!("new issue");
            };
            retained_new = issue;
        }
    }
    let (status, c) = get(
        &f,
        &token,
        &format!("/api/orgs/{}/deployments/{id}/comparison", org.id),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    eprintln!("round2 retention comparison: {c}");
    assert_eq!(
        (
            c["before"]["events"]["value"].clone(),
            c["after"]["events"]["value"].clone()
        ),
        (json!(1), json!(3))
    );
    assert_eq!(
        (
            c["coverage"]["before_truncated_by_retention"].clone(),
            c["coverage"]["after_truncated_by_retention"].clone()
        ),
        (json!(true), json!(true))
    );
    let ids = |key: &str| {
        c[key]["items"]
            .as_array()
            .unwrap()
            .iter()
            .map(|i| i["id"].as_i64().unwrap())
            .collect::<Vec<_>>()
    };
    assert_eq!(ids("regressed"), [retained_regression]);
    assert_eq!(ids("newly_observed"), [retained_new]);
    assert_eq!(c["regressed"]["total"]["value"], 1);
    assert_eq!(c["newly_observed"]["total"]["value"], 1);
    let mcp = f
        .call(&token, "compare_deployment", json!({"deployment_id": id}))
        .await;
    assert_eq!(mcp["structuredContent"]["after"]["events"]["value"], 3);
    assert_eq!(
        mcp["structuredContent"]["coverage"]["after_truncated_by_retention"],
        true
    );
    let html = dashboard_html(
        &f,
        email,
        &format!(
            "/dashboard/orgs/{}/projects/{project}/deployments?deployment={id}",
            org.id
        ),
    )
    .await;
    assert!(html.contains(
        "Some or all of the earlier window is past error retention, so its count is incomplete."
    ));
    assert!(html.contains(
        "Some or all of the later window is past error retention, so its count is incomplete."
    ));
    assert!(html.contains("First received after this deployment"));
    assert!(!html.contains("expired-regression failed"));
    assert!(!html.contains("expired-new failed"));
    let (status, created) = send(&f, reqwest::Method::POST, &token, &deployments,
        Some(json!({"environment": "production", "version": "fully-expired", "deployed_at": deployed - 2 * DAY_US}))).await;
    assert_eq!(status, StatusCode::CREATED);
    let expired_id = created["deployment"]["id"].as_i64().unwrap();
    let (status, expired) = get(
        &f,
        &token,
        &format!("/api/orgs/{}/deployments/{expired_id}/comparison", org.id),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(expired["before"]["events"]["value"], 0);
    assert_eq!(expired["after"]["events"]["value"], 0);
    assert_eq!(expired["newly_observed"]["total"]["value"], 0);
    assert_eq!(expired["regressed"]["total"]["value"], 0);
    assert_eq!(expired["coverage"]["before_truncated_by_retention"], true);
    assert_eq!(expired["coverage"]["after_truncated_by_retention"], true);
    let expired_html = dashboard_html(
        &f,
        email,
        &format!(
            "/dashboard/orgs/{}/projects/{project}/deployments?deployment={expired_id}",
            org.id
        ),
    )
    .await;
    assert!(expired_html.contains("Some or all of the earlier window is past error retention"));
    assert!(expired_html.contains("Some or all of the later window is past error retention"));
    TestApp::on_shutdown(&f.boot.app_context).await;
}

#[tokio::test]
async fn round2_recurrence_reports_more_than_ten_releases_and_deployments() {
    use postdeploy::issues::{self, Committed, EventSource};
    let f = common::fixture("diag-recurrence-lists").await;
    let email = "diag-recurrence-lists@example.invalid";
    let org = f.org(email, "Recurrence lists").await;
    let token = f.token(org.owner, &org.id, Some(common::FULL)).await;
    let (project, source, _) = f.source(&token, "web").await;
    let fixed = now_micros() - 120 * MIN_US;
    let environment = Environment::parse("production").unwrap();
    let source = EventSource {
        org: &org.id,
        project: ProjectId(project),
        source: SourceId(source["id"].as_i64().unwrap()),
        environment: &environment,
    };
    let committed = issues::commit(
        &f.rt,
        &source,
        error_event(1, "recurrence", Some("original"), fixed - MIN_US),
        fixed - MIN_US,
    )
    .await
    .unwrap();
    let Committed::New { issue, .. } = committed else {
        panic!("new issue");
    };
    let (_, unresolved) = get(
        &f,
        &token,
        &format!("/api/orgs/{}/issues/{issue}/recurrence", org.id),
    )
    .await;
    assert_eq!(unresolved["resolved_at"], Value::Null);
    assert_eq!(unresolved["releases_truncated"], false);
    assert_eq!(unresolved["deployments_truncated"], false);
    let handle = f.rt.tenant(&org.id).await.unwrap();
    sea_orm::ConnectionTrait::execute_raw(
        &*handle,
        postdeploy::runtime::sql(
            "UPDATE issues SET status = 'resolved', resolved_at = ? WHERE id = ?",
            vec![fixed.into(), issue.into()],
        ),
    )
    .await
    .unwrap();
    drop(handle);
    for n in 1..=11 {
        let version = format!("release-{n:02}");
        let occurred = fixed + i64::from(n) * MIN_US;
        issues::commit(
            &f.rt,
            &source,
            error_event(n + 1, "recurrence", Some(&version), occurred),
            occurred,
        )
        .await
        .unwrap();
        let (status, _) = send(
            &f,
            reqwest::Method::POST,
            &token,
            &format!("/api/orgs/{}/projects/{project}/deployments", org.id),
            Some(json!({"environment": "production", "version": version, "deployed_at": occurred})),
        )
        .await;
        assert_eq!(status, StatusCode::CREATED);
        if n == 10 {
            let (status, exact) = get(
                &f,
                &token,
                &format!("/api/orgs/{}/issues/{issue}/recurrence", org.id),
            )
            .await;
            assert_eq!(status, StatusCode::OK);
            assert_eq!(exact["releases_after_fix"].as_array().unwrap().len(), 10);
            assert_eq!(exact["deployments_since_fix"].as_array().unwrap().len(), 10);
            assert_eq!(exact["releases_truncated"], false);
            assert_eq!(exact["deployments_truncated"], false);
        }
    }
    issues::commit(
        &f.rt,
        &source,
        error_event(100, "recurrence", Some("release-11"), fixed + 12 * MIN_US),
        fixed + 12 * MIN_US,
    )
    .await
    .unwrap();
    let (status, recurrence) = get(
        &f,
        &token,
        &format!("/api/orgs/{}/issues/{issue}/recurrence", org.id),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    eprintln!("round2 recurrence: {recurrence}");
    assert_eq!(recurrence["events_after_fix"]["value"], 12);
    assert_eq!(
        recurrence["releases_after_fix"].as_array().unwrap().len(),
        10
    );
    assert_eq!(
        recurrence["deployments_since_fix"]
            .as_array()
            .unwrap()
            .len(),
        10
    );
    assert_eq!(recurrence["releases_truncated"], true);
    assert_eq!(recurrence["deployments_truncated"], true);
    assert_eq!(recurrence["releases_after_fix"][0]["release"], "release-11");
    assert_eq!(recurrence["releases_after_fix"][0]["events"], 2);
    assert_eq!(recurrence["releases_after_fix"][9]["release"], "release-09");
    assert_eq!(
        recurrence["deployments_since_fix"][9]["version"],
        "release-10"
    );
    let mcp = f
        .call(&token, "issue_recurrence", json!({"issue_id": issue}))
        .await;
    assert_eq!(mcp["structuredContent"]["releases_truncated"], true);
    assert_eq!(mcp["structuredContent"]["deployments_truncated"], true);
    assert_eq!(
        mcp["structuredContent"]["releases_after_fix"][0]["release"],
        "release-11"
    );
    let html = dashboard_html(
        &f,
        email,
        &format!(
            "/dashboard/orgs/{}/projects/{project}/observe/issues/{issue}",
            org.id
        ),
    )
    .await;
    assert!(html.contains("Only the 10 releases with the most events are shown."));
    assert!(html.contains("Only the first 10 deployments since the fix are shown."));
    TestApp::on_shutdown(&f.boot.app_context).await;
}

#[tokio::test]
async fn comparison_release_presence_uses_after_window_and_receive_retention() {
    use postdeploy::issues::{self, EventSource};
    let (f, org, token, project, source, deployed, id) =
        comparison_fixture("diag-window-release").await;
    let environment = Environment::parse("production").unwrap();
    let source = EventSource {
        org: &org.id,
        project: ProjectId(project),
        source: SourceId(source),
        environment: &environment,
    };
    for (n, fingerprint, release, occurred, received) in [
        (1, "outside", "web@1", deployed + MIN_US, deployed + MIN_US),
        (
            2,
            "outside",
            "web@2",
            deployed + 90 * MIN_US,
            deployed + 90 * MIN_US,
        ),
        (3, "expired", "web@1", deployed + MIN_US, deployed + MIN_US),
        (
            4,
            "expired",
            "web@2",
            deployed + 2 * MIN_US,
            deployed + 2 * MIN_US,
        ),
    ] {
        issues::commit(
            &f.rt,
            &source,
            error_event(n, fingerprint, Some(release), occurred),
            received,
        )
        .await
        .unwrap();
    }
    let handle = f.rt.tenant(&org.id).await.unwrap();
    sea_orm::ConnectionTrait::execute_raw(
        &*handle,
        postdeploy::runtime::sql(
            "UPDATE events SET received_at = ? WHERE event_id = ?",
            vec![
                (now_micros() - 100 * DAY_US).into(),
                format!("{:032x}", 4).into(),
            ],
        ),
    )
    .await
    .unwrap();
    drop(handle);
    let (status, comparison) = get(
        &f,
        &token,
        &format!("/api/orgs/{}/deployments/{id}/comparison", org.id),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let issues = comparison["newly_observed"]["items"].as_array().unwrap();
    assert_eq!(issues.len(), 2);
    assert_eq!(
        issues
            .iter()
            .map(|i| i["seen_in_version"].clone())
            .collect::<Vec<_>>(),
        [json!(false), json!(false)]
    );
    TestApp::on_shutdown(&f.boot.app_context).await;
}

#[tokio::test]
async fn comparison_reports_more_than_ten_overlapping_deployments() {
    let (f, org, token, project, _, deployed, id) = comparison_fixture("diag-many-overlaps").await;
    for n in 1..=11 {
        let (status, _) = send(&f, reqwest::Method::POST, &token,
            &format!("/api/orgs/{}/projects/{project}/deployments", org.id),
            Some(json!({"environment": "production", "version": format!("hotfix-{n}"), "deployed_at": deployed + n * MIN_US}))).await;
        assert_eq!(status, StatusCode::CREATED);
    }
    let comparison = f
        .call(&token, "compare_deployment", json!({"deployment_id": id}))
        .await;
    let coverage = &comparison["structuredContent"]["coverage"];
    assert_eq!(
        coverage["overlapping_deployments"]
            .as_array()
            .unwrap()
            .len(),
        10
    );
    assert_eq!(coverage["overlapping_deployments_truncated"], true);
    let mut api = support::Api::new(&f.base);
    let (status, _) = api
        .auth(
            "login",
            "diag-many-overlaps@example.invalid",
            common::PASSWORD,
        )
        .await;
    assert_eq!(status, StatusCode::OK);
    let response = f
        .http
        .get(format!(
            "{}/dashboard/orgs/{}/projects/{project}/deployments?deployment={id}",
            f.base, org.id
        ))
        .header("cookie", api.cookie.as_deref().unwrap())
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert!(response
        .text()
        .await
        .unwrap()
        .contains("Only the first 10 overlapping deployments are shown."));
    TestApp::on_shutdown(&f.boot.app_context).await;
}

#[tokio::test]
async fn context_bounds_large_stack_without_logs_over_http_and_mcp() {
    let f = common::fixture("diag-large-stack").await;
    let org = f
        .org("diag-large-stack@example.invalid", "Large stack")
        .await;
    let owner = f.token(org.owner, &org.id, Some(common::FULL)).await;
    let (project, source, dsn) = f.source(&owner, "web").await;
    let event_id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    let mut frames: Vec<Value> = (0..29).map(|n| json!({"function": format!("call_{n}{}", "\n\"".repeat(500)), "filename": format!("app/{n}{}", "\n\"".repeat(500)), "lineno": n, "in_app": true})).collect();
    frames.push(json!({"function": format!("useful_prefix{}", "λ\n\"".repeat(20000)), "filename": "app/large.rs", "lineno": 42, "in_app": true}));
    let payload = json!({"event_id": event_id, "level": "error", "tags": {"request_id": "req-large"},
        "exception": {"values": [{"type": "LargeStack", "value": "failed", "stacktrace": {"frames": frames}}]}});
    let envelope = format!(
        "{}\n{}\n{payload}\n",
        json!({"event_id": event_id}),
        json!({"type": "event"})
    );
    let (status, _) = support::post_envelope(
        &f.base,
        project,
        &support::dsn_key(&dsn),
        envelope.into_bytes(),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let listed = f.call(&owner, "list_issues", json!({})).await;
    let issue = listed["structuredContent"]["issues"][0]["id"]
        .as_i64()
        .unwrap();
    let response = f
        .http
        .get(format!(
            "{}/api/orgs/{}/issues/{issue}/context",
            f.base, org.id
        ))
        .bearer_auth(&owner)
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let bytes = response.bytes().await.unwrap();
    assert!(bytes.len() <= 65_536, "actual HTTP bytes {}", bytes.len());
    let context: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(context["logs"], json!([]));
    assert_eq!(context["coverage"]["stack_truncated"], true);
    assert_eq!(context["event"]["event_id"], event_id);
    assert_eq!(context["event"]["source_id"], source["id"]);
    assert_eq!(context["filters"]["request_id"], "req-large");
    assert_eq!(context["stack"]["frames"][0]["filename"], "app/large.rs");
    assert_eq!(context["stack"]["frames"][0]["lineno"], 42);
    assert_eq!(context["stack"]["frames"].as_array().unwrap().len(), 30);
    assert!(context["stack"]["frames"][0]["function"]
        .as_str()
        .unwrap()
        .starts_with("useful_prefix"));
    let (status, _, wire) = f
        .post(
            Some(format!("Bearer {owner}")),
            &[],
            common::call_body("get_error_context", json!({"issue_id": issue})),
        )
        .await;
    assert_eq!(status, StatusCode::OK);
    let result: Value = serde_json::from_str(&wire).unwrap();
    let context = &result["result"]["structuredContent"];
    let structured_bytes = serde_json::to_vec(context).unwrap().len();
    assert!(structured_bytes <= 65_536);
    assert_eq!(context["coverage"]["stack_truncated"], true);
    println!(
        "large-stack HTTP={} MCP structured={} full wire={}",
        bytes.len(),
        structured_bytes,
        wire.len()
    );
    let now = now_micros();
    let records: Vec<Value> = (0..60)
        .map(|n| {
            log_item(
                now + n * 1_000,
                "info",
                &format!("large-stack log {n} {}", "x".repeat(1500)),
                json!({"request_id": attr("req-large")}),
            )
        })
        .collect();
    send_logs(&f, project, &dsn, Value::Array(records)).await;
    let response = f
        .http
        .get(format!(
            "{}/api/orgs/{}/issues/{issue}/context",
            f.base, org.id
        ))
        .bearer_auth(&owner)
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let bytes = response.bytes().await.unwrap();
    assert!(
        bytes.len() <= 65_536,
        "actual HTTP bytes with logs {}",
        bytes.len()
    );
    let context: Value = serde_json::from_slice(&bytes).unwrap();
    let logs = context["logs"].as_array().unwrap();
    assert_eq!(logs.len(), 31, "64 KiB cap applies before the 50-row cap");
    assert_eq!(context["coverage"]["logs"]["truncated_by"], "output_bytes");
    assert_eq!(context["coverage"]["stack_truncated"], true);
    let (status, _, wire) = f
        .post(
            Some(format!("Bearer {owner}")),
            &[],
            common::call_body("get_error_context", json!({"issue_id": issue})),
        )
        .await;
    assert_eq!(status, StatusCode::OK);
    let result: Value = serde_json::from_str(&wire).unwrap();
    let context = &result["result"]["structuredContent"];
    let structured_bytes = serde_json::to_vec(context).unwrap().len();
    assert!(structured_bytes <= 65_536);
    assert_eq!(context["logs"].as_array().unwrap().len(), logs.len());
    println!(
        "large-stack plus logs HTTP={} MCP structured={} full wire={} retained logs={}",
        bytes.len(),
        structured_bytes,
        wire.len(),
        logs.len()
    );
    TestApp::on_shutdown(&f.boot.app_context).await;
}

#[tokio::test]
async fn diagnostics_migration_pins_only_unique_historical_event_evidence() {
    use migration::{MigratorTrait, OrgMigrator};
    use postdeploy::{runtime::sql, testing::TestEnv};
    use sea_orm::{ConnectionTrait, Database};
    let env = TestEnv::new("diag-evidence-migration");
    let db = Database::connect(format!(
        "sqlite://{}?mode=rwc",
        env.dir.join("old-tenant.sqlite").display()
    ))
    .await
    .unwrap();
    OrgMigrator::up(&db, Some(5)).await.unwrap();
    db.execute_unprepared("INSERT INTO issues (id, project_id, environment, fingerprint, title, level, status, first_seen, last_seen, event_count) VALUES (1, 1, 'production', 'test', 'Failure', 'error', 'open', 1, 2, 4);
        INSERT INTO reports VALUES ('old-report', 1, 1, 1, 'old-report-object', 10, 1, 4);
        INSERT INTO events (issue_id, project_id, source_id, event_id, level, occurred_at, received_at, payload_key, payload_bytes) VALUES
        (1, 1, 11, 'unique', 'error', 1, 1, 'first-source', 1),
        (1, 1, 11, 'ambiguous', 'error', 1, 1, 'ambiguous-a', 1),
        (1, 1, 12, 'ambiguous', 'error', 1, 1, 'ambiguous-b', 1),
        (1, 2, 11, 'foreign-project', 'error', 1, 1, 'foreign', 1);
        INSERT INTO report_evidence (report_id, ordinal, finding, kind, issue_id, event_id) VALUES
        ('old-report', 0, 0, 'event', 1, 'unique'), ('old-report', 1, 0, 'event', 1, 'ambiguous'),
        ('old-report', 2, 0, 'event', 1, 'missing'), ('old-report', 3, 0, 'event', 1, 'foreign-project');").await.unwrap();
    OrgMigrator::up(&db, None).await.unwrap();
    let rows = db
        .query_all_raw(sql(
            "SELECT source_id FROM report_evidence ORDER BY ordinal",
            vec![],
        ))
        .await
        .unwrap();
    assert_eq!(
        rows.iter()
            .map(|r| r.try_get::<Option<i64>>("", "source_id").unwrap())
            .collect::<Vec<_>>(),
        [Some(11), None, None, None]
    );
    db.execute_unprepared("INSERT INTO events (issue_id, project_id, source_id, event_id, level, occurred_at, received_at, payload_key, payload_bytes) VALUES (1, 1, 12, 'unique', 'error', 2, 2, 'second-source', 1)").await.unwrap();
    let rows = db.query_all_raw(sql("SELECT e.payload_key FROM report_evidence r JOIN events e ON e.issue_id = r.issue_id AND e.event_id = r.event_id AND e.source_id = r.source_id WHERE r.ordinal = 0", vec![])).await.unwrap();
    assert_eq!(
        rows.iter()
            .map(|r| r.try_get::<String>("", "payload_key").unwrap())
            .collect::<Vec<_>>(),
        ["first-source"]
    );
    db.close().await.unwrap();
}
