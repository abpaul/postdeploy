mod support;

use std::{
    path::PathBuf,
    process::{Child, Command},
    sync::atomic::Ordering,
    time::{Duration, Instant},
};

use postdeploy::{
    domain::{now_micros, utc_day, OrgId},
    quota::Usage,
    runtime::{sql, Runtime},
    testing::{serve, TestEnv},
};
use reqwest::StatusCode;
use sea_orm::ConnectionTrait;
use serde_json::{json, Value};
use support::*;

const CHILD_NAME: &str = "POSTDEPLOY_LOG_KILL_CHILD";
const CHILD_READY: &str = "POSTDEPLOY_LOG_KILL_READY";

fn quiet_batches(settings: &mut Value) {
    settings["logs"]["batch_max_age_ms"] = json!(600_000);
    settings["logs"]["archive_tick_ms"] = json!(50);
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

async fn log_usage(rt: &Runtime, org: &OrgId) -> (i64, i64) {
    let tenant = rt.tenant(org).await.unwrap();
    let row = tenant
        .query_one_raw(sql(
            "SELECT COALESCE(SUM(accepted),0) AS accepted, COALESCE(SUM(bytes),0) AS bytes FROM usage_daily WHERE category = 'log'",
            vec![],
        ))
        .await
        .unwrap()
        .unwrap();
    (
        row.try_get("", "accepted").unwrap(),
        row.try_get("", "bytes").unwrap(),
    )
}

fn rows(page: &Value) -> Vec<(String, String)> {
    page["rows"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| {
            (
                row["cursor"].as_str().unwrap().to_owned(),
                row["body"].as_str().unwrap().to_owned(),
            )
        })
        .collect()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "internal kill child; launched by acknowledged_logs_survive_kill_and_restart_without_r2"]
async fn log_kill_child() {
    let name = std::env::var(CHILD_NAME).expect("parent supplies child identity");
    let ready = PathBuf::from(std::env::var_os(CHILD_READY).unwrap());
    let env = TestEnv::new(&name);
    let boot = env.boot_memory(quiet_batches).await.unwrap();
    let (base, _server) = serve(&boot).await;
    let api = Api::signup(&base, &format!("{name}@example.test")).await;
    let (org, project, dsn) = api.setup_source("Kill after acknowledgement").await;
    for marker in [
        "kill-marker-alpha",
        "kill-marker-bravo",
        "kill-marker-charlie",
    ] {
        let (status, _) = post_envelope(
            &base,
            project,
            &dsn_key(&dsn),
            envelope(None, &[marker]),
            None,
        )
        .await;
        assert_eq!(status, StatusCode::OK, "{marker} acknowledged");
    }
    let (status, page) = api.get(&format!("/api/orgs/{org}/logs?limit=10")).await;
    assert_eq!(status, StatusCode::OK);
    let rt = Runtime::get(&boot.app_context);
    let usage = log_usage(&rt, &org.parse().unwrap()).await;
    let report = json!({"org": org, "rows": rows(&page), "usage": usage});
    let temporary = ready.with_extension("tmp");
    std::fs::write(&temporary, report.to_string()).unwrap();
    std::fs::rename(temporary, ready).unwrap();
    std::future::pending::<()>().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn acknowledged_logs_survive_kill_and_restart_without_r2() {
    let name = format!("log-kill-{}", uuid::Uuid::now_v7().simple());
    let env = TestEnv::new(&name);
    let ready = env.dir.join("child.ready");
    let log = std::fs::File::create(env.dir.join("child.log")).unwrap();
    let run = env.dir.parent().unwrap();
    let mut child = OwnedChild(
        Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "log_kill_child",
                "--ignored",
                "--nocapture",
                "--test-threads=1",
            ])
            .env(CHILD_NAME, &name)
            .env(CHILD_READY, &ready)
            .env("POSTDEPLOY_TEST_ROOT", run.parent().unwrap())
            .env("POSTDEPLOY_TEST_RUN", run.file_name().unwrap())
            .stdout(log.try_clone().unwrap())
            .stderr(log)
            .spawn()
            .unwrap(),
    );
    let deadline = Instant::now() + Duration::from_secs(120);
    while !ready.exists() {
        assert!(
            child.0.try_wait().unwrap().is_none(),
            "child exited early; see child.log"
        );
        assert!(Instant::now() < deadline, "child timed out; see child.log");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let report: Value = serde_json::from_str(&std::fs::read_to_string(&ready).unwrap()).unwrap();
    child.0.kill().unwrap();
    let status = child.0.wait().unwrap();
    assert_eq!(
        std::os::unix::process::ExitStatusExt::signal(&status),
        Some(9)
    );
    let before: Vec<(String, String)> = serde_json::from_value(report["rows"].clone()).unwrap();
    assert_eq!(
        before
            .iter()
            .map(|(_, body)| body.as_str())
            .collect::<Vec<_>>(),
        [
            "kill-marker-charlie",
            "kill-marker-bravo",
            "kill-marker-alpha"
        ]
    );
    let tenants = env.tenant_root();
    for marker in [
        "kill-marker-alpha",
        "kill-marker-bravo",
        "kill-marker-charlie",
    ] {
        assert_eq!(
            file_contains(&tenants, marker.as_bytes()),
            Vec::<String>::new(),
            "{marker} must not be stored as plaintext in SQLite or WAL"
        );
    }

    env.faults.fail_puts.store(u32::MAX, Ordering::SeqCst);
    let boot = env.boot_memory(quiet_batches).await.unwrap();
    let (base, server) = serve(&boot).await;
    let rt = Runtime::get(&boot.app_context);
    let org: OrgId = report["org"].as_str().unwrap().parse().unwrap();
    let mut api = Api::new(&base);
    assert_eq!(
        api.auth("login", &format!("{name}@example.test"), PASSWORD)
            .await
            .0,
        StatusCode::OK
    );
    let (status, page) = api.get(&format!("/api/orgs/{org}/logs?limit=10")).await;
    assert_eq!(status, StatusCode::OK, "{page}");
    assert_eq!(rows(&page), before, "same entries and cursors after kill");
    let usage: (i64, i64) = serde_json::from_value(report["usage"].clone()).unwrap();
    assert_eq!(usage.0, 3);
    assert_eq!(log_usage(&rt, &org).await, usage, "usage counted once");
    assert_eq!(rt.store.counters().put_bytes.load(Ordering::SeqCst), 0);
    rt.shutdown().await;
    server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn appends_to_one_open_object_reach_an_attached_tail_once_and_resume_per_entry() {
    let env = TestEnv::new("log-open-tail");
    let boot = env.boot_memory(quiet_batches).await.unwrap();
    let (base, server) = serve(&boot).await;
    let api = Api::signup(&base, "open-tail@example.test").await;
    let (org, project, dsn) = api.setup_source("Open tail").await;
    let key = dsn_key(&dsn);
    let (status, _) =
        post_envelope(&base, project, &key, envelope(None, &["tail-first"]), None).await;
    assert_eq!(status, StatusCode::OK);
    let response = api
        .http
        .get(format!("{base}/api/orgs/{org}/logs/tail"))
        .header("cookie", api.cookie.clone().unwrap())
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let sender = {
        let base = base.clone();
        let key = key.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(300)).await;
            for marker in ["tail-second", "tail-third"] {
                let (status, _) =
                    post_envelope(&base, project, &key, envelope(None, &[marker]), None).await;
                assert_eq!(status, StatusCode::OK);
                tokio::time::sleep(Duration::from_millis(200)).await;
            }
        })
    };
    let mut seen = Vec::new();
    let events = read_sse(response, Duration::from_secs(10), |name, value| {
        if name == "entries" {
            for row in value["rows"].as_array().unwrap() {
                seen.push((
                    row["cursor"].as_str().unwrap().to_owned(),
                    row["body"].as_str().unwrap().to_owned(),
                ));
            }
        }
        seen.len() >= 2
    })
    .await;
    sender.await.unwrap();
    let (status, page) = api.get(&format!("/api/orgs/{org}/logs?limit=10")).await;
    assert_eq!(status, StatusCode::OK);
    let all = rows(&page);
    let first_cursor = all.last().unwrap().0.clone();
    let seq = first_cursor.split('.').nth(1).unwrap().to_owned();
    assert_eq!(
        all,
        [
            (format!("c1.{seq}.2"), "tail-third".to_owned()),
            (format!("c1.{seq}.1"), "tail-second".to_owned()),
            (format!("c1.{seq}.0"), "tail-first".to_owned()),
        ],
        "three appends share one open object"
    );
    assert_eq!(
        seen,
        [
            (format!("c1.{seq}.1"), "tail-second".to_owned()),
            (format!("c1.{seq}.2"), "tail-third".to_owned()),
        ],
        "tail events: {events:?}"
    );
    for (after, expected) in [
        (format!("c1.{seq}.0"), vec!["tail-second", "tail-third"]),
        (format!("c1.{seq}.1"), vec!["tail-third"]),
    ] {
        let response = api
            .http
            .get(format!("{base}/api/orgs/{org}/logs/tail?after={after}"))
            .header("cookie", api.cookie.clone().unwrap())
            .send()
            .await
            .unwrap();
        let mut bodies = Vec::new();
        read_sse(response, Duration::from_secs(5), |name, value| {
            if name == "entries" {
                for row in value["rows"].as_array().unwrap() {
                    bodies.push(row["body"].as_str().unwrap().to_owned());
                }
            }
            bodies.len() >= expected.len()
        })
        .await;
        assert_eq!(bodies, expected, "resume after {after}");
    }
    Runtime::get(&boot.app_context).shutdown().await;
    server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn storage_status_reports_pending_entries_then_the_archive() {
    let env = TestEnv::new("log-storage-status");
    let boot = env
        .boot_memory(|settings| {
            settings["logs"]["batch_max_age_ms"] = json!(300);
            settings["logs"]["archive_tick_ms"] = json!(50);
        })
        .await
        .unwrap();
    let (base, server) = serve(&boot).await;
    let api = Api::signup(&base, "storage-status@example.test").await;
    let (org, project, dsn) = api.setup_source("Status").await;
    env.faults.fail_puts.store(u32::MAX, Ordering::SeqCst);
    let (status, _) = post_envelope(
        &base,
        project,
        &dsn_key(&dsn),
        envelope(None, &["status-marker"]),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (status, pending) = api.get(&format!("/api/orgs/{org}/logs/storage")).await;
    assert_eq!(status, StatusCode::OK, "{pending}");
    assert_eq!(pending["pending_entries"], 1);
    assert_eq!(pending["archived_objects"], 0);
    assert_eq!(pending["last_archive"], Value::Null);
    assert_eq!(pending["backlog_limit_bytes"], 64 << 20);
    eventually(Duration::from_secs(10), || {
        let api = api.clone();
        let org = org.clone();
        async move {
            let (_, status) = api.get(&format!("/api/orgs/{org}/logs/storage")).await;
            status["archive_failure"]["reason"] == "store_unavailable"
                && status["sealed_objects"] == 1
        }
    })
    .await;
    env.faults.fail_puts.store(0, Ordering::SeqCst);
    eventually(Duration::from_secs(10), || {
        let api = api.clone();
        let org = org.clone();
        async move {
            let (_, status) = api.get(&format!("/api/orgs/{org}/logs/storage")).await;
            status["pending_entries"] == 0 && status["archived_objects"] == 1
        }
    })
    .await;
    let (_, archived) = api.get(&format!("/api/orgs/{org}/logs/storage")).await;
    let object = archived["last_archive"]["object"].as_i64().unwrap();
    assert_eq!(archived["last_archive"]["entries"], 1);
    assert_eq!(archived["archive_failure"], Value::Null);
    let key = archived["last_archive"]["key"].as_str().unwrap();
    assert!(key.starts_with(&format!("logs/v1/{org}/v2/")), "{key}");
    assert!(env.store.get(key, 1 << 20).await.unwrap().is_some());
    let (_, page) = api.get(&format!("/api/orgs/{org}/logs?limit=10")).await;
    assert_eq!(
        rows(&page),
        [(format!("c1.{object}.0"), "status-marker".to_owned())]
    );
    Runtime::get(&boot.app_context).shutdown().await;
    server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn organization_backlog_limit_refuses_with_503_and_unchanged_usage() {
    let env = TestEnv::new("log-backlog-limit");
    let boot = env
        .boot_memory(|settings| {
            quiet_batches(settings);
            settings["logs"]["org_backlog_bytes"] = json!(4_096);
        })
        .await
        .unwrap();
    let (base, server) = serve(&boot).await;
    let rt = Runtime::get(&boot.app_context);
    let api = Api::signup(&base, "backlog-limit@example.test").await;
    let (org, project, dsn) = api.setup_source("Backlog").await;
    let org_id: OrgId = org.parse().unwrap();
    env.faults.fail_puts.store(u32::MAX, Ordering::SeqCst);
    let body = "b".repeat(1_500);
    let (status, _) = post_envelope(
        &base,
        project,
        &dsn_key(&dsn),
        envelope(None, &[&body]),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (status, _) = post_envelope(
        &base,
        project,
        &dsn_key(&dsn),
        envelope(None, &[&body]),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let accepted = log_usage(&rt, &org_id).await;
    let (status, refusal) = post_envelope(
        &base,
        project,
        &dsn_key(&dsn),
        envelope(None, &[&body]),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(refusal, json!({"error": "log_backlog_full"}));
    assert_eq!(log_usage(&rt, &org_id).await, accepted);
    let other = Api::signup(&base, "backlog-other@example.test").await;
    let (other_org, other_project, other_dsn) = other.setup_source("Other").await;
    let (status, _) = post_envelope(
        &base,
        other_project,
        &dsn_key(&other_dsn),
        envelope(None, &[&body]),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "another organization is isolated");
    let (_, page) = other.get(&format!("/api/orgs/{other_org}/logs")).await;
    assert_eq!(page["rows"].as_array().unwrap().len(), 1);
    rt.shutdown().await;
    server.abort();
}

struct Ctx {
    env: TestEnv,
    boot: loco_rs::boot::BootResult,
    server: tokio::task::JoinHandle<()>,
    base: String,
    rt: std::sync::Arc<Runtime>,
    api: Api,
    org: String,
    org_id: OrgId,
    project: i64,
    key: String,
}

impl Ctx {
    async fn new(name: &str, settings: impl FnOnce(&mut Value)) -> Self {
        let env = TestEnv::new(name);
        let boot = env.boot_memory(settings).await.unwrap();
        let (base, server) = serve(&boot).await;
        let rt = Runtime::get(&boot.app_context);
        let api = Api::signup(&base, &format!("{name}@example.test")).await;
        let (org, project, dsn) = api.setup_source(name).await;
        Self {
            env,
            boot,
            server,
            base,
            rt,
            api,
            org_id: org.parse().unwrap(),
            org,
            project,
            key: dsn_key(&dsn),
        }
    }

    async fn add_source(&self, environment: &str) -> (i64, i64, String) {
        let (status, project) = self
            .api
            .post(
                &format!("/api/orgs/{}/projects", self.org),
                json!({"name": format!("p-{environment}")}),
            )
            .await;
        assert_eq!(status, StatusCode::CREATED);
        let project = project["id"].as_i64().unwrap();
        let (status, source) = self
            .api
            .post(
                &format!("/api/orgs/{}/projects/{project}/sources", self.org),
                json!({"name": "second", "environment": environment}),
            )
            .await;
        assert_eq!(status, StatusCode::CREATED);
        let dsn = source["dsn"].as_str().unwrap().to_owned();
        (
            project,
            source["source"]["id"].as_i64().unwrap(),
            dsn_key(&dsn),
        )
    }

    async fn send_to(&self, project: i64, key: &str, bodies: &[&str]) -> (StatusCode, Value) {
        post_envelope(&self.base, project, key, envelope(None, bodies), None).await
    }

    async fn send(&self, bodies: &[&str]) -> (StatusCode, Value) {
        self.send_to(self.project, &self.key, bodies).await
    }

    async fn search(&self, query: &str) -> Vec<(String, String)> {
        let (status, page) = self
            .api
            .get(&format!("/api/orgs/{}/logs?limit=200{query}", self.org))
            .await;
        assert_eq!(status, StatusCode::OK, "{page}");
        rows(&page)
    }

    async fn status(&self) -> Value {
        let (status, body) = self
            .api
            .get(&format!("/api/orgs/{}/logs/storage", self.org))
            .await;
        assert_eq!(status, StatusCode::OK, "{body}");
        body
    }

    async fn tail_bodies(&self, query: &str, expected: usize) -> Vec<String> {
        let response = self
            .api
            .http
            .get(format!(
                "{}/api/orgs/{}/logs/tail?{query}",
                self.base, self.org
            ))
            .header("cookie", self.api.cookie.clone().unwrap())
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let mut bodies = Vec::new();
        read_sse(response, Duration::from_secs(3), |name, value| {
            if name == "entries" {
                for row in value["rows"].as_array().unwrap() {
                    bodies.push(row["body"].as_str().unwrap().to_owned());
                }
            }
            bodies.len() >= expected
        })
        .await;
        bodies
    }

    async fn scalar(&self, query: &str) -> i64 {
        let tenant = self.rt.tenant(&self.org_id).await.unwrap();
        tenant
            .query_one_raw(sql(query, vec![]))
            .await
            .unwrap()
            .unwrap()
            .try_get_by_index::<i64>(0)
            .unwrap()
    }

    async fn close(self) {
        self.rt.shutdown().await;
        self.server.abort();
        drop(self.boot);
    }
}

fn bodies(rows: &[(String, String)]) -> Vec<&str> {
    rows.iter().map(|(_, body)| body.as_str()).collect()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn interleaved_projects_keep_entry_permissions_and_cursors_through_open_sealed_and_archived()
{
    let c = Ctx::new("log-mixed-partitions", |s| {
        s["logs"]["batch_max_age_ms"] = json!(600_000);
        s["logs"]["batch_max_entries"] = json!(3);
        s["logs"]["archive_tick_ms"] = json!(50);
    })
    .await;
    let (staging_project, staging_source, staging_key) = c.add_source("staging").await;
    c.env.faults.fail_puts.store(u32::MAX, Ordering::SeqCst);
    assert_eq!(c.send(&["mix-a"]).await.0, StatusCode::OK);
    assert_eq!(
        c.send_to(staging_project, &staging_key, &["mix-b"]).await.0,
        StatusCode::OK
    );
    let open_rows = c.search("").await;
    let seq = open_rows[0].0.split('.').nth(1).unwrap().to_owned();
    assert_eq!(
        open_rows,
        [
            (format!("c1.{seq}.1"), "mix-b".to_owned()),
            (format!("c1.{seq}.0"), "mix-a".to_owned()),
        ]
    );
    assert_eq!(
        c.tail_bodies(&format!("after=c1.{seq}.0"), 1).await,
        ["mix-b"]
    );
    assert_eq!(c.send(&["mix-c"]).await.0, StatusCode::OK);
    assert_eq!(
        c.status().await["sealed_objects"],
        1,
        "third entry fills the batch"
    );

    let (status, owner) = c
        .api
        .get(&format!(
            "/api/orgs/{}/logs?project={staging_project}",
            c.org
        ))
        .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(owner["rows"][0]["project_id"], staging_project);
    assert_eq!(owner["rows"][0]["source_id"], staging_source);
    assert_eq!(owner["rows"][0]["environment"], "staging");

    for stage in ["sealed", "archived"] {
        if stage == "archived" {
            c.env.faults.fail_puts.store(0, Ordering::SeqCst);
            eventually(Duration::from_secs(10), || async {
                c.status().await["archived_objects"] == 1
            })
            .await;
            assert_eq!(
                c.scalar("SELECT COUNT(*) FROM log_entries_pending").await,
                0
            );
        }
        assert_eq!(
            bodies(&c.search(&format!("&project={}", c.project)).await),
            ["mix-c", "mix-a"],
            "{stage}: project filter uses each entry"
        );
        assert_eq!(
            bodies(&c.search(&format!("&project={staging_project}")).await),
            ["mix-b"],
            "{stage}"
        );
        assert_eq!(
            bodies(&c.search("&environment=staging").await),
            ["mix-b"],
            "{stage}"
        );
        assert_eq!(
            bodies(&c.search(&format!("&source={staging_source}")).await),
            ["mix-b"],
            "{stage}"
        );
        assert_eq!(
            c.tail_bodies(&format!("after=c1.{seq}.0"), 2).await,
            ["mix-b", "mix-c"],
            "{stage}"
        );
        assert_eq!(
            c.tail_bodies(&format!("after=c1.{seq}.1"), 1).await,
            ["mix-c"],
            "{stage}"
        );
        assert_eq!(
            c.tail_bodies(&format!("after=c1.{seq}.0&project={}", c.project), 1)
                .await,
            ["mix-c"],
            "{stage}"
        );
    }

    let user: i64 = {
        let row =
            c.rt.control
                .query_one_raw(sql(
                    "SELECT user_id FROM memberships WHERE org_id = ?",
                    vec![c.org.clone().into()],
                ))
                .await
                .unwrap()
                .unwrap();
        row.try_get("", "user_id").unwrap()
    };
    let access =
        postdeploy::identity::access::authorize(&c.rt, postdeploy::domain::UserId(user), &c.org_id)
            .await
            .unwrap();
    let reports = &postdeploy::services::Services::get(&c.boot.app_context).reports;
    let report = |cursor: String| {
        serde_json::from_value(json!({"project_id": staging_project, "title": "Mixed", "summary": "mixed batch",
            "findings": [{"title": "Entry", "severity": "low", "detail": "entry", "evidence": [{"kind": "log", "cursor": cursor}]}]}))
        .unwrap()
    };
    let foreign = reports
        .publish(&access, report(format!("c1.{seq}.0")))
        .await;
    assert!(
        matches!(
            foreign,
            Err(postdeploy::error::ApiError::BadRequest("unknown_evidence"))
        ),
        "an entry of another project in the same batch is not evidence for this project"
    );
    let own = reports
        .publish(&access, report(format!("c1.{seq}.1")))
        .await
        .unwrap();
    let view = reports.get(&access, &own.report.id).await.unwrap();
    let facts = view.evidence[0].log.as_ref().unwrap();
    assert_eq!((facts.object_id.to_string(), facts.entry_count), (seq, 1));
    c.close().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn failed_put_response_after_a_stored_object_converges_to_one_object_and_one_charge() {
    let c = Ctx::new("log-put-after-write", fast_archive).await;
    c.env.faults.fail_put_after_write.store(1, Ordering::SeqCst);
    c.env
        .faults
        .pause_after_log_put
        .store(true, Ordering::SeqCst);
    assert_eq!(c.send(&["after-write-marker"]).await.0, StatusCode::OK);
    tokio::time::timeout(Duration::from_secs(10), c.env.faults.log_paused.notified())
        .await
        .expect("archive reached the point after its conditional PUT");
    let usage = log_usage(&c.rt, &c.org_id).await;
    assert_eq!(usage.0, 1);
    assert_eq!(
        c.rt.store
            .list_page("logs/", None, 4)
            .await
            .unwrap()
            .keys
            .len(),
        1
    );
    assert_eq!(
        bodies(&c.search("").await),
        ["after-write-marker"],
        "the paused archive transition returns the entry once"
    );
    c.env.faults.log_resume.notify_one();
    eventually(Duration::from_secs(10), || async {
        c.status().await["archived_objects"] == 1
    })
    .await;
    assert_eq!(
        c.rt.store
            .list_page("logs/", None, 4)
            .await
            .unwrap()
            .keys
            .len(),
        1
    );
    assert_eq!(c.scalar("SELECT COUNT(*) FROM log_objects").await, 1);
    assert_eq!(
        c.scalar("SELECT COUNT(*) FROM log_entries_pending").await,
        0
    );
    assert_eq!(log_usage(&c.rt, &c.org_id).await, usage, "no second charge");
    let stored = c.status().await["last_archive"]["stored_bytes"]
        .as_u64()
        .unwrap();
    assert_eq!(
        c.rt.store.counters().put_bytes.load(Ordering::SeqCst),
        stored,
        "exactly one body was written; the retry found and verified it"
    );
    assert_eq!(c.rt.store.counters().puts.load(Ordering::SeqCst), 2);
    assert_eq!(bodies(&c.search("").await), ["after-write-marker"]);
    c.close().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn quota_refusal_returns_429_and_changes_no_usage() {
    let c = Ctx::new("log-quota-refusal", |s| {
        quiet_batches(s);
        s["quotas"]["daily_logs"] = json!(2);
    })
    .await;
    assert_eq!(c.send(&["quota-one", "quota-two"]).await.0, StatusCode::OK);
    let usage = log_usage(&c.rt, &c.org_id).await;
    let (status, body) = c.send(&["quota-three"]).await;
    assert_eq!(status, StatusCode::TOO_MANY_REQUESTS);
    assert_eq!(body, json!({"error": "rate_limited"}));
    assert_eq!(log_usage(&c.rt, &c.org_id).await, usage);
    assert_eq!(bodies(&c.search("").await), ["quota-two", "quota-one"]);
    c.close().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn concurrent_requests_racing_the_age_seal_land_whole_in_one_batch() {
    let c = Ctx::new("log-seal-race", |s| {
        s["logs"]["batch_max_age_ms"] = json!(30);
        s["logs"]["archive_tick_ms"] = json!(10);
    })
    .await;
    let mut requests = Vec::new();
    for request in 0..12 {
        let base = c.base.clone();
        let key = c.key.clone();
        let project = c.project;
        requests.push(tokio::spawn(async move {
            let markers: Vec<String> = (0..5).map(|i| format!("race-{request}-{i}")).collect();
            let refs: Vec<&str> = markers.iter().map(String::as_str).collect();
            post_envelope(&base, project, &key, envelope(None, &refs), None)
                .await
                .0
        }));
        tokio::time::sleep(Duration::from_millis(7)).await;
    }
    for request in requests {
        assert_eq!(request.await.unwrap(), StatusCode::OK);
    }
    let rows = c.search("").await;
    assert_eq!(rows.len(), 60);
    let objects: std::collections::BTreeSet<&str> = rows
        .iter()
        .map(|(cursor, _)| cursor.split('.').nth(1).unwrap())
        .collect();
    assert!(
        objects.len() >= 2,
        "the age seal ran during the burst: {objects:?}"
    );
    for request in 0..12 {
        let mut positions: Vec<(i64, u32, String)> = rows
            .iter()
            .filter(|(_, body)| body.starts_with(&format!("race-{request}-")))
            .map(|(cursor, body)| {
                let mut parts = cursor.split('.').skip(1);
                (
                    parts.next().unwrap().parse().unwrap(),
                    parts.next().unwrap().parse().unwrap(),
                    body.clone(),
                )
            })
            .collect();
        positions.sort();
        let object = positions[0].0;
        let first = positions[0].1;
        assert_eq!(
            positions,
            (0..5)
                .map(|i| (object, first + i, format!("race-{request}-{i}")))
                .collect::<Vec<_>>(),
            "request {request} is contiguous within one batch"
        );
    }
    assert_eq!(log_usage(&c.rt, &c.org_id).await.0, 60);
    c.close().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_utc_day_change_seals_the_batch_and_charges_each_day() {
    use postdeploy::{
        domain::{now_micros, utc_day, Environment, ProjectId, SourceId},
        logs::{object::Partition, record::LogRecord, storage},
        quota::Usage,
    };
    let c = Ctx::new("log-day-rollover", |s| {
        quiet_batches(s);
        s["logs"]["retention_secs"] = json!(172_800);
    })
    .await;
    let source =
        c.rt.control
            .query_one_raw(sql(
                "SELECT id FROM sources WHERE project_id = ?",
                vec![c.project.into()],
            ))
            .await
            .unwrap()
            .unwrap()
            .try_get::<i64>("", "id")
            .unwrap();
    let partition = Partition {
        org: c.org_id.clone(),
        project: ProjectId(c.project),
        source: SourceId(source),
        environment: Environment::parse("production").unwrap(),
    };
    let now = now_micros();
    let yesterday = now - 86_400_000_000;
    let mut cursors = Vec::new();
    for (received, body) in [(yesterday, "before-midnight"), (now, "after-midnight")] {
        let record: LogRecord = serde_json::from_value(
            json!({"ts": received, "rt": received, "level": "info", "body": body, "attributes": {}}),
        )
        .unwrap();
        let hold =
            c.rt.quotas
                .reserve_at(
                    &c.rt,
                    &c.org_id,
                    Usage {
                        logs: 1,
                        log_bytes: record.approx_bytes() as u64,
                        ..Usage::default()
                    },
                    received,
                )
                .await
                .unwrap();
        let at = storage::append(&c.rt, &partition, vec![record], hold)
            .await
            .unwrap();
        cursors.push(
            postdeploy::logs::read::CursorEpoch::INITIAL
                .token(at)
                .to_string(),
        );
    }
    assert_eq!(
        cursors,
        ["c1.1.0", "c1.2.0"],
        "the day change opened a new batch"
    );
    let tenant = c.rt.tenant(&c.org_id).await.unwrap();
    let rows = tenant
        .query_all_raw(sql(
            "SELECT day, accepted FROM usage_daily WHERE category = 'log' ORDER BY day",
            vec![],
        ))
        .await
        .unwrap();
    let days: Vec<(String, i64)> = rows
        .iter()
        .map(|row| {
            (
                row.try_get("", "day").unwrap(),
                row.try_get("", "accepted").unwrap(),
            )
        })
        .collect();
    drop(tenant);
    assert_eq!(days, [(utc_day(yesterday), 1), (utc_day(now), 1)]);
    assert_eq!(
        c.scalar("SELECT COUNT(*) FROM log_objects WHERE state = 'sealed' AND id = 1")
            .await,
        1
    );
    c.close().await;
}

fn restore_settings(settings: &mut Value) {
    settings["logs"]["batch_max_age_ms"] = json!(600_000);
    settings["logs"]["batch_max_entries"] = json!(3);
    settings["logs"]["archive_tick_ms"] = json!(50);
    settings["logs"]["reconcile_max_objects"] = json!(1);
}

/// Replaces the organization's database with an offline restored file, the
/// way an operator activates a supported restore while the server is down.
fn activate(env: &TestEnv, org: &OrgId, restored: &std::path::Path) {
    let live = env.tenant_root().join(format!("{org}.db"));
    for suffix in ["-wal", "-shm"] {
        let sidecar = PathBuf::from(format!("{}{suffix}", live.display()));
        if sidecar.exists() {
            std::fs::remove_file(sidecar).unwrap();
        }
    }
    std::fs::copy(restored, &live).unwrap();
}

async fn login(base: &str, email: &str) -> Api {
    let mut api = Api::new(base);
    assert_eq!(api.auth("login", email, PASSWORD).await.0, StatusCode::OK);
    api
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn restoring_an_older_database_recovers_the_r2_superset_once_and_never_reuses_cursors() {
    let name = "log-restore-superset";
    let c = Ctx::new(name, restore_settings).await;
    assert_eq!(c.send(&["restore-a"]).await.0, StatusCode::OK);
    assert_eq!(c.send(&["restore-b"]).await.0, StatusCode::OK);
    let backup = backup_org(&c).await;
    assert_eq!(c.send(&["restore-c"]).await.0, StatusCode::OK);
    assert_eq!(
        c.send(&["restore-d", "restore-e", "restore-f"]).await.0,
        StatusCode::OK
    );
    eventually(Duration::from_secs(10), || async {
        let status = c.status().await;
        status["archived_objects"] == 2 && status["pending_entries"] == 0
    })
    .await;
    let before = c.search("").await;
    assert_eq!(
        before
            .iter()
            .map(|(cursor, body)| format!("{cursor}={body}"))
            .collect::<Vec<_>>(),
        [
            "c1.2.2=restore-f",
            "c1.2.1=restore-e",
            "c1.2.0=restore-d",
            "c1.1.2=restore-c",
            "c1.1.1=restore-b",
            "c1.1.0=restore-a"
        ]
    );
    let usage = log_usage(&c.rt, &c.org_id).await;
    assert_eq!(usage.0, 6);
    let objects = c.rt.store.list_page("logs/", None, 10).await.unwrap().keys;
    assert_eq!(objects.len(), 2);
    let restored_dir = c.env.dir.join("restored");
    std::fs::create_dir_all(&restored_dir).unwrap();
    let mut restores = Vec::new();
    let mut epochs = Vec::new();
    for attempt in 0..2 {
        let destination = restored_dir.join(format!("org-{attempt}.db"));
        restore_org(&c, backup, &destination).await;
        restores.push(destination);
    }
    let Ctx {
        env,
        boot,
        server,
        rt,
        org_id,
        org,
        project,
        key,
        ..
    } = c;
    rt.shutdown().await;
    server.abort();
    drop((rt, boot));

    for restored in &restores {
        activate(&env, &org_id, restored);
        let written = env.store.counters().put_bytes.load(Ordering::SeqCst);
        let deleted = env.store.counters().deletes.load(Ordering::SeqCst);
        env.faults.delay_get_ms.store(5_000, Ordering::SeqCst);
        let boot = env.boot_memory(restore_settings).await.unwrap();
        let (base, server) = serve(&boot).await;
        let rt = Runtime::get(&boot.app_context);
        let api = login(&base, &format!("{name}@example.test")).await;
        let (status, refusal) = post_envelope(
            &base,
            project,
            &key,
            envelope(None, &["restore-early"]),
            None,
        )
        .await;
        assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(refusal, json!({"error": "log_restore_pending"}));
        let (status, refusal) = api.get(&format!("/api/orgs/{org}/logs")).await;
        assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(refusal, json!({"error": "log_restore_pending"}));
        let (_, status) = api.get(&format!("/api/orgs/{org}/logs/storage")).await;
        assert_eq!(status["restore_required"], true);
        env.faults.delay_get_ms.store(0, Ordering::SeqCst);
        eventually(Duration::from_secs(20), || {
            let api = api.clone();
            let org = org.clone();
            async move {
                let (_, status) = api.get(&format!("/api/orgs/{org}/logs/storage")).await;
                status["restore_required"] == false
            }
        })
        .await;
        let (status, page) = api.get(&format!("/api/orgs/{org}/logs?limit=50")).await;
        assert_eq!(status, StatusCode::OK);
        let restored = rows(&page);
        let epoch = epoch_of(&restored[0].0);
        assert_eq!(
            restored,
            before
                .iter()
                .map(|(cursor, body)| (
                    cursor.replacen("c1.", &format!("c2.{epoch}."), 1),
                    body.clone()
                ))
                .collect::<Vec<_>>(),
            "original ids and entries in a new cursor epoch"
        );
        epochs.push(epoch);
        assert_eq!(
            log_usage(&rt, &org_id).await,
            usage,
            "suffix and missing object charged once"
        );
        let (_, status) = api.get(&format!("/api/orgs/{org}/logs/storage")).await;
        assert_eq!(status["orphan_cleanup_held"], true);
        assert_eq!(status["archived_objects"], 2);
        assert_eq!(
            rt.store.list_page("logs/", None, 10).await.unwrap().keys,
            objects,
            "no R2 object was added, replaced or deleted"
        );
        assert_eq!(
            rt.store.counters().put_bytes.load(Ordering::SeqCst),
            written
        );
        assert_eq!(rt.store.counters().deletes.load(Ordering::SeqCst), deleted);
        rt.shutdown().await;
        server.abort();
    }

    let boot = env.boot_memory(restore_settings).await.unwrap();
    let (base, server) = serve(&boot).await;
    let rt = Runtime::get(&boot.app_context);
    let api = login(&base, &format!("{name}@example.test")).await;
    let (status, _) =
        post_envelope(&base, project, &key, envelope(None, &["restore-g"]), None).await;
    assert_eq!(status, StatusCode::OK);
    assert_ne!(epochs[0], epochs[1], "each restore starts its own epoch");
    let (_, page) = api.get(&format!("/api/orgs/{org}/logs?limit=1")).await;
    assert_eq!(
        rows(&page),
        [(format!("c2.{}.3.0", epochs[1]), "restore-g".to_owned())],
        "the next batch id is above every recovered id"
    );
    rt.shutdown().await;
    server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_differing_object_at_a_sealed_key_is_an_explicit_conflict_without_overwrite() {
    use postdeploy::logs::object::{decode, encode_batch, BatchIdentity};
    let c = Ctx::new("log-archive-conflict", restore_settings).await;
    c.env.faults.fail_puts.store(u32::MAX, Ordering::SeqCst);
    assert_eq!(
        c.send(&["conflict-a", "conflict-b", "conflict-c"]).await.0,
        StatusCode::OK
    );
    let (key, opened_at, usage_day): (String, i64, String) = {
        let tenant = c.rt.tenant(&c.org_id).await.unwrap();
        let row = tenant
            .query_one_raw(sql(
                "SELECT object_key, opened_at, usage_day FROM log_objects WHERE id = 1 AND state = 'sealed'",
                vec![],
            ))
            .await
            .unwrap()
            .unwrap();
        (
            row.try_get("", "object_key").unwrap(),
            row.try_get("", "opened_at").unwrap(),
            row.try_get("", "usage_day").unwrap(),
        )
    };
    let identity = BatchIdentity {
        org: c.org_id.clone(),
        object_id: 1,
        key: key.clone(),
        usage_day,
        opened_at,
    };
    let mut entries = Vec::new();
    {
        let tenant = c.rt.tenant(&c.org_id).await.unwrap();
        let pending = tenant
            .query_all_raw(sql(
                "SELECT entry, project_id, source_id, environment, billable_bytes, sealed
                 FROM log_entries_pending WHERE object_id = 1 ORDER BY entry",
                vec![],
            ))
            .await
            .unwrap();
        for row in pending {
            let environment: String = row.try_get("", "environment").unwrap();
            let sealed: Vec<u8> = row.try_get("", "sealed").unwrap();
            entries.push(
                c.rt.pending_cipher
                    .open(
                        &postdeploy::logs::pending::Slot {
                            org: &c.org_id,
                            object_id: 1,
                            entry: row.try_get::<i64>("", "entry").unwrap() as u32,
                            project: row.try_get("", "project_id").unwrap(),
                            source: row.try_get("", "source_id").unwrap(),
                            environment: &environment,
                            billable_bytes: row.try_get::<i64>("", "billable_bytes").unwrap()
                                as u64,
                        },
                        &sealed,
                    )
                    .unwrap(),
            );
        }
    }
    assert_eq!(entries.len(), 3);
    let mut changed = serde_json::to_value(&entries[1].record).unwrap();
    changed["body"] = json!("conflict-CHANGED");
    entries[1].record = serde_json::from_value(changed).unwrap();
    let planted = encode_batch(&identity, &entries).unwrap();
    eventually(Duration::from_secs(10), || async {
        c.status().await["archive_failure"]["reason"] == "store_unavailable"
    })
    .await;
    c.env.faults.fail_puts.store(0, Ordering::SeqCst);
    c.env.store.put(&key, planted.body.clone()).await.unwrap();
    eventually(Duration::from_secs(10), || async {
        c.status().await["archive_failure"]["reason"] == "remote_prefix_mismatch"
    })
    .await;
    assert_eq!(c.status().await["sealed_objects"], 1);
    assert_eq!(
        c.scalar("SELECT COUNT(*) FROM log_entries_pending").await,
        3
    );
    assert_eq!(
        c.env.store.get(&key, 1 << 20).await.unwrap().unwrap(),
        planted.body,
        "the conflicting object is never replaced"
    );
    assert_eq!(
        bodies(&c.search("").await),
        ["conflict-c", "conflict-b", "conflict-a"],
        "acknowledged entries stay readable from SQLite"
    );

    let tenant = c.rt.tenant(&c.org_id).await.unwrap();
    tenant
        .execute_unprepared(
            "UPDATE restore_state SET logs_reconcile_required = 1, orphan_cleanup_held = 1",
        )
        .await
        .unwrap();
    drop(tenant);
    c.rt.mark_dirty(&c.org_id);
    eventually(Duration::from_secs(10), || async {
        c.status().await["restore_conflict"] == "remote_prefix_mismatch"
    })
    .await;
    let (status, refusal) = c.send(&["conflict-late"]).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(refusal, json!({"error": "log_restore_conflict"}));
    let (status, refusal) = c.api.get(&format!("/api/orgs/{}/logs", c.org)).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(refusal, json!({"error": "log_restore_conflict"}));
    assert_eq!(
        c.scalar("SELECT COUNT(*) FROM log_entries_pending").await,
        3
    );
    let Ok((_, stored)) = decode(
        &c.env.store.get(&key, 1 << 20).await.unwrap().unwrap(),
        1 << 20,
    ) else {
        panic!("planted object stays a batch");
    };
    assert_eq!(stored[1].record.body.as_str(), "conflict-CHANGED");
    c.close().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn restore_refuses_an_object_outside_the_batch_layout() {
    let c = Ctx::new("log-restore-unmapped", restore_settings).await;
    let key = format!(
        "logs/v1/{}/{}/1/production/2026101612/orphan.ndjson.zst",
        c.org_id, c.project
    );
    c.env
        .store
        .put(&key, bytes::Bytes::from_static(b"unmapped"))
        .await
        .unwrap();
    let tenant = c.rt.tenant(&c.org_id).await.unwrap();
    tenant
        .execute_unprepared(
            "UPDATE restore_state SET logs_reconcile_required = 1, orphan_cleanup_held = 1",
        )
        .await
        .unwrap();
    drop(tenant);
    c.rt.mark_dirty(&c.org_id);
    eventually(Duration::from_secs(10), || async {
        c.status().await["restore_conflict"] == "unmapped_format1_object"
    })
    .await;
    assert_eq!(c.scalar("SELECT COUNT(*) FROM log_objects").await, 0);
    let (status, refusal) = c.send(&["after-unmapped"]).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(refusal, json!({"error": "log_restore_conflict"}));
    c.close().await;
}

const DAY_US: i64 = 86_400_000_000;

fn ninety_days(settings: &mut Value) {
    quiet_batches(settings);
    settings["logs"]["retention_secs"] = json!(7_776_000);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn retention_deletes_expired_unarchived_batches_with_their_r2_object_and_keeps_unexpired_ones(
) {
    use postdeploy::{
        domain::{now_micros, Environment, ProjectId, SourceId},
        logs::{object::Partition, record::LogRecord, retention, storage},
        quota::Usage,
    };
    let c = Ctx::new("log-retention-unarchived", ninety_days).await;
    let source =
        c.rt.control
            .query_one_raw(sql(
                "SELECT id FROM sources WHERE project_id = ?",
                vec![c.project.into()],
            ))
            .await
            .unwrap()
            .unwrap()
            .try_get::<i64>("", "id")
            .unwrap();
    let partition = Partition {
        org: c.org_id.clone(),
        project: ProjectId(c.project),
        source: SourceId(source),
        environment: Environment::parse("production").unwrap(),
    };
    c.env.faults.fail_puts.store(u32::MAX, Ordering::SeqCst);
    let now = now_micros();
    for (received, body) in [
        (now - 91 * DAY_US, "expired-pending"),
        (now, "fresh-pending"),
    ] {
        let record: LogRecord = serde_json::from_value(
            json!({"ts": received, "rt": received, "level": "info", "body": body, "attributes": {}}),
        )
        .unwrap();
        let hold =
            c.rt.quotas
                .reserve_at(
                    &c.rt,
                    &c.org_id,
                    Usage {
                        logs: 1,
                        log_bytes: record.approx_bytes() as u64,
                        ..Usage::default()
                    },
                    received,
                )
                .await
                .unwrap();
        storage::append(&c.rt, &partition, vec![record], hold)
            .await
            .unwrap();
    }
    let expired_key: String = {
        let tenant = c.rt.tenant(&c.org_id).await.unwrap();
        tenant
            .query_one_raw(sql(
                "SELECT object_key FROM log_objects WHERE id = 1 AND state = 'sealed'",
                vec![],
            ))
            .await
            .unwrap()
            .unwrap()
            .try_get("", "object_key")
            .unwrap()
    };
    c.env.faults.fail_puts.store(0, Ordering::SeqCst);
    c.env
        .store
        .put(
            &expired_key,
            bytes::Bytes::from_static(b"uploaded-before-crash"),
        )
        .await
        .unwrap();
    c.env.faults.fail_puts.store(u32::MAX, Ordering::SeqCst);
    assert_eq!(
        postdeploy::logs::retention::sweep_org(&c.rt, &c.org_id)
            .await
            .unwrap(),
        1
    );
    assert!(c.env.store.get(&expired_key, 64).await.unwrap().is_none());
    assert_eq!(
        c.scalar("SELECT COUNT(*) FROM log_objects WHERE id = 1")
            .await,
        0
    );
    assert_eq!(
        c.scalar("SELECT COUNT(*) FROM log_entries_pending WHERE object_id = 1")
            .await,
        0
    );
    assert_eq!(
        c.scalar("SELECT COUNT(*) FROM log_entries_pending WHERE object_id = 2")
            .await,
        1,
        "an unexpired acknowledged pending entry survives failed archiving"
    );
    assert_eq!(bodies(&c.search("").await), ["fresh-pending"]);
    assert_eq!(retention::sweep_org(&c.rt, &c.org_id).await.unwrap(), 0);
    c.close().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn missing_and_corrupt_batches_are_reported_in_coverage_and_never_deleted() {
    let c = Ctx::new("log-missing-corrupt", |s| {
        s["logs"]["batch_max_age_ms"] = json!(600_000);
        s["logs"]["batch_max_entries"] = json!(1);
        s["logs"]["archive_tick_ms"] = json!(50);
    })
    .await;
    assert_eq!(c.send(&["will-go-missing"]).await.0, StatusCode::OK);
    assert_eq!(c.send(&["will-be-corrupt"]).await.0, StatusCode::OK);
    eventually(Duration::from_secs(10), || async {
        c.status().await["archived_objects"] == 2
    })
    .await;
    let keys: Vec<String> = {
        let tenant = c.rt.tenant(&c.org_id).await.unwrap();
        tenant
            .query_all_raw(sql(
                "SELECT object_key FROM log_objects ORDER BY id",
                vec![],
            ))
            .await
            .unwrap()
            .iter()
            .map(|row| row.try_get("", "object_key").unwrap())
            .collect()
    };
    c.env.store.delete(&keys[0]).await.unwrap();
    c.env
        .store
        .put(&keys[1], bytes::Bytes::from_static(b"not zstd"))
        .await
        .unwrap();
    c.env.faults.fail_puts.store(u32::MAX, Ordering::SeqCst);
    assert_eq!(c.send(&["pending-tampered"]).await.0, StatusCode::OK);
    let tenant = c.rt.tenant(&c.org_id).await.unwrap();
    tenant
        .execute_unprepared(
            "UPDATE log_entries_pending SET sealed = zeroblob(length(sealed)) WHERE object_id = 3",
        )
        .await
        .unwrap();
    drop(tenant);
    let (status, page) = c.api.get(&format!("/api/orgs/{}/logs", c.org)).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(page["rows"], json!([]));
    assert_eq!(page["coverage"]["missing_objects"], 1);
    assert_eq!(page["coverage"]["corrupt_objects"], 2);
    c.env.faults.fail_puts.store(0, Ordering::SeqCst);
    eventually(Duration::from_secs(10), || async {
        c.status().await["archive_failure"]["reason"] == "pending_entry_corrupt"
    })
    .await;
    assert_eq!(
        c.scalar("SELECT COUNT(*) FROM log_entries_pending").await,
        1
    );
    assert_eq!(c.scalar("SELECT COUNT(*) FROM log_objects").await, 3);
    c.close().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_organization_write_barrier_fences_batch_archives() {
    let c = Ctx::new("log-deletion-fence", fast_archive).await;
    c.env.faults.fail_puts.store(u32::MAX, Ordering::SeqCst);
    assert_eq!(c.send(&["fenced-marker"]).await.0, StatusCode::OK);
    c.rt.store.block_org_writes(&c.org_id).unwrap();
    c.env.faults.fail_puts.store(0, Ordering::SeqCst);
    eventually(Duration::from_secs(10), || async {
        let status = c.status().await;
        status["sealed_objects"] == 1
            && status["archive_failure"]["reason"] == "store_unavailable"
            && status["archive_failure"]["attempts"].as_u64() > Some(1)
    })
    .await;
    assert!(c
        .rt
        .store
        .list_page(&format!("logs/v1/{}/", c.org), None, 10)
        .await
        .unwrap()
        .keys
        .is_empty());
    c.close().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn local_disk_pressure_refuses_ingestion_with_503_and_unchanged_usage() {
    let c = Ctx::new("log-disk-pressure", |s| {
        quiet_batches(s);
        s["disk"]["max_bytes"] = json!(1u64 << 30);
        s["disk"]["min_free_bytes"] = json!(0);
        s["disk"]["scan_interval_secs"] = json!(1);
    })
    .await;
    assert_eq!(c.send(&["before-pressure"]).await.0, StatusCode::OK);
    let ballast = c.env.dir.join("ballast.bin");
    std::fs::File::create(&ballast)
        .unwrap()
        .set_len(2 << 30)
        .unwrap();
    eventually(Duration::from_secs(10), || async {
        c.send(&["probe-pressure"]).await.0 == StatusCode::SERVICE_UNAVAILABLE
    })
    .await;
    let usage = log_usage(&c.rt, &c.org_id).await;
    assert_eq!(
        c.send(&["during-pressure"]).await,
        (
            StatusCode::SERVICE_UNAVAILABLE,
            json!({"error": "local_storage_pressure"})
        )
    );
    assert_eq!(log_usage(&c.rt, &c.org_id).await, usage);
    std::fs::remove_file(&ballast).unwrap();
    eventually(Duration::from_secs(10), || async {
        c.send(&["after-pressure"]).await.0 == StatusCode::OK
    })
    .await;
    let seen = c.search("").await;
    assert_eq!(seen.first().unwrap().1, "after-pressure");
    assert!(!seen.iter().any(|(_, body)| body == "during-pressure"));
    c.close().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_pending_organization_bound_refuses_new_backlogs_until_archives_drain() {
    let c = Ctx::new("log-pending-orgs", |s| {
        fast_archive(s);
        s["logs"]["max_pending_orgs"] = json!(1);
    })
    .await;
    c.env.faults.fail_puts.store(u32::MAX, Ordering::SeqCst);
    assert_eq!(c.send(&["first-org-pending"]).await.0, StatusCode::OK);
    let other = Api::signup(&c.base, "log-pending-orgs-other@example.test").await;
    let (other_org, other_project, other_dsn) = other.setup_source("Other").await;
    let other_key = dsn_key(&other_dsn);
    assert_eq!(
        c.send_to(other_project, &other_key, &["second-org"]).await,
        (
            StatusCode::SERVICE_UNAVAILABLE,
            json!({"error": "log_backlog_full"})
        )
    );
    c.env.faults.fail_puts.store(0, Ordering::SeqCst);
    eventually(Duration::from_secs(10), || async {
        c.status().await["pending_entries"] == 0
    })
    .await;
    assert_eq!(
        c.send_to(other_project, &other_key, &["second-org"])
            .await
            .0,
        StatusCode::OK
    );
    let (_, page) = other.get(&format!("/api/orgs/{other_org}/logs")).await;
    assert_eq!(page["rows"][0]["body"], "second-org");
    c.close().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn stale_cache_cannot_bypass_authoritative_daily_log_count_or_byte_limits() {
    for (name, accepted, bytes, count_limit, byte_limit) in [
        ("log-stale-count", 1_i64, 0_i64, 1_u64, 1_000_000_u64),
        ("log-stale-bytes", 0, 1_000, 100, 1_000),
    ] {
        let c = Ctx::new(name, |s| {
            quiet_batches(s);
            s["quotas"]["daily_logs"] = json!(count_limit);
            s["quotas"]["daily_log_bytes"] = json!(byte_limit);
        })
        .await;
        drop(
            c.rt.quotas
                .reserve(&c.rt, &c.org_id, Usage::default())
                .await
                .unwrap(),
        );
        let tenant = c.rt.tenant(&c.org_id).await.unwrap();
        tenant
            .execute_raw(sql(
                "INSERT INTO usage_daily (day, category, accepted, bytes) VALUES (?, 'log', ?, ?)",
                vec![utc_day(now_micros()).into(), accepted.into(), bytes.into()],
            ))
            .await
            .unwrap();
        drop(tenant);
        let puts = c.rt.store.counters().puts.load(Ordering::SeqCst);
        assert_eq!(
            c.send(&["stale-sql-quota-marker"]).await,
            (
                StatusCode::TOO_MANY_REQUESTS,
                json!({"error": "rate_limited"})
            ),
            "{name}"
        );
        assert_eq!(log_usage(&c.rt, &c.org_id).await, (accepted, bytes));
        for query in [
            "SELECT COUNT(*) FROM log_objects",
            "SELECT COUNT(*) FROM log_entries_pending",
            "SELECT COUNT(*) FROM log_entry_runs",
            "SELECT COUNT(*) FROM usage_alerts",
        ] {
            assert_eq!(c.scalar(query).await, 0, "{name}: {query}");
        }
        assert_eq!(c.rt.store.counters().puts.load(Ordering::SeqCst), puts);
        assert_eq!(c.search("").await, Vec::<(String, String)>::new());
        c.close().await;
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn sql_append_rollback_releases_its_quota_hold_and_retry_commits_once() {
    let c = Ctx::new("log-append-rollback", |s| {
        quiet_batches(s);
        s["quotas"]["daily_logs"] = json!(1);
    })
    .await;
    let tenant = c.rt.tenant(&c.org_id).await.unwrap();
    tenant.execute_raw(sql(
        "CREATE TRIGGER reject_log_usage BEFORE INSERT ON usage_daily WHEN NEW.category = 'log' BEGIN SELECT RAISE(ABORT, 'append rollback injected'); END",
        vec![],
    )).await.unwrap();
    drop(tenant);
    assert_eq!(
        c.send(&["rollback-retry-marker"]).await,
        (
            StatusCode::SERVICE_UNAVAILABLE,
            json!({"error": "ingest_unavailable"})
        )
    );
    assert_eq!(log_usage(&c.rt, &c.org_id).await, (0, 0));
    for query in [
        "SELECT COUNT(*) FROM log_objects",
        "SELECT COUNT(*) FROM log_entries_pending",
        "SELECT COUNT(*) FROM log_entry_runs",
        "SELECT COUNT(*) FROM usage_alerts",
    ] {
        assert_eq!(c.scalar(query).await, 0, "{query}");
    }
    assert_eq!(c.rt.store.counters().puts.load(Ordering::SeqCst), 0);
    let tenant = c.rt.tenant(&c.org_id).await.unwrap();
    tenant
        .execute_raw(sql("DROP TRIGGER reject_log_usage", vec![]))
        .await
        .unwrap();
    drop(tenant);
    assert_eq!(
        c.send(&["rollback-retry-marker"]).await,
        (StatusCode::OK, accepted(None, 0, 1))
    );
    assert_eq!(
        c.search("").await,
        [("c1.1.0".to_owned(), "rollback-retry-marker".to_owned())]
    );
    assert_eq!(log_usage(&c.rt, &c.org_id).await, (1, 154));
    assert_eq!(c.scalar("SELECT COUNT(*) FROM log_objects").await, 1);
    assert_eq!(
        c.scalar("SELECT COUNT(*) FROM log_entries_pending").await,
        1
    );
    assert_eq!(c.scalar("SELECT COUNT(*) FROM usage_alerts").await, 0);
    assert_eq!(
        c.send(&["rollback-refused-marker"]).await,
        (
            StatusCode::TOO_MANY_REQUESTS,
            json!({"error": "rate_limited"})
        )
    );
    assert_eq!(log_usage(&c.rt, &c.org_id).await, (1, 154));
    assert_eq!(c.rt.store.counters().puts.load(Ordering::SeqCst), 0);
    c.close().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn independent_cold_error_and_log_requests_share_local_readiness_without_r2_reads() {
    let settings = |s: &mut Value| {
        quiet_batches(s);
        s["lifecycle"]["max_cached_orgs"] = json!(1);
        s["lifecycle"]["max_active_requests"] = json!(2);
    };
    let c = Ctx::new("log-cold-mixed", settings).await;
    assert_eq!(c.send(&["cold-existing-marker"]).await.0, StatusCode::OK);
    let before = c.search("").await;
    assert_eq!(
        before,
        [("c1.1.0".to_owned(), "cold-existing-marker".to_owned())]
    );
    let org = c.org_id.clone();
    let project = c.project;
    let key = c.key.clone();
    let email = "log-cold-mixed@example.test";
    c.rt.shutdown().await;
    c.server.abort();
    drop(c.boot);
    let env = c.env;
    let boot = env.boot_memory(settings).await.unwrap();
    let (base, server) = serve(&boot).await;
    let rt = Runtime::get(&boot.app_context);
    rt.cancel.cancel();
    let mut api = Api::new(&base);
    assert_eq!(api.auth("login", email, PASSWORD).await.0, StatusCode::OK);
    drop(rt.quotas.write(&OrgId::generate()).await.unwrap());
    assert!(!rt.quotas.is_ready(&org));
    let gets = rt.store.counters().gets.load(Ordering::SeqCst);
    let lists = rt.store.counters().lists.load(Ordering::SeqCst);
    let puts = rt.store.counters().puts.load(Ordering::SeqCst);
    env.faults.delay_get_ms.store(60_000, Ordering::SeqCst);
    let writer = rt.quotas.write(&org).await.unwrap();
    assert!(rt.gate.is_open());
    let start = std::sync::Arc::new(tokio::sync::Barrier::new(3));
    let requests = [
        envelope(Some("40000000000000000000000000000001"), &[]),
        envelope(None, &["cold-concurrent-marker"]),
    ]
    .map(|body| {
        let base = base.clone();
        let key = key.clone();
        let start = start.clone();
        tokio::spawn(async move {
            start.wait().await;
            post_envelope(&base, project, &key, body, None).await
        })
    });
    start.wait().await;
    eventually(Duration::from_secs(5), || async {
        rt.metrics.envelopes.load(Ordering::SeqCst) == 2
    })
    .await;
    assert!(!rt.quotas.is_ready(&org));
    assert!(requests.iter().all(|request| !request.is_finished()));
    assert!(
        rt.gate.enter().is_none(),
        "both admission slots are occupied behind the writer"
    );
    assert_eq!(rt.store.counters().gets.load(Ordering::SeqCst), gets);
    assert_eq!(rt.store.counters().lists.load(Ordering::SeqCst), lists);
    drop(writer);
    let [error, log] = requests;
    let (error, log) = tokio::time::timeout(Duration::from_secs(5), async {
        (error.await.unwrap(), log.await.unwrap())
    })
    .await
    .expect("both cold admissions finish without an R2 read");
    assert_eq!(
        error,
        (
            StatusCode::OK,
            accepted(Some("40000000000000000000000000000001"), 1, 0)
        )
    );
    assert_eq!(log, (StatusCode::OK, accepted(None, 0, 1)));
    assert!(rt.quotas.is_ready(&org));
    assert_eq!(rt.store.counters().gets.load(Ordering::SeqCst), gets);
    assert_eq!(rt.store.counters().lists.load(Ordering::SeqCst), lists);
    assert_eq!(
        rt.store.counters().puts.load(Ordering::SeqCst),
        puts + 1,
        "the error still requires its durable PUT"
    );
    let (status, page) = api.get(&format!("/api/orgs/{org}/logs?limit=10")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        rows(&page),
        [
            ("c1.2.0".to_owned(), "cold-concurrent-marker".to_owned()),
            before[0].clone(),
        ]
    );
    assert_eq!(log_usage(&rt, &org).await, (2, 308));
    let tenant = rt.tenant(&org).await.unwrap();
    let row = tenant.query_one_raw(sql(
        "SELECT (SELECT COUNT(*) FROM events) AS events, (SELECT event_id FROM events LIMIT 1) AS event_id, COALESCE((SELECT SUM(accepted) FROM usage_daily WHERE category='error'),0) AS errors, (SELECT COUNT(*) FROM log_objects) AS objects, (SELECT COUNT(*) FROM log_entries_pending) AS pending",
        vec![],
    )).await.unwrap().unwrap();
    assert_eq!(row.try_get::<i64>("", "events").unwrap(), 1);
    assert_eq!(
        row.try_get::<String>("", "event_id").unwrap(),
        "40000000000000000000000000000001"
    );
    assert_eq!(row.try_get::<i64>("", "errors").unwrap(), 1);
    assert_eq!(row.try_get::<i64>("", "objects").unwrap(), 2);
    assert_eq!(row.try_get::<i64>("", "pending").unwrap(), 2);
    drop(tenant);
    env.faults.delay_get_ms.store(0, Ordering::SeqCst);
    rt.shutdown().await;
    server.abort();
}

async fn backup_org(c: &Ctx) -> postdeploy::backup_sets::SetId {
    run_backup(&c.boot).await.set
}

/// Restores the set and places the organization's marked file at `destination`.
async fn restore_org(c: &Ctx, set: postdeploy::backup_sets::SetId, destination: &std::path::Path) {
    std::fs::create_dir_all(destination.parent().unwrap()).unwrap();
    let directory = PathBuf::from(format!("{}.set", destination.display()));
    let report = restore_set(&c.boot, set, &directory).await;
    let restored = report
        .organizations
        .iter()
        .find(|org| org.org == c.org_id)
        .unwrap();
    std::fs::hard_link(&restored.path, destination).unwrap();
}

async fn restore_scan_after(rt: &Runtime, org: &OrgId) -> Option<String> {
    let tenant = rt.tenant(org).await.unwrap();
    tenant
        .query_one_raw(sql(
            "SELECT scan_after FROM restore_state WHERE id = 1",
            vec![],
        ))
        .await
        .unwrap()
        .unwrap()
        .try_get("", "scan_after")
        .unwrap()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_restore_pass_over_slow_r2_persists_progress_and_completes_more_than_one_page() {
    const OBJECTS: usize = 130;
    let name = "log-restore-slow-pages";
    let settings = |s: &mut Value| {
        s["logs"]["batch_max_age_ms"] = json!(600_000);
        s["logs"]["batch_max_entries"] = json!(1);
        s["logs"]["archive_tick_ms"] = json!(20);
        s["ingest"]["rate_burst"] = json!(OBJECTS);
    };
    let c = Ctx::new(name, settings).await;
    let backup = backup_org(&c).await;
    for index in 0..OBJECTS {
        let body = format!("slow-page-{index:03}");
        assert_eq!(c.send(&[body.as_str()]).await.0, StatusCode::OK);
    }
    eventually(Duration::from_secs(60), || async {
        c.status().await["archived_objects"] == OBJECTS
    })
    .await;
    let usage = log_usage(&c.rt, &c.org_id).await;
    assert_eq!(usage.0, OBJECTS as i64);
    let restored = c.env.dir.join("restored-slow").join("org.db");
    restore_org(&c, backup, &restored).await;
    let Ctx {
        env,
        boot,
        server,
        rt,
        org_id,
        org,
        ..
    } = c;
    rt.shutdown().await;
    server.abort();
    drop((rt, boot));

    activate(&env, &org_id, &restored);
    env.faults.delay_get_ms.store(40, Ordering::SeqCst);
    let started = Instant::now();
    let boot = env.boot_memory(settings).await.unwrap();
    let (base, server) = serve(&boot).await;
    let rt = Runtime::get(&boot.app_context);
    assert_eq!(rt.settings.logs.reconcile_max_objects, 128);
    assert_eq!(rt.settings.logs.reconcile_timeout_ms, 2_000);
    let api = login(&base, &format!("{name}@example.test")).await;
    let mut progress = Vec::new();
    loop {
        let (_, status) = api.get(&format!("/api/orgs/{org}/logs/storage")).await;
        assert_eq!(status["restore_conflict"], Value::Null, "{status}");
        if status["restore_required"] == false {
            break;
        }
        if let Some(after) = restore_scan_after(&rt, &org_id).await {
            if progress.last() != Some(&after) {
                progress.push(after);
            }
        }
        assert!(
            started.elapsed() < Duration::from_secs(60),
            "restore did not finish; scan positions seen: {progress:?}"
        );
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert!(
        progress.len() >= 2,
        "progress persisted across passes: {progress:?}"
    );
    env.faults.delay_get_ms.store(0, Ordering::SeqCst);
    let (_, status) = api.get(&format!("/api/orgs/{org}/logs/storage")).await;
    assert_eq!(status["archived_objects"], OBJECTS);
    assert_eq!(status["restore_conflict"], Value::Null);
    let (status, page) = api.get(&format!("/api/orgs/{org}/logs?limit=1")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        rows(&page)
            .into_iter()
            .map(|(_, body)| body)
            .collect::<Vec<_>>(),
        ["slow-page-129"]
    );
    assert_eq!(log_usage(&rt, &org_id).await, usage, "historic usage once");
    rt.shutdown().await;
    server.abort();
}

const SMALL_DOUBLE: &str = "1.054436654199542e-8";

fn double_envelope(body: &str) -> Vec<u8> {
    let now = chrono::Utc::now().timestamp_micros() as f64 / 1e6;
    let payload = format!(
        r#"{{"items":[{{"timestamp":{now},"level":"info","body":"{body}","attributes":{{"ratio":{{"type":"double","value":{SMALL_DOUBLE}}}}}}}]}}"#
    );
    format!(
        "{}\n{}\n{payload}\n",
        json!({}),
        json!({"type": "log", "item_count": 1, "content_type": "application/vnd.sentry.items.log+json", "length": payload.len()})
    )
    .into_bytes()
}

async fn search_text(api: &Api, org: &str) -> String {
    let response = api
        .http
        .get(format!("{}/api/orgs/{org}/logs?limit=50", api.base))
        .header("cookie", api.cookie.clone().unwrap())
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    response.text().await.unwrap()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_small_double_attribute_survives_put_retry_with_exact_value_and_no_conflict() {
    let c = Ctx::new("log-double-retry", fast_archive).await;
    c.env.faults.fail_puts.store(u32::MAX, Ordering::SeqCst);
    let (status, _) = post_envelope(
        &c.base,
        c.project,
        &c.key,
        double_envelope("double-marker"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let pending = search_text(&c.api, &c.org).await;
    assert!(
        pending.contains(&format!(
            r#""ratio":{{"type":"double","value":{SMALL_DOUBLE}}}"#
        )),
        "pending read keeps the submitted value: {pending}"
    );
    eventually(Duration::from_secs(10), || async {
        c.status().await["archive_failure"]["reason"] == "store_unavailable"
    })
    .await;
    let usage = log_usage(&c.rt, &c.org_id).await;
    c.env.faults.fail_put_after_write.store(1, Ordering::SeqCst);
    c.env.faults.fail_puts.store(0, Ordering::SeqCst);
    eventually(Duration::from_secs(20), || async {
        let status = c.status().await;
        status["archived_objects"] == 1
            || status["archive_failure"]["reason"] == "remote_prefix_mismatch"
    })
    .await;
    let status = c.status().await;
    assert_eq!(status["archive_failure"], Value::Null, "{status}");
    assert_eq!(status["archived_objects"], 1);
    assert_eq!(status["pending_entries"], 0);
    assert_eq!(log_usage(&c.rt, &c.org_id).await, usage, "no second charge");
    let archived = search_text(&c.api, &c.org).await;
    assert!(
        archived.contains(&format!(
            r#""ratio":{{"type":"double","value":{SMALL_DOUBLE}}}"#
        )),
        "archived read keeps the submitted value: {archived}"
    );
    c.close().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn restore_accepts_a_remote_extension_whose_prefix_holds_a_small_double() {
    let name = "log-double-restore";
    let c = Ctx::new(name, restore_settings).await;
    let (status, _) = post_envelope(
        &c.base,
        c.project,
        &c.key,
        double_envelope("double-prefix"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let backup = backup_org(&c).await;
    assert_eq!(
        c.send(&["double-suffix-b", "double-suffix-c"]).await.0,
        StatusCode::OK
    );
    eventually(Duration::from_secs(10), || async {
        c.status().await["archived_objects"] == 1
    })
    .await;
    let usage = log_usage(&c.rt, &c.org_id).await;
    let restored = c.env.dir.join("restored-double").join("org.db");
    restore_org(&c, backup, &restored).await;
    let Ctx {
        env,
        boot,
        server,
        rt,
        org_id,
        org,
        ..
    } = c;
    rt.shutdown().await;
    server.abort();
    drop((rt, boot));
    activate(&env, &org_id, &restored);
    let boot = env.boot_memory(restore_settings).await.unwrap();
    let (base, server) = serve(&boot).await;
    let rt = Runtime::get(&boot.app_context);
    let api = login(&base, &format!("{name}@example.test")).await;
    eventually(Duration::from_secs(20), || {
        let api = api.clone();
        let org = org.clone();
        async move {
            let (_, status) = api.get(&format!("/api/orgs/{org}/logs/storage")).await;
            status["restore_required"] == false || status["restore_conflict"] != Value::Null
        }
    })
    .await;
    let (_, status) = api.get(&format!("/api/orgs/{org}/logs/storage")).await;
    assert_eq!(status["restore_conflict"], Value::Null, "{status}");
    assert_eq!(status["restore_required"], false);
    let text = search_text(&api, &org).await;
    assert!(
        text.contains(&format!(
            r#""ratio":{{"type":"double","value":{SMALL_DOUBLE}}}"#
        )),
        "{text}"
    );
    let page: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(
        rows(&page).into_iter().map(|(_, b)| b).collect::<Vec<_>>(),
        ["double-suffix-c", "double-suffix-b", "double-prefix"]
    );
    assert_eq!(log_usage(&rt, &org_id).await, usage, "suffix charged once");
    rt.shutdown().await;
    server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_archive_upload_that_outlives_its_expired_row_leaves_no_r2_object() {
    let c = Ctx::new("log-retention-put-race", |s| {
        fast_archive(s);
        s["logs"]["retention_secs"] = json!(2);
        s["logs"]["sweep_interval_secs"] = json!(3_600);
    })
    .await;
    let keys = || async {
        c.rt.store
            .list_page(&format!("logs/v1/{}/", c.org), None, 10)
            .await
            .unwrap()
            .keys
    };

    c.env.faults.delay_put_ms.store(800, Ordering::SeqCst);
    assert_eq!(c.send(&["unexpired-lost-row"]).await.0, StatusCode::OK);
    eventually(Duration::from_secs(5), || async {
        c.rt.store.org_writes_pending(&c.org_id)
    })
    .await;
    {
        let tenant = c.rt.tenant(&c.org_id).await.unwrap();
        for table in ["log_entries_pending", "log_entry_runs"] {
            tenant
                .execute_unprepared(&format!("DELETE FROM {table}"))
                .await
                .unwrap();
        }
        tenant
            .execute_unprepared("DELETE FROM log_objects")
            .await
            .unwrap();
    }
    eventually(Duration::from_secs(5), || async {
        !c.rt.store.org_writes_pending(&c.org_id)
    })
    .await;
    eventually(Duration::from_secs(5), || async {
        c.status().await["sealed_objects"] == 0
    })
    .await;
    let unexpired = keys().await;
    assert_eq!(
        unexpired.len(),
        1,
        "an object with unexpired entries is never deleted by the archiver"
    );

    c.env.faults.delay_put_ms.store(5_000, Ordering::SeqCst);
    assert_eq!(c.send(&["expired-during-put"]).await.0, StatusCode::OK);
    let sent = Instant::now();
    eventually(Duration::from_secs(5), || async {
        c.rt.store.org_writes_pending(&c.org_id)
    })
    .await;
    tokio::time::sleep(Duration::from_millis(2_500).saturating_sub(sent.elapsed())).await;
    assert_eq!(
        postdeploy::logs::retention::sweep_org(&c.rt, &c.org_id)
            .await
            .unwrap(),
        1,
        "retention removed the expired sealed row while its upload was in flight"
    );
    assert!(c.rt.store.org_writes_pending(&c.org_id));
    eventually(Duration::from_secs(10), || async {
        !c.rt.store.org_writes_pending(&c.org_id)
    })
    .await;
    let deadline = Instant::now() + Duration::from_secs(5);
    while keys().await != unexpired && Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert_eq!(
        keys().await,
        unexpired,
        "the expired batch's late upload is removed with its row"
    );
    assert_eq!(c.scalar("SELECT COUNT(*) FROM log_objects").await, 0);
    assert_eq!(c.rt.metrics.objects_archived.load(Ordering::SeqCst), 0);
    assert_eq!(c.rt.metrics.objects_expired.load(Ordering::SeqCst), 1);
    c.close().await;
}

#[path = "support/mcp.rs"]
mod mcp_support;

struct Server {
    boot: loco_rs::boot::BootResult,
    server: tokio::task::JoinHandle<()>,
    base: String,
    rt: std::sync::Arc<Runtime>,
    api: Api,
}

impl Server {
    async fn start(env: &TestEnv, name: &str) -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let boot = env
            .boot_memory(|s| {
                restore_settings(s);
                s["oauth"]["issuer"] = json!(base);
                s["oauth"]["resource"] = json!(format!("{base}/mcp"));
            })
            .await
            .unwrap();
        let router = boot.router.clone().unwrap();
        let server = tokio::spawn(async move {
            let _ = axum::serve(
                listener,
                router.into_make_service_with_connect_info::<std::net::SocketAddr>(),
            )
            .await;
        });
        let rt = Runtime::get(&boot.app_context);
        let api = login(&base, &format!("{name}@example.test")).await;
        Self {
            boot,
            server,
            base,
            rt,
            api,
        }
    }

    async fn wait_restored(&self, org: &str) {
        eventually(Duration::from_secs(20), || {
            let api = self.api.clone();
            let org = org.to_owned();
            async move {
                let (_, status) = api.get(&format!("/api/orgs/{org}/logs/storage")).await;
                status["restore_required"] == false
            }
        })
        .await;
    }

    async fn search(&self, org: &str, query: &str) -> (StatusCode, Value) {
        self.api
            .get(&format!("/api/orgs/{org}/logs?limit=50{query}"))
            .await
    }

    async fn tail(&self, org: &str, last_event_id: &str) -> reqwest::Response {
        self.api
            .http
            .get(format!("{}/api/orgs/{org}/logs/tail", self.base))
            .header("cookie", self.api.cookie.clone().unwrap())
            .header("last-event-id", last_event_id)
            .send()
            .await
            .unwrap()
    }

    async fn page(&self, path: &str) -> String {
        let response = self
            .api
            .http
            .get(format!("{}{path}", self.base))
            .header("cookie", self.api.cookie.clone().unwrap())
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK, "{path}");
        response.text().await.unwrap()
    }

    async fn mcp_token(&self, org: &OrgId) -> String {
        let user: i64 = self
            .rt
            .control
            .query_one_raw(sql(
                "SELECT user_id FROM memberships WHERE org_id = ?",
                vec![org.as_str().into()],
            ))
            .await
            .unwrap()
            .unwrap()
            .try_get("", "user_id")
            .unwrap();
        let oauth = &postdeploy::services::Services::get(&self.boot.app_context).oauth;
        let client = oauth
            .register_client(postdeploy::agent_access::ClientRegistration {
                redirect_uris: vec![mcp_support::REDIRECT.into()],
                client_name: Some("Restore cursor test".into()),
                scope: Some(mcp_support::FULL.into()),
                ..Default::default()
            })
            .await
            .unwrap()
            .client_id
            .as_str()
            .to_owned();
        let user = postdeploy::domain::UserId(user);
        let postdeploy::agent_access::Consent::Ready(prompt) = oauth
            .begin_consent(
                user,
                postdeploy::agent_access::AuthorizeRequest {
                    response_type: Some("code".into()),
                    client_id: Some(client.clone()),
                    redirect_uri: Some(mcp_support::REDIRECT.into()),
                    code_challenge: Some(mcp_support::CHALLENGE.into()),
                    code_challenge_method: Some("S256".into()),
                    scope: Some(mcp_support::FULL.into()),
                    state: None,
                    resource: Some(format!("{}/mcp", self.base)),
                },
            )
            .await
            .unwrap()
        else {
            panic!("the user belongs to an organization");
        };
        let redirect = oauth
            .approve_consent(user, prompt.handle.expose(), org, prompt.requested.clone())
            .await
            .unwrap();
        let code = url::Url::parse(&redirect)
            .unwrap()
            .query_pairs()
            .find(|(key, _)| key == "code")
            .unwrap()
            .1
            .into_owned();
        oauth
            .token(postdeploy::agent_access::TokenForm {
                grant_type: Some("authorization_code".into()),
                client_id: Some(client),
                code: Some(code.into()),
                redirect_uri: Some(mcp_support::REDIRECT.into()),
                code_verifier: Some(mcp_support::VERIFIER.into()),
                resource: Some(format!("{}/mcp", self.base)),
                ..Default::default()
            })
            .await
            .unwrap()
            .access_token
            .expose()
            .to_owned()
    }

    async fn mcp(&self, token: &str, tool: &str, arguments: Value) -> Value {
        let response = self
            .api
            .http
            .post(format!("{}/mcp", self.base))
            .header("content-type", "application/json")
            .header("accept", "application/json, text/event-stream")
            .header("mcp-protocol-version", "2025-06-18")
            .header("authorization", format!("Bearer {token}"))
            .body(mcp_support::call_body(tool, arguments).to_string())
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let mut body: Value = serde_json::from_str(&response.text().await.unwrap()).unwrap();
        if body["result"]["structuredContent"]["error"].is_string() {
            assert_eq!(body["result"]["isError"], true, "{body}");
        }
        body["result"]["structuredContent"].take()
    }

    async fn stop(self) {
        self.rt.shutdown().await;
        self.server.abort();
        drop(self.boot);
    }
}

fn epoch_of(token: &str) -> String {
    let parts: Vec<&str> = token.split('.').collect();
    assert_eq!(parts.len(), 4, "{token}");
    assert_eq!(parts[0], "c2", "{token}");
    let epoch = parts[1];
    assert_eq!(epoch.len(), 16, "{token}");
    assert!(
        epoch
            .bytes()
            .all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f')),
        "{token}"
    );
    assert_ne!(epoch, "0000000000000000");
    epoch.to_owned()
}

const RESET: &str = r#"{"error":"cursor_reset_required"}"#;

struct LostBatch {
    env: TestEnv,
    name: String,
    org: String,
    org_id: OrgId,
    project: i64,
    key: String,
    report: postdeploy::reports::ReportId,
    report_key: String,
    report_sha: String,
    files: Vec<PathBuf>,
}

async fn lose_an_unarchived_batch(name: &str, files: usize) -> LostBatch {
    use sha2::Digest;
    let c = Ctx::new(name, restore_settings).await;
    assert_eq!(
        c.send(&["restore-a", "restore-b", "restore-c"]).await.0,
        StatusCode::OK
    );
    eventually(Duration::from_secs(10), || async {
        c.status().await["archived_objects"] == 1
    })
    .await;
    let user: i64 =
        c.rt.control
            .query_one_raw(sql(
                "SELECT user_id FROM memberships WHERE org_id = ?",
                vec![c.org.clone().into()],
            ))
            .await
            .unwrap()
            .unwrap()
            .try_get("", "user_id")
            .unwrap();
    let access =
        postdeploy::identity::access::authorize(&c.rt, postdeploy::domain::UserId(user), &c.org_id)
            .await
            .unwrap();
    let reports = &postdeploy::services::Services::get(&c.boot.app_context).reports;
    let published = reports
        .publish(
            &access,
            serde_json::from_value(json!({"project_id": c.project, "title": "Before restore",
                "summary": "cites an archived entry", "findings": [{"title": "Entry", "severity": "low",
                "detail": "entry", "evidence": [{"kind": "log", "cursor": "c1.1.1"}]}]}))
            .unwrap(),
        )
        .await
        .unwrap();
    let report_key: String =
        c.rt.tenant(&c.org_id)
            .await
            .unwrap()
            .query_one_raw(sql(
                "SELECT object_key FROM reports WHERE id = ?",
                vec![published.report.id.as_str().into()],
            ))
            .await
            .unwrap()
            .unwrap()
            .try_get("", "object_key")
            .unwrap();
    let body = c.rt.store.get(&report_key, 1 << 20).await.unwrap().unwrap();
    let report_sha = hex::encode(sha2::Sha256::digest(&body));
    let backup = backup_org(&c).await;
    assert_eq!(c.send(&["restore-d", "restore-e"]).await.0, StatusCode::OK);
    assert_eq!(c.search("").await[0].0, "c1.2.1");
    let mut restored = Vec::new();
    for index in 0..files {
        let file = c.env.dir.join("restored-lost").join(format!("f{index}.db"));
        restore_org(&c, backup, &file).await;
        restored.push(file);
    }
    let Ctx {
        env,
        boot,
        server,
        rt,
        org,
        org_id,
        project,
        key,
        ..
    } = c;
    rt.shutdown().await;
    server.abort();
    drop((rt, boot));
    LostBatch {
        env,
        name: name.to_owned(),
        org,
        org_id,
        project,
        key,
        report: published.report.id,
        report_key,
        report_sha,
        files: restored,
    }
}

impl LostBatch {
    async fn activate(&self, file: usize) -> Server {
        activate(&self.env, &self.org_id, &self.files[file]);
        let server = Server::start(&self.env, &self.name).await;
        server.wait_restored(&self.org).await;
        server
    }

    async fn send(&self, server: &Server, bodies: &[&str]) {
        let (status, _) = post_envelope(
            &server.base,
            self.project,
            &self.key,
            envelope(None, bodies),
            None,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
    }

    async fn newest(&self, server: &Server) -> (String, String) {
        let (status, page) = server.search(&self.org, "").await;
        assert_eq!(status, StatusCode::OK, "{page}");
        rows(&page).remove(0)
    }

    async fn assert_reset(&self, server: &Server, token: &str) {
        let response = server.tail(&self.org, token).await;
        assert_eq!(response.status(), StatusCode::CONFLICT, "tail {token}");
        assert_eq!(response.text().await.unwrap(), RESET, "tail {token}");
        let (status, body) = server.search(&self.org, &format!("&before={token}")).await;
        assert_eq!(status, StatusCode::CONFLICT, "search {token}");
        assert_eq!(body, json!({"error": "cursor_reset_required"}));
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_restore_rejects_cursors_of_lost_unarchived_entries_and_never_resumes_into_new_ones() {
    let lost = lose_an_unarchived_batch("log-restore-lost-cursor", 1).await;
    let server = lost.activate(0).await;
    lost.send(&server, &["restore-f"]).await;
    let (newest, body) = lost.newest(&server).await;
    let epoch = epoch_of(&newest);
    assert_eq!(
        (newest.as_str(), body.as_str()),
        (format!("c2.{epoch}.2.0").as_str(), "restore-f")
    );

    lost.assert_reset(&server, "c1.2.1").await;
    let token = server.mcp_token(&lost.org_id).await;
    assert_eq!(
        server
            .mcp(
                &token,
                "replay_logs",
                json!({"after": "c1.2.1", "wait_ms": 100})
            )
            .await,
        json!({"error": "cursor_reset_required"})
    );
    assert_eq!(
        server
            .mcp(&token, "search_logs", json!({"before": "c1.2.1"}))
            .await,
        json!({"error": "cursor_reset_required"})
    );
    for malformed in [
        "c2.0000000000000000.2.1",
        "c2.00000000000000FF.2.1",
        "c2.0000000000000ff.2.1",
        "c3.2.1",
    ] {
        let response = server.tail(&lost.org, malformed).await;
        assert_eq!(response.status(), StatusCode::BAD_REQUEST, "{malformed}");
        assert_eq!(
            response.json::<Value>().await.unwrap(),
            json!({"error": "invalid_cursor"})
        );
        let (status, body) = server
            .search(&lost.org, &format!("&before={malformed}"))
            .await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{malformed}");
        assert_eq!(body, json!({"error": "invalid_cursor"}));
        assert_eq!(
            server
                .mcp(
                    &token,
                    "replay_logs",
                    json!({"after": malformed, "wait_ms": 100})
                )
                .await,
            json!({"error": "invalid_cursor"})
        );
    }
    for stale in ["c1.2.1", "c1.1.0"] {
        let report = json!({"project_id": lost.project, "title": "Stale", "summary": "stale cursor",
            "findings": [{"title": "Entry", "severity": "low", "detail": "entry",
            "evidence": [{"kind": "log", "cursor": stale}]}]});
        assert_eq!(
            server.mcp(&token, "publish_report", report).await,
            json!({"error": "cursor_reset_required"}),
            "{stale}"
        );
    }
    let reports: i64 = server
        .rt
        .tenant(&lost.org_id)
        .await
        .unwrap()
        .query_one_raw(sql("SELECT COUNT(*) AS n FROM reports", vec![]))
        .await
        .unwrap()
        .unwrap()
        .try_get("", "n")
        .unwrap();
    assert_eq!(reports, 1, "refused reports are not recorded");

    let response = server.tail(&lost.org, &newest).await;
    assert_eq!(response.status(), StatusCode::OK);
    lost.send(&server, &["restore-g"]).await;
    let events = read_sse(response, Duration::from_secs(5), |name, _| {
        name == "entries"
    })
    .await;
    let (_, entries) = events.iter().find(|(name, _)| name == "entries").unwrap();
    assert_eq!(entries["rows"][0]["body"], "restore-g");
    assert_eq!(entries["rows"][0]["cursor"], format!("c2.{epoch}.2.1"));
    assert_eq!(entries["rows"].as_array().unwrap().len(), 1);

    let html = server
        .page(&format!(
            "/dashboard/orgs/{}/projects/{}/logs?cursor=c1.2.1",
            lost.org, lost.project
        ))
        .await;
    assert!(
        html.contains("That page link is no longer valid. Search again."),
        "{html}"
    );
    server.stop().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn restoring_the_same_backup_or_file_twice_rotates_the_cursor_epoch_each_time() {
    let lost = lose_an_unarchived_batch("log-restore-twice", 2).await;
    let server = lost.activate(0).await;
    lost.send(&server, &["restore-x"]).await;
    let (x0, _) = lost.newest(&server).await;
    let e0 = epoch_of(&x0);
    assert_eq!(x0, format!("c2.{e0}.2.0"));
    server.stop().await;

    let server = lost.activate(1).await;
    lost.send(&server, &["restore-y"]).await;
    let (y1, _) = lost.newest(&server).await;
    let e1 = epoch_of(&y1);
    assert_eq!(y1, format!("c2.{e1}.2.0"));
    assert_ne!(e1, e0);
    lost.assert_reset(&server, &x0).await;
    server.stop().await;

    let server = lost.activate(0).await;
    lost.send(&server, &["restore-z"]).await;
    let (z2, _) = lost.newest(&server).await;
    let e2 = epoch_of(&z2);
    assert_eq!(z2, format!("c2.{e2}.2.0"), "the same file activated again");
    assert_ne!(e2, e0);
    assert_ne!(e2, e1);
    lost.assert_reset(&server, &x0).await;
    lost.assert_reset(&server, &y1).await;
    server.stop().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_ordinary_restart_after_a_restore_keeps_cursor_tokens() {
    let lost = lose_an_unarchived_batch("log-restore-restart", 1).await;
    let server = lost.activate(0).await;
    lost.send(&server, &["restore-f"]).await;
    lost.send(&server, &["restore-g"]).await;
    let (status, before) = server.search(&lost.org, "").await;
    assert_eq!(status, StatusCode::OK);
    let before = rows(&before);
    let epoch = epoch_of(&before[0].0);
    server.stop().await;

    let server = Server::start(&lost.env, &lost.name).await;
    let (status, after) = server.search(&lost.org, "").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(rows(&after), before, "identical cursor strings");
    let response = server.tail(&lost.org, &format!("c2.{epoch}.2.0")).await;
    assert_eq!(response.status(), StatusCode::OK);
    let events = read_sse(response, Duration::from_secs(5), |name, _| {
        name == "entries"
    })
    .await;
    let (_, entries) = events.iter().find(|(name, _)| name == "entries").unwrap();
    assert_eq!(entries["rows"][0]["body"], "restore-g");
    assert_eq!(entries["rows"][0]["cursor"], format!("c2.{epoch}.2.1"));
    server.stop().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn report_evidence_published_before_a_restore_stays_resolvable() {
    use sha2::Digest;
    let lost = lose_an_unarchived_batch("log-restore-report", 1).await;
    let server = lost.activate(0).await;
    lost.send(&server, &["restore-f"]).await;
    let epoch = epoch_of(&lost.newest(&server).await.0);
    let user: i64 = server
        .rt
        .control
        .query_one_raw(sql(
            "SELECT user_id FROM memberships WHERE org_id = ?",
            vec![lost.org.clone().into()],
        ))
        .await
        .unwrap()
        .unwrap()
        .try_get("", "user_id")
        .unwrap();
    let access = postdeploy::identity::access::authorize(
        &server.rt,
        postdeploy::domain::UserId(user),
        &lost.org_id,
    )
    .await
    .unwrap();
    let reports = &postdeploy::services::Services::get(&server.boot.app_context).reports;
    let view = serde_json::to_value(reports.get(&access, &lost.report).await.unwrap()).unwrap();
    assert_eq!(
        view["document"]["findings"][0]["evidence"][0]["cursor"],
        "c1.1.1"
    );
    assert_eq!(
        view["evidence"][0]["evidence"]["cursor"],
        format!("c2.{epoch}.1.1")
    );
    assert_eq!(view["evidence"][0]["log"]["object_id"], 1);

    let html = server
        .page(&format!(
            "/dashboard/orgs/{}/projects/{}/reports/{}",
            lost.org,
            lost.project,
            lost.report.as_str()
        ))
        .await;
    let link = format!(
        "/dashboard/orgs/{}/projects/{}/logs?cursor=c2.{epoch}.1.1",
        lost.org, lost.project
    );
    assert!(html.contains(&link), "{html}");
    let logs = server.page(&link).await;
    assert!(logs.contains("restore-b"), "{logs}");
    assert!(!logs.contains("restore-c"), "{logs}");

    let body = server
        .rt
        .store
        .get(&lost.report_key, 1 << 20)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(hex::encode(sha2::Sha256::digest(&body)), lost.report_sha);
    server.stop().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "requires isolated R2 credentials; creates and cleans one owned local-verification prefix"]
async fn real_r2_restore_recovers_a_prefix_and_rotates_each_marked_activation() {
    use postdeploy::credentials::Credentials;
    use sha2::{Digest, Sha256};
    let path = PathBuf::from(std::env::var_os("POSTDEPLOY_CREDENTIALS_FILE").unwrap());
    let credentials = Credentials::load(&path, "test").unwrap();
    assert_eq!(credentials.r2.bucket, "postdeploy-rust-local-test-20261015");
    let name = format!("storage-fix1-{}", uuid::Uuid::now_v7().simple());
    let prefix = format!("local-verification/{name}/");
    println!("actual R2 owned prefix={prefix}");
    let password = zeroize::Zeroizing::new(format!("Restore!{}", uuid::Uuid::now_v7().simple()));
    let email = format!("{name}@example.test");
    let env = TestEnv::new(&name);
    let boot = env.boot_r2(&prefix, restore_settings).await.unwrap();
    let (base, server) = serve(&boot).await;
    let rt = Runtime::get(&boot.app_context);
    let api = Api::signup_with_password(&base, &email, &password).await;
    let (org, project, dsn) = api.setup_source(&name).await;
    let c = Ctx {
        env,
        boot,
        server,
        base,
        rt,
        api,
        org_id: org.parse().unwrap(),
        org,
        project,
        key: dsn_key(&dsn),
    };
    assert_eq!(c.send(&["real-a", "real-b"]).await.0, StatusCode::OK);
    let user: i64 =
        c.rt.control
            .query_one_raw(sql(
                "SELECT user_id FROM memberships WHERE org_id = ?",
                vec![c.org.clone().into()],
            ))
            .await
            .unwrap()
            .unwrap()
            .try_get("", "user_id")
            .unwrap();
    let access =
        postdeploy::identity::access::authorize(&c.rt, postdeploy::domain::UserId(user), &c.org_id)
            .await
            .unwrap();
    let report = postdeploy::services::Services::get(&c.boot.app_context)
        .reports
        .publish(
            &access,
            serde_json::from_value(
                json!({"project_id": c.project, "title": "Real R2 before restore",
            "summary": "Original entry", "findings": [{"title": "Entry", "severity": "low",
            "detail": "entry", "evidence": [{"kind": "log", "cursor": "c1.1.1"}]}]}),
            )
            .unwrap(),
        )
        .await
        .unwrap()
        .report
        .id;
    let backup = backup_org(&c).await;
    assert_eq!(c.send(&["real-c"]).await.0, StatusCode::OK);
    eventually(Duration::from_secs(30), || async {
        c.status().await["archived_objects"] == 1
    })
    .await;
    assert_eq!(
        c.send(&["real-d", "real-e", "real-f"]).await.0,
        StatusCode::OK
    );
    eventually(Duration::from_secs(30), || async {
        c.status().await["archived_objects"] == 2
    })
    .await;
    let usage = log_usage(&c.rt, &c.org_id).await;
    assert_eq!(usage.0, 6);
    let expected = c
        .search("")
        .await
        .into_iter()
        .map(|(cursor, body)| (cursor.strip_prefix("c1.").unwrap().to_owned(), body))
        .collect::<Vec<_>>();
    assert_eq!(c.send(&["lost-unarchived"]).await.0, StatusCode::OK);
    assert_eq!(
        c.search("").await[0],
        ("c1.3.0".into(), "lost-unarchived".into())
    );
    let keys = c.rt.store.list_page("", None, 10).await.unwrap();
    assert!(keys.next.is_none());
    assert_eq!(
        keys.keys.len(),
        6,
        "one report, a control, organization and manifest backup set, and two archives"
    );
    let mut hashes = Vec::new();
    for key in &keys.keys {
        let body = c.rt.store.get(key, 4 << 20).await.unwrap().unwrap();
        hashes.push((key.clone(), hex::encode(Sha256::digest(&body))));
    }
    let mut files = Vec::new();
    for index in 0..2 {
        let file = c.env.dir.join("restored-real").join(format!("f{index}.db"));
        restore_org(&c, backup, &file).await;
        files.push(file);
    }
    let Ctx {
        env,
        boot,
        server,
        rt,
        org,
        org_id,
        project,
        key,
        ..
    } = c;
    rt.shutdown().await;
    server.abort();
    drop((rt, boot));
    let mut epochs = Vec::new();
    let mut stale = vec!["c1.3.0".to_owned()];
    for file in [0, 1, 0] {
        activate(&env, &org_id, &files[file]);
        let boot = env.boot_r2(&prefix, restore_settings).await.unwrap();
        let (base, server) = serve(&boot).await;
        let rt = Runtime::get(&boot.app_context);
        let mut api = Api::new(&base);
        assert_eq!(api.auth("login", &email, &password).await.0, StatusCode::OK);
        eventually(Duration::from_secs(60), || async {
            let (_, status) = api.get(&format!("/api/orgs/{org}/logs/storage")).await;
            assert_eq!(status["restore_conflict"], Value::Null, "{status}");
            status["restore_required"] == false
        })
        .await;
        let (status, page) = api.get(&format!("/api/orgs/{org}/logs?limit=50")).await;
        assert_eq!(status, StatusCode::OK, "{page}");
        let actual = rows(&page);
        let epoch = epoch_of(&actual[0].0);
        assert!(
            !epochs.contains(&epoch),
            "each marked activation has its own epoch"
        );
        epochs.push(epoch.clone());
        let access =
            postdeploy::identity::access::authorize(&rt, postdeploy::domain::UserId(user), &org_id)
                .await
                .unwrap();
        let view = serde_json::to_value(
            postdeploy::services::Services::get(&boot.app_context)
                .reports
                .get(&access, &report)
                .await
                .unwrap(),
        )
        .unwrap();
        assert_eq!(
            view["document"]["findings"][0]["evidence"][0]["cursor"],
            "c1.1.1"
        );
        assert_eq!(
            view["evidence"][0]["evidence"]["cursor"],
            format!("c2.{epoch}.1.1")
        );
        assert_eq!(view["evidence"][0]["log"]["object_id"], 1);
        let positions = actual
            .into_iter()
            .map(|(cursor, body)| {
                (
                    cursor
                        .strip_prefix(&format!("c2.{epoch}."))
                        .unwrap()
                        .to_owned(),
                    body,
                )
            })
            .collect::<Vec<_>>();
        assert_eq!(positions, expected);
        assert_eq!(
            log_usage(&rt, &org_id).await,
            usage,
            "historic usage exactly once"
        );
        for token in &stale {
            let (status, body) = api
                .get(&format!("/api/orgs/{org}/logs?before={token}"))
                .await;
            assert_eq!(status, StatusCode::CONFLICT);
            assert_eq!(body, json!({"error": "cursor_reset_required"}));
            let response = api
                .http
                .get(format!("{base}/api/orgs/{org}/logs/tail"))
                .header("cookie", api.cookie.clone().unwrap())
                .header("last-event-id", token)
                .send()
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::CONFLICT);
            assert_eq!(
                response.json::<Value>().await.unwrap(),
                json!({"error": "cursor_reset_required"})
            );
        }
        assert_eq!(
            post_envelope(
                &base,
                project,
                &key,
                envelope(None, &["fresh-unarchived"]),
                None
            )
            .await
            .0,
            StatusCode::OK
        );
        let (_, page) = api.get(&format!("/api/orgs/{org}/logs?limit=1")).await;
        let cursor = format!("c2.{epoch}.3.0");
        assert_eq!(rows(&page), [(cursor.clone(), "fresh-unarchived".into())]);
        stale.push(cursor);
        assert_eq!(
            rt.store.list_page("", None, 10).await.unwrap().keys,
            keys.keys
        );
        for (key, hash) in &hashes {
            let body = rt.store.get(key, 4 << 20).await.unwrap().unwrap();
            assert_eq!(
                &hex::encode(Sha256::digest(&body)),
                hash,
                "remote body unchanged {key}"
            );
        }
        if epochs.len() == 3 {
            for key in &keys.keys {
                rt.store.delete(key).await.unwrap();
            }
            assert!(rt
                .store
                .list_page("", None, 10)
                .await
                .unwrap()
                .keys
                .is_empty());
        }
        rt.shutdown().await;
        server.abort();
        drop((rt, boot));
    }
    println!("actual R2 prefix={prefix} marked_activations=3 distinct_epochs=3 recovered_entries=6 historic_report_resolves=3 unchanged_remote_bodies=6 cleaned_objects=6");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn reports_reject_stale_log_evidence_while_a_repeated_restore_is_pending() {
    let lost = lose_an_unarchived_batch("log-report-pending-repeat", 1).await;
    let server = lost.activate(0).await;
    lost.send(&server, &["sibling-x", "sibling-y", "sibling-z"])
        .await;
    lost.send(&server, &["later-a", "later-b", "later-c"]).await;
    lost.send(&server, &["later-d", "later-e", "later-f"]).await;
    eventually(Duration::from_secs(10), || async {
        server
            .api
            .get(&format!("/api/orgs/{}/logs/storage", lost.org))
            .await
            .1["archived_objects"]
            == 4
    })
    .await;
    let (_, page) = server.search(&lost.org, "").await;
    assert!(rows(&page)
        .iter()
        .any(|(cursor, body)| cursor.ends_with(".2.0") && body == "sibling-x"));
    let sibling_key: String = server
        .rt
        .tenant(&lost.org_id)
        .await
        .unwrap()
        .query_one_raw(sql(
            "SELECT object_key FROM log_objects WHERE id = 2",
            vec![],
        ))
        .await
        .unwrap()
        .unwrap()
        .try_get("", "object_key")
        .unwrap();
    server.stop().await;

    activate(&lost.env, &lost.org_id, &lost.files[0]);
    lost.env.faults.delay_get_ms.store(3_000, Ordering::SeqCst);
    let server = Server::start(&lost.env, &lost.name).await;
    let token = server.mcp_token(&lost.org_id).await;
    eventually(Duration::from_secs(20), || async {
        let tenant = server.rt.tenant(&lost.org_id).await.unwrap();
        tenant
            .query_one_raw(sql(
                "SELECT id FROM log_objects WHERE id = 2 AND state = 'archived'",
                vec![],
            ))
            .await
            .unwrap()
            .is_some()
    })
    .await;
    {
        let tenant = server.rt.tenant(&lost.org_id).await.unwrap();
        let row = tenant
            .query_one_raw(sql(
                "SELECT logs_reconcile_required, cursor_epoch FROM restore_state WHERE id = 1",
                vec![],
            ))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(
            row.try_get::<i64>("", "logs_reconcile_required").unwrap(),
            1
        );
        assert_eq!(row.try_get::<i64>("", "cursor_epoch").unwrap(), 0);
        let row = tenant
            .query_one_raw(sql(
                "SELECT object_key FROM log_objects WHERE id = 2",
                vec![],
            ))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(
            row.try_get::<String>("", "object_key").unwrap(),
            sibling_key
        );
    }
    let (status, body) = server.search(&lost.org, "").await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body, json!({"error": "log_restore_pending"}));
    let report = json!({"project_id": lost.project, "title": "Pending repeat restore", "summary": "stale d must never cite sibling x",
        "findings": [{"title": "Entry", "severity": "low", "detail": "entry", "evidence": [{"kind": "log", "cursor": "c1.2.0"}]}]});
    let result = server.mcp(&token, "publish_report", report.clone()).await;
    let reports: i64 = server
        .rt
        .tenant(&lost.org_id)
        .await
        .unwrap()
        .query_one_raw(sql("SELECT COUNT(*) AS n FROM reports", vec![]))
        .await
        .unwrap()
        .unwrap()
        .try_get("", "n")
        .unwrap();
    eprintln!("pending repeated restore, sibling id 2 already inserted, stale c1.2.0 publish result={result}, report rows={reports}");
    lost.env.faults.delay_get_ms.store(0, Ordering::SeqCst);
    server.wait_restored(&lost.org).await;
    assert_eq!(
        result,
        json!({"error": "log_restore_pending", "retry_after_secs": 1})
    );
    assert_eq!(reports, 1, "only the report present in the backup remains");
    assert_eq!(
        server.mcp(&token, "publish_report", report).await,
        json!({"error": "cursor_reset_required"})
    );
    let (_, page) = server.search(&lost.org, "").await;
    assert!(rows(&page)
        .iter()
        .any(|(cursor, body)| cursor.ends_with(".2.0") && body == "sibling-x"));
    server.stop().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_already_expired_sealed_batch_skips_upload_and_retains_metadata_until_delete_retries() {
    use postdeploy::{
        domain::{Environment, ProjectId, SourceId},
        logs::{object::Partition, record::LogRecord, retention, storage},
    };
    let c = Ctx::new("log-expired-before-upload", |s| {
        quiet_batches(s);
        s["logs"]["batch_max_entries"] = json!(1);
        s["logs"]["sweep_interval_secs"] = json!(3_600);
    })
    .await;
    let source: i64 =
        c.rt.control
            .query_one_raw(sql(
                "SELECT id FROM sources WHERE project_id = ?",
                vec![c.project.into()],
            ))
            .await
            .unwrap()
            .unwrap()
            .try_get("", "id")
            .unwrap();
    let partition = Partition {
        org: c.org_id.clone(),
        project: ProjectId(c.project),
        source: SourceId(source),
        environment: Environment::parse("production").unwrap(),
    };
    let received = now_micros() - 91 * DAY_US;
    let record: LogRecord = serde_json::from_value(json!({"ts": received, "rt": received, "level": "info", "body": "expired-before-upload", "attributes": {}})).unwrap();
    let hold =
        c.rt.quotas
            .reserve_at(
                &c.rt,
                &c.org_id,
                Usage {
                    logs: 1,
                    log_bytes: record.approx_bytes() as u64,
                    ..Usage::default()
                },
                received,
            )
            .await
            .unwrap();
    let puts = c.rt.store.counters().puts.load(Ordering::SeqCst);
    storage::append(&c.rt, &partition, vec![record], hold)
        .await
        .unwrap();
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert_eq!(
        c.rt.store.counters().puts.load(Ordering::SeqCst),
        puts,
        "expired sealed batch is never uploaded"
    );
    assert_eq!(
        c.scalar("SELECT COUNT(*) FROM log_objects WHERE state = 'sealed'")
            .await,
        1
    );
    assert_eq!(
        c.scalar("SELECT COUNT(*) FROM log_entries_pending").await,
        1
    );
    let key: String =
        c.rt.tenant(&c.org_id)
            .await
            .unwrap()
            .query_one_raw(sql(
                "SELECT object_key FROM log_objects WHERE id = 1",
                vec![],
            ))
            .await
            .unwrap()
            .unwrap()
            .try_get("", "object_key")
            .unwrap();
    c.rt.store
        .put(&key, bytes::Bytes::from_static(b"uploaded-before-crash"))
        .await
        .unwrap();
    c.env.faults.fail_deletes.store(1, Ordering::SeqCst);
    assert_eq!(retention::sweep_org(&c.rt, &c.org_id).await.unwrap(), 0);
    assert_eq!(c.scalar("SELECT COUNT(*) FROM log_objects").await, 1);
    assert_eq!(
        c.scalar("SELECT COUNT(*) FROM log_entries_pending").await,
        1
    );
    assert_eq!(c.rt.metrics.objects_expired.load(Ordering::SeqCst), 0);
    assert_eq!(
        c.rt.store.get(&key, 64).await.unwrap().unwrap().as_ref(),
        b"uploaded-before-crash"
    );
    assert_eq!(retention::sweep_org(&c.rt, &c.org_id).await.unwrap(), 1);
    assert!(c.rt.store.get(&key, 64).await.unwrap().is_none());
    assert_eq!(c.scalar("SELECT COUNT(*) FROM log_objects").await, 0);
    assert_eq!(
        c.scalar("SELECT COUNT(*) FROM log_entries_pending").await,
        0
    );
    assert_eq!(c.rt.metrics.objects_expired.load(Ordering::SeqCst), 1);
    assert_eq!(c.rt.metrics.objects_archived.load(Ordering::SeqCst), 0);
    assert!(c
        .rt
        .store
        .list_page(&format!("logs/v1/{}/", c.org), None, 10)
        .await
        .unwrap()
        .keys
        .is_empty());
    c.close().await;
}
