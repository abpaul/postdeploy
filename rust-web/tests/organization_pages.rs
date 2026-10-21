mod support;

use loco_rs::app::Hooks;
use postdeploy::{
    domain::OrgId,
    identity::orgs,
    runtime::{sql, Runtime},
    testing::{serve, TestApp, TestEnv},
};
use reqwest::StatusCode;
use sea_orm::ConnectionTrait;
use serde_json::json;
use support::Api;

#[tokio::test]
async fn organization_pages_are_ordered_bounded_and_exclude_deleting() {
    let env = TestEnv::new("organization-pages");
    let boot = env.boot_memory(|_| {}).await.unwrap();
    let (base, server) = serve(&boot).await;
    let api = Api::signup(&base, "pages@example.test").await;
    let rt = Runtime::get(&boot.app_context);
    rt.cancel.cancel();
    let mut ids = Vec::new();
    for name in ["First", "Second", "Third", "Deleting"] {
        let (status, org) = api.post("/api/orgs", json!({"name": name})).await;
        assert_eq!(status, StatusCode::CREATED);
        ids.push(org["id"].as_str().unwrap().parse::<OrgId>().unwrap());
    }
    let deleting = ids.pop().unwrap();
    rt.control
        .execute_raw(sql(
            "UPDATE organizations SET lifecycle = 'deleting' WHERE id = ?",
            vec![deleting.as_str().into()],
        ))
        .await
        .unwrap();
    ids.sort_by(|a, b| a.as_str().cmp(b.as_str()));
    let first = orgs::page_ids(&rt, None, 2).await.unwrap();
    assert_eq!(first, ids[..2]);
    let second = orgs::page_ids(&rt, first.last(), 2).await.unwrap();
    assert_eq!(second, ids[2..]);
    assert!(orgs::page_ids(&rt, second.last(), 2)
        .await
        .unwrap()
        .is_empty());
    assert_eq!(orgs::page_ids(&rt, None, 0).await.unwrap(), ids[..1]);
    server.abort();
    TestApp::on_shutdown(&boot.app_context).await;
}

#[tokio::test]
async fn one_account_creates_at_most_five_organizations() {
    let env = TestEnv::new("organization-create-limit");
    let boot = env.boot_memory(|_| {}).await.unwrap();
    let (base, server) = serve(&boot).await;
    let api = Api::signup(&base, "limit@example.test").await;
    for n in 1..=5 {
        let (status, _) = api
            .post("/api/orgs", json!({"name": format!("Org {n}")}))
            .await;
        assert_eq!(status, StatusCode::CREATED, "organization {n}");
    }
    let (status, body) = api.post("/api/orgs", json!({"name": "Org 6"})).await;
    assert_eq!(
        (status, body),
        (StatusCode::CONFLICT, json!({"error": "organization_limit"}))
    );
    let (_, listed) = api.get("/api/orgs").await;
    assert_eq!(listed["orgs"].as_array().unwrap().len(), 5);
    let tenants = std::fs::read_dir(env.tenant_root())
        .unwrap()
        .filter(|entry| {
            entry
                .as_ref()
                .unwrap()
                .path()
                .extension()
                .is_some_and(|ext| ext == "db")
        })
        .count();
    assert_eq!(tenants, 5);
    let other = Api::signup(&base, "other@example.test").await;
    let (status, _) = other.post("/api/orgs", json!({"name": "Other"})).await;
    assert_eq!(status, StatusCode::CREATED);
    server.abort();
    TestApp::on_shutdown(&boot.app_context).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn concurrent_creates_stop_at_the_organization_limit() {
    let env = TestEnv::new("organization-create-race");
    let boot = env.boot_memory(|_| {}).await.unwrap();
    let (base, server) = serve(&boot).await;
    let api = Api::signup(&base, "race@example.test").await;
    for n in 1..=4 {
        let (status, _) = api
            .post("/api/orgs", json!({"name": format!("Org {n}")}))
            .await;
        assert_eq!(status, StatusCode::CREATED, "organization {n}");
    }
    let attempts = (0..6).map(|n| {
        let api = api.clone();
        tokio::spawn(async move {
            api.post("/api/orgs", json!({"name": format!("Race {n}")}))
                .await
                .0
        })
    });
    let mut statuses: Vec<u16> = futures::future::join_all(attempts)
        .await
        .into_iter()
        .map(|status| status.unwrap().as_u16())
        .collect();
    statuses.sort_unstable();
    assert_eq!(statuses, [201, 409, 409, 409, 409, 409]);
    let (_, listed) = api.get("/api/orgs").await;
    assert_eq!(listed["orgs"].as_array().unwrap().len(), 5);
    server.abort();
    TestApp::on_shutdown(&boot.app_context).await;
}
