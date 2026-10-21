#![allow(dead_code)]

use std::{path::Path, sync::Arc, time::Duration};

use futures::StreamExt;
use reqwest::StatusCode;
use serde_json::{json, Value};

pub const PASSWORD: &str = "correct horse battery";

/// Dashboard API client holding one session cookie and its CSRF token.
#[derive(Clone)]
pub struct Api {
    pub base: String,
    pub http: reqwest::Client,
    pub cookie: Option<String>,
    pub csrf: Option<String>,
}

impl Api {
    pub fn new(base: &str) -> Self {
        Self {
            base: base.to_owned(),
            http: reqwest::Client::new(),
            cookie: None,
            csrf: None,
        }
    }

    pub async fn signup(base: &str, email: &str) -> Self {
        Self::signup_with_password(base, email, PASSWORD).await
    }

    pub async fn signup_with_password(base: &str, email: &str, password: &str) -> Self {
        let mut api = Self::new(base);
        let (status, _) = api.auth("signup", email, password).await;
        assert_eq!(status, StatusCode::CREATED, "signup status");
        api
    }

    pub async fn auth(&mut self, action: &str, email: &str, password: &str) -> (StatusCode, Value) {
        let response = self
            .http
            .post(format!("{}/api/auth/{action}", self.base))
            .json(&json!({"email": email, "password": password}))
            .send()
            .await
            .unwrap();
        let status = response.status();
        if let Some(cookie) = response.headers().get("set-cookie") {
            let cookie = cookie.to_str().unwrap();
            self.cookie = Some(cookie.split(';').next().unwrap().to_owned());
        }
        let body: Value = response.json().await.unwrap_or(Value::Null);
        if let Some(csrf) = body["csrf_token"].as_str() {
            self.csrf = Some(csrf.to_owned());
        }
        (status, body)
    }

    pub async fn send(
        &self,
        method: reqwest::Method,
        path: &str,
        body: Option<Value>,
    ) -> (StatusCode, Value) {
        let mut request = self.http.request(method, format!("{}{path}", self.base));
        if let Some(cookie) = &self.cookie {
            request = request.header("cookie", cookie);
        }
        if let Some(csrf) = &self.csrf {
            request = request.header("x-csrf-token", csrf);
        }
        if let Some(body) = body {
            request = request.json(&body);
        }
        let response = request.send().await.unwrap();
        let status = response.status();
        let text = response.text().await.unwrap();
        (status, serde_json::from_str(&text).unwrap_or(Value::Null))
    }

    pub async fn get(&self, path: &str) -> (StatusCode, Value) {
        self.send(reqwest::Method::GET, path, None).await
    }

    pub async fn post(&self, path: &str, body: Value) -> (StatusCode, Value) {
        self.send(reqwest::Method::POST, path, Some(body)).await
    }

    /// Creates an organization, a project and a source. Returns (org, project, dsn).
    pub async fn setup_source(&self, name: &str) -> (String, i64, String) {
        let (status, org) = self.post("/api/orgs", json!({"name": name})).await;
        assert_eq!(status, StatusCode::CREATED, "create organization");
        let org = org["id"].as_str().unwrap().to_owned();
        let (status, project) = self
            .post(&format!("/api/orgs/{org}/projects"), json!({"name": "web"}))
            .await;
        assert_eq!(status, StatusCode::CREATED, "create project");
        let project = project["id"].as_i64().unwrap();
        let (status, source) = self
            .post(
                &format!("/api/orgs/{org}/projects/{project}/sources"),
                json!({"name": "api", "environment": "production"}),
            )
            .await;
        assert_eq!(status, StatusCode::CREATED, "create source");
        let host = self.base.trim_start_matches("http://");
        let dsn = source["dsn"]
            .as_str()
            .unwrap()
            .replace("@127.0.0.1:5167/", &format!("@{host}/"));
        (org, project, dsn)
    }
}

pub fn dsn_key(dsn: &str) -> String {
    dsn.split("://")
        .nth(1)
        .unwrap()
        .split('@')
        .next()
        .unwrap()
        .to_owned()
}

