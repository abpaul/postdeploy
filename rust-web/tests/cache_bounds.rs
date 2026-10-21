mod support;

use std::{sync::Arc, time::Duration};

use loco_rs::{app::Hooks, boot::BootResult};
use postdeploy::{
    domain::{now_micros, Environment, OrgId, ProjectId, SourceId},
    error::ApiError,
    logs::{live::Published, read::Cursor},
    quota::{QuotaError, Usage},
    runtime::{sql, Runtime},
    testing::{serve, TestApp, TestEnv},
};
use reqwest::StatusCode;
use sea_orm::ConnectionTrait;
use serde_json::json;
use support::*;

struct Tenant {
    org: OrgId,
    project: i64,
    key: String,
}
struct Fixture {
    env: TestEnv,
    boot: BootResult,
    api: Api,
    rt: Arc<Runtime>,
    server: tokio::task::JoinHandle<()>,
    tenants: Vec<Tenant>,
}

impl Fixture {
    async fn new(name: &str, cap: usize, logs: u64) -> Self {
        Self::build(name, cap, logs, false, 86_400, 1).await
    }

    async fn build(
        name: &str,
        cap: usize,
        logs: u64,
        background: bool,
        interval: u64,
        page: usize,
    ) -> Self {
        let env = TestEnv::new(name);
        let boot = env
            .boot_memory(|s| {
                s["lifecycle"]["max_cached_orgs"] = json!(cap);
                s["logs"]["batch_max_entries"] = json!(1);
                s["logs"]["reconcile_max_objects"] = json!(page);
                s["quotas"]["daily_logs"] = json!(logs);
                s["logs"]["sweep_interval_secs"] = json!(interval);
                s["quotas"]["daily_errors"] = json!(logs);
            })
            .await
            .unwrap();
        let rt = Runtime::get(&boot.app_context);
        if !background {
            rt.cancel.cancel();
        }
        let (base, server) = serve(&boot).await;
        let api = Api::signup(&base, &format!("{name}@example.test")).await;
        let mut tenants = Vec::new();
        for index in 0..4 {
            let (org, project, dsn) = api.setup_source(&format!("Cache {index}")).await;
            tenants.push(Tenant {
                org: org.parse().unwrap(),
                project,
                key: dsn_key(&dsn),
            });
        }
        Self {
            env,
            boot,
            api,
            rt,
            server,
            tenants,
        }
    }
    async fn ingest(&self, at: usize, body: &str) -> (StatusCode, serde_json::Value) {
        let tenant = &self.tenants[at];
        post_envelope(
            &self.api.base,
            tenant.project,
            &tenant.key,
            envelope(None, &[body]),
            None,
        )
        .await
    }
    fn bounded(&self, cap: usize) {
        assert!(self.rt.quotas.cached_orgs() <= cap);
        assert!(self.rt.hub.cached_orgs() <= cap);
        assert!(self.rt.reconciliation.cached_orgs() <= cap);
        assert!(self.rt.dirty_orgs() <= cap);
    }
    async fn close(self) {
        TestApp::on_shutdown(&self.boot.app_context).await;
        self.server.abort();
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn idle_cache_churn_preserves_http_ingestion_search_and_live_delivery() {
    let _ = tracing_subscriber::fmt()
        .with_max_level(tracing::Level::ERROR)
        .with_test_writer()
        .try_init();
    let f = Fixture::build("cache-idle-churn", 2, 100, false, 86_400, 32).await;
    for round in 0..3 {
        for at in 0..f.tenants.len() {
            let marker = format!("cachechurn{at}round{round}");
            let (status, response) = f.ingest(at, &marker).await;
            assert_eq!(
                status,
                StatusCode::OK,
                "round={round} at={at} response={response} ready={} quota={} progress={} dirty={}",
                f.rt.quotas.is_ready(&f.tenants[at].org),
                f.rt.quotas.cached_orgs(),
                f.rt.reconciliation.cached_orgs(),
                f.rt.dirty_orgs()
            );
            let org = &f.tenants[at].org;
            let (status, page) = f.api.get(&format!("/api/orgs/{org}/logs?q={marker}")).await;
            assert_eq!(status, StatusCode::OK);
            assert_eq!(page["rows"][0]["body"], json!(marker));
            let response = f
                .api
                .http
                .get(format!(
                    "{}/api/orgs/{org}/logs/tail?after=c1.0.4294967295",
                    f.api.base
                ))
                .header("cookie", f.api.cookie.as_deref().unwrap())
                .send()
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::OK);
            let frames = read_sse(response, Duration::from_secs(2), |event, body| {
                event == "entries" && body.to_string().contains(&marker)
            })
            .await;
            assert!(frames
                .iter()
                .any(|(event, body)| event == "entries" && body.to_string().contains(&marker)));
            f.bounded(2);
        }
    }
    f.close().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn active_quota_holds_cannot_be_evicted_and_idle_reload_uses_sqlite_usage() {
    let f = Fixture::new("cache-active-holds", 2, 2).await;
    assert_eq!(f.ingest(0, "cachecommitted").await.0, StatusCode::OK);
    let want = Usage {
        logs: 1,
        ..Usage::default()
    };
    let first =
        f.rt.quotas
            .reserve(&f.rt, &f.tenants[0].org, want)
            .await
            .unwrap();
    let second =
        f.rt.quotas
            .reserve(&f.rt, &f.tenants[1].org, want)
            .await
            .unwrap();
    assert!(matches!(
        f.rt.quotas.reserve(&f.rt, &f.tenants[2].org, want).await,
        Err(QuotaError::Unavailable(ApiError::Unavailable(
            "org_cache_overloaded"
        )))
    ));
    assert!(matches!(
        f.rt.quotas.reserve(&f.rt, &f.tenants[0].org, want).await,
        Err(QuotaError::Exceeded("log_item"))
    ));
    drop(first);
    let third =
        f.rt.quotas
            .reserve(&f.rt, &f.tenants[2].org, want)
            .await
            .unwrap();
    drop((second, third));
    assert!(matches!(
        f.rt.quotas
            .reserve(
                &f.rt,
                &f.tenants[0].org,
                Usage {
                    logs: 2,
                    ..Usage::default()
                }
            )
            .await,
        Err(QuotaError::Exceeded("log_item"))
    ));
    f.bounded(2);
    f.close().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn live_cache_preserves_active_arc_and_receiver_then_reuses_idle_slot() {
    let f = Fixture::new("cache-live-leases", 1, 100).await;
    let first = f.rt.hub.channel(&f.tenants[0].org).unwrap();
    assert!(matches!(
        f.rt.hub.channel(&f.tenants[1].org),
        Err(ApiError::Unavailable("org_cache_overloaded"))
    ));
    let overloaded = f
        .api
        .http
        .get(format!(
            "{}/api/orgs/{}/logs/tail",
            f.api.base, f.tenants[1].org
        ))
        .header("cookie", f.api.cookie.as_deref().unwrap())
        .timeout(Duration::from_secs(2))
        .send()
        .await
        .unwrap();
    assert_eq!(overloaded.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(
        overloaded.json::<serde_json::Value>().await.unwrap(),
        json!({"error":"org_cache_overloaded"})
    );
    let mut receiver = first.tx.subscribe();
    drop(first);
    assert!(matches!(
        f.rt.hub.channel(&f.tenants[1].org),
        Err(ApiError::Unavailable("org_cache_overloaded"))
    ));
    let same = f.rt.hub.channel(&f.tenants[0].org).unwrap();
    let cursor = Cursor { seq: 42, entry: 3 };
    assert!(same.tx.send(Arc::new(Published { cursor })).is_ok());
    assert_eq!(receiver.recv().await.unwrap().cursor, cursor);
    drop((receiver, same));
    assert!(f.rt.hub.channel(&f.tenants[1].org).is_ok());
    f.bounded(1);
    f.close().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn dirty_generation_between_readiness_and_reserve_returns_503() {
    let f = Fixture::new("cache-dirty-reserve", 2, 10).await;
    let org = &f.tenants[0].org;
    f.rt.quotas.ensure_ready(&f.rt, org).await.unwrap();
    let gate = f.rt.quotas.write(org).await.unwrap();
    let mut reserve = Box::pin(f.rt.quotas.reserve(
        &f.rt,
        org,
        Usage {
            logs: 1,
            ..Usage::default()
        },
    ));
    assert!(futures::poll!(reserve.as_mut()).is_pending());
    f.rt.mark_dirty(org);
    drop(gate);
    assert!(matches!(
        reserve.await,
        Err(QuotaError::Unavailable(ApiError::Unavailable(
            "reconciling"
        )))
    ));
    assert!(!f.rt.quotas.is_ready(org));
    assert_eq!(f.ingest(0, "cacheafterrepair").await.0, StatusCode::OK);
    f.close().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_live_viewer_cannot_make_another_organizations_ingestion_depend_on_live_cache_space() {
    let f = Fixture::build("cache-live-ingest-isolation", 1, 100, true, 86_400, 1).await;
    let org_a = &f.tenants[0].org;
    let org_b = &f.tenants[1].org;
    let viewer = f
        .api
        .http
        .get(format!("{}/api/orgs/{org_a}/logs/tail", f.api.base))
        .header("cookie", f.api.cookie.as_deref().unwrap())
        .send()
        .await
        .unwrap();
    assert_eq!(viewer.status(), StatusCode::OK);
    assert_eq!(f.ingest(1, "cacheotherdurable").await.0, StatusCode::OK);
    let (status, page) = f
        .api
        .get(&format!("/api/orgs/{org_b}/logs?q=cacheotherdurable"))
        .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(page["rows"][0]["body"], json!("cacheotherdurable"));
    assert_eq!(
        f.api.get(&format!("/api/orgs/{org_b}/logs/tail")).await.0,
        StatusCode::SERVICE_UNAVAILABLE
    );
    drop(viewer);
    let replay = tokio::time::timeout(Duration::from_secs(3), async {
        loop {
            let response = f
                .api
                .http
                .get(format!(
                    "{}/api/orgs/{org_b}/logs/tail?after=c1.0.4294967295",
                    f.api.base
                ))
                .header("cookie", f.api.cookie.as_deref().unwrap())
                .send()
                .await
                .unwrap();
            if response.status() == StatusCode::OK {
                break response;
            }
            assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .unwrap();
    let frames = read_sse(replay, Duration::from_secs(2), |event, body| {
        event == "entries" && body.to_string().contains("cacheotherdurable")
    })
    .await;
    assert!(frames
        .iter()
        .any(|(event, body)| event == "entries" && body.to_string().contains("cacheotherdurable")));
    f.bounded(1);
    f.close().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn multi_error_envelope_settles_each_committed_item_before_the_next_upload() {
    let f = Fixture::build("cache-multi-error-settle", 8, 3, true, 86_400, 1).await;
    let first = "10000000000000000000000000000001";
    let second = "10000000000000000000000000000002";
    let mut batch = envelope(Some(first), &[]);
    let extra = envelope(Some(second), &[]);
    batch.extend_from_slice(&extra[extra.iter().position(|b| *b == b'\n').unwrap() + 1..]);
    f.env
        .faults
        .pause_after_error_settle
        .store(true, std::sync::atomic::Ordering::SeqCst);
    let base = f.api.base.clone();
    let project = f.tenants[0].project;
    let key = f.tenants[0].key.clone();
    let request =
        tokio::spawn(async move { post_envelope(&base, project, &key, batch, None).await });
    tokio::time::timeout(
        Duration::from_secs(3),
        f.env.faults.error_settled.notified(),
    )
    .await
    .unwrap();
    let concurrent = post_envelope(
        &f.api.base,
        project,
        &f.tenants[0].key,
        envelope(Some("10000000000000000000000000000003"), &[]),
        None,
    )
    .await;
    assert_eq!(concurrent.0, StatusCode::OK);
    f.env.faults.error_resume.notify_one();
    assert_eq!(request.await.unwrap().0, StatusCode::OK);
    assert_eq!(
        post_envelope(
            &f.api.base,
            project,
            &f.tenants[0].key,
            envelope(Some("10000000000000000000000000000004"), &[]),
            None
        )
        .await
        .0,
        StatusCode::TOO_MANY_REQUESTS
    );
    let tenant = f.rt.tenant(&f.tenants[0].org).await.unwrap();
    let row = tenant.query_one_raw(sql("SELECT COUNT(*) AS events, (SELECT SUM(accepted) FROM usage_daily WHERE category='error') AS accepted FROM events", vec![])).await.unwrap().unwrap();
    assert_eq!(
        (
            row.try_get::<i64>("", "events").unwrap(),
            row.try_get::<i64>("", "accepted").unwrap()
        ),
        (3, 3)
    );
    drop(tenant);
    f.close().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_failed_error_upload_leaves_log_ingest_of_the_same_org_available() {
    let f = Fixture::build("cache-error-upload-logs", 8, 100, true, 86_400, 1).await;
    let project = f.tenants[0].project;
    let mut batch = envelope(Some("30000000000000000000000000000001"), &[]);
    let extra = envelope(Some("30000000000000000000000000000002"), &[]);
    batch.extend_from_slice(&extra[extra.iter().position(|b| *b == b'\n').unwrap() + 1..]);
    f.env
        .faults
        .pause_after_error_settle
        .store(true, std::sync::atomic::Ordering::SeqCst);
    let request = tokio::spawn({
        let (base, key) = (f.api.base.clone(), f.tenants[0].key.clone());
        async move { post_envelope(&base, project, &key, batch, None).await }
    });
    tokio::time::timeout(
        Duration::from_secs(3),
        f.env.faults.error_settled.notified(),
    )
    .await
    .unwrap();
    f.env
        .faults
        .fail_puts
        .store(1, std::sync::atomic::Ordering::SeqCst);
    let failed = post_envelope(
        &f.api.base,
        project,
        &f.tenants[0].key,
        envelope(Some("30000000000000000000000000000003"), &[]),
        None,
    )
    .await;
    assert_eq!(
        failed,
        (
            StatusCode::SERVICE_UNAVAILABLE,
            json!({"error": "ingest_unavailable"})
        )
    );
    let (status, body) = f.ingest(0, "logsduringstoreoutage").await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let org = &f.tenants[0].org;
    let (status, page) = f
        .api
        .get(&format!("/api/orgs/{org}/logs?q=logsduringstoreoutage"))
        .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(page["rows"][0]["body"], json!("logsduringstoreoutage"));
    f.env.faults.error_resume.notify_one();
    assert_eq!(request.await.unwrap().0, StatusCode::OK);
    f.close().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_ambiguous_error_commit_is_reloaded_before_retry_and_never_exceeds_sql_quota() {
    let f = Fixture::new("cache-ambiguous-error", 2, 1).await;
    f.env
        .faults
        .fail_error_after_commit
        .store(1, std::sync::atomic::Ordering::SeqCst);
    let tenant = &f.tenants[0];
    assert_eq!(
        post_envelope(
            &f.api.base,
            tenant.project,
            &tenant.key,
            envelope(Some("20000000000000000000000000000001"), &[]),
            None
        )
        .await
        .0,
        StatusCode::SERVICE_UNAVAILABLE
    );
    assert_eq!(
        post_envelope(
            &f.api.base,
            tenant.project,
            &tenant.key,
            envelope(Some("20000000000000000000000000000002"), &[]),
            None
        )
        .await
        .0,
        StatusCode::TOO_MANY_REQUESTS
    );
    let handle = f.rt.tenant(&tenant.org).await.unwrap();
    let row = handle.query_one_raw(sql("SELECT COUNT(*) AS events, (SELECT SUM(accepted) FROM usage_daily WHERE category='error') AS accepted FROM events", vec![])).await.unwrap().unwrap();
    assert_eq!(
        (
            row.try_get::<i64>("", "events").unwrap(),
            row.try_get::<i64>("", "accepted").unwrap()
        ),
        (1, 1)
    );
    drop(handle);
    assert_eq!(
        f.rt.store
            .list_page(&format!("errors/v1/{}/", tenant.org), None, 10)
            .await
            .unwrap()
            .keys
            .len(),
        1
    );
    f.close().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn captured_receipt_day_keeps_old_and_new_day_error_limits_independent() {
    use postdeploy::{
        ingest::event,
        issues::{self, Committed, EventSource},
    };
    let f = Fixture::new("cache-receipt-day", 2, 1).await;
    let tenant = &f.tenants[0];
    let source =
        f.rt.control
            .query_one_raw(sql(
                "SELECT id FROM sources WHERE project_id = ?",
                vec![tenant.project.into()],
            ))
            .await
            .unwrap()
            .unwrap()
            .try_get::<i64>("", "id")
            .unwrap();
    let environment = Environment::parse("production").unwrap();
    let at = EventSource {
        org: &tenant.org,
        project: ProjectId(tenant.project),
        source: SourceId(source),
        environment: &environment,
    };
    let today = now_micros();
    let yesterday = today - 86_400_000_000;
    let want = Usage {
        errors: 1,
        ..Usage::default()
    };
    let mut old =
        f.rt.quotas
            .reserve_at(&f.rt, &tenant.org, want, yesterday)
            .await
            .unwrap();
    let mapped = |id: &str, received| {
        event::map(
            &serde_json::to_vec(&json!({"event_id":id, "message":"receipt day fixture"})).unwrap(),
            None,
            at.project,
            &environment,
            received,
            1 << 20,
            &postdeploy::ingest::policy::IngestionPolicy::default(),
        )
        .unwrap()
    };
    assert!(matches!(
        issues::commit(
            &f.rt,
            &at,
            mapped("30000000000000000000000000000001", yesterday),
            yesterday
        )
        .await
        .unwrap(),
        Committed::New { .. }
    ));
    assert!(matches!(
        f.rt.quotas
            .reserve_at(&f.rt, &tenant.org, want, today)
            .await,
        Err(QuotaError::Unavailable(ApiError::Unavailable(
            "reconciling"
        )))
    ));
    old.settle(want, true);
    drop(old);
    let mut new =
        f.rt.quotas
            .reserve_at(&f.rt, &tenant.org, want, today)
            .await
            .unwrap();
    assert!(matches!(
        issues::commit(
            &f.rt,
            &at,
            mapped("30000000000000000000000000000002", today),
            today
        )
        .await
        .unwrap(),
        Committed::New { .. }
    ));
    new.settle(want, true);
    drop(new);
    assert!(matches!(
        issues::commit(
            &f.rt,
            &at,
            mapped("30000000000000000000000000000003", yesterday),
            yesterday
        )
        .await
        .unwrap(),
        Committed::QuotaExceeded
    ));
    assert!(matches!(
        issues::commit(
            &f.rt,
            &at,
            mapped("30000000000000000000000000000004", today),
            today
        )
        .await
        .unwrap(),
        Committed::QuotaExceeded
    ));
    let handle = f.rt.tenant(&tenant.org).await.unwrap();
    let rows = handle
        .query_all_raw(sql(
            "SELECT day, accepted FROM usage_daily WHERE category = 'error' ORDER BY day",
            vec![],
        ))
        .await
        .unwrap();
    assert_eq!(rows.len(), 2);
    assert_eq!(
        rows[0].try_get::<String>("", "day").unwrap(),
        postdeploy::domain::utc_day(yesterday)
    );
    assert_eq!(
        rows[1].try_get::<String>("", "day").unwrap(),
        postdeploy::domain::utc_day(today)
    );
    assert_eq!(
        (
            rows[0].try_get::<i64>("", "accepted").unwrap(),
            rows[1].try_get::<i64>("", "accepted").unwrap()
        ),
        (1, 1)
    );
    drop(handle);
    f.close().await;
}
