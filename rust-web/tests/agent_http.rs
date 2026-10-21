mod support;

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use loco_rs::app::Hooks;
use postdeploy::{
    agent_access::{AuthorizeRequest, ClientRegistration, RevokeForm, TokenForm},
    domain::{OrgId, UserId},
    runtime::Runtime,
    services::Services,
    testing::{serve, TestApp, TestEnv},
};
use reqwest::StatusCode;
use serde_json::json;
use sha2::{Digest, Sha256};
use support::Api;

#[tokio::test]
async fn oauth_api_enforces_scope_org_and_revocation() {
    let env = TestEnv::new("agent-http");
    let boot = env.boot_memory(|_| {}).await.unwrap();
    let (base, server) = serve(&boot).await;
    let api = Api::signup(&base, "agent-http@example.invalid").await;
    let (_, session) = api.get("/api/auth/session").await;
    let user = UserId(session["user"]["id"].as_i64().unwrap());
    let (org, _, dsn) = api.setup_source("Agent API").await;
    let org: OrgId = org.parse().unwrap();
    let (status, other) = api
        .post("/api/orgs", json!({"name":"Another organization"}))
        .await;
    assert_eq!(status, StatusCode::CREATED);
    let oauth = &Services::get(&boot.app_context).oauth;
    let redirect = "http://127.0.0.1:31589/callback";
    let client = oauth
        .register_client(ClientRegistration {
            redirect_uris: vec![redirect.into()],
            scope: Some("logs:read".into()),
            ..ClientRegistration::default()
        })
        .await
        .unwrap();
    let verifier = "a".repeat(43);
    let resource = Runtime::get(&boot.app_context)
        .settings
        .oauth
        .resource
        .clone();
    let postdeploy::agent_access::Consent::Ready(prompt) = oauth
        .begin_consent(
            user,
            AuthorizeRequest {
                response_type: Some("code".into()),
                client_id: Some(client.client_id.as_str().into()),
                redirect_uri: Some(redirect.into()),
                code_challenge: Some(URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()))),
                code_challenge_method: Some("S256".into()),
                scope: Some("logs:read".into()),
                state: Some("isolated-state".into()),
                resource: Some(resource.clone()),
            },
        )
        .await
        .unwrap()
    else {
        panic!("the user belongs to an organization");
    };
    let redirect_url = oauth
        .approve_consent(user, prompt.handle.expose(), &org, prompt.requested.clone())
        .await
        .unwrap();
    let url = url::Url::parse(&redirect_url).unwrap();
    let code = url
        .query_pairs()
        .find(|(key, _)| key == "code")
        .unwrap()
        .1
        .into_owned();
    let token = oauth
        .token(TokenForm {
            grant_type: Some("authorization_code".into()),
            client_id: Some(client.client_id.as_str().into()),
            code: Some(code.into()),
            redirect_uri: Some(redirect.into()),
            code_verifier: Some(verifier.into()),
            resource: Some(resource),
            ..TokenForm::default()
        })
        .await
        .unwrap();
    let http = reqwest::Client::new();
    let read = http
        .get(format!("{base}/api/orgs/{org}/logs"))
        .bearer_auth(token.access_token.expose())
        .send()
        .await
        .unwrap();
    assert_eq!(read.status(), StatusCode::OK);
    let page: serde_json::Value = read.json().await.unwrap();
    assert!(page["rows"].as_array().unwrap().is_empty());
    let rejected = http
        .post(format!("{base}/api/orgs/{org}/projects"))
        .bearer_auth(token.access_token.expose())
        .json(&json!({"name":"Forbidden"}))
        .send()
        .await
        .unwrap();
    assert_eq!(rejected.status(), StatusCode::FORBIDDEN);
    let (_, projects) = api.get(&format!("/api/orgs/{org}/projects")).await;
    assert_eq!(projects["projects"].as_array().unwrap().len(), 1);
    let other_org = other["id"].as_str().unwrap();
    let rejected = http
        .get(format!("{base}/api/orgs/{other_org}/logs"))
        .bearer_auth(token.access_token.expose())
        .send()
        .await
        .unwrap();
    assert_eq!(rejected.status(), StatusCode::NOT_FOUND);
    let dsn = url::Url::parse(&dsn).unwrap();
    let rejected = http
        .get(format!("{base}/api/orgs/{org}/logs"))
        .bearer_auth(dsn.username())
        .send()
        .await
        .unwrap();
    assert_eq!(rejected.status(), StatusCode::UNAUTHORIZED);
    oauth
        .revoke(RevokeForm {
            token: Some(token.access_token.expose().into()),
            client_id: Some(client.client_id.as_str().into()),
            token_type_hint: None,
        })
        .await
        .unwrap();
    let revoked = http
        .get(format!("{base}/api/orgs/{org}/logs"))
        .bearer_auth(token.access_token.expose())
        .send()
        .await
        .unwrap();
    assert_eq!(revoked.status(), StatusCode::UNAUTHORIZED);
    TestApp::on_shutdown(&boot.app_context).await;
    server.abort();
    let _ = server.await;
}

