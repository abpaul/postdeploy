mod support;

use loco_rs::boot::BootResult;
use postdeploy::{
    runtime::Runtime,
    testing::{serve, TestApp, TestEnv},
};
use reqwest::StatusCode;
use serde_json::{json, Value};
use support::*;

const FAKE: &str = "syntheticprivacymarker20261016";

async fn shutdown(boot: &BootResult) {
    <TestApp as loco_rs::app::Hooks>::on_shutdown(&boot.app_context).await;
}

fn raw_envelope(event_id: Option<&str>, event: Option<&Value>, logs: &[Value]) -> Vec<u8> {
    let mut out = format!("{}\n", json!({"event_id": event_id}));
    if let Some(event) = event {
        out.push_str(&format!("{}\n{event}\n", json!({"type": "event"})));
    }
    if !logs.is_empty() {
        out.push_str(&format!(
            "{}\n{}\n",
            json!({"type": "log"}),
            json!({"items": logs})
        ));
    }
    out.into_bytes()
}

fn connection_url(secret: &str) -> String {
    format!("postgresql://probe-user:{secret}@example.invalid/probe-db")
}

fn leaky_event(event_id: &str, secret: &str) -> Value {
    json!({
        "event_id": event_id,
        "message": format!("connect {} failed", connection_url(secret)),
        "request": {
            "headers": [["Authorization", secret], ["Cookie", secret], ["X-Api-Key", secret],
                        ["Accept", "application/json"], ["X-Request-Id", "probe-request-1"]],
            "url": format!("https://example.invalid/path?%74oken={secret}&page=2"),
            "query_string": [["token", secret], ["page", "2"]],
            "cookies": [["sessionid", secret], ["theme", "dark"]],
            "env": {"REMOTE_ADDR": "192.0.2.1"}
        },
        "tags": [["api_key", secret], ["region", "eu"]],
        "user": {"ip_address": "192.0.2.1", "email": "fake-user@example.invalid"},
        "extra": {
            "password": secret,
            "customer_email": "fake-user@example.invalid",
            "connection_url": connection_url(secret),
            "callback_url": format!("https://example.invalid/cb?session_id={secret}&page=2"),
            "form": format!("session_id={secret}&page=2"),
            "fragment": format!("https://example.invalid/cb#access_token={secret}&state=ok"),
            "user_only": format!("https://{secret}@example.invalid/repo"),
            "set": {"Set-Cookie": [secret, secret]}
        }
    })
}

fn leaky_log(secret: &str) -> Value {
    json!({
        "level": "info",
        "body": format!("dial {}", connection_url(secret)),
        "attributes": {
            "request_id": {"type": "string", "value": "probe-request-attr"},
            "authorization": {"type": "string", "value": secret},
            "customer_email": {"type": "string", "value": "fake-user@example.invalid"},
            "db.connection_url": {"type": "string", "value": connection_url(secret)},
            "url.full": {"type": "string", "value": format!("https://example.invalid/a?%74oken={secret}&page=2")},
            "http.request.header.cookie": {"type": "array", "value": [secret]}
        }
    })
}

