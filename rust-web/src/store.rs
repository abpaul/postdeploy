use std::{
    collections::{HashMap, HashSet},
    future::Future,
    sync::{
        atomic::{AtomicU32, AtomicU64, Ordering},
        Arc, Mutex,
    },
    time::Duration,
};

use bytes::{Bytes, BytesMut};
use futures::TryStreamExt;
use opendal::{ErrorKind, Operator};

use crate::{credentials::R2Credentials, domain::OrgId};

/// Object storage failure. Display and Debug carry only the error kind:
/// backend errors can embed remote response bodies or headers, which must not
/// reach operational logs.
pub enum StoreError {
    Backend(ErrorKind),
    Timeout,
    Injected,
    TooLarge(usize),
    OrganizationDeleting,
    WriteBarrierCapacity,
}

impl StoreError {
    fn backend(error: &opendal::Error) -> Self {
        Self::Backend(error.kind())
    }
}

impl std::fmt::Display for StoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Backend(kind) => write!(f, "object store request failed ({kind})"),
            Self::OrganizationDeleting => f.write_str("organization is being deleted"),
            Self::WriteBarrierCapacity => {
                f.write_str("organization write barrier capacity reached")
            }
            Self::Timeout => f.write_str("object store operation timed out"),
            Self::Injected => f.write_str("object store fault injected"),
            Self::TooLarge(max) => write!(f, "object exceeds {max} bytes"),
        }
    }
}

impl std::fmt::Debug for StoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        std::fmt::Display::fmt(self, f)
    }
}

impl std::error::Error for StoreError {}

/// Durable object storage. Production uses Cloudflare R2 through the S3 API.
/// Tests construct the in-memory variant explicitly; no runtime path selects it.
#[derive(Clone)]
pub struct ObjectStore {
    op: Operator,
    prefix: Arc<str>,
    timeout: Duration,
    faults: Option<Arc<Faults>>,
    counters: Arc<StoreCounters>,
    pending: Arc<Mutex<PendingState>>,
}

#[derive(Default)]
struct PendingState {
    keys: HashMap<String, usize>,
    blocked: HashSet<OrgId>,
}

const MAX_WRITE_BARRIERS: usize = 16_384;

fn key_org(key: &str) -> Option<OrgId> {
    let tail = [
        "logs/v1/",
        "errors/v1/",
        "releases/v1/",
        "reports/v1/",
        "backups/org/",
    ]
    .into_iter()
    .find_map(|prefix| key.strip_prefix(prefix))?;
    tail.split_once('/')?.0.parse().ok()
}

pub struct OrgWriteBarrier {
    store: ObjectStore,
    org: OrgId,
    reserved: bool,
}

impl OrgWriteBarrier {
    pub fn commit(mut self) {
        self.reserved = false;
    }
}

impl Drop for OrgWriteBarrier {
    fn drop(&mut self) {
        if self.reserved {
            self.store.release_org_write_barrier(&self.org);
        }
    }
}

pub struct PendingObject {
    keys: Arc<Mutex<PendingState>>,
    key: String,
}

impl Drop for PendingObject {
    fn drop(&mut self) {
        let mut keys = self.keys.lock().expect("pending object lock");
        if let Some(count) = keys.keys.get_mut(&self.key) {
            *count -= 1;
            if *count == 0 {
                keys.keys.remove(&self.key);
            }
        }
    }
}

#[derive(Debug, Default)]
pub struct StoreCounters {
    pub http_requests: AtomicU64,
    pub http_head: AtomicU64,
    pub http_get: AtomicU64,
    pub http_put: AtomicU64,
    pub http_delete: AtomicU64,
    pub http_duration_us: AtomicU64,
    pub http_max_duration_us: AtomicU64,
    pub http_head_duration_us: AtomicU64,
    pub http_head_max_duration_us: AtomicU64,
    pub http_get_duration_us: AtomicU64,
    pub http_get_max_duration_us: AtomicU64,
    pub http_put_duration_us: AtomicU64,
    pub http_put_max_duration_us: AtomicU64,
    pub http_delete_duration_us: AtomicU64,
    pub http_delete_max_duration_us: AtomicU64,
    pub http_inflight: AtomicU64,
    pub http_inflight_peak: AtomicU64,
    pub http_put_inflight: AtomicU64,
    pub http_put_inflight_peak: AtomicU64,
    pub http_completed: AtomicU64,
    pub http_failed: AtomicU64,
    pub http_cancelled: AtomicU64,
    pub puts: AtomicU64,
    pub put_bytes: AtomicU64,
    pub gets: AtomicU64,
    pub get_bytes: AtomicU64,
    pub lists: AtomicU64,
    pub deletes: AtomicU64,
    pub failures: AtomicU64,
}

