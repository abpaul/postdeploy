mod support;

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use loco_rs::app::Hooks;
use postdeploy::{
    runtime::Runtime,
    services::Services,
    testing::{serve, TestApp, TestEnv},
};
use reqwest::{header, Client, Response, StatusCode};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use support::{Api, PASSWORD};

const ORIGIN: &str = "http://127.0.0.1:5167";

fn http() -> Client {
    let _ = tracing_subscriber::fmt()
        .with_env_filter("off,postdeploy=error")
        .with_test_writer()
        .try_init();
    Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .unwrap()
}

fn cookie(response: &Response, name: &str) -> String {
    response
        .headers()
        .get_all(header::SET_COOKIE)
        .iter()
        .filter_map(|v| v.to_str().ok())
        .find(|value| value.starts_with(&format!("{name}=")))
        .expect("expected response cookie")
        .split(';')
        .next()
        .unwrap()
        .to_owned()
}

fn hidden(html: &str, name: &str) -> String {
    let marker = format!("name=\"{name}\" value=\"");
    html.split_once(&marker)
        .expect("rendered hidden form field")
        .1
        .split('"')
        .next()
        .unwrap()
        .to_owned()
}

async fn html(response: Response, status: StatusCode, marker: &str) -> String {
    assert_eq!(response.status(), status);
    assert_eq!(response.headers()[header::CACHE_CONTROL], "no-store");
    assert!(response.headers()[header::CONTENT_TYPE]
        .to_str()
        .unwrap()
        .starts_with("text/html"));
    let body = response.text().await.unwrap();
    assert!(body.contains(marker), "page must contain {marker}");
    assert!(
        !body.contains("{{"),
        "template expressions must be rendered"
    );
    body
}

fn form(
    client: &Client,
    base: &str,
    path: &str,
    api: &Api,
    fields: &[(&str, &str)],
) -> reqwest::RequestBuilder {
    let mut values = fields.to_vec();
    values.push(("_csrf_token", api.csrf.as_deref().unwrap()));
    client
        .post(format!("{base}{path}"))
        .header(header::ORIGIN, ORIGIN)
        .header(header::COOKIE, api.cookie.as_deref().unwrap())
        .form(&values)
}

