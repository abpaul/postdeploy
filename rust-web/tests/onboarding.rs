#[path = "support/mcp.rs"]
mod common;

use common::{fixture, Fixture, CHALLENGE, PASSWORD, REDIRECT, VERIFIER};
use reqwest::{header, Response, StatusCode};
use serde_json::{json, Value};

const ORIGIN: &str = "http://127.0.0.1:5167";

fn client() -> reqwest::Client {
    reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .unwrap()
}

fn cookie(response: &Response, name: &str) -> String {
    response
        .headers()
        .get_all(header::SET_COOKIE)
        .iter()
        .map(|value| value.to_str().unwrap())
        .find(|value| value.starts_with(&format!("{name}=")))
        .unwrap_or_else(|| panic!("{name} cookie"))
        .split(';')
        .next()
        .unwrap()
        .to_owned()
}

fn location(response: &Response) -> String {
    response.headers()[header::LOCATION]
        .to_str()
        .unwrap()
        .to_owned()
}

fn hidden(html: &str, name: &str) -> String {
    let marker = format!("name=\"{name}\" value=\"");
    html.split_once(&marker)
        .unwrap_or_else(|| panic!("hidden field {name}"))
        .1
        .split('"')
        .next()
        .unwrap()
        .replace("&amp;", "&")
}

fn checked_scopes(html: &str) -> Vec<String> {
    html.split("name=\"scopes\" value=\"")
        .skip(1)
        .filter(|rest| rest.split('>').next().unwrap().contains("checked"))
        .map(|rest| rest.split('"').next().unwrap().to_owned())
        .collect()
}

fn authorize_path(f: &Fixture, client_id: &str) -> String {
    let resource = format!("{}/mcp", f.base);
    let query = url::form_urlencoded::Serializer::new(String::new())
        .extend_pairs([
            ("response_type", "code"),
            ("client_id", client_id),
            ("redirect_uri", REDIRECT),
            ("code_challenge", CHALLENGE),
            ("code_challenge_method", "S256"),
            ("state", "agent-state"),
            ("resource", resource.as_str()),
        ])
        .finish();
    format!("/oauth/authorize?{query}")
}

async fn get(f: &Fixture, http: &reqwest::Client, path: &str, cookies: &str) -> Response {
    http.get(format!("{}{path}", f.base))
        .header(header::COOKIE, cookies)
        .send()
        .await
        .unwrap()
}