struct CountedTransport {
    inner: opendal::HttpTransporter,
    counters: Arc<StoreCounters>,
}

impl opendal::HttpTransport for CountedTransport {
    async fn fetch(
        &self,
        request: axum::http::Request<opendal::Buffer>,
    ) -> opendal::Result<axum::http::Response<opendal::HttpBody>> {
        self.counters.http_requests.fetch_add(1, Ordering::Relaxed);
        let counters = &*self.counters;
        let method = match *request.method() {
            axum::http::Method::HEAD => Some((
                &counters.http_head,
                &counters.http_head_duration_us,
                &counters.http_head_max_duration_us,
            )),
            axum::http::Method::GET => Some((
                &counters.http_get,
                &counters.http_get_duration_us,
                &counters.http_get_max_duration_us,
            )),
            axum::http::Method::PUT => Some((
                &counters.http_put,
                &counters.http_put_duration_us,
                &counters.http_put_max_duration_us,
            )),
            axum::http::Method::DELETE => Some((
                &counters.http_delete,
                &counters.http_delete_duration_us,
                &counters.http_delete_max_duration_us,
            )),
            _ => None,
        };
        if let Some((count, _, _)) = method {
            count.fetch_add(1, Ordering::Relaxed);
        }
        let active = counters.http_inflight.fetch_add(1, Ordering::Relaxed) + 1;
        counters
            .http_inflight_peak
            .fetch_max(active, Ordering::Relaxed);
        let is_put = request.method() == axum::http::Method::PUT;
        if is_put {
            let active = counters.http_put_inflight.fetch_add(1, Ordering::Relaxed) + 1;
            counters
                .http_put_inflight_peak
                .fetch_max(active, Ordering::Relaxed);
        }
        struct Attempt<'a> {
            counters: &'a StoreCounters,
            method: Option<(&'a AtomicU64, &'a AtomicU64, &'a AtomicU64)>,
            started: std::time::Instant,
            is_put: bool,
            completed: bool,
        }
        impl Drop for Attempt<'_> {
            fn drop(&mut self) {
                let elapsed = self.started.elapsed().as_micros() as u64;
                self.counters
                    .http_duration_us
                    .fetch_add(elapsed, Ordering::Relaxed);
                self.counters
                    .http_max_duration_us
                    .fetch_max(elapsed, Ordering::Relaxed);
                if let Some((_, total, max)) = self.method {
                    total.fetch_add(elapsed, Ordering::Relaxed);
                    max.fetch_max(elapsed, Ordering::Relaxed);
                }
                if self.is_put {
                    self.counters
                        .http_put_inflight
                        .fetch_sub(1, Ordering::Relaxed);
                }
                self.counters.http_inflight.fetch_sub(1, Ordering::Relaxed);
                if !self.completed {
                    self.counters.http_cancelled.fetch_add(1, Ordering::Relaxed);
                }
            }
        }
        let mut attempt = Attempt {
            counters,
            method,
            started: std::time::Instant::now(),
            is_put,
            completed: false,
        };
        let result = self.inner.fetch(request).await;
        attempt.completed = true;
        counters.http_completed.fetch_add(1, Ordering::Relaxed);
        let failed = match &result {
            Ok(response) => !response.status().is_success(),
            Err(_) => true,
        };
        if failed {
            counters.http_failed.fetch_add(1, Ordering::Relaxed);
        }
        result
    }
}

/// Test-only fault plan. Each counter fails that many upcoming operations.
#[derive(Debug, Default)]
pub struct Faults {
    pub fail_puts: AtomicU32,
    pub fail_put_after_write: AtomicU32,
    pub delay_put_ms: AtomicU64,
    pub delayed_puts: AtomicU64,
    pub fail_error_after_commit: AtomicU32,
    pub pause_after_error_settle: std::sync::atomic::AtomicBool,
    pub error_settled: tokio::sync::Notify,
    pub error_resume: tokio::sync::Notify,
    pub pause_after_log_put: std::sync::atomic::AtomicBool,
    pub log_paused: tokio::sync::Notify,
    pub log_resume: tokio::sync::Notify,
    pub fail_deletes: AtomicU32,
    pub delay_get_after: AtomicU64,
    pub delay_get_ms: AtomicU64,
    /// While true, every backup seal blocks after it starts.
    backup_seal_hold: Mutex<bool>,
    backup_seal_released: std::sync::Condvar,
    pub backup_seal_held: tokio::sync::Notify,
    pub pause_after_backup_member: std::sync::atomic::AtomicBool,
    pub backup_paused: tokio::sync::Notify,
    pub backup_resume: tokio::sync::Notify,
}

