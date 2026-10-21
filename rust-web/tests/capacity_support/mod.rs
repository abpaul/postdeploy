#![allow(dead_code)]

use postdeploy::runtime::Runtime;
use serde::Serialize;
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant},
};

#[derive(Clone, Serialize)]
pub struct Workload {
    pub repetitions: usize,
    pub orgs: usize,
    pub seconds: usize,
    pub sustained_rps: usize,
    pub burst_requests: usize,
    pub concurrency: usize,
    pub logs_per_request: usize,
    pub body_bytes: usize,
    pub entropy: bool,
    pub errors: bool,
    pub viewers: usize,
    pub searchers: usize,
    pub search_interval_ms: u64,
    pub cold_churn: usize,
    pub retention_passes: usize,
    pub backups: usize,
    pub max_pools: usize,
    pub max_cached_orgs: usize,
    pub batch_age_ms: u64,
    pub request_timeout_secs: u64,
    pub tail_settle_secs: u64,
}

impl Workload {
    pub fn from_env() -> Self {
        let number = |name: &str, default: usize| {
            std::env::var(format!("CAPACITY_{name}"))
                .ok()
                .map(|v| {
                    v.parse::<usize>()
                        .expect("positive integer workload setting")
                })
                .unwrap_or(default)
        };
        let orgs = number("ORGS", 100);
        let config = Self {
            repetitions: number("REPETITIONS", 5),
            orgs,
            seconds: number("SECONDS", 20),
            sustained_rps: number("RPS", 100),
            burst_requests: number("BURST_REQUESTS", orgs * 4),
            concurrency: number("CONCURRENCY", 100),
            logs_per_request: number("LOGS", 4),
            body_bytes: number("BODY_BYTES", 512),
            entropy: number("ENTROPY", 1) != 0,
            errors: number("ERRORS", 1) != 0,
            viewers: number("VIEWERS", 8),
            searchers: number("SEARCHERS", 2),
            search_interval_ms: number("SEARCH_INTERVAL_MS", 250) as u64,
            cold_churn: number("COLD_CHURN", 10),
            retention_passes: number("RETENTION_PASSES", 4),
            backups: number("BACKUPS", 2),
            max_pools: number("MAX_POOLS", 32),
            max_cached_orgs: number("CACHE_ORGS", 4_096),
            batch_age_ms: number("BATCH_AGE_MS", 100) as u64,
            request_timeout_secs: number("REQUEST_TIMEOUT_SECS", 45) as u64,
            tail_settle_secs: number("TAIL_SETTLE_SECS", 3) as u64,
        };
        assert!(
            config.orgs > 0
                && config.repetitions > 0
                && config.seconds > 0
                && config.sustained_rps > 0
                && config.concurrency > 0
        );
        assert!(
            config.logs_per_request > 0
                && config.logs_per_request <= 100
                && config.body_bytes <= 15_000
                && config.max_pools > 0
                && (1..=65_536).contains(&config.max_cached_orgs)
        );
        config
    }
}

#[derive(Default)]
pub struct Operation {
    pub latency_us: Vec<u64>,
    pub successful_latency_us: Vec<u64>,
    pub statuses: BTreeMap<u16, u64>,
    pub timed_out: u64,
    pub transport_failed: u64,
    pub invalid_json: u64,
    pub incomplete_successes: u64,
    pub wire_bytes: u64,
    pub response_bytes: u64,
    pub skipped: u64,
    pub error_bodies: BTreeMap<String, u64>,
    pub search_rows: u64,
    pub search_nonmatching_rows: u64,
    pub search_objects: u64,
    pub search_truncated: BTreeMap<String, u64>,
}

impl Operation {
    pub fn record(&mut self, elapsed: Duration, status: u16, wire_bytes: usize) {
        self.latency_us.push(elapsed.as_micros() as u64);
        if (200..300).contains(&status) {
            self.successful_latency_us.push(elapsed.as_micros() as u64);
        }
        *self.statuses.entry(status).or_default() += 1;
        self.wire_bytes += wire_bytes as u64;
    }

