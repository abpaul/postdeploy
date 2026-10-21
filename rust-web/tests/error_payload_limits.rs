mod support;

use loco_rs::app::Hooks;
use postdeploy::{
    domain::{Environment, ProjectId},
    ingest::{event, receipt::Reason},
    runtime::{sql, Runtime},
    testing::{serve, TestApp, TestEnv},
};
use reqwest::StatusCode;
use sea_orm::ConnectionTrait;
use serde_json::json;
use support::*;

#[test]
fn scrub_expansion_is_subject_to_the_accepted_payload_limit() {
    let body = serde_json::to_vec(&json!({
        "event_id":"8f4c2a91b703d65e0a9b72ce4681f3d0", "password":"x"
    }))
    .unwrap();
    let result = event::map(
        &body,
        None,
        ProjectId(1),
        &Environment::parse("production").unwrap(),
        1,
        body.len(),
        &postdeploy::ingest::policy::IngestionPolicy::default(),
    );
    assert!(matches!(result, Err(Reason::TooLarge)));
}

#[tokio::test]
async fn accepted_near_limit_event_round_trips_and_oversized_stored_payload_is_refused() {
    let payload = serde_json::to_vec(&json!({
        "event_id":"8f4c2a91b703d65e0a9b72ce4681f3d0", "message":"near-limit"
    }))
    .unwrap();
    let maximum = payload.len();
    let compressed = zstd::stream::encode_all(&payload[..], 3).unwrap();
    assert!(
        compressed.len() > maximum,
        "fixture must exercise compressed frame overhead"
    );
    let env = TestEnv::new("error-object-bound");
    let boot = env
        .boot_memory(|settings| settings["ingest"]["max_event_bytes"] = json!(maximum))
        .await
        .unwrap();
    let rt = Runtime::get(&boot.app_context);
    let (base, server) = serve(&boot).await;
    let api = Api::signup(&base, "payload-bound@example.test").await;
    let (org, project, dsn) = api.setup_source("Payload bound").await;
    let mut envelope = b"{}\n{\"type\":\"event\"}\n".to_vec();
    envelope.extend_from_slice(&payload);
    envelope.push(b'\n');
    assert_eq!(
        post_envelope(&base, project, &dsn_key(&dsn), envelope, None)
            .await
            .0,
        StatusCode::OK
    );
    let (status, issues) = api.get(&format!("/api/orgs/{org}/issues")).await;
    assert_eq!(status, StatusCode::OK);
    let issue = issues["issues"][0]["id"].as_i64().unwrap();
    let path = format!("/api/orgs/{org}/issues/{issue}/events/8f4c2a91b703d65e0a9b72ce4681f3d0");
    let (status, body) = api.get(&path).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["payload"]["message"], "near-limit");

    let handle = rt.tenant(&org.parse().unwrap()).await.unwrap();
    let row = handle
        .query_one_raw(sql(
            "SELECT payload_key FROM events WHERE issue_id = ?",
            vec![issue.into()],
        ))
        .await
        .unwrap()
        .unwrap();
    let key: String = row.try_get("", "payload_key").unwrap();
    drop(handle);
    let oversized = serde_json::to_vec(&json!({"message":"x".repeat(maximum - 13)})).unwrap();
    assert_eq!(oversized.len(), maximum + 1);
    let compressed = zstd::stream::encode_all(&oversized[..], 3).unwrap();
    rt.store.put(&key, compressed.clone().into()).await.unwrap();
    let handle = rt.tenant(&org.parse().unwrap()).await.unwrap();
    handle
        .execute_raw(sql(
            "UPDATE events SET payload_bytes = ? WHERE payload_key = ?",
            vec![(compressed.len() as i64).into(), key.into()],
        ))
        .await
        .unwrap();
    drop(handle);
    let (status, body) = api.get(&path).await;
    assert_eq!(status, StatusCode::INTERNAL_SERVER_ERROR);
    assert!(
        body == json!({"error":"internal_error"}),
        "oversized stored payload must fail with the fixed response"
    );
    server.abort();
    TestApp::on_shutdown(&boot.app_context).await;
}