impl Faults {
    pub fn hold_backup_seals(&self, held: bool) {
        *self.backup_seal_hold.lock().expect("backup seal hold") = held;
        self.backup_seal_released.notify_all();
    }

    pub(crate) fn wait_for_backup_seal(&self) {
        let mut held = self.backup_seal_hold.lock().expect("backup seal hold");
        if *held {
            self.backup_seal_held.notify_one();
        }
        while *held {
            held = self
                .backup_seal_released
                .wait(held)
                .expect("backup seal hold");
        }
    }

    pub(crate) fn take(counter: &AtomicU32) -> bool {
        let mut current = counter.load(Ordering::SeqCst);
        while current > 0 {
            match counter.compare_exchange(current, current - 1, Ordering::SeqCst, Ordering::SeqCst)
            {
                Ok(_) => return true,
                Err(actual) => current = actual,
            }
        }
        false
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Created {
    New,
    Exists,
}

/// One bounded listing pass. `next` resumes after the last returned key.
#[derive(Debug, Default)]
pub struct ListPage {
    pub keys: Vec<String>,
    pub next: Option<String>,
}

impl ObjectStore {
    pub fn r2(
        credentials: &R2Credentials,
        prefix: &str,
        timeout: Duration,
    ) -> Result<Self, StoreError> {
        opendal::install_default();
        let builder = opendal::services::S3::default()
            .endpoint(&credentials.endpoint)
            .region("auto")
            .bucket(&credentials.bucket)
            .access_key_id(credentials.access_key_id.expose_secret())
            .secret_access_key(credentials.secret_access_key.expose_secret())
            .disable_config_load()
            .disable_ec2_metadata();
        let op = Operator::new(builder).map_err(|e| StoreError::backend(&e))?;
        Ok(Self::with_operator(op, prefix, timeout, None))
    }

    pub fn memory(
        prefix: &str,
        timeout: Duration,
        faults: Arc<Faults>,
    ) -> Result<Self, StoreError> {
        let op = Operator::new(opendal::services::Memory::default())
            .map_err(|e| StoreError::backend(&e))?;
        Ok(Self::with_operator(op, prefix, timeout, Some(faults)))
    }

    fn with_operator(
        op: Operator,
        prefix: &str,
        timeout: Duration,
        faults: Option<Arc<Faults>>,
    ) -> Self {
        let counters = Arc::new(StoreCounters::default());
        let transport = CountedTransport {
            inner: opendal::HttpTransporter::default(),
            counters: counters.clone(),
        };
        let op = op.with_context(
            opendal::OperationContext::new()
                .with_http_transport(opendal::HttpTransporter::new(transport)),
        );
        Self {
            op,
            prefix: prefix.into(),
            timeout,
            faults,
            counters,
            pending: Arc::default(),
        }
    }

    /// The same store with another per-operation deadline. Counters, faults and
    /// write barriers stay shared.
    pub fn with_timeout(&self, timeout: Duration) -> Self {
        Self {
            timeout,
            ..self.clone()
        }
    }

    pub fn faults(&self) -> Option<&Arc<Faults>> {
        self.faults.as_ref()
    }

    pub fn counters(&self) -> &StoreCounters {
        &self.counters
    }

    pub fn pending(&self, key: &str) -> PendingObject {
        *self
            .pending
            .lock()
            .expect("pending object lock")
            .keys
            .entry(key.to_owned())
            .or_default() += 1;
        PendingObject {
            keys: self.pending.clone(),
            key: key.to_owned(),
        }
    }

    fn begin_put(&self, key: &str) -> Result<PendingObject, StoreError> {
        let mut state = self.pending.lock().expect("pending object lock");
        if key_org(key).is_some_and(|org| state.blocked.contains(&org)) {
            return Err(StoreError::OrganizationDeleting);
        }
        *state.keys.entry(key.to_owned()).or_default() += 1;
        Ok(PendingObject {
            keys: self.pending.clone(),
            key: key.to_owned(),
        })
    }

    pub fn block_org_writes(&self, org: &OrgId) -> Result<(), StoreError> {
        self.reserve_org_write_barrier(org)?.commit();
        Ok(())
    }

    pub fn reserve_org_write_barrier(&self, org: &OrgId) -> Result<OrgWriteBarrier, StoreError> {
        let mut state = self.pending.lock().expect("pending object lock");
        if !state.blocked.contains(org) && state.blocked.len() >= MAX_WRITE_BARRIERS {
            return Err(StoreError::WriteBarrierCapacity);
        }
        let reserved = state.blocked.insert(org.clone());
        Ok(OrgWriteBarrier {
            store: self.clone(),
            org: org.clone(),
            reserved,
        })
    }

    pub fn release_org_write_barrier(&self, org: &OrgId) {
        self.pending
            .lock()
            .expect("pending object lock")
            .blocked
            .remove(org);
    }

    pub fn org_writes_pending(&self, org: &OrgId) -> bool {
        self.pending
            .lock()
            .expect("pending object lock")
            .keys
            .keys()
            .any(|key| key_org(key).as_ref() == Some(org))
    }

    pub fn is_pending(&self, key: &str) -> bool {
        self.pending
            .lock()
            .expect("pending object lock")
            .keys
            .contains_key(key)
    }

    fn path(&self, key: &str) -> String {
        format!("{}{key}", self.prefix)
    }

    async fn bounded<T>(
        &self,
        work: impl Future<Output = Result<T, StoreError>>,
    ) -> Result<T, StoreError> {
        let result = tokio::time::timeout(self.timeout, work)
            .await
            .unwrap_or(Err(StoreError::Timeout));
        if result.is_err() {
            self.counters.failures.fetch_add(1, Ordering::Relaxed);
        }
        result
    }

    pub async fn put(&self, key: &str, body: Bytes) -> Result<(), StoreError> {
        let _pending = self.begin_put(key)?;
        if let Some(faults) = &self.faults {
            if Faults::take(&faults.fail_puts) {
                self.counters.failures.fetch_add(1, Ordering::Relaxed);
                return Err(StoreError::Injected);
            }
        }
        if let Some(faults) = &self.faults {
            faults.delayed_puts.fetch_add(1, Ordering::Relaxed);
            tokio::time::sleep(Duration::from_millis(
                faults.delay_put_ms.load(Ordering::Relaxed),
            ))
            .await;
        }
        let len = body.len() as u64;
        self.counters.puts.fetch_add(1, Ordering::Relaxed);
        let path = self.path(key);
        self.bounded(async {
            self.op
                .write(&path, body)
                .await
                .map_err(|e| StoreError::backend(&e))
        })
        .await?;
        self.counters.put_bytes.fetch_add(len, Ordering::Relaxed);
        if self
            .faults
            .as_ref()
            .is_some_and(|faults| Faults::take(&faults.fail_put_after_write))
        {
            self.counters.failures.fetch_add(1, Ordering::Relaxed);
            return Err(StoreError::Injected);
        }
        Ok(())
    }

    /// Creates `key` only when no object exists there. An existing object is
    /// never replaced; callers verify its content instead.
    pub async fn put_if_absent(&self, key: &str, body: Bytes) -> Result<Created, StoreError> {
        let _pending = self.begin_put(key)?;
        if let Some(faults) = &self.faults {
            if Faults::take(&faults.fail_puts) {
                self.counters.failures.fetch_add(1, Ordering::Relaxed);
                return Err(StoreError::Injected);
            }
            faults.delayed_puts.fetch_add(1, Ordering::Relaxed);
            tokio::time::sleep(Duration::from_millis(
                faults.delay_put_ms.load(Ordering::Relaxed),
            ))
            .await;
        }
        let len = body.len() as u64;
        self.counters.puts.fetch_add(1, Ordering::Relaxed);
        let path = self.path(key);
        let created = self
            .bounded(async {
                match self.op.write_with(&path, body).if_not_exists(true).await {
                    Ok(_) => Ok(Created::New),
                    Err(error) if error.kind() == ErrorKind::ConditionNotMatch => {
                        Ok(Created::Exists)
                    }
                    Err(error) => Err(StoreError::backend(&error)),
                }
            })
            .await?;
        if created == Created::New {
            self.counters.put_bytes.fetch_add(len, Ordering::Relaxed);
            if self
                .faults
                .as_ref()
                .is_some_and(|faults| Faults::take(&faults.fail_put_after_write))
            {
                self.counters.failures.fetch_add(1, Ordering::Relaxed);
                return Err(StoreError::Injected);
            }
        }
        Ok(created)
    }

    /// Refuses objects larger than `max_bytes` from their stated size before any
    /// download, then reads exactly that range and still stops at the limit.
    /// Returns `None` when absent.
    pub async fn get(&self, key: &str, max_bytes: usize) -> Result<Option<Bytes>, StoreError> {
        let ordinal = self.counters.gets.fetch_add(1, Ordering::Relaxed) + 1;
        if let Some(faults) = &self.faults {
            let delay = faults.delay_get_ms.load(Ordering::Relaxed);
            if delay > 0 && ordinal >= faults.delay_get_after.load(Ordering::Relaxed) {
                tokio::time::sleep(Duration::from_millis(delay)).await;
            }
        }
        let path = self.path(key);
        let read = async {
            let not_found = |error: &opendal::Error| error.kind() == ErrorKind::NotFound;
            let size = match self.op.stat(&path).await {
                Ok(meta) => meta.content_length(),
                Err(error) if not_found(&error) => return Ok(None),
                Err(error) => return Err(StoreError::backend(&error)),
            };
            if size > max_bytes as u64 {
                return Err(StoreError::TooLarge(max_bytes));
            }
            let reader = match self.op.reader(&path).await {
                Ok(reader) => reader,
                Err(error) if not_found(&error) => return Ok(None),
                Err(error) => return Err(StoreError::backend(&error)),
            };
            let mut stream = match reader.into_bytes_stream(0..size).await {
                Ok(stream) => stream,
                Err(error) if not_found(&error) => return Ok(None),
                Err(error) => return Err(StoreError::backend(&error)),
            };
            let mut buffer = BytesMut::new();
            loop {
                match stream.try_next().await {
                    Ok(Some(chunk)) => {
                        if buffer.len() + chunk.len() > max_bytes {
                            return Err(StoreError::TooLarge(max_bytes));
                        }
                        buffer.extend_from_slice(&chunk);
                    }
                    Ok(None) => return Ok(Some(buffer.freeze())),
                    Err(error)
                        if error.kind() == std::io::ErrorKind::NotFound && buffer.is_empty() =>
                    {
                        return Ok(None)
                    }
                    Err(_) => return Err(StoreError::Backend(ErrorKind::Unexpected)),
                }
            }
        };
        let body = self.bounded(read).await?;
        if let Some(body) = &body {
            self.counters
                .get_bytes
                .fetch_add(body.len() as u64, Ordering::Relaxed);
        }
        Ok(body)
    }

    pub async fn delete(&self, key: &str) -> Result<(), StoreError> {
        if self
            .faults
            .as_ref()
            .is_some_and(|faults| Faults::take(&faults.fail_deletes))
        {
            self.counters.failures.fetch_add(1, Ordering::Relaxed);
            return Err(StoreError::Injected);
        }
        self.counters.deletes.fetch_add(1, Ordering::Relaxed);
        let path = self.path(key);
        self.bounded(async {
            match self.op.delete(&path).await {
                Ok(()) => Ok(()),
                Err(error) if error.kind() == ErrorKind::NotFound => Ok(()),
                Err(error) => Err(StoreError::backend(&error)),
            }
        })
        .await
    }

    /// Lists at most `max` keys under `prefix` in key order, starting after
    /// `after`. Callers pass `ListPage::next` back to continue a scan.
    pub async fn list_page(
        &self,
        prefix: &str,
        after: Option<&str>,
        max: usize,
    ) -> Result<ListPage, StoreError> {
        self.counters.lists.fetch_add(1, Ordering::Relaxed);
        let root = self.path(prefix);
        let after_path = after.map(|key| self.path(key));
        let server_side = self.op.info().capability().list_with_start_after;
        self.bounded(async {
            let mut request = self.op.lister_with(&root).recursive(true);
            if let (true, Some(after)) = (server_side, &after_path) {
                request = request.start_after(after);
            }
            let mut lister = request.await.map_err(|e| StoreError::backend(&e))?;
            let mut page = ListPage::default();
            while let Some(entry) = lister
                .try_next()
                .await
                .map_err(|e| StoreError::backend(&e))?
            {
                if entry.metadata().is_dir() {
                    continue;
                }
                if after_path
                    .as_deref()
                    .is_some_and(|after| entry.path() <= after)
                {
                    continue;
                }
                let Some(key) = entry.path().strip_prefix(&*self.prefix) else {
                    continue;
                };
                if page.keys.len() == max {
                    page.next = page.keys.last().cloned();
                    break;
                }
                page.keys.push(key.to_owned());
            }
            Ok(page)
        })
        .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store() -> ObjectStore {
        ObjectStore::memory("t/", Duration::from_secs(5), Arc::default()).unwrap()
    }

    #[tokio::test]
    async fn deletion_barrier_blocks_every_org_payload_family_and_tracks_pending_work() {
        let store = store();
        let org = OrgId::generate();
        let other = OrgId::generate();
        let key = format!("logs/v1/{org}/object");
        let pending = store.pending(&key);
        assert!(store.org_writes_pending(&org));
        assert!(!store.org_writes_pending(&other));
        store.block_org_writes(&org).unwrap();
        for family in [
            "logs/v1",
            "errors/v1",
            "releases/v1",
            "reports/v1",
            "backups/org",
        ] {
            let key = format!("{family}/{org}/late");
            assert!(matches!(
                store.put(&key, Bytes::from_static(b"late")).await,
                Err(StoreError::OrganizationDeleting)
            ));
            assert!(store.get(&key, 16).await.unwrap().is_none());
        }
        store
            .put(&format!("logs/v1/{other}/ok"), Bytes::from_static(b"ok"))
            .await
            .unwrap();
        assert_eq!(
            store
                .get(&format!("logs/v1/{other}/ok"), 16)
                .await
                .unwrap()
                .unwrap(),
            Bytes::from_static(b"ok")
        );
        drop(pending);
        assert!(!store.org_writes_pending(&org));
        assert_eq!(store.counters().puts.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn deletion_barrier_capacity_is_bounded_and_existing_barriers_are_idempotent() {
        let store = store();
        let first = OrgId::generate();
        store.block_org_writes(&first).unwrap();
        for _ in 1..MAX_WRITE_BARRIERS {
            store.block_org_writes(&OrgId::generate()).unwrap();
        }
        store.block_org_writes(&first).unwrap();
        assert!(matches!(
            store.block_org_writes(&OrgId::generate()),
            Err(StoreError::WriteBarrierCapacity)
        ));
    }

    #[tokio::test]
    async fn conditional_create_keeps_the_first_body_and_reports_the_existing_key() {
        let store = store();
        assert_eq!(
            store
                .put_if_absent("logs/v1/a/v2/k", Bytes::from_static(b"first"))
                .await
                .unwrap(),
            Created::New
        );
        assert_eq!(
            store
                .put_if_absent("logs/v1/a/v2/k", Bytes::from_static(b"second"))
                .await
                .unwrap(),
            Created::Exists
        );
        assert_eq!(
            store.get("logs/v1/a/v2/k", 16).await.unwrap().unwrap(),
            Bytes::from_static(b"first")
        );
    }

    #[tokio::test]
    async fn get_rejects_objects_over_the_limit_and_reads_exact_fits() {
        let store = store();
        store
            .put("big", Bytes::from(vec![7u8; 4096]))
            .await
            .unwrap();
        assert!(matches!(
            store.get("big", 4095).await,
            Err(StoreError::TooLarge(4095))
        ));
        assert_eq!(store.get("big", 4096).await.unwrap().unwrap().len(), 4096);
        assert!(store.get("missing", 10).await.unwrap().is_none());
    }

    #[tokio::test]
    async fn list_pages_continue_until_every_key_is_seen() {
        let store = store();
        for i in 0..7 {
            store
                .put(&format!("logs/a/{i}"), Bytes::from_static(b"x"))
                .await
                .unwrap();
        }
        store
            .put("logs/b/0", Bytes::from_static(b"x"))
            .await
            .unwrap();
        let mut seen = Vec::new();
        let mut after: Option<String> = None;
        loop {
            let page = store
                .list_page("logs/a/", after.as_deref(), 3)
                .await
                .unwrap();
            seen.extend(page.keys);
            match page.next {
                Some(next) => after = Some(next),
                None => break,
            }
        }
        assert_eq!(
            seen,
            (0..7).map(|i| format!("logs/a/{i}")).collect::<Vec<_>>()
        );
    }
}