    fn summary(&self) -> Value {
        let successful: u64 = self
            .statuses
            .iter()
            .filter(|(s, _)| (200..300).contains(*s))
            .map(|(_, v)| *v)
            .sum::<u64>()
            .saturating_sub(self.incomplete_successes);
        let rejected: u64 = self
            .statuses
            .iter()
            .filter(|(s, _)| **s == 429 || **s == 503)
            .map(|(_, v)| *v)
            .sum();
        let http_failed: u64 = self
            .statuses
            .iter()
            .filter(|(s, _)| **s >= 400 && **s != 429 && **s != 503)
            .map(|(_, v)| *v)
            .sum();
        json!({"latency_ms":percentiles(&self.latency_us),"successful_latency_ms":percentiles(&self.successful_latency_us),"statuses":self.statuses,"successful":successful,"rejected":rejected,"http_failed":http_failed,"transport_failed":self.transport_failed,"timed_out":self.timed_out,"invalid_json":self.invalid_json,"incomplete_successes":self.incomplete_successes,"wire_bytes":self.wire_bytes,"response_bytes":self.response_bytes,"skipped_items":self.skipped,"error_bodies":self.error_bodies,"search_rows":self.search_rows,"search_nonmatching_rows":self.search_nonmatching_rows,"search_objects":self.search_objects,"search_truncated":self.search_truncated})
    }
}

#[derive(Default)]
pub struct Stats {
    operations: BTreeMap<String, Operation>,
    pub tail_rows: u64,
    pub tail_latency_us: Vec<u64>,
    pub tail_gaps: BTreeMap<String, u64>,
    pub tail_stream_errors: u64,
    pub tail_closings: u64,
    pub tail_stream_ends: u64,
    pub tail_duplicate_rows: u64,
    pub tail_unrecognized_rows: u64,
    pub queue_latency_us: Vec<u64>,
    pub schedule_lateness_us: Vec<u64>,
    pub retention_objects_deleted: u64,
    pub backup_snapshot_bytes: u64,
    pub backup_object_bytes: u64,
}

pub type SharedStats = Arc<Mutex<Stats>>;

impl Stats {
    pub fn operation(&mut self, name: &str) -> &mut Operation {
        self.operations.entry(name.to_owned()).or_default()
    }
    pub fn summary(&self) -> Value {
        let operations: BTreeMap<_, _> = self
            .operations
            .iter()
            .map(|(name, op)| (name.clone(), op.summary()))
            .collect();
        json!({"operations":operations,"tail_rows":self.tail_rows,"tail_latency_ms":percentiles(&self.tail_latency_us),"tail_gaps":self.tail_gaps,"tail_stream_errors":self.tail_stream_errors,"tail_closings":self.tail_closings,"tail_stream_ends":self.tail_stream_ends,"tail_duplicate_rows":self.tail_duplicate_rows,"tail_unrecognized_rows":self.tail_unrecognized_rows,"generator_queue_ms":percentiles(&self.queue_latency_us),"schedule_lateness_ms":percentiles(&self.schedule_lateness_us),"retention_objects_deleted":self.retention_objects_deleted,"backup_snapshot_bytes":self.backup_snapshot_bytes,"backup_object_bytes":self.backup_object_bytes})
    }
}