#[tokio::test]
async fn usage_bearer_requires_projects_read_and_hides_other_organizations() {
    let env = TestEnv::new("usage-oauth-scope");
    let boot = env.boot_memory(|_| {}).await.unwrap();
    let (base, server) = serve(&boot).await;
    let api = Api::signup(&base, "usage-oauth@example.test").await;
    let (_, session) = api.get("/api/auth/session").await;
    let user = UserId(session["user"]["id"].as_i64().unwrap());
    let (org, ..) = api.setup_source("Usage OAuth").await;
    let (other, ..) = api.setup_source("Other Usage OAuth").await;
    let unauthorized = reqwest::Client::new()
        .get(format!("{base}/api/orgs/{org}/usage"))
        .bearer_auth("invalid-usage-token")
        .send()
        .await
        .unwrap();
    assert_eq!(unauthorized.status(), StatusCode::UNAUTHORIZED);
    let oauth = &Services::get(&boot.app_context).oauth;
    let redirect = "http://127.0.0.1:31589/callback";
    let resource = Runtime::get(&boot.app_context)
        .settings
        .oauth
        .resource
        .clone();
    for (scope, expected) in [
        ("projects:read", StatusCode::OK),
        ("logs:read", StatusCode::FORBIDDEN),
    ] {
        let client = oauth
            .register_client(ClientRegistration {
                redirect_uris: vec![redirect.into()],
                scope: Some(scope.into()),
                ..ClientRegistration::default()
            })
            .await
            .unwrap();
        let verifier = "b".repeat(43);
        let postdeploy::agent_access::Consent::Ready(prompt) = oauth
            .begin_consent(
                user,
                AuthorizeRequest {
                    response_type: Some("code".into()),
                    client_id: Some(client.client_id.as_str().into()),
                    redirect_uri: Some(redirect.into()),
                    code_challenge: Some(
                        URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes())),
                    ),
                    code_challenge_method: Some("S256".into()),
                    scope: Some(scope.into()),
                    state: Some("usage-state".into()),
                    resource: Some(resource.clone()),
                },
            )
            .await
            .unwrap()
        else {
            panic!("the user belongs to an organization");
        };
        let redirect_url = oauth
            .approve_consent(
                user,
                prompt.handle.expose(),
                &org.parse().unwrap(),
                prompt.requested.clone(),
            )
            .await
            .unwrap();
        let url = url::Url::parse(&redirect_url).unwrap();
        let code = url
            .query_pairs()
            .find(|(k, _)| k == "code")
            .unwrap()
            .1
            .into_owned();
        let token = oauth
            .token(TokenForm {
                grant_type: Some("authorization_code".into()),
                client_id: Some(client.client_id.as_str().into()),
                code: Some(code.into()),
                redirect_uri: Some(redirect.into()),
                code_verifier: Some(verifier.into()),
                resource: Some(resource.clone()),
                ..TokenForm::default()
            })
            .await
            .unwrap();
        let http = reqwest::Client::new();
        let response = http
            .get(format!("{base}/api/orgs/{org}/usage"))
            .bearer_auth(token.access_token.expose())
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), expected);
        if expected == StatusCode::OK {
            let body: serde_json::Value = response.json().await.unwrap();
            assert_eq!(body["errors"]["used"], 0);
            assert_eq!(body["errors"]["limit"], 1_000_000);
            assert_eq!(body["log_bytes"]["limit"], 100_000_000_000u64);
        }
        let response = http
            .get(format!("{base}/api/orgs/{other}/usage"))
            .bearer_auth(token.access_token.expose())
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::NOT_FOUND);
    }
    TestApp::on_shutdown(&boot.app_context).await;
    server.abort();
    let _ = server.await;
}