/// Posts a raw envelope with the DSN key in `X-Sentry-Auth`.
pub async fn post_envelope(
    base: &str,
    project: i64,
    key: &str,
    body: Vec<u8>,
    encoding: Option<&str>,
) -> (StatusCode, Value) {
    let mut request = reqwest::Client::new()
        .post(format!("{base}/api/{project}/envelope/"))
        .header(
            "x-sentry-auth",
            format!("Sentry sentry_version=7, sentry_key={key}, sentry_client=test/1"),
        )
        .body(body);
    if let Some(encoding) = encoding {
        request = request.header("content-encoding", encoding);
    }
    let response = request.send().await.unwrap();
    let status = response.status();
    (status, response.json().await.unwrap_or(Value::Null))
}

pub fn envelope(event_id: Option<&str>, logs: &[&str]) -> Vec<u8> {
    let now = chrono::Utc::now().timestamp_micros() as f64 / 1e6;
    let mut out = format!("{}\n", json!({"event_id": event_id}));
    if let Some(id) = event_id {
        let event = json!({"event_id": id, "level": "error", "release": "web@1",
            "exception": {"values": [{"type": "Boom", "value": "kaput", "stacktrace": {"frames": [
                {"function": "handler", "abs_path": "/srv/app/handler.rs", "in_app": true, "lineno": 3}]}}]}});
        out.push_str(&format!("{}\n{}\n", json!({"type": "event"}), event));
    }
    if !logs.is_empty() {
        let items: Vec<Value> = logs
            .iter()
            .map(|body| json!({"timestamp": now, "level": "info", "body": body, "trace_id": "0123456789abcdef0123456789abcdef"}))
            .collect();
        let payload = json!({"items": items}).to_string();
        out.push_str(&format!(
            "{}\n{payload}\n",
            json!({"type": "log", "item_count": items.len(), "content_type": "application/vnd.sentry.items.log+json", "length": payload.len()})
        ));
    }
    out.into_bytes()
}

/// Sends one error with a breadcrumb and two structured logs through the real
/// Sentry Rust SDK, then flushes.
pub async fn sdk_send(dsn: String, marker: String) {
    tokio::task::spawn_blocking(move || {
        let mut options = sentry::ClientOptions::default();
        options.dsn = Some(dsn.parse().unwrap());
        options.release = Some("checkout@1.4.2".into());
        options.environment = Some("staging".into());
        options.attach_stacktrace = true;
        let options = sentry::apply_defaults(options);
        let client = Arc::new(sentry::Client::with_options(options));
        let hub = Arc::new(sentry::Hub::new(
            Some(client.clone()),
            Arc::new(sentry::Scope::default()),
        ));
        sentry::Hub::run(hub, || {
            sentry::add_breadcrumb(sentry::Breadcrumb {
                category: Some("ui.click".into()),
                message: Some("checkout button".into()),
                ..Default::default()
            });
            sentry::logger_info!(order.id = "o-1", "checkout started {}", marker.as_str());
            sentry::logger_error!("payment failed {}", marker.as_str());
            let error = std::io::Error::other("card declined");
            sentry::capture_error(&error);
        });
        assert!(client.flush(Some(Duration::from_secs(15))), "sdk flush");
    })
    .await
    .unwrap();
}

