mod support;

use loco_rs::app::Hooks;
use postdeploy::testing::{serve, TestApp, TestEnv};
use reqwest::StatusCode;
use support::Api;

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
async fn notifications_page_states_the_events_every_channel_receives() {
    let env = TestEnv::new("notification-events");
    let boot = env.boot_memory(|_| {}).await.unwrap();
    let (base, server) = serve(&boot).await;
    let api = Api::signup(&base, "notes@example.invalid").await;
    let (org, _, _) = api.setup_source("Notes").await;
    let html = page(
        &api,
        &format!("/dashboard/orgs/{org}/settings/notifications"),
    )
    .await;
    assert!(html.contains(
        "id=\"notification-events\" class=\"mt-1 text-body text-text-secondary\">Every channel receives new issues, regressions, and published reports."
    ));
    assert!(!html.contains("Add a channel before you add a rule."));
    assert!(!html.contains("No alert rules."));
    assert!(!html.contains("Alert rules"));
    TestApp::on_shutdown(&boot.app_context).await;
    server.abort();
    let _ = server.await;
    drop(boot);
    drop(env);
}