pub async fn record_response(
    stats: &SharedStats,
    name: &str,
    start: Instant,
    response: Result<reqwest::Response, reqwest::Error>,
    wire_bytes: usize,
) {
    let (status, text) = match response {
        Ok(response) => (response.status().as_u16(), response.text().await),
        Err(error) => {
            let mut stats = stats.lock().unwrap();
            let op = stats.operation(name);
            if error.is_timeout() {
                op.timed_out += 1;
            } else {
                op.transport_failed += 1;
            }
            op.latency_us.push(start.elapsed().as_micros() as u64);
            op.wire_bytes += wire_bytes as u64;
            return;
        }
    };
    let mut stats = stats.lock().unwrap();
    let op = stats.operation(name);
    op.record(start.elapsed(), status, wire_bytes);
    match text {
        Ok(text) => {
            op.response_bytes += text.len() as u64;
            match serde_json::from_str::<Value>(&text) {
                Ok(body) => {
                    let skipped = body["receipt"]["other"]["unsupported"]
                        .as_u64()
                        .unwrap_or(0);
                    op.skipped += skipped;
                    if name == "ingest" && (200..300).contains(&status) && skipped > 0 {
                        op.incomplete_successes += 1;
                        op.successful_latency_us.pop();
                    }
                    if let Some(error) = body["error"].as_str() {
                        *op.error_bodies.entry(error.to_owned()).or_default() += 1;
                    }
                    if name == "search" && (200..300).contains(&status) {
                        if let Some(rows) = body["rows"].as_array() {
                            op.search_rows += rows.len() as u64;
                            op.search_nonmatching_rows +=
                                rows.iter()
                                    .filter(|row| {
                                        !row["body"]
                                            .as_str()
                                            .is_some_and(|body| body.starts_with("capacity."))
                                    })
                                    .count() as u64;
                        } else {
                            op.incomplete_successes += 1;
                            op.successful_latency_us.pop();
                        }
                        op.search_objects += body["coverage"]["objects"].as_u64().unwrap_or(0);
                        if let Some(reason) = body["coverage"]["truncated_by"].as_str() {
                            *op.search_truncated.entry(reason.to_owned()).or_default() += 1;
                        }
                    }
                }
                Err(_) => {
                    op.invalid_json += 1;
                    if (200..300).contains(&status) {
                        op.incomplete_successes += 1;
                        op.successful_latency_us.pop();
                    }
                }
            }
        }
        Err(error) => {
            if error.is_timeout() {
                op.timed_out += 1;
            } else {
                op.transport_failed += 1;
            }
            if (200..300).contains(&status) {
                op.incomplete_successes += 1;
                op.successful_latency_us.pop();
            }
        }
    }
}

pub fn percentiles(values: &[u64]) -> Value {
    if values.is_empty() {
        return json!({"count":0});
    }
    let mut values = values.to_vec();
    values.sort_unstable();
    let percentile = |p: usize| values[((values.len() - 1) * p) / 100] as f64 / 1000.0;
    json!({"count":values.len(),"min":values[0] as f64/1000.0,"p50":percentile(50),"p95":percentile(95),"p99":percentile(99),"max":values[values.len()-1] as f64/1000.0})
}

pub fn payload(bytes: usize, entropy: bool) -> String {
    if !entropy {
        return "x".repeat(bytes);
    }
    use rand::Rng as _;
    const CHARS: &[u8] = b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    let mut rng = rand::rng();
    (0..bytes)
        .map(|_| CHARS[rng.random_range(0..CHARS.len())] as char)
        .collect()
}

pub fn org_cache_counts(rt: &Runtime) -> Value {
    json!({"quota":rt.quotas.cached_orgs(),"live":rt.hub.cached_orgs(),"reconciliation":rt.reconciliation.cached_orgs(),"dirty":rt.dirty_orgs(),"maximum":rt.settings.lifecycle.max_cached_orgs})
}

pub fn metrics(rt: &Runtime) -> BTreeMap<String, u64> {
    let m = &rt.metrics;
    [
        ("envelopes", &m.envelopes),
        ("events_accepted", &m.events_accepted),
        ("events_duplicate", &m.events_duplicate),
        ("events_dropped", &m.events_dropped),
        ("logs_accepted", &m.logs_accepted),
        ("logs_dropped", &m.logs_dropped),
        ("items_skipped", &m.items_skipped),
        ("rejected_rate", &m.rejected_rate),
        ("rejected_overload", &m.rejected_overload),
        ("log_batches_failed", &m.log_batches_failed),
        ("log_upload_retries", &m.log_upload_retries),
        ("objects_archived", &m.objects_archived),
        ("archive_conflicts", &m.archive_conflicts),
        ("logs_adopted", &m.logs_adopted),
        ("objects_adopted", &m.objects_adopted),
        ("objects_expired", &m.objects_expired),
    ]
    .into_iter()
    .map(|(k, v)| (k.to_owned(), v.load(Ordering::Relaxed)))
    .collect()
}