#[tokio::test]
async fn anonymous_forms_require_origin_cookie_and_csrf_and_return_to_saved_page() {
    let env = TestEnv::new("web-auth");
    let boot = env.boot_memory(|_| {}).await.unwrap();
    let (base, server) = serve(&boot).await;
    let client = http();
    let root = client.get(format!("{base}/")).send().await.unwrap();
    html(
        root,
        StatusCode::OK,
        "PostDeploy: production errors and logs for your coding agent",
    )
    .await;
    let saved = client
        .get(format!("{base}/dashboard/account"))
        .send()
        .await
        .unwrap();
    assert_eq!(saved.status(), StatusCode::SEE_OTHER);
    let return_cookie = cookie(&saved, "pd_return");
    let register = client.get(format!("{base}/register")).send().await.unwrap();
    let preauth = cookie(&register, "pd_preauth");
    assert!(register
        .headers()
        .get_all(header::SET_COOKIE)
        .iter()
        .any(|v| v.to_str().unwrap().contains("HttpOnly; SameSite=Lax")));
    let body = html(register, StatusCode::OK, "Create an account").await;
    let csrf = hidden(&body, "_csrf_token");
    let values = [
        ("email", "web-form@example.invalid"),
        ("password", PASSWORD),
        ("password_confirmation", PASSWORD),
        ("_csrf_token", csrf.as_str()),
    ];
    for (origin, cookies, token) in [
        (None, preauth.as_str(), csrf.as_str()),
        (
            Some("https://evil.invalid"),
            preauth.as_str(),
            csrf.as_str(),
        ),
        (Some(ORIGIN), "", csrf.as_str()),
        (Some(ORIGIN), preauth.as_str(), "wrong"),
    ] {
        let mut request = client
            .post(format!("{base}/register"))
            .header(header::COOKIE, cookies);
        if let Some(origin) = origin {
            request = request.header(header::ORIGIN, origin);
        }
        let mut fields = values;
        fields[3].1 = token;
        assert_eq!(
            request.form(&fields).send().await.unwrap().status(),
            StatusCode::FORBIDDEN
        );
    }
    let denied = client
        .post(format!("{base}/register"))
        .header(header::COOKIE, &preauth)
        .header(header::ORIGIN, ORIGIN)
        .header("sec-fetch-site", "cross-site")
        .form(&values)
        .send()
        .await
        .unwrap();
    assert_eq!(denied.status(), StatusCode::FORBIDDEN);
    let registered = client
        .post(format!("{base}/register"))
        .header(header::ORIGIN, ORIGIN)
        .header(header::COOKIE, format!("{preauth}; {return_cookie}"))
        .form(&values)
        .send()
        .await
        .unwrap();
    assert_eq!(registered.status(), StatusCode::SEE_OTHER);
    assert_eq!(registered.headers()[header::LOCATION], "/dashboard/account");
    let session = cookie(&registered, "pd_session");
    html(
        client
            .get(format!("{base}/dashboard/account"))
            .header(header::COOKIE, &session)
            .send()
            .await
            .unwrap(),
        StatusCode::OK,
        "account-page",
    )
    .await;
    let account = client
        .get(format!("{base}/dashboard/account"))
        .header(header::COOKIE, &session)
        .send()
        .await
        .unwrap()
        .text()
        .await
        .unwrap();
    let signed_csrf = hidden(&account, "_csrf_token");
    let signed_out = client
        .post(format!("{base}/sign-out"))
        .header(header::ORIGIN, ORIGIN)
        .header(header::COOKIE, &session)
        .form(&[("_csrf_token", signed_csrf.as_str())])
        .send()
        .await
        .unwrap();
    assert_eq!(signed_out.status(), StatusCode::SEE_OTHER);
    assert_eq!(
        client
            .get(format!("{base}/dashboard"))
            .header(header::COOKIE, &session)
            .send()
            .await
            .unwrap()
            .status(),
        StatusCode::SEE_OTHER
    );
    let sign_in = client.get(format!("{base}/sign-in")).send().await.unwrap();
    let preauth = cookie(&sign_in, "pd_preauth");
    let sign_in = sign_in.text().await.unwrap();
    let csrf = hidden(&sign_in, "_csrf_token");
    let signed_in = client
        .post(format!("{base}/sign-in"))
        .header(header::ORIGIN, ORIGIN)
        .header(header::COOKIE, &preauth)
        .form(&[
            ("email", "web-form@example.invalid"),
            ("password", PASSWORD),
            ("_csrf_token", csrf.as_str()),
        ])
        .send()
        .await
        .unwrap();
    assert_eq!(signed_in.status(), StatusCode::SEE_OTHER);
    assert_eq!(signed_in.headers()[header::LOCATION], "/dashboard");
    let renewed = cookie(&signed_in, "pd_session");
    assert!(renewed != session);
    for path in ["/sign-in", "/reset", "/reset/complete?token=invalid"] {
        html(
            client.get(format!("{base}{path}")).send().await.unwrap(),
            StatusCode::OK,
            "PostDeploy",
        )
        .await;
    }
    html(
        client
            .get(format!("{base}/does-not-exist"))
            .send()
            .await
            .unwrap(),
        StatusCode::NOT_FOUND,
        "Page not found",
    )
    .await;
    for (path, mime) in [
        ("/css/app.css", "text/css"),
        ("/css/layout.css", "text/css"),
        ("/js/console.js", "javascript"),
        ("/favicon.svg", "image/svg+xml"),
        ("/brand/postdeploy-mark.svg", "image/svg+xml"),
        ("/images/postdeploy-mark.svg", "image/svg+xml"),
        ("/fonts/open-runde-600.woff2", "font/woff2"),
    ] {
        let response = client.get(format!("{base}{path}")).send().await.unwrap();
        assert_eq!(response.status(), StatusCode::OK, "static path {path}");
        assert!(response.headers()[header::CONTENT_TYPE]
            .to_str()
            .unwrap()
            .contains(mime));
    }
    TestApp::on_shutdown(&boot.app_context).await;
    server.abort();
    let _ = server.await;
}