/// Every object in the store, decompressed when it is zstd, as text.
async fn stored_object_text(rt: &Runtime) -> String {
    let keys = rt.store.list_page("", None, 1_000).await.unwrap().keys;
    let mut text = String::new();
    for key in keys {
        let body = rt.store.get(&key, 64 << 20).await.unwrap().unwrap();
        let raw = zstd::stream::decode_all(&body[..]).unwrap_or_else(|_| body.to_vec());
        text.push_str(&String::from_utf8_lossy(&raw));
        text.push('\n');
    }
    text
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn persisted_errors_and_logs_redact_pairs_urls_and_queries_before_metadata() {
    let env = TestEnv::new("privacy-persisted-redaction");
    let boot = env.boot_memory(fast_archive).await.unwrap();
    let (base, _server) = serve(&boot).await;
    let api = Api::signup(&base, "privacy-redaction@example.test").await;
    let (org, project, dsn) = api.setup_source("Privacy").await;
    let event_id = "0123456789abcdef0123456789abcdef";
    let body = raw_envelope(
        Some(event_id),
        Some(&leaky_event(event_id, FAKE)),
        &[leaky_log(FAKE)],
    );
    let (status, _) = post_envelope(&base, project, &dsn_key(&dsn), body, None).await;
    assert_eq!(status, StatusCode::OK);

    let (_, issues) = api.get(&format!("/api/orgs/{org}/issues")).await;
    let issue = &issues["issues"][0];
    assert_eq!(
        issue["title"],
        "connect postgresql://probe-user:[Filtered]@example.invalid/probe-db failed"
    );
    let issue_id = issue["id"].as_i64().unwrap();
    let (status, stored) = api
        .get(&format!(
            "/api/orgs/{org}/issues/{issue_id}/events/{event_id}"
        ))
        .await;
    assert_eq!(status, StatusCode::OK);
    let payload = &stored["payload"];
    assert_eq!(
        payload["request"],
        json!({
            "headers": [["Authorization", "[Filtered]"], ["Cookie", "[Filtered]"],
                        ["X-Api-Key", "[Filtered]"], ["Accept", "application/json"],
                        ["X-Request-Id", "probe-request-1"]],
            "url": "https://example.invalid/path?%74oken=[Filtered]&page=2",
            "query_string": [["token", "[Filtered]"], ["page", "2"]],
            "cookies": "[Filtered]",
            "env": {"REMOTE_ADDR": "192.0.2.1"}
        })
    );
    assert_eq!(
        payload["tags"],
        json!([["api_key", "[Filtered]"], ["region", "eu"]])
    );
    assert_eq!(
        payload["user"],
        json!({"email": "fake-user@example.invalid"})
    );
    assert_eq!(
        payload["extra"],
        json!({
            "password": "[Filtered]",
            "customer_email": "fake-user@example.invalid",
            "connection_url": "postgresql://probe-user:[Filtered]@example.invalid/probe-db",
            "callback_url": "https://example.invalid/cb?session_id=[Filtered]&page=2",
            "form": "session_id=[Filtered]&page=2",
            "fragment": "https://example.invalid/cb#access_token=[Filtered]&state=ok",
            "user_only": "https://[Filtered]@example.invalid/repo",
            "set": {"Set-Cookie": "[Filtered]"}
        })
    );
    let (_, summary) = api.get(&format!("/api/orgs/{org}/issues/{issue_id}")).await;
    assert_eq!(summary["latest_event"]["request_id"], "probe-request-1");

    wait_archived(&api, &org).await;
    let (status, logs) = api
        .get(&format!("/api/orgs/{org}/logs?project={project}&limit=5"))
        .await;
    assert_eq!(status, StatusCode::OK);
    let row = &logs["rows"][0];
    assert_eq!(
        row["body"],
        "dial postgresql://probe-user:[Filtered]@example.invalid/probe-db"
    );
    assert_eq!(
        row["attributes"],
        json!({
            "request_id": {"type": "string", "value": "probe-request-attr"},
            "authorization": {"type": "string", "value": "[Filtered]"},
            "customer_email": {"type": "string", "value": "fake-user@example.invalid"},
            "db.connection_url": {"type": "string", "value": "postgresql://probe-user:[Filtered]@example.invalid/probe-db"},
            "url.full": {"type": "string", "value": "https://example.invalid/a?%74oken=[Filtered]&page=2"},
            "http.request.header.cookie": {"type": "string", "value": "[Filtered]"}
        })
    );

    let rt = Runtime::get(&boot.app_context);
    let objects = stored_object_text(&rt).await;
    assert!(
        objects.contains("probe-request-1"),
        "the error object was read"
    );
    assert!(
        objects.contains("probe-request-attr"),
        "the log object was read"
    );
    assert!(
        !objects.contains(FAKE),
        "a stored object holds the fake secret"
    );
    shutdown(&boot).await;
    assert_eq!(
        file_contains(&env.dir, FAKE.as_bytes()),
        Vec::<String>::new(),
        "SQLite, WAL or temporary files hold the fake secret"
    );
}

const KILL_CHILD_NAME: &str = "POSTDEPLOY_PRIVACY_KILL_CHILD";
const KILL_CHILD_READY: &str = "POSTDEPLOY_PRIVACY_KILL_READY";

fn quiet_batches(settings: &mut Value) {
    settings["logs"]["batch_max_age_ms"] = json!(600_000);
    settings["logs"]["archive_tick_ms"] = json!(50);
}

struct OwnedChild(std::process::Child);

impl Drop for OwnedChild {
    fn drop(&mut self) {
        if self.0.try_wait().ok().flatten().is_none() {
            let _ = self.0.kill();
        }
        let _ = self.0.wait();
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "internal kill child; launched by acknowledged_redacted_logs_survive_kill_without_plaintext_secrets"]
async fn privacy_kill_child() {
    let name = std::env::var(KILL_CHILD_NAME).expect("parent supplies child identity");
    let ready = std::path::PathBuf::from(std::env::var_os(KILL_CHILD_READY).unwrap());
    let env = TestEnv::new(&name);
    let boot = env.boot_memory(quiet_batches).await.unwrap();
    let (base, _server) = serve(&boot).await;
    let api = Api::signup(&base, &format!("{name}@example.test")).await;
    let (org, project, dsn) = api.setup_source("Kill with secrets").await;
    let event_id = "0123456789abcdef0123456789abcdee";
    let body = raw_envelope(
        Some(event_id),
        Some(&leaky_event(event_id, FAKE)),
        &[leaky_log(FAKE)],
    );
    let (status, _) = post_envelope(&base, project, &dsn_key(&dsn), body, None).await;
    assert_eq!(status, StatusCode::OK, "acknowledged");
    let (_, storage) = api.get(&format!("/api/orgs/{org}/logs/storage")).await;
    assert_eq!(storage["pending_entries"], 1, "the log is still pending");
    let objects = stored_object_text(&Runtime::get(&boot.app_context)).await;
    let report = json!({
        "org": org,
        "error_object_redacted": objects.contains("probe-user:[Filtered]@example.invalid"),
        "error_object_has_secret": objects.contains(FAKE),
    });
    let temporary = ready.with_extension("tmp");
    std::fs::write(&temporary, report.to_string()).unwrap();
    std::fs::rename(temporary, ready).unwrap();
    std::future::pending::<()>().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn acknowledged_redacted_logs_survive_kill_without_plaintext_secrets() {
    let name = format!("privacy-kill-{}", uuid::Uuid::now_v7().simple());
    let env = TestEnv::new(&name);
    let ready = env.dir.join("child.ready");
    let log = std::fs::File::create(env.dir.join("child.log")).unwrap();
    let run = env.dir.parent().unwrap();
    let mut child = OwnedChild(
        std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "privacy_kill_child",
                "--ignored",
                "--nocapture",
                "--test-threads=1",
            ])
            .env(KILL_CHILD_NAME, &name)
            .env(KILL_CHILD_READY, &ready)
            .env("POSTDEPLOY_TEST_ROOT", run.parent().unwrap())
            .env("POSTDEPLOY_TEST_RUN", run.file_name().unwrap())
            .stdout(log.try_clone().unwrap())
            .stderr(log)
            .spawn()
            .unwrap(),
    );
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(120);
    while !ready.exists() {
        assert!(
            child.0.try_wait().unwrap().is_none(),
            "child exited early; see child.log"
        );
        assert!(
            std::time::Instant::now() < deadline,
            "child timed out; see child.log"
        );
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    let report: Value = serde_json::from_str(&std::fs::read_to_string(&ready).unwrap()).unwrap();
    child.0.kill().unwrap();
    let status = child.0.wait().unwrap();
    assert_eq!(
        std::os::unix::process::ExitStatusExt::signal(&status),
        Some(9)
    );
    assert_eq!(
        (
            report["error_object_redacted"].clone(),
            report["error_object_has_secret"].clone()
        ),
        (json!(true), json!(false)),
        "the archived error body before the kill"
    );
    assert_eq!(
        file_contains(&env.dir, FAKE.as_bytes()),
        Vec::<String>::new(),
        "SQLite, WAL or temporary files hold the fake secret after the kill"
    );

    let boot = env.boot_memory(fast_archive).await.unwrap();
    let (base, _server) = serve(&boot).await;
    let org = report["org"].as_str().unwrap().to_owned();
    let mut api = Api::new(&base);
    assert_eq!(
        api.auth("login", &format!("{name}@example.test"), PASSWORD)
            .await
            .0,
        StatusCode::OK
    );
    wait_archived(&api, &org).await;
    let rt = Runtime::get(&boot.app_context);
    let keys = rt.store.list_page("logs/", None, 10).await.unwrap().keys;
    assert_eq!(keys.len(), 1);
    let records = stored_records(&rt.store.get(&keys[0], 4 << 20).await.unwrap().unwrap());
    assert_eq!(
        records
            .iter()
            .map(|record| (
                record.body.as_str().to_owned(),
                record
                    .attributes
                    .get_str("db.connection_url")
                    .map(str::to_owned),
                record
                    .attributes
                    .get_str("authorization")
                    .map(str::to_owned),
            ))
            .collect::<Vec<_>>(),
        [(
            "dial postgresql://probe-user:[Filtered]@example.invalid/probe-db".to_owned(),
            Some("postgresql://probe-user:[Filtered]@example.invalid/probe-db".to_owned()),
            Some("[Filtered]".to_owned()),
        )],
        "the log archived after restart was redacted before it was acknowledged"
    );
    assert!(!stored_object_text(&rt).await.contains(FAKE));
    let (status, page) = api.get(&format!("/api/orgs/{org}/logs?limit=5")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        page["rows"][0]["attributes"]["url.full"]["value"],
        "https://example.invalid/a?%74oken=[Filtered]&page=2"
    );
    shutdown(&boot).await;
    assert_eq!(
        file_contains(&env.dir, FAKE.as_bytes()),
        Vec::<String>::new(),
        "SQLite, WAL or temporary files hold the fake secret after archiving"
    );
}

fn default_policy() -> Value {
    json!({
        "sensitive_fields": [],
        "log_levels": ["trace", "debug", "info", "warn", "error", "fatal"],
        "excluded_exception_types": [],
        "error_sample_percent": 100,
        "log_sample_percent": 100
    })
}

async fn put_policy(api: &Api, org: &str, policy: Value) -> (StatusCode, Value) {
    api.send(
        reqwest::Method::PUT,
        &format!("/api/orgs/{org}/ingestion-policy"),
        Some(policy),
    )
    .await
}

async fn bearer_send(
    base: &str,
    token: &str,
    method: reqwest::Method,
    path: &str,
    body: Option<Value>,
) -> (StatusCode, Value) {
    let mut request = reqwest::Client::new()
        .request(method, format!("{base}{path}"))
        .bearer_auth(token);
    if let Some(body) = body {
        request = request.json(&body);
    }
    let response = request.send().await.unwrap();
    let status = response.status();
    (status, response.json().await.unwrap_or(Value::Null))
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn ingestion_policy_is_managed_by_session_and_inspected_by_read_only_agents() {
    let env = TestEnv::new("privacy-policy-api");
    let boot = env.boot_memory(|_| {}).await.unwrap();
    let (base, _server) = serve(&boot).await;
    let owner = Api::signup(&base, "policy-owner@example.test").await;
    let (org, _project, _dsn) = owner.setup_source("Policy").await;
    let path = format!("/api/orgs/{org}/ingestion-policy");

    assert_eq!(
        owner.get(&path).await,
        (
            StatusCode::OK,
            json!({"policy": default_policy(), "updated_at": null})
        )
    );

    let mut no_csrf = owner.clone();
    no_csrf.csrf = None;
    assert_eq!(
        put_policy(&no_csrf, &org, default_policy()).await.0,
        StatusCode::FORBIDDEN
    );

    let with = |key: &str, value: Value| {
        let mut policy = default_policy();
        policy[key] = value;
        policy
    };
    let mut unknown = default_policy();
    unknown["regex"] = json!(".*");
    let mut missing = default_policy();
    missing
        .as_object_mut()
        .unwrap()
        .remove("log_sample_percent");
    for invalid in [
        unknown,
        missing,
        with("error_sample_percent", json!(101)),
        with("log_sample_percent", json!(-1)),
        with("sensitive_fields", json!(["ab"])),
        with("sensitive_fields", json!(["has space"])),
        with("sensitive_fields", json!(["_id"])),
        with("sensitive_fields", json!(["Value"])),
        with(
            "sensitive_fields",
            json!((0..33).map(|i| format!("field_{i}")).collect::<Vec<_>>()),
        ),
        with("log_levels", json!(["verbose"])),
        with("excluded_exception_types", json!([""])),
        with("excluded_exception_types", json!(["x".repeat(129)])),
    ] {
        assert_eq!(
            put_policy(&owner, &org, invalid.clone()).await,
            (
                StatusCode::BAD_REQUEST,
                json!({"error": "invalid_ingestion_policy"})
            ),
            "{invalid}"
        );
    }

    let configured = json!({
        "sensitive_fields": ["Customer-SSN", "customer_ssn", "loyalty.number"],
        "log_levels": ["warning", "error", "fatal", "error"],
        "excluded_exception_types": [" NotFoundError ", "NotFoundError"],
        "error_sample_percent": 25,
        "log_sample_percent": 0
    });
    let normalized = json!({
        "sensitive_fields": ["customer_ssn", "loyalty.number"],
        "log_levels": ["warn", "error", "fatal"],
        "excluded_exception_types": ["NotFoundError"],
        "error_sample_percent": 25,
        "log_sample_percent": 0
    });
    let (status, saved) = put_policy(&owner, &org, configured).await;
    assert_eq!(
        (status, saved["policy"].clone()),
        (StatusCode::OK, normalized.clone())
    );
    assert!(saved["updated_at"].as_i64().is_some());
    assert_eq!(owner.get(&path).await.1["policy"], normalized);

    let member = Api::signup(&base, "policy-member@example.test").await;
    let (status, _) = owner
        .post(
            &format!("/api/orgs/{org}/members"),
            json!({"email": "policy-member@example.test", "role": "member"}),
        )
        .await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(member.get(&path).await.1["policy"], normalized);
    assert_eq!(
        put_policy(&member, &org, default_policy()).await,
        (StatusCode::FORBIDDEN, json!({"error": "forbidden"}))
    );

    let (status, key) = owner
        .post(
            &format!("/api/orgs/{org}/api-keys"),
            json!({"name": "reader", "scopes": ["issues:read", "logs:read", "projects:read"]}),
        )
        .await;
    assert_eq!(status, StatusCode::CREATED, "{key}");
    let token = key["secret"].as_str().unwrap();
    let (status, usage) = bearer_send(
        &base,
        token,
        reqwest::Method::GET,
        &format!("/api/orgs/{org}/usage"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(usage["ingestion"]["policy"], normalized);
    assert_eq!(
        bearer_send(&base, token, reqwest::Method::GET, &path, None).await,
        (
            StatusCode::OK,
            json!({"policy": normalized, "updated_at": saved["updated_at"]})
        )
    );
    assert_eq!(
        bearer_send(
            &base,
            token,
            reqwest::Method::PUT,
            &path,
            Some(default_policy())
        )
        .await,
        (StatusCode::FORBIDDEN, json!({"error": "forbidden"}))
    );
    assert_eq!(owner.get(&path).await.1["policy"], normalized);
    shutdown(&boot).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn configured_fields_redact_errors_nested_pairs_and_typed_logs() {
    let env = TestEnv::new("privacy-configured-fields");
    let boot = env.boot_memory(fast_archive).await.unwrap();
    let (base, _server) = serve(&boot).await;
    let api = Api::signup(&base, "policy-fields@example.test").await;
    let (org, project, dsn) = api.setup_source("Fields").await;
    let mut policy = default_policy();
    policy["sensitive_fields"] = json!(["customer_ssn"]);
    assert_eq!(put_policy(&api, &org, policy).await.0, StatusCode::OK);

    let event_id = "0123456789abcdef0123456789abcdea";
    let event = json!({
        "event_id": event_id,
        "message": "lookup failed",
        "request": {"url": format!("https://example.invalid/p?customer_ssn={FAKE}&page=2")},
        "contexts": {"customer": {"nested": [["Customer-SSN", FAKE], ["tier", "gold"]]}},
        "extra": {"customer_ssn": FAKE, "order": "o-1"}
    });
    let log = json!({
        "level": "info",
        "body": "lookup",
        "attributes": {
            "customer_ssn": {"type": "string", "value": FAKE},
            "order": {"type": "string", "value": "o-1"}
        }
    });
    let (status, _) = post_envelope(
        &base,
        project,
        &dsn_key(&dsn),
        raw_envelope(Some(event_id), Some(&event), &[log]),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (_, issues) = api.get(&format!("/api/orgs/{org}/issues")).await;
    let issue_id = issues["issues"][0]["id"].as_i64().unwrap();
    let (_, stored) = api
        .get(&format!(
            "/api/orgs/{org}/issues/{issue_id}/events/{event_id}"
        ))
        .await;
    let payload = &stored["payload"];
    assert_eq!(
        (
            payload["request"]["url"].clone(),
            payload["contexts"]["customer"]["nested"].clone(),
            payload["extra"].clone()
        ),
        (
            json!("https://example.invalid/p?customer_ssn=[Filtered]&page=2"),
            json!([["Customer-SSN", "[Filtered]"], ["tier", "gold"]]),
            json!({"customer_ssn": "[Filtered]", "order": "o-1"})
        )
    );
    wait_archived(&api, &org).await;
    let (_, logs) = api.get(&format!("/api/orgs/{org}/logs?limit=5")).await;
    assert_eq!(
        logs["rows"][0]["attributes"],
        json!({
            "customer_ssn": {"type": "string", "value": "[Filtered]"},
            "order": {"type": "string", "value": "o-1"}
        })
    );
    let rt = Runtime::get(&boot.app_context);
    assert!(!stored_object_text(&rt).await.contains(FAKE));
    shutdown(&boot).await;
    assert_eq!(
        file_contains(&env.dir, FAKE.as_bytes()),
        Vec::<String>::new()
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_invalid_stored_policy_refuses_ingestion_and_is_shown_until_a_manager_replaces_it() {
    use sea_orm::ConnectionTrait;
    let log = CapturedLog::default();
    tracing_subscriber::fmt()
        .with_max_level(tracing::Level::WARN)
        .with_ansi(false)
        .with_writer({
            let log = log.clone();
            move || log.clone()
        })
        .try_init()
        .expect("this test owns the process log subscriber");
    let env = TestEnv::new("privacy-invalid-stored-policy");
    let boot = env.boot_memory(|_| {}).await.unwrap();
    let (base, _server) = serve(&boot).await;
    let api = Api::signup(&base, "policy-invalid@example.test").await;
    let (org, project, dsn) = api.setup_source("Invalid").await;
    let rt = Runtime::get(&boot.app_context);
    let mut stored = default_policy();
    stored["error_sample_percent"] = json!(250);
    rt.control
        .execute_raw(postdeploy::runtime::sql(
            "INSERT INTO ingestion_policies (org_id, policy, updated_at, updated_by) VALUES (?, ?, 1, 1)",
            vec![org.clone().into(), stored.to_string().into()],
        ))
        .await
        .unwrap();
    let key = dsn_key(&dsn);
    let send = |n: u32| {
        post_envelope(
            &base,
            project,
            &key,
            envelope(
                Some(&format!("0123456789abcdef0123456789abcd{n:02}")),
                &["x"],
            ),
            None,
        )
    };
    let refused = (
        StatusCode::SERVICE_UNAVAILABLE,
        json!({"error": "ingestion_policy_invalid"}),
    );
    assert_eq!(send(1).await, refused);
    assert_eq!(send(2).await, refused);
    assert_eq!(send(4).await, refused);
    assert_eq!(
        rt.metrics
            .rejected_policy_invalid
            .load(std::sync::atomic::Ordering::Relaxed),
        3
    );
    let warnings: Vec<String> = log
        .text()
        .lines()
        .filter(|line| line.contains("stored ingestion policy is invalid") && line.contains(&org))
        .map(|line| {
            line.split_once("WARN")
                .map_or(line, |(_, rest)| rest)
                .to_owned()
        })
        .collect();
    assert_eq!(warnings.len(), 2, "{warnings:#?}");
    assert!(
        warnings[0].ends_with(&format!("org={org} refused=1")),
        "{warnings:#?}"
    );
    assert!(
        warnings[1].ends_with(&format!("org={org} refused=2")),
        "{warnings:#?}"
    );
    let other = Api::signup(&base, "policy-invalid-other@example.test").await;
    let (other_org, other_project, other_dsn) = other.setup_source("Other").await;
    rt.control
        .execute_raw(postdeploy::runtime::sql(
            "INSERT INTO ingestion_policies (org_id, policy, updated_at, updated_by) VALUES (?, ?, 1, 1)",
            vec![other_org.clone().into(), stored.to_string().into()],
        ))
        .await
        .unwrap();
    assert_eq!(
        post_envelope(
            &base,
            other_project,
            &dsn_key(&other_dsn),
            envelope(Some("0123456789abcdef0123456789abcd05"), &["x"]),
            None,
        )
        .await,
        refused
    );
    let other_warnings: Vec<String> = log
        .text()
        .lines()
        .filter(|line| {
            line.contains("stored ingestion policy is invalid") && line.contains(&other_org)
        })
        .map(|line| {
            line.split_once("WARN")
                .map_or(line, |(_, rest)| rest)
                .to_owned()
        })
        .collect();
    assert_eq!(other_warnings.len(), 1, "{other_warnings:#?}");
    assert!(
        other_warnings[0].ends_with(&format!("org={other_org} refused=1")),
        "{other_warnings:#?}"
    );
    assert_eq!(
        api.get(&format!("/api/orgs/{org}/ingestion-policy")).await,
        (
            StatusCode::OK,
            json!({"policy": {"error": "ingestion_policy_invalid"}, "updated_at": 1})
        )
    );
    assert_eq!(
        usage(&api, &org).await["ingestion"]["policy"],
        json!({"error": "ingestion_policy_invalid"})
    );
    let (_, issues) = api.get(&format!("/api/orgs/{org}/issues")).await;
    assert_eq!(issues["issues"], json!([]));

    let path = format!("/dashboard/orgs/{org}/settings/ingestion");
    let (status, html) = page(&api, &path).await;
    assert_eq!(status, StatusCode::OK);
    assert!(
        html.contains("The saved data controls are not valid. Every project in this organization refuses new events and logs until valid data controls are saved."),
        "{html}"
    );
    let saved = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .unwrap()
        .post(format!("{base}{path}"))
        .header("origin", "http://127.0.0.1:5167")
        .header("cookie", api.cookie.as_deref().unwrap())
        .form(&[
            ("log_levels", "error"),
            ("error_sample_percent", "100"),
            ("log_sample_percent", "100"),
            ("_csrf_token", &hidden_value(&html, "_csrf_token")),
        ])
        .send()
        .await
        .unwrap();
    assert_eq!(saved.status(), StatusCode::SEE_OTHER);
    let (status, html) = page(&api, &path).await;
    assert_eq!(status, StatusCode::OK);
    assert!(!html.contains("id=\"ingestion-policy-invalid\""));
    assert_eq!(send(3).await.0, StatusCode::OK);
    shutdown(&boot).await;
}

#[derive(Clone, Default)]
struct CapturedLog(std::sync::Arc<std::sync::Mutex<Vec<u8>>>);

impl CapturedLog {
    fn text(&self) -> String {
        String::from_utf8_lossy(&self.0.lock().unwrap()).into_owned()
    }
}

impl std::io::Write for CapturedLog {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

fn hidden_value(html: &str, name: &str) -> String {
    let marker = format!("name=\"{name}\" value=\"");
    html.split_once(&marker)
        .expect("rendered hidden form field")
        .1
        .split('"')
        .next()
        .unwrap()
        .to_owned()
}

async fn page(api: &Api, path: &str) -> (StatusCode, String) {
    let response = api
        .http
        .get(format!("{}{path}", api.base))
        .header("cookie", api.cookie.as_deref().unwrap())
        .send()
        .await
        .unwrap();
    (response.status(), response.text().await.unwrap())
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_dashboard_shows_and_saves_the_ingestion_policy() {
    let env = TestEnv::new("privacy-policy-dashboard");
    let boot = env.boot_memory(|_| {}).await.unwrap();
    let (base, _server) = serve(&boot).await;
    let owner = Api::signup(&base, "policy-dash@example.test").await;
    let (org, _project, _dsn) = owner.setup_source("Dashboard policy").await;
    let path = format!("/dashboard/orgs/{org}/settings/ingestion");
    let (status, html) = page(&owner, &path).await;
    assert_eq!(status, StatusCode::OK);
    assert!(html.contains("id=\"ingestion-policy-form\""), "{html}");
    let csrf = hidden_value(&html, "_csrf_token");

    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .unwrap();
    let post = |fields: Vec<(&'static str, String)>| {
        let mut fields = fields;
        fields.push(("_csrf_token", csrf.clone()));
        client
            .post(format!("{base}{path}"))
            .header("origin", "http://127.0.0.1:5167")
            .header("cookie", owner.cookie.as_deref().unwrap())
            .form(&fields)
            .send()
    };
    let forged = client
        .post(format!("{base}{path}"))
        .header("origin", "http://127.0.0.1:5167")
        .header("cookie", owner.cookie.as_deref().unwrap())
        .form(&[
            ("log_levels", "error"),
            ("error_sample_percent", "0"),
            ("log_sample_percent", "0"),
            ("_csrf_token", "wrong"),
        ])
        .send()
        .await
        .unwrap();
    assert_eq!(forged.status(), StatusCode::FORBIDDEN);
    let rejected = post(vec![
        ("sensitive_fields", "ab".to_owned()),
        ("log_levels", "error".to_owned()),
        ("error_sample_percent", "100".to_owned()),
        ("log_sample_percent", "100".to_owned()),
    ])
    .await
    .unwrap();
    assert_eq!(rejected.status(), StatusCode::UNPROCESSABLE_ENTITY);
    assert!(rejected
        .text()
        .await
        .unwrap()
        .contains("id=\"ingestion-policy-error\""));
    let structural = post(vec![
        ("sensitive_fields", "trace".to_owned()),
        ("log_levels", "error".to_owned()),
        ("error_sample_percent", "100".to_owned()),
        ("log_sample_percent", "100".to_owned()),
    ])
    .await
    .unwrap();
    assert_eq!(structural.status(), StatusCode::UNPROCESSABLE_ENTITY);
    assert!(structural.text().await.unwrap().contains(
        "A field name cannot be all or part of a name PostDeploy needs to group and store events and logs, such as message, type, value, trace, level or service."
    ));

    let saved = post(vec![
        (
            "sensitive_fields",
            "customer_ssn\nloyalty-number".to_owned(),
        ),
        ("log_levels", "warn".to_owned()),
        ("log_levels", "error".to_owned()),
        ("excluded_exception_types", "NotFoundError".to_owned()),
        ("error_sample_percent", "50".to_owned()),
        ("log_sample_percent", "10".to_owned()),
    ])
    .await
    .unwrap();
    assert_eq!(saved.status(), StatusCode::SEE_OTHER);
    assert_eq!(
        owner
            .get(&format!("/api/orgs/{org}/ingestion-policy"))
            .await
            .1["policy"],
        json!({
            "sensitive_fields": ["customer_ssn", "loyalty_number"],
            "log_levels": ["warn", "error"],
            "excluded_exception_types": ["NotFoundError"],
            "error_sample_percent": 50,
            "log_sample_percent": 10
        })
    );

    let member = Api::signup(&base, "policy-dash-member@example.test").await;
    owner
        .post(
            &format!("/api/orgs/{org}/members"),
            json!({"email": "policy-dash-member@example.test", "role": "member"}),
        )
        .await;
    let (status, html) = page(&member, &path).await;
    assert_eq!(status, StatusCode::OK);
    assert!(!html.contains("id=\"ingestion-policy-form\""));
    assert!(html.contains("loyalty_number"));
    shutdown(&boot).await;
}

fn counts(outcomes: [u32; 6], reasons: Value) -> Value {
    json!({
        "accepted": outcomes[0], "duplicate": outcomes[1], "filtered": outcomes[2],
        "sampled": outcomes[3], "unsupported": outcomes[4], "invalid": outcomes[5],
        "reasons": reasons
    })
}

fn refused(outcomes: [u32; 5], reasons: Value) -> Value {
    json!({
        "duplicate": outcomes[0], "filtered": outcomes[1], "sampled": outcomes[2],
        "unsupported": outcomes[3], "invalid": outcomes[4], "reasons": reasons
    })
}

fn none() -> Value {
    counts([0; 6], json!({}))
}

fn exception_event(event_id: &str, kind: &str) -> Value {
    json!({"event_id": event_id, "level": "error",
        "exception": {"values": [{"type": kind, "value": "x", "stacktrace": {"frames": [
            {"function": "handler", "abs_path": "/srv/app/handler.rs", "in_app": true}]}}]}})
}

fn mixed_envelope(events: &[Vec<u8>], logs: &[Value], unsupported: usize) -> Vec<u8> {
    let mut out = String::from("{}\n");
    for event in events {
        out.push_str(&format!("{}\n", json!({"type": "event"})));
        out.push_str(&String::from_utf8_lossy(event));
        out.push('\n');
    }
    if !logs.is_empty() {
        out.push_str(&format!(
            "{}\n{}\n",
            json!({"type": "log"}),
            json!({"items": logs})
        ));
    }
    for _ in 0..unsupported {
        out.push_str("{\"type\":\"session\"}\n{\"sid\":\"x\"}\n");
    }
    out.into_bytes()
}

fn log_entry(level: &str, body: &str) -> Value {
    json!({"level": level, "body": body})
}

async fn usage(api: &Api, org: &str) -> Value {
    let (status, usage) = api.get(&format!("/api/orgs/{org}/usage")).await;
    assert_eq!(status, StatusCode::OK);
    usage
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_default_policy_accepts_supported_items_and_explains_every_refusal() {
    let env = TestEnv::new("privacy-default-receipt");
    let boot = env
        .boot_memory(|s| {
            s["logs"]["max_body_bytes"] = json!(64);
            s["logs"]["max_attributes"] = json!(2);
        })
        .await
        .unwrap();
    let (base, _server) = serve(&boot).await;
    let api = Api::signup(&base, "receipt-default@example.test").await;
    let (org, project, dsn) = api.setup_source("Receipts").await;
    let key = dsn_key(&dsn);
    let valid = exception_event("10000000000000000000000000000001", "Boom");
    let events = [
        valid.to_string().into_bytes(),
        b"{not json".to_vec(),
        json!({"message": "no id"}).to_string().into_bytes(),
    ];
    let logs = [
        log_entry("info", "kept"),
        log_entry("loud", "bad level"),
        log_entry("warn", &"long".repeat(40)),
        json!({"level": "error", "body": "three attributes", "attributes": {
            "a": {"type": "string", "value": "1"},
            "b": {"type": "string", "value": "2"},
            "c": {"type": "string", "value": "3"},
            "d": {"type": "object", "value": {}}
        }}),
    ];
    let (status, body) = post_envelope(
        &base,
        project,
        &key,
        mixed_envelope(&events, &logs, 2),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        body,
        json!({
            "id": "10000000000000000000000000000001",
            "receipt": {
                "error": counts([1, 0, 0, 0, 0, 2], json!({"malformed": 1, "missing_event_id": 1})),
                "log": counts([3, 0, 0, 0, 0, 1], json!({"invalid_entry": 1, "body_truncated": 1, "attribute_dropped": 2})),
                "other": counts([0, 0, 0, 0, 2, 0], json!({"unsupported_item_type": 2}))
            }
        })
    );
    let (status, again) = post_envelope(
        &base,
        project,
        &key,
        mixed_envelope(&[valid.to_string().into_bytes()], &[], 0),
        None,
    )
    .await;
    assert_eq!(
        (status, again["receipt"]["error"].clone()),
        (
            StatusCode::OK,
            counts([0, 1, 0, 0, 0, 0], json!({"duplicate_event_id": 1}))
        )
    );
    let (_, page) = api.get(&format!("/api/orgs/{org}/logs?limit=10")).await;
    let bodies: Vec<&str> = page["rows"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| row["body"].as_str().unwrap())
        .collect();
    assert_eq!(bodies.len(), 3);
    assert!(bodies.contains(&"long".repeat(16).as_str()), "{bodies:?}");

    let usage = usage(&api, &org).await;
    assert_eq!(usage["errors"]["used"], 1);
    assert_eq!(
        usage["ingestion"]["outcomes"],
        json!({
            "error": refused([1, 0, 0, 0, 2], json!({"malformed": 1, "missing_event_id": 1, "duplicate_event_id": 1})),
            "log": refused([0, 0, 0, 0, 1], json!({"invalid_entry": 1, "body_truncated": 1, "attribute_dropped": 2})),
            "other": refused([0, 0, 0, 2, 0], json!({"unsupported_item_type": 2}))
        })
    );
    shutdown(&boot).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn filters_and_zero_or_full_sampling_refuse_items_without_billing_them() {
    let env = TestEnv::new("privacy-filter-sample");
    let boot = env.boot_memory(|_| {}).await.unwrap();
    let (base, _server) = serve(&boot).await;
    let api = Api::signup(&base, "receipt-filters@example.test").await;
    let (org, project, dsn) = api.setup_source("Filters").await;
    let key = dsn_key(&dsn);
    let mut policy = default_policy();
    policy["log_levels"] = json!(["error", "fatal"]);
    policy["excluded_exception_types"] = json!(["NotFoundError"]);
    assert_eq!(
        put_policy(&api, &org, policy.clone()).await.0,
        StatusCode::OK
    );
    let events = [
        exception_event("20000000000000000000000000000001", "NotFoundError")
            .to_string()
            .into_bytes(),
        exception_event("20000000000000000000000000000002", "Boom")
            .to_string()
            .into_bytes(),
    ];
    let logs = [log_entry("info", "dropped"), log_entry("error", "kept")];
    let (status, body) = post_envelope(
        &base,
        project,
        &key,
        mixed_envelope(&events, &logs, 0),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        body["receipt"],
        json!({
            "error": counts([1, 0, 1, 0, 0, 0], json!({"exception_type_excluded": 1})),
            "log": counts([1, 0, 1, 0, 0, 0], json!({"level_disabled": 1})),
            "other": none()
        })
    );
    let before = usage(&api, &org).await;
    assert_eq!(before["errors"]["used"], 1);
    let log_bytes = before["log_bytes"]["used"].clone();

    policy["error_sample_percent"] = json!(0);
    policy["log_sample_percent"] = json!(0);
    assert_eq!(put_policy(&api, &org, policy).await.0, StatusCode::OK);
    let events = [exception_event("20000000000000000000000000000003", "Boom")
        .to_string()
        .into_bytes()];
    let logs = [log_entry("error", "sampled out")];
    let (status, body) = post_envelope(
        &base,
        project,
        &key,
        mixed_envelope(&events, &logs, 0),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        body["receipt"],
        json!({
            "error": counts([0, 0, 0, 1, 0, 0], json!({"sample_rate": 1})),
            "log": counts([0, 0, 0, 1, 0, 0], json!({"sample_rate": 1})),
            "other": none()
        })
    );
    let after = usage(&api, &org).await;
    assert_eq!(
        (
            after["errors"]["used"].clone(),
            after["log_bytes"]["used"].clone()
        ),
        (json!(1), log_bytes),
        "refused items are not billed"
    );
    assert_eq!(
        after["ingestion"]["outcomes"],
        json!({
            "error": refused([0, 1, 1, 0, 0], json!({"exception_type_excluded": 1, "sample_rate": 1})),
            "log": refused([0, 1, 1, 0, 0], json!({"level_disabled": 1, "sample_rate": 1})),
            "other": refused([0, 0, 0, 0, 0], json!({}))
        })
    );
    let (_, issues) = api.get(&format!("/api/orgs/{org}/issues")).await;
    assert_eq!(
        issues["issues"]
            .as_array()
            .unwrap()
            .iter()
            .map(|issue| issue["title"].as_str().unwrap())
            .collect::<Vec<_>>(),
        ["Boom: x"]
    );
    shutdown(&boot).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn error_sampling_keeps_the_same_events_on_every_retry() {
    let env = TestEnv::new("privacy-error-sampling");
    let boot = env.boot_memory(|_| {}).await.unwrap();
    let (base, _server) = serve(&boot).await;
    let api = Api::signup(&base, "receipt-sampling@example.test").await;
    let (org, project, dsn) = api.setup_source("Sampling").await;
    let mut policy = default_policy();
    policy["error_sample_percent"] = json!(50);
    assert_eq!(put_policy(&api, &org, policy).await.0, StatusCode::OK);
    let events: Vec<Vec<u8>> = (0..20)
        .map(|i| {
            json!({"event_id": format!("{i:032x}"), "message": format!("sampled {i}")})
                .to_string()
                .into_bytes()
        })
        .collect();
    let body = mixed_envelope(&events, &[], 0);
    let (status, first) = post_envelope(&base, project, &dsn_key(&dsn), body.clone(), None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        first["receipt"]["error"],
        counts([11, 0, 0, 9, 0, 0], json!({"sample_rate": 9}))
    );
    let (status, retry) = post_envelope(&base, project, &dsn_key(&dsn), body, None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        retry["receipt"]["error"],
        counts(
            [0, 11, 0, 9, 0, 0],
            json!({"sample_rate": 9, "duplicate_event_id": 11})
        )
    );
    assert_eq!(usage(&api, &org).await["errors"]["used"], 11);
    shutdown(&boot).await;
}

async fn raw_post(base: &str, project: i64, key: &str, body: Vec<u8>) -> reqwest::Response {
    reqwest::Client::new()
        .post(format!("{base}/api/{project}/envelope/"))
        .header(
            "x-sentry-auth",
            format!("Sentry sentry_version=7, sentry_key={key}, sentry_client=test/1"),
        )
        .body(body)
        .send()
        .await
        .unwrap()
}

fn limited(response: &reqwest::Response) -> (StatusCode, Option<String>, Option<String>) {
    let header = |name: &str| {
        response
            .headers()
            .get(name)
            .map(|v| v.to_str().unwrap().to_owned())
    };
    (
        response.status(),
        header("retry-after"),
        header("x-sentry-rate-limits"),
    )
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_organization_rate_gate_limits_isolates_bounds_and_recovers() {
    let env = TestEnv::new("privacy-rate-gate");
    let boot = env
        .boot_memory(|s| {
            s["ingest"]["rate_per_second"] = json!(1);
            s["ingest"]["rate_burst"] = json!(2);
            s["ingest"]["rate_max_orgs"] = json!(2);
        })
        .await
        .unwrap();
    let (base, _server) = serve(&boot).await;
    let rt = Runtime::get(&boot.app_context);
    let api = Api::signup(&base, "rate-gate@example.test").await;
    let (org_a, project_a, dsn_a) = api.setup_source("Rate A").await;
    let (status, second) = api
        .post(
            &format!("/api/orgs/{org_a}/projects/{project_a}/sources"),
            json!({"name": "second", "environment": "staging"}),
        )
        .await;
    assert_eq!(status, StatusCode::CREATED);
    let second_key = dsn_key(second["dsn"].as_str().unwrap());
    let (org_b, project_b, dsn_b) = api.setup_source("Rate B").await;
    let (_org_c, project_c, dsn_c) = api.setup_source("Rate C").await;
    let error = |n: u32| envelope(Some(&format!("{n:032x}")), &[]);

    for n in 1..=2 {
        let response = raw_post(&base, project_a, &dsn_key(&dsn_a), error(n)).await;
        assert_eq!(response.status(), StatusCode::OK, "burst request {n}");
    }
    let refused = raw_post(&base, project_a, &dsn_key(&dsn_a), error(3)).await;
    assert_eq!(
        limited(&refused),
        (
            StatusCode::TOO_MANY_REQUESTS,
            Some("1".to_owned()),
            Some("1::organization".to_owned())
        )
    );
    assert_eq!(
        refused.json::<Value>().await.unwrap(),
        json!({"error": "rate_limited"})
    );
    assert_eq!(
        limited(&raw_post(&base, project_a, &second_key, error(4)).await).0,
        StatusCode::TOO_MANY_REQUESTS,
        "another key of the same organization shares its budget"
    );
    assert_eq!(
        raw_post(&base, project_b, &dsn_key(&dsn_b), error(5))
            .await
            .status(),
        StatusCode::OK,
        "another organization keeps its own budget"
    );
    let full = raw_post(&base, project_c, &dsn_key(&dsn_c), error(6)).await;
    assert_eq!(
        limited(&full),
        (StatusCode::SERVICE_UNAVAILABLE, Some("1".to_owned()), None)
    );
    assert_eq!(
        full.json::<Value>().await.unwrap(),
        json!({"error": "ingest_overloaded"})
    );
    assert_eq!(rt.admission.ingest_rate.cached_orgs(), 2);

    tokio::time::sleep(std::time::Duration::from_millis(2_100)).await;
    assert_eq!(
        raw_post(&base, project_c, &dsn_key(&dsn_c), error(7))
            .await
            .status(),
        StatusCode::OK,
        "refilled organizations leave the bounded cache"
    );
    assert!(rt.admission.ingest_rate.cached_orgs() <= 2);
    assert_eq!(
        raw_post(&base, project_a, &dsn_key(&dsn_a), error(8))
            .await
            .status(),
        StatusCode::OK,
        "the limited organization recovers after its window"
    );
    assert_eq!(usage(&api, &org_a).await["errors"]["used"], 3);
    assert_eq!(usage(&api, &org_b).await["errors"]["used"], 1);
    shutdown(&boot).await;
}

fn marker(n: u32) -> String {
    format!("leakmark{n:02}qz")
}

const MARKERS: [u32; 60] = [
    1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26,
    27, 28, 29, 30, 31, 32, 33, 34, 35, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55,
    56, 57, 58, 59, 60, 61, 62, 63, 64, 65,
];

fn shape_event(event_id: &str) -> Value {
    let m = marker;
    json!({
        "event_id": event_id,
        "message": format!("request failed {{\"password\": \"{}\"}}", m(1)),
        "exception": {"values": [{
            "type": "DbError",
            "value": format!("bad config {{\"api_key\":\"{}\"}} token=\"{}\" {{'secret': '{}'}}", m(2), m(3), m(51)),
            "stacktrace": {"frames": [{
                "function": "connect", "abs_path": "/srv/app/db.rs", "in_app": true,
                "vars": {"secret_key": m(4), "args": [format!("password={}", m(5))],
                         "env": format!("{{AWS_SECRET_ACCESS_KEY={}}}", m(6)),
                         "pwd": m(7), "auth": m(8)}
            }]}
        }]},
        "request": {
            "url": "https://example.invalid/x",
            "headers": [["X-Forwarded-Host", "h"], ["Accept", "*/*"]],
            "data": {"raw_headers": format!("Host: h\r\nAuthorization: {}\r\nX-Session-Id: {}\r\nCookie: a=b; c={}\r\n", m(9), m(10), m(52)),
                     "har": [{"name": "Authorization", "value": m(11)}],
                     "form": format!("user[name]=a&user[password]={}", m(55))},
            "query_string": format!("a=1,session_id={}", m(12))
        },
        "breadcrumbs": {"values": [
            {"message": format!("GET https://u:{}@example.invalid/x {{'password': '{}'}}", m(13), m(62)),
             "data": {"url": format!("https://example.invalid/?api_key={}", m(14)), "Authorization": m(15),
                      "har": [{"name": "X-Api-Key", "value": m(57)}]}}
        ]},
        "contexts": {"db": {"connection_string": format!("Host=h;Password={};", m(16))}},
        "tags": {"session": m(17), "region": "eu"},
        "extra": {
            "slash_pw": format!("redis://:pa/{}@example.invalid:6379", m(18)),
            "hash_pw": format!("postgres://u:x#{}@example.invalid/db", m(19)),
            "query_pw": format!("amqp://u:x?{}@example.invalid/v", m(20)),
            "srv": format!("mongodb+srv://u:{}@cluster0.example.invalid/db", m(21)),
            "ipv6": format!("postgres://u:{}@[::1]:5432/db", m(22)),
            "colon_pw": format!("redis://u:{}:x@example.invalid", m(23)),
            "encoded_nested": format!("https://example.invalid/cb?next=https%3A%2F%2Fu%3A{}%40h", m(24)),
            "jdbc": format!("jdbc:mysql://h:3306/db?user=u&password={}", m(25)),
            "at_user": format!("https://{}@x@example.invalid/", m(26)),
            "lower_header": format!("authorization: {}", m(27)),
            "pass": m(28),
            "triple": [["Authorization", m(29), "x"]],
            "set_cookie_line": format!("Set-Cookie: sid={}; Path=/", m(30)),
            "header_map_str": {"X-Sentry-Auth": format!("Sentry sentry_key={}", m(31))},
            "basic_short": format!("Authorization: Basic {}", m(32)),
            "dsn": format!("https://{}@o1.ingest.example.invalid/1", m(33)),
            "base64_pw": format!("postgres://u:ab/{}+d==@example.invalid:5432/x", m(50)),
            "encoded_query": format!("https://example.invalid/cb?next=https%3A%2F%2Fh%2Fcb%3Ftoken%3D{}", m(54)),
            "basicAuth": m(61),
            "profile": "https://example.invalid/users/@alice",
            "search": "https://example.invalid/search?q=a@b.example&page=2",
            "port_path": "http://localhost:3000/@me/x",
            "ipv6_port": "http://[::1]:8080/x@y",
            "author": "Ada",
            "plain_headers": "Host: h\r\nAccept: */*",
            "encoded_ok": "https://example.invalid/cb?next=https%3A%2F%2Fexample.invalid%2Fhome",
            "note": "Error: connection refused",
            "header_object": {"name": "Accept", "value": "*/*"},
            "pairs_ok": [["Accept", "*/*", "x"]],
            "token_count": 5
        },
        "fingerprint": [format!("token={}", m(34))],
        "transaction": format!("/reset?token={}", m(35))
    })
}

fn shape_log() -> Value {
    let m = marker;
    json!({
        "level": "info",
        "body": format!(
            "payload {{\"password\":\"{}\"}} auth={} {{AWS_SECRET_ACCESS_KEY={}}} postgres://u:x#{}@h\nX-Session-Id: {}",
            m(41), m(42), m(43), m(64), m(58)
        ),
        "attributes": {
            "pwd": {"type": "string", "value": m(44)},
            "http.request.header.x_session_id": {"type": "string", "value": m(45)},
            "raw": {"type": "string", "value": format!("authorization: {}", m(46))},
            "list": {"type": "array", "value": [format!("password={}", m(47)), "ok"]},
            "db.url": {"type": "string", "value": format!("redis://:pa/{}@h", m(48))},
            "request_id": {"type": "string", "value": format!("rid?token={}", m(49))},
            "payload": {"type": "string", "value": format!("{{\"api_key\": \"{}\"}}", m(53))},
            "digest": {"type": "string", "value": format!("Authorization: Digest username=\"u\", response=\"{}\"", m(56))},
            "pairs": {"type": "string", "value": format!("a=1,token={}", m(59))},
            "db.pass": {"type": "string", "value": m(60)},
            "query": {"type": "string", "value": format!("q=1&pass={}", m(63))},
            "escaped": {"type": "string", "value": format!(r#"{{\"token\":\"{}\"}}"#, m(65))},
            "author": {"type": "string", "value": "Ada"},
            "http.request.header.accept": {"type": "string", "value": "*/*"},
            "url.full": {"type": "string", "value": "https://example.invalid/list?page=2"}
        }
    })
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn labelled_credentials_in_every_shape_never_reach_apis_objects_or_files() {
    let env = TestEnv::new("privacy-credential-shapes");
    let boot = env.boot_memory(fast_archive).await.unwrap();
    let (base, _server) = serve(&boot).await;
    let api = Api::signup(&base, "privacy-shapes@example.test").await;
    let (org, project, dsn) = api.setup_source("Shapes").await;
    let event_id = "fedcba9876543210fedcba9876543210";
    let body = raw_envelope(Some(event_id), Some(&shape_event(event_id)), &[shape_log()]);
    let (status, _) = post_envelope(&base, project, &dsn_key(&dsn), body, None).await;
    assert_eq!(status, StatusCode::OK);

    let (_, issues) = api.get(&format!("/api/orgs/{org}/issues")).await;
    let issue_id = issues["issues"][0]["id"].as_i64().unwrap();
    let (_, summary) = api.get(&format!("/api/orgs/{org}/issues/{issue_id}")).await;
    let (status, event) = api
        .get(&format!(
            "/api/orgs/{org}/issues/{issue_id}/events/{event_id}"
        ))
        .await;
    assert_eq!(status, StatusCode::OK);
    wait_archived(&api, &org).await;
    let (status, logs) = api
        .get(&format!("/api/orgs/{org}/logs?project={project}&limit=5"))
        .await;
    assert_eq!(status, StatusCode::OK);
    let rt = Runtime::get(&boot.app_context);
    let objects = stored_object_text(&rt).await;
    assert!(
        objects.contains("example.invalid/users/@alice"),
        "the error object was read"
    );
    assert!(objects.contains("list?page=2"), "the log object was read");
    shutdown(&boot).await;

    let surfaces = [
        ("issues", issues.to_string()),
        ("summary", summary.to_string()),
        ("event", event.to_string()),
        ("logs", logs.to_string()),
        ("objects", objects),
    ];
    let mut leaks = Vec::new();
    for n in MARKERS {
        let marker = marker(n);
        let mut at: Vec<String> = surfaces
            .iter()
            .filter(|(_, text)| text.contains(&marker))
            .map(|(name, _)| (*name).to_owned())
            .collect();
        let files = file_contains(&env.dir, marker.as_bytes());
        if !files.is_empty() {
            at.push(format!("files:{}", files.len()));
        }
        if !at.is_empty() {
            leaks.push(format!("{marker} -> {}", at.join(",")));
        }
    }
    println!(
        "SURVIVORS {} of {}\n{}",
        leaks.len(),
        MARKERS.len(),
        leaks.join("\n")
    );
    assert_eq!(leaks, Vec::<String>::new());

    let extra = &event["payload"]["extra"];
    let controls = [
        "profile",
        "search",
        "port_path",
        "ipv6_port",
        "author",
        "plain_headers",
        "encoded_ok",
        "note",
        "header_object",
        "pairs_ok",
        "token_count",
    ]
    .map(|key| (key, extra[key].clone()));
    assert_eq!(
        controls,
        [
            ("profile", json!("https://example.invalid/users/@alice")),
            (
                "search",
                json!("https://example.invalid/search?q=a@b.example&page=2")
            ),
            ("port_path", json!("http://localhost:3000/@me/x")),
            ("ipv6_port", json!("http://[::1]:8080/x@y")),
            ("author", json!("Ada")),
            ("plain_headers", json!("Host: h\r\nAccept: */*")),
            (
                "encoded_ok",
                json!("https://example.invalid/cb?next=https%3A%2F%2Fexample.invalid%2Fhome")
            ),
            ("note", json!("Error: connection refused")),
            ("header_object", json!({"name": "Accept", "value": "*/*"})),
            ("pairs_ok", json!([["Accept", "*/*", "x"]])),
            ("token_count", json!("[Filtered]")),
        ]
    );
    assert_eq!(
        event["payload"]["request"]["headers"],
        json!([["X-Forwarded-Host", "h"], ["Accept", "*/*"]])
    );
    assert_eq!(event["payload"]["tags"]["region"], "eu");
    let attributes = &logs["rows"][0]["attributes"];
    assert_eq!(
        [
            &attributes["author"],
            &attributes["http.request.header.accept"],
            &attributes["url.full"]
        ],
        [
            &json!({"type": "string", "value": "Ada"}),
            &json!({"type": "string", "value": "*/*"}),
            &json!({"type": "string", "value": "https://example.invalid/list?page=2"})
        ]
    );
}

/// One `{"message": "note %s", "params": [inner]}` level per `depth` around
/// `{"note": text}`, sent in `extra`.
fn nested_templates(depth: usize, text: &str) -> Value {
    let mut value = json!({"note": text});
    for _ in 0..depth {
        value = json!({"message": "note %s", "params": [value]});
    }
    value
}

fn gzip(body: &[u8]) -> Vec<u8> {
    use std::io::Write;
    let mut encoder = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::best());
    encoder.write_all(body).unwrap();
    encoder.finish().unwrap()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn nested_message_templates_cost_time_linear_in_the_payload() {
    let env = TestEnv::new("privacy-nested-templates");
    let boot = env.boot_memory(fast_archive).await.unwrap();
    let (base, _server) = serve(&boot).await;
    let api = Api::signup(&base, "nested-templates@example.test").await;
    let (org, project, dsn) = api.setup_source("Nested templates").await;
    let key = dsn_key(&dsn);
    let depth = 62;

    let mut oversized_time = Vec::new();
    for (first, levels) in [(0xabc000, 0), (0xabd000, depth)] {
        let mut body = format!("{}\n", json!({}));
        for n in 0..4 {
            let event = json!({"event_id": format!("{:032x}", first + n), "message": "nested",
                "extra": {"t": nested_templates(levels, &"password=x ".repeat(1_000_000 / 11))}});
            body.push_str(&format!("{}\n{event}\n", json!({"type": "event"})));
        }
        let wire = gzip(body.as_bytes());
        assert!(wire.len() < 16 << 10, "{} wire bytes", wire.len());
        let start = std::time::Instant::now();
        let (status, receipt) = post_envelope(&base, project, &key, wire, Some("gzip")).await;
        oversized_time.push(start.elapsed());
        assert_eq!(status, StatusCode::OK, "{receipt}");
        assert_eq!(
            receipt["receipt"]["error"],
            counts([0, 0, 0, 0, 0, 4], json!({"too_large": 4}))
        );
    }
    let [flat_time, nested_time] = oversized_time[..] else {
        unreachable!()
    };

    // The events API adds one level around the payload, and its JSON reader
    // stops at the same depth limit as the ingest parser.
    let readable = depth - 1;
    let text = "password=x ".repeat(200_000 / 11);
    let event_id = "abcd0000000000000000000000000001";
    let event = json!({"event_id": event_id, "message": "nested",
        "extra": {"t": nested_templates(readable, &text)}});
    let start = std::time::Instant::now();
    let (status, receipt) = post_envelope(
        &base,
        project,
        &key,
        gzip(&raw_envelope(Some(event_id), Some(&event), &[])),
        Some("gzip"),
    )
    .await;
    let accepted_time = start.elapsed();
    assert_eq!(status, StatusCode::OK, "{receipt}");
    assert_eq!(
        receipt["receipt"]["error"],
        counts([1, 0, 0, 0, 0, 0], json!({}))
    );
    let (_, issues) = api.get(&format!("/api/orgs/{org}/issues")).await;
    let issue = issues["issues"][0]["id"].as_i64().unwrap();
    let (status, stored) = api
        .get(&format!("/api/orgs/{org}/issues/{issue}/events/{event_id}"))
        .await;
    assert_eq!(status, StatusCode::OK);
    assert!(
        stored["payload"]["extra"]["t"]
            == nested_templates(readable, &"password=[Filtered] ".repeat(200_000 / 11)),
        "nested template payload stored differently"
    );
    println!(
        "4 oversized events: flat {flat_time:?}, {depth} deep {nested_time:?}; \
         one accepted event {accepted_time:?}"
    );
    assert!(
        nested_time < flat_time * 3 + std::time::Duration::from_secs(1)
            && accepted_time < std::time::Duration::from_secs(1),
        "flat {flat_time:?}, nested {nested_time:?}, accepted {accepted_time:?}"
    );
    shutdown(&boot).await;
}