pub fn store_metrics(rt: &Runtime) -> BTreeMap<String, u64> {
    let s = rt.store.counters();
    [
        ("logical_puts", &s.puts),
        ("put_bytes", &s.put_bytes),
        ("logical_gets", &s.gets),
        ("get_bytes", &s.get_bytes),
        ("logical_lists", &s.lists),
        ("logical_deletes", &s.deletes),
        ("failures", &s.failures),
        ("http_requests", &s.http_requests),
        ("http_head", &s.http_head),
        ("http_get", &s.http_get),
        ("http_put", &s.http_put),
        ("http_delete", &s.http_delete),
        ("http_duration_us", &s.http_duration_us),
        ("http_max_duration_us", &s.http_max_duration_us),
        ("http_head_duration_us", &s.http_head_duration_us),
        ("http_head_max_duration_us", &s.http_head_max_duration_us),
        ("http_get_duration_us", &s.http_get_duration_us),
        ("http_get_max_duration_us", &s.http_get_max_duration_us),
        ("http_put_duration_us", &s.http_put_duration_us),
        ("http_put_max_duration_us", &s.http_put_max_duration_us),
        ("http_delete_duration_us", &s.http_delete_duration_us),
        (
            "http_delete_max_duration_us",
            &s.http_delete_max_duration_us,
        ),
        ("http_inflight", &s.http_inflight),
        ("http_inflight_peak", &s.http_inflight_peak),
        ("http_put_inflight", &s.http_put_inflight),
        ("http_put_inflight_peak", &s.http_put_inflight_peak),
        ("http_completed", &s.http_completed),
        ("http_failed", &s.http_failed),
        ("http_cancelled", &s.http_cancelled),
    ]
    .into_iter()
    .map(|(k, v)| (k.to_owned(), v.load(Ordering::Relaxed)))
    .collect()
}

pub fn delta(before: &BTreeMap<String, u64>, after: &BTreeMap<String, u64>) -> Value {
    json!(after
        .iter()
        .filter(|(key, _)| !key.ends_with("_peak")
            && !key.ends_with("_inflight")
            && !key.contains("_max_duration_us"))
        .map(|(k, v)| (k, v.saturating_sub(*before.get(k).unwrap_or(&0))))
        .collect::<BTreeMap<_, _>>())
}

pub fn r2_latency(before: &BTreeMap<String, u64>, after: &BTreeMap<String, u64>) -> Value {
    let mut methods = BTreeMap::new();
    for method in ["head", "get", "put", "delete"] {
        let count_key = format!("http_{method}");
        let duration_key = format!("http_{method}_duration_us");
        let max_key = format!("http_{method}_max_duration_us");
        let attempts = after[&count_key].saturating_sub(before[&count_key]);
        let duration = after[&duration_key].saturating_sub(before[&duration_key]);
        methods.insert(method,json!({"attempts":attempts,"mean_attempt_ms":if attempts>0 {Some(duration as f64/attempts as f64/1000.0)} else {None},"max_attempt_ms_cumulative":after[&max_key] as f64/1000.0}));
    }
    json!({"methods":methods,"inflight_before":before["http_inflight"],"inflight_after":after["http_inflight"],"peak_inflight_cumulative":after["http_inflight_peak"],"put_inflight_before":before["http_put_inflight"],"put_inflight_after":after["http_put_inflight"],"peak_put_inflight_cumulative":after["http_put_inflight_peak"],"scope":"HTTP fetch until response headers, including failed and cancelled attempt lifetimes; GET body transfer excluded; maxima and peaks cumulative since boot; attempts can cross observation boundaries"})
}

