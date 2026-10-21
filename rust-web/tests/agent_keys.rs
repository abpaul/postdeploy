#[path = "support/mcp.rs"]
mod common;
mod support;

use std::sync::Mutex;

use async_trait::async_trait;
use common::{call_body, envelope, error_of, fixture, Fixture, FULL};
use credseal::SecretString;
use postdeploy::{
    account_settings::{self, AccountMail, AccountMessage, AccountToken, MailFailure},
    api_keys,
    domain::Role,
    error::ApiError,
    identity::access::authorize,
    runtime::sql,
};
use reqwest::{header, Method, StatusCode};
use sea_orm::ConnectionTrait;
use serde_json::{json, Value};
use support::Api;

const READ_ONLY: &str = "issues:read logs:read projects:read";
const ORIGIN: &str = "http://127.0.0.1:5167";

async fn session(f: &Fixture, email: &str) -> Api {
    let mut api = Api::new(&f.base);
    let (status, _) = api.auth("login", email, common::PASSWORD).await;
    assert_eq!(status, StatusCode::OK, "login {email}");
    api
}

async fn create_key(api: &Api, org: &str, body: Value) -> (StatusCode, header::HeaderMap, Value) {
    let response = api
        .http
        .post(format!("{}/api/orgs/{org}/api-keys", api.base))
        .header("cookie", api.cookie.as_deref().unwrap())
        .header("x-csrf-token", api.csrf.as_deref().unwrap())
        .json(&body)
        .send()
        .await
        .unwrap();
    let status = response.status();
    let headers = response.headers().clone();
    let text = response.text().await.unwrap();
    (
        status,
        headers,
        serde_json::from_str(&text).unwrap_or(Value::Null),
    )
}

async fn secret(api: &Api, org: &str, body: Value) -> String {
    let (status, _, created) = create_key(api, org, body).await;
    assert_eq!(status, StatusCode::CREATED, "key creation: {created}");
    created["secret"].as_str().unwrap().to_owned()
}

async fn bearer(
    f: &Fixture,
    key: &str,
    method: Method,
    path: &str,
    body: Option<Value>,
) -> (StatusCode, Value) {
    let mut request = f
        .http
        .request(method, format!("{}{path}", f.base))
        .bearer_auth(key);
    if let Some(body) = body {
        request = request.json(&body);
    }
    let response = request.send().await.unwrap();
    let status = response.status();
    let text = response.text().await.unwrap();
    (status, serde_json::from_str(&text).unwrap_or(Value::Null))
}

async fn mcp_status(f: &Fixture, key: &str) -> (StatusCode, String) {
    let (status, _, body) = f
        .post(
            Some(format!("Bearer {key}")),
            &[],
            call_body("list_projects", json!({})),
        )
        .await;
    (status, body)
}

