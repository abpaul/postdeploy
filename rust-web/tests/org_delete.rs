mod support;

use std::{path::PathBuf, sync::atomic::Ordering};

use bytes::Bytes;
use loco_rs::app::Hooks;
use postdeploy::{
    domain::{OrgId, Role},
    identity::{
        access::{authorize, OrgAccess},
        orgs,
    },
    runtime::{sql, Runtime},
    testing::{serve, TestApp, TestEnv},
};
use sea_orm::ConnectionTrait;
use serde_json::{json, Value};
use support::Api;

fn limits(s: &mut Value) {
    s["organization_deletion"] = json!({"page_size": 1, "max_pages": 1, "max_jobs": 2, "interval_secs": 86400, "close_timeout_ms": 50});
}

async fn preserve_tenant(rt: &Runtime, env: &TestEnv, org: &OrgId) -> PathBuf {
    let destination = env.dir.join(format!("preserved-{org}.sqlite"));
    let handle = rt.tenant(org).await.unwrap();
    handle
        .execute_raw(sql(
            "VACUUM INTO ?",
            vec![destination.to_string_lossy().to_string().into()],
        ))
        .await
        .unwrap();
    drop(handle);
    assert!(destination.is_file());
    destination
}

async fn access(rt: &Runtime, org: &str) -> OrgAccess {
    let row = rt
        .control
        .query_one_raw(sql(
            "SELECT created_by FROM organizations WHERE id = ?",
            vec![org.into()],
        ))
        .await
        .unwrap()
        .unwrap();
    let user = postdeploy::domain::UserId(row.try_get("", "created_by").unwrap());
    authorize(rt, user, &org.parse().unwrap()).await.unwrap()
}

async fn remove_local_database(rt: &Runtime) {
    for _ in 0..30 {
        rt.organization_lifecycle.sweep().await.unwrap();
        if rt
            .control
            .query_one_raw(sql(
                "SELECT 1 FROM organizations WHERE lifecycle = 'deleting' LIMIT 1",
                vec![],
            ))
            .await
            .unwrap()
            .is_none()
        {
            return;
        }
    }
    panic!("organization local removal did not finish");
}

