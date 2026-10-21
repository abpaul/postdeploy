#[path = "support/mcp.rs"]
mod common;

use common::{call_body, envelope, error_of, fixture, Fixture, CHALLENGE, REDIRECT, VERIFIER};
use postdeploy::domain::Role;
use reqwest::{header, StatusCode};
use serde_json::{json, Value};

const ORIGIN: &str = "http://127.0.0.1:5167";
const WRITE: &str =
    "issues:read issues:triage logs:read projects:read projects:write reports:write";
const READ_ONLY: &str = "issues:read logs:read projects:read";

struct Browser {
    http: reqwest::Client,
    cookie: String,
    csrf: String,
}

async fn sign_in(f: &Fixture, email: &str) -> Browser {
    let http = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .unwrap();
    let response = http
        .post(format!("{}/api/auth/login", f.base))
        .json(&json!({"email": email, "password": common::PASSWORD}))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK, "login");
    let cookie = response.headers()[header::SET_COOKIE]
        .to_str()
        .unwrap()
        .split(';')
        .next()
        .unwrap()
        .to_owned();
    let body: Value = response.json().await.unwrap();
    Browser {
        http,
        cookie,
        csrf: body["csrf_token"].as_str().unwrap().to_owned(),
    }
}

async fn register(f: &Fixture, scope: Option<&str>) -> (StatusCode, Value) {
    let mut body = json!({"client_name": "Scope probe", "redirect_uris": [REDIRECT]});
    if let Some(scope) = scope {
        body["scope"] = json!(scope);
    }
    let response = f
        .http
        .post(format!("{}/oauth/register", f.base))
        .json(&body)
        .send()
        .await
        .unwrap();
    let status = response.status();
    (status, response.json().await.unwrap())
}

async fn consent_page(f: &Fixture, browser: &Browser, client: &str, scope: Option<&str>) -> String {
    let resource = format!("{}/mcp", f.base);
    let mut pairs = vec![
        ("response_type", "code"),
        ("client_id", client),
        ("redirect_uri", REDIRECT),
        ("code_challenge", CHALLENGE),
        ("code_challenge_method", "S256"),
        ("resource", resource.as_str()),
    ];
    if let Some(scope) = scope {
        pairs.push(("scope", scope));
    }
    let query = url::form_urlencoded::Serializer::new(String::new())
        .extend_pairs(pairs)
        .finish();
    let response = browser
        .http
        .get(format!("{}/oauth/authorize?{query}", f.base))
        .header(header::COOKIE, &browser.cookie)
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK, "consent page");
    response.text().await.unwrap()
}

fn checkbox(html: &str, scope: &str) -> Option<bool> {
    let marker = format!("name=\"scopes\" value=\"{scope}\"");
    let rest = html.split_once(&marker)?.1;
    Some(rest.split('>').next().unwrap().contains("checked"))
}

fn hidden(html: &str, name: &str) -> String {
    let marker = format!("name=\"{name}\" value=\"");
    html.split_once(&marker)
        .expect("hidden field")
        .1
        .split('"')
        .next()
        .unwrap()
        .to_owned()
}

/// Approves the rendered consent with the given boxes. Returns the code.
async fn consent_code(
    f: &Fixture,
    browser: &Browser,
    html: &str,
    org: &str,
    scopes: &[&str],
) -> String {
    let handle = hidden(html, "consent");
    let mut form = vec![
        ("consent", handle.as_str()),
        ("org_id", org),
        ("decision", "allow"),
        ("_csrf_token", browser.csrf.as_str()),
    ];
    form.extend(scopes.iter().map(|scope| ("scopes", *scope)));
    let response = browser
        .http
        .post(format!("{}/oauth/authorize", f.base))
        .header(header::ORIGIN, ORIGIN)
        .header(header::COOKIE, &browser.cookie)
        .form(&form)
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::SEE_OTHER, "consent approval");
    let location = url::Url::parse(response.headers()[header::LOCATION].to_str().unwrap()).unwrap();
    location
        .query_pairs()
        .find(|(key, _)| key == "code")
        .unwrap()
        .1
        .into_owned()
}

