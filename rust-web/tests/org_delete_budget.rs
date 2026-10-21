mod support;

use loco_rs::app::Hooks;
use postdeploy::{
    domain::OrgId,
    identity::access::authorize,
    runtime::{sql, Runtime},
    testing::{serve, TestApp, TestEnv},
};
use sea_orm::ConnectionTrait;
use serde_json::{json, Value};
use support::Api;

fn limits(s: &mut Value) {
    s["organization_deletion"] = json!({
        "page_size": 1, "max_pages": 6, "max_jobs": 2, "interval_secs": 86400,
        "close_timeout_ms": 50, "max_local_deletions_per_process": 1,
    });
}

#[tokio::test]
async fn local_delete_budget_defers_second_org_until_restart_and_preserves_snapshots() {
    let env = TestEnv::new("org-delete-process-budget");
    let boot = env.boot_memory(limits).await.unwrap();
    let (base, server) = serve(&boot).await;
    let api = Api::signup(&base, "delete-budget@example.test").await;
    let (first, _, _) = api.setup_source("First deletion").await;
    let (second, _, _) = api.setup_source("Second deletion").await;
    let rt = Runtime::get(&boot.app_context);
    let billing = postdeploy::services::Services::get(&boot.app_context)
        .billing
        .clone();
    let mut snapshots = Vec::new();
    for raw in [&first, &second] {
        let org: OrgId = raw.parse().unwrap();
        let snapshot = env.dir.join(format!("preserved-{org}.sqlite"));
        let handle = rt.tenant(&org).await.unwrap();
        handle
            .execute_raw(sql(
                "VACUUM INTO ?",
                vec![snapshot.to_string_lossy().to_string().into()],
            ))
            .await
            .unwrap();
        drop(handle);
        snapshots.push(snapshot);
    }
    for (raw, name) in [(&first, "First deletion"), (&second, "Second deletion")] {
        let org: OrgId = raw.parse().unwrap();
        let row = rt
            .control
            .query_one_raw(sql(
                "SELECT created_by FROM organizations WHERE id = ?",
                vec![raw.as_str().into()],
            ))
            .await
            .unwrap()
            .unwrap();
        let user = postdeploy::domain::UserId(row.try_get("", "created_by").unwrap());
        let owner = authorize(&rt, user, &org).await.unwrap();
        rt.organization_lifecycle
            .request(&rt, &billing, &owner, name)
            .await
            .unwrap();
    }
    let report = rt.organization_lifecycle.sweep().await.unwrap();
    assert_eq!(report.local_removed, 1);
    assert_eq!(report.deferred, 1);
    let row = rt
        .control
        .query_one_raw(sql(
            "SELECT COUNT(*) AS n FROM organizations WHERE lifecycle = 'deleting'",
            vec![],
        ))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(row.try_get::<i64>("", "n").unwrap(), 1);
    let report = rt.organization_lifecycle.sweep().await.unwrap();
    assert_eq!(report.local_removed, 0);
    assert_eq!(report.deferred, 1);
    assert!(snapshots.iter().all(|path| path.is_file()));
    server.abort();
    TestApp::on_shutdown(&boot.app_context).await;
    let restarted = env.boot_memory(limits).await.unwrap();
    let rt = Runtime::get(&restarted.app_context);
    assert_eq!(
        rt.organization_lifecycle
            .sweep()
            .await
            .unwrap()
            .local_removed,
        1
    );
    for raw in [first, second] {
        assert!(!env.tenant_root().join(format!("{raw}.db")).exists());
        assert!(rt
            .control
            .query_one_raw(sql(
                "SELECT id FROM organizations WHERE id = ?",
                vec![raw.into()]
            ))
            .await
            .unwrap()
            .is_none());
    }
    assert!(snapshots.iter().all(|path| path.is_file()));
    TestApp::on_shutdown(&restarted.app_context).await;
}
