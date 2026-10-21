#[path = "support/mcp.rs"]
mod common;

use std::sync::Mutex;

use async_trait::async_trait;
use common::*;
use credseal::SecretString;
use postdeploy::{
    account_settings::{self, AccountMail, AccountMessage, AccountToken, MailFailure},
    agent_access::{RevokeForm, TokenForm},
    domain::Role,
    identity::accounts,
    runtime::sql,
};
use reqwest::StatusCode;
use sea_orm::ConnectionTrait;
use serde_json::{json, Value};

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn concurrent_project_and_source_creation_converges_without_extra_keys() {
    let f = fixture("concurrent-create").await;
    let org = f.org("owner@concurrency.test", "Concurrency").await;
    let token = f.token(org.owner, &org.id, Some(FULL)).await;
    for round in 0..4 {
        let name = format!("parallel-{round}");
        let calls = (0..8).map(|_| f.call(&token, "create_project", json!({"name": name})));
        let projects = futures::future::join_all(calls).await;
        assert_eq!(
            projects
                .iter()
                .filter(|r| r["structuredContent"]["created"] == true)
                .count(),
            1
        );
        let project = projects[0]["structuredContent"]["project"]["id"]
            .as_i64()
            .expect("project id");
        assert!(
            projects
                .iter()
                .all(|r| r["structuredContent"]["project"]["id"] == project),
            "all project calls must return the same id"
        );
        let calls = (0..8).map(|_| {
            f.call(
                &token,
                "create_source",
                json!({"project_id": project, "name": "api", "environment": "production"}),
            )
        });
        let sources = futures::future::join_all(calls).await;
        assert_eq!(
            sources
                .iter()
                .filter(|r| r["structuredContent"]["created"] == true)
                .count(),
            1
        );
        assert_eq!(
            sources
                .iter()
                .filter(|r| r["structuredContent"].get("dsn").is_some())
                .count(),
            1
        );
        let source = sources[0]["structuredContent"]["source"]["id"]
            .as_i64()
            .expect("source id");
        assert!(
            sources
                .iter()
                .all(|r| r["structuredContent"]["source"]["id"] == source),
            "all source calls must return the same id"
        );
        let keys =
            f.rt.control
                .query_one_raw(sql(
                    "SELECT COUNT(*) FROM ingest_keys WHERE source_id = ?",
                    vec![source.into()],
                ))
                .await
                .unwrap()
                .unwrap()
                .try_get_by_index::<i64>(0)
                .unwrap();
        assert_eq!(keys, 1);
    }
    let listed = f.call(&token, "list_projects", json!({})).await;
    assert_eq!(
        listed["structuredContent"]["projects"]
            .as_array()
            .unwrap()
            .len(),
        4
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn member_cannot_triage_through_session_http_or_mcp() {
    let f = fixture("shared-triage").await;
    let org = f.org("owner@triage-shared.test", "Triage").await;
    let member = f
        .add_member(&org, "member@triage-shared.test", Role::Member)
        .await;
    let owner_token = f.token(org.owner, &org.id, Some(FULL)).await;
    let (_, _, dsn) = f.source(&owner_token, "web").await;
    assert_eq!(
        f.ingest(
            &dsn,
            envelope("abcdef0123456789abcdef0123456789", "triage", &[])
        )
        .await,
        StatusCode::OK
    );
    let member_token = f.token(member, &org.id, Some(FULL)).await;
    let denied = f
        .call(
            &member_token,
            "set_issue_status",
            json!({"issue_id": 1, "status": "resolved"}),
        )
        .await;
    assert!(
        error_of(&denied) == json!({"error": "forbidden"}),
        "MCP must reject member triage"
    );
    let session = accounts::login(&f.rt, "member@triage-shared.test", PASSWORD)
        .await
        .unwrap();
    let denied = f
        .http
        .patch(format!("{}/api/orgs/{}/issues/1", f.base, org.id))
        .header("cookie", format!("pd_session={}", session.token))
        .header("x-csrf-token", session.csrf_token)
        .json(&json!({"status": "resolved"}))
        .send()
        .await
        .unwrap();
    assert_eq!(denied.status(), StatusCode::FORBIDDEN);
    let unchanged = f
        .call(&owner_token, "get_issue", json!({"issue_id": 1}))
        .await;
    assert!(
        unchanged["structuredContent"]["issue"]["status"] == "open",
        "rejected writes must leave the issue open"
    );
    let session = accounts::login(&f.rt, "owner@triage-shared.test", PASSWORD)
        .await
        .unwrap();
    let accepted = f
        .http
        .patch(format!("{}/api/orgs/{}/issues/1", f.base, org.id))
        .header("cookie", format!("pd_session={}", session.token))
        .header("x-csrf-token", session.csrf_token)
        .json(&json!({"status": "resolved"}))
        .send()
        .await
        .unwrap();
    assert_eq!(accepted.status(), StatusCode::OK);
    let resolved = f
        .call(&owner_token, "get_issue", json!({"issue_id": 1}))
        .await;
    assert!(
        resolved["structuredContent"]["issue"]["status"] == "resolved",
        "owner HTTP write must use the shared issue state"
    );
}

#[derive(Default)]
struct Inbox(Mutex<Option<String>>);

#[async_trait]
impl AccountMail for Inbox {
    fn configured(&self) -> bool {
        true
    }
    async fn send(&self, message: AccountMessage) -> Result<(), MailFailure> {
        *self.0.lock().unwrap() = Some(message.text().to_owned());
        Ok(())
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn password_reset_revokes_real_access_and_refresh_grants() {
    let f = fixture("reset-oauth").await;
    let org = f.org("owner@reset-oauth.test", "Reset").await;
    let (tokens, client) = f.token_response(org.owner, &org.id, Some(FULL)).await;
    let before = f
        .http
        .get(format!("{}/api/orgs/{}/projects", f.base, org.id))
        .bearer_auth(tokens.access_token.expose())
        .send()
        .await
        .unwrap();
    assert_eq!(before.status(), StatusCode::OK);
    let inbox = Inbox::default();
    account_settings::request_password_reset(&f.rt, &inbox, "owner@reset-oauth.test")
        .await
        .unwrap();
    let text = inbox.0.lock().unwrap().take().unwrap();
    let start = text.find("?token=").expect("reset mail link") + "?token=".len();
    let raw: String = text[start..]
        .chars()
        .take_while(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_')
        .collect();
    let token: AccountToken = serde_json::from_value(json!(raw)).unwrap();
    let password: SecretString =
        serde_json::from_value(json!("new-password-for-reset-012345")).unwrap();
    account_settings::reset_password(&f.rt, &token, &password)
        .await
        .unwrap();
    let after = f
        .http
        .get(format!("{}/api/orgs/{}/projects", f.base, org.id))
        .bearer_auth(tokens.access_token.expose())
        .send()
        .await
        .unwrap();
    assert_eq!(after.status(), StatusCode::UNAUTHORIZED);
    let (status, _, _) = f
        .post(
            Some(format!("Bearer {}", tokens.access_token.expose())),
            &[],
            call_body("list_projects", json!({})),
        )
        .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    let refresh = f
        .http
        .post(format!("{}/oauth/token", f.base))
        .form(&[
            ("grant_type", "refresh_token"),
            ("client_id", client.as_str()),
            ("refresh_token", tokens.refresh_token.expose()),
        ])
        .send()
        .await
        .unwrap();
    assert_eq!(refresh.status(), StatusCode::BAD_REQUEST);
    let error: Value = refresh.json().await.unwrap();
    assert!(
        error["error"] == "invalid_grant",
        "reset must revoke the refresh grant family"
    );
    assert!(accounts::login(
        &f.rt,
        "owner@reset-oauth.test",
        "new-password-for-reset-012345"
    )
    .await
    .is_ok());
}

#[test]
fn oauth_form_debug_redacts_all_secret_fields() {
    let token: TokenForm = serde_json::from_value(json!({"code": "private-code", "code_verifier": "private-verifier", "refresh_token": "private-refresh"})).unwrap();
    let debug = format!("{token:?}");
    assert!(
        !debug.contains("private-"),
        "token form debug must redact secrets"
    );
    assert!(debug.contains("Secret(<redacted>)"));
    let revoke: RevokeForm = serde_json::from_value(json!({"token": "private-revoke"})).unwrap();
    assert!(
        !format!("{revoke:?}").contains("private-"),
        "revoke form debug must redact its token"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn expired_errors_are_hidden_before_the_retention_sweep() {
    let f = fixture("retained-reads").await;
    let org = f.org("owner@retained-reads.test", "Retention").await;
    let token = f.token(org.owner, &org.id, Some(FULL)).await;
    let (_, _, dsn) = f.source(&token, "web").await;
    let expired_issue = "11111111111111111111111111111111";
    let expired_event = "22222222222222222222222222222222";
    let current_event = "33333333333333333333333333333333";
    for (id, value) in [
        (expired_issue, "expired issue"),
        (expired_event, "current issue"),
        (current_event, "current issue"),
    ] {
        assert_eq!(
            f.ingest(&dsn, envelope(id, value, &[])).await,
            StatusCode::OK
        );
    }
    {
        let tenant = f.rt.tenant(&org.id).await.unwrap();
        tenant
            .execute_raw(sql(
                "UPDATE events SET received_at = 0 WHERE event_id IN (?, ?)",
                vec![expired_issue.into(), expired_event.into()],
            ))
            .await
            .unwrap();
        tenant
            .execute_unprepared("UPDATE issues SET last_seen = 0 WHERE id = 1")
            .await
            .unwrap();
    }
    let listed = f.call(&token, "list_issues", json!({})).await;
    assert_eq!(
        listed["structuredContent"]["issues"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert!(
        listed["structuredContent"]["issues"][0]["id"] == 2,
        "the current issue remains visible"
    );
    assert!(
        error_of(&f.call(&token, "get_issue", json!({"issue_id": 1})).await)
            == json!({"error": "not_found"}),
        "expired issue is hidden"
    );
    assert!(
        error_of(
            &f.call(
                &token,
                "set_issue_status",
                json!({"issue_id": 1, "status": "resolved"})
            )
            .await
        ) == json!({"error": "not_found"}),
        "expired issue cannot be triaged"
    );
    let events = f
        .call(&token, "list_issue_events", json!({"issue_id": 2}))
        .await;
    assert_eq!(
        events["structuredContent"]["events"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert!(
        events["structuredContent"]["events"][0]["event_id"] == current_event,
        "the current event remains visible"
    );
    assert!(
        error_of(
            &f.call(
                &token,
                "get_issue_event",
                json!({"issue_id": 2, "event_id": expired_event})
            )
            .await
        ) == json!({"error": "not_found"}),
        "expired payload is hidden"
    );
    let current = f
        .call(
            &token,
            "get_issue_event",
            json!({"issue_id": 2, "event_id": current_event}),
        )
        .await;
    assert!(
        current["structuredContent"]["payload"]["postdeploy_symbolicated"].is_object(),
        "event read includes the symbolication result"
    );
    let response = f
        .http
        .get(format!(
            "{}/api/orgs/{}/issues/2/events/{expired_event}",
            f.base, org.id
        ))
        .bearer_auth(&token)
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn http_and_mcp_event_reads_include_uploaded_source_map_frames() {
    use bytes::Bytes;
    use postdeploy::{domain::ProjectId, identity::access::authorize, releases::UploadRequest};

    let f = fixture("event-symbolication").await;
    let org = f
        .org("owner@event-symbolication.test", "Symbolication")
        .await;
    let token = f.token(org.owner, &org.id, Some(FULL)).await;
    let (project, _, dsn) = f.source(&token, "web").await;
    let access = authorize(&f.rt, org.owner, &org.id).await.unwrap();
    f.rt.releases.upload(&access, UploadRequest {
        project: ProjectId(project), release: Some("web@1".into()), dist: None,
        name: "https://static.example.test/app.js".into(), debug_id: None,
        body: Bytes::from(json!({"version": 3, "file": "app.js", "sources": ["src/cart.ts"], "sourcesContent": ["throw new Error('cart');"], "names": ["checkout"], "mappings": "AAAAA"}).to_string()),
    }).await.unwrap();
    let event = json!({"event_id": "44444444444444444444444444444444", "level": "error", "platform": "javascript", "release": "web@1", "timestamp": now_secs(), "exception": {"values": [{"type": "TypeError", "value": "cart failed", "stacktrace": {"frames": [{"abs_path": "https://static.example.test/app.js", "function": "a", "lineno": 1, "colno": 1}]}}]}});
    let body = format!("{{}}\n{{\"type\":\"event\"}}\n{event}\n");
    assert_eq!(f.ingest(&dsn, body).await, StatusCode::OK);
    let response = f
        .http
        .get(format!(
            "{}/api/orgs/{}/issues/1/events/44444444444444444444444444444444",
            f.base, org.id
        ))
        .bearer_auth(&token)
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let http: Value = response.json().await.unwrap();
    let mcp = f
        .call(
            &token,
            "get_issue_event",
            json!({"issue_id": 1, "event_id": "44444444444444444444444444444444"}),
        )
        .await;
    for payload in [&http["payload"], &mcp["structuredContent"]["payload"]] {
        let frame = &payload["postdeploy_symbolicated"]["stacks"][0]["frames"][0];
        assert!(
            frame["status"] == "symbolicated",
            "the source map must resolve the frame"
        );
        assert!(
            frame["raw"]["file"] == "https://static.example.test/app.js",
            "raw frame remains available"
        );
        assert!(
            frame["original"]["file"] == "src/cart.ts",
            "original source file must match the uploaded map"
        );
        assert!(
            frame["original"]["function"] == "a",
            "the first frame preserves its function when the map has no caller"
        );
        assert!(
            frame["original"]["context_line"] == "throw new Error('cart');",
            "source context must come from the uploaded map"
        );
        assert!(
            frame["original"]["lineno"] == 1,
            "original line must use one-based indexing"
        );
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn saturated_password_lane_rejects_auth_until_capacity_returns() {
    let f = fixture_with("password-capacity", |config| {
        config.settings.as_mut().unwrap()["auth"]["password_concurrency"] = json!(2);
    })
    .await;
    let _user = f.user("existing@password-capacity.test").await;
    let first = f.rt.admission.password_lane().unwrap();
    let second = f.rt.admission.password_lane().unwrap();
    assert!(f.rt.admission.password_lane().is_none());
    for (action, email) in [
        ("signup", "new@password-capacity.test"),
        ("login", "existing@password-capacity.test"),
        ("login", "unknown@password-capacity.test"),
    ] {
        let response = f
            .http
            .post(format!("{}/api/auth/{action}", f.base))
            .json(&json!({"email": email, "password": PASSWORD}))
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
        let body: Value = response.json().await.unwrap();
        assert!(
            body["error"] == "auth_overloaded",
            "password saturation must return the explicit overload code"
        );
    }
    drop((first, second));
    let response = f
        .http
        .post(format!("{}/api/auth/login", f.base))
        .json(&json!({"email": "existing@password-capacity.test", "password": PASSWORD}))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
}
