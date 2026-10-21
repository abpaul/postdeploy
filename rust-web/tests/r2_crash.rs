mod support;

use std::{
    path::{Path, PathBuf},
    process::{Child, Command},
    time::{Duration, Instant},
};

use loco_rs::app::Hooks;
use postdeploy::{
    app::App,
    credentials::Credentials,
    domain::OrgId,
    runtime::{sql, Runtime},
    testing::{serve, TestEnv},
};
use reqwest::StatusCode;
use sea_orm::ConnectionTrait;
use sha2::{Digest, Sha256};
use support::*;
use zeroize::Zeroizing;

const CHILD_NAME: &str = "POSTDEPLOY_R2_CRASH_CHILD";
const CHILD_READY: &str = "POSTDEPLOY_R2_CRASH_READY";
const BODY: &str = "r2-crash-body-8b210dc5290e492a86cc405a8b6c65fd-archived-before-commit";
const EMAIL: &str = "r2-crash@example.test";

fn password(name: &str) -> Zeroizing<String> {
    let path = PathBuf::from(std::env::var_os("POSTDEPLOY_CREDENTIALS_FILE").unwrap());
    let credentials = Credentials::load(&path, "test").unwrap();
    assert_eq!(credentials.r2.bucket, "postdeploy-rust-local-test-20261015");
    let mut hash = Sha256::new();
    hash.update(b"postdeploy-isolated-r2-crash-password");
    hash.update(credentials.security.data_key.expose_secret().as_bytes());
    hash.update(name.as_bytes());
    Zeroizing::new(format!("R2Crash!{:x}", hash.finalize()))
}

fn prefix(name: &str) -> String {
    format!("local-verification/r2-crash-{name}/")
}

fn fast_archive(settings: &mut serde_json::Value) {
    settings["logs"]["batch_max_age_ms"] = serde_json::json!(200);
    settings["logs"]["archive_tick_ms"] = serde_json::json!(50);
}

async fn org_counts(rt: &Runtime, org: &OrgId) -> (String, i64, i64, i64) {
    let tenant = rt.tenant(org).await.unwrap();
    let row = tenant.query_one_raw(sql("SELECT (SELECT GROUP_CONCAT(state) FROM log_objects) AS states, (SELECT COUNT(*) FROM log_objects) AS objects, (SELECT COUNT(*) FROM log_entries_pending) AS pending, (SELECT COALESCE(SUM(accepted),0) FROM usage_daily WHERE category='log') AS accepted", vec![])).await.unwrap().unwrap();
    (
        row.try_get::<Option<String>>("", "states")
            .unwrap()
            .unwrap_or_default(),
        row.try_get("", "objects").unwrap(),
        row.try_get("", "pending").unwrap(),
        row.try_get("", "accepted").unwrap(),
    )
}

struct OwnedChild(Child);

impl Drop for OwnedChild {
    fn drop(&mut self) {
        if self.0.try_wait().ok().flatten().is_none() {
            let _ = self.0.kill();
        }
        let _ = self.0.wait();
    }
}

