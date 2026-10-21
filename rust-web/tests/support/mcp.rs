#![allow(dead_code)]

use std::{net::SocketAddr, sync::Arc};

use loco_rs::{
    app::Hooks,
    boot::{BootResult, StartMode},
    config::Config,
    environment::Environment,
};
use postdeploy::{
    agent_access::{AuthorizeRequest, ClientRegistration, OAuthService, TokenForm},
    domain::{OrgId, Role, UserId},
    identity::{access::authorize, accounts, orgs},
    runtime::Runtime,
    services::Services,
    testing::{TestApp, TestEnv},
};
use reqwest::{header, StatusCode};
use serde_json::{json, Value};

pub const REDIRECT: &str = "http://127.0.0.1:9/callback";
pub const VERIFIER: &str = "dBjftJeZ4CVP-mJ92K4ZGtUPN3rM2VZVrAXQMBG7AS0";
pub const CHALLENGE: &str = "NOSqpkFz8Iy3AunRk54LYFQxpu6zFvmca0ao2UCw65o";
pub const PASSWORD: &str = "probe-password-0123456789";
pub const TRACE: &str = "0af7651916cd43dd8448eb211c80319c";
pub const OTHER_TRACE: &str = "11111111111111111111111111111111";
pub const FULL: &str = "issues:read issues:triage logs:read projects:read projects:write reports:write deployments:write";

pub struct Fixture {
    pub boot: BootResult,
    pub rt: Arc<Runtime>,
    pub faults: Arc<postdeploy::store::Faults>,
    pub oauth: OAuthService,
    pub base: String,
    pub http: reqwest::Client,
    server: tokio::task::JoinHandle<()>,
}

impl Drop for Fixture {
    fn drop(&mut self) {
        self.server.abort();
    }
}

pub struct Org {
    pub id: OrgId,
    pub owner: UserId,
}

pub async fn fixture(name: &str) -> Fixture {
    fixture_with(name, |_| {}).await
}

pub async fn fixture_with(name: &str, config: impl FnOnce(&mut Config)) -> Fixture {
    let env = TestEnv::new(&format!("{name}-{}", uuid::Uuid::now_v7().simple()));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let mut loco_config = env
        .config(&format!("test/{}/", env.name), |block| {
            block["oauth"]["issuer"] = json!(base);
            block["oauth"]["resource"] = json!(format!("{base}/mcp"));
        })
        .await;
    config(&mut loco_config);
    let boot = TestApp::boot(StartMode::ServerOnly, &Environment::Test, loco_config)
        .await
        .expect("boot test app");
    let rt = Runtime::get(&boot.app_context);
    let services = Services::get(&boot.app_context);
    let oauth = services.oauth.clone();
    let router = boot.router.clone().unwrap();
    let server = tokio::spawn(async move {
        let _ = axum::serve(
            listener,
            router.into_make_service_with_connect_info::<SocketAddr>(),
        )
        .await;
    });
    Fixture {
        boot,
        rt,
        faults: env.faults.clone(),
        oauth,
        base,
        http: reqwest::Client::new(),
        server,
    }
}

impl Fixture {
    pub async fn user(&self, email: &str) -> UserId {
        accounts::signup(&self.rt, email, PASSWORD)
            .await
            .unwrap()
            .user
            .id
    }

    pub async fn org(&self, email: &str, name: &str) -> Org {
        let owner = self.user(email).await;
        let id = orgs::create(&self.rt, owner, name).await.unwrap().id;
        Org { id, owner }
    }

    pub async fn add_member(&self, org: &Org, email: &str, role: Role) -> UserId {
        let user = self.user(email).await;
        let access = authorize(&self.rt, org.owner, &org.id).await.unwrap();
        orgs::add_member(&self.rt, &access, email, role)
            .await
            .unwrap();
        user
    }

    /// Runs the real registration, consent, and PKCE code exchange.
    pub async fn token(&self, user: UserId, org: &OrgId, scope: Option<&str>) -> String {
        self.token_and_client(user, org, scope).await.0
    }

    pub async fn token_and_client(
        &self,
        user: UserId,
        org: &OrgId,
        scope: Option<&str>,
    ) -> (String, String) {
        let (tokens, client) = self.token_response(user, org, scope).await;
        (tokens.access_token.expose().to_owned(), client)
    }

