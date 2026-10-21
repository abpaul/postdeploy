#[path = "support/mcp.rs"]
mod common;
mod support;

use std::{sync::atomic::Ordering, time::Duration};

use common::{envelope, error_of, fixture, fixture_with, Fixture, FULL, TRACE};
use postdeploy::domain::OrgId;
use reqwest::{header, StatusCode};
use serde_json::{json, Value};

async fn get(f: &Fixture, token: &str, path: &str) -> (StatusCode, Option<String>, Value) {
    let response = f
        .http
        .get(format!("{}{path}", f.base))
        .bearer_auth(token)
        .timeout(Duration::from_secs(5))
        .send()
        .await
        .expect("request answers within five seconds");
    let status = response.status();
    let retry = response
        .headers()
        .get(header::RETRY_AFTER)
        .map(|value| value.to_str().unwrap().to_owned());
    let text = response.text().await.unwrap();
    (
        status,
        retry,
        serde_json::from_str(&text).unwrap_or(Value::Null),
    )
}

async fn eventually<F, Fut>(timeout: Duration, mut check: F)
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = bool>,
{
    let deadline = tokio::time::Instant::now() + timeout;
    while !check().await {
        assert!(
            tokio::time::Instant::now() < deadline,
            "condition not met in {timeout:?}"
        );
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

async fn wait_archived(f: &Fixture, token: &str, org: &OrgId) {
    eventually(Duration::from_secs(20), || async {
        let (_, _, status) = get(f, token, &format!("/api/orgs/{org}/logs/storage")).await;
        status["pending_entries"] == 0 && status["archived_objects"].as_i64() > Some(0)
    })
    .await;
}

fn logs(org: &OrgId) -> String {
    format!("/api/orgs/{org}/logs")
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn stalled_searches_fill_one_org_and_cancellation_releases_them() {
    let f = fixture_with("admission-stall", |config| {
        let settings = config.settings.as_mut().unwrap();
        settings["logs"]["batch_max_age_ms"] = json!(50);
        settings["logs"]["archive_tick_ms"] = json!(20);
        settings["logs"]["search"]["timeout_ms"] = json!(60_000);
        settings["lifecycle"]["request_timeout_ms"] = json!(60_000);
    })
    .await;
    let a = f.org("owner@stall-a.test", "Stall A").await;
    let b = f.org("owner@stall-b.test", "Stall B").await;
    let token_a = f.token(a.owner, &a.id, Some(FULL)).await;
    let token_b = f.token(b.owner, &b.id, Some(FULL)).await;
    let (_, _, dsn) = f.source(&token_a, "web").await;
    assert_eq!(
        f.ingest(
            &dsn,
            envelope(
                "9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a",
                "stall",
                &[("info", "archived line", TRACE)]
            )
        )
        .await,
        StatusCode::OK
    );
    wait_archived(&f, &token_a, &a.id).await;

    let gets = f.rt.store.counters().gets.load(Ordering::SeqCst);
    f.faults.delay_get_ms.store(60_000, Ordering::SeqCst);
    let stalled: Vec<_> = (0..2)
        .map(|_| {
            let request = f
                .http
                .get(format!("{}{}", f.base, logs(&a.id)))
                .bearer_auth(&token_a);
            tokio::spawn(async move { request.send().await })
        })
        .collect();
    eventually(Duration::from_secs(5), || async {
        f.rt.store.counters().gets.load(Ordering::SeqCst) >= gets + 2
    })
    .await;

    let (status, retry, body) = get(&f, &token_a, &logs(&a.id)).await;
    assert_eq!(
        (status, retry.as_deref(), body),
        (
            StatusCode::TOO_MANY_REQUESTS,
            Some("1"),
            json!({"error": "rate_limited"})
        )
    );
    assert_eq!(
        error_of(&f.call(&token_a, "search_logs", json!({})).await),
        json!({"error": "rate_limited", "retry_after_secs": 1})
    );
    let (status, _, page) = get(&f, &token_b, &logs(&b.id)).await;
    assert_eq!(
        status,
        StatusCode::OK,
        "another organization still searches"
    );
    assert_eq!(page["rows"], json!([]));

    for request in &stalled {
        request.abort();
    }
    f.faults.delay_get_ms.store(0, Ordering::SeqCst);
    eventually(Duration::from_secs(5), || async {
        get(&f, &token_a, &logs(&a.id)).await.0 == StatusCode::OK
    })
    .await;
    let (_, _, page) = get(&f, &token_a, &logs(&a.id)).await;
    assert_eq!(page["rows"][0]["body"], "archived line");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn http_and_mcp_searches_share_one_org_rate_budget() {
    let f = fixture("admission-rate").await;
    let a = f.org("owner@rate-a.test", "Rate A").await;
    let b = f.org("owner@rate-b.test", "Rate B").await;
    let token_a = f.token(a.owner, &a.id, Some(FULL)).await;
    let token_b = f.token(b.owner, &b.id, Some(FULL)).await;
    for _ in 0..20 {
        assert_eq!(get(&f, &token_a, &logs(&a.id)).await.0, StatusCode::OK);
    }
    for _ in 0..10 {
        let result = f.call(&token_a, "search_logs", json!({})).await;
        assert_eq!(result["isError"], json!(false), "{result}");
    }
    let (status, retry, body) = get(&f, &token_a, &logs(&a.id)).await;
    assert_eq!(
        (status, body),
        (
            StatusCode::TOO_MANY_REQUESTS,
            json!({"error": "rate_limited"})
        )
    );
    let retry: u64 = retry.unwrap().parse().unwrap();
    assert!((1..=60).contains(&retry), "retry after {retry}");
    let error = error_of(&f.call(&token_a, "search_logs", json!({})).await);
    assert_eq!(error["error"], "rate_limited");
    assert!(error["retry_after_secs"].as_u64().unwrap().abs_diff(retry) <= 1);
    assert_eq!(get(&f, &token_b, &logs(&b.id)).await.0, StatusCode::OK);
    let result = f.call(&token_b, "search_logs", json!({}));
    assert_eq!(result.await["isError"], json!(false));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn nested_context_takes_one_permit_and_one_request_until_the_window_ends() {
    let f = fixture_with("admission-nested", |config| {
        let settings = config.settings.as_mut().unwrap();
        settings["query_admission"] =
            json!({"org_active_queries": 1, "org_queries_per_window": 2, "window_ms": 1500});
    })
    .await;
    let a = f.org("owner@nested.test", "Nested").await;
    let token = f.token(a.owner, &a.id, Some(FULL)).await;
    let (_, _, dsn) = f.source(&token, "web").await;
    assert_eq!(
        f.ingest(
            &dsn,
            envelope(
                "8b8b8b8b8b8b8b8b8b8b8b8b8b8b8b8b",
                "nested",
                &[("error", "correlated line", TRACE)]
            )
        )
        .await,
        StatusCode::OK
    );
    let context = f
        .call(&token, "get_error_context", json!({"issue_id": 1}))
        .await;
    assert_eq!(context["structuredContent"]["matched_by"], "trace_id");
    assert_eq!(
        context["structuredContent"]["logs"][0]["body"],
        "correlated line"
    );
    assert_eq!(get(&f, &token, &logs(&a.id)).await.0, StatusCode::OK);
    let context_path = format!("/api/orgs/{}/issues/1/context", a.id);
    let (status, _, body) = get(&f, &token, &context_path).await;
    assert_eq!(
        (status, body),
        (
            StatusCode::TOO_MANY_REQUESTS,
            json!({"error": "rate_limited"})
        )
    );
    assert_eq!(
        error_of(
            &f.call(&token, "get_error_context", json!({"issue_id": 1}))
                .await
        )["error"],
        "rate_limited"
    );
    tokio::time::sleep(Duration::from_millis(1_600)).await;
    let (status, _, body) = get(&f, &token, &context_path).await;
    assert_eq!(status, StatusCode::OK, "a new window restores admission");
    assert_eq!(body["logs"][0]["body"], "correlated line");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn mcp_calls_are_bounded_per_organization() {
    let f = fixture_with("admission-mcp", |config| {
        let settings = config.settings.as_mut().unwrap();
        settings["query_admission"] = json!({"mcp_calls_per_window": 3});
    })
    .await;
    let a = f.org("owner@mcp-a.test", "Mcp A").await;
    let b = f.org("owner@mcp-b.test", "Mcp B").await;
    let token_a = f.token(a.owner, &a.id, None).await;
    let token_b = f.token(b.owner, &b.id, None).await;
    for _ in 0..3 {
        let result = f.call(&token_a, "list_projects", json!({})).await;
        assert_eq!(result["structuredContent"]["projects"], json!([]));
    }
    let error = error_of(&f.call(&token_a, "list_projects", json!({})).await);
    assert_eq!(error["error"], "rate_limited");
    assert!((1..=60).contains(&error["retry_after_secs"].as_u64().unwrap()));
    let other = f.call(&token_b, "list_projects", json!({})).await;
    assert_eq!(other["structuredContent"]["projects"], json!([]));
    let (status, _, _) = get(&f, &token_a, &format!("/api/orgs/{}/projects", a.id)).await;
    assert_eq!(
        status,
        StatusCode::OK,
        "the MCP bound does not limit the HTTP API"
    );
}

async fn dashboard(f: &Fixture, cookie: &str, path: &str) -> (StatusCode, Option<String>, String) {
    let response = f
        .http
        .get(format!("{}{path}", f.base))
        .header(header::COOKIE, cookie)
        .timeout(Duration::from_secs(5))
        .send()
        .await
        .expect("page answers within five seconds");
    let status = response.status();
    let retry = response
        .headers()
        .get(header::RETRY_AFTER)
        .map(|value| value.to_str().unwrap().to_owned());
    (status, retry, response.text().await.unwrap())
}

async fn signed_in(f: &Fixture, email: &str) -> String {
    let mut api = support::Api::new(&f.base);
    let (status, _) = api.auth("login", email, common::PASSWORD).await;
    assert_eq!(status, StatusCode::OK, "login {email}");
    api.cookie.unwrap()
}

fn stack_envelope(event_id: &str) -> String {
    let event = json!({
        "event_id": event_id,
        "level": "error",
        "platform": "rust",
        "timestamp": common::now_secs(),
        "exception": { "values": [{
            "type": "CheckoutError",
            "value": "card declined",
            "stacktrace": { "frames": [
                { "function": "checkout_handler", "filename": "src/cart.rs", "lineno": 42, "in_app": true }
            ] }
        }] },
        "contexts": { "trace": { "trace_id": TRACE, "span_id": "b7ad6b7169203331" } }
    });
    format!(
        "{}\n{}\n{}\n",
        json!({ "event_id": event_id }),
        json!({ "type": "event" }),
        event,
    )
}

const ORG_BUSY: &str = "This organization&#39;s query budget is busy. Try again in 1 second.";

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn dashboard_pages_render_with_a_busy_notice_when_the_org_is_saturated() {
    let f = fixture_with("admission-dashboard", |config| {
        let settings = config.settings.as_mut().unwrap();
        settings["query_admission"] = json!({"org_active_queries": 1});
    })
    .await;
    let a = f.org("owner@dash-busy.test", "Dash busy").await;
    let token = f.token(a.owner, &a.id, Some(FULL)).await;
    let (project, _, dsn) = f.source(&token, "web").await;
    assert_eq!(
        f.ingest(&dsn, stack_envelope("7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c"))
            .await,
        StatusCode::OK
    );
    let (_, _, listed) = get(&f, &token, &format!("/api/orgs/{}/issues", a.id)).await;
    let issue = listed["issues"][0]["id"].as_i64().unwrap();
    let resolved = f
        .call(
            &token,
            "set_issue_status",
            json!({"issue_id": issue, "status": "resolved"}),
        )
        .await;
    assert_eq!(resolved["isError"], json!(false), "{resolved}");
    let recorded = f
        .http
        .post(format!(
            "{}/api/orgs/{}/projects/{project}/deployments",
            f.base, a.id
        ))
        .bearer_auth(&token)
        .json(&json!({"environment": "production", "version": "v-busy-1"}))
        .send()
        .await
        .unwrap();
    assert_eq!(recorded.status(), StatusCode::CREATED);
    let cookie = signed_in(&f, "owner@dash-busy.test").await;
    let base = format!("/dashboard/orgs/{}/projects/{project}", a.id);
    let issue_page = format!("{base}/observe/issues/{issue}");

    let held = f.rt.admission.queries.expensive(&a.id).unwrap();
    let (status, retry, html) = dashboard(&f, &cookie, &issue_page).await;
    assert_eq!(
        (status, retry.as_deref()),
        (StatusCode::TOO_MANY_REQUESTS, Some("1"))
    );
    assert!(html.contains("CheckoutError"), "issue details render");
    assert!(html.contains("checkout_handler"), "the stack trace renders");
    assert_eq!(
        html.matches(ORG_BUSY).count(),
        2,
        "related logs and recurrence each show the notice"
    );
    assert!(!html.contains("No log lines match."));

    let (status, retry, html) = dashboard(&f, &cookie, &format!("{base}/logs")).await;
    assert_eq!(
        (status, retry.as_deref()),
        (StatusCode::TOO_MANY_REQUESTS, Some("1"))
    );
    assert!(
        html.contains("id=\"logs-search\""),
        "the search form renders"
    );
    assert_eq!(html.matches(ORG_BUSY).count(), 1);
    assert!(!html.contains("No log lines in this range."));

    let (status, retry, html) = dashboard(&f, &cookie, &format!("{base}/deployments")).await;
    assert_eq!(
        (status, retry.as_deref()),
        (StatusCode::TOO_MANY_REQUESTS, Some("1"))
    );
    assert!(html.contains("v-busy-1"), "the deployment list renders");
    assert_eq!(html.matches(ORG_BUSY).count(), 1);

    drop(held);
    let (status, retry, html) = dashboard(&f, &cookie, &issue_page).await;
    assert_eq!((status, retry), (StatusCode::OK, None));
    assert_eq!(html.matches(ORG_BUSY).count(), 0);
    assert!(html.contains("After the fix"));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn global_saturation_reports_one_reason_and_retry_over_http_mcp_and_dashboard() {
    let f = fixture_with("admission-global", |config| {
        let settings = config.settings.as_mut().unwrap();
        settings["logs"]["search"]["max_active_queries"] = json!(1);
    })
    .await;
    let a = f.org("owner@global-a.test", "Global A").await;
    let b = f.org("owner@global-b.test", "Global B").await;
    let token = f.token(a.owner, &a.id, Some(FULL)).await;
    let (project, _, _) = f.source(&token, "web").await;
    let cookie = signed_in(&f, "owner@global-a.test").await;

    let held = f.rt.admission.queries.expensive(&b.id).unwrap();
    let (status, retry, body) = get(&f, &token, &logs(&a.id)).await;
    assert_eq!(
        (status, retry.as_deref(), body),
        (
            StatusCode::SERVICE_UNAVAILABLE,
            Some("1"),
            json!({"error": "log_query_overloaded"})
        )
    );
    assert_eq!(
        error_of(&f.call(&token, "search_logs", json!({})).await),
        json!({"error": "log_query_overloaded", "retry_after_secs": 1})
    );
    let logs_page = format!("/dashboard/orgs/{}/projects/{project}/logs", a.id);
    let (status, retry, html) = dashboard(&f, &cookie, &logs_page).await;
    assert_eq!(
        (status, retry.as_deref()),
        (StatusCode::SERVICE_UNAVAILABLE, Some("1"))
    );
    assert!(html.contains("The server is busy with other log queries. Try again in 1 second."));
    assert!(html.contains("id=\"logs-search\""));

    drop(held);
    let (status, _, _) = dashboard(&f, &cookie, &logs_page).await;
    assert_eq!(status, StatusCode::OK);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn denied_mcp_calls_do_not_spend_the_org_call_budget() {
    let f = fixture_with("admission-denied", |config| {
        let settings = config.settings.as_mut().unwrap();
        settings["query_admission"] = json!({"mcp_calls_per_window": 3});
    })
    .await;
    let a = f.org("owner@denied.test", "Denied").await;
    let member = f
        .add_member(&a, "member@denied.test", postdeploy::domain::Role::Member)
        .await;
    let reader = f.token(member, &a.id, None).await;
    let owner = f.token(a.owner, &a.id, Some(FULL)).await;
    for _ in 0..5 {
        assert_eq!(
            error_of(
                &f.call(
                    &reader,
                    "set_issue_status",
                    json!({"issue_id": 1, "status": "resolved"})
                )
                .await
            ),
            json!({"error": "insufficient_scope", "required_scope": "issues:triage"})
        );
    }
    for _ in 0..3 {
        let result = f.call(&owner, "list_projects", json!({})).await;
        assert_eq!(
            result["structuredContent"]["projects"],
            json!([]),
            "{result}"
        );
    }
    let error = error_of(&f.call(&owner, "list_projects", json!({})).await);
    assert_eq!(
        error["error"], "rate_limited",
        "allowed calls still spend it"
    );
}
