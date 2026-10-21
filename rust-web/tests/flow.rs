mod support;

use std::{sync::atomic::Ordering, time::Duration};

use loco_rs::{app::Hooks, boot::BootResult};
use postdeploy::{
    runtime::Runtime,
    testing::{serve, TestApp, TestEnv},
};
use reqwest::StatusCode;
use sea_orm::ConnectionTrait;
use serde_json::{json, Value};
use support::*;

fn fast(settings: &mut Value) {
    settings["logs"]["batch_max_age_ms"] = json!(200);
    settings["logs"]["archive_tick_ms"] = json!(50);
}

async fn shutdown(boot: &BootResult) {
    TestApp::on_shutdown(&boot.app_context).await;
}

/// Signup through retrieval: real SDK error and logs, durable before 200,
/// grouped issue with payload from the object store, bounded search, replay
/// and live tail, logout. Shared by the memory and the R2 runs.
pub async fn vertical_flow(
    env: &TestEnv,
    boot: &BootResult,
    email: &str,
    marker: &str,
    password: &str,
) {
    let (base, _server) = serve(boot).await;
    let api = Api::signup_with_password(&base, email, password).await;
    let (org, _project, dsn) = api.setup_source("Acme").await;

    sdk_send(dsn.clone(), marker.to_owned()).await;

    let (status, issues) = api.get(&format!("/api/orgs/{org}/issues")).await;
    assert_eq!(status, StatusCode::OK);
    let issue = &issues["issues"][0];
    assert_eq!(
        issues["issues"].as_array().map_or(0, Vec::len),
        1,
        "one grouped issue"
    );
    assert_eq!(issue["event_count"], 1);
    assert_eq!(issue["environment"], "production");
    assert_eq!(issue["last_release"], "checkout@1.4.2");
    let issue_id = issue["id"].as_i64().unwrap();
    let (_, detail) = api.get(&format!("/api/orgs/{org}/issues/{issue_id}")).await;
    let event_id = detail["latest_event"]["event_id"]
        .as_str()
        .unwrap()
        .to_owned();
    let (status, event) = api
        .get(&format!(
            "/api/orgs/{org}/issues/{issue_id}/events/{event_id}"
        ))
        .await;
    assert_eq!(status, StatusCode::OK, "event payload status");
    let payload = &event["payload"];
    assert!(
        payload["exception"]["values"][0]["value"] == "card declined",
        "exception value stored"
    );
    let frames = payload["exception"]["values"][0]["stacktrace"]["frames"]
        .as_array()
        .or_else(|| payload["threads"]["values"][0]["stacktrace"]["frames"].as_array());
    assert!(
        frames.is_some_and(|f| !f.is_empty()),
        "stack frames in stored payload"
    );
    assert_eq!(payload["release"], "checkout@1.4.2");
    let crumbs = payload["breadcrumbs"]["values"].as_array().unwrap();
    assert!(
        crumbs.iter().any(|c| c["message"] == "checkout button"),
        "breadcrumb stored"
    );

    let (status, page) = api.get(&format!("/api/orgs/{org}/logs?q={marker}")).await;
    assert_eq!(status, StatusCode::OK);
    let bodies: Vec<&str> = page["rows"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["body"].as_str().unwrap())
        .collect();
    assert!(
        bodies.contains(&format!("checkout started {marker}").as_str()),
        "info log found by search"
    );
    assert!(
        bodies.contains(&format!("payment failed {marker}").as_str()),
        "error log found by search"
    );
    let (_, errors_only) = api
        .get(&format!("/api/orgs/{org}/logs?q={marker}&level=error"))
        .await;
    assert_eq!(errors_only["rows"].as_array().map_or(0, Vec::len), 1);
    assert_eq!(errors_only["rows"][0]["level"], "error");

    let replay = api
        .http
        .get(format!(
            "{base}/api/orgs/{org}/logs/tail?after=c1.0.4294967295"
        ))
        .header("cookie", api.cookie.clone().unwrap())
        .send()
        .await
        .unwrap();
    assert_eq!(replay.status(), StatusCode::OK);
    let events = read_sse(replay, Duration::from_secs(5), |name, data| {
        name == "entries"
            && data
                .to_string()
                .contains(&format!("payment failed {marker}"))
    })
    .await;
    assert!(
        events.iter().any(|(name, _)| name == "entries"),
        "replay delivered entries"
    );
    let resume = events.last().unwrap().1["cursor"]
        .as_str()
        .unwrap()
        .to_owned();

    let live = api
        .http
        .get(format!("{base}/api/orgs/{org}/logs/tail"))
        .header("cookie", api.cookie.clone().unwrap())
        .header("last-event-id", &resume)
        .send()
        .await
        .unwrap();
    assert_eq!(live.status(), StatusCode::OK);
    let second = format!("{marker}-live");
    let sender = tokio::spawn(sdk_send(dsn.clone(), second.clone()));
    let events = read_sse(live, Duration::from_secs(15), |name, data| {
        name == "entries"
            && data
                .to_string()
                .contains(&format!("payment failed {second}"))
    })
    .await;
    sender.await.unwrap();
    assert!(
        events.iter().any(|(_, data)| data
            .to_string()
            .contains(&format!("payment failed {second}"))),
        "live tail delivered the new log"
    );
    assert!(
        !events.iter().any(|(_, data)| data
            .to_string()
            .contains(&format!("checkout started {marker}\""))),
        "resumed tail replayed old rows"
    );

    let hits = file_contains(&env.dir, marker.as_bytes());
    assert!(
        hits.is_empty(),
        "log or event text found on local disk: {hits:?}"
    );

    let (status, _) = api.post("/api/auth/logout", json!({})).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let (status, _) = api.get(&format!("/api/orgs/{org}/issues")).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn vertical_flow_with_memory_store() {
    let env = TestEnv::new("vertical-memory");
    let boot = env.boot_memory(fast).await.unwrap();
    vertical_flow(
        &env,
        &boot,
        "owner-memory@example.test",
        "mk7f3a9memory",
        PASSWORD,
    )
    .await;
    shutdown(&boot).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "uses real R2: needs CREDSEAL_KEY_FILE and POSTDEPLOY_CREDENTIALS_FILE"]
async fn vertical_flow_with_r2() {
    let env = TestEnv::new("vertical-r2");
    let run = env
        .dir
        .parent()
        .unwrap()
        .file_name()
        .unwrap()
        .to_string_lossy()
        .to_lowercase();
    let prefix = format!(
        "local-verification/{}/",
        run.replace(|c: char| !c.is_ascii_alphanumeric() && c != '-', "-")
    );
    let boot = env.boot_r2(&prefix, fast).await.unwrap();
    let password = zeroize::Zeroizing::new(uuid::Uuid::new_v4().to_string());
    vertical_flow(
        &env,
        &boot,
        "owner-r2@example.test",
        "mk7f3a9rtwo",
        &password,
    )
    .await;
    let rt = Runtime::get(&boot.app_context);
    let counters = rt.store.counters();
    println!(
        "r2 prefix={prefix} puts={} put_bytes={} gets={} get_bytes={} lists={} failures={}",
        counters.puts.load(Ordering::Relaxed),
        counters.put_bytes.load(Ordering::Relaxed),
        counters.gets.load(Ordering::Relaxed),
        counters.get_bytes.load(Ordering::Relaxed),
        counters.lists.load(Ordering::Relaxed),
        counters.failures.load(Ordering::Relaxed),
    );
    shutdown(&boot).await;

    let again = env.boot_r2(&prefix, fast).await.unwrap();
    let (base, _server) = serve(&again).await;
    let mut api = Api::new(&base);
    let (status, _) = api.auth("login", "owner-r2@example.test", &password).await;
    assert_eq!(status, StatusCode::OK);
    let (_, orgs) = api.get("/api/orgs").await;
    let org = orgs["orgs"][0]["id"].as_str().unwrap().to_owned();
    let (_, page) = api
        .get(&format!("/api/orgs/{org}/logs?q=mk7f3a9rtwo"))
        .await;
    assert!(
        page["rows"].as_array().map_or(0, Vec::len) >= 4,
        "logs readable after restart"
    );
    shutdown(&again).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn organizations_are_isolated_and_dsn_keys_cannot_read() {
    let env = TestEnv::new("isolation");
    let boot = env.boot_memory(fast).await.unwrap();
    let (base, _server) = serve(&boot).await;
    let alice = Api::signup(&base, "alice@example.test").await;
    let bob = Api::signup(&base, "bob@example.test").await;
    let (org, project, dsn) = alice.setup_source("Alice Co").await;
    let key = dsn_key(&dsn);
    let (status, _) = post_envelope(
        &base,
        project,
        &key,
        envelope(Some("0123456789abcdef0123456789abcdef"), &["iso-log"]),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    for path in [
        format!("/api/orgs/{org}"),
        format!("/api/orgs/{org}/issues"),
        format!("/api/orgs/{org}/logs"),
        format!("/api/orgs/{org}/projects"),
    ] {
        let (status, _) = bob.get(&path).await;
        assert_eq!(status, StatusCode::NOT_FOUND, "bob read {path}");
    }
    let (status, _) = bob
        .post(&format!("/api/orgs/{org}/projects"), json!({"name": "x"}))
        .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (_, bob_orgs) = bob.get("/api/orgs").await;
    assert_eq!(bob_orgs["orgs"], json!([]));

    let anonymous = reqwest::Client::new();
    for path in [
        format!("/api/orgs/{org}/issues"),
        format!("/api/orgs/{org}/logs?q=iso"),
    ] {
        let response = anonymous
            .get(format!("{base}{path}"))
            .header("x-sentry-auth", format!("Sentry sentry_key={key}"))
            .send()
            .await
            .unwrap();
        assert_eq!(
            response.status(),
            StatusCode::UNAUTHORIZED,
            "dsn read {path}"
        );
        let joiner = if path.contains('?') { '&' } else { '?' };
        let response = anonymous
            .get(format!("{base}{path}{joiner}sentry_key={key}"))
            .send()
            .await
            .unwrap();
        assert_eq!(
            response.status(),
            StatusCode::UNAUTHORIZED,
            "dsn query read {path}"
        );
    }

    let mut forged = alice.clone();
    forged.csrf = Some("wrong".into());
    let (status, _) = forged
        .post(&format!("/api/orgs/{org}/projects"), json!({"name": "x"}))
        .await;
    assert_eq!(
        status,
        StatusCode::FORBIDDEN,
        "missing CSRF must be refused"
    );

    let (status, _) = alice
        .post(
            &format!("/api/orgs/{org}/members"),
            json!({"email": "bob@example.test", "role": "member"}),
        )
        .await;
    assert_eq!(status, StatusCode::CREATED);
    let (status, page) = bob.get(&format!("/api/orgs/{org}/logs?q=iso-log")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(page["rows"].as_array().map_or(0, Vec::len), 1);
    let (status, _) = bob
        .post(&format!("/api/orgs/{org}/projects"), json!({"name": "x"}))
        .await;
    assert_eq!(
        status,
        StatusCode::FORBIDDEN,
        "members cannot manage projects"
    );
    let bob_id = bob.get("/api/auth/session").await.1["user"]["id"]
        .as_i64()
        .unwrap();
    let (status, _) = alice
        .send(
            reqwest::Method::DELETE,
            &format!("/api/orgs/{org}/members/{bob_id}"),
            None,
        )
        .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let (status, _) = bob.get(&format!("/api/orgs/{org}/issues")).await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    let (bob_org, _, _) = bob.setup_source("Bob Co").await;
    let (status, _) = alice.get(&format!("/api/orgs/{bob_org}/issues")).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (status, _) = post_envelope(&base, project + 1, &key, envelope(None, &["x"]), None).await;
    assert_eq!(
        status,
        StatusCode::FORBIDDEN,
        "key used with another project"
    );
    shutdown(&boot).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn ingestion_rejects_bad_requests_with_fixed_codes() {
    let env = TestEnv::new("ingest-limits");
    let boot = env.boot_memory(fast).await.unwrap();
    let (base, _server) = serve(&boot).await;
    let api = Api::signup(&base, "limits@example.test").await;
    let (org, project, dsn) = api.setup_source("Limits").await;
    let key = dsn_key(&dsn);

    let (status, body) = post_envelope(
        &base,
        project,
        "00000000000000000000000000000000",
        envelope(None, &["x"]),
        None,
    )
    .await;
    assert_eq!(
        (status, body),
        (
            StatusCode::UNAUTHORIZED,
            json!({"error": "invalid_api_key"})
        )
    );
    let (status, _) = post_envelope(&base, project, &key, vec![b'x'; (1 << 20) + 1], None).await;
    assert_eq!(status, StatusCode::PAYLOAD_TOO_LARGE);
    let (status, _) = post_envelope(&base, project, &key, envelope(None, &["x"]), Some("br")).await;
    assert_eq!(status, StatusCode::UNSUPPORTED_MEDIA_TYPE);
    let (status, body) =
        post_envelope(&base, project, &key, b"not an envelope".to_vec(), None).await;
    assert_eq!(
        (status, body),
        (
            StatusCode::BAD_REQUEST,
            json!({"error": "invalid_envelope"})
        )
    );

    use std::io::Write;
    let mut gz = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
    gz.write_all(&vec![b' '; 5 << 20]).unwrap();
    let (status, _) = post_envelope(&base, project, &key, gz.finish().unwrap(), Some("gzip")).await;
    assert_eq!(
        status,
        StatusCode::PAYLOAD_TOO_LARGE,
        "inflated body over the limit"
    );

    let mut gz = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
    gz.write_all(&envelope(None, &["gzip-log"])).unwrap();
    let mut body = gz.finish().unwrap();
    let mixed = [
        b"{}\n{\"type\":\"session\"}\n{\"sid\":\"x\"}\n{\"type\":\"transaction\"}\n{}\n".to_vec(),
    ];
    let (status, _) = post_envelope(&base, project, &key, body.clone(), Some("gzip")).await;
    assert_eq!(status, StatusCode::OK, "gzip envelope accepted");
    let (status, reply) = post_envelope(&base, project, &key, mixed[0].clone(), None).await;
    assert_eq!(
        (status, reply["receipt"]["other"].clone()),
        (
            StatusCode::OK,
            json!({"accepted": 0, "duplicate": 0, "filtered": 0, "sampled": 0, "unsupported": 2,
                "invalid": 0, "reasons": {"unsupported_item_type": 2}})
        )
    );
    body.truncate(body.len() - 12);
    let (status, _) = post_envelope(&base, project, &key, body, Some("gzip")).await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "truncated gzip");
    let (_, page) = api.get(&format!("/api/orgs/{org}/logs?q=gzip-log")).await;
    assert_eq!(page["rows"].as_array().map_or(0, Vec::len), 1);
    shutdown(&boot).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn restart_keeps_acknowledged_logs_and_expiry_hides_and_deletes_them() {
    let env = TestEnv::new("restart-expiry");
    let short = |s: &mut Value| {
        fast(s);
        s["logs"]["retention_secs"] = json!(3);
    };
    let boot = env.boot_memory(short).await.unwrap();
    let (base, server) = serve(&boot).await;
    let api = Api::signup(&base, "restart@example.test").await;
    let (org, project, dsn) = api.setup_source("Restart").await;
    let key = dsn_key(&dsn);
    let (status, _) = post_envelope(
        &base,
        project,
        &key,
        envelope(None, &["before-restart"]),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    env.faults.fail_puts.store(u32::MAX, Ordering::SeqCst);
    let (status, _) = post_envelope(
        &base,
        project,
        &key,
        envelope(None, &["unarchived-at-shutdown"]),
        None,
    )
    .await;
    assert_eq!(
        status,
        StatusCode::OK,
        "acknowledged from SQLite during an R2 outage"
    );
    shutdown(&boot).await;
    server.abort();
    drop(boot);

    env.faults.fail_puts.store(0, Ordering::SeqCst);
    let boot = env.boot_memory(short).await.unwrap();
    let (base, _server) = serve(&boot).await;
    let mut api = Api::new(&base);
    assert_eq!(
        api.auth("login", "restart@example.test", PASSWORD).await.0,
        StatusCode::OK
    );
    let api2 = api.clone();
    let org2 = org.clone();
    eventually(Duration::from_secs(5), || {
        let api = api2.clone();
        let org = org2.clone();
        async move {
            let (_, page) = api.get(&format!("/api/orgs/{org}/logs?q=-")).await;
            page["rows"].as_array().is_some_and(|rows| rows.len() == 2)
        }
    })
    .await;

    tokio::time::sleep(Duration::from_secs(4)).await;
    let (_, page) = api.get(&format!("/api/orgs/{org}/logs")).await;
    assert!(
        page["rows"].as_array().is_some_and(Vec::is_empty),
        "expired entries are not readable"
    );
    let replay = api
        .http
        .get(format!(
            "{base}/api/orgs/{org}/logs/tail?after=c1.0.4294967295"
        ))
        .header("cookie", api.cookie.clone().unwrap())
        .send()
        .await
        .unwrap();
    let events = read_sse(replay, Duration::from_secs(3), |name, _| name == "gap").await;
    assert_eq!(
        events
            .first()
            .map(|(n, d)| (n.as_str(), d["reason"].clone())),
        Some(("gap", json!("expired"))),
        "first replay event is an expired gap"
    );
    assert!(
        !events.iter().any(|(name, _)| name == "entries"),
        "expired rows replayed"
    );

    let rt = Runtime::get(&boot.app_context);
    let parsed: postdeploy::domain::OrgId = org.parse().unwrap();
    postdeploy::logs::retention::sweep_org(&rt, &parsed)
        .await
        .unwrap();
    let tenant = rt.tenant(&parsed).await.unwrap();
    let left = tenant
        .query_one_raw(postdeploy::runtime::sql(
            "SELECT (SELECT COUNT(*) FROM log_objects) + (SELECT COUNT(*) FROM log_entries_pending) AS n",
            vec![],
        ))
        .await
        .unwrap()
        .unwrap()
        .try_get::<i64>("", "n")
        .unwrap();
    drop(tenant);
    assert_eq!(left, 0, "expired batches and pending entries are deleted");
    assert!(env
        .store
        .list_page("logs/", None, 10)
        .await
        .unwrap()
        .keys
        .is_empty());
    shutdown(&boot).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn second_process_on_the_same_tenant_root_is_refused() {
    let env = TestEnv::new("root-lock");
    let first = env.boot_memory(fast).await.unwrap();
    let error = env
        .boot_memory(fast)
        .await
        .err()
        .expect("second boot must fail")
        .to_string();
    assert!(
        error.contains("owned by another running process"),
        "{error}"
    );
    let (base, _server) = serve(&first).await;
    let response = reqwest::get(format!("{base}/healthz")).await.unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let api = Api::signup(&base, "lock@example.test").await;
    api.setup_source("Lock").await;
    shutdown(&first).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn every_pooled_connection_uses_full_synchronous_mode() {
    use sea_orm::{ConnectionTrait, TransactionTrait};
    let env = TestEnv::new("pragmas");
    let boot = env.boot_memory(fast).await.unwrap();
    let (base, _server) = serve(&boot).await;
    let api = Api::signup(&base, "pragma@example.test").await;
    let (org, _, _) = api.setup_source("Pragma").await;
    let rt = Runtime::get(&boot.app_context);
    let pragma = |sql: &'static str| postdeploy::runtime::sql(sql, vec![]);

    let held = rt.control.begin().await.unwrap();
    let a: i32 = held
        .query_one_raw(pragma("PRAGMA synchronous"))
        .await
        .unwrap()
        .unwrap()
        .try_get_by_index(0)
        .unwrap();
    let b: i32 = rt
        .control
        .query_one_raw(pragma("PRAGMA synchronous"))
        .await
        .unwrap()
        .unwrap()
        .try_get_by_index(0)
        .unwrap();
    held.commit().await.unwrap();
    assert_eq!((a, b), (2, 2), "control connections");

    let org: postdeploy::domain::OrgId = org.parse().unwrap();
    let first = rt.tenant(&org).await.unwrap();
    let txn = first.begin().await.unwrap();
    let a: i32 = txn
        .query_one_raw(pragma("PRAGMA synchronous"))
        .await
        .unwrap()
        .unwrap()
        .try_get_by_index(0)
        .unwrap();
    let second = rt.tenant(&org).await.unwrap();
    let b: i32 = second
        .query_one_raw(pragma("PRAGMA synchronous"))
        .await
        .unwrap()
        .unwrap()
        .try_get_by_index(0)
        .unwrap();
    let version: String = second
        .query_one_raw(pragma("SELECT sqlite_version()"))
        .await
        .unwrap()
        .unwrap()
        .try_get_by_index(0)
        .unwrap();
    txn.commit().await.unwrap();
    drop((first, second));
    assert_eq!((a, b), (2, 2), "tenant connections");
    assert_eq!(version, "3.51.3");
    shutdown(&boot).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn error_ingest_stores_payloads_in_r2_and_refuses_with_503_while_r2_is_unreachable() {
    let env = TestEnv::new("error-ingest-r2-outage");
    let boot = env.boot_memory(fast).await.unwrap();
    let (base, _server) = serve(&boot).await;
    let api = Api::signup(&base, "r2-outage@example.test").await;
    let (org, project, dsn) = api.setup_source("Outage").await;
    let key = dsn_key(&dsn);
    let rt = Runtime::get(&boot.app_context);
    assert!(env.tenant_root().join(format!("{org}.db")).is_file());
    let payloads = || async {
        rt.store
            .list_page(&format!("errors/v1/{org}/"), None, 10)
            .await
            .unwrap()
            .keys
    };
    let used_errors = || async {
        let (status, usage) = api.get(&format!("/api/orgs/{org}/usage")).await;
        assert_eq!(status, StatusCode::OK);
        usage["errors"]["used"].clone()
    };

    env.faults.fail_puts.store(u32::MAX, Ordering::SeqCst);
    let refused_id = "0123456789abcdef0123456789abcdef";
    let (status, body) =
        post_envelope(&base, project, &key, envelope(Some(refused_id), &[]), None).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body, json!({"error": "ingest_unavailable"}));
    let (_, issues) = api.get(&format!("/api/orgs/{org}/issues")).await;
    assert_eq!(issues["issues"], json!([]));
    assert_eq!(used_errors().await, json!(0));
    assert_eq!(payloads().await, Vec::<String>::new());

    env.faults.fail_puts.store(0, Ordering::SeqCst);
    let (status, body) =
        post_envelope(&base, project, &key, envelope(Some(refused_id), &[]), None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, accepted(Some(refused_id), 1, 0));
    let (_, issues) = api.get(&format!("/api/orgs/{org}/issues")).await;
    assert_eq!(issues["issues"].as_array().unwrap().len(), 1, "{issues}");
    assert_eq!(used_errors().await, json!(1));
    let stored = payloads().await;
    assert_eq!(stored.len(), 1, "{stored:?}");
    assert!(
        stored[0].contains(&format!("/{refused_id}-")) && stored[0].ends_with(".json.zst"),
        "{stored:?}"
    );
    shutdown(&boot).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn slow_compressed_error_uploads_do_not_refuse_a_small_log_envelope() {
    use std::io::Write;
    let gzip = |body: Vec<u8>| {
        let mut gz = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
        gz.write_all(&body).unwrap();
        gz.finish().unwrap()
    };
    let env = TestEnv::new("ingest-body-budget");
    let boot = env.boot_memory(|_| {}).await.unwrap();
    let (base, server) = serve(&boot).await;
    let api = Api::signup(&base, "body-budget@example.test").await;
    let (_org, project, dsn) = api.setup_source("Budget").await;
    let key = dsn_key(&dsn);

    env.faults.delay_put_ms.store(3_000, Ordering::SeqCst);
    let errors: Vec<_> = (0..16)
        .map(|index| {
            let (base, key) = (base.clone(), key.clone());
            let body = gzip(envelope(Some(&format!("{:032x}", 0x6000 + index)), &[]));
            tokio::spawn(async move {
                post_envelope(&base, project, &key, body, Some("gzip"))
                    .await
                    .0
            })
        })
        .collect();
    eventually(Duration::from_secs(5), || async {
        env.faults.delayed_puts.load(Ordering::SeqCst) == 16
    })
    .await;

    let log = post_envelope(
        &base,
        project,
        &key,
        gzip(envelope(None, &["budgetlog"])),
        Some("gzip"),
    )
    .await;
    assert_eq!(
        log,
        (StatusCode::OK, accepted(None, 0, 1)),
        "a small log envelope is accepted while 16 error uploads are slow"
    );
    for error in errors {
        assert_eq!(error.await.unwrap(), StatusCode::OK);
    }
    env.faults.delay_put_ms.store(0, Ordering::SeqCst);
    server.abort();
    shutdown(&boot).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_slow_request_holds_body_budget_for_its_inflated_bytes() {
    use std::io::Write;
    let gzip = |body: Vec<u8>| {
        let mut gz = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
        gz.write_all(&body).unwrap();
        gz.finish().unwrap()
    };
    let env = TestEnv::new("ingest-body-budget-held");
    let boot = env
        .boot_memory(|s| s["ingest"]["body_budget_bytes"] = json!(4 << 20))
        .await
        .unwrap();
    let (base, server) = serve(&boot).await;
    let api = Api::signup(&base, "body-budget-held@example.test").await;
    let (_org, project, dsn) = api.setup_source("Held").await;
    let key = dsn_key(&dsn);

    let mut large = format!("{}\n", json!({"event_id": null}));
    for index in 0..3 {
        let event = json!({"event_id": format!("{:032x}", 0x7000 + index), "level": "error",
            "extra": {"pad": "x".repeat(900_000)},
            "exception": {"values": [{"type": "Boom", "value": "large"}]}});
        large.push_str(&format!("{}\n{event}\n", json!({"type": "event"})));
    }
    env.faults.delay_put_ms.store(3_000, Ordering::SeqCst);
    let slow = {
        let (base, key, body) = (base.clone(), key.clone(), gzip(large.into_bytes()));
        tokio::spawn(async move {
            post_envelope(&base, project, &key, body, Some("gzip"))
                .await
                .0
        })
    };
    eventually(Duration::from_secs(5), || async {
        env.faults.delayed_puts.load(Ordering::SeqCst) == 1
    })
    .await;

    assert_eq!(
        post_envelope(
            &base,
            project,
            &key,
            gzip(envelope(None, &["heldgzip"])),
            Some("gzip")
        )
        .await,
        (
            StatusCode::SERVICE_UNAVAILABLE,
            json!({"error": "ingest_overloaded"})
        ),
        "2.7 MB stay reserved, so a 4 MiB inflation reservation does not fit"
    );
    assert_eq!(
        post_envelope(&base, project, &key, envelope(None, &["heldplain"]), None).await,
        (StatusCode::OK, accepted(None, 0, 1)),
        "an uncompressed envelope reserves its declared length"
    );
    assert_eq!(slow.await.unwrap(), StatusCode::OK);
    env.faults.delay_put_ms.store(0, Ordering::SeqCst);
    server.abort();
    shutdown(&boot).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_retried_mixed_envelope_stores_its_logs_once() {
    let env = TestEnv::new("mixed-envelope-retry");
    let boot = env.boot_memory(|_| {}).await.unwrap();
    let (base, server) = serve(&boot).await;
    let api = Api::signup(&base, "mixed@example.test").await;
    let (org, project, dsn) = api.setup_source("Mixed").await;
    let key = dsn_key(&dsn);
    let body = envelope(Some("40000000000000000000000000000001"), &["mixedretrylog"]);
    env.faults.fail_puts.store(1, Ordering::SeqCst);
    let first = post_envelope(&base, project, &key, body.clone(), None).await;
    assert_eq!(
        first,
        (
            StatusCode::SERVICE_UNAVAILABLE,
            json!({"error": "ingest_unavailable"})
        )
    );
    let (status, _) = post_envelope(&base, project, &key, body, None).await;
    assert_eq!(status, StatusCode::OK);
    let (_, page) = api
        .get(&format!("/api/orgs/{org}/logs?q=mixedretrylog"))
        .await;
    assert_eq!(page["rows"].as_array().map_or(0, Vec::len), 1);
    let (_, issues) = api.get(&format!("/api/orgs/{org}/issues")).await;
    assert_eq!(issues["issues"][0]["event_count"], json!(1));
    server.abort();
    shutdown(&boot).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_error_timestamp_far_in_the_future_is_stored_as_receive_time() {
    let env = TestEnv::new("error-future-timestamp");
    let boot = env.boot_memory(|_| {}).await.unwrap();
    let (base, server) = serve(&boot).await;
    let api = Api::signup(&base, "future@example.test").await;
    let (org, project, dsn) = api.setup_source("Future").await;
    let key = dsn_key(&dsn);
    let event = json!({"event_id": "50000000000000000000000000000001", "level": "error",
        "timestamp": 4102444800_i64,
        "exception": {"values": [{"type": "Boom", "value": "from the future"}]}});
    let body = format!(
        "{}\n{}\n{}\n",
        json!({"event_id": "50000000000000000000000000000001"}),
        json!({"type": "event"}),
        event
    );
    let (status, _) = post_envelope(&base, project, &key, body.into_bytes(), None).await;
    assert_eq!(status, StatusCode::OK);
    let (_, events) = api.get(&format!("/api/orgs/{org}/issues/1/events")).await;
    let event = &events["events"][0];
    assert_eq!(event["occurred_at"], event["received_at"]);
    server.abort();
    shutdown(&boot).await;
}
