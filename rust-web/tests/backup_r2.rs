mod support;

use std::{path::PathBuf, time::Duration};

use postdeploy::{
    credentials::Credentials,
    runtime::Runtime,
    store::ObjectStore,
    testing::{serve, TestEnv},
};
use reqwest::StatusCode;
use sea_orm::{ConnectionTrait, DbBackend, Statement};
use serde_json::json;
use support::*;

const TEST_BUCKET: &str = "postdeploy-rust-local-test-20261015";

fn test_credentials() -> Credentials {
    let credentials = Credentials::load(
        &PathBuf::from(std::env::var_os("POSTDEPLOY_CREDENTIALS_FILE").unwrap()),
        "test",
    )
    .unwrap();
    assert_eq!(credentials.r2.bucket, TEST_BUCKET);
    credentials
}

/// Gate 5 runs this before any write. It reads the credentials and writes nothing.
#[test]
#[ignore = "requires isolated R2 credentials"]
fn real_r2_credentials_name_the_test_bucket() {
    assert_eq!(test_credentials().r2.bucket, TEST_BUCKET);
}

async fn delete_prefix(credentials: &Credentials, prefix: &str) -> usize {
    let store = ObjectStore::r2(&credentials.r2, prefix, Duration::from_secs(30)).unwrap();
    let mut deleted = 0;
    loop {
        let page = store.list_page("", None, 1_000).await.unwrap();
        if page.keys.is_empty() {
            return deleted;
        }
        for key in &page.keys {
            store.delete(key).await.unwrap();
            deleted += 1;
        }
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "requires isolated R2 credentials"]
async fn real_r2_backup_set_restores_through_the_isolated_bucket() {
    let credentials = test_credentials();
    let id = uuid::Uuid::now_v7().simple().to_string();
    let prefix = format!("local-verification/backup-sets-{id}/");
    let name = format!("backup-r2-{id}");
    let env = TestEnv::new(&name);
    let boot = env
        .boot_r2(&prefix, |settings| {
            settings["backup"] = json!({"initial_delay_secs": 86_400});
        })
        .await
        .unwrap();
    let (base, server) = serve(&boot).await;
    let rt = Runtime::get(&boot.app_context);
    let api = Api::signup(&base, &format!("{name}@example.invalid")).await;
    let (org, project, dsn) = api.setup_source(&name).await;
    let (status, _) = post_envelope(
        &base,
        project,
        &dsn_key(&dsn),
        envelope(Some("50000000000000000000000000000001"), &["r2-set-log"]),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let manifest = run_backup(&boot).await;
    let destination = env.dir.join("restored");
    let report = restore_set(&boot, manifest.set, &destination).await;
    let restored = sea_orm::Database::connect(format!(
        "sqlite://{}?mode=ro",
        report.organizations[0].path.display()
    ))
    .await
    .unwrap();
    let row = restored
        .query_one_raw(Statement::from_string(
            DbBackend::Sqlite,
            "SELECT title FROM issues",
        ))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(row.try_get::<String>("", "title").unwrap(), "Boom: kaput");
    restored.close().await.unwrap();
    rt.shutdown().await;
    server.abort();
    let deleted = delete_prefix(&credentials, &prefix).await;
    println!(
        "R2 backup set restored: set={} org={org} raw_bytes={} sealed_bytes={} deleted_objects={deleted}",
        manifest.set,
        manifest.raw_bytes(),
        manifest.sealed_bytes()
    );
}

/// Deletes the task-owned prefix of a gate 5 run. Refuses any other prefix.
#[tokio::test]
#[ignore = "requires isolated R2 credentials and POSTDEPLOY_R2_OWNED_PREFIX"]
async fn real_r2_owned_verification_prefix_is_deleted() {
    let prefix = std::env::var("POSTDEPLOY_R2_OWNED_PREFIX").unwrap();
    assert!(
        prefix.starts_with("local-verification/backup-gate5-")
            && prefix.ends_with('/')
            && !prefix.contains(".."),
        "refusing prefix {prefix}"
    );
    let credentials = test_credentials();
    let deleted = delete_prefix(&credentials, &prefix).await;
    let store = ObjectStore::r2(&credentials.r2, &prefix, Duration::from_secs(30)).unwrap();
    assert!(store.list_page("", None, 1).await.unwrap().keys.is_empty());
    println!("owned prefix {prefix} deleted_objects={deleted} remaining=0");
}