#[tokio::test]
async fn owner_confirmation_revokes_access_before_bounded_purge_and_preserves_other_org() {
    let _ = tracing_subscriber::fmt()
        .with_max_level(tracing::Level::ERROR)
        .with_test_writer()
        .try_init();
    let env = TestEnv::new("org-delete-isolation");
    let boot = env.boot_memory(limits).await.unwrap();
    let (base, server) = serve(&boot).await;
    let api = Api::signup(&base, "delete-owner@example.test").await;
    let (org, project, dsn) = api.setup_source("Delete me").await;
    let (other, _, _) = api.setup_source("Keep me").await;
    let rt = Runtime::get(&boot.app_context);
    let billing = postdeploy::services::Services::get(&boot.app_context)
        .billing
        .clone();
    let owner = access(&rt, &org).await;
    let other_id: OrgId = other.parse().unwrap();
    let status = support::post_envelope(
        &base,
        project,
        &support::dsn_key(&dsn),
        support::envelope(Some("00112233445566778899aabbccddeeff"), &[]),
        None,
    )
    .await
    .0;
    assert_eq!(status, reqwest::StatusCode::OK);
    let snapshot = preserve_tenant(&rt, &env, &owner.org).await;
    let key = format!("reports/v1/{org}/report.json");
    let other_key = format!("reports/v1/{other}/report.json");
    env.store
        .put(&key, Bytes::from_static(b"private deleted report"))
        .await
        .unwrap();
    env.store
        .put(&other_key, Bytes::from_static(b"retained report"))
        .await
        .unwrap();
    assert!(matches!(
        rt.organization_lifecycle
            .request(&rt, &billing, &owner, "wrong")
            .await,
        Err(postdeploy::error::ApiError::BadRequest(_))
    ));
    let stranger = Api::signup(&base, "delete-member@example.test").await;
    assert_eq!(
        api.post(
            &format!("/api/orgs/{org}/members"),
            json!({"email":"delete-member@example.test", "role":"member"})
        )
        .await
        .0,
        reqwest::StatusCode::CREATED
    );
    let stranger_user = rt
        .control
        .query_one_raw(sql(
            "SELECT id FROM users WHERE email = ?",
            vec!["delete-member@example.test".into()],
        ))
        .await
        .unwrap()
        .unwrap();
    let forged = OrgAccess {
        user: postdeploy::domain::UserId(stranger_user.try_get("", "id").unwrap()),
        org: owner.org.clone(),
        role: Role::Owner,
    };
    assert!(matches!(
        rt.organization_lifecycle
            .request(&rt, &billing, &forged, "Delete me")
            .await,
        Err(postdeploy::error::ApiError::Forbidden)
    ));
    assert_eq!(
        stranger.get(&format!("/api/orgs/{org}/projects")).await.0,
        reqwest::StatusCode::OK
    );
    let browser = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .unwrap();
    let delete_url = format!("{base}/dashboard/orgs/{org}/delete");
    let settings_response = browser
        .get(format!("{base}/dashboard/orgs/{org}/settings"))
        .header("cookie", api.cookie.as_deref().unwrap())
        .send()
        .await
        .unwrap();
    assert_eq!(settings_response.status(), reqwest::StatusCode::OK);
    let settings = settings_response.text().await.unwrap();
    assert!(
        settings.contains(&format!("action=\"/dashboard/orgs/{org}/delete\"")),
        "danger zone={}, rendered form actions={:?}",
        settings.contains("org-danger-zone"),
        settings
            .split("action=\"")
            .skip(1)
            .filter_map(|part| part.split('"').next())
            .collect::<Vec<_>>()
    );
    assert!(settings.contains("name=\"confirmed_name\""));
    assert!(settings.contains("Confirm delete"));
    let missing_csrf = browser
        .post(&delete_url)
        .header("cookie", api.cookie.as_deref().unwrap())
        .header("origin", "http://127.0.0.1:5167")
        .form(&[("confirmed_name", "Delete me")])
        .send()
        .await
        .unwrap();
    assert_eq!(missing_csrf.status(), reqwest::StatusCode::FORBIDDEN);
    let mismatch = browser
        .post(&delete_url)
        .header("cookie", api.cookie.as_deref().unwrap())
        .header("origin", "http://127.0.0.1:5167")
        .form(&[
            ("confirmed_name", "wrong"),
            ("_csrf_token", api.csrf.as_deref().unwrap()),
        ])
        .send()
        .await
        .unwrap();
    assert_eq!(mismatch.status(), reqwest::StatusCode::UNPROCESSABLE_ENTITY);
    assert!(mismatch
        .text()
        .await
        .unwrap()
        .contains("Enter the organization name exactly as shown."));
    assert!(authorize(&rt, owner.user, &owner.org).await.is_ok());
    let member_attempt = browser
        .post(&delete_url)
        .header("cookie", stranger.cookie.as_deref().unwrap())
        .header("origin", "http://127.0.0.1:5167")
        .form(&[
            ("confirmed_name", "Delete me"),
            ("_csrf_token", stranger.csrf.as_deref().unwrap()),
        ])
        .send()
        .await
        .unwrap();
    assert_eq!(member_attempt.status(), reqwest::StatusCode::FORBIDDEN);
    let deleted = browser
        .post(&delete_url)
        .header("cookie", api.cookie.as_deref().unwrap())
        .header("origin", "http://127.0.0.1:5167")
        .form(&[
            ("confirmed_name", "Delete me"),
            ("_csrf_token", api.csrf.as_deref().unwrap()),
        ])
        .send()
        .await
        .unwrap();
    assert_eq!(deleted.status(), reqwest::StatusCode::SEE_OTHER);
    assert!(authorize(&rt, owner.user, &owner.org).await.is_err());
    assert_eq!(
        orgs::list(&rt, owner.user)
            .await
            .unwrap()
            .iter()
            .map(|org| org.name.as_str())
            .collect::<Vec<_>>(),
        vec!["Keep me"]
    );
    assert_eq!(
        stranger.get(&format!("/api/orgs/{org}/projects")).await.0,
        reqwest::StatusCode::NOT_FOUND
    );
    assert!(
        postdeploy::ingest::resolve_grant(&rt, &support::dsn_key(&dsn))
            .await
            .is_err()
    );
    assert!(rt.tenant(&owner.org).await.is_err());
    assert!(env
        .store
        .put(&key, Bytes::from_static(b"late writer"))
        .await
        .is_err());
    assert_eq!(
        rt.organization_lifecycle
            .sweep()
            .await
            .unwrap()
            .local_removed,
        0
    );
    remove_local_database(&rt).await;
    assert!(env
        .store
        .list_page(&format!("reports/v1/{org}/"), None, 10)
        .await
        .unwrap()
        .keys
        .is_empty());
    assert_eq!(
        env.store.get(&other_key, 100).await.unwrap().unwrap(),
        Bytes::from_static(b"retained report")
    );
    assert!(rt.tenant(&other_id).await.is_ok());
    assert!(!env.tenant_root().join(format!("{org}.db")).exists());
    assert!(snapshot.is_file());
    let evidence = sea_orm::Database::connect(format!("sqlite://{}?mode=ro", snapshot.display()))
        .await
        .unwrap();
    let row = evidence
        .query_one_raw(sql("SELECT COUNT(*) AS n FROM events", vec![]))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(row.try_get::<i64>("", "n").unwrap(), 1);
    evidence.close().await.unwrap();
    assert_eq!(env.store.counters().gets.load(Ordering::Relaxed), 1);
    server.abort();
    TestApp::on_shutdown(&boot.app_context).await;
}

