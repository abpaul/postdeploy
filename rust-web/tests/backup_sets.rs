mod support;

use postdeploy::{
    runtime::{sql, Runtime},
    testing::{serve, TestEnv},
};
use reqwest::StatusCode;
use sea_orm::ConnectionTrait;
use serde_json::json;
use support::*;

async fn revision(rt: &Runtime) -> i64 {
    rt.control
        .query_one_raw(sql(
            "SELECT revision FROM backup_revision WHERE id = 1",
            vec![],
        ))
        .await
        .unwrap()
        .unwrap()
        .try_get("", "revision")
        .unwrap()
}

async fn web_form(api: &Api, path: &str, fields: &[(&str, &str)]) -> StatusCode {
    let mut form: Vec<(&str, &str)> = fields.to_vec();
    form.push(("_csrf_token", api.csrf.as_deref().unwrap()));
    reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .unwrap()
        .post(format!("{}{path}", api.base))
        .header("cookie", api.cookie.as_deref().unwrap())
        .header("origin", "http://127.0.0.1:5167")
        .form(&form)
        .send()
        .await
        .unwrap()
        .status()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn structural_changes_bump_the_backup_revision_and_renames_do_not() {
    let env = TestEnv::new("backup-revision");
    let boot = env.boot_memory(|_| {}).await.unwrap();
    let (base, server) = serve(&boot).await;
    let rt = Runtime::get(&boot.app_context);
    assert_eq!(revision(&rt).await, 0);
    let api = Api::signup(&base, "backup-revision@example.test").await;
    let (org, _, _) = api.setup_source("Revision").await;
    assert_eq!(revision(&rt).await, 3, "organization, project and source");
    assert_eq!(
        web_form(
            &api,
            &format!("/dashboard/orgs/{org}/settings/name"),
            &[("name", "Renamed")]
        )
        .await,
        StatusCode::SEE_OTHER
    );
    assert_eq!(revision(&rt).await, 3, "a rename keeps ownership");
    let (status, _) = api
        .post(
            &format!("/api/orgs/{org}/projects"),
            json!({"name": "second"}),
        )
        .await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(revision(&rt).await, 4);
    assert_eq!(
        web_form(
            &api,
            &format!("/dashboard/orgs/{org}/delete"),
            &[("confirmed_name", "Renamed")]
        )
        .await,
        StatusCode::SEE_OTHER
    );
    assert_eq!(
        revision(&rt).await,
        8,
        "lifecycle change, two projects and the cascaded source"
    );
    rt.shutdown().await;
    server.abort();
}

async fn connect(path: &std::path::Path) -> sea_orm::DatabaseConnection {
    sea_orm::Database::connect(format!("sqlite://{}?mode=rwc", path.display()))
        .await
        .unwrap()
}

async fn texts(db: &impl ConnectionTrait, query: &str) -> Vec<String> {
    db.query_all_raw(sql(query, vec![]))
        .await
        .unwrap()
        .iter()
        .map(|row| row.try_get_by_index::<String>(0).unwrap())
        .collect()
}

/// Brings copies of databases at control migration 17 and organization migration 18
/// to the current schema. Existing rows stay and the new objects start empty.
async fn upgrade_migration_18(control_path: &std::path::Path, tenant_path: &std::path::Path) {
    use migration::{ControlMigrator, OrgMigrator};
    let control = connect(control_path).await;
    loco_rs::db::migrate::<ControlMigrator>(&control)
        .await
        .unwrap();
    let tenant = connect(tenant_path).await;
    loco_rs::db::migrate::<OrgMigrator>(&tenant).await.unwrap();
    assert_eq!(
        texts(
            &control,
            "SELECT version FROM seaql_migrations ORDER BY version DESC LIMIT 1"
        )
        .await,
        ["m20261017_000027_trial_notices"]
    );
    assert_eq!(
        texts(
            &tenant,
            "SELECT version FROM seaql_migrations ORDER BY version DESC LIMIT 1"
        )
        .await,
        ["m20261018_000028_event_lookup_indexes"]
    );
    assert_eq!(
        texts(
            &control,
            "SELECT CAST(revision AS TEXT) FROM backup_revision"
        )
        .await,
        ["0"]
    );
    assert_eq!(
        texts(&control, "SELECT CAST(COUNT(*) AS TEXT) FROM backup_cycles").await,
        ["0"]
    );
    assert_eq!(
        texts(&control, "SELECT CAST(COUNT(*) AS TEXT) FROM id_floor").await,
        ["0"]
    );
    assert_eq!(
        texts(
            &tenant,
            "SELECT COALESCE(CAST(snapshot_captured_at AS TEXT), 'null') FROM restore_state"
        )
        .await,
        ["null"]
    );
    assert_eq!(texts(&control, "PRAGMA integrity_check").await, ["ok"]);
    assert_eq!(texts(&tenant, "PRAGMA integrity_check").await, ["ok"]);
    control.close().await.unwrap();
    tenant.close().await.unwrap();
}

#[tokio::test]
async fn migrations_19_and_20_apply_to_databases_at_migration_18_and_keep_their_rows() {
    use migration::{ControlMigrator, MigratorTrait, OrgMigrator};
    let env = TestEnv::new("backup-migration-18");
    let control_path = env.dir.join("control.sqlite");
    let tenant_path = env.dir.join("tenant.db");
    let control = connect(&control_path).await;
    ControlMigrator::up(&control, Some(10)).await.unwrap();
    assert_eq!(
        texts(
            &control,
            "SELECT version FROM seaql_migrations ORDER BY version DESC LIMIT 1"
        )
        .await,
        ["m20261016_000017_ingestion_policies"]
    );
    control
        .execute_unprepared(
            "INSERT INTO users (id, email, password_hash, created_at) VALUES (1, 'm18@example.test', 'x', 1);
             INSERT INTO organizations (id, name, created_by, created_at) VALUES ('o0123456789abcdef0123456789abcdef', 'Kept', 1, 1);
             INSERT INTO projects (id, org_id, name, created_at) VALUES (7, 'o0123456789abcdef0123456789abcdef', 'web', 1);",
        )
        .await
        .unwrap();
    control.close().await.unwrap();
    let tenant = connect(&tenant_path).await;
    OrgMigrator::up(&tenant, Some(9)).await.unwrap();
    tenant
        .execute_unprepared(
            "INSERT INTO issues (project_id, environment, fingerprint, title, level, status, first_seen, last_seen, event_count)
             VALUES (7, 'production', 'f', 'kept-issue', 'error', 'open', 1, 1, 1)",
        )
        .await
        .unwrap();
    tenant.close().await.unwrap();

    upgrade_migration_18(&control_path, &tenant_path).await;
    let control = connect(&control_path).await;
    assert_eq!(texts(&control, "SELECT name FROM projects").await, ["web"]);
    control
        .execute_unprepared("INSERT INTO projects (id, org_id, name, created_at) VALUES (8, 'o0123456789abcdef0123456789abcdef', 'api', 2)")
        .await
        .unwrap();
    assert_eq!(
        texts(
            &control,
            "SELECT CAST(revision AS TEXT) FROM backup_revision"
        )
        .await,
        ["1"]
    );
    control.close().await.unwrap();
    let tenant = connect(&tenant_path).await;
    assert_eq!(
        texts(&tenant, "SELECT title FROM issues").await,
        ["kept-issue"]
    );
    tenant.close().await.unwrap();
}

/// Copies of retained databases at control migration 17 and organization migration 18. Set
/// `POSTDEPLOY_RETAINED_MIG18` to a directory holding `control.sqlite` (with its
/// `-wal`) and one `tenants/<org>.db`.
#[tokio::test]
#[ignore = "requires POSTDEPLOY_RETAINED_MIG18 copies of retained databases"]
async fn migrations_19_and_20_apply_to_retained_migration_18_copies() {
    let source = std::path::PathBuf::from(std::env::var_os("POSTDEPLOY_RETAINED_MIG18").unwrap());
    let env = TestEnv::new("backup-retained-migration-18");
    for suffix in ["", "-wal"] {
        let from = source.join(format!("control.sqlite{suffix}"));
        if from.exists() {
            std::fs::copy(&from, env.dir.join(format!("control.sqlite{suffix}"))).unwrap();
        }
    }
    let tenant = std::fs::read_dir(source.join("tenants"))
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .find(|path| path.extension().is_some_and(|ext| ext == "db"))
        .unwrap();
    std::fs::copy(&tenant, env.dir.join("tenant.db")).unwrap();
    let control = connect(&env.dir.join("control.sqlite")).await;
    let before = texts(
        &control,
        "SELECT id || ':' || name FROM organizations ORDER BY id",
    )
    .await;
    control.close().await.unwrap();
    upgrade_migration_18(&env.dir.join("control.sqlite"), &env.dir.join("tenant.db")).await;
    let control = connect(&env.dir.join("control.sqlite")).await;
    let after = texts(
        &control,
        "SELECT id || ':' || name FROM organizations ORDER BY id",
    )
    .await;
    control.close().await.unwrap();
    assert_eq!(after, before);
    println!(
        "retained migration 18 copies upgraded; organizations={}",
        after.len()
    );
}

use std::{
    path::Path,
    sync::{atomic::Ordering, Arc},
    time::Duration,
};

use postdeploy::{
    backup_sets::{manifest_key, Cycle, Stage},
    domain::OrgId,
    store::Faults,
};

/// Releases held backup seals when a test ends, so a failed assertion reports
/// instead of waiting on a blocked seal.
struct ReleaseSeals(Arc<Faults>);

impl Drop for ReleaseSeals {
    fn drop(&mut self) {
        self.0.hold_backup_seals(false);
    }
}

fn error_envelope(id: &str, value: &str, logs: &[&str]) -> Vec<u8> {
    let now = chrono::Utc::now().timestamp_micros() as f64 / 1e6;
    let mut out = format!("{}\n", json!({"event_id": id}));
    let event = json!({"event_id": id, "level": "error", "release": "web@1",
        "exception": {"values": [{"type": "Boom", "value": value, "stacktrace": {"frames": [
            {"function": value, "abs_path": "/srv/app/handler.rs", "in_app": true, "lineno": 3}]}}]}});
    out.push_str(&format!("{}\n{}\n", json!({"type": "event"}), event));
    if !logs.is_empty() {
        let items: Vec<serde_json::Value> = logs
            .iter()
            .map(|body| json!({"timestamp": now, "level": "info", "body": body}))
            .collect();
        let payload = json!({"items": items}).to_string();
        out.push_str(&format!(
            "{}\n{payload}\n",
            json!({"type": "log", "item_count": items.len(), "content_type": "application/vnd.sentry.items.log+json", "length": payload.len()})
        ));
    }
    out.into_bytes()
}

fn event_id(n: u32) -> String {
    format!("{n:032x}")
}

/// Pending logs stay in SQLite so restores exercise the pending-entry key check.
fn quiet(settings: &mut serde_json::Value) {
    settings["logs"]["batch_max_age_ms"] = json!(600_000);
    settings["logs"]["archive_tick_ms"] = json!(50);
}

struct Server {
    env: TestEnv,
    boot: loco_rs::boot::BootResult,
    server: tokio::task::JoinHandle<()>,
    base: String,
    rt: Arc<Runtime>,
    api: Api,
    org: String,
    org_id: OrgId,
    project: i64,
    key: String,
}

impl Server {
    async fn start(name: &str, settings: impl FnOnce(&mut serde_json::Value)) -> Self {
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

    async fn send(&self, body: Vec<u8>) -> StatusCode {
        post_envelope(&self.base, self.project, &self.key, body, None)
            .await
            .0
    }

    async fn stop(self) -> TestEnv {
        self.rt.shutdown().await;
        self.server.abort();
        self.env
    }

    async fn cycles(&self) -> Vec<String> {
        texts(
            &self.rt.control,
            "SELECT COALESCE(outcome, 'open') || ':' || COALESCE(stage, '-') || ':' || attempts FROM backup_cycles ORDER BY started_at",
        )
        .await
    }

    async fn manifests(&self) -> Vec<String> {
        all_keys(&self.rt)
            .await
            .into_iter()
            .filter(|key| key.ends_with("/manifest.pdbk"))
            .collect()
    }

    fn spawn_cycle(&self) -> tokio::task::JoinHandle<Cycle> {
        let (sets, rt) = (backup_sets(&self.boot), self.rt.clone());
        tokio::spawn(async move { sets.run_once(&rt).await })
    }

    async fn paused(&self) {
        tokio::time::timeout(
            Duration::from_secs(10),
            self.env.faults.backup_paused.notified(),
        )
        .await
        .expect("backup paused after the control member");
    }
}

async fn all_keys(rt: &Runtime) -> Vec<String> {
    let mut keys = Vec::new();
    let mut after: Option<String> = None;
    loop {
        let page = rt
            .store
            .list_page("", after.as_deref(), 1_000)
            .await
            .unwrap();
        keys.extend(page.keys);
        after = page.next;
        if after.is_none() {
            return keys;
        }
    }
}

async fn file_texts(path: &Path, query: &str) -> Vec<String> {
    let db = sea_orm::Database::connect(format!("sqlite://{}?mode=ro", path.display()))
        .await
        .unwrap();
    let values = texts(&db, query).await;
    db.close().await.unwrap();
    values
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack
        .windows(needle.len())
        .any(|window| window == needle)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_online_set_restores_committed_wal_rows_exactly_while_ingestion_keeps_succeeding() {
    let s = Server::start("backup-gate1", quiet).await;
    assert_eq!(
        s.send(error_envelope(
            &event_id(1),
            "committed-in-wal",
            &["log-before"]
        ))
        .await,
        StatusCode::OK
    );
    let tenant_file = s.env.tenant_root().join(format!("{}.db", s.org));
    let wal = std::fs::read(format!("{}-wal", tenant_file.display())).unwrap();
    assert!(
        contains(&wal, b"committed-in-wal"),
        "committed row is in the WAL"
    );
    assert!(
        !contains(&std::fs::read(&tenant_file).unwrap(), b"committed-in-wal"),
        "committed row is not checkpointed into the main file"
    );

    s.env
        .faults
        .pause_after_backup_member
        .store(true, Ordering::SeqCst);
    let cycle = s.spawn_cycle();
    s.paused().await;
    for n in 2..=6 {
        let value = format!("during-backup-{n}");
        let log = format!("log-during-backup-{n}");
        assert_eq!(
            s.send(error_envelope(&event_id(n), &value, &[&log])).await,
            StatusCode::OK,
            "ingestion accepted while the backup runs"
        );
    }
    let (status, page) = s
        .api
        .get(&format!("/api/orgs/{}/logs?limit=50", s.org))
        .await;
    assert_eq!(status, StatusCode::OK);
    let mut bodies: Vec<String> = page["rows"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| row["body"].as_str().unwrap().to_owned())
        .collect();
    bodies.sort();
    assert_eq!(
        bodies,
        [
            "log-before",
            "log-during-backup-2",
            "log-during-backup-3",
            "log-during-backup-4",
            "log-during-backup-5",
            "log-during-backup-6"
        ]
    );
    s.env.faults.backup_resume.notify_one();
    let Cycle::Complete(manifest) = cycle.await.unwrap() else {
        panic!("cycle did not complete");
    };
    assert_eq!(
        manifest.organizations.keys().collect::<Vec<_>>(),
        [&s.org_id]
    );
    assert_eq!(s.cycles().await, ["complete:-:1"]);

    let destination = s.env.dir.join("restored-gate1");
    let report = restore_set(&s.boot, manifest.set, &destination).await;
    let restored = destination.join("tenants").join(format!("{}.db", s.org));
    assert_eq!(report.organizations[0].path, restored);
    assert_eq!(report.control, destination.join("control.sqlite"));
    assert_eq!(
        file_texts(&restored, "SELECT title FROM issues ORDER BY title").await,
        [
            "Boom: committed-in-wal",
            "Boom: during-backup-2",
            "Boom: during-backup-3",
            "Boom: during-backup-4",
            "Boom: during-backup-5",
            "Boom: during-backup-6"
        ]
    );
    let usage = "SELECT category || '=' || accepted FROM usage_daily ORDER BY category";
    assert_eq!(file_texts(&restored, usage).await, ["error=6", "log=6"]);
    let live = s.rt.tenant(&s.org_id).await.unwrap();
    assert_eq!(texts(&*live, usage).await, ["error=6", "log=6"]);
    drop(live);
    for file in [&restored, &report.control] {
        assert_eq!(file_texts(file, "PRAGMA integrity_check").await, ["ok"]);
    }
    assert_eq!(
        file_texts(
            &restored,
            "SELECT logs_reconcile_required || ',' || orphan_cleanup_held FROM restore_state"
        )
        .await,
        ["1,1"]
    );
    assert_eq!(
        file_texts(
            &restored,
            "SELECT CAST(snapshot_captured_at AS TEXT) FROM restore_state"
        )
        .await,
        [manifest.organizations[&s.org_id].captured_at_us.to_string()]
    );
    assert_eq!(
        file_texts(
            &report.control,
            &format!("SELECT name FROM organizations WHERE id = '{}'", s.org)
        )
        .await,
        ["backup-gate1"]
    );
    assert!(!Path::new(&format!("{}.partial", destination.display())).exists());
    s.stop().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_failed_tenant_upload_leaves_the_previous_set_current() {
    let s = Server::start("backup-gate2-failure", quiet).await;
    let first = run_backup(&s.boot).await;
    s.env
        .faults
        .pause_after_backup_member
        .store(true, Ordering::SeqCst);
    let cycle = s.spawn_cycle();
    s.paused().await;
    s.env.faults.fail_puts.store(1, Ordering::SeqCst);
    s.env.faults.backup_resume.notify_one();
    match cycle.await.unwrap() {
        Cycle::Failed { stage, error } => {
            assert_eq!(stage, Stage::Organization(s.org_id.clone()));
            assert_eq!(
                error.to_string(),
                "object store: object store fault injected"
            );
        }
        other => panic!("expected a failed cycle: {other:?}"),
    }
    assert_eq!(
        s.cycles().await,
        [
            "complete:-:1".to_owned(),
            format!("failed:organization({}):1", s.org)
        ]
    );
    assert_eq!(s.manifests().await, [manifest_key(first.set)]);
    s.stop().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_structural_change_during_collection_retries_and_publishes_a_consistent_set() {
    let s = Server::start("backup-gate2-changed", quiet).await;
    s.env
        .faults
        .pause_after_backup_member
        .store(true, Ordering::SeqCst);
    let cycle = s.spawn_cycle();
    s.paused().await;
    let (status, _) = s
        .api
        .post(
            &format!("/api/orgs/{}/projects", s.org),
            json!({"name": "added-during-backup"}),
        )
        .await;
    assert_eq!(status, StatusCode::CREATED);
    s.env.faults.backup_resume.notify_one();
    let Cycle::Complete(manifest) = cycle.await.unwrap() else {
        panic!("cycle did not complete");
    };
    assert_eq!(s.cycles().await, ["complete:-:2"]);
    assert_eq!(manifest.revision, revision(&s.rt).await);
    assert_eq!(manifest.revision, 4);
    assert_eq!(s.manifests().await, [manifest_key(manifest.set)]);
    let destination = s.env.dir.join("restored-changed");
    let report = restore_set(&s.boot, manifest.set, &destination).await;
    assert_eq!(
        file_texts(&report.control, "SELECT name FROM projects ORDER BY id").await,
        ["web", "added-during-backup"]
    );
    s.stop().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn changes_on_every_attempt_exhaust_the_retry_budget_without_a_manifest() {
    let s = Server::start("backup-gate2-exhausted", quiet).await;
    s.env
        .faults
        .pause_after_backup_member
        .store(true, Ordering::SeqCst);
    let cycle = s.spawn_cycle();
    for attempt in 0..3 {
        s.paused().await;
        let (status, _) = s
            .api
            .post(
                &format!("/api/orgs/{}/projects", s.org),
                json!({"name": format!("moving-{attempt}")}),
            )
            .await;
        assert_eq!(status, StatusCode::CREATED);
        if attempt < 2 {
            s.env
                .faults
                .pause_after_backup_member
                .store(true, Ordering::SeqCst);
        }
        s.env.faults.backup_resume.notify_one();
    }
    assert!(matches!(
        cycle.await.unwrap(),
        Cycle::Changed { attempts: 3 }
    ));
    assert_eq!(s.cycles().await, ["changed:-:3"]);
    assert_eq!(s.manifests().await, Vec::<String>::new());
    s.stop().await;
}

fn hourly_loop_every_second(settings: &mut serde_json::Value) {
    quiet(settings);
    settings["backup"] = json!({"interval_secs": 1, "initial_delay_secs": 0});
}

fn no_backup_loop(settings: &mut serde_json::Value) {
    quiet(settings);
    settings["backup"] = json!({"initial_delay_secs": 86_400});
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_hourly_loop_publishes_sets_serially_and_shutdown_leaves_no_manifest() {
    let s = Server::start("backup-loop", hourly_loop_every_second).await;
    eventually(Duration::from_secs(20), || async {
        s.cycles()
            .await
            .iter()
            .filter(|row| row.starts_with("complete:"))
            .count()
            >= 2
    })
    .await;
    let _release = ReleaseSeals(s.env.faults.clone());
    s.env.faults.hold_backup_seals(true);
    tokio::time::timeout(
        Duration::from_secs(10),
        s.env.faults.backup_seal_held.notified(),
    )
    .await
    .expect("a later cycle reached its seal");
    let complete = s.cycles().await;
    eprintln!("cycles while a seal is held: {complete:?}");
    assert_eq!(complete.len(), 3, "{complete:?}");
    assert_eq!(&complete[..2], ["complete:-:1", "complete:-:1"]);
    assert_eq!(complete[2], "open:-:0");
    let sets = backup_sets(&s.boot);
    let puts = s.env.store.counters().puts.load(Ordering::SeqCst);
    s.rt.shutdown().await;
    s.server.abort();
    eprintln!("runtime shut down during a held seal");
    s.env.faults.hold_backup_seals(false);
    tokio::time::timeout(Duration::from_secs(10), sets.backups().idle())
        .await
        .unwrap();
    assert_eq!(
        s.env.store.counters().puts.load(Ordering::SeqCst),
        puts,
        "a cancelled attempt never starts an upload"
    );
    let manifests: Vec<String> = all_keys(&s.rt)
        .await
        .into_iter()
        .filter(|key| key.ends_with("/manifest.pdbk"))
        .collect();
    assert_eq!(manifests.len(), 2);

    let boot = s.env.boot_memory(no_backup_loop).await.unwrap();
    let rt = Runtime::get(&boot.app_context);
    eventually(Duration::from_secs(10), || async {
        texts(
            &rt.control,
            "SELECT COALESCE(outcome, 'open') FROM backup_cycles ORDER BY started_at",
        )
        .await
            == ["complete", "complete", "abandoned"]
    })
    .await;
    eventually(Duration::from_secs(10), || async {
        scratch_dirs(&s.env) == 0
    })
    .await;
    rt.shutdown().await;
}

const SOURCE_MAP: &str =
    r#"{"version":3,"file":"app.js","sources":["app.ts"],"names":[],"mappings":"AAAA"}"#;

async fn upload_release(s: &Server) {
    let response = s
        .api
        .http
        .post(format!(
            "{}/api/orgs/{}/projects/{}/artifacts",
            s.base, s.org, s.project
        ))
        .header("cookie", s.api.cookie.as_ref().unwrap())
        .header("x-csrf-token", s.api.csrf.as_ref().unwrap())
        .query(&[("release", "web@2"), ("name", "~/dist/app.js")])
        .header("content-type", "application/json")
        .body(SOURCE_MAP)
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::CREATED);
}

async fn publish_report(s: &Server) {
    let user: i64 =
        s.rt.control
            .query_one_raw(sql(
                "SELECT user_id FROM memberships WHERE org_id = ?",
                vec![s.org.clone().into()],
            ))
            .await
            .unwrap()
            .unwrap()
            .try_get("", "user_id")
            .unwrap();
    let access =
        postdeploy::identity::access::authorize(&s.rt, postdeploy::domain::UserId(user), &s.org_id)
            .await
            .unwrap();
    postdeploy::services::Services::get(&s.boot.app_context)
        .reports
        .publish(
            &access,
            serde_json::from_value(json!({"project_id": s.project, "title": "After the snapshot",
                "summary": "newer than the backup", "findings": [{"title": "Entry", "severity": "low",
                "detail": "entry", "evidence": [{"kind": "log", "cursor": "c1.1.0"}]}]}))
            .unwrap(),
        )
        .await
        .unwrap();
}

async fn log_usage(rt: &Runtime, org: &OrgId) -> Vec<String> {
    let tenant = rt.tenant(org).await.unwrap();
    texts(
        &*tenant,
        "SELECT CAST(COALESCE(SUM(accepted), 0) AS TEXT) || '/' || CAST(COALESCE(SUM(bytes), 0) AS TEXT) FROM usage_daily WHERE category = 'log'",
    )
    .await
}

fn archive_fast(settings: &mut serde_json::Value) {
    no_backup_loop(settings);
    fast_archive(settings);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn restoring_an_older_tenant_keeps_every_newer_payload_recovers_logs_once_and_reports_the_error_interval(
) {
    let s = Server::start("backup-gate3", archive_fast).await;
    assert_eq!(
        s.send(error_envelope(
            &event_id(1),
            "before-snapshot",
            &["log-before"]
        ))
        .await,
        StatusCode::OK
    );
    wait_archived(&s.api, &s.org).await;
    let manifest = run_backup(&s.boot).await;
    assert_eq!(
        s.send(error_envelope(
            &event_id(2),
            "after-snapshot",
            &["log-after-1", "log-after-2"]
        ))
        .await,
        StatusCode::OK
    );
    upload_release(&s).await;
    publish_report(&s).await;
    eventually(Duration::from_secs(20), || async {
        let (_, status) = s
            .api
            .get(&format!("/api/orgs/{}/logs/storage", s.org))
            .await;
        status["pending_entries"] == 0 && status["archived_objects"] == 2
    })
    .await;
    let keys = all_keys(&s.rt).await;
    let families: Vec<&str> = keys
        .iter()
        .map(|key| key.splitn(3, '/').take(2).last().unwrap())
        .collect();
    assert_eq!(
        families.iter().filter(|family| **family == "v1").count(),
        2 + 2 + 1 + 1,
        "{keys:?}"
    );
    let usage = log_usage(&s.rt, &s.org_id).await;
    assert_eq!(usage.len(), 1);

    let destination = s.env.dir.join("restored-gate3");
    let report = restore_set(&s.boot, manifest.set, &destination).await;
    let restored = &report.organizations[0];
    assert_eq!(
        serde_json::to_value(restored.unreferenced).unwrap(),
        json!({"errors": {"after_snapshot": 1, "before_snapshot": 0},
               "releases": {"after_snapshot": 1, "before_snapshot": 0},
               "reports": {"after_snapshot": 1, "before_snapshot": 0}})
    );
    assert_eq!(
        restored.snapshot_captured_at_us,
        manifest.organizations[&s.org_id].captured_at_us
    );
    assert_eq!(
        report.security_interval_from_us,
        manifest.control.captured_at_us
    );
    assert_eq!(
        report.billing_refresh_required,
        std::slice::from_ref(&s.org_id)
    );
    let restored_file = restored.path.clone();
    let (org, org_id, api_email) = (
        s.org.clone(),
        s.org_id.clone(),
        format!("{}@example.test", "backup-gate3"),
    );
    let env = s.stop().await;

    let live = env.tenant_root().join(format!("{org}.db"));
    for suffix in ["-wal", "-shm"] {
        let sidecar = std::path::PathBuf::from(format!("{}{suffix}", live.display()));
        if sidecar.exists() {
            std::fs::remove_file(sidecar).unwrap();
        }
    }
    std::fs::copy(&restored_file, &live).unwrap();

    for boot_number in 0..2 {
        let boot = env.boot_memory(archive_fast).await.unwrap();
        let (base, server) = serve(&boot).await;
        let rt = Runtime::get(&boot.app_context);
        let mut api = Api::new(&base);
        assert_eq!(
            api.auth("login", &api_email, PASSWORD).await.0,
            StatusCode::OK
        );
        eventually(Duration::from_secs(20), || async {
            let (_, status) = api.get(&format!("/api/orgs/{org}/logs/storage")).await;
            status["restore_required"] == false
        })
        .await;
        let (_, status) = api.get(&format!("/api/orgs/{org}/logs/storage")).await;
        assert_eq!(status["orphan_cleanup_held"], true);
        assert_eq!(
            log_usage(&rt, &org_id).await,
            usage,
            "recovered logs are charged once"
        );
        let (_, page) = api.get(&format!("/api/orgs/{org}/logs?limit=50")).await;
        let mut bodies: Vec<&str> = page["rows"]
            .as_array()
            .unwrap()
            .iter()
            .map(|row| row["body"].as_str().unwrap())
            .collect();
        bodies.sort_unstable();
        assert_eq!(bodies, ["log-after-1", "log-after-2", "log-before"]);
        let adopted = rt.metrics.objects_adopted.load(Ordering::SeqCst);
        assert_eq!(
            adopted,
            if boot_number == 0 { 1 } else { 0 },
            "logs recover exactly once"
        );

        let past_grace = postdeploy::domain::now_micros() + 7_201_000_000;
        let sweep = rt
            .orphan_retention
            .sweep_org(&org_id, past_grace)
            .await
            .unwrap();
        assert_eq!(
            format!("{sweep:?}"),
            "SweepReport { listed: 4, deleted: 0, delete_failures: 0, protected: 0, invalid: 0, held: true, unreferenced_after_snapshot: 3 }"
        );
        rt.error_retention
            .sweep_org(&org_id, postdeploy::domain::now_micros())
            .await
            .unwrap();
        assert_eq!(all_keys(&rt).await, keys, "every unexpired object survives");
        if boot_number == 1 {
            let tenant = rt.tenant(&org_id).await.unwrap();
            let referenced = texts(&*tenant, "SELECT payload_key FROM events").await;
            drop(tenant);
            assert_eq!(referenced.len(), 1, "{referenced:?}");
            let past_event_retention = postdeploy::domain::now_micros() + 91 * 86_400_000_000;
            let expired = rt
                .error_retention
                .sweep_org(&org_id, past_event_retention)
                .await
                .unwrap();
            assert_eq!(expired.events_deleted, 1);
            let expected: Vec<String> = keys
                .iter()
                .filter(|key| **key != referenced[0])
                .cloned()
                .collect();
            assert_eq!(
                all_keys(&rt).await,
                expected,
                "error retention deletes the expired referenced payload during the hold"
            );
            let (_, status) = api.get(&format!("/api/orgs/{org}/logs/storage")).await;
            assert_eq!(status["orphan_cleanup_held"], true);
        }
        rt.shutdown().await;
        server.abort();
    }
}

fn replace_database(live: &Path, restored: &Path) {
    for suffix in ["-wal", "-shm"] {
        let sidecar = std::path::PathBuf::from(format!("{}{suffix}", live.display()));
        if sidecar.exists() {
            std::fs::remove_file(sidecar).unwrap();
        }
    }
    std::fs::copy(restored, live).unwrap();
}

async fn log_bodies(api: &Api, query: &str) -> Vec<String> {
    let (status, page) = api.get(query).await;
    assert_eq!(status, StatusCode::OK, "{page}");
    let mut bodies: Vec<String> = page["rows"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| row["body"].as_str().unwrap().to_owned())
        .collect();
    bodies.sort();
    bodies
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn projects_created_after_restoring_older_control_never_reuse_lost_ids() {
    let s = Server::start("backup-id-reuse", archive_fast).await;
    let manifest = run_backup(&s.boot).await;
    let (status, lost_project) = s
        .api
        .post(
            &format!("/api/orgs/{}/projects", s.org),
            json!({"name": "lost"}),
        )
        .await;
    assert_eq!(status, StatusCode::CREATED);
    let lost_project = lost_project["id"].as_i64().unwrap();
    let (status, lost_source) = s
        .api
        .post(
            &format!("/api/orgs/{}/projects/{lost_project}/sources", s.org),
            json!({"name": "lost-api", "environment": "production"}),
        )
        .await;
    assert_eq!(status, StatusCode::CREATED);
    let lost_source_id = lost_source["source"]["id"].as_i64().unwrap();
    let lost_key = dsn_key(lost_source["dsn"].as_str().unwrap());
    assert_eq!(
        post_envelope(
            &s.base,
            lost_project,
            &lost_key,
            error_envelope(&event_id(1), "lost", &["lost-project-log"]),
            None
        )
        .await
        .0,
        StatusCode::OK
    );
    wait_archived(&s.api, &s.org).await;
    let forgotten =
        s.rt.control
            .execute_raw(sql(
                "DELETE FROM projects WHERE id = ?",
                vec![lost_project.into()],
            ))
            .await
            .unwrap();
    assert_eq!(
        forgotten.rows_affected(),
        1,
        "live control no longer knows the lost project, as after control loss"
    );

    let destination = s.env.dir.join("restored-id-reuse");
    let report = restore_set(&s.boot, manifest.set, &destination).await;
    assert_eq!(
        (report.project_id_floor, report.source_id_floor),
        (lost_project, lost_source_id)
    );
    let (org, email) = (s.org.clone(), "backup-id-reuse@example.test");
    let env = s.stop().await;
    replace_database(&env.dir.join("control.sqlite"), &report.control);
    replace_database(
        &env.tenant_root().join(format!("{org}.db")),
        &report.organizations[0].path,
    );

    let boot = env.boot_memory(archive_fast).await.unwrap();
    let (base, server) = serve(&boot).await;
    let mut api = Api::new(&base);
    assert_eq!(api.auth("login", email, PASSWORD).await.0, StatusCode::OK);
    eventually(Duration::from_secs(20), || async {
        let (_, status) = api.get(&format!("/api/orgs/{org}/logs/storage")).await;
        status["restore_required"] == false
    })
    .await;
    assert_eq!(
        log_bodies(&api, &format!("/api/orgs/{org}/logs?limit=50")).await,
        ["lost-project-log"],
        "the recovered entry stays in the organization"
    );
    let (status, created) = api
        .post(
            &format!("/api/orgs/{org}/projects"),
            json!({"name": "created-after-restore"}),
        )
        .await;
    assert_eq!(status, StatusCode::CREATED);
    let created = created["id"].as_i64().unwrap();
    assert_eq!(
        created,
        lost_project + 1,
        "the lost project id is not reused"
    );
    let (status, source) = api
        .post(
            &format!("/api/orgs/{org}/projects/{created}/sources"),
            json!({"name": "after-restore", "environment": "production"}),
        )
        .await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(source["source"]["id"].as_i64().unwrap(), lost_source_id + 1);
    assert_eq!(
        log_bodies(
            &api,
            &format!("/api/orgs/{org}/logs?limit=50&project={created}")
        )
        .await,
        Vec::<String>::new()
    );
    Runtime::get(&boot.app_context).shutdown().await;
    server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn ids_issued_between_the_restore_task_and_activation_are_never_reused() {
    let s = Server::start("backup-id-window", archive_fast).await;
    let manifest = run_backup(&s.boot).await;
    let destination = s.env.dir.join("restored-id-window");
    let report = restore_set(&s.boot, manifest.set, &destination).await;
    assert_eq!((report.project_id_floor, report.source_id_floor), (1, 1));

    let (status, window_project) = s
        .api
        .post(
            &format!("/api/orgs/{}/projects", s.org),
            json!({"name": "review-window"}),
        )
        .await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(window_project["id"].as_i64().unwrap(), 2);
    let (status, window_source) = s
        .api
        .post(
            &format!("/api/orgs/{}/projects/2/sources", s.org),
            json!({"name": "window-api", "environment": "production"}),
        )
        .await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(window_source["source"]["id"].as_i64().unwrap(), 2);
    let window_key = dsn_key(window_source["dsn"].as_str().unwrap());
    assert_eq!(
        post_envelope(
            &s.base,
            2,
            &window_key,
            error_envelope(&event_id(1), "window", &["review-window-log"]),
            None
        )
        .await
        .0,
        StatusCode::OK
    );
    wait_archived(&s.api, &s.org).await;

    let (org, email) = (s.org.clone(), "backup-id-window@example.test");
    let env = s.stop().await;
    replace_database(&env.dir.join("control.sqlite"), &report.control);
    replace_database(
        &env.tenant_root().join(format!("{org}.db")),
        &report.organizations[0].path,
    );
    let boot = env.boot_memory(archive_fast).await.unwrap();
    let (base, server) = serve(&boot).await;
    let mut api = Api::new(&base);
    assert_eq!(api.auth("login", email, PASSWORD).await.0, StatusCode::OK);
    let (status, created) = api
        .post(
            &format!("/api/orgs/{org}/projects"),
            json!({"name": "created-after-activation"}),
        )
        .await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(created["id"].as_i64().unwrap(), 3);
    let (status, source) = api
        .post(
            &format!("/api/orgs/{org}/projects/3/sources"),
            json!({"name": "after-activation", "environment": "production"}),
        )
        .await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(source["source"]["id"].as_i64().unwrap(), 3);
    eventually(Duration::from_secs(20), || async {
        let (_, status) = api.get(&format!("/api/orgs/{org}/logs/storage")).await;
        status["restore_required"] == false
    })
    .await;
    assert_eq!(
        log_bodies(&api, &format!("/api/orgs/{org}/logs?limit=50&project=3")).await,
        Vec::<String>::new()
    );
    assert_eq!(
        log_bodies(&api, &format!("/api/orgs/{org}/logs?limit=50&project=2")).await,
        ["review-window-log"]
    );
    Runtime::get(&boot.app_context).shutdown().await;
    server.abort();
    drop(boot);

    let restarted = env.boot_memory(archive_fast).await.unwrap();
    let rt = Runtime::get(&restarted.app_context);
    assert_eq!(
        texts(
            &rt.control,
            "SELECT name || ':' || CAST(floor AS TEXT) FROM id_floor ORDER BY name"
        )
        .await,
        ["projects:2", "sources:2"]
    );
    rt.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn restore_rejects_missing_tampered_misowned_or_tombstoned_sets_without_output() {
    let s = Server::start("backup-restore-rejects", no_backup_loop).await;
    let sets = backup_sets(&s.boot);
    let reject = |name: &'static str, set| {
        let destination = s.env.dir.join(name);
        let (sets, rt) = (sets.clone(), s.rt.clone());
        async move {
            let error = sets.restore(&rt, set, &destination).await.unwrap_err();
            assert!(!destination.exists(), "{name} has no output");
            error.to_string()
        }
    };
    let missing = postdeploy::backup_sets::SetId::generate();
    assert_eq!(
        reject("missing", missing).await,
        format!("backup object backups/sets/{missing}/manifest.pdbk not found")
    );

    let good = run_backup(&s.boot).await;
    let member = &good.organizations[&s.org_id].key;
    let object = s.rt.store.get(member, 64 << 20).await.unwrap().unwrap();
    let mut flipped = object.to_vec();
    let last = flipped.len() - 1;
    flipped[last] ^= 1;
    s.rt.store.put(member, flipped.into()).await.unwrap();
    assert_eq!(
        reject("tampered", good.set).await,
        "backup object failed authentication"
    );
    s.rt.store.put(member, object).await.unwrap();
    assert!(Path::new(&format!("{}.partial", s.env.dir.join("tampered").display())).is_dir());

    let other = s.api.setup_source("Other organization").await;
    let tenant = s.rt.tenant(&s.org_id).await.unwrap();
    tenant
        .execute_raw(sql(
            "INSERT INTO issues (project_id, environment, fingerprint, title, level, status, first_seen, last_seen, event_count)
             VALUES (?, 'production', 'stray', 'stray', 'error', 'open', 1, 1, 1)",
            vec![other.1.into()],
        ))
        .await
        .unwrap();
    drop(tenant);
    let misowned = run_backup(&s.boot).await;
    assert_eq!(
        reject("misowned", misowned.set).await,
        format!(
            "restored database is invalid: organization {} table issues references project_id {} outside the organization",
            s.org, other.1
        )
    );

    assert_eq!(
        web_form(
            &s.api,
            &format!("/dashboard/orgs/{}/delete", other.0),
            &[("confirmed_name", "Other organization")]
        )
        .await,
        StatusCode::SEE_OTHER
    );
    assert_eq!(
        reject("tombstoned", misowned.set).await,
        format!(
            "restored database is invalid: organization {} is deleted in the live control database",
            other.0
        )
    );
    let restored = restore_set(&s.boot, good.set, &s.env.dir.join("accepted")).await;
    assert_eq!(restored.organizations.len(), 1);
    s.stop().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_offline_restore_task_writes_the_set_and_refuses_a_live_server() {
    use loco_rs::{
        boot::create_context,
        environment::Environment,
        task::{Tasks, Vars},
    };
    let s = Server::start("backup-restore-task", no_backup_loop).await;
    assert_eq!(
        s.send(error_envelope(&event_id(1), "offline-restore", &[]))
            .await,
        StatusCode::OK
    );
    let manifest = run_backup(&s.boot).await;
    let mut tasks = Tasks::default();
    postdeploy::operations::register(&mut tasks);
    let destination = s
        .env
        .dir
        .parent()
        .unwrap()
        .join(format!("{}-offline", s.env.name))
        .join("set");
    std::fs::create_dir_all(destination.parent().unwrap()).unwrap();
    let vars = Vars::from_cli_args(vec![
        ("set".to_owned(), manifest.set.to_string()),
        ("destination".to_owned(), destination.display().to_string()),
    ]);
    assert_eq!(
        tasks
            .run(&s.boot.app_context, "restore", &vars)
            .await
            .unwrap_err()
            .to_string(),
        "operator tasks require a fresh offline context"
    );
    let org = s.org.clone();
    let env = s.stop().await;
    let config = env
        .config(&format!("test/{}/", env.name), no_backup_loop)
        .await;
    let ctx = create_context::<postdeploy::testing::TestApp>(&Environment::Test, config)
        .await
        .unwrap();
    tasks.run(&ctx, "restore", &vars).await.unwrap();
    let tenant = destination.join("tenants").join(format!("{org}.db"));
    assert_eq!(
        file_texts(&tenant, "SELECT title FROM issues").await,
        ["Boom: offline-restore"]
    );
    assert_eq!(
        file_texts(
            &destination.join("control.sqlite"),
            "PRAGMA integrity_check"
        )
        .await,
        ["ok"]
    );
    let config = env
        .config(&format!("test/{}/", env.name), no_backup_loop)
        .await;
    let ctx = create_context::<postdeploy::testing::TestApp>(&Environment::Test, config)
        .await
        .unwrap();
    let error = tasks
        .run(&ctx, "restore", &vars)
        .await
        .unwrap_err()
        .to_string();
    assert!(error.contains("already exists"), "{error}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_backup_sets_task_lists_and_verifies_sets_from_r2_with_an_empty_control_database() {
    use loco_rs::{
        boot::create_context,
        environment::Environment,
        task::{Tasks, Vars},
    };
    let s = Server::start("backup-sets-task", no_backup_loop).await;
    let older = run_backup(&s.boot).await;
    s.env
        .faults
        .pause_after_backup_member
        .store(true, Ordering::SeqCst);
    let cycle = s.spawn_cycle();
    s.paused().await;
    s.env.faults.fail_puts.store(1, Ordering::SeqCst);
    s.env.faults.backup_resume.notify_one();
    let Cycle::Failed { .. } = cycle.await.unwrap() else {
        panic!("expected a failed cycle");
    };
    let newest = run_backup(&s.boot).await;
    let sets = backup_sets(&s.boot);
    let listed: Vec<(bool, usize, Option<usize>)> = sets
        .list(&s.rt)
        .await
        .unwrap()
        .iter()
        .map(|set| (set.complete, set.objects, set.organizations))
        .collect();
    assert_eq!(
        listed,
        [(true, 3, Some(1)), (false, 1, None), (true, 3, Some(1))]
    );
    let ids: Vec<_> = sets
        .list(&s.rt)
        .await
        .unwrap()
        .iter()
        .map(|set| set.set)
        .collect();
    assert_eq!((ids[0], ids[2]), (newest.set, older.set));
    assert_eq!(sets.verify(&s.rt, newest.set).await.unwrap(), newest);

    let member = &older.organizations[&s.org_id].key;
    let object = s.rt.store.get(member, 64 << 20).await.unwrap().unwrap();
    let mut flipped = object.to_vec();
    let last = flipped.len() - 1;
    flipped[last] ^= 1;
    s.rt.store.put(member, flipped.into()).await.unwrap();
    assert_eq!(
        sets.verify(&s.rt, older.set).await.unwrap_err().to_string(),
        "backup object failed authentication"
    );
    assert!(
        !scratch_names(&s.env)
            .iter()
            .any(|name| name.starts_with("verify-")),
        "{:?}",
        scratch_names(&s.env)
    );

    let env = s.stop().await;
    let empty_control = env.dir.join("recovery-control.sqlite");
    let offline = || async {
        let mut config = env
            .config(&format!("test/{}/", env.name), no_backup_loop)
            .await;
        config.database.uri = format!("sqlite://{}?mode=rwc", empty_control.display());
        create_context::<postdeploy::testing::TestApp>(&Environment::Test, config)
            .await
            .unwrap()
    };
    let mut tasks = Tasks::default();
    postdeploy::operations::register(&mut tasks);
    let verify = |set: postdeploy::backup_sets::SetId| {
        Vars::from_cli_args(vec![("set".to_owned(), set.to_string())])
    };
    tasks
        .run(&offline().await, "backup-sets", &Vars::default())
        .await
        .unwrap();
    tasks
        .run(&offline().await, "backup-sets", &verify(newest.set))
        .await
        .unwrap();
    assert_eq!(
        tasks
            .run(&offline().await, "backup-sets", &verify(older.set))
            .await
            .unwrap_err()
            .to_string(),
        "backup object failed authentication"
    );
    let control = connect(&empty_control).await;
    assert_eq!(
        texts(&control, "SELECT name FROM sqlite_master").await,
        Vec::<String>::new(),
        "the tasks read and wrote no control table"
    );
    control.close().await.unwrap();
}

fn old_set(days: i64) -> String {
    let ms = (chrono::Utc::now().timestamp_millis() - days * 86_400_000) as u64;
    uuid::Uuid::new_v7(uuid::Timestamp::from_unix(
        uuid::NoContext,
        ms / 1000,
        ((ms % 1000) * 1_000_000) as u32,
    ))
    .simple()
    .to_string()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn retention_keeps_the_newest_valid_set_and_deletes_only_old_sets_under_backups_sets() {
    let s = Server::start("backup-retention", no_backup_loop).await;
    let (old_complete, old_incomplete, recent) = (old_set(15), old_set(16), old_set(1));
    let mut seeded = vec![
        format!("backups/sets/{old_complete}/manifest.pdbk"),
        format!("backups/sets/{old_complete}/control.pdbk"),
        format!("backups/sets/{old_complete}/org/{}.pdbk", s.org),
        format!("backups/sets/{old_incomplete}/control.pdbk"),
        format!("backups/sets/{recent}/control.pdbk"),
        "backups/control/legacy.pdbk".to_owned(),
        format!("backups/org/{}/legacy.pdbk", s.org),
        "other/keep".to_owned(),
    ];
    for key in &seeded {
        s.rt.store
            .put(key, bytes::Bytes::from_static(b"seed"))
            .await
            .unwrap();
    }
    let old_started = postdeploy::domain::now_micros() - 15 * 86_400_000_000;
    s.rt.control
        .execute_raw(sql(
            "INSERT INTO backup_cycles (set_id, started_at, finished_at, outcome, attempts) VALUES (?, ?, ?, 'complete', 1)",
            vec![old_complete.clone().into(), old_started.into(), old_started.into()],
        ))
        .await
        .unwrap();
    let current = run_backup(&s.boot).await;
    let mut expected = vec![
        format!("backups/sets/{recent}/control.pdbk"),
        "backups/control/legacy.pdbk".to_owned(),
        format!("backups/org/{}/legacy.pdbk", s.org),
        "other/keep".to_owned(),
        format!("backups/sets/{}/control.pdbk", current.set),
        format!("backups/sets/{}/manifest.pdbk", current.set),
        format!("backups/sets/{}/org/{}.pdbk", current.set, s.org),
    ];
    expected.sort();
    let backup_like = |keys: Vec<String>| -> Vec<String> {
        keys.into_iter()
            .filter(|key| key.starts_with("backups/") || key.starts_with("other/"))
            .collect()
    };
    assert_eq!(backup_like(all_keys(&s.rt).await), expected);
    assert_eq!(s.cycles().await, ["complete:-:1"]);

    s.env.faults.fail_puts.store(1, Ordering::SeqCst);
    let rt = s.rt.clone();
    assert!(matches!(
        backup_sets(&s.boot).run_once(&rt).await,
        Cycle::Failed {
            stage: Stage::Control,
            ..
        }
    ));
    assert_eq!(
        backup_like(all_keys(&s.rt).await),
        expected,
        "a failed cycle deletes nothing"
    );
    seeded.clear();
    s.stop().await;
}

fn scratch_dirs(env: &TestEnv) -> usize {
    std::fs::read_dir(env.dir.join("backup-scratch"))
        .unwrap()
        .count()
}

async fn backup_health(base: &str) -> serde_json::Value {
    let response = reqwest::get(format!("{base}/healthz")).await.unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    response.json::<serde_json::Value>().await.unwrap()["backups"].clone()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn two_transient_put_failures_keep_later_cycles_running_and_health_reports_them() {
    let s = Server::start("backup-transient-puts", no_backup_loop).await;
    for _ in 0..2 {
        s.env.faults.fail_puts.store(1, Ordering::SeqCst);
        match backup_sets(&s.boot).run_once(&s.rt).await {
            Cycle::Failed { stage, error } => {
                assert_eq!(stage, Stage::Control);
                assert_eq!(
                    error.to_string(),
                    "object store: object store fault injected"
                );
            }
            other => panic!("expected a failed cycle: {other:?}"),
        }
    }
    assert_eq!(scratch_dirs(&s.env), 1, "only the newest failure is kept");
    assert_eq!(
        backup_health(&s.base).await,
        json!({"state": "failing", "last_complete_age_secs": null})
    );

    let Cycle::Complete(manifest) = backup_sets(&s.boot).run_once(&s.rt).await else {
        panic!("the third cycle did not complete");
    };
    assert_eq!(
        s.cycles().await,
        ["failed:control:1", "failed:control:1", "complete:-:1"]
    );
    assert_eq!(s.manifests().await, [manifest_key(manifest.set)]);
    assert_eq!(scratch_dirs(&s.env), 1);
    let health = backup_health(&s.base).await;
    assert_eq!(health["state"], "ok", "{health}");
    let age = health["last_complete_age_secs"].as_u64().unwrap();
    assert!(age <= 5, "{health}");
    s.stop().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_organization_over_the_snapshot_cap_fails_the_cycle_by_name_without_a_manifest() {
    let s = Server::start("backup-oversize", |settings| {
        no_backup_loop(settings);
        settings["backup"]["max_snapshot_bytes"] = json!(1 << 20);
        settings["backup"]["max_object_bytes"] = json!(1 << 20);
    })
    .await;
    let (large, large_project, _) = s.api.setup_source("Large organization").await;
    let tenant = s.rt.tenant(&large.parse().unwrap()).await.unwrap();
    tenant
        .execute_raw(sql(
            "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 600)
             INSERT INTO issues (project_id, environment, fingerprint, title, level, status, first_seen, last_seen, event_count)
             SELECT ?, 'production', 'f' || i, hex(randomblob(1024)), 'error', 'open', 1, 1, 1 FROM n",
            vec![large_project.into()],
        ))
        .await
        .unwrap();
    drop(tenant);
    match backup_sets(&s.boot).run_once(&s.rt).await {
        Cycle::Failed { stage, error } => {
            assert_eq!(stage, Stage::Organization(large.parse().unwrap()));
            assert_eq!(error.to_string(), "snapshot exceeds 1048576 bytes");
        }
        other => panic!("expected a failed cycle: {other:?}"),
    }
    assert_eq!(
        texts(
            &s.rt.control,
            "SELECT outcome || ':' || stage || ':' || detail FROM backup_cycles"
        )
        .await,
        [format!(
            "failed:organization({large}):snapshot exceeds 1048576 bytes"
        )]
    );
    assert_eq!(s.manifests().await, Vec::<String>::new());
    let health = backup_health(&s.base).await;
    assert_eq!(health["state"], "failing", "{health}");
    s.stop().await;
}

fn scratch_names(env: &TestEnv) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(env.dir.join("backup-scratch"))
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    names
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn deleting_an_organization_removes_its_retained_plaintext_snapshot() {
    let s = Server::start("backup-deleted-org-scratch", no_backup_loop).await;
    s.env
        .faults
        .pause_after_backup_member
        .store(true, Ordering::SeqCst);
    let cycle = s.spawn_cycle();
    s.paused().await;
    s.env.faults.fail_puts.store(1, Ordering::SeqCst);
    s.env.faults.backup_resume.notify_one();
    assert!(matches!(
        cycle.await.unwrap(),
        Cycle::Failed {
            stage: Stage::Organization(_),
            ..
        }
    ));
    let retained = scratch_names(&s.env);
    assert_eq!(retained.len(), 1);
    assert!(
        retained[0].starts_with(&format!("org-{}-", s.org)),
        "{retained:?}"
    );
    assert!(s
        .env
        .dir
        .join("backup-scratch")
        .join(&retained[0])
        .join("snapshot.db")
        .is_file());

    assert_eq!(
        web_form(
            &s.api,
            &format!("/dashboard/orgs/{}/delete", s.org),
            &[("confirmed_name", "backup-deleted-org-scratch")]
        )
        .await,
        StatusCode::SEE_OTHER
    );
    for _ in 0..30 {
        s.rt.organization_lifecycle.sweep().await.unwrap();
        if texts(
            &s.rt.control,
            &format!("SELECT id FROM organizations WHERE id = '{}'", s.org),
        )
        .await
        .is_empty()
        {
            break;
        }
    }
    assert_eq!(
        texts(
            &s.rt.control,
            &format!("SELECT id FROM organizations WHERE id = '{}'", s.org)
        )
        .await,
        Vec::<String>::new()
    );
    assert_eq!(scratch_names(&s.env), Vec::<String>::new());
    s.stop().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_timed_out_member_fails_the_cycle_even_when_the_structure_changes() {
    let s = Server::start("backup-timeout-and-change", |settings| {
        no_backup_loop(settings);
        settings["backup"]["deadline_secs"] = json!(1);
    })
    .await;
    let _release = ReleaseSeals(s.env.faults.clone());
    s.env.faults.hold_backup_seals(true);
    let held = s.env.faults.backup_seal_held.notified();
    let cycle = s.spawn_cycle();
    tokio::time::timeout(Duration::from_secs(10), held)
        .await
        .expect("control seal held");
    let (status, _) = s
        .api
        .post(
            &format!("/api/orgs/{}/projects", s.org),
            json!({"name": "during-held-seal"}),
        )
        .await;
    assert_eq!(status, StatusCode::CREATED);
    match cycle.await.unwrap() {
        Cycle::Failed { stage, error } => {
            assert_eq!(stage, Stage::Control);
            assert_eq!(error.to_string(), "backup operation timed out");
        }
        other => panic!("expected a failed cycle: {other:?}"),
    }
    assert_eq!(s.cycles().await, ["failed:control:1"]);
    let scratch = std::fs::read_dir(s.env.dir.join("backup-scratch"))
        .unwrap()
        .count();
    assert_eq!(scratch, 1, "one snapshot only");
    s.env.faults.hold_backup_seals(false);
    s.stop().await;
}
