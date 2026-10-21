mod capacity_support;
mod support;

use std::{
    collections::{BTreeMap, BTreeSet},
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant},
};

use capacity_support::*;
use futures::StreamExt;
use loco_rs::app::Hooks;
use postdeploy::{
    app::App,
    backup::Backups,
    backup_sets::{BackupSets, Cycle},
    credentials::Credentials,
    domain::OrgId,
    error::ApiError,
    logs::retention,
    runtime::{sql, Runtime},
    testing::{serve, TestEnv},
};
use sea_orm::ConnectionTrait;
use serde_json::{json, Value};
use support::{dsn_key, envelope, Api};

#[derive(Clone)]
struct Tenant {
    org: OrgId,
    project: i64,
    key: String,
}

async fn ingest(
    http: &reqwest::Client,
    base: &str,
    tenant: &Tenant,
    config: &Workload,
    stats: &SharedStats,
) {
    let micros = chrono::Utc::now().timestamp_micros();
    let marker = format!("capacity.{micros}.{}.", uuid::Uuid::new_v4().simple());
    let suffix = payload(
        config.body_bytes.saturating_sub(marker.len()),
        config.entropy,
    );
    let body = format!("{marker}{suffix}");
    let bodies: Vec<&str> = std::iter::repeat_n(body.as_str(), config.logs_per_request).collect();
    let event = uuid::Uuid::new_v4().simple().to_string();
    let bytes = envelope(config.errors.then_some(event.as_str()), &bodies);
    let wire_bytes = bytes.len();
    let start = Instant::now();
    let result = http
        .post(format!("{base}/api/{}/envelope/", tenant.project))
        .header(
            "x-sentry-auth",
            format!("Sentry sentry_version=7, sentry_key={}", tenant.key),
        )
        .body(bytes)
        .send()
        .await;
    record_response(stats, "ingest", start, result, wire_bytes).await;
}

async fn viewer(response: reqwest::Response, stop: Arc<AtomicBool>, stats: SharedStats) {
    let mut stream = response.bytes_stream();
    let mut buffer = String::new();
    let mut cursors = std::collections::HashSet::new();
    while !stop.load(Ordering::Relaxed) {
        let next = tokio::time::timeout(Duration::from_millis(500), stream.next()).await;
        let chunk = match next {
            Err(_) => continue,
            Ok(Some(Ok(bytes))) => bytes,
            Ok(Some(Err(_))) => {
                stats.lock().unwrap().tail_stream_errors += 1;
                return;
            }
            Ok(None) => {
                stats.lock().unwrap().tail_stream_ends += 1;
                return;
            }
        };
        buffer.push_str(&String::from_utf8_lossy(&chunk));
        if buffer.len() > 2 << 20 {
            stats.lock().unwrap().tail_stream_errors += 1;
            return;
        }
        while let Some(end) = buffer.find("\n\n") {
            let frame: String = buffer.drain(..end + 2).collect();
            let name = frame
                .lines()
                .find_map(|line| line.strip_prefix("event:"))
                .unwrap_or("")
                .trim();
            let data = frame
                .lines()
                .find_map(|line| line.strip_prefix("data:"))
                .unwrap_or("")
                .trim();
            let Ok(data) = serde_json::from_str::<Value>(data) else {
                continue;
            };
            let mut stats = stats.lock().unwrap();
            if name == "closing" {
                stats.tail_closings += 1;
            }
            if name == "gap" {
                let reason = data["reason"].as_str().unwrap_or("unknown").to_owned();
                *stats.tail_gaps.entry(reason).or_default() += 1;
            }
            if name == "entries" {
                for row in data["rows"].as_array().into_iter().flatten() {
                    stats.tail_rows += 1;
                    if let Some(cursor) = row["cursor"].as_str() {
                        if !cursors.insert(cursor.to_owned()) {
                            stats.tail_duplicate_rows += 1;
                        }
                    }
                    if let Some(ts) = row["body"]
                        .as_str()
                        .and_then(|b| b.strip_prefix("capacity."))
                        .and_then(|b| b.split('.').next())
                        .and_then(|t| t.parse::<i64>().ok())
                    {
                        stats
                            .tail_latency_us
                            .push(chrono::Utc::now().timestamp_micros().saturating_sub(ts) as u64);
                    } else {
                        stats.tail_unrecognized_rows += 1;
                    }
                }
            }
        }
    }
}