async fn token_endpoint(f: &Fixture, form: &[(&str, &str)]) -> (StatusCode, Value) {
    let response = f
        .http
        .post(format!("{}/oauth/token", f.base))
        .form(form)
        .send()
        .await
        .unwrap();
    let status = response.status();
    (status, response.json().await.unwrap())
}

async fn exchange(
    f: &Fixture,
    client: &str,
    code: &str,
    verifier: &str,
    resource: &str,
) -> (StatusCode, Value) {
    token_endpoint(
        f,
        &[
            ("grant_type", "authorization_code"),
            ("client_id", client),
            ("code", code),
            ("redirect_uri", REDIRECT),
            ("code_verifier", verifier),
            ("resource", resource),
        ],
    )
    .await
}

async fn approve(
    f: &Fixture,
    browser: &Browser,
    html: &str,
    client: &str,
    org: &str,
    scopes: &[&str],
) -> Value {
    let code = consent_code(f, browser, html, org, scopes).await;
    let (status, tokens) = exchange(f, client, &code, VERIFIER, &format!("{}/mcp", f.base)).await;
    assert_eq!(status, StatusCode::OK, "token exchange");
    tokens
}

async fn bearer(
    f: &Fixture,
    token: &str,
    method: reqwest::Method,
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
    let text = response.text().await.unwrap();
    (status, serde_json::from_str(&text).unwrap_or(Value::Null))
}

fn offered(html: &str) -> Vec<&str> {
    html.split("name=\"scopes\" value=\"")
        .skip(1)
        .map(|rest| rest.split('"').next().unwrap())
        .collect()
}

fn checked(html: &str) -> Vec<&str> {
    offered(html)
        .into_iter()
        .filter(|scope| checkbox(html, scope) == Some(true))
        .collect()
}

