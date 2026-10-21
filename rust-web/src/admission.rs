use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use tokio::sync::{OwnedSemaphorePermit, Semaphore};

use crate::{
    domain::OrgId,
    error::ApiError,
    settings::{QueryAdmissionSettings, Settings},
};

pub struct Admission {
    body_bytes: Arc<Semaphore>,
    errors: Arc<Semaphore>,
    passwords: Arc<Semaphore>,
    pub queries: QueryAdmission,
    pub ingest_rate: IngestRate,
}

impl Admission {
    pub fn new(settings: &Settings) -> Self {
        Self {
            body_bytes: Arc::new(Semaphore::new(settings.ingest.body_budget_bytes)),
            errors: Arc::new(Semaphore::new(settings.ingest.error_lane)),
            passwords: Arc::new(Semaphore::new(settings.auth.password_concurrency)),
            queries: QueryAdmission::new(
                settings.logs.search.max_active_queries,
                settings.query_admission.clone(),
            ),
            ingest_rate: IngestRate::new(
                settings.ingest.rate_per_second,
                settings.ingest.rate_burst,
                settings.ingest.rate_max_orgs,
            ),
        }
    }

    /// Reserves memory for one request body before any byte is read.
    pub fn body(&self, bytes: usize) -> Option<OwnedSemaphorePermit> {
        let bytes = u32::try_from(bytes.max(1)).ok()?;
        self.body_bytes.clone().try_acquire_many_owned(bytes).ok()
    }

    pub fn error_lane(&self) -> Option<OwnedSemaphorePermit> {
        self.errors.clone().try_acquire_owned().ok()
    }

    pub fn password_lane(&self) -> Option<OwnedSemaphorePermit> {
        self.passwords.clone().try_acquire_owned().ok()
    }
}

/// Token bucket per organization for ingestion requests. Every key of an
/// organization draws from the same bucket. The map holds at most `max_orgs`
/// buckets; a bucket that has refilled to `burst` carries no state and is
/// dropped when room is needed.
pub struct IngestRate {
    per_second: f64,
    burst: f64,
    max_orgs: usize,
    buckets: Mutex<HashMap<OrgId, Bucket>>,
}

#[derive(Clone, Copy)]
struct Bucket {
    tokens: f64,
    at: Instant,
}

impl Bucket {
    fn refilled(self, now: Instant, per_second: f64, burst: f64) -> f64 {
        (self.tokens + now.duration_since(self.at).as_secs_f64() * per_second).min(burst)
    }
}

impl IngestRate {
    pub fn new(per_second: u32, burst: u32, max_orgs: usize) -> Self {
        Self {
            per_second: f64::from(per_second),
            burst: f64::from(burst),
            max_orgs,
            buckets: Mutex::default(),
        }
    }

    /// Takes one request token for `org`. An empty bucket is `RateLimited`
    /// until one token has refilled; a full map of active organizations is
    /// `Unavailable`.
    pub fn admit(&self, org: &OrgId) -> Result<(), ApiError> {
        let now = Instant::now();
        let mut buckets = self.buckets.lock().expect("ingest rate lock");
        let tokens = match buckets.get(org) {
            Some(bucket) => bucket.refilled(now, self.per_second, self.burst),
            None => {
                if buckets.len() >= self.max_orgs {
                    let (per_second, burst) = (self.per_second, self.burst);
                    buckets.retain(|_, bucket| bucket.refilled(now, per_second, burst) < burst);
                }
                if buckets.len() >= self.max_orgs {
                    return Err(ApiError::Unavailable("ingest_overloaded"));
                }
                self.burst
            }
        };
        if tokens < 1.0 {
            buckets.insert(org.clone(), Bucket { tokens, at: now });
            let wait = Duration::from_secs_f64((1.0 - tokens) / self.per_second);
            return Err(ApiError::RateLimited {
                retry: Duration::from_secs(wait.as_secs() + u64::from(wait.subsec_nanos() > 0)),
                categories: "",
            });
        }
        buckets.insert(
            org.clone(),
            Bucket {
                tokens: tokens - 1.0,
                at: now,
            },
        );
        Ok(())
    }

    pub fn cached_orgs(&self) -> usize {
        self.buckets.lock().expect("ingest rate lock").len()
    }
}

/// Map size from which every lookup drops idle organizations. It is a trigger,
/// not a cap: organizations with live windows or permits stay in the map.
const SWEEP_AT: usize = 1_024;
const ORG_BUSY_RETRY: Duration = Duration::from_secs(1);

#[derive(Clone, Copy)]
struct Window {
    start: Instant,
    used: u32,
}

impl Window {
    fn new(now: Instant) -> Self {
        Self {
            start: now,
            used: 0,
        }
    }

    /// Restarts an elapsed window, then returns the wait until it ends when it
    /// is full.
    fn check(&mut self, now: Instant, length: Duration, limit: u32) -> Result<(), Duration> {
        let elapsed = now.duration_since(self.start);
        if elapsed >= length {
            *self = Self::new(now);
            return Ok(());
        }
        if self.used >= limit {
            return Err(length - elapsed);
        }
        Ok(())
    }

    fn elapsed(&self, now: Instant, length: Duration) -> bool {
        now.duration_since(self.start) >= length
    }
}

struct OrgQueries {
    active: usize,
    expensive: Window,
    mcp: Window,
}