async fn metadata(rt: &Runtime, tenants: &[Tenant]) -> Value {
    let mut totals = [0i64; 5];
    let mut active_orgs = 0;
    for tenant in tenants {
        let handle = rt.tenant(&tenant.org).await.unwrap();
        let row = handle.query_one_raw(sql("SELECT (SELECT COUNT(*) FROM events) AS errors, COUNT(*) AS objects, COALESCE(SUM(entry_count),0) AS entries, COALESCE(SUM(raw_bytes),0) AS raw_bytes, COALESCE(SUM(stored_bytes),0) AS stored_bytes FROM log_objects", vec![])).await.unwrap().unwrap();
        for (i, field) in ["errors", "objects", "entries", "raw_bytes", "stored_bytes"]
            .iter()
            .enumerate()
        {
            let count: i64 = row.try_get("", field).unwrap();
            totals[i] += count;
            if i == 0 && count > 0 {
                active_orgs += 1;
            }
        }
        drop(handle);
    }
    json!({"errors":totals[0], "objects":totals[1], "entries":totals[2], "raw_bytes":totals[3], "stored_bytes":totals[4], "orgs_with_errors":active_orgs})
}

async fn object_keys(rt: &Runtime, prefix: &str) -> BTreeSet<String> {
    let mut keys = BTreeSet::new();
    let mut after = None;
    loop {
        let page = rt
            .store
            .list_page(prefix, after.as_deref(), 1000)
            .await
            .unwrap();
        keys.extend(page.keys);
        match page.next {
            Some(next) => after = Some(next),
            None => return keys,
        }
    }
}

async fn metadata_keys(rt: &Runtime, tenants: &[Tenant], query: &str) -> BTreeSet<String> {
    let mut keys = BTreeSet::new();
    for tenant in tenants {
        let handle = rt.tenant(&tenant.org).await.unwrap();
        let rows = handle.query_all_raw(sql(query, vec![])).await.unwrap();
        keys.extend(
            rows.into_iter()
                .map(|row| row.try_get::<String>("", "key").unwrap()),
        );
    }
    keys
}