/// A new account that starts from an agent: the authorize request saves the
/// return cookie, and registration follows it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn signup_from_an_agent_creates_an_org_and_lets_the_agent_set_up_a_project() {
    let f = fixture("onboarding-agent").await;
    let http = client();

    let registered: Value = http
        .post(format!("{}/oauth/register", f.base))
        .json(&json!({"client_name": "Claude Code", "redirect_uris": [REDIRECT]}))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let client_id = registered["client_id"].as_str().unwrap().to_owned();
    let authorize = authorize_path(&f, &client_id);

    let signed_out = get(&f, &http, &authorize, "").await;
    assert_eq!(signed_out.status(), StatusCode::SEE_OTHER);
    assert_eq!(location(&signed_out), "/sign-in");
    let return_cookie = cookie(&signed_out, "pd_return");

    let form = get(&f, &http, "/register", "").await;
    let preauth = cookie(&form, "pd_preauth");
    let csrf = hidden(&form.text().await.unwrap(), "_csrf_token");
    let created = http
        .post(format!("{}/register", f.base))
        .header(header::ORIGIN, ORIGIN)
        .header(header::COOKIE, format!("{preauth}; {return_cookie}"))
        .form(&[
            ("email", "agent-first@onboarding.test"),
            ("password", PASSWORD),
            ("password_confirmation", PASSWORD),
            ("_csrf_token", csrf.as_str()),
        ])
        .send()
        .await
        .unwrap();
    assert_eq!(created.status(), StatusCode::SEE_OTHER);
    assert_eq!(location(&created), authorize);
    let session = cookie(&created, "pd_session");

    let back = get(&f, &http, &authorize, &session).await;
    let status = back.status();
    let target = back
        .headers()
        .get(header::LOCATION)
        .map(|value| value.to_str().unwrap().to_owned());
    let body = back.text().await.unwrap();
    assert_eq!(
        (status, target.as_deref()),
        (
            StatusCode::SEE_OTHER,
            Some(
                format!(
                    "/dashboard/orgs/new?return_to={}",
                    url::form_urlencoded::byte_serialize(authorize.as_bytes()).collect::<String>()
                )
                .as_str()
            )
        ),
        "a signed-in user without an organization is sent to create one, not to a dead end:\n{}",
        body.split_once("<main")
            .map_or(body.as_str(), |(_, main)| main)
    );

    let org_page = get(&f, &http, &target.unwrap(), &session).await;
    assert_eq!(org_page.status(), StatusCode::OK);
    let org_html = org_page.text().await.unwrap();
    assert!(
        org_html.contains("Create an organization to finish connecting Claude Code."),
        "the org page names the waiting agent"
    );
    assert_eq!(hidden(&org_html, "return_to"), authorize);
    let org_created = http
        .post(format!("{}/dashboard/orgs/new", f.base))
        .header(header::ORIGIN, ORIGIN)
        .header(header::COOKIE, &session)
        .form(&[
            ("name", "Agent First"),
            ("return_to", authorize.as_str()),
            ("_csrf_token", hidden(&org_html, "_csrf_token").as_str()),
        ])
        .send()
        .await
        .unwrap();
    assert_eq!(org_created.status(), StatusCode::SEE_OTHER);
    assert_eq!(location(&org_created), authorize);

    let consent = get(&f, &http, &authorize, &session).await;
    assert_eq!(consent.status(), StatusCode::OK);
    let consent_html = consent.text().await.unwrap();
    assert!(consent_html.contains("Agent First"), "new org preselected");
    assert!(consent_html.contains("Let Claude Code create projects and sources"));
    assert!(!consent_html.contains("From ."), "no empty client host");
    assert_eq!(
        checked_scopes(&consent_html),
        [
            "issues:read",
            "logs:read",
            "projects:read",
            "projects:write"
        ]
    );

    let org_id = hidden(&consent_html, "org_id");
    let mut approval = vec![
        ("consent", hidden(&consent_html, "consent")),
        ("org_id", org_id.clone()),
        ("decision", "allow".to_owned()),
        ("_csrf_token", hidden(&consent_html, "_csrf_token")),
    ];
    approval.extend(
        checked_scopes(&consent_html)
            .into_iter()
            .map(|scope| ("scopes", scope)),
    );
    let approved = http
        .post(format!("{}/oauth/authorize", f.base))
        .header(header::ORIGIN, ORIGIN)
        .header(header::COOKIE, &session)
        .form(&approval)
        .send()
        .await
        .unwrap();
    assert_eq!(approved.status(), StatusCode::SEE_OTHER);
    let redirect = url::Url::parse(&location(&approved)).unwrap();
    let code = redirect
        .query_pairs()
        .find(|(key, _)| key == "code")
        .unwrap()
        .1
        .into_owned();

    let resource = format!("{}/mcp", f.base);
    let tokens: Value = http
        .post(format!("{}/oauth/token", f.base))
        .form(&[
            ("grant_type", "authorization_code"),
            ("client_id", client_id.as_str()),
            ("code", code.as_str()),
            ("redirect_uri", REDIRECT),
            ("code_verifier", VERIFIER),
            ("resource", resource.as_str()),
        ])
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(
        tokens["scope"],
        "issues:read logs:read projects:read projects:write"
    );
    let token = tokens["access_token"].as_str().unwrap();
    let (project, source, dsn) = f.source(token, "agent-made").await;
    assert_eq!(source["name"], "api");
    assert!(
        dsn.starts_with("http://") && dsn.ends_with(&format!("/{project}")),
        "{dsn}"
    );
}

async fn sign_in(f: &Fixture, email: &str) -> String {
    let response = client()
        .post(format!("{}/api/auth/login", f.base))
        .json(&json!({"email": email, "password": PASSWORD}))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK, "login");
    cookie(&response, "pd_session")
}

fn step_states(html: &str) -> Vec<(String, String)> {
    html.split("<li id=\"onboarding-step-")
        .skip(1)
        .map(|rest| {
            let key = rest.split('"').next().unwrap().to_owned();
            let state = rest
                .split_once("data-state=\"")
                .unwrap()
                .1
                .split('"')
                .next()
                .unwrap()
                .to_owned();
            (key, state)
        })
        .collect()
}

