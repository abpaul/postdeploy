mod support;

use std::{
    path::{Path, PathBuf},
    sync::atomic::Ordering,
    time::{Duration, Instant},
};

use loco_rs::{app::Hooks, boot::BootResult};
use postdeploy::{
    domain::OrgId,
    runtime::{sql, Runtime},
    testing::{serve, TestApp, TestEnv},
};
use reqwest::StatusCode;
use sea_orm::{
    sqlx::{
        self,
        sqlite::{SqliteConnectOptions, SqliteConnection, SqliteJournalMode},
        Connection,
    },
    ConnectionTrait,
};
use serde_json::{json, Value};
use support::*;
use tenant_sqlite_loco::TenantId;

const ROOT_OWNED: &str = "tenant root is owned by another running process";
const CHILD_READY: &str = "POSTDEPLOY_LIFECYCLE_CHILD_READY";
const EVENT_ID: &str = "00112233445566778899aabbccddeeff";

async fn shutdown(boot: &BootResult) {
    TestApp::on_shutdown(&boot.app_context).await;
}

fn org_id(org: &str) -> OrgId {
    org.parse().expect("organization id")
}

fn tenant_databases(root: &Path) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(root)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .filter(|name| name.ends_with(".db"))
        .collect();
    names.sort();
    names
}

/// A connection from outside the application, as an operator tool would open it.
async fn outside_connection(path: &Path, journal: SqliteJournalMode) -> SqliteConnection {
    let options = SqliteConnectOptions::new()
        .filename(path)
        .create_if_missing(false)
        .journal_mode(journal)
        .busy_timeout(Duration::from_secs(5));
    SqliteConnection::connect_with(&options).await.unwrap()
}

async fn outside_execute(path: &Path, statement: &'static str) {
    let mut conn = outside_connection(path, SqliteJournalMode::Wal).await;
    sqlx::query(statement).execute(&mut conn).await.unwrap();
    conn.close().await.unwrap();
}

async fn issue_rows(api: &Api, org: &str) -> (StatusCode, Value) {
    api.get(&format!("/api/orgs/{org}/issues")).await
}

async fn send_error(base: &str, project: i64, dsn: &str) -> StatusCode {
    post_envelope(
        base,
        project,
        &dsn_key(dsn),
        envelope(Some(EVENT_ID), &[]),
        None,
    )
    .await
    .0
}