fn assert_body_absent(root: &Path) {
    let mut pending = vec![root.to_owned()];
    while let Some(dir) = pending.pop() {
        for entry in std::fs::read_dir(dir).unwrap() {
            let entry = entry.unwrap();
            let kind = entry.file_type().unwrap();
            if kind.is_dir() {
                pending.push(entry.path());
            } else if kind.is_file() {
                let bytes = std::fs::read(entry.path()).unwrap();
                assert!(
                    !bytes
                        .windows(BODY.len())
                        .any(|part| part == BODY.as_bytes()),
                    "log body persisted in {}",
                    entry.path().display()
                );
            }
        }
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "internal actual-R2 crash child; launched by the parent crash test"]
async fn r2_archive_crash_child() {
    let name = std::env::var(CHILD_NAME).expect("parent crash test supplies child identity");
    let ready = PathBuf::from(std::env::var_os(CHILD_READY).unwrap());
    let password = password(&name);
    let env = TestEnv::new(&name);
    let boot = env.boot_r2(&prefix(&name), fast_archive).await.unwrap();
    let (base, _server) = serve(&boot).await;
    let api = Api::signup_with_password(&base, EMAIL, password.as_str()).await;
    let (org, project, dsn) = api.setup_source("R2 crash").await;
    let org_id: OrgId = org.parse().unwrap();
    let rt = Runtime::get(&boot.app_context);
    let tenant = rt.tenant(&org_id).await.unwrap();
    tenant.execute_raw(sql("CREATE TRIGGER crash_archive_commit BEFORE UPDATE OF state ON log_objects WHEN NEW.state = 'archived' BEGIN SELECT RAISE(ABORT, 'isolated crash archive commit failure'); END", vec![])).await.unwrap();
    drop(tenant);
    let (status, _) = post_envelope(
        &base,
        project,
        &dsn_key(&dsn),
        envelope(None, &[BODY]),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "acknowledged from SQLite");
    eventually(Duration::from_secs(60), || {
        let rt = rt.clone();
        async move {
            rt.store
                .list_page("logs/", None, 2)
                .await
                .unwrap()
                .keys
                .len()
                == 1
        }
    })
    .await;
    assert_eq!(
        org_counts(&rt, &org_id).await,
        ("sealed".to_owned(), 1, 1, 1),
        "the object exists in actual R2 while SQLite still holds the sealed batch"
    );
    let temporary = ready.with_extension("tmp");
    std::fs::write(&temporary, org).unwrap();
    std::fs::rename(temporary, ready).unwrap();
    std::future::pending::<()>().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "actual R2 process crash: needs CREDSEAL_KEY_FILE and POSTDEPLOY_CREDENTIALS_FILE"]
async fn real_r2_crash_after_archive_put_converges_without_overwrite() {
    let name = format!("crash-{}", uuid::Uuid::now_v7().simple());
    let password = password(&name);
    let env = TestEnv::new(&name);
    let ready = env.dir.join("child.ready");
    let log = std::fs::File::create(env.dir.join("child.log")).unwrap();
    let run = env.dir.parent().unwrap();
    let mut child = OwnedChild(
        Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "r2_archive_crash_child",
                "--ignored",
                "--nocapture",
                "--test-threads=1",
            ])
            .env(CHILD_NAME, &name)
            .env(CHILD_READY, &ready)
            .env("POSTDEPLOY_TEST_ROOT", run.parent().unwrap())
            .env("POSTDEPLOY_TEST_RUN", run.file_name().unwrap())
            .env_remove("CREDSEAL_MASTER_KEY")
            .env(
                "CREDSEAL_KEY_FILE",
                std::env::var_os("CREDSEAL_KEY_FILE").unwrap(),
            )
            .stdout(log.try_clone().unwrap())
            .stderr(log)
            .spawn()
            .unwrap(),
    );
    let deadline = Instant::now() + Duration::from_secs(120);
    while !ready.exists() {
        assert!(
            child.0.try_wait().unwrap().is_none(),
            "child exited before its archive checkpoint; see child.log"
        );
        assert!(
            Instant::now() < deadline,
            "child archive checkpoint timed out; see child.log"
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let org: OrgId = std::fs::read_to_string(&ready).unwrap().parse().unwrap();
    child.0.kill().unwrap();
    let status = child.0.wait().unwrap();
    assert_eq!(
        std::os::unix::process::ExitStatusExt::signal(&status),
        Some(9)
    );
    let boot = env.boot_r2(&prefix(&name), fast_archive).await.unwrap();
    let (base, server) = serve(&boot).await;
    let rt = Runtime::get(&boot.app_context);
    let mut api = Api::new(&base);
    assert_eq!(
        api.auth("login", EMAIL, password.as_str()).await.0,
        StatusCode::OK
    );
    let (status, page) = api.get(&format!("/api/orgs/{org}/logs?q={BODY}")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(page["rows"][0]["cursor"], "c1.1.0");
    assert_eq!(page["rows"].as_array().unwrap().len(), 1);
    let tenant = rt.tenant(&org).await.unwrap();
    tenant
        .execute_raw(sql("DROP TRIGGER crash_archive_commit", vec![]))
        .await
        .unwrap();
    drop(tenant);
    eventually(Duration::from_secs(60), || {
        let rt = rt.clone();
        let org = org.clone();
        async move { org_counts(&rt, &org).await.0 == "archived" }
    })
    .await;
    assert_eq!(
        org_counts(&rt, &org).await,
        ("archived".to_owned(), 1, 0, 1),
        "one archived row, no pending entries and one usage charge"
    );
    let keys = rt.store.list_page("logs/", None, 4).await.unwrap().keys;
    assert_eq!(keys.len(), 1, "one object in actual R2");
    let counters = rt.store.counters();
    let conditional_puts = counters.http_put.load(std::sync::atomic::Ordering::Relaxed);
    let written = counters
        .put_bytes
        .load(std::sync::atomic::Ordering::Relaxed);
    println!(
        "restart conditional_put_attempts={conditional_puts} written_bytes={written} key={}",
        keys[0]
    );
    assert!(
        conditional_puts >= 1,
        "restart retried the archive with a conditional PUT"
    );
    assert_eq!(
        written, 0,
        "the existing object was verified, never replaced"
    );
    let (status, page) = api.get(&format!("/api/orgs/{org}/logs?q={BODY}")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(page["rows"].as_array().unwrap().len(), 1);
    assert_eq!(page["rows"][0]["cursor"], "c1.1.0");
    for key in rt.store.list_page("", None, 100).await.unwrap().keys {
        rt.store.delete(&key).await.unwrap();
    }
    assert!(rt
        .store
        .list_page("", None, 10)
        .await
        .unwrap()
        .keys
        .is_empty());
    App::on_shutdown(&boot.app_context).await;
    server.abort();
    let _ = server.await;
    drop(api);
    drop(rt);
    drop(boot);
    assert_body_absent(&env.dir);
}