fn states(pairs: &[(&str, &str)]) -> Vec<(String, String)> {
    pairs
        .iter()
        .map(|(key, state)| ((*key).to_owned(), (*state).to_owned()))
        .collect()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn organization_control_is_static_for_one_org_and_switches_multiple_orgs() {
    use postdeploy::identity::orgs;

    let f = fixture("onboarding-org-switcher").await;
    let user = f.user("switcher@onboarding.test").await;
    let first = orgs::create(&f.rt, user, "First organization")
        .await
        .unwrap();
    let session = sign_in(&f, "switcher@onboarding.test").await;
    let http = client();
    let first_path = format!("/dashboard/orgs/{}/projects", first.id);

    let single = get(&f, &http, &first_path, &session)
        .await
        .text()
        .await
        .unwrap();
    assert!(single.contains("id=\"desktop-nav-organization-identity\""));
    assert!(!single.contains("id=\"desktop-nav-organization-switcher\""));
    assert!(single.contains("href=\"/dashboard/orgs/new\" role=\"menuitem\""));

    orgs::create(&f.rt, user, "Second organization")
        .await
        .unwrap();
    let multiple = get(&f, &http, &first_path, &session)
        .await
        .text()
        .await
        .unwrap();
    assert!(multiple.contains("id=\"desktop-nav-organization-switcher\""));
    assert!(!multiple.contains("id=\"desktop-nav-organization-identity\""));
    assert!(multiple.contains("First organization"));
    assert!(multiple.contains("Second organization"));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn projects_page_follows_each_onboarding_stage() {
    use postdeploy::{
        api_keys::{self, NewApiKey},
        identity::{access::authorize, projects},
    };
    let f = fixture("onboarding-stages").await;
    let org = f.org("owner@stages.test", "Stages").await;
    let member = f
        .add_member(&org, "member@stages.test", postdeploy::domain::Role::Member)
        .await;
    let session = sign_in(&f, "owner@stages.test").await;
    let http = client();
    let path = format!("/dashboard/orgs/{}/projects", org.id);
    let page = || async { get(&f, &http, &path, &session).await.text().await.unwrap() };
    let mcp_url = format!("{}/mcp", f.base);

    let empty = page().await;
    assert!(empty.contains("id=\"onboarding-path-yourself\""));
    assert!(empty.contains("id=\"first-project-form\""));
    assert!(empty.contains("id=\"desktop-nav-organization-identity\""));
    assert!(!empty.contains("id=\"desktop-nav-organization-switcher\""));
    assert!(empty.contains("href=\"/dashboard/orgs/new\" role=\"menuitem\""));
    assert!(empty.contains(&format!(
        "claude mcp add --transport http postdeploy {mcp_url}"
    )));
    assert!(empty.contains(&format!("codex mcp add postdeploy --url {mcp_url}")));
    assert!(!empty.contains("id=\"onboarding-agent-ready\""));
    assert_eq!(
        step_states(&empty),
        states(&[
            ("organization", "done"),
            ("project", "current"),
            ("source", "todo"),
            ("first-event", "todo"),
            ("agent", "todo"),
        ])
    );

    let member_page = get(&f, &http, &path, &sign_in(&f, "member@stages.test").await)
        .await
        .text()
        .await
        .unwrap();
    assert!(member_page.contains("Ask an organization owner or admin to create the first project."));
    assert!(member_page
        .contains("Only an organization owner or admin can let an agent create projects."));
    assert!(!member_page.contains("claude mcp add"));

    let owner = authorize(&f.rt, org.owner, &org.id).await.unwrap();
    let key = |scopes: &[&str]| NewApiKey {
        name: "agent".into(),
        scopes: Some(scopes.iter().map(|s| (*s).to_owned()).collect()),
        expires_in_days: None,
    };
    let reader = authorize(&f.rt, member, &org.id).await.unwrap();
    api_keys::create(&f.rt, &reader, key(&["issues:read"]))
        .await
        .unwrap();
    let read_agent = page().await;
    assert!(!read_agent.contains("id=\"onboarding-agent-ready\""));
    assert_eq!(step_states(&read_agent)[4], states(&[("agent", "done")])[0]);

    api_keys::create(&f.rt, &owner, key(&["projects:write"]))
        .await
        .unwrap();
    let ready = page().await;
    assert!(ready.contains("An agent is connected and can create projects and sources."));
    assert!(ready.contains("Set up PostDeploy for this repository."));

    let project = projects::create(&f.rt, &owner, "web").await.unwrap();
    let no_source = page().await;
    assert!(!no_source.contains("id=\"onboarding-paths\""));
    assert_eq!(
        step_states(&no_source),
        states(&[
            ("organization", "done"),
            ("project", "done"),
            ("source", "current"),
            ("first-event", "todo"),
            ("agent", "done"),
        ])
    );
    let project_path = format!("/dashboard/orgs/{}/projects/{}", org.id, project.id.0);
    assert!(no_source.contains(&format!("href=\"{project_path}/sources\"")));

    let (source, dsn) = projects::create_source(&f.rt, &owner, project.id, "api", "production")
        .await
        .unwrap();
    let waiting = page().await;
    assert_eq!(
        step_states(&waiting)[3],
        ("first-event".to_owned(), "current".to_owned())
    );
    assert!(waiting.contains(&format!("href=\"{project_path}/sources/{}\"", source.id.0)));

    let stored = f
        .ingest(
            &dsn.dsn,
            common::envelope("0123456789abcdef0123456789abcdef", "first", &[]),
        )
        .await;
    assert_eq!(stored, StatusCode::OK);
    let done = page().await;
    assert!(
        !done.contains("id=\"onboarding-checklist\""),
        "checklist ends at Done"
    );
    assert!(done.contains(">web</a>"));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn org_creation_returns_only_to_an_authorization_request() {
    let f = fixture("onboarding-return").await;
    f.user("new@return.test").await;
    let session = sign_in(&f, "new@return.test").await;
    let http = client();

    for target in [
        "https://evil.example/oauth/authorize?client_id=x",
        "//evil.example/oauth/authorize?client_id=x",
        "/dashboard/account",
        "/oauth/authorize",
    ] {
        let encoded: String = url::form_urlencoded::byte_serialize(target.as_bytes()).collect();
        let html = get(
            &f,
            &http,
            &format!("/dashboard/orgs/new?return_to={encoded}"),
            &session,
        )
        .await
        .text()
        .await
        .unwrap();
        assert!(!html.contains("name=\"return_to\""), "{target} refused");
        assert!(!html.contains("finish connecting"), "{target} refused");
    }

    let html = get(&f, &http, "/dashboard/orgs/new", &session)
        .await
        .text()
        .await
        .unwrap();
    let created = http
        .post(format!("{}/dashboard/orgs/new", f.base))
        .header(header::ORIGIN, ORIGIN)
        .header(header::COOKIE, &session)
        .form(&[
            ("name", "Direct"),
            (
                "return_to",
                "https://evil.example/oauth/authorize?client_id=x",
            ),
            ("_csrf_token", hidden(&html, "_csrf_token").as_str()),
        ])
        .send()
        .await
        .unwrap();
    assert_eq!(created.status(), StatusCode::SEE_OTHER);
    let target = location(&created);
    assert!(
        target.starts_with("/dashboard/orgs/") && target.ends_with("/projects"),
        "{target}"
    );
    let projects = get(&f, &http, &target, &session)
        .await
        .text()
        .await
        .unwrap();
    assert!(projects.contains("Set up your first project"));
    assert!(projects.contains("id=\"onboarding-path-agent\""));

    let unknown = authorize_path(&f, "pdi_unknown");
    let encoded: String = url::form_urlencoded::byte_serialize(unknown.as_bytes()).collect();
    let waiting = get(
        &f,
        &http,
        &format!("/dashboard/orgs/new?return_to={encoded}"),
        &session,
    )
    .await
    .text()
    .await
    .unwrap();
    assert!(waiting.contains("Create an organization to finish connecting your agent."));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn consent_errors_name_the_next_action() {
    let f = fixture("onboarding-errors").await;
    f.user("lost@errors.test").await;
    let session = sign_in(&f, "lost@errors.test").await;
    let http = client();

    let page = get(&f, &http, &authorize_path(&f, "pdi_unknown"), &session).await;
    assert_eq!(page.status(), StatusCode::BAD_REQUEST);
    let html = page.text().await.unwrap();
    assert!(html.contains(
        "This agent is not registered here. Start the connection again from your agent."
    ));
    assert!(html.contains("href=\"/dashboard/orgs/new\""));
    assert!(!html.contains("From ."));
    assert!(
        !html.contains("value=\"deny\""),
        "no Deny without a consent"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn org_form_explains_the_organization_limit() {
    let f = fixture("onboarding-org-limit").await;
    let user = f.user("limit@onboarding.test").await;
    for n in 1..=5 {
        postdeploy::identity::orgs::create(&f.rt, user, &format!("Org {n}"))
            .await
            .unwrap();
    }
    let session = sign_in(&f, "limit@onboarding.test").await;
    let http = client();
    let html = get(&f, &http, "/dashboard/orgs/new", &session)
        .await
        .text()
        .await
        .unwrap();
    let refused = http
        .post(format!("{}/dashboard/orgs/new", f.base))
        .header(header::ORIGIN, ORIGIN)
        .header(header::COOKIE, &session)
        .form(&[
            ("name", "Org 6"),
            ("_csrf_token", hidden(&html, "_csrf_token").as_str()),
        ])
        .send()
        .await
        .unwrap();
    assert_eq!(refused.status(), StatusCode::UNPROCESSABLE_ENTITY);
    assert!(refused
        .text()
        .await
        .unwrap()
        .contains("You have created the maximum number of organizations."));
}