/// Reads SSE frames until `done` returns true or the timeout passes.
pub async fn read_sse(
    response: reqwest::Response,
    timeout: Duration,
    mut done: impl FnMut(&str, &Value) -> bool,
) -> Vec<(String, Value)> {
    let mut stream = response.bytes_stream();
    let mut buffer = String::new();
    let mut events = Vec::new();
    let deadline = tokio::time::Instant::now() + timeout;
    while let Ok(Some(Ok(chunk))) = tokio::time::timeout_at(deadline, stream.next()).await {
        buffer.push_str(&String::from_utf8_lossy(&chunk));
        while let Some(end) = buffer.find("\n\n") {
            let frame: String = buffer.drain(..end + 2).collect();
            let mut name = String::from("message");
            let mut data = String::new();
            for line in frame.lines() {
                if let Some(value) = line.strip_prefix("event:") {
                    name = value.trim().to_owned();
                } else if let Some(value) = line.strip_prefix("data:") {
                    data.push_str(value.trim_start());
                }
            }
            if data.is_empty() {
                continue;
            }
            let value: Value = serde_json::from_str(&data).unwrap();
            let stop = done(&name, &value);
            events.push((name, value));
            if stop {
                return events;
            }
        }
    }
    events
}

pub fn file_contains(root: &Path, needle: &[u8]) -> Vec<String> {
    let mut hits = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(path) = stack.pop() {
        if path.is_dir() {
            for entry in std::fs::read_dir(&path).unwrap() {
                stack.push(entry.unwrap().path());
            }
        } else if let Ok(bytes) = std::fs::read(&path) {
            if bytes.windows(needle.len()).any(|w| w == needle) {
                hits.push(path.display().to_string());
            }
        }
    }
    hits
}

pub async fn eventually<F, Fut>(timeout: Duration, mut check: F)
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = bool>,
{
    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        if check().await {
            return;
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "condition not met in {timeout:?}"
        );
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

/// Settings that seal a batch after 50 ms and check for archive work every 20 ms.
pub fn fast_archive(settings: &mut Value) {
    settings["logs"]["batch_max_age_ms"] = json!(50);
    settings["logs"]["archive_tick_ms"] = json!(20);
}

/// Waits until every acknowledged log entry of `org` is archived in R2.
pub async fn wait_archived(api: &Api, org: &str) {
    eventually(Duration::from_secs(20), || {
        let api = api.clone();
        let org = org.to_owned();
        async move {
            let (_, status) = api.get(&format!("/api/orgs/{org}/logs/storage")).await;
            status["pending_entries"] == 0 && status["archived_objects"].as_i64() > Some(0)
        }
    })
    .await;
}

/// Records of a stored log object.
pub fn stored_records(body: &[u8]) -> Vec<postdeploy::logs::record::LogRecord> {
    let (_, entries) = postdeploy::logs::object::decode(body, 12 << 20).unwrap();
    entries.into_iter().map(|entry| entry.record).collect()
}

/// The envelope response when every error and log item is stored.
pub fn accepted(id: Option<&str>, errors: u64, logs: u64) -> Value {
    let counts = |accepted: u64| {
        json!({"accepted": accepted, "duplicate": 0, "filtered": 0, "sampled": 0,
            "unsupported": 0, "invalid": 0, "reasons": {}})
    };
    json!({"id": id, "receipt": {"error": counts(errors), "log": counts(logs), "other": counts(0)}})
}

/// The application's backup sets service of a booted server.
pub fn backup_sets(boot: &loco_rs::boot::BootResult) -> Arc<postdeploy::backup_sets::BackupSets> {
    postdeploy::services::Services::get(&boot.app_context)
        .backups
        .clone()
}

/// Runs one backup cycle the way the hourly loop does and returns its manifest.
pub async fn run_backup(boot: &loco_rs::boot::BootResult) -> postdeploy::backup_sets::Manifest {
    let rt = postdeploy::runtime::Runtime::get(&boot.app_context);
    match backup_sets(boot).run_once(&rt).await {
        postdeploy::backup_sets::Cycle::Complete(manifest) => manifest,
        other => panic!("backup cycle did not complete: {other:?}"),
    }
}

/// Restores a complete set into the new directory `destination`.
pub async fn restore_set(
    boot: &loco_rs::boot::BootResult,
    set: postdeploy::backup_sets::SetId,
    destination: &Path,
) -> postdeploy::backup_sets::RestoreReport {
    let rt = postdeploy::runtime::Runtime::get(&boot.app_context);
    backup_sets(boot)
        .restore(&rt, set, destination)
        .await
        .unwrap()
}