#[tokio::test]
async fn dashboard_forms_and_project_pages_use_live_services_and_one_time_dsns() {
    let env = TestEnv::new("web-project");
    let boot = env.boot_memory(|_| {}).await.unwrap();
    let (base, server) = serve(&boot).await;
    let client = http();
    let api = Api::signup(&base, "web-project@example.invalid").await;
    let (org, project, dsn) = api.setup_source("Web forms").await;
    let org_base = format!("/dashboard/orgs/{org}");
    let project_base = format!("{org_base}/projects/{project}");
    for (path, marker) in [
        ("/dashboard".to_owned(), "Web forms"),
        ("/dashboard/account".to_owned(), "account-page"),
        (format!("{org_base}/projects"), "web"),
        (format!("{org_base}/team"), "team-page"),
        (format!("{org_base}/settings"), "settings-page"),
        (
            format!("{org_base}/settings/notifications"),
            "notification-settings-page",
        ),
        (project_base.clone(), "No report yet"),
        (format!("{project_base}/observe"), "observe-page"),
        (format!("{project_base}/logs"), "logs-page"),
        (format!("{project_base}/sources"), "api"),
        (format!("{project_base}/access"), "Agent"),
    ] {
        html(
            client
                .get(format!("{base}{path}"))
                .header(header::COOKIE, api.cookie.as_deref().unwrap())
                .send()
                .await
                .unwrap(),
            StatusCode::OK,
            marker,
        )
        .await;
    }
    let rejected = client
        .post(format!("{base}/dashboard/account/name"))
        .header(header::COOKIE, api.cookie.as_deref().unwrap())
        .header(header::ORIGIN, ORIGIN)
        .form(&[("name", "Malicious"), ("_csrf_token", "wrong")])
        .send()
        .await
        .unwrap();
    assert_eq!(rejected.status(), StatusCode::FORBIDDEN);
    let changed = form(
        &client,
        &base,
        "/dashboard/account/name",
        &api,
        &[("name", "Ada Browser")],
    )
    .send()
    .await
    .unwrap();
    assert_eq!(changed.status(), StatusCode::SEE_OTHER);
    html(
        client
            .get(format!("{base}/dashboard/account"))
            .header(header::COOKIE, api.cookie.as_deref().unwrap())
            .send()
            .await
            .unwrap(),
        StatusCode::OK,
        "Ada Browser",
    )
    .await;
    let renamed = form(
        &client,
        &base,
        &format!("{org_base}/settings/name"),
        &api,
        &[("name", "Renamed Web")],
    )
    .send()
    .await
    .unwrap();
    assert_eq!(renamed.status(), StatusCode::SEE_OTHER);
    html(
        client
            .get(format!("{base}{org_base}/settings"))
            .header(header::COOKIE, api.cookie.as_deref().unwrap())
            .send()
            .await
            .unwrap(),
        StatusCode::OK,
        "Renamed Web",
    )
    .await;
    let created = form(
        &client,
        &base,
        &format!("{project_base}/sources"),
        &api,
        &[("name", "Browser source"), ("environment", "staging")],
    )
    .send()
    .await
    .unwrap();
    let created = html(created, StatusCode::CREATED, "source-dsn-value").await;
    let new_dsn = created
        .split_once("id=\"source-dsn-value\"")
        .unwrap()
        .1
        .split_once('>')
        .unwrap()
        .1
        .split('<')
        .next()
        .unwrap();
    assert!(new_dsn.contains('@'));
    let (_, sources) = api
        .get(&format!("/api/orgs/{org}/projects/{project}/sources"))
        .await;
    let source_id = sources["sources"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["name"] == "Browser source")
        .unwrap()["id"]
        .as_i64()
        .unwrap();
    let source_path = format!("{project_base}/sources/{source_id}");
    let read = html(
        client
            .get(format!("{base}{source_path}"))
            .header(header::COOKIE, api.cookie.as_deref().unwrap())
            .send()
            .await
            .unwrap(),
        StatusCode::OK,
        "Browser source",
    )
    .await;
    assert!(!read.contains(new_dsn));
    assert!(!read.contains("id=\"source-dsn-value\""));
    let rotated = html(
        form(&client, &base, &format!("{source_path}/rotate"), &api, &[])
            .send()
            .await
            .unwrap(),
        StatusCode::CREATED,
        "source-dsn-value",
    )
    .await;
    assert!(!rotated.contains(new_dsn));
    assert_eq!(
        form(&client, &base, &format!("{source_path}/revoke"), &api, &[])
            .send()
            .await
            .unwrap()
            .status(),
        StatusCode::SEE_OTHER
    );
    html(
        client
            .get(format!("{base}{source_path}"))
            .header(header::COOKIE, api.cookie.as_deref().unwrap())
            .send()
            .await
            .unwrap(),
        StatusCode::OK,
        "Not accepting events",
    )
    .await;
    let key = support::dsn_key(&dsn);
    let (status, _) = support::post_envelope(
        &base,
        project,
        &key,
        support::envelope(
            Some("1234567890abcdef1234567890abcdef"),
            &["browser log evidence"],
        ),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (_, issues) = api
        .get(&format!("/api/orgs/{org}/issues?project={project}"))
        .await;
    let issue = issues["issues"][0]["id"].as_i64().unwrap();
    let issue_path = format!("{project_base}/observe/issues/{issue}");
    html(
        client
            .get(format!("{base}{issue_path}"))
            .header(header::COOKIE, api.cookie.as_deref().unwrap())
            .send()
            .await
            .unwrap(),
        StatusCode::OK,
        "kaput",
    )
    .await;
    assert_eq!(
        form(&client, &base, &format!("{issue_path}/resolve"), &api, &[])
            .send()
            .await
            .unwrap()
            .status(),
        StatusCode::SEE_OTHER
    );
    let (_, issue_json) = api.get(&format!("/api/orgs/{org}/issues/{issue}")).await;
    assert_eq!(issue_json["issue"]["status"], "resolved");
    let rt = Runtime::get(&boot.app_context);
    let (_, session) = api.get("/api/auth/session").await;
    let user = postdeploy::domain::UserId(session["user"]["id"].as_i64().unwrap());
    let org_id = org.parse().unwrap();
    let access = postdeploy::identity::access::authorize(&rt, user, &org_id)
        .await
        .unwrap();
    let report = Services::get(&boot.app_context).reports.publish(&access, serde_json::from_value(json!({
        "project_id": project, "title": "Browser investigation", "summary": "An agent checked the stored event.",
        "findings": [{"title": "Handler failure", "severity": "high", "detail": "The handler raised an exception.",
            "evidence": [{"kind": "issue", "issue_id": issue}]}]
    })).unwrap()).await.unwrap();
    for path in [
        project_base.clone(),
        format!("{project_base}/reports/{}", report.report.id),
    ] {
        let rendered = html(
            client
                .get(format!("{base}{path}"))
                .header(header::COOKIE, api.cookie.as_deref().unwrap())
                .send()
                .await
                .unwrap(),
            StatusCode::OK,
            "Browser investigation",
        )
        .await;
        assert!(rendered.contains(&issue_path));
        assert!(rendered.contains("An agent checked the stored event."));
    }
    support::eventually(std::time::Duration::from_secs(8), || async {
        let (_, logs) = api
            .get(&format!("/api/orgs/{org}/logs?project={project}"))
            .await;
        logs["rows"]
            .as_array()
            .is_some_and(|rows| rows.iter().any(|r| r["body"] == "browser log evidence"))
    })
    .await;
    html(
        client
            .get(format!("{base}{project_base}/logs"))
            .header(header::COOKIE, api.cookie.as_deref().unwrap())
            .send()
            .await
            .unwrap(),
        StatusCode::OK,
        "browser log evidence",
    )
    .await;
    let trace = "0123456789abcdef0123456789abcdef";
    let correlated = html(
        client
            .get(format!(
                "{base}{project_base}/logs?trace_id={trace}&q=not-matched"
            ))
            .header(header::COOKIE, api.cookie.as_deref().unwrap())
            .send()
            .await
            .unwrap(),
        StatusCode::OK,
        "No log lines match this search.",
    )
    .await;
    assert!(correlated.contains(&format!("name=\"trace_id\" value=\"{trace}\"")));
    let outsider = Api::signup(&base, "web-outsider@example.invalid").await;
    html(
        client
            .get(format!("{base}{project_base}"))
            .header(header::COOKIE, outsider.cookie.as_deref().unwrap())
            .send()
            .await
            .unwrap(),
        StatusCode::NOT_FOUND,
        "Page not found",
    )
    .await;
    TestApp::on_shutdown(&boot.app_context).await;
    server.abort();
    let _ = server.await;
}

#[tokio::test]
async fn oauth_http_discovery_registration_consent_token_and_revoke() {
    let env = TestEnv::new("web-oauth");
    let boot = env.boot_memory(|_| {}).await.unwrap();
    let (base, server) = serve(&boot).await;
    let client = http();
    let api = Api::signup(&base, "web-oauth@example.invalid").await;
    let (org, project, _) = api.setup_source("OAuth browser").await;
    let resource = Runtime::get(&boot.app_context)
        .settings
        .oauth
        .resource
        .clone();
    let discovery: Value = client
        .get(format!("{base}/.well-known/oauth-authorization-server"))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(
        discovery["authorization_endpoint"],
        format!("{ORIGIN}/oauth/authorize")
    );
    let metadata: Value = client
        .get(format!("{base}/.well-known/oauth-protected-resource/mcp"))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(metadata["resource"], resource);
    let redirect = "http://127.0.0.1:31589/callback";
    let registration = client.post(format!("{base}/oauth/register")).json(&json!({"client_name":"Browser agent", "redirect_uris":[redirect], "scope":"logs:read"})).send().await.unwrap();
    assert_eq!(registration.status(), StatusCode::CREATED);
    let registered: Value = registration.json().await.unwrap();
    let client_id = registered["client_id"].as_str().unwrap();
    let verifier = "a".repeat(43);
    let challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));
    let query = url::form_urlencoded::Serializer::new(String::new())
        .extend_pairs([
            ("response_type", "code"),
            ("client_id", client_id),
            ("redirect_uri", redirect),
            ("code_challenge", &challenge),
            ("code_challenge_method", "S256"),
            ("scope", "logs:read"),
            ("state", "browser-state"),
            ("resource", &resource),
        ])
        .finish();
    let consent_path = format!("/oauth/authorize?{query}");
    let unsigned = client
        .get(format!("{base}{consent_path}"))
        .send()
        .await
        .unwrap();
    assert_eq!(unsigned.status(), StatusCode::SEE_OTHER);
    assert_eq!(unsigned.headers()[header::LOCATION], "/sign-in");
    let consent = html(
        client
            .get(format!("{base}{consent_path}"))
            .header(header::COOKIE, api.cookie.as_deref().unwrap())
            .send()
            .await
            .unwrap(),
        StatusCode::OK,
        "Browser agent",
    )
    .await;
    let handle = hidden(&consent, "consent");
    let approved = form(
        &client,
        &base,
        "/oauth/authorize",
        &api,
        &[
            ("consent", &handle),
            ("org_id", &org),
            ("decision", "allow"),
            ("scopes", "logs:read"),
        ],
    )
    .send()
    .await
    .unwrap();
    assert_eq!(approved.status(), StatusCode::SEE_OTHER);
    let target = url::Url::parse(approved.headers()[header::LOCATION].to_str().unwrap()).unwrap();
    let code = target
        .query_pairs()
        .find(|(k, _)| k == "code")
        .unwrap()
        .1
        .into_owned();
    assert_eq!(
        target.query_pairs().find(|(k, _)| k == "state").unwrap().1,
        "browser-state"
    );
    let exchange = [
        ("grant_type", "authorization_code"),
        ("client_id", client_id),
        ("code", &code),
        ("redirect_uri", redirect),
        ("code_verifier", &verifier),
        ("resource", &resource),
    ];
    let token = client
        .post(format!("{base}/oauth/token"))
        .form(&exchange)
        .send()
        .await
        .unwrap();
    assert_eq!(token.status(), StatusCode::OK);
    assert_eq!(token.headers()[header::CACHE_CONTROL], "no-store");
    let token: Value = token.json().await.unwrap();
    let access = token["access_token"].as_str().unwrap();
    assert_eq!(
        client
            .get(format!("{base}/api/orgs/{org}/logs"))
            .bearer_auth(access)
            .send()
            .await
            .unwrap()
            .status(),
        StatusCode::OK
    );
    let access_page = format!("/dashboard/orgs/{org}/projects/{project}/access");
    let grants = html(
        client
            .get(format!("{base}{access_page}"))
            .header(header::COOKIE, api.cookie.as_deref().unwrap())
            .send()
            .await
            .unwrap(),
        StatusCode::OK,
        "Browser agent",
    )
    .await;
    assert!(grants.contains("Revoke"));
    let revoke_path = grants
        .split("action=\"")
        .filter_map(|part| part.split('"').next())
        .find(|path| path.starts_with(&format!("{access_page}/grants/")))
        .expect("grant revoke form");
    assert_eq!(
        form(&client, &base, revoke_path, &api, &[])
            .send()
            .await
            .unwrap()
            .status(),
        StatusCode::SEE_OTHER
    );
    assert_eq!(
        client
            .get(format!("{base}/api/orgs/{org}/logs"))
            .bearer_auth(access)
            .send()
            .await
            .unwrap()
            .status(),
        StatusCode::UNAUTHORIZED
    );
    let revoked = client
        .post(format!("{base}/oauth/revoke"))
        .form(&[("client_id", client_id), ("token", access)])
        .send()
        .await
        .unwrap();
    assert_eq!(revoked.status(), StatusCode::OK);
    assert_eq!(
        client
            .get(format!("{base}/api/orgs/{org}/logs"))
            .bearer_auth(access)
            .send()
            .await
            .unwrap()
            .status(),
        StatusCode::UNAUTHORIZED
    );
    let replay = client
        .post(format!("{base}/oauth/token"))
        .form(&exchange)
        .send()
        .await
        .unwrap();
    assert_eq!(replay.status(), StatusCode::BAD_REQUEST);
    TestApp::on_shutdown(&boot.app_context).await;
    server.abort();
    let _ = server.await;
}