fn disk_usage(root: &Path) -> (u64, u64, u64) {
    use std::os::unix::fs::MetadataExt as _;
    let mut bytes = 0;
    let mut allocated = 0;
    let mut files = 0;
    let mut paths = vec![root.to_path_buf()];
    while let Some(path) = paths.pop() {
        let Ok(metadata) = std::fs::symlink_metadata(&path) else {
            continue;
        };
        if metadata.is_dir() {
            if let Ok(entries) = std::fs::read_dir(&path) {
                paths.extend(entries.flatten().map(|e| e.path()));
            }
        } else if metadata.is_file() {
            bytes += metadata.len();
            allocated += metadata.blocks() * 512;
            files += 1;
        }
    }
    (bytes, allocated, files)
}

pub fn spawn_sampler(
    root: PathBuf,
    report: PathBuf,
    stop: Arc<AtomicBool>,
) -> tokio::task::JoinHandle<Value> {
    tokio::task::spawn_blocking(move || {
        use std::io::Write;
        let mut file = std::fs::File::create(report.join("resources.tsv")).unwrap();
        writeln!(
            file,
            "elapsed_s\trss_bytes\tcpu_percent\tfd_count\tdisk_apparent_bytes\tdisk_allocated_bytes\tfiles"
        )
        .unwrap();
        let start = Instant::now();
        let mut samples = 0;
        let mut peak_rss = 0;
        let mut peak_fd = 0;
        let mut peak_disk = 0;
        let mut peak_allocated = 0;
        let mut peak_cpu = 0.0f64;
        while !stop.load(Ordering::Relaxed) {
            let out = std::process::Command::new("ps")
                .args(["-o", "rss=,%cpu=", "-p", &std::process::id().to_string()])
                .output()
                .unwrap();
            let fields: Vec<String> = String::from_utf8_lossy(&out.stdout)
                .split_whitespace()
                .map(str::to_owned)
                .collect();
            let rss = fields
                .first()
                .and_then(|v| v.parse::<u64>().ok())
                .unwrap_or(0)
                * 1024;
            let cpu = fields
                .get(1)
                .and_then(|v| v.parse::<f64>().ok())
                .unwrap_or(0.0);
            let fd = std::fs::read_dir("/dev/fd").map(|r| r.count()).unwrap_or(0);
            let (disk, allocated, files) = disk_usage(&root);
            peak_rss = peak_rss.max(rss);
            peak_fd = peak_fd.max(fd);
            peak_disk = peak_disk.max(disk);
            peak_allocated = peak_allocated.max(allocated);
            peak_cpu = peak_cpu.max(cpu);
            samples += 1;
            writeln!(
                file,
                "{:.3}\t{rss}\t{cpu}\t{fd}\t{disk}\t{allocated}\t{files}",
                start.elapsed().as_secs_f64()
            )
            .unwrap();
            std::thread::sleep(Duration::from_millis(500));
        }
        json!({"samples":samples,"peak_rss_bytes":peak_rss,"peak_fd_count":peak_fd,"peak_disk_bytes":peak_disk,"peak_disk_allocated_bytes":peak_allocated,"peak_ps_cpu_percent":peak_cpu,"sampling_interval_ms":500,"rss_scope":"server and load generator in one process","cpu_scope":"ps percent CPU, process lifetime average"})
    })
}

pub fn aggregate(runs: &[Value]) -> Value {
    let mut result = serde_json::Map::new();
    for (phase, name) in [(0, "sustained"), (1, "burst")] {
        let mut rates: Vec<f64> = runs
            .iter()
            .map(|r| {
                r["phases"][phase]["operations"]["ingest"]["successful"]
                    .as_u64()
                    .unwrap_or(0) as f64
                    / r["phases"][phase]["elapsed_seconds"].as_f64().unwrap()
            })
            .collect();
        rates.sort_by(f64::total_cmp);
        result.insert(name.to_owned(),json!({"runs":rates.len(),"successful_requests_per_second":{"min":rates.first(),"median":rates.get(rates.len()/2),"max":rates.last()},"verdict":"inconclusive until limiter is independently profiled; workload report only"}));
    }
    Value::Object(result)
}