#[tokio::test]
async fn failed_r2_delete_preserves_job_and_restart_resumes_cursor() {
    let env = TestEnv::new("org-delete-resume");
    let boot = env.boot_memory(limits).await.unwrap();
    let (base, server) = serve(&boot).await;
    let api = Api::signup(&base, "delete-restart@example.test").await;
    let (org, _, _) = api.setup_source("Resumable").await;
    let rt = Runtime::get(&boot.app_context);
    let billing = postdeploy::services::Services::get(&boot.app_context)
        .billing
        .clone();
    let owner = access(&rt, &org).await;
    let snapshot = preserve_tenant(&rt, &env, &owner.org).await;
    for family in [
        "logs/v1",
        "errors/v1",
        "releases/v1",
        "reports/v1",
        "backups/org",
    ] {
        for number in 0..3 {
            env.store
                .put(
                    &format!("{family}/{org}/{number}"),
                    Bytes::from_static(b"test object"),
                )
                .await
                .unwrap();
        }
    }
    rt.organization_lifecycle
        .request(&rt, &billing, &owner, "Resumable")
        .await
        .unwrap();
    env.faults.fail_deletes.store(1, Ordering::SeqCst);
    assert_eq!(rt.organization_lifecycle.sweep().await.unwrap().deferred, 1);
    assert!(env.tenant_root().join(format!("{org}.db")).is_file());
    let row = rt
        .control
        .query_one_raw(sql(
            "SELECT phase, after_key FROM organization_deletions WHERE org_id = ?",
            vec![org.clone().into()],
        ))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(row.try_get::<i64>("", "phase").unwrap(), 0);
    assert_eq!(
        row.try_get::<Option<String>>("", "after_key").unwrap(),
        None
    );
    assert_eq!(rt.organization_lifecycle.sweep().await.unwrap().deleted, 1);
    let row = rt
        .control
        .query_one_raw(sql(
            "SELECT phase, after_key FROM organization_deletions WHERE org_id = ?",
            vec![org.clone().into()],
        ))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        row.try_get::<Option<String>>("", "after_key").unwrap(),
        Some(format!("logs/v1/{org}/0"))
    );
    server.abort();
    TestApp::on_shutdown(&boot.app_context).await;
    let restarted = env.boot_memory(limits).await.unwrap();
    let rt = Runtime::get(&restarted.app_context);
    remove_local_database(&rt).await;
    for family in [
        "logs/v1",
        "errors/v1",
        "releases/v1",
        "reports/v1",
        "backups/org",
    ] {
        assert!(env
            .store
            .list_page(&format!("{family}/{org}/"), None, 10)
            .await
            .unwrap()
            .keys
            .is_empty());
    }
    assert!(rt
        .control
        .query_one_raw(sql(
            "SELECT id FROM organizations WHERE id = ?",
            vec![org.clone().into()]
        ))
        .await
        .unwrap()
        .is_none());
    assert_eq!(env.store.counters().gets.load(Ordering::Relaxed), 0);
    assert!(snapshot.is_file());
    TestApp::on_shutdown(&restarted.app_context).await;
    let late_keys = [
        format!("logs/v1/{org}/late-commit"),
        format!("backups/org/{org}/late-backup"),
    ];
    for key in &late_keys {
        env.store
            .put(key, Bytes::from_static(b"late remote commit fixture"))
            .await
            .unwrap();
    }
    let late_restart = env.boot_memory(limits).await.unwrap();
    let rt = Runtime::get(&late_restart.app_context);
    assert_eq!(rt.tenants.registry().stats().await.retained_pools, 0);
    for _ in 0..12 {
        rt.organization_lifecycle.sweep().await.unwrap();
    }
    for key in &late_keys {
        assert!(env.store.get(key, 100).await.unwrap().is_none());
    }
    assert_eq!(rt.tenants.registry().stats().await.retained_pools, 0);
    assert!(rt.tenant(&org.parse().unwrap()).await.is_err());
    let tombstone = rt
        .control
        .query_one_raw(sql(
            "SELECT local_removed FROM organization_deletions WHERE org_id = ?",
            vec![org.clone().into()],
        ))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(tombstone.try_get::<i64>("", "local_removed").unwrap(), 1);
    assert!(!env.tenant_root().join(format!("{org}.db")).exists());
    assert!(snapshot.is_file());
    TestApp::on_shutdown(&late_restart.app_context).await;
}

