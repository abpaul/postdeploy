mod support;

use loco_rs::app::Hooks;
use postdeploy::{
    runtime::Runtime,
    testing::{serve, TestApp, TestEnv},
};
use reqwest::StatusCode;
use serde_json::json;
use support::{envelope, post_envelope, Api};

async fn page(api: &Api, path: &str) -> String {
    let response = api
        .http
        .get(format!("{}{path}", api.base))
        .header("cookie", api.cookie.as_deref().unwrap())
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK, "{path}");
    response.text().await.unwrap()
}

#[tokio::test]
async fn member_sees_agent_commands_on_the_source_page() {
    let env = TestEnv::new("source-agent-commands");
    let boot = env.boot_memory(|_| {}).await.unwrap();
    let (base, server) = serve(&boot).await;
    let owner = Api::signup(&base, "owner@source-agent.example").await;
    let member = Api::signup(&base, "member@source-agent.example").await;
    let (status, org) = owner.post("/api/orgs", json!({"name": "Commands"})).await;
    assert_eq!(status, StatusCode::CREATED);
    let org = org["id"].as_str().unwrap();
    let (status, _) = owner
        .post(
            &format!("/api/orgs/{org}/members"),
            json!({"email": "member@source-agent.example", "role": "member"}),
        )
        .await;
    assert_eq!(status, StatusCode::CREATED);
    let (status, project) = owner
        .post(&format!("/api/orgs/{org}/projects"), json!({"name": "web"}))
        .await;
    assert_eq!(status, StatusCode::CREATED);
    let project = project["id"].as_i64().unwrap();
    let (status, source) = owner
        .post(
            &format!("/api/orgs/{org}/projects/{project}/sources"),
            json!({"name": "api", "environment": "production"}),
        )
        .await;
    assert_eq!(status, StatusCode::CREATED, "{source}");
    let source_id = source["source"]["id"].as_i64().unwrap();
    let dsn = source["dsn"].as_str().unwrap();
    let (status, _) = post_envelope(
        &base,
        project,
        &support::dsn_key(dsn),
        envelope(Some("abababababababababababababababab"), &[]),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let endpoint = Runtime::get(&boot.app_context)
        .settings
        .oauth
        .resource
        .clone();
    let claude = format!("claude mcp add --transport http postdeploy {endpoint}");
    let codex = format!("codex mcp add postdeploy --url {endpoint}");
    let source_page = page(
        &member,
        &format!("/dashboard/orgs/{org}/projects/{project}/sources/{source_id}"),
    )
    .await;
    assert!(source_page.contains(&claude), "{source_page}");
    assert!(source_page.contains(&codex), "{source_page}");
    assert!(source_page.contains("id=\"source-agent-endpoint\""));
    assert!(source_page.contains(&endpoint));
    assert!(source_page.contains("href=\"/docs/agents\""));
    assert!(!source_page.contains("id=\"source-api-key-link\""));
    assert!(!source_page.contains("<section id=\"source-agent\" hidden"));
    let owner_source = page(
        &owner,
        &format!("/dashboard/orgs/{org}/projects/{project}/sources/{source_id}"),
    )
    .await;
    assert!(owner_source.contains("id=\"source-api-key-link\""));
    assert!(owner_source.contains(&format!("/dashboard/orgs/{org}/settings#api-keys")));
    let settings = page(&owner, &format!("/dashboard/orgs/{org}/settings")).await;
    assert!(settings.contains(&claude), "{settings}");
    assert!(settings.contains(&codex), "{settings}");
    TestApp::on_shutdown(&boot.app_context).await;
    server.abort();
    let _ = server.await;
    drop(boot);
    drop(env);
}