async fn seeded(f: &Fixture, email: &str, name: &str) -> (common::Org, i64, i64, String) {
    let org = f.org(email, name).await;
    let writer = f.token(org.owner, &org.id, Some(FULL)).await;
    let (project, source, dsn) = f.source(&writer, "web").await;
    assert_eq!(
        f.ingest(
            &dsn,
            envelope("cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd", name, &[])
        )
        .await,
        StatusCode::OK
    );
    (org, project, source["id"].as_i64().unwrap(), dsn)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn default_api_key_reads_once_shown_and_revocation_stops_http_and_mcp() {
    let f = fixture("key-lifecycle").await;
    let (org, _, _, _) = seeded(&f, "owner@key-lifecycle.test", "Key lifecycle").await;
    let (other, other_project, _, other_dsn) =
        seeded(&f, "owner@key-other.test", "Key other").await;
    assert_eq!(
        f.ingest(
            &other_dsn,
            envelope("efefefefefefefefefefefefefefefef", "other secret", &[])
        )
        .await,
        StatusCode::OK
    );
    let api = session(&f, "owner@key-lifecycle.test").await;
    let org_id = org.id.as_str();

    let (status, headers, created) =
        create_key(&api, org_id, json!({"name": "laptop agent"})).await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(headers[header::CACHE_CONTROL], "no-store");
    let key = created["secret"].as_str().unwrap().to_owned();
    assert!(
        key.starts_with("pdk_") && key.len() == 47,
        "pdk_ plus 43 characters"
    );
    assert_eq!(created["key"]["name"], "laptop agent");
    assert_eq!(created["key"]["scopes"], READ_ONLY);
    assert_eq!(created["key"]["hint"], key[key.len() - 4..]);
    assert_eq!(created["key"]["email"], "owner@key-lifecycle.test");
    assert_eq!(
        created["key"]["expires_at"].as_i64().unwrap()
            - created["key"]["created_at"].as_i64().unwrap(),
        30 * 86_400
    );
    let id = created["key"]["id"].as_i64().unwrap();

    let (status, listed) = api.get(&format!("/api/orgs/{org_id}/api-keys")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(listed["keys"][0]["id"], id);
    assert_eq!(listed["keys"][0]["hint"], created["key"]["hint"]);
    assert!(
        !listed.to_string().contains(&key),
        "list never shows the secret"
    );
    let (status, detail) = api.get(&format!("/api/orgs/{org_id}/api-keys/{id}")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(detail["key"], created["key"]);
    assert!(
        !detail.to_string().contains(&key),
        "detail never shows the secret"
    );

    let base = format!("/api/orgs/{org_id}");
    let (status, issues) = bearer(&f, &key, Method::GET, &format!("{base}/issues"), None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(issues["issues"][0]["title"], "ProbeError: Key lifecycle");
    let (status, _) = bearer(&f, &key, Method::GET, &format!("{base}/logs"), None).await;
    assert_eq!(status, StatusCode::OK);
    let (status, body) = bearer(
        &f,
        &key,
        Method::PATCH,
        &format!("{base}/issues/1"),
        Some(json!({"status": "resolved"})),
    )
    .await;
    assert_eq!(
        (status, body),
        (StatusCode::FORBIDDEN, json!({"error": "forbidden"}))
    );
    let (status, _) = bearer(
        &f,
        &key,
        Method::POST,
        &format!("{base}/api-keys"),
        Some(json!({"name": "minted by key"})),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN, "keys cannot manage keys");
    let (status, _) = bearer(
        &f,
        &key,
        Method::DELETE,
        &format!("{base}/api-keys/{id}"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN, "keys cannot revoke keys");

    let (status, body) = bearer(
        &f,
        &key,
        Method::GET,
        &format!("/api/orgs/{}/issues", other.id),
        None,
    )
    .await;
    assert_eq!(
        (status, body),
        (StatusCode::NOT_FOUND, json!({"error": "not_found"}))
    );
    let listed = f.call(&key, "list_issues", json!({})).await;
    assert_eq!(
        listed["structuredContent"]["issues"][0]["title"],
        "ProbeError: Key lifecycle"
    );
    assert_eq!(
        error_of(&f.call(&key, "get_issue", json!({"issue_id": 2})).await),
        json!({"error": "not_found"})
    );
    assert_eq!(
        error_of(
            &f.call(&key, "list_sources", json!({"project_id": other_project}))
                .await
        ),
        json!({"error": "not_found"})
    );
    assert_eq!(
        error_of(
            &f.call(
                &key,
                "set_issue_status",
                json!({"issue_id": 1, "status": "resolved"})
            )
            .await
        ),
        json!({"error": "insufficient_scope", "required_scope": "issues:triage"})
    );
    let (status, tools) = {
        let (status, _, body) = f
            .post(
                Some(format!("Bearer {key}")),
                &[],
                json!({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}),
            )
            .await;
        (status, serde_json::from_str::<Value>(&body).unwrap())
    };
    assert_eq!(status, StatusCode::OK);
    assert!(
        !tools.to_string().contains("api_key"),
        "no key management tools"
    );

    let (status, _) = api
        .send(
            reqwest::Method::DELETE,
            &format!("/api/orgs/{org_id}/api-keys/{id}"),
            None,
        )
        .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let (status, _) = api
        .send(
            reqwest::Method::DELETE,
            &format!("/api/orgs/{org_id}/api-keys/{id}"),
            None,
        )
        .await;
    assert_eq!(status, StatusCode::NO_CONTENT, "revocation is idempotent");
    let (status, body) = bearer(&f, &key, Method::GET, &format!("{base}/issues"), None).await;
    assert_eq!(
        (status, body),
        (StatusCode::UNAUTHORIZED, json!({"error": "unauthorized"}))
    );
    assert_eq!(
        mcp_status(&f, &key).await,
        (
            StatusCode::UNAUTHORIZED,
            r#"{"error":"unauthorized"}"#.to_owned()
        )
    );
    let (_, listed) = api.get(&format!("/api/orgs/{org_id}/api-keys")).await;
    assert_eq!(listed["keys"], json!([]), "revoked keys leave the list");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn key_creation_validates_name_scopes_role_expiry_and_ownership() {
    let f = fixture("key-validation").await;
    let (org, _, _, _) = seeded(&f, "owner@key-validation.test", "Validation").await;
    let member = f
        .add_member(&org, "member@key-validation.test", Role::Member)
        .await;
    let owner = session(&f, "owner@key-validation.test").await;
    let member_api = session(&f, "member@key-validation.test").await;
    let org_id = org.id.as_str();

    for (body, code) in [
        (json!({"name": ""}), "invalid_name"),
        (json!({"name": "x".repeat(101)}), "invalid_name"),
        (json!({"name": "ok", "scopes": []}), "invalid_scope"),
        (json!({"name": "ok", "scopes": ["admin"]}), "invalid_scope"),
        (
            json!({"name": "ok", "expires_in_days": 0}),
            "invalid_expiry",
        ),
        (
            json!({"name": "ok", "expires_in_days": 91}),
            "invalid_expiry",
        ),
    ] {
        let (status, _, error) = create_key(&owner, org_id, body.clone()).await;
        assert_eq!(
            (status, error),
            (StatusCode::BAD_REQUEST, json!({"error": code})),
            "{body}"
        );
    }
    let (status, _, longest) = create_key(
        &owner,
        org_id,
        json!({"name": "ci", "scopes": ["deployments:write"], "expires_in_days": 90}),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(longest["key"]["scopes"], "deployments:write");
    assert_eq!(
        longest["key"]["expires_at"].as_i64().unwrap()
            - longest["key"]["created_at"].as_i64().unwrap(),
        90 * 86_400
    );
    let (status, _, error) = create_key(
        &member_api,
        org_id,
        json!({"name": "member write", "scopes": ["projects:write"]}),
    )
    .await;
    assert_eq!(
        (status, error),
        (StatusCode::BAD_REQUEST, json!({"error": "invalid_scope"}))
    );

    let without_csrf = owner
        .http
        .post(format!("{}/api/orgs/{org_id}/api-keys", f.base))
        .header("cookie", owner.cookie.as_deref().unwrap())
        .json(&json!({"name": "no csrf"}))
        .send()
        .await
        .unwrap();
    assert_eq!(without_csrf.status(), StatusCode::FORBIDDEN);
    let cross_site = owner
        .http
        .post(format!("{}/api/orgs/{org_id}/api-keys", f.base))
        .header("cookie", owner.cookie.as_deref().unwrap())
        .header("x-csrf-token", owner.csrf.as_deref().unwrap())
        .header("origin", "https://evil.example")
        .json(&json!({"name": "cross site"}))
        .send()
        .await
        .unwrap();
    assert_eq!(cross_site.status(), StatusCode::FORBIDDEN);
    let same_site = owner
        .http
        .post(format!("{}/api/orgs/{org_id}/api-keys", f.base))
        .header("cookie", owner.cookie.as_deref().unwrap())
        .header("x-csrf-token", owner.csrf.as_deref().unwrap())
        .header("origin", ORIGIN)
        .json(&json!({"name": "same site"}))
        .send()
        .await
        .unwrap();
    assert_eq!(same_site.status(), StatusCode::CREATED);

    let (status, _, member_key) =
        create_key(&member_api, org_id, json!({"name": "member read"})).await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(member_key["key"]["user_id"], member.0);
    let member_key_id = member_key["key"]["id"].as_i64().unwrap();
    let owner_key_id = longest["key"]["id"].as_i64().unwrap();

    let (_, mine) = member_api
        .get(&format!("/api/orgs/{org_id}/api-keys"))
        .await;
    let ids: Vec<i64> = mine["keys"]
        .as_array()
        .unwrap()
        .iter()
        .map(|k| k["id"].as_i64().unwrap())
        .collect();
    assert_eq!(ids, vec![member_key_id], "members list their own keys");
    let (status, _) = member_api
        .get(&format!("/api/orgs/{org_id}/api-keys/{owner_key_id}"))
        .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (status, _) = member_api
        .send(
            reqwest::Method::DELETE,
            &format!("/api/orgs/{org_id}/api-keys/{owner_key_id}"),
            None,
        )
        .await;
    assert_eq!(
        status,
        StatusCode::NOT_FOUND,
        "members cannot revoke other keys"
    );

    let (_, all) = owner.get(&format!("/api/orgs/{org_id}/api-keys")).await;
    assert_eq!(
        all["keys"].as_array().unwrap().len(),
        3,
        "managers list every key"
    );
    let (_, page) = owner
        .get(&format!("/api/orgs/{org_id}/api-keys?limit=2"))
        .await;
    assert_eq!(page["keys"].as_array().unwrap().len(), 2);
    let (_, rest) = owner
        .get(&format!(
            "/api/orgs/{org_id}/api-keys?limit=2&before={}",
            page["next"]
        ))
        .await;
    assert_eq!(rest["keys"].as_array().unwrap().len(), 1);
    assert_eq!(rest["next"], Value::Null);
    let (status, _) = owner
        .send(
            reqwest::Method::DELETE,
            &format!("/api/orgs/{org_id}/api-keys/{member_key_id}"),
            None,
        )
        .await;
    assert_eq!(
        status,
        StatusCode::NO_CONTENT,
        "managers revoke organization keys"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn ci_key_records_a_deployment_but_cannot_mint_a_dsn() {
    let f = fixture("key-ci").await;
    let (org, project, source, _) = seeded(&f, "owner@key-ci.test", "CI").await;
    let api = session(&f, "owner@key-ci.test").await;
    let key = secret(
        &api,
        org.id.as_str(),
        json!({"name": "ci", "scopes": ["deployments:write"]}),
    )
    .await;
    let base = format!("/api/orgs/{}", org.id);
    let (status, recorded) = bearer(
        &f,
        &key,
        Method::POST,
        &format!("{base}/projects/{project}/deployments"),
        Some(
            json!({"environment": "production", "version": "web@12", "commit_sha": "a".repeat(40)}),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(recorded["deployment"]["version"], "web@12");
    let (status, _) = bearer(
        &f,
        &key,
        Method::POST,
        &format!("{base}/sources/{source}/keys"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let (status, _) = bearer(&f, &key, Method::GET, &format!("{base}/issues"), None).await;
    assert_eq!(
        status,
        StatusCode::FORBIDDEN,
        "the CI key has no read scope"
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
    assert_eq!(keys, 1, "no DSN was minted");
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
async fn expiry_reset_downgrade_removal_and_deletion_stop_keys_on_http_and_mcp() {
    let f = fixture("key-stops").await;
    let (org, _, _, _) = seeded(&f, "owner@key-stops.test", "Stops").await;
    let admin = f
        .add_member(&org, "admin@key-stops.test", Role::Admin)
        .await;
    let removed = f
        .add_member(&org, "removed@key-stops.test", Role::Member)
        .await;
    let owner = session(&f, "owner@key-stops.test").await;
    let admin_api = session(&f, "admin@key-stops.test").await;
    let removed_api = session(&f, "removed@key-stops.test").await;
    let org_id = org.id.as_str();
    let issues = format!("/api/orgs/{org_id}/issues");

    let expiring = secret(&owner, org_id, json!({"name": "expiring"})).await;
    assert_eq!(
        bearer(&f, &expiring, Method::GET, &issues, None).await.0,
        StatusCode::OK
    );
    f.rt.control
        .execute_raw(sql(
            "UPDATE agent_api_keys SET created_at = created_at - 100 WHERE name = 'expiring'",
            vec![],
        ))
        .await
        .unwrap();
    f.rt.control
        .execute_raw(sql(
            "UPDATE agent_api_keys SET expires_at = ? WHERE name = 'expiring'",
            vec![(postdeploy::domain::now_secs() - 1).into()],
        ))
        .await
        .unwrap();
    assert_eq!(
        bearer(&f, &expiring, Method::GET, &issues, None).await.0,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(mcp_status(&f, &expiring).await.0, StatusCode::UNAUTHORIZED);

    let triage = secret(
        &admin_api,
        org_id,
        json!({"name": "triage", "scopes": ["issues:read", "issues:triage"]}),
    )
    .await;
    let (status, _) = bearer(
        &f,
        &triage,
        Method::PATCH,
        &format!("{issues}/1"),
        Some(json!({"status": "ignored"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "admin key triages");
    let access = authorize(&f.rt, org.owner, &org.id).await.unwrap();
    account_settings::set_member_role(&f.rt, &access, admin, Role::Member)
        .await
        .unwrap();
    let (status, _) = bearer(
        &f,
        &triage,
        Method::PATCH,
        &format!("{issues}/1"),
        Some(json!({"status": "open"})),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::FORBIDDEN,
        "downgraded role stops triage"
    );
    assert_eq!(
        error_of(
            &f.call(
                &triage,
                "set_issue_status",
                json!({"issue_id": 1, "status": "open"})
            )
            .await
        ),
        json!({"error": "forbidden"})
    );
    assert_eq!(
        bearer(&f, &triage, Method::GET, &issues, None).await.0,
        StatusCode::OK,
        "reads continue"
    );

    let leaving = secret(&removed_api, org_id, json!({"name": "leaving"})).await;
    assert_eq!(
        bearer(&f, &leaving, Method::GET, &issues, None).await.0,
        StatusCode::OK
    );
    postdeploy::identity::orgs::remove_member(&f.rt, &access, removed)
        .await
        .unwrap();
    assert_eq!(
        bearer(&f, &leaving, Method::GET, &issues, None).await.0,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        mcp_status(&f, &leaving).await,
        (
            StatusCode::UNAUTHORIZED,
            r#"{"error":"unauthorized"}"#.to_owned()
        )
    );

    let before_reset = secret(&owner, org_id, json!({"name": "before reset"})).await;
    assert_eq!(
        bearer(&f, &before_reset, Method::GET, &issues, None)
            .await
            .0,
        StatusCode::OK
    );
    let inbox = Inbox::default();
    account_settings::request_password_reset(&f.rt, &inbox, "owner@key-stops.test")
        .await
        .unwrap();
    let text = inbox.0.lock().unwrap().take().unwrap();
    let start = text.find("?token=").unwrap() + "?token=".len();
    let raw: String = text[start..]
        .chars()
        .take_while(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_')
        .collect();
    let token: AccountToken = serde_json::from_value(json!(raw)).unwrap();
    let password: SecretString =
        serde_json::from_value(json!("key-reset-password-0123456789")).unwrap();
    account_settings::reset_password(&f.rt, &token, &password)
        .await
        .unwrap();
    assert_eq!(
        bearer(&f, &before_reset, Method::GET, &issues, None)
            .await
            .0,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        mcp_status(&f, &before_reset).await.0,
        StatusCode::UNAUTHORIZED
    );

    let mut owner = Api::new(&f.base);
    assert_eq!(
        owner
            .auth(
                "login",
                "owner@key-stops.test",
                "key-reset-password-0123456789"
            )
            .await
            .0,
        StatusCode::OK
    );
    let surviving = secret(&owner, org_id, json!({"name": "until deletion"})).await;
    assert_eq!(
        bearer(&f, &surviving, Method::GET, &issues, None).await.0,
        StatusCode::OK
    );
    let deleted = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .unwrap()
        .post(format!("{}/dashboard/orgs/{org_id}/delete", f.base))
        .header("cookie", owner.cookie.as_deref().unwrap())
        .header("origin", ORIGIN)
        .form(&[
            ("confirmed_name", "Stops"),
            ("_csrf_token", owner.csrf.as_deref().unwrap()),
        ])
        .send()
        .await
        .unwrap();
    assert_eq!(deleted.status(), StatusCode::SEE_OTHER);
    assert_eq!(
        bearer(&f, &surviving, Method::GET, &issues, None).await.0,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(mcp_status(&f, &surviving).await.0, StatusCode::UNAUTHORIZED);
    let rows =
        f.rt.control
            .query_one_raw(sql(
                "SELECT COUNT(*) FROM agent_api_keys WHERE org_id = ?",
                vec![org_id.into()],
            ))
            .await
            .unwrap()
            .unwrap()
            .try_get_by_index::<i64>(0)
            .unwrap();
    assert_eq!(rows, 0, "organization deletion removes its keys");
}

fn checkbox(html: &str, scope: &str) -> Option<bool> {
    let marker = format!("name=\"scopes\" value=\"{scope}\"");
    let rest = html.split_once(&marker)?.1;
    Some(rest.split('>').next().unwrap().contains("checked"))
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn dashboard_creates_shows_once_and_revokes_member_keys() {
    let f = fixture("key-dashboard").await;
    let (org, _, _, _) = seeded(&f, "owner@key-dashboard.test", "Dashboard keys").await;
    f.add_member(&org, "member@key-dashboard.test", Role::Member)
        .await;
    let member = session(&f, "member@key-dashboard.test").await;
    let browser = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .unwrap();
    let settings = format!("{}/dashboard/orgs/{}/settings", f.base, org.id);
    let page = |cookie: String| {
        let request = browser.get(&settings).header("cookie", cookie);
        async move { request.send().await.unwrap().text().await.unwrap() }
    };
    let html = page(member.cookie.clone().unwrap()).await;
    assert_eq!(checkbox(&html, "issues:read"), Some(true));
    assert_eq!(checkbox(&html, "logs:read"), Some(true));
    assert_eq!(checkbox(&html, "reports:write"), Some(false));
    assert_eq!(
        checkbox(&html, "projects:write"),
        None,
        "members cannot pick manager scopes"
    );

    let post = |path: String, fields: Vec<(&'static str, String)>, csrf: bool| {
        let mut fields = fields;
        if csrf {
            fields.push(("_csrf_token", member.csrf.clone().unwrap()));
        }
        let request = browser
            .post(format!("{}{path}", f.base))
            .header("cookie", member.cookie.clone().unwrap())
            .header("origin", ORIGIN)
            .form(&fields);
        async move { request.send().await.unwrap() }
    };
    let create = format!("/dashboard/orgs/{}/settings/api-keys", org.id);
    let read = |name: &str| {
        vec![
            ("key_name", name.to_owned()),
            ("scopes", "issues:read".to_owned()),
            ("scopes", "logs:read".to_owned()),
            ("expires_in_days", "7".to_owned()),
        ]
    };
    assert_eq!(
        post(create.clone(), read("no token"), false).await.status(),
        StatusCode::FORBIDDEN
    );
    let empty = post(create.clone(), vec![("key_name", "empty".to_owned())], true).await;
    assert_eq!(empty.status(), StatusCode::UNPROCESSABLE_ENTITY);
    assert!(empty
        .text()
        .await
        .unwrap()
        .contains("Select at least one kind of access."));

    let created = post(create.clone(), read("dashboard agent"), true).await;
    assert_eq!(created.status(), StatusCode::CREATED);
    assert_eq!(created.headers()[header::CACHE_CONTROL], "no-store");
    let html = created.text().await.unwrap();
    let key = html
        .split_once("id=\"api-key-secret-value\"")
        .unwrap()
        .1
        .split_once('>')
        .unwrap()
        .1
        .split('<')
        .next()
        .unwrap()
        .to_owned();
    assert!(key.starts_with("pdk_") && key.len() == 47);
    let issues = format!("/api/orgs/{}/issues", org.id);
    assert_eq!(
        bearer(&f, &key, Method::GET, &issues, None).await.0,
        StatusCode::OK
    );

    let again = page(member.cookie.clone().unwrap()).await;
    assert!(
        !again.contains(&key),
        "the settings page never shows the key again"
    );
    assert!(again.contains(&format!("ends in {}", &key[key.len() - 4..])));
    assert!(again.contains("Read issues, Read logs"));
    let revoke = again
        .split("action=\"")
        .filter_map(|part| part.split('"').next())
        .find(|path| path.contains("/settings/api-keys/") && path.ends_with("/revoke"))
        .unwrap()
        .to_owned();
    let revoked = post(revoke, Vec::new(), true).await;
    assert_eq!(revoked.status(), StatusCode::SEE_OTHER);
    assert_eq!(
        bearer(&f, &key, Method::GET, &issues, None).await.0,
        StatusCode::UNAUTHORIZED
    );
    assert!(page(member.cookie.clone().unwrap())
        .await
        .contains("No API keys."));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn removing_a_member_revokes_their_keys_and_grants_for_good() {
    let f = fixture("key-removal").await;
    let (org, _, _, _) = seeded(&f, "owner@key-removal.test", "Removal").await;
    let elsewhere = f.org("owner@key-removal-b.test", "Elsewhere").await;
    let member = f
        .add_member(&org, "member@key-removal.test", Role::Member)
        .await;
    let elsewhere_access = authorize(&f.rt, elsewhere.owner, &elsewhere.id)
        .await
        .unwrap();
    postdeploy::identity::orgs::add_member(
        &f.rt,
        &elsewhere_access,
        "member@key-removal.test",
        Role::Member,
    )
    .await
    .unwrap();
    let owner = session(&f, "owner@key-removal.test").await;
    let member_api = session(&f, "member@key-removal.test").await;
    let org_id = org.id.as_str();
    let issues = format!("/api/orgs/{org_id}/issues");
    let key = secret(&member_api, org_id, json!({"name": "ci"})).await;
    let oauth = f.token(member, &org.id, None).await;
    let other_key = secret(&member_api, elsewhere.id.as_str(), json!({"name": "other"})).await;
    for credential in [&key, &oauth] {
        assert_eq!(
            bearer(&f, credential, Method::GET, &issues, None).await.0,
            StatusCode::OK
        );
    }

    let (status, _) = owner
        .send(
            Method::DELETE,
            &format!("/api/orgs/{org_id}/members/{}", member.0),
            None,
        )
        .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let (status, _) = owner
        .post(
            &format!("/api/orgs/{org_id}/members"),
            json!({"email": "member@key-removal.test", "role": "member"}),
        )
        .await;
    assert_eq!(status, StatusCode::CREATED, "the member is added again");

    for credential in [&key, &oauth] {
        assert_eq!(
            bearer(&f, credential, Method::GET, &issues, None).await,
            (StatusCode::UNAUTHORIZED, json!({"error": "unauthorized"}))
        );
        assert_eq!(
            mcp_status(&f, credential).await,
            (
                StatusCode::UNAUTHORIZED,
                r#"{"error":"unauthorized"}"#.to_owned()
            )
        );
    }
    let (_, listed) = owner.get(&format!("/api/orgs/{org_id}/api-keys")).await;
    assert_eq!(
        listed["keys"],
        json!([]),
        "the removed member's key is revoked"
    );
    assert_eq!(
        bearer(
            &f,
            &other_key,
            Method::GET,
            &format!("/api/orgs/{}/issues", elsewhere.id),
            None
        )
        .await
        .0,
        StatusCode::OK,
        "keys for another organization stay"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn api_keys_cannot_be_inserted_into_an_organization_being_deleted() {
    let f = fixture("key-trigger").await;
    let org = f.org("owner@key-trigger.test", "Trigger").await;
    f.rt.control
        .execute_raw(sql(
            "UPDATE organizations SET lifecycle = 'deleting' WHERE id = ?",
            vec![org.id.as_str().into()],
        ))
        .await
        .unwrap();
    let inserted = f
        .rt
        .control
        .execute_raw(sql(
            "INSERT INTO agent_api_keys (org_id, user_id, name, key_hash, hint, scopes, created_at, expires_at)
             VALUES (?, ?, 'late', zeroblob(32), 'xxxx', 'issues:read', 1, 2)",
            vec![org.id.as_str().into(), org.owner.0.into()],
        ))
        .await;
    let error = inserted.expect_err("insert into a deleting organization aborts");
    assert!(
        error.to_string().contains("organization unavailable"),
        "{error}"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_key_created_after_membership_removal_commits_is_refused() {
    let f = fixture("key-removed-race").await;
    let org = f.org("owner@key-race.test", "Race").await;
    let member = f.user("member@key-race.test").await;
    f.rt.control
        .execute_raw(sql(
            "INSERT INTO memberships (org_id, user_id, role, created_at) VALUES (?, ?, 'member', 1)",
            vec![org.id.as_str().into(), member.0.into()],
        ))
        .await
        .unwrap();
    let access = authorize(&f.rt, member, &org.id).await.unwrap();
    f.rt.control
        .execute_raw(sql(
            "DELETE FROM memberships WHERE org_id = ? AND user_id = ?",
            vec![org.id.as_str().into(), member.0.into()],
        ))
        .await
        .unwrap();
    let refused = api_keys::create(
        &f.rt,
        &access,
        api_keys::NewApiKey {
            name: "late".into(),
            scopes: None,
            expires_in_days: None,
        },
    )
    .await
    .expect_err("create after removal is refused");
    assert!(matches!(refused, ApiError::NotFound), "{refused:?}");
    let rows =
        f.rt.control
            .query_one_raw(sql("SELECT COUNT(*) AS n FROM agent_api_keys", vec![]))
            .await
            .unwrap()
            .unwrap()
            .try_get::<i64>("", "n")
            .unwrap();
    assert_eq!(rows, 0);
}

const KEY_LIMIT: &str = "api_key_limit";

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn active_keys_are_capped_at_fifty_per_user_and_organization() {
    let f = fixture("key-cap").await;
    let (org, _, _, _) = seeded(&f, "owner@key-cap.test", "Cap").await;
    let elsewhere = postdeploy::identity::orgs::create(&f.rt, org.owner, "Cap elsewhere")
        .await
        .unwrap();
    f.add_member(&org, "member@key-cap.test", Role::Member)
        .await;
    let owner = session(&f, "owner@key-cap.test").await;
    let member = session(&f, "member@key-cap.test").await;
    let org_id = org.id.as_str();
    let mut ids = Vec::new();
    for n in 0..50 {
        let (status, _, created) =
            create_key(&owner, org_id, json!({"name": format!("k{n}")})).await;
        assert_eq!(status, StatusCode::CREATED, "key {n}: {created}");
        ids.push(created["key"]["id"].as_i64().unwrap());
    }
    let (status, _, body) = create_key(&owner, org_id, json!({"name": "one too many"})).await;
    assert_eq!(
        (status, body),
        (StatusCode::CONFLICT, json!({"error": KEY_LIMIT}))
    );
    assert_eq!(
        create_key(&member, org_id, json!({"name": "member"}))
            .await
            .0,
        StatusCode::CREATED,
        "another user has their own cap"
    );
    assert_eq!(
        create_key(&owner, elsewhere.id.as_str(), json!({"name": "elsewhere"}))
            .await
            .0,
        StatusCode::CREATED,
        "another organization has its own cap"
    );

    let browser = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .unwrap();
    let form = browser
        .post(format!(
            "{}/dashboard/orgs/{org_id}/settings/api-keys",
            f.base
        ))
        .header("cookie", owner.cookie.clone().unwrap())
        .header("origin", ORIGIN)
        .form(&[
            ("key_name", "dashboard extra"),
            ("scopes", "issues:read"),
            ("expires_in_days", "7"),
            ("_csrf_token", owner.csrf.as_deref().unwrap()),
        ])
        .send()
        .await
        .unwrap();
    assert_eq!(form.status(), StatusCode::UNPROCESSABLE_ENTITY);
    assert!(form
        .text()
        .await
        .unwrap()
        .contains("You have 50 active keys here. Revoke one to create another."));

    let (status, _) = owner
        .send(
            Method::DELETE,
            &format!("/api/orgs/{org_id}/api-keys/{}", ids[0]),
            None,
        )
        .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_eq!(
        create_key(&owner, org_id, json!({"name": "after revoke"}))
            .await
            .0,
        StatusCode::CREATED,
        "revoking frees a slot"
    );
    f.rt.control
        .execute_raw(sql(
            "UPDATE agent_api_keys SET created_at = 0, expires_at = 1 WHERE id = ?",
            vec![ids[1].into()],
        ))
        .await
        .unwrap();
    assert_eq!(
        create_key(&owner, org_id, json!({"name": "after expiry"}))
            .await
            .0,
        StatusCode::CREATED,
        "an expired key frees a slot"
    );
    assert_eq!(
        create_key(&owner, org_id, json!({"name": "full again"}))
            .await
            .2,
        json!({"error": KEY_LIMIT})
    );
}