    pub async fn token_response(
        &self,
        user: UserId,
        org: &OrgId,
        scope: Option<&str>,
    ) -> (postdeploy::agent_access::TokenResponse, String) {
        let client = self
            .oauth
            .register_client(ClientRegistration {
                redirect_uris: vec![REDIRECT.into()],
                client_name: Some("MCP integration test".into()),
                scope: scope.map(str::to_owned),
                ..ClientRegistration::default()
            })
            .await
            .unwrap()
            .client_id
            .as_str()
            .to_owned();
        let postdeploy::agent_access::Consent::Ready(prompt) = self
            .oauth
            .begin_consent(
                user,
                AuthorizeRequest {
                    response_type: Some("code".into()),
                    client_id: Some(client.clone()),
                    redirect_uri: Some(REDIRECT.into()),
                    code_challenge: Some(CHALLENGE.into()),
                    code_challenge_method: Some("S256".into()),
                    scope: scope.map(str::to_owned),
                    state: None,
                    resource: Some(format!("{}/mcp", self.base)),
                },
            )
            .await
            .unwrap()
        else {
            panic!("the user belongs to an organization");
        };
        let redirect = self
            .oauth
            .approve_consent(user, prompt.handle.expose(), org, prompt.requested.clone())
            .await
            .unwrap();
        let code = url::Url::parse(&redirect)
            .unwrap()
            .query_pairs()
            .find(|(key, _)| key == "code")
            .unwrap()
            .1
            .into_owned();
        let token = self
            .oauth
            .token(TokenForm {
                grant_type: Some("authorization_code".into()),
                client_id: Some(client.clone()),
                code: Some(code.into()),
                redirect_uri: Some(REDIRECT.into()),
                code_verifier: Some(VERIFIER.into()),
                resource: Some(format!("{}/mcp", self.base)),
                ..TokenForm::default()
            })
            .await
            .unwrap();
        (token, client)
    }

    pub async fn post(
        &self,
        authorization: Option<String>,
        extra: &[(&str, &str)],
        body: Value,
    ) -> (StatusCode, header::HeaderMap, String) {
        let mut request = self
            .http
            .post(format!("{}/mcp", self.base))
            .header(header::CONTENT_TYPE, "application/json")
            .header(header::ACCEPT, "application/json, text/event-stream");
        if !extra
            .iter()
            .any(|(name, _)| name.eq_ignore_ascii_case("MCP-Protocol-Version"))
        {
            request = request.header("MCP-Protocol-Version", "2025-06-18");
        }
        if let Some(authorization) = authorization {
            request = request.header(header::AUTHORIZATION, authorization);
        }
        for (name, value) in extra {
            request = request.header(*name, *value);
        }
        let response = request.body(body.to_string()).send().await.unwrap();
        let status = response.status();
        let headers = response.headers().clone();
        (status, headers, response.text().await.unwrap())
    }

    /// Calls a tool and returns the JSON-RPC `result`.
    pub async fn call(&self, token: &str, tool: &str, arguments: Value) -> Value {
        let (status, _, body) = self
            .post(
                Some(format!("Bearer {token}")),
                &[],
                call_body(tool, arguments),
            )
            .await;
        assert_eq!(status, StatusCode::OK, "MCP request status");
        let mut parsed: Value = serde_json::from_str(&body).unwrap();
        parsed["result"].take()
    }

    pub async fn ingest(&self, dsn: &str, envelope: String) -> StatusCode {
        let rest = dsn.split_once("://").unwrap().1;
        let (key, path) = rest.split_once('@').unwrap();
        let project = path.rsplit('/').next().unwrap();
        self.http
            .post(format!("{}/api/{project}/envelope", self.base))
            .header(
                "X-Sentry-Auth",
                format!("Sentry sentry_version=7, sentry_key={key}"),
            )
            .body(envelope)
            .send()
            .await
            .unwrap()
            .status()
    }

    /// Creates a project and source through MCP and returns (project id, source, dsn).
    pub async fn source(&self, token: &str, project: &str) -> (i64, Value, String) {
        let created = self
            .call(token, "create_project", json!({ "name": project }))
            .await;
        let project_id = created["structuredContent"]["project"]["id"]
            .as_i64()
            .unwrap();
        let source = self
            .call(
                token,
                "create_source",
                json!({ "project_id": project_id, "name": "api", "environment": "production" }),
            )
            .await;
        let dsn = source["structuredContent"]["dsn"]
            .as_str()
            .unwrap()
            .to_owned();
        (
            project_id,
            source["structuredContent"]["source"].clone(),
            dsn,
        )
    }
}

pub fn call_body(tool: &str, arguments: Value) -> Value {
    json!({ "jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": { "name": tool, "arguments": arguments } })
}

pub fn now_secs() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs_f64()
}

pub fn envelope(event_id: &str, value: &str, logs: &[(&str, &str, &str)]) -> String {
    let event = json!({
        "event_id": event_id,
        "level": "error",
        "platform": "rust",
        "timestamp": now_secs(),
        "exception": { "values": [{ "type": "ProbeError", "value": value }] },
        "contexts": { "trace": { "trace_id": TRACE, "span_id": "b7ad6b7169203331" } }
    });
    let items: Vec<Value> = logs
        .iter()
        .map(|(level, body, trace)| json!({ "timestamp": now_secs(), "level": level, "body": body, "trace_id": trace }))
        .collect();
    format!(
        "{}\n{}\n{}\n{}\n{}\n",
        json!({ "event_id": event_id }),
        json!({ "type": "event" }),
        event,
        json!({ "type": "log", "item_count": items.len(), "content_type": "application/vnd.sentry.items.log+json" }),
        json!({ "items": items }),
    )
}

pub fn error_of(result: &Value) -> Value {
    assert!(result["isError"] == json!(true), "expected tool error");
    result["structuredContent"].clone()
}

pub fn titles(result: &Value) -> Vec<String> {
    result["structuredContent"]["issues"]
        .as_array()
        .unwrap()
        .iter()
        .map(|issue| issue["title"].as_str().unwrap().to_owned())
        .collect()
}