#[derive(Default)]
struct QueryState {
    active: usize,
    orgs: HashMap<OrgId, OrgQueries>,
}

impl QueryState {
    fn org(&mut self, org: &OrgId, now: Instant, window: Duration) -> &mut OrgQueries {
        if self.orgs.len() >= SWEEP_AT {
            self.orgs.retain(|_, queries| {
                queries.active > 0
                    || !queries.expensive.elapsed(now, window)
                    || !queries.mcp.elapsed(now, window)
            });
        }
        self.orgs.entry(org.clone()).or_insert_with(|| OrgQueries {
            active: 0,
            expensive: Window::new(now),
            mcp: Window::new(now),
        })
    }
}

/// Admission for expensive reads, shared by the HTTP API, the dashboard and
/// MCP. Budgets are per organization, so extra credentials add no capacity.
pub struct QueryAdmission {
    global_active: usize,
    limits: QueryAdmissionSettings,
    state: Arc<Mutex<QueryState>>,
}

/// One admitted read. Dropping it, including on cancellation, frees the slot.
#[must_use]
pub struct QueryPermit {
    state: Arc<Mutex<QueryState>>,
    org: Option<OrgId>,
}

impl Drop for QueryPermit {
    fn drop(&mut self) {
        let mut state = self.state.lock().expect("query admission lock");
        state.active -= 1;
        if let Some(queries) = self.org.as_ref().and_then(|org| state.orgs.get_mut(org)) {
            queries.active -= 1;
        }
    }
}

fn retry_after(wait: Duration) -> ApiError {
    let secs = wait.as_secs() + u64::from(wait.subsec_nanos() > 0);
    ApiError::RateLimited {
        retry: Duration::from_secs(secs.max(1)),
        categories: "query",
    }
}

impl QueryAdmission {
    pub fn new(global_active: usize, limits: QueryAdmissionSettings) -> Self {
        Self {
            global_active,
            limits,
            state: Arc::default(),
        }
    }

    fn window(&self) -> Duration {
        Duration::from_millis(self.limits.window_ms)
    }

    /// Admits one investigation or historical log read for `org`. A full
    /// organization budget is `RateLimited`; a full server is `Unavailable`.
    pub fn expensive(&self, org: &OrgId) -> Result<QueryPermit, ApiError> {
        let now = Instant::now();
        let window = self.window();
        let mut state = self.state.lock().expect("query admission lock");
        let server_full = state.active >= self.global_active;
        let queries = state.org(org, now, window);
        queries
            .expensive
            .check(now, window, self.limits.org_queries_per_window)
            .map_err(retry_after)?;
        if queries.active >= self.limits.org_active_queries {
            return Err(retry_after(ORG_BUSY_RETRY));
        }
        if server_full {
            return Err(ApiError::Unavailable("log_query_overloaded"));
        }
        queries.expensive.used += 1;
        queries.active += 1;
        state.active += 1;
        Ok(QueryPermit {
            state: self.state.clone(),
            org: Some(org.clone()),
        })
    }

    /// Admits one bounded read of entries a live tail has just received. It
    /// takes a server slot only, so viewers of one organization never refuse
    /// each other.
    pub fn live(&self) -> Result<QueryPermit, ApiError> {
        let mut state = self.state.lock().expect("query admission lock");
        if state.active >= self.global_active {
            return Err(ApiError::Unavailable("log_query_overloaded"));
        }
        state.active += 1;
        Ok(QueryPermit {
            state: self.state.clone(),
            org: None,
        })
    }

    pub fn mcp_call(&self, org: &OrgId) -> Result<(), ApiError> {
        let now = Instant::now();
        let window = self.window();
        let mut state = self.state.lock().expect("query admission lock");
        let queries = state.org(org, now, window);
        queries
            .mcp
            .check(now, window, self.limits.mcp_calls_per_window)
            .map_err(retry_after)?;
        queries.mcp.used += 1;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn admission(global: usize) -> QueryAdmission {
        QueryAdmission::new(
            global,
            QueryAdmissionSettings {
                org_active_queries: 2,
                org_queries_per_window: 30,
                mcp_calls_per_window: 120,
                window_ms: 60_000,
            },
        )
    }

    #[test]
    fn global_saturation_is_unavailable_and_org_saturation_is_rate_limited() {
        let queries = admission(3);
        let a: OrgId = "o00000000000000000000000000000001".parse().unwrap();
        let b: OrgId = "o00000000000000000000000000000002".parse().unwrap();
        let c: OrgId = "o00000000000000000000000000000003".parse().unwrap();
        let held = [
            queries.expensive(&a).unwrap(),
            queries.expensive(&a).unwrap(),
        ];
        assert!(matches!(
            queries.expensive(&a),
            Err(ApiError::RateLimited { retry, .. }) if retry == Duration::from_secs(1)
        ));
        let third = queries.expensive(&b).unwrap();
        assert!(matches!(
            queries.expensive(&c),
            Err(ApiError::Unavailable("log_query_overloaded"))
        ));
        assert!(matches!(
            queries.live(),
            Err(ApiError::Unavailable("log_query_overloaded"))
        ));
        drop(third);
        let live = queries.live().unwrap();
        drop((held, live));
        assert!(queries.expensive(&c).is_ok());
    }
}