async fn ready_all(rt: &Runtime, tenants: &[Tenant]) {
    for tenant in tenants {
        tokio::time::timeout(Duration::from_secs(30), async {
            loop {
                match rt.quotas.ensure_ready(rt, &tenant.org).await {
                    Ok(()) => return,
                    Err(ApiError::Unavailable("reconciling" | "org_cache_overloaded")) => {}
                    Err(error) => panic!("post-restart readiness failed: {error}"),
                }
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
        })
        .await
        .expect("post-restart readiness completed within its bounded retry budget");
    }
}

/// Waits until every acknowledged log batch is archived in R2.
async fn archived_all(rt: &Runtime, tenants: &[Tenant], timeout: Duration) {
    tokio::time::timeout(timeout, async {
        loop {
            let mut pending = 0;
            for tenant in tenants {
                let status = postdeploy::logs::storage::status(rt, &tenant.org)
                    .await
                    .unwrap();
                pending += status.pending_entries;
            }
            if pending == 0 {
                return;
            }
            tokio::time::sleep(Duration::from_millis(500)).await;
        }
    })
    .await
    .expect("every acknowledged batch reached R2 before the key comparison");
}

async fn phase(
    env: &TestEnv,
    api: &Api,
    rt: Arc<Runtime>,
    tenants: &[Tenant],
    config: &Workload,
    burst: bool,
    report_dir: &std::path::Path,
) -> Value {
    let base = api.base.as_str();
    let resource_stop = Arc::new(AtomicBool::new(false));
    let sampler = spawn_sampler(
        env.dir.clone(),
        report_dir.to_owned(),
        resource_stop.clone(),
    );
    let before = metrics(&rt);
    let store_before = store_metrics(&rt);
    let caches_before = org_cache_counts(&rt);
    let observation_start = Instant::now();
    let stats: SharedStats = Arc::new(Mutex::new(Stats::default()));
    let stop = Arc::new(AtomicBool::new(false));
    let http = reqwest::Client::builder()
        .timeout(Duration::from_secs(config.request_timeout_secs))
        .build()
        .unwrap();
    let mut workers = Vec::new();
    for index in 0..config.viewers {
        let tenant = &tenants[index % tenants.len()];
        let start = Instant::now();
        let result = api
            .http
            .get(format!("{base}/api/orgs/{}/logs/tail", tenant.org))
            .header("cookie", api.cookie.as_deref().unwrap())
            .send()
            .await;
        match result {
            Ok(response) if response.status().is_success() => {
                stats.lock().unwrap().operation("tail_open").record(
                    start.elapsed(),
                    response.status().as_u16(),
                    0,
                );
                workers.push(tokio::spawn(viewer(response, stop.clone(), stats.clone())));
            }
            other => {
                record_response(&stats, "tail_open", start, other, 0).await;
            }
        }
    }
    for index in 0..config.searchers {
        let (api, tenant, stats, stop) = (
            api.clone(),
            tenants[index % tenants.len()].clone(),
            stats.clone(),
            stop.clone(),
        );
        let pause = config.search_interval_ms;
        workers.push(tokio::spawn(async move {
            while !stop.load(Ordering::Relaxed) {
                let start = Instant::now();
                let result = api
                    .http
                    .get(format!(
                        "{}/api/orgs/{}/logs?q=capacity&limit=20",
                        api.base, tenant.org
                    ))
                    .header("cookie", api.cookie.as_deref().unwrap())
                    .timeout(Duration::from_secs(30))
                    .send()
                    .await;
                record_response(&stats, "search", start, result, 0).await;
                tokio::time::sleep(Duration::from_millis(pause)).await;
            }
        }));
    }
    if config.cold_churn > 0 {
        let (rt, tenants, stats, stop) =
            (rt.clone(), tenants.to_vec(), stats.clone(), stop.clone());
        let count = config.cold_churn;
        workers.push(tokio::spawn(async move {
            let mut next = 0;
            while !stop.load(Ordering::Relaxed) {
                for _ in 0..count {
                    let tenant = &tenants[next % tenants.len()];
                    next += 1;
                    let started = Instant::now();
                    let result = rt
                        .tenants
                        .registry()
                        .evict(&tenant_sqlite_loco::TenantId::new(tenant.org.to_string()).unwrap())
                        .await;
                    let mut stats = stats.lock().unwrap();
                    stats.operation("cold_evict").record(
                        started.elapsed(),
                        if result.is_ok() { 200 } else { 503 },
                        0,
                    );
                }
                tokio::time::sleep(Duration::from_secs(1)).await;
            }
        }));
    }
    if config.retention_passes > 0 {
        let (rt, tenants, stats) = (rt.clone(), tenants.to_vec(), stats.clone());
        let passes = config.retention_passes;
        workers.push(tokio::spawn(async move {
            for pass in 0..passes {
                let tenant = &tenants[pass % tenants.len()];
                let start = Instant::now();
                let result = retention::sweep_org(&rt, &tenant.org).await;
                {
                    let mut stats = stats.lock().unwrap();
                    match result {
                        Ok(deleted) => {
                            stats.retention_objects_deleted += deleted as u64;
                            stats.operation("retention").record(start.elapsed(), 200, 0);
                        }
                        Err(_) => stats.operation("retention").record(start.elapsed(), 500, 0),
                    }
                }
                tokio::time::sleep(Duration::from_secs(1)).await;
            }
        }));
    }
    if config.backups > 0 {
        let (rt, stats) = (rt.clone(), stats.clone());
        let scratch = env.dir.join(format!(
            "scratch-{}",
            if burst { "burst" } else { "sustained" }
        ));
        std::fs::create_dir_all(&scratch).unwrap();
        let count = config.backups;
        workers.push(tokio::spawn(async move {
            let creds = Credentials::load(
                &PathBuf::from(std::env::var_os("POSTDEPLOY_CREDENTIALS_FILE").unwrap()),
                "test",
            )
            .unwrap();
            let settings = postdeploy::settings::BackupSettings {
                max_snapshot_bytes: 64 << 20,
                max_object_bytes: 64 << 20,
                deadline_secs: 60,
                max_scratch_dirs: count + 1,
                ..Default::default()
            };
            let sets = BackupSets::new(
                Backups::new(scratch, settings.limits(), &creds.security.data_key).unwrap(),
                settings,
            );
            for _ in 0..count {
                let start = Instant::now();
                let cycle = sets.run_once(&rt).await;
                let mut stats = stats.lock().unwrap();
                match cycle {
                    Cycle::Complete(manifest) => {
                        stats.backup_snapshot_bytes += manifest.raw_bytes();
                        stats.backup_object_bytes += manifest.sealed_bytes();
                        stats.operation("backup").record(start.elapsed(), 200, 0);
                    }
                    _ => stats.operation("backup").record(start.elapsed(), 500, 0),
                }
            }
        }));
    }
    let start = Instant::now();
    let limit = Arc::new(tokio::sync::Semaphore::new(config.concurrency));
    let requests = if burst {
        config.burst_requests
    } else {
        config.sustained_rps * config.seconds
    };
    let mut pending = tokio::task::JoinSet::new();
    for index in 0..requests {
        if !burst {
            let scheduled =
                start + Duration::from_secs_f64(index as f64 / config.sustained_rps as f64);
            tokio::time::sleep_until(tokio::time::Instant::from_std(scheduled)).await;
            stats
                .lock()
                .unwrap()
                .schedule_lateness_us
                .push(scheduled.elapsed().as_micros() as u64);
        }
        let queued = Instant::now();
        let permit = limit.clone().acquire_owned().await.unwrap();
        stats
            .lock()
            .unwrap()
            .queue_latency_us
            .push(queued.elapsed().as_micros() as u64);
        let (http, base, tenant, config, stats) = (
            http.clone(),
            base.to_owned(),
            tenants[index % tenants.len()].clone(),
            config.clone(),
            stats.clone(),
        );
        pending.spawn(async move {
            let _permit = permit;
            ingest(&http, &base, &tenant, &config, &stats).await;
        });
        while let Some(result) = pending.try_join_next() {
            result.unwrap();
        }
    }
    while let Some(result) = pending.join_next().await {
        result.unwrap();
    }
    let elapsed = start.elapsed();
    tokio::time::sleep(Duration::from_secs(config.tail_settle_secs)).await;
    stop.store(true, Ordering::Relaxed);
    for worker in workers {
        worker.await.unwrap();
    }
    resource_stop.store(true, Ordering::Relaxed);
    let resources = sampler.await.unwrap();
    let after = metrics(&rt);
    let store_after = store_metrics(&rt);
    let metadata = metadata(&rt, tenants).await;
    let mut summary = stats.lock().unwrap().summary();
    if config.searchers > 0 {
        assert_eq!(
            summary["operations"]["search"]["search_nonmatching_rows"],
            json!(0)
        );
    }
    summary["phase"] = json!(if burst { "burst" } else { "sustained" });
    summary["observation_seconds"] = json!(observation_start.elapsed().as_secs_f64());
    summary["elapsed_seconds"] = json!(elapsed.as_secs_f64());
    summary["offered_requests"] = json!(requests);
    summary["metrics_delta"] = delta(&before, &after);
    summary["store_delta"] = delta(&store_before, &store_after);
    summary["r2_latency"] = r2_latency(&store_before, &store_after);
    summary["metadata_cumulative"] = metadata;
    summary["org_cache_counts_before"] = caches_before;
    summary["org_cache_counts_after"] = org_cache_counts(&rt);
    summary["resources"] = resources;
    summary
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "isolated R2 release capacity run; use .audit/postdeploy-rust/capacity/run.py"]
async fn capacity_r2_workload() {
    if cfg!(debug_assertions) {
        panic!("capacity measurements require --release");
    }
    let credentials_path = PathBuf::from(
        std::env::var_os("POSTDEPLOY_CREDENTIALS_FILE").expect("encrypted test credentials"),
    );
    let credentials = Credentials::load(&credentials_path, "test").unwrap();
    assert_eq!(
        credentials.r2.bucket, "postdeploy-rust-local-test-20261015",
        "capacity only uses the isolated test bucket"
    );
    let config = Workload::from_env();
    let output = PathBuf::from(std::env::var_os("CAPACITY_OUTPUT").expect("CAPACITY_OUTPUT"));
    std::fs::create_dir_all(&output).unwrap();
    let mut results = Vec::new();
    for repetition in 0..config.repetitions {
        let id = uuid::Uuid::now_v7().simple().to_string();
        let prefix = format!("local-verification/capacity-{id}/");
        let env = TestEnv::new(&format!("capacity-{id}"));
        let configure = |s: &mut Value| {
            s["logs"]["batch_max_age_ms"] = json!(config.batch_age_ms);
            s["tenants"]["max_pools"] = json!(config.max_pools);
            s["lifecycle"]["max_cached_orgs"] = json!(config.max_cached_orgs);
        };
        let boot = env.boot_r2(&prefix, configure).await.unwrap();
        let (base, server) = serve(&boot).await;
        let password = zeroize::Zeroizing::new(format!(
            "Capacity!{}{}",
            uuid::Uuid::new_v4().simple(),
            uuid::Uuid::new_v4().simple()
        ));
        let api =
            Api::signup_with_password(&base, "capacity@example.test", password.as_str()).await;
        let mut tenants = Vec::new();
        for index in 0..config.orgs {
            let (org, project, dsn) = api.setup_source(&format!("Capacity {index}")).await;
            tenants.push(Tenant {
                org: org.parse().unwrap(),
                project,
                key: dsn_key(&dsn),
            });
        }
        let rt = Runtime::get(&boot.app_context);
        let runtime_limits = json!({"request_slots":rt.settings.lifecycle.max_active_requests,"org_cache_entries":rt.settings.lifecycle.max_cached_orgs,"query_slots":rt.settings.logs.search.max_active_queries,"object_reads_per_query":rt.settings.logs.search.concurrency,"log_upload_slots":rt.settings.logs.upload_concurrency,"error_commit_slots":rt.settings.ingest.error_lane,"log_backlog_bytes":rt.settings.logs.backlog_bytes,"org_log_backlog_bytes":rt.settings.logs.org_backlog_bytes,"tail_viewers":rt.settings.logs.tail.max_viewers,"tail_output_bytes":rt.settings.logs.tail.replay_max_output_bytes,"tenant_pools":rt.settings.tenants.max_pools,"connections_per_tenant":rt.settings.tenants.max_connections});
        let warmup: SharedStats = Arc::new(Mutex::new(Stats::default()));
        let warmup_http = reqwest::Client::builder()
            .timeout(Duration::from_secs(config.request_timeout_secs))
            .build()
            .unwrap();
        for tenant in &tenants {
            ingest(&warmup_http, &base, tenant, &config, &warmup).await;
        }
        assert_eq!(
            warmup.lock().unwrap().summary()["operations"]["ingest"]["successful"],
            json!(config.orgs),
            "every organization is active before measurement"
        );
        let mut phases = Vec::new();
        for burst in [false, true] {
            let report_dir = output.join(format!(
                "repetition-{repetition}-{}",
                if burst { "burst" } else { "sustained" }
            ));
            std::fs::create_dir_all(&report_dir).unwrap();
            let result = phase(
                &env,
                &api,
                rt.clone(),
                &tenants,
                &config,
                burst,
                &report_dir,
            )
            .await;
            std::fs::write(
                report_dir.join("result.json"),
                serde_json::to_vec_pretty(&result).unwrap(),
            )
            .unwrap();
            phases.push(result);
        }
        archived_all(
            &rt,
            &tenants,
            Duration::from_millis(config.batch_age_ms + 120_000),
        )
        .await;
        let metadata_before = metadata(&rt, &tenants).await;
        let log_keys = object_keys(&rt, "logs/").await;
        let error_keys = object_keys(&rt, "errors/").await;
        let backup_keys = object_keys(&rt, "backups/").await;
        let referenced_logs =
            metadata_keys(&rt, &tenants, "SELECT object_key AS key FROM log_objects").await;
        let referenced_errors =
            metadata_keys(&rt, &tenants, "SELECT payload_key AS key FROM events").await;
        assert!(
            referenced_logs.is_subset(&log_keys),
            "every indexed log object exists in R2"
        );
        assert!(
            referenced_errors.is_subset(&error_keys),
            "every committed error payload exists in R2"
        );
        let stored_logs = log_keys.len();
        let stored_errors = error_keys.len();
        let orphan_logs = log_keys.difference(&referenced_logs).count();
        let orphan_errors = error_keys.difference(&referenced_errors).count();
        std::fs::write(
            output.join(format!("checkpoint-{repetition}-before-restart.json")),
            serde_json::to_vec_pretty(&json!({
                "metadata": metadata_before,
                "log_keys": log_keys,
                "referenced_log_keys": referenced_logs,
                "unreferenced_log_keys": log_keys.difference(&referenced_logs).collect::<Vec<_>>(),
                "unreferenced_error_keys": error_keys.difference(&referenced_errors).collect::<Vec<_>>()
            })).unwrap(),
        ).unwrap();
        App::on_shutdown(&boot.app_context).await;
        let before = metrics(&rt);
        let accepted_logs = before["logs_accepted"];
        let accepted_errors = before["events_accepted"];
        let acknowledged = config.orgs as u64
            + phases
                .iter()
                .map(|phase| {
                    phase["operations"]["ingest"]["successful"]
                        .as_u64()
                        .unwrap()
                })
                .sum::<u64>();
        assert!(
            accepted_logs >= acknowledged * config.logs_per_request as u64,
            "each successful envelope committed its log records"
        );
        if config.errors {
            assert!(
                accepted_errors >= acknowledged,
                "each successful envelope committed its error event"
            );
        }
        assert_eq!(
            metadata_before["errors"].as_u64().unwrap(),
            accepted_errors,
            "accepted errors are persisted"
        );
        server.abort();
        drop(boot);
        let restarted = env.boot_r2(&prefix, configure).await.unwrap();
        let (base, server) = serve(&restarted).await;
        let mut api = Api::new(&base);
        assert_eq!(
            api.auth("login", "capacity@example.test", password.as_str())
                .await
                .0,
            reqwest::StatusCode::OK
        );
        let restarted_rt = Runtime::get(&restarted.app_context);
        ready_all(&restarted_rt, &tenants).await;
        let after_restart = metadata(&restarted_rt, &tenants).await;
        let recovered_log_keys = metadata_keys(
            &restarted_rt,
            &tenants,
            "SELECT object_key AS key FROM log_objects",
        )
        .await;
        let recovered_error_keys = metadata_keys(
            &restarted_rt,
            &tenants,
            "SELECT payload_key AS key FROM events",
        )
        .await;
        let actual_log_keys = object_keys(&restarted_rt, "logs/").await;
        let actual_error_keys = object_keys(&restarted_rt, "errors/").await;
        assert_eq!(
            actual_error_keys, error_keys,
            "restart preserves the observed R2 error payload set"
        );
        assert_eq!(
            actual_log_keys, log_keys,
            "restart preserves the actual observed immutable R2 object set"
        );
        assert_eq!(
            recovered_log_keys, log_keys,
            "restart keeps exactly the archived R2 log objects indexed"
        );
        assert!(
            referenced_logs.is_subset(&recovered_log_keys),
            "restart retains all original metadata references"
        );
        assert_eq!(
            recovered_error_keys, referenced_errors,
            "restart preserves every committed error payload reference"
        );
        let restarted_metrics = metrics(&restarted_rt);
        assert_eq!(
            after_restart["entries"].as_u64().unwrap(),
            accepted_logs,
            "metadata accounts for every accepted entry"
        );
        assert_eq!(after_restart["errors"].as_u64().unwrap(), accepted_errors);
        std::fs::write(
            output.join(format!("checkpoint-{repetition}-before-expiry.json")),
            serde_json::to_vec_pretty(&json!({
                "metadata": after_restart,
                "log_keys": actual_log_keys,
                "indexed_log_keys": recovered_log_keys,
                "before_shutdown_metrics": before,
                "restarted_metrics": restarted_metrics
            }))
            .unwrap(),
        )
        .unwrap();
        let mut search_statuses = BTreeMap::new();
        for tenant in &tenants {
            let (status, body) = api
                .get(&format!("/api/orgs/{}/logs?q=capacity&limit=1", tenant.org))
                .await;
            *search_statuses.entry(status.as_u16()).or_insert(0usize) += 1;
            assert_eq!(
                status,
                reqwest::StatusCode::OK,
                "each active organization is searchable after complete repair"
            );
            if status.is_success() && accepted_logs > 0 {
                assert_eq!(
                    body["rows"].as_array().unwrap().len(),
                    1,
                    "each active organization has searchable logs after restart"
                );
                assert!(body["rows"][0]["body"]
                    .as_str()
                    .is_some_and(|body| body.starts_with("capacity.")));
            }
        }
        let mut expired_entries = 0i64;
        let mut expired_objects = 0usize;
        for tenant in &tenants {
            let handle = restarted_rt.tenant(&tenant.org).await.unwrap();
            let row = handle
                .query_one_raw(sql(
                    "SELECT COALESCE(SUM(entry_count),0) AS entries FROM log_objects",
                    vec![],
                ))
                .await
                .unwrap()
                .unwrap();
            expired_entries += row.try_get::<i64>("", "entries").unwrap();
            handle
                .execute_raw(sql("UPDATE log_objects SET received_at = 0", vec![]))
                .await
                .unwrap();
            drop(handle);
            loop {
                let count = retention::sweep_org(&restarted_rt, &tenant.org)
                    .await
                    .unwrap();
                expired_objects += count;
                if count == 0 {
                    break;
                }
            }
        }
        let remaining = object_keys(&restarted_rt, "logs/").await.len();
        assert_eq!(
            remaining, 0,
            "retention removes every observed R2 log object after complete indexing"
        );
        let after_retention = metadata(&restarted_rt, &tenants).await;
        assert_eq!(after_retention["objects"], json!(0));
        assert_eq!(after_retention["entries"], json!(0));
        let result = json!({"repetition":repetition,"config":config,"runtime_limits":runtime_limits,"prefix":prefix,"data_dir":env.dir,"phases":phases,"metadata":after_restart,"metadata_before_restart":metadata_before,"acknowledged_envelopes":acknowledged,"r2_log_objects":stored_logs,"r2_error_objects":stored_errors,"r2_backup_objects":backup_keys.len(),"unreferenced_log_objects":orphan_logs,"unreferenced_error_objects":orphan_errors,"restart_metadata_equal":metadata_before==after_restart,"restart_metadata_preserved":true,"restarted_metrics":restarted_metrics,"restart_search_statuses":search_statuses,"retention":{"entries":expired_entries,"objects":expired_objects,"remaining_objects":remaining},"limitations":["Server and HTTP generator share one process. RSS, CPU, and FDs include both.","Counters count OpenDAL transport attempts; inner reqwest redirects or protocol retries can add wire requests. Object bytes count completed application transfers; failed partial bytes are unmeasured.","No capacity comparison verdict is valid without independent limiter profiling."]});
        std::fs::write(
            output.join(format!("repetition-{repetition}.json")),
            serde_json::to_vec_pretty(&result).unwrap(),
        )
        .unwrap();
        results.push(result);
        App::on_shutdown(&restarted.app_context).await;
        server.abort();
    }
    let report = json!({"runs":results,"aggregate":aggregate(&results)});
    std::fs::write(
        output.join("summary.json"),
        serde_json::to_vec_pretty(&report).unwrap(),
    )
    .unwrap();
    println!(
        "capacity evidence {}",
        output.join("summary.json").display()
    );
}