const ALL: [&str; 7] = [
    "issues:read",
    "issues:triage",
    "logs:read",
    "projects:read",
    "projects:write",
    "reports:write",
    "deployments:write",
];
const READ: [&str; 3] = ["issues:read", "logs:read", "projects:read"];

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn consent_offers_grantable_scopes_and_preselects_project_setup_only_for_an_empty_org_manager(
) {
    let f = fixture("scope-defaults").await;
    let org = f.org("owner@scope-defaults.test", "Scope defaults").await;
    f.add_member(&org, "member@scope-defaults.test", Role::Member)
        .await;
    let owner = sign_in(&f, "owner@scope-defaults.test").await;
    let member = sign_in(&f, "member@scope-defaults.test").await;

    let (status, client) = register(&f, None).await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(client["scope"], READ_ONLY);
    let client_id = client["client_id"].as_str().unwrap();
    let (status, writer) = register(&f, Some(WRITE)).await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(writer["scope"], WRITE);
    let writer_id = writer["client_id"].as_str().unwrap();

    let empty_owner = consent_page(&f, &owner, client_id, None).await;
    assert_eq!(offered(&empty_owner), ALL);
    assert_eq!(
        checked(&empty_owner),
        [
            "issues:read",
            "logs:read",
            "projects:read",
            "projects:write"
        ]
    );
    assert!(empty_owner.contains("Let Scope probe create projects and sources"));

    let empty_member = consent_page(&f, &member, client_id, None).await;
    assert_eq!(
        offered(&empty_member),
        ["issues:read", "logs:read", "projects:read", "reports:write"]
    );
    assert_eq!(checked(&empty_member), READ);

    let tokens = approve(
        &f,
        &owner,
        &empty_owner,
        client_id,
        org.id.as_str(),
        &["projects:read", "projects:write"],
    )
    .await;
    assert_eq!(tokens["scope"], "projects:read projects:write");
    let token = tokens["access_token"].as_str().unwrap();
    let (status, project) = bearer(
        &f,
        token,
        reqwest::Method::POST,
        &format!("/api/orgs/{}/projects", org.id),
        Some(json!({"name": "agent-made"})),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "granted beyond the request");
    assert_eq!(project["name"], "agent-made");

    let with_project = consent_page(&f, &owner, writer_id, Some(WRITE)).await;
    assert_eq!(offered(&with_project), ALL);
    assert_eq!(checked(&with_project), READ);
    let unscoped = consent_page(&f, &owner, client_id, None).await;
    assert_eq!(checked(&unscoped), READ);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn default_oauth_credentials_read_but_cannot_modify() {
    let f = fixture("default-read-only").await;
    let org = f.org("owner@default-read.test", "Default read").await;
    let writer = f.token(org.owner, &org.id, Some(WRITE)).await;
    let (project, source, dsn) = f.source(&writer, "web").await;
    let source_id = source["id"].as_i64().unwrap();
    assert_eq!(
        f.ingest(
            &dsn,
            envelope("abababababababababababababababab", "default read", &[])
        )
        .await,
        StatusCode::OK
    );
    let reader = f.token(org.owner, &org.id, None).await;
    let base = format!("/api/orgs/{}", org.id);

    let (status, issues) = bearer(
        &f,
        &reader,
        reqwest::Method::GET,
        &format!("{base}/issues"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(issues["issues"][0]["title"], "ProbeError: default read");
    let (status, _) = bearer(
        &f,
        &reader,
        reqwest::Method::GET,
        &format!("{base}/logs"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (status, projects) = bearer(
        &f,
        &reader,
        reqwest::Method::GET,
        &format!("{base}/projects"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(projects["projects"][0]["name"], "web");

    let denied = [
        (
            reqwest::Method::PATCH,
            format!("{base}/issues/1"),
            Some(json!({"status": "resolved"})),
        ),
        (
            reqwest::Method::POST,
            format!("{base}/projects"),
            Some(json!({"name": "denied"})),
        ),
        (
            reqwest::Method::POST,
            format!("{base}/projects/{project}/deployments"),
            Some(json!({"environment": "production", "version": "web@2"})),
        ),
        (
            reqwest::Method::POST,
            format!("{base}/sources/{source_id}/keys"),
            None,
        ),
    ];
    for (method, path, body) in denied {
        let (status, body) = bearer(&f, &reader, method.clone(), &path, body).await;
        assert_eq!(
            (status, body),
            (StatusCode::FORBIDDEN, json!({"error": "forbidden"})),
            "{method} {path}"
        );
    }
    let (_, issue) = bearer(
        &f,
        &writer,
        reqwest::Method::GET,
        &format!("{base}/issues/1"),
        None,
    )
    .await;
    assert_eq!(
        issue["issue"]["status"], "open",
        "denied triage leaves the issue open"
    );
    let (_, deployments) = bearer(
        &f,
        &writer,
        reqwest::Method::GET,
        &format!("{base}/projects/{project}/deployments"),
        None,
    )
    .await;
    assert_eq!(
        deployments["deployments"],
        json!([]),
        "denied deployment is not stored"
    );

    let denied = f
        .call(
            &reader,
            "set_issue_status",
            json!({"issue_id": 1, "status": "resolved"}),
        )
        .await;
    assert_eq!(
        error_of(&denied),
        json!({"error": "insufficient_scope", "required_scope": "issues:triage"})
    );
    let denied = f
        .call(&reader, "create_project", json!({"name": "denied"}))
        .await;
    assert_eq!(
        error_of(&denied),
        json!({"error": "insufficient_scope", "required_scope": "projects:write"})
    );
    let listed = f.call(&reader, "list_issues", json!({})).await;
    assert_eq!(
        listed["structuredContent"]["issues"][0]["title"],
        "ProbeError: default read"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn deployment_scope_records_deployments_without_minting_dsns() {
    let f = fixture("deployment-scope").await;
    let org = f.org("owner@deployment-scope.test", "Deployments").await;
    let member = f
        .add_member(&org, "member@deployment-scope.test", Role::Member)
        .await;
    let writer = f.token(org.owner, &org.id, Some(WRITE)).await;
    let (project, source, _) = f.source(&writer, "web").await;
    let source_id = source["id"].as_i64().unwrap();
    let ci = f.token(org.owner, &org.id, Some("deployments:write")).await;
    let base = format!("/api/orgs/{}", org.id);
    let (status, recorded) = bearer(
        &f,
        &ci,
        reqwest::Method::POST,
        &format!("{base}/projects/{project}/deployments"),
        Some(json!({"environment": "production", "version": "web@7", "deployed_at": 1_700_000_000_000_000i64})),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(recorded["deployment"]["version"], "web@7");
    for (path, body) in [
        (format!("{base}/sources/{source_id}/keys"), None),
        (
            format!("{base}/projects/{project}/sources"),
            Some(json!({"name": "ci", "environment": "production"})),
        ),
        (format!("{base}/projects"), Some(json!({"name": "ci"}))),
    ] {
        let (status, _) = bearer(&f, &ci, reqwest::Method::POST, &path, body).await;
        assert_eq!(status, StatusCode::FORBIDDEN, "{path}");
    }
    let (status, _) = bearer(
        &f,
        &writer,
        reqwest::Method::POST,
        &format!("{base}/projects/{project}/deployments"),
        Some(json!({"environment": "production", "version": "web@8"})),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::FORBIDDEN,
        "projects:write no longer records deployments"
    );

    let member_ci = f.token(member, &org.id, Some("deployments:write")).await;
    let (status, _) = bearer(
        &f,
        &member_ci,
        reqwest::Method::POST,
        &format!("{base}/projects/{project}/deployments"),
        Some(json!({"environment": "production", "version": "web@9"})),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::FORBIDDEN,
        "deployments:write is manager-only"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn log_storage_status_is_readable_with_logs_read_only() {
    let f = fixture("storage-scope").await;
    let org = f.org("owner@storage-scope.test", "Storage").await;
    let logs = f.token(org.owner, &org.id, Some("logs:read")).await;
    let issues = f.token(org.owner, &org.id, Some("issues:read")).await;
    let path = format!("/api/orgs/{}/logs/storage", org.id);
    let (status, body) = bearer(&f, &logs, reqwest::Method::GET, &path, None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["pending_entries"], 0);
    let (status, _) = bearer(&f, &issues, reqwest::Method::GET, &path, None).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let (status, _, _) = f
        .post(
            Some(format!("Bearer {logs}")),
            &[],
            call_body("list_issues", json!({})),
        )
        .await;
    assert_eq!(status, StatusCode::OK);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn audience_pkce_code_replay_and_refresh_reuse_checks_still_hold() {
    let f = fixture("oauth-protocol").await;
    let org = f.org("owner@oauth-protocol.test", "Protocol").await;
    let browser = sign_in(&f, "owner@oauth-protocol.test").await;
    let (_, client) = register(&f, None).await;
    let client = client["client_id"].as_str().unwrap().to_owned();
    let resource = format!("{}/mcp", f.base);
    let read = ["issues:read", "logs:read", "projects:read"];
    let issues = format!("/api/orgs/{}/issues", org.id);

    let query = url::form_urlencoded::Serializer::new(String::new())
        .extend_pairs([
            ("response_type", "code"),
            ("client_id", client.as_str()),
            ("redirect_uri", REDIRECT),
            ("code_challenge", CHALLENGE),
            ("code_challenge_method", "S256"),
            ("resource", "https://other.example/mcp"),
        ])
        .finish();
    let wrong_audience = browser
        .http
        .get(format!("{}/oauth/authorize?{query}", f.base))
        .header(header::COOKIE, &browser.cookie)
        .send()
        .await
        .unwrap();
    assert_eq!(wrong_audience.status(), StatusCode::BAD_REQUEST);

    let page = consent_page(&f, &browser, &client, None).await;
    let code = consent_code(&f, &browser, &page, org.id.as_str(), &read).await;
    let other_verifier = "x".repeat(43);
    assert_eq!(
        exchange(&f, &client, &code, &other_verifier, &resource).await,
        (StatusCode::BAD_REQUEST, json!({"error": "invalid_grant"})),
        "PKCE mismatch"
    );
    assert_eq!(
        exchange(&f, &client, &code, VERIFIER, &resource).await,
        (StatusCode::BAD_REQUEST, json!({"error": "invalid_grant"})),
        "a refused code cannot be retried"
    );

    let page = consent_page(&f, &browser, &client, None).await;
    let code = consent_code(&f, &browser, &page, org.id.as_str(), &read).await;
    assert_eq!(
        exchange(&f, &client, &code, VERIFIER, "https://other.example/mcp").await,
        (StatusCode::BAD_REQUEST, json!({"error": "invalid_target"})),
        "wrong audience at the token endpoint"
    );
    let (status, tokens) = exchange(&f, &client, &code, VERIFIER, &resource).await;
    assert_eq!(status, StatusCode::OK);
    let access = tokens["access_token"].as_str().unwrap().to_owned();
    assert_eq!(
        bearer(&f, &access, reqwest::Method::GET, &issues, None)
            .await
            .0,
        StatusCode::OK
    );
    assert_eq!(
        exchange(&f, &client, &code, VERIFIER, &resource).await,
        (StatusCode::BAD_REQUEST, json!({"error": "invalid_grant"})),
        "code replay"
    );
    assert_eq!(
        bearer(&f, &access, reqwest::Method::GET, &issues, None)
            .await
            .0,
        StatusCode::UNAUTHORIZED,
        "code replay revokes the grant it produced"
    );

    let page = consent_page(&f, &browser, &client, None).await;
    let code = consent_code(&f, &browser, &page, org.id.as_str(), &read).await;
    let (_, first) = exchange(&f, &client, &code, VERIFIER, &resource).await;
    let refresh = |token: String| {
        let client = client.clone();
        let f = &f;
        async move {
            token_endpoint(
                f,
                &[
                    ("grant_type", "refresh_token"),
                    ("client_id", client.as_str()),
                    ("refresh_token", token.as_str()),
                ],
            )
            .await
        }
    };
    let (status, rotated) = refresh(first["refresh_token"].as_str().unwrap().to_owned()).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        rotated["scope"], READ_ONLY,
        "rotation keeps the consented scopes"
    );
    let rotated_access = rotated["access_token"].as_str().unwrap().to_owned();
    assert_eq!(
        bearer(&f, &rotated_access, reqwest::Method::GET, &issues, None)
            .await
            .0,
        StatusCode::OK
    );
    assert_eq!(
        refresh(first["refresh_token"].as_str().unwrap().to_owned()).await,
        (StatusCode::BAD_REQUEST, json!({"error": "invalid_grant"})),
        "reused refresh token"
    );
    assert_eq!(
        bearer(&f, &rotated_access, reqwest::Method::GET, &issues, None)
            .await
            .0,
        StatusCode::UNAUTHORIZED,
        "refresh reuse revokes the whole family"
    );
}

#[tokio::test]
async fn registration_limit_applies_per_client_address_behind_the_tunnel() {
    let f = fixture("agent-register-client-address").await;
    let register_from = |address: &'static str| {
        f.http
            .post(format!("{}/oauth/register", f.base))
            .header("cf-connecting-ip", address)
            .json(&json!({"client_name": "Tunnel client", "redirect_uris": [REDIRECT]}))
            .send()
    };
    for n in 1..=10 {
        let response = register_from("198.51.100.1").await.unwrap();
        assert_eq!(response.status(), StatusCode::CREATED, "registration {n}");
    }
    let limited = register_from("198.51.100.1").await.unwrap();
    assert_eq!(limited.status(), StatusCode::TOO_MANY_REQUESTS);
    assert_eq!(
        limited.json::<Value>().await.unwrap(),
        json!({"error": "temporarily_unavailable"})
    );
    let other = register_from("198.51.100.2").await.unwrap();
    assert_eq!(other.status(), StatusCode::CREATED);
}