#[tokio::test]
async fn registry_waits_for_owned_lease_and_releases_capacity_after_retry() {
    let env = TestEnv::new("org-delete-registry-drain");
    let boot = env
        .boot_memory(|s| {
            limits(s);
            s["tenants"]["max_pools"] = json!(2);
        })
        .await
        .unwrap();
    let (base, server) = serve(&boot).await;
    let api = Api::signup(&base, "delete-drain@example.test").await;
    let (org, _, _) = api.setup_source("Drain me").await;
    let (other, _, _) = api.setup_source("Still here").await;
    let rt = Runtime::get(&boot.app_context);
    let billing = postdeploy::services::Services::get(&boot.app_context)
        .billing
        .clone();
    let owner = access(&rt, &org).await;
    let snapshot = preserve_tenant(&rt, &env, &owner.org).await;
    let handle = rt.tenant(&owner.org).await.unwrap();
    rt.organization_lifecycle
        .request(&rt, &billing, &owner, "Drain me")
        .await
        .unwrap();
    let stale_insert = rt
        .control
        .execute_raw(sql(
            "INSERT INTO projects (org_id, name, created_at) VALUES (?, 'stale', 0)",
            vec![org.clone().into()],
        ))
        .await;
    assert!(stale_insert.is_err());
    for _ in 0..5 {
        assert_eq!(
            rt.organization_lifecycle
                .sweep()
                .await
                .unwrap()
                .local_removed,
            0
        );
    }
    let deferred = rt.organization_lifecycle.sweep().await.unwrap();
    assert_eq!(deferred.deferred, 1);
    assert_eq!(deferred.local_removed, 0);
    assert!(env.tenant_root().join(format!("{org}.db")).is_file());
    let unrelated = tokio::time::timeout(
        std::time::Duration::from_millis(250),
        rt.tenant(&other.parse().unwrap()),
    )
    .await
    .unwrap()
    .unwrap();
    drop(unrelated);
    drop(handle);
    remove_local_database(&rt).await;
    assert!(rt.tenant(&other.parse().unwrap()).await.is_ok());
    assert_eq!(rt.tenants.registry().stats().await.retained_pools, 1);
    assert!(snapshot.is_file());
    server.abort();
    TestApp::on_shutdown(&boot.app_context).await;
}
