mod support;

use bytes::Bytes;
use loco_rs::app::Hooks;
use postdeploy::{
    domain::{OrgId, UserId},
    error::ApiError,
    identity::access::{authorize, OrgAccess},
    runtime::{sql, Runtime},
    store::StoreError,
    testing::{serve, TestApp, TestEnv},
};
use reqwest::StatusCode;
use sea_orm::ConnectionTrait;
use support::{dsn_key, envelope, post_envelope, Api};

async fn owner(rt: &Runtime, org: &str) -> OrgAccess {
    let row = rt
        .control
        .query_one_raw(sql(
            "SELECT created_by FROM organizations WHERE id = ?",
            vec![org.into()],
        ))
        .await
        .unwrap()
        .unwrap();
    authorize(
        rt,
        UserId(row.try_get("", "created_by").unwrap()),
        &org.parse().unwrap(),
    )
    .await
    .unwrap()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn full_write_barrier_capacity_preserves_active_organization_and_ingestion() {
    let env = TestEnv::new("delete-barrier-capacity");
    let boot = env
        .boot_memory(|s| s["logs"]["batch_max_entries"] = serde_json::json!(1))
        .await
        .unwrap();
    let (base, server) = serve(&boot).await;
    let api = Api::signup(&base, "barrier-capacity@example.test").await;
    let (org, project, dsn) = api.setup_source("Keep active").await;
    let rt = Runtime::get(&boot.app_context);
    let billing = postdeploy::services::Services::get(&boot.app_context)
        .billing
        .clone();
    rt.cancel.cancel();
    let access = owner(&rt, &org).await;
    let first_barrier = OrgId::generate();
    rt.store.block_org_writes(&first_barrier).unwrap();
    for _ in 1..16_384 {
        rt.store.block_org_writes(&OrgId::generate()).unwrap();
    }
    assert!(matches!(
        rt.organization_lifecycle
            .request(&rt, &billing, &access, "wrong name")
            .await,
        Err(ApiError::BadRequest("organization_name_confirmation"))
    ));
    let browser = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .unwrap();
    let response = browser
        .post(format!("{base}/dashboard/orgs/{org}/delete"))
        .header("cookie", api.cookie.as_deref().unwrap())
        .header("origin", "http://127.0.0.1:5167")
        .form(&[
            ("confirmed_name", "Keep active"),
            ("_csrf_token", api.csrf.as_deref().unwrap()),
        ])
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert!(authorize(&rt, access.user, &access.org).await.is_ok());
    assert_eq!(
        api.get(&format!("/api/orgs/{org}/projects")).await.0,
        StatusCode::OK
    );
    assert_eq!(
        post_envelope(
            &base,
            project,
            &dsn_key(&dsn),
            envelope(
                Some("11223344556677889900aabbccddeeff"),
                &["barriercapacitystillactive"]
            ),
            None,
        )
        .await,
        (
            StatusCode::OK,
            support::accepted(Some("11223344556677889900aabbccddeeff"), 1, 1)
        )
    );
    let row = rt.control.query_one_raw(sql("SELECT lifecycle, (SELECT COUNT(*) FROM organization_deletions WHERE org_id = ?) AS jobs FROM organizations WHERE id = ?", vec![org.clone().into(), org.clone().into()])).await.unwrap().unwrap();
    assert_eq!(row.try_get::<String>("", "lifecycle").unwrap(), "active");
    assert_eq!(row.try_get::<i64>("", "jobs").unwrap(), 0);
    rt.store.release_org_write_barrier(&first_barrier);
    let response = browser
        .post(format!("{base}/dashboard/orgs/{org}/delete"))
        .header("cookie", api.cookie.as_deref().unwrap())
        .header("origin", "http://127.0.0.1:5167")
        .form(&[
            ("confirmed_name", "Keep active"),
            ("_csrf_token", api.csrf.as_deref().unwrap()),
        ])
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::SEE_OTHER);
    assert!(matches!(
        authorize(&rt, access.user, &access.org).await,
        Err(ApiError::NotFound)
    ));
    assert!(matches!(
        rt.store
            .put(
                &format!("reports/v1/{org}/late.json"),
                Bytes::from_static(b"late writer")
            )
            .await,
        Err(StoreError::OrganizationDeleting)
    ));
    TestApp::on_shutdown(&boot.app_context).await;
    server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn failed_delete_releases_only_its_reservation_and_concurrent_retry_keeps_the_barrier() {
    let env = TestEnv::new("delete-barrier-rollback");
    let boot = env.boot_memory(|_| {}).await.unwrap();
    let (base, server) = serve(&boot).await;
    let api = Api::signup(&base, "barrier-rollback@example.test").await;
    let (org, _, _) = api.setup_source("Retry delete").await;
    let rt = Runtime::get(&boot.app_context);
    let billing = postdeploy::services::Services::get(&boot.app_context)
        .billing
        .clone();
    rt.cancel.cancel();
    let access = owner(&rt, &org).await;
    rt.control.execute_raw(sql("CREATE TRIGGER reject_deletion BEFORE DELETE ON projects BEGIN SELECT RAISE(ABORT, 'fixture deletion failure'); END", vec![])).await.unwrap();
    assert!(matches!(
        rt.organization_lifecycle
            .request(&rt, &billing, &access, "Retry delete")
            .await,
        Err(ApiError::Internal(_))
    ));
    assert!(authorize(&rt, access.user, &access.org).await.is_ok());
    let key = format!("reports/v1/{org}/fixture.json");
    rt.store
        .put(&key, Bytes::from_static(b"after rollback"))
        .await
        .unwrap();
    rt.control
        .execute_raw(sql("DROP TRIGGER reject_deletion", vec![]))
        .await
        .unwrap();
    let (first, second) = tokio::join!(
        rt.organization_lifecycle
            .request(&rt, &billing, &access, "Retry delete"),
        rt.organization_lifecycle
            .request(&rt, &billing, &access, "Retry delete")
    );
    assert!(matches!(
        (&first, &second),
        (Ok(()), Err(ApiError::NotFound)) | (Err(ApiError::NotFound), Ok(()))
    ));
    assert!(matches!(
        rt.store
            .put(&key, Bytes::from_static(b"after commit"))
            .await,
        Err(StoreError::OrganizationDeleting)
    ));
    let reservation = rt.store.reserve_org_write_barrier(&access.org).unwrap();
    drop(reservation);
    assert!(matches!(
        rt.store
            .put(&key, Bytes::from_static(b"after duplicate reservation"))
            .await,
        Err(StoreError::OrganizationDeleting)
    ));
    let row = rt
        .control
        .query_one_raw(sql(
            "SELECT COUNT(*) AS jobs FROM organization_deletions WHERE org_id = ?",
            vec![org.into()],
        ))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(row.try_get::<i64>("", "jobs").unwrap(), 1);
    TestApp::on_shutdown(&boot.app_context).await;
    server.abort();
}