fn sse_mentions(events: &[(String, Value)], marker: &str) -> bool {
    events
        .iter()
        .any(|(name, data)| name == "entries" && data.to_string().contains(marker))
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn shutdown_keeps_acknowledged_entries_closes_tails_and_closes_the_registry() {
    let env = TestEnv::new("shutdown-drain");
    let settings = |s: &mut Value| {
        s["logs"]["batch_max_age_ms"] = json!(60_000);
        s["lifecycle"]["drain_ms"] = json!(5_000);
    };
    let boot = env.boot_memory(settings).await.unwrap();
    let (base, _server) = serve(&boot).await;
    let api = Api::signup(&base, "drain@example.test").await;
    let (org, project, dsn) = api.setup_source("Drain").await;
    let key = dsn_key(&dsn);
    let rt = Runtime::get(&boot.app_context);
    let marker = "lcdrain7q2";

    let tail = api
        .http
        .get(format!("{base}/api/orgs/{org}/logs/tail"))
        .header("cookie", api.cookie.clone().unwrap())
        .send()
        .await
        .unwrap();
    assert_eq!(tail.status(), StatusCode::OK);
    let tail = tokio::spawn(read_sse(tail, Duration::from_secs(30), |name, _| {
        name == "closing"
    }));

    assert_eq!(
        post_envelope(&base, project, &key, envelope(None, &[marker]), None).await,
        (StatusCode::OK, accepted(None, 0, 1)),
        "acknowledged once the SQLite transaction commits"
    );
    assert!(
        env.store
            .list_page("logs/", None, 10)
            .await
            .unwrap()
            .keys
            .is_empty(),
        "the batch is still open in SQLite"
    );

    let started = Instant::now();
    let closing = tokio::spawn({
        let ctx = boot.app_context.clone();
        async move {
            TestApp::on_shutdown(&ctx).await;
            started.elapsed()
        }
    });
    let gate = rt.clone();
    eventually(Duration::from_secs(5), || {
        let gate = gate.clone();
        async move { !gate.gate.is_open() }
    })
    .await;
    let health = reqwest::get(format!("{base}/healthz")).await.unwrap();
    assert_eq!(health.status(), StatusCode::SERVICE_UNAVAILABLE);
    let late = post_envelope(&base, project, &key, envelope(None, &["lclate"]), None).await;
    assert_eq!(
        late,
        (
            StatusCode::SERVICE_UNAVAILABLE,
            json!({"error": "shutting_down"})
        )
    );

    let elapsed = closing.await.unwrap();
    assert!(
        elapsed < Duration::from_secs(5),
        "shutdown took {elapsed:?}, over the 5 s drain deadline"
    );
    assert!(
        env.store
            .list_page("logs/", None, 10)
            .await
            .unwrap()
            .keys
            .is_empty(),
        "shutdown leaves the acknowledged batch in SQLite for the next start"
    );
    let before_restart = tail.await.unwrap();
    let (last, data) = before_restart.last().expect("tail events");
    assert_eq!(last, "closing", "the tail ends with a closing event");
    let resume = data["resume"].as_str().unwrap().to_owned();

    let stats = rt.tenants.registry().stats().await;
    assert_eq!(
        (stats.retained_pools, stats.leased_pools, stats.shutdown),
        (0, 0, true),
        "registry closed every pool"
    );
    assert!(
        matches!(
            rt.tenants
                .registry()
                .open_existing(&TenantId::new(org.clone()).unwrap())
                .await,
            Err(tenant_sqlite_loco::Error::Shutdown)
        ),
        "the closed registry refuses opens"
    );

    let again = env.boot_memory(settings).await.unwrap();
    let (base, _server) = serve(&again).await;
    let mut api = Api::new(&base);
    assert_eq!(
        api.auth("login", "drain@example.test", PASSWORD).await.0,
        StatusCode::OK
    );
    let (status, page) = api.get(&format!("/api/orgs/{org}/logs?q={marker}")).await;
    assert_eq!(status, StatusCode::OK);
    assert!(
        page["rows"]
            .as_array()
            .is_some_and(|rows| rows.len() == 1 && rows[0]["body"].as_str() == Some(marker)),
        "the acknowledged log is searchable after restart"
    );
    let replay = api
        .http
        .get(format!("{base}/api/orgs/{org}/logs/tail?after={resume}"))
        .header("cookie", api.cookie.clone().unwrap())
        .send()
        .await
        .unwrap();
    assert_eq!(replay.status(), StatusCode::OK);
    let after_restart = read_sse(replay, Duration::from_secs(3), |name, data| {
        name == "entries" && data.to_string().contains(marker)
    })
    .await;
    assert!(
        sse_mentions(&before_restart, marker) != sse_mentions(&after_restart, marker),
        "the viewer receives the acknowledged log exactly once across the restart"
    );
    assert!(
        file_contains(&env.dir, marker.as_bytes()).is_empty(),
        "log text found on local disk"
    );
    shutdown(&again).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn shutdown_is_bounded_when_an_archive_upload_straggles() {
    let env = TestEnv::new("shutdown-straggler");
    let settings = |s: &mut Value| {
        s["logs"]["batch_max_age_ms"] = json!(100);
        s["logs"]["upload_attempts"] = json!(100);
        s["logs"]["upload_deadline_ms"] = json!(10_000);
        s["lifecycle"]["drain_ms"] = json!(300);
        s["lifecycle"]["background_ms"] = json!(300);
        s["lifecycle"]["registry_ms"] = json!(2_000);
    };
    let boot = env.boot_memory(settings).await.unwrap();
    let (base, _server) = serve(&boot).await;
    let api = Api::signup(&base, "straggler@example.test").await;
    let (_org, project, dsn) = api.setup_source("Straggler").await;
    let key = dsn_key(&dsn);
    let rt = Runtime::get(&boot.app_context);
    let marker = "lcstraggle4k";

    env.faults.fail_puts.store(10_000, Ordering::SeqCst);
    assert_eq!(
        post_envelope(&base, project, &key, envelope(None, &[marker]), None)
            .await
            .0,
        StatusCode::OK
    );
    let retrying = rt.clone();
    eventually(Duration::from_secs(10), || {
        let rt = retrying.clone();
        async move { rt.metrics.log_upload_retries.load(Ordering::Relaxed) >= 1 }
    })
    .await;

    let started = Instant::now();
    shutdown(&boot).await;
    let elapsed = started.elapsed();
    assert!(
        elapsed < Duration::from_millis(300 + 300 + 300 + 2_000),
        "shutdown took {elapsed:?}, over its drain, background and registry deadlines"
    );
    let stats = rt.tenants.registry().stats().await;
    assert_eq!(
        (stats.retained_pools, stats.leased_pools, stats.shutdown),
        (0, 0, true),
        "an upload holds no tenant handle, so the registry closes"
    );
    let successor = env
        .boot_memory(settings)
        .await
        .expect("a closed registry releases the root lock");

    assert!(
        env.store
            .list_page("logs/", None, 10)
            .await
            .unwrap()
            .keys
            .is_empty(),
        "no object was stored before shutdown"
    );
    env.faults.fail_puts.store(0, Ordering::SeqCst);
    let store = env.store.clone();
    eventually(Duration::from_secs(15), || {
        let store = store.clone();
        async move { store.list_page("logs/", None, 10).await.unwrap().keys.len() == 1 }
    })
    .await;
    assert!(
        file_contains(&env.dir, marker.as_bytes()).is_empty(),
        "log text found on local disk"
    );
    shutdown(&successor).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_leased_tenant_handle_fails_shutdown_and_keeps_the_root_lock_until_retry() {
    let env = TestEnv::new("shutdown-leased");
    let settings = |s: &mut Value| {
        s["lifecycle"]["drain_ms"] = json!(300);
        s["lifecycle"]["background_ms"] = json!(300);
        s["lifecycle"]["registry_ms"] = json!(500);
    };
    let boot = env.boot_memory(settings).await.unwrap();
    let (base, _server) = serve(&boot).await;
    let api = Api::signup(&base, "leased@example.test").await;
    let (org, _, _) = api.setup_source("Leased").await;
    let rt = Runtime::get(&boot.app_context);

    let job = rt.tenant(&org_id(&org)).await.unwrap();
    let started = Instant::now();
    shutdown(&boot).await;
    let elapsed = started.elapsed();
    assert!(
        elapsed < Duration::from_millis(300 + 300 + 500 + 1_500),
        "shutdown took {elapsed:?} with a leased handle"
    );
    let refused = env
        .boot_memory(settings)
        .await
        .err()
        .expect("a failed registry shutdown keeps the root lock")
        .to_string();
    assert!(refused.contains(ROOT_OWNED), "{refused}");

    drop(job);
    shutdown(&boot).await;
    let stats = rt.tenants.registry().stats().await;
    assert_eq!(
        (stats.retained_pools, stats.leased_pools, stats.shutdown),
        (0, 0, true)
    );
    let successor = env
        .boot_memory(settings)
        .await
        .expect("a successful shutdown retry releases the root lock");
    shutdown(&successor).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_cold_tenant_whose_migration_fails_is_refused_and_recovers_without_reprovisioning() {
    let env = TestEnv::new("migration-failure");
    let boot = env.boot_memory(|_| {}).await.unwrap();
    let (base, _server) = serve(&boot).await;
    let api = Api::signup(&base, "migrate@example.test").await;
    let (alpha, alpha_project, alpha_dsn) = api.setup_source("Alpha").await;
    let (beta, beta_project, beta_dsn) = api.setup_source("Beta").await;
    assert_eq!(
        send_error(&base, alpha_project, &alpha_dsn).await,
        StatusCode::OK
    );
    assert_eq!(
        send_error(&base, beta_project, &beta_dsn).await,
        StatusCode::OK
    );
    shutdown(&boot).await;
    drop(boot);

    let root = env.tenant_root();
    let alpha_file = root.join(format!("{alpha}.db"));
    let databases = tenant_databases(&root);
    let inode = std::os::unix::fs::MetadataExt::ino(&std::fs::metadata(&alpha_file).unwrap());
    outside_execute(
        &alpha_file,
        "INSERT INTO seaql_migrations (version, applied_at) VALUES ('m29991231_000001_newer_release', 0)",
    )
    .await;

    let boot = env.boot_memory(|_| {}).await.unwrap();
    let (base, _server) = serve(&boot).await;
    let mut api = Api::new(&base);
    assert_eq!(
        api.auth("login", "migrate@example.test", PASSWORD).await.0,
        StatusCode::OK
    );
    let rt = Runtime::get(&boot.app_context);

    assert_eq!(
        issue_rows(&api, &alpha).await,
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            json!({"error": "internal_error"})
        ),
        "reads of the unmigratable tenant fail"
    );
    assert_eq!(
        post_envelope(
            &base,
            alpha_project,
            &dsn_key(&alpha_dsn),
            envelope(None, &["lcmigrate"]),
            None
        )
        .await,
        (
            StatusCode::SERVICE_UNAVAILABLE,
            json!({"error": "ingest_unavailable"})
        ),
        "ingestion for the unmigratable tenant is retryable"
    );
    let (status, beta_issues) = issue_rows(&api, &beta).await;
    assert_eq!(status, StatusCode::OK, "other tenants keep working");
    assert_eq!(beta_issues["issues"][0]["event_count"], 1);
    assert_eq!(
        tenant_databases(&root),
        databases,
        "no tenant was provisioned"
    );
    assert_eq!(
        std::os::unix::fs::MetadataExt::ino(&std::fs::metadata(&alpha_file).unwrap()),
        inode,
        "the failed tenant file was not replaced"
    );
    assert_eq!(
        rt.tenants.registry().stats().await.retained_pools,
        1,
        "the failed open retains no pool"
    );

    outside_execute(
        &alpha_file,
        "DELETE FROM seaql_migrations WHERE version = 'm29991231_000001_newer_release'",
    )
    .await;
    let (status, alpha_issues) = issue_rows(&api, &alpha).await;
    assert_eq!(
        status,
        StatusCode::OK,
        "an ordinary open recovers after repair"
    );
    assert_eq!(
        (
            alpha_issues["issues"].as_array().map_or(0, Vec::len),
            alpha_issues["issues"][0]["event_count"].clone(),
            alpha_issues["issues"][0]["last_release"].clone()
        ),
        (1, json!(1), json!("web@1")),
        "the issue committed before the failure is intact"
    );
    assert_eq!(
        send_error(&base, alpha_project, &alpha_dsn).await,
        StatusCode::OK
    );
    let (_, alpha_issues) = issue_rows(&api, &alpha).await;
    assert_eq!(
        alpha_issues["issues"][0]["event_count"], 1,
        "the retried event deduplicates against the preserved row"
    );
    assert_eq!(tenant_databases(&root), databases);
    shutdown(&boot).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn leased_pools_never_exceed_the_registry_bound() {
    let env = TestEnv::new("pool-capacity");
    let settings = |s: &mut Value| {
        s["tenants"]["max_pools"] = json!(2);
    };
    let boot = env.boot_memory(settings).await.unwrap();
    let (base, _server) = serve(&boot).await;
    let api = Api::signup(&base, "capacity@example.test").await;
    let mut orgs = Vec::new();
    for name in ["Alpha", "Beta", "Gamma"] {
        let (org, project, dsn) = api.setup_source(name).await;
        assert_eq!(send_error(&base, project, &dsn).await, StatusCode::OK);
        orgs.push(org);
    }
    let rt = Runtime::get(&boot.app_context);
    let registry = rt.tenants.registry();
    assert_eq!(registry.stats().await.retained_pools, 2);

    let alpha = rt.tenant(&org_id(&orgs[0])).await.unwrap();
    let beta = rt.tenant(&org_id(&orgs[1])).await.unwrap();
    let stats = registry.stats().await;
    assert_eq!((stats.retained_pools, stats.leased_pools), (2, 2));
    assert_eq!(
        issue_rows(&api, &orgs[2]).await,
        (
            StatusCode::SERVICE_UNAVAILABLE,
            json!({"error": "tenant_unavailable"})
        ),
        "a third tenant cannot open while both pools are leased"
    );
    assert_eq!(
        api.post("/api/orgs", json!({"name": "Delta"})).await,
        (
            StatusCode::SERVICE_UNAVAILABLE,
            json!({"error": "tenant_unavailable"})
        ),
        "provisioning respects the same bound"
    );
    assert_eq!(
        tenant_databases(&env.tenant_root()).len(),
        3,
        "no file for the refused organization"
    );
    assert_eq!(
        api.get("/api/orgs").await.1["orgs"]
            .as_array()
            .map_or(0, Vec::len),
        3,
        "no control rows for the refused organization"
    );

    drop(beta);
    let (status, gamma) = issue_rows(&api, &orgs[2]).await;
    assert_eq!(
        status,
        StatusCode::OK,
        "an idle pool is evicted for the third tenant"
    );
    assert_eq!(gamma["issues"][0]["event_count"], 1);
    let stats = registry.stats().await;
    assert_eq!((stats.retained_pools, stats.leased_pools), (2, 1));
    drop(alpha);

    let sampling = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(true));
    let sampler = tokio::spawn({
        let (rt, sampling) = (rt.clone(), sampling.clone());
        async move {
            let mut max = 0;
            while sampling.load(Ordering::Relaxed) {
                max = max.max(rt.tenants.registry().stats().await.retained_pools);
                tokio::time::sleep(Duration::from_millis(2)).await;
            }
            max
        }
    });
    let requests = (0..30).map(|i| {
        let (api, org) = (api.clone(), orgs[i % 3].clone());
        tokio::spawn(async move { issue_rows(&api, &org).await })
    });
    let mut served = 0;
    for request in futures::future::join_all(requests).await {
        match request.unwrap() {
            (StatusCode::OK, _) => served += 1,
            other => assert_eq!(
                other,
                (
                    StatusCode::SERVICE_UNAVAILABLE,
                    json!({"error": "tenant_unavailable"})
                )
            ),
        }
    }
    sampling.store(false, Ordering::Relaxed);
    assert!(served > 0, "concurrent requests were served");
    assert!(
        sampler.await.unwrap() <= 2,
        "retained pools exceeded max_pools"
    );
    assert!(registry.stats().await.retained_pools <= 2);
    shutdown(&boot).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_cold_tenant_open_stalls_hot_tenant_requests_until_it_finishes() {
    let env = TestEnv::new("cold-open-contention");
    let boot = env.boot_memory(|_| {}).await.unwrap();
    let (base, _server) = serve(&boot).await;
    let api = Api::signup(&base, "contention@example.test").await;
    let (hot, hot_project, hot_dsn) = api.setup_source("Hot").await;
    let (cold, cold_project, cold_dsn) = api.setup_source("Cold").await;
    assert_eq!(
        send_error(&base, hot_project, &hot_dsn).await,
        StatusCode::OK
    );
    assert_eq!(
        send_error(&base, cold_project, &cold_dsn).await,
        StatusCode::OK
    );
    let rt = Runtime::get(&boot.app_context);
    rt.tenants
        .registry()
        .evict(&TenantId::new(cold.clone()).unwrap())
        .await
        .unwrap();

    let started = Instant::now();
    assert_eq!(issue_rows(&api, &hot).await.0, StatusCode::OK);
    let unblocked = started.elapsed();

    let hold = Duration::from_millis(2_000);
    let mut blocker = outside_connection(
        &env.tenant_root().join(format!("{cold}.db")),
        SqliteJournalMode::Delete,
    )
    .await;
    sqlx::query("BEGIN EXCLUSIVE")
        .execute(&mut blocker)
        .await
        .unwrap();
    let held = Instant::now();
    let timed = |api: Api, org: String| async move {
        let started = Instant::now();
        let (status, body) = issue_rows(&api, &org).await;
        (status, body, started.elapsed())
    };
    let cold_request = tokio::spawn(timed(api.clone(), cold.clone()));
    tokio::time::sleep(Duration::from_millis(500)).await;
    let hot_request = tokio::spawn(timed(api.clone(), hot.clone()));
    tokio::time::sleep(hold.saturating_sub(held.elapsed())).await;
    sqlx::query("COMMIT").execute(&mut blocker).await.unwrap();
    blocker.close().await.unwrap();

    let (cold_status, cold_body, cold_latency) = cold_request.await.unwrap();
    let (hot_status, hot_body, hot_latency) = hot_request.await.unwrap();
    println!(
        "cold-open contention: hot unblocked {unblocked:?}, cold {cold_latency:?}, hot during cold open {hot_latency:?}"
    );
    assert_eq!(
        (cold_status, cold_body["issues"][0]["event_count"].clone()),
        (StatusCode::OK, json!(1))
    );
    assert_eq!(
        (hot_status, hot_body["issues"][0]["event_count"].clone()),
        (StatusCode::OK, json!(1))
    );
    assert!(
        unblocked < Duration::from_millis(750),
        "an unblocked hot read took {unblocked:?}"
    );
    assert!(
        hot_latency >= Duration::from_millis(1_000),
        "the hot tenant read finished in {hot_latency:?} while a cold open held the registry"
    );
    shutdown(&boot).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_crashed_owner_releases_the_root_lock_and_restart_keeps_committed_rows() {
    let env = TestEnv::new("crash-restart");
    let ready = env.dir.join("child.ready");
    let log = std::fs::File::create(env.dir.join("child.log")).unwrap();
    let run = env.dir.parent().unwrap();
    let mut child = std::process::Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "crash_child_owner",
            "--ignored",
            "--nocapture",
            "--test-threads=1",
        ])
        .env(CHILD_READY, &ready)
        .env("POSTDEPLOY_TEST_ROOT", run.parent().unwrap())
        .env("POSTDEPLOY_TEST_RUN", run.file_name().unwrap())
        .stdout(log.try_clone().unwrap())
        .stderr(log)
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(120);
    while !ready.exists() {
        assert!(
            child.try_wait().unwrap().is_none(),
            "child exited before it was ready; see child.log"
        );
        assert!(Instant::now() < deadline, "child was not ready in time");
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    let org = std::fs::read_to_string(&ready).unwrap();

    let refused = env
        .boot_memory(|_| {})
        .await
        .err()
        .expect("another process owns the tenant root")
        .to_string();
    assert!(refused.contains(ROOT_OWNED), "{refused}");

    child.kill().unwrap();
    let status = child.wait().unwrap();
    assert_eq!(
        std::os::unix::process::ExitStatusExt::signal(&status),
        Some(9)
    );

    let boot = env
        .boot_memory(|_| {})
        .await
        .expect("the operating system released the crashed owner's lock");
    let (base, _server) = serve(&boot).await;
    let mut api = Api::new(&base);
    assert_eq!(
        api.auth("login", "crash@example.test", PASSWORD).await.0,
        StatusCode::OK
    );
    let (status, issues) = issue_rows(&api, &org).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        (
            issues["issues"].as_array().map_or(0, Vec::len),
            issues["issues"][0]["event_count"].clone(),
            issues["issues"][0]["last_release"].clone()
        ),
        (1, json!(1), json!("web@1")),
        "the acknowledged error survived the crash"
    );
    let rt = Runtime::get(&boot.app_context);
    let handle = rt.tenant(&org_id(&org)).await.unwrap();
    let check: String = handle
        .query_one_raw(postdeploy::runtime::sql("PRAGMA quick_check", vec![]))
        .await
        .unwrap()
        .unwrap()
        .try_get_by_index(0)
        .unwrap();
    drop(handle);
    assert_eq!(check, "ok");
    shutdown(&boot).await;
}

/// Runs only as the child of the crash test: owns the tenant root, commits one
/// error and waits to be killed.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "child process of a_crashed_owner_releases_the_root_lock_and_restart_keeps_committed_rows"]
async fn crash_child_owner() {
    let Some(ready) = std::env::var_os(CHILD_READY).map(PathBuf::from) else {
        return;
    };
    let env = TestEnv::new("crash-restart");
    let boot = env.boot_memory(|_| {}).await.unwrap();
    let (base, _server) = serve(&boot).await;
    let api = Api::signup(&base, "crash@example.test").await;
    let (org, project, dsn) = api.setup_source("Crash").await;
    assert_eq!(send_error(&base, project, &dsn).await, StatusCode::OK);
    std::fs::write(&ready, org).unwrap();
    std::future::pending::<()>().await;
}

const LARGE_ENTRIES: usize = 250;
const LARGE_BODY: usize = 15_000;

fn large_batches(s: &mut Value) {
    s["logs"]["batch_max_age_ms"] = json!(50);
    s["logs"]["batch_max_bytes"] = json!(4 << 20);
}

/// A gzip envelope of near-maximal, highly compressible log bodies. The stored
/// object is small; the parsed records in memory are about 3.75 MB.
fn large_log_envelope(tag: &str) -> Vec<u8> {
    use std::io::Write;
    let body = format!("{tag}{}", "x".repeat(LARGE_BODY - tag.len()));
    let bodies: Vec<&str> = std::iter::repeat_n(body.as_str(), LARGE_ENTRIES).collect();
    let mut gz = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
    gz.write_all(&envelope(None, &bodies)).unwrap();
    gz.finish().unwrap()
}

async fn ingest_large_batches(base: &str, project: i64, key: &str, count: usize, tag: &str) {
    for _ in 0..count {
        let (status, _) =
            post_envelope(base, project, key, large_log_envelope(tag), Some("gzip")).await;
        assert_eq!(status, StatusCode::OK, "large batch acknowledged");
    }
}

fn rss_bytes() -> u64 {
    let out = std::process::Command::new("ps")
        .args(["-o", "rss=", "-p", &std::process::id().to_string()])
        .output()
        .unwrap();
    String::from_utf8(out.stdout)
        .unwrap()
        .trim()
        .parse::<u64>()
        .unwrap()
        * 1024
}

const MIB: f64 = (1 << 20) as f64;

/// Opens a live tail and never reads past the response headers.
fn stalled_viewer(base: &str, org: &str, cookie: &str) -> std::net::TcpStream {
    use std::io::{Read, Write};
    let host = base.trim_start_matches("http://");
    let mut stream = std::net::TcpStream::connect(host).unwrap();
    write!(
        stream,
        "GET /api/orgs/{org}/logs/tail HTTP/1.1\r\nHost: {host}\r\nCookie: {cookie}\r\n\r\n"
    )
    .unwrap();
    let mut head = Vec::new();
    let mut byte = [0u8; 1];
    while !head.ends_with(b"\r\n\r\n") {
        stream.read_exact(&mut byte).unwrap();
        head.push(byte[0]);
    }
    assert!(head.starts_with(b"HTTP/1.1 200"), "tail opened");
    stream
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "resource measurement: run alone with --ignored --exact --test-threads=1"]
async fn a_stalled_tail_viewer_retains_bounded_memory() {
    let env = TestEnv::new("stalled-viewer-memory");
    let boot = env.boot_memory(large_batches).await.unwrap();
    let (base, _server) = serve(&boot).await;
    let api = Api::signup(&base, "stalled@example.test").await;
    let (org, project, dsn) = api.setup_source("Stalled").await;
    let key = dsn_key(&dsn);
    let batches = Runtime::get(&boot.app_context)
        .settings
        .logs
        .tail
        .channel_capacity;

    ingest_large_batches(&base, project, &key, batches, "lcwarm").await;
    let without_viewer = rss_bytes();
    let viewer = stalled_viewer(&base, &org, api.cookie.as_deref().unwrap());
    ingest_large_batches(&base, project, &key, batches, "lcstall").await;
    let with_viewer = rss_bytes();
    drop(viewer);

    let retained = with_viewer.saturating_sub(without_viewer) as f64 / MIB;
    let published = (batches * LARGE_ENTRIES * LARGE_BODY) as f64 / MIB;
    println!(
        "stalled viewer: {batches} batches, {published:.0} MiB of bodies published, rss without viewer {:.0} MiB, with stalled viewer {:.0} MiB, growth {retained:.0} MiB",
        without_viewer as f64 / MIB,
        with_viewer as f64 / MIB,
    );
    assert!(
        retained < 32.0,
        "one stalled viewer grew process memory by {retained:.0} MiB after {published:.0} MiB of published bodies"
    );
    shutdown(&boot).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn saturated_log_query_slots_refuse_search_without_blocking_ingestion() {
    let env = TestEnv::new("query-admission");
    let boot = env
        .boot_memory(|s| {
            s["logs"]["search"]["max_active_queries"] = json!(2);
            s["logs"]["batch_max_age_ms"] = json!(50);
        })
        .await
        .unwrap();
    let (base, _server) = serve(&boot).await;
    let api = Api::signup(&base, "query-admission@example.test").await;
    let (org, project, dsn) = api.setup_source("Query admission").await;
    let rt = Runtime::get(&boot.app_context);
    let slots = [
        rt.admission.queries.live().unwrap(),
        rt.admission.queries.live().unwrap(),
    ];
    assert_eq!(
        api.get(&format!("/api/orgs/{org}/logs?q=lcadmission"))
            .await,
        (
            StatusCode::SERVICE_UNAVAILABLE,
            json!({"error":"log_query_overloaded"})
        )
    );
    assert_eq!(
        post_envelope(
            &base,
            project,
            &dsn_key(&dsn),
            envelope(None, &["lcadmission"]),
            None
        )
        .await
        .0,
        StatusCode::OK,
        "search saturation leaves the ingest lane available"
    );
    drop(slots);
    let (status, page) = api
        .get(&format!("/api/orgs/{org}/logs?q=lcadmission"))
        .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(page["rows"][0]["body"], json!("lcadmission"));
    assert_eq!(page["rows"].as_array().unwrap().len(), 1);
    shutdown(&boot).await;
}

async fn open_tail(api: &Api, org: &str, after: Option<&str>) -> reqwest::Response {
    let query = after.map_or_else(String::new, |cursor| format!("?after={cursor}"));
    api.http
        .get(format!("{}/api/orgs/{org}/logs/tail{query}", api.base))
        .header("cookie", api.cookie.clone().unwrap())
        .send()
        .await
        .unwrap()
}

/// Leading `tag` of each delivered row body, in delivery order.
fn delivered(events: &[(String, Value)], tag_len: usize) -> Vec<String> {
    events
        .iter()
        .filter(|(name, _)| name == "entries")
        .flat_map(|(_, data)| data["rows"].as_array().cloned().unwrap_or_default())
        .filter_map(|row| {
            row["body"]
                .as_str()
                .map(|b| b.chars().take(tag_len).collect())
        })
        .collect()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn following_replay_budget_gaps_delivers_every_entry_of_a_large_object() {
    let env = TestEnv::new("tail-budget-resume");
    let settings = |s: &mut Value| {
        s["logs"]["batch_max_age_ms"] = json!(200);
        s["logs"]["tail"]["replay_max_output_bytes"] = json!(4_000);
    };
    let boot = env.boot_memory(settings).await.unwrap();
    let (base, _server) = serve(&boot).await;
    let api = Api::signup(&base, "budget@example.test").await;
    let (org, project, dsn) = api.setup_source("Budget").await;
    let bodies: Vec<String> = (0..10)
        .map(|i| format!("lcpart{i:02}{}", "y".repeat(1_000)))
        .collect();
    let refs: Vec<&str> = bodies.iter().map(String::as_str).collect();
    let (status, _) =
        post_envelope(&base, project, &dsn_key(&dsn), envelope(None, &refs), None).await;
    assert_eq!(status, StatusCode::OK);

    let mut seen = Vec::new();
    let mut after = "c1.0.4294967295".to_owned();
    for _ in 0..12 {
        let events = read_sse(
            open_tail(&api, &org, Some(&after)).await,
            Duration::from_secs(2),
            |name, data| name == "gap" && data["reason"] == "replay_budget",
        )
        .await;
        seen.extend(delivered(&events, 8));
        match events
            .iter()
            .find(|(name, data)| name == "gap" && data["reason"] == "replay_budget")
        {
            Some((_, gap)) => after = gap["resume"].as_str().unwrap().to_owned(),
            None => break,
        }
    }
    let expected: Vec<String> = (0..10).map(|i| format!("lcpart{i:02}")).collect();
    let mut unique = seen.clone();
    unique.sort();
    unique.dedup();
    println!(
        "replay budget: {} of 10 entries delivered across resumes, {} deliveries",
        unique.len(),
        seen.len()
    );
    assert_eq!(
        unique, expected,
        "resuming from replay_budget gaps delivers every entry"
    );
    assert_eq!(seen.len(), 10, "no entry is delivered twice");
    shutdown(&boot).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn resuming_from_the_first_tail_event_never_skips_undelivered_entries() {
    let env = TestEnv::new("tail-gap-order");
    let settings = |s: &mut Value| {
        s["logs"]["batch_max_age_ms"] = json!(200);
        s["logs"]["retention_secs"] = json!(3);
    };
    let boot = env.boot_memory(settings).await.unwrap();
    let (base, _server) = serve(&boot).await;
    let api = Api::signup(&base, "gaporder@example.test").await;
    let (org, project, dsn) = api.setup_source("GapOrder").await;
    let key = dsn_key(&dsn);
    assert_eq!(
        post_envelope(&base, project, &key, envelope(None, &["lcold"]), None)
            .await
            .0,
        StatusCode::OK
    );
    tokio::time::sleep(Duration::from_secs(4)).await;
    assert_eq!(
        post_envelope(&base, project, &key, envelope(None, &["lcnew"]), None)
            .await
            .0,
        StatusCode::OK
    );

    let first = read_sse(
        open_tail(&api, &org, Some("c1.0.4294967295")).await,
        Duration::from_secs(3),
        |_, _| true,
    )
    .await;
    let (name, data) = first.first().expect("a first tail event");
    let resume = data["resume"]
        .as_str()
        .or_else(|| data["cursor"].as_str())
        .unwrap()
        .to_owned();
    let mut seen = delivered(&first, 5);
    let rest = read_sse(
        open_tail(&api, &org, Some(&resume)).await,
        Duration::from_secs(2),
        |_, _| false,
    )
    .await;
    seen.extend(delivered(&rest, 5));
    println!(
        "first tail event {name}; retained entry delivered after resuming from its id: {}",
        seen.iter().any(|b| b == "lcnew")
    );
    assert!(
        seen.iter().any(|b| b == "lcnew"),
        "a viewer that reconnects with the id of the first event it received still gets the retained entry"
    );
    assert!(!seen.iter().any(|b| b == "lcold"), "expired entry replayed");
    shutdown(&boot).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_stalled_viewer_does_not_starve_other_log_reads() {
    let env = TestEnv::new("stalled-viewer-slots");
    let settings = |s: &mut Value| {
        large_batches(s);
        s["logs"]["search"]["max_active_queries"] = json!(1);
    };
    let boot = env.boot_memory(settings).await.unwrap();
    let (base, _server) = serve(&boot).await;
    let api = Api::signup(&base, "slots@example.test").await;
    let (stalled_org, stalled_project, stalled_dsn) = api.setup_source("Stalled").await;
    let (other_org, other_project, other_dsn) = api.setup_source("Other").await;
    assert_eq!(
        post_envelope(
            &base,
            other_project,
            &dsn_key(&other_dsn),
            envelope(None, &["lcother"]),
            None
        )
        .await
        .0,
        StatusCode::OK
    );

    let viewer = stalled_viewer(&base, &stalled_org, api.cookie.as_deref().unwrap());
    ingest_large_batches(&base, stalled_project, &dsn_key(&stalled_dsn), 12, "lcslot").await;
    tokio::time::sleep(Duration::from_secs(1)).await;
    let mut statuses = Vec::new();
    for _ in 0..10 {
        let (status, body) = api
            .get(&format!("/api/orgs/{other_org}/logs?q=lcother"))
            .await;
        statuses.push((status, body["error"].clone()));
    }
    let refused = statuses
        .iter()
        .filter(|(s, _)| *s != StatusCode::OK)
        .count();
    println!("searches on another organization while one viewer is stalled: {refused} of 10 refused, first {:?}", statuses[0]);
    drop(viewer);
    assert_eq!(
        refused, 0,
        "a stalled viewer holds no global log query slot"
    );
    shutdown(&boot).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_full_request_gate_refuses_new_tails_as_overloaded() {
    let env = TestEnv::new("request-slots");
    let settings = |s: &mut Value| {
        s["lifecycle"]["max_active_requests"] = json!(3);
    };
    let boot = env.boot_memory(settings).await.unwrap();
    let (base, _server) = serve(&boot).await;
    let api = Api::signup(&base, "gate@example.test").await;
    let (org, _, _) = api.setup_source("Gate").await;

    let first = open_tail(&api, &org, None).await;
    let second = open_tail(&api, &org, None).await;
    assert_eq!(
        (first.status(), second.status()),
        (StatusCode::OK, StatusCode::OK)
    );
    let third = open_tail(&api, &org, None).await;
    let refused = (
        third.status(),
        third.json::<Value>().await.unwrap_or(Value::Null),
    );
    let (status, _) = api.get("/api/orgs").await;
    assert_eq!(
        status,
        StatusCode::OK,
        "short requests still fit beside two streams"
    );
    assert_eq!(
        refused,
        (
            StatusCode::SERVICE_UNAVAILABLE,
            json!({"error": "server_overloaded"})
        ),
        "a full gate is reported as overload, not shutdown"
    );
    drop((first, second));
    let opened = open_tail(&api, &org, None).await;
    assert_eq!(
        opened.status(),
        StatusCode::OK,
        "closed streams return their slots"
    );
    drop(opened);
    shutdown(&boot).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn every_live_viewer_receives_each_entry_once_from_committed_storage() {
    let env = TestEnv::new("live-from-storage");
    let settings = |s: &mut Value| {
        s["logs"]["batch_max_age_ms"] = json!(100);
    };
    let boot = env.boot_memory(settings).await.unwrap();
    let (base, _server) = serve(&boot).await;
    let api = Api::signup(&base, "live@example.test").await;
    let (org, project, dsn) = api.setup_source("Live").await;
    let rt = Runtime::get(&boot.app_context);
    let markers: Vec<String> = (0..5).map(|i| format!("lclive{i}")).collect();

    let viewers: Vec<_> = futures::future::join_all((0..2).map(|_| open_tail(&api, &org, None)))
        .await
        .into_iter()
        .map(|response| {
            assert_eq!(response.status(), StatusCode::OK);
            tokio::spawn(read_sse(response, Duration::from_secs(20), |_, data| {
                data.to_string().contains("lclive4")
            }))
        })
        .collect();
    tokio::time::sleep(Duration::from_millis(300)).await;
    let gets = rt.store.counters().gets.load(Ordering::Relaxed);
    for marker in &markers {
        let (status, _) = post_envelope(
            &base,
            project,
            &dsn_key(&dsn),
            envelope(None, &[marker]),
            None,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
    }
    for viewer in viewers {
        let events = viewer.await.unwrap();
        assert_eq!(
            delivered(&events, 7),
            markers,
            "each viewer gets every entry once, in order"
        );
    }
    let reads = rt.store.counters().gets.load(Ordering::Relaxed) - gets;
    println!("live tail: 5 appends, 2 viewers, {reads} logical object reads");
    shutdown(&boot).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_saturated_request_gate_does_not_stop_background_token_cleanup() {
    let env = TestEnv::new("gate-background");
    let boot = env
        .boot_memory(|s| s["lifecycle"]["max_active_requests"] = json!(2))
        .await
        .unwrap();
    let (base, _server) = serve(&boot).await;
    let api = Api::signup(&base, "gate-background@example.test").await;
    let rt = Runtime::get(&boot.app_context);
    let first = rt.gate.enter().expect("first gate slot");
    let second = rt.gate.enter().expect("second gate slot");
    rt.control.execute_unprepared("INSERT INTO account_tokens(token_hash,user_id,purpose,email,created_at,expires_at) SELECT X'0123456789ABCDEF',id,'reset_password',email,0,0 FROM users WHERE email='gate-background@example.test'").await.unwrap();
    assert_eq!(
        api.get("/api/orgs").await,
        (
            StatusCode::SERVICE_UNAVAILABLE,
            json!({"error":"server_overloaded"})
        )
    );
    tokio::time::sleep(Duration::from_secs(6)).await;
    let count = |rt: std::sync::Arc<Runtime>| async move {
        rt.control
            .query_one_raw(postdeploy::runtime::sql(
                "SELECT COUNT(*) AS n FROM account_tokens WHERE token_hash=X'0123456789ABCDEF'",
                vec![],
            ))
            .await
            .unwrap()
            .unwrap()
            .try_get::<i64>("", "n")
            .unwrap()
    };
    assert_eq!(
        count(rt.clone()).await,
        1,
        "cleanup waits while the gate is full"
    );
    drop((first, second));
    eventually(Duration::from_secs(12), || {
        let rt = rt.clone();
        async { count(rt).await == 0 }
    })
    .await;
    assert_eq!(api.get("/api/orgs").await.0, StatusCode::OK);
    shutdown(&boot).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn many_organization_archives_share_one_shutdown_deadline_and_recover_exactly() {
    let env = TestEnv::new("shutdown-many-org-archives");
    let settings = |s: &mut Value| {
        s["logs"]["batch_max_entries"] = json!(100);
        s["logs"]["batch_max_age_ms"] = json!(100);
        s["logs"]["archive_tick_ms"] = json!(10);
        s["logs"]["upload_concurrency"] = json!(2);
        s["logs"]["upload_deadline_ms"] = json!(10_000);
        s["lifecycle"]["drain_ms"] = json!(300);
        s["lifecycle"]["background_ms"] = json!(300);
        s["lifecycle"]["registry_ms"] = json!(500);
        s["auth"]["max_created_orgs"] = json!(6);
    };
    let boot = env.boot_memory(settings).await.unwrap();
    let (base, server) = serve(&boot).await;
    let api = Api::signup(&base, "many-archive-orgs@example.test").await;
    let rt = Runtime::get(&boot.app_context);
    env.faults.delay_put_ms.store(60_000, Ordering::SeqCst);
    let mut acknowledged = Vec::new();
    for index in 0..6 {
        let (org, project, dsn) = api.setup_source(&format!("Shutdown archive {index}")).await;
        let marker = format!("shutdown-org-marker-{index}");
        assert_eq!(
            post_envelope(
                &base,
                project,
                &dsn_key(&dsn),
                envelope(None, &[&marker]),
                None
            )
            .await,
            (StatusCode::OK, accepted(None, 0, 1))
        );
        let (status, page) = api.get(&format!("/api/orgs/{org}/logs")).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(page["rows"].as_array().unwrap().len(), 1);
        assert_eq!(page["rows"][0]["cursor"], "c1.1.0");
        assert_eq!(page["rows"][0]["body"], marker);
        acknowledged.push((org_id(&org), marker));
    }
    eventually(Duration::from_secs(5), || async {
        for (org, _) in &acknowledged {
            let tenant = rt.tenant(org).await.unwrap();
            let row = tenant
                .query_one_raw(sql(
                    "SELECT COUNT(*) AS sealed FROM log_objects WHERE state='sealed'",
                    vec![],
                ))
                .await
                .unwrap()
                .unwrap();
            if row.try_get::<i64>("", "sealed").unwrap() != 1 {
                return false;
            }
        }
        true
    })
    .await;
    eventually(Duration::from_secs(5), || async {
        acknowledged
            .iter()
            .filter(|(org, _)| rt.store.org_writes_pending(org))
            .count()
            == 2
    })
    .await;
    assert_eq!(
        rt.store.counters().puts.load(Ordering::SeqCst),
        0,
        "two conditional PUTs are delayed before writing"
    );
    let started = Instant::now();
    shutdown(&boot).await;
    assert!(
        started.elapsed() < Duration::from_millis(1_200),
        "six organizations share one drain deadline, shutdown took {:?}",
        started.elapsed()
    );
    assert_eq!(
        rt.metrics.log_batches_failed.load(Ordering::SeqCst),
        6,
        "both active uploads and all four queued jobs finished cancellation"
    );
    assert!(acknowledged
        .iter()
        .all(|(org, _)| !rt.store.org_writes_pending(org)));
    let stats = rt.tenants.registry().stats().await;
    assert_eq!(
        (stats.retained_pools, stats.leased_pools, stats.shutdown),
        (0, 0, true)
    );
    assert_eq!(rt.store.counters().puts.load(Ordering::SeqCst), 0);
    server.abort();
    env.faults.delay_put_ms.store(0, Ordering::SeqCst);
    let successor = env
        .boot_memory(settings)
        .await
        .expect("all jobs and tenant leases release the root lock");
    let (base, successor_server) = serve(&successor).await;
    let mut api = Api::new(&base);
    assert_eq!(
        api.auth("login", "many-archive-orgs@example.test", PASSWORD)
            .await
            .0,
        StatusCode::OK
    );
    let recovered = Runtime::get(&successor.app_context);
    for (org, marker) in &acknowledged {
        let (status, page) = api.get(&format!("/api/orgs/{org}/logs")).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(page["rows"].as_array().unwrap().len(), 1);
        assert_eq!(page["rows"][0]["cursor"], "c1.1.0");
        assert_eq!(page["rows"][0]["body"], *marker);
        let tenant = recovered.tenant(org).await.unwrap();
        let row = tenant.query_one_raw(sql(
            "SELECT COALESCE(SUM(accepted),0) AS accepted, COALESCE(SUM(bytes),0) AS bytes, (SELECT COUNT(*) FROM log_objects) AS objects FROM usage_daily WHERE category='log'",
            vec![],
        )).await.unwrap().unwrap();
        assert_eq!(row.try_get::<i64>("", "accepted").unwrap(), 1);
        assert_eq!(row.try_get::<i64>("", "bytes").unwrap(), 154);
        assert_eq!(row.try_get::<i64>("", "objects").unwrap(), 1);
    }
    eventually(Duration::from_secs(10), || async {
        recovered.metrics.objects_archived.load(Ordering::SeqCst) == 6
    })
    .await;
    assert_eq!(recovered.store.counters().puts.load(Ordering::SeqCst), 6);
    for (org, marker) in &acknowledged {
        let (status, page) = api.get(&format!("/api/orgs/{org}/logs")).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(page["rows"].as_array().unwrap().len(), 1);
        assert_eq!(page["rows"][0]["cursor"], "c1.1.0");
        assert_eq!(page["rows"][0]["body"], *marker);
        let tenant = recovered.tenant(org).await.unwrap();
        let row = tenant.query_one_raw(sql(
            "SELECT COALESCE(SUM(accepted),0) AS accepted, COALESCE(SUM(bytes),0) AS bytes, (SELECT COUNT(*) FROM log_objects WHERE state='archived') AS archived, (SELECT COUNT(*) FROM log_entries_pending) AS pending FROM usage_daily WHERE category='log'",
            vec![],
        )).await.unwrap().unwrap();
        assert_eq!(row.try_get::<i64>("", "accepted").unwrap(), 1);
        assert_eq!(row.try_get::<i64>("", "bytes").unwrap(), 154);
        assert_eq!(row.try_get::<i64>("", "archived").unwrap(), 1);
        assert_eq!(row.try_get::<i64>("", "pending").unwrap(), 0);
    }
    shutdown(&successor).await;
    successor_server.abort();
}