#[tokio::test]
async fn team_forms_recheck_roles_confirm_removal_and_transfer_ownership() {
    let env = TestEnv::new("web-team");
    let boot = env.boot_memory(|_| {}).await.unwrap();
    let (base, server) = serve(&boot).await;
    let client = http();
    let owner = Api::signup(&base, "web-owner@example.invalid").await;
    let member = Api::signup(&base, "web-member@example.invalid").await;
    let (org, project, _) = owner.setup_source("Web team").await;
    let (status, added) = owner
        .post(
            &format!("/api/orgs/{org}/members"),
            json!({"email":"web-member@example.invalid", "role":"member"}),
        )
        .await;
    assert_eq!(status, StatusCode::CREATED);
    let member_id = added["user_id"].as_i64().unwrap();
    let team = format!("/dashboard/orgs/{org}/team");
    let body = html(
        client
            .get(format!("{base}{team}"))
            .header(header::COOKIE, member.cookie.as_deref().unwrap())
            .send()
            .await
            .unwrap(),
        StatusCode::OK,
        "web-owner@example.invalid",
    )
    .await;
    assert!(!body.contains(&format!("action=\"{team}/{member_id}/role\"")));
    let forbidden = form(
        &client,
        &base,
        &format!("/dashboard/orgs/{org}/settings/name"),
        &member,
        &[("name", "Unauthorized")],
    )
    .send()
    .await
    .unwrap();
    assert_eq!(forbidden.status(), StatusCode::FORBIDDEN);
    let forbidden = form(
        &client,
        &base,
        &format!("/dashboard/orgs/{org}/projects/{project}/sources"),
        &member,
        &[("name", "Unauthorized"), ("environment", "production")],
    )
    .send()
    .await
    .unwrap();
    assert_eq!(forbidden.status(), StatusCode::FORBIDDEN);
    assert_eq!(
        form(
            &client,
            &base,
            &format!("{team}/{member_id}/role"),
            &owner,
            &[("role", "admin")]
        )
        .send()
        .await
        .unwrap()
        .status(),
        StatusCode::SEE_OTHER
    );
    let (_, members) = owner.get(&format!("/api/orgs/{org}/members")).await;
    assert_eq!(
        members["members"]
            .as_array()
            .unwrap()
            .iter()
            .find(|m| m["user_id"] == member_id)
            .unwrap()["role"],
        "admin"
    );
    assert_eq!(
        form(
            &client,
            &base,
            &format!("{team}/{member_id}/remove"),
            &owner,
            &[("confirm_email", "wrong@example.invalid")]
        )
        .send()
        .await
        .unwrap()
        .status(),
        StatusCode::SEE_OTHER
    );
    let (_, members) = owner.get(&format!("/api/orgs/{org}/members")).await;
    assert_eq!(members["members"].as_array().unwrap().len(), 2);
    assert_eq!(
        form(
            &client,
            &base,
            &format!("{team}/{member_id}/transfer"),
            &owner,
            &[("confirm_email", "web-member@example.invalid")]
        )
        .send()
        .await
        .unwrap()
        .status(),
        StatusCode::SEE_OTHER
    );
    let (_, members) = owner.get(&format!("/api/orgs/{org}/members")).await;
    assert_eq!(
        members["members"]
            .as_array()
            .unwrap()
            .iter()
            .find(|m| m["user_id"] == member_id)
            .unwrap()["role"],
        "owner"
    );
    let (_, session) = owner.get("/api/auth/session").await;
    let owner_id = session["user"]["id"].as_i64().unwrap();
    assert_eq!(
        members["members"]
            .as_array()
            .unwrap()
            .iter()
            .find(|m| m["user_id"] == owner_id)
            .unwrap()["role"],
        "admin"
    );
    assert_eq!(
        form(
            &client,
            &base,
            &format!("{team}/{owner_id}/remove"),
            &member,
            &[("confirm_email", "web-owner@example.invalid")]
        )
        .send()
        .await
        .unwrap()
        .status(),
        StatusCode::SEE_OTHER
    );
    let (_, members) = member.get(&format!("/api/orgs/{org}/members")).await;
    assert_eq!(members["members"].as_array().unwrap().len(), 1);
    html(
        client
            .get(format!("{base}{team}"))
            .header(header::COOKIE, owner.cookie.as_deref().unwrap())
            .send()
            .await
            .unwrap(),
        StatusCode::NOT_FOUND,
        "Page not found",
    )
    .await;
    TestApp::on_shutdown(&boot.app_context).await;
    server.abort();
    let _ = server.await;
}
