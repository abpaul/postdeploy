use std::{path::PathBuf, time::Duration};

use loco_rs::{app::AppContext, Error, Result};
use serde::Deserialize;

/// Typed `settings` block of the Loco configuration. Contains no secrets.
#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Settings {
    pub credentials_file: PathBuf,
    pub oauth: crate::agent_access::OAuthConfig,
    #[serde(default)]
    pub notifications: crate::notifications::NotificationSettings,
    pub tenants: tenant_sqlite_loco::Settings,
    pub storage: StorageSettings,
    #[serde(default)]
    pub min_sqlite_version: Option<String>,
    #[serde(default)]
    pub auth: AuthSettings,
    #[serde(default)]
    pub ingest: IngestSettings,
    #[serde(default)]
    pub logs: LogSettings,
    #[serde(default)]
    pub quotas: QuotaSettings,
    #[serde(default)]
    pub billing: BillingSettings,
    #[serde(default)]
    pub lifecycle: LifecycleSettings,
    #[serde(default)]
    pub disk: DiskSettings,
    #[serde(default)]
    pub releases: crate::releases::ReleaseSettings,
    #[serde(default)]
    pub error_retention: crate::error_retention::ErrorRetentionSettings,
    #[serde(default)]
    pub orphan_retention: crate::orphan_retention::OrphanRetentionSettings,
    #[serde(default)]
    pub organization_deletion: crate::organization_lifecycle::DeleteSettings,
    #[serde(default)]
    pub query_admission: QueryAdmissionSettings,
    #[serde(default)]
    pub backup: BackupSettings,
    #[serde(default)]
    pub host_redirects: Vec<crate::host_redirect::HostRedirect>,
}

impl Settings {
    pub fn from_context(ctx: &AppContext) -> Result<Self> {
        let value = ctx
            .config
            .settings
            .clone()
            .ok_or_else(|| Error::string("settings block is missing"))?;
        let settings: Self = serde_json::from_value(value)
            .map_err(|error| Error::string(&format!("invalid settings: {error}")))?;
        settings.validate()?;
        if ctx.environment == loco_rs::environment::Environment::Production {
            settings.validate_production()?;
        }
        Ok(settings)
    }

    /// Production serves real customers: Stripe calls go only to Stripe, and
    /// daily technical caps never refuse work the monthly plan allows.
    fn validate_production(&self) -> Result<()> {
        let public_url = &self.notifications.public_url;
        if !public_url.starts_with("https://") || public_url.ends_with('/') {
            return Err(Error::string(
                "production settings.notifications.public_url must be an https origin without a trailing slash",
            ));
        }
        if self.logs.batch_max_age_ms + self.logs.archive_tick_ms + self.logs.upload_deadline_ms
            > 300_000
        {
            return Err(Error::string(
                "production log archiving must fit five minutes: batch_max_age_ms + archive_tick_ms + upload_deadline_ms <= 300000",
            ));
        }
        if self.billing.api_base != crate::billing::stripe::DEFAULT_API_BASE {
            return Err(Error::string(
                "production refuses a custom settings.billing.api_base",
            ));
        }
        if self.quotas.daily_errors < crate::billing::MONTHLY_ERRORS
            || self.quotas.daily_log_bytes < crate::billing::MONTHLY_LOG_BYTES
            || self.quotas.daily_logs < crate::billing::MONTHLY_LOG_BYTES
        {
            return Err(Error::string(
                "production daily quotas must not be lower than the monthly plan limits",
            ));
        }
        Ok(())
    }

    fn validate(&self) -> Result<()> {
        self.oauth.validate().map_err(Error::string)?;
        for redirect in &self.host_redirects {
            redirect.validate()?;
        }
        if !self.backup.validate() {
            return Err(Error::string("backup limits are invalid"));
        }
        if !self.organization_deletion.validate() {
            return Err(Error::string("organization deletion limits are invalid"));
        }
        if !self.releases.validate()
            || !self.error_retention.validate()
            || !self.orphan_retention.validate()
        {
            return Err(Error::string(
                "release and error retention limits are invalid",
            ));
        }
        let prefix = &self.storage.prefix;
        let valid = !prefix.is_empty()
            && prefix.ends_with('/')
            && !prefix.starts_with('/')
            && !prefix.contains("//")
            && prefix
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b"/-_.".contains(&b));
        if !valid {
            return Err(Error::string(
                "settings.storage.prefix must be lowercase path segments ending in '/'",
            ));
        }
        let base = url::Url::parse(&self.billing.api_base)
            .map_err(|_| Error::string("settings.billing.api_base must be a URL"))?;
        if !matches!(base.scheme(), "https" | "http")
            || base.path() != "/"
            || base.query().is_some()
            || !(100..=60_000).contains(&self.billing.request_timeout_ms)
        {
            return Err(Error::string(
                "settings.billing requires an origin URL and a 100..60000 ms timeout",
            ));
        }
        if self.logs.batch_max_bytes > self.logs.max_object_bytes {
            return Err(Error::string(
                "settings.logs.batch_max_bytes must not exceed max_object_bytes",
            ));
        }
        if !(1..=5_000).contains(&self.logs.archive_tick_ms)
            || self.logs.org_backlog_bytes == 0
            || self.logs.max_pending_orgs == 0
            || self.logs.backlog_bytes < self.logs.org_backlog_bytes
            || self.logs.batch_max_entries == 0
            || self.logs.batch_max_age_ms == 0
            || self.logs.upload_attempts == 0
        {
            return Err(Error::string(
                "settings.logs requires archive_tick_ms 1..5000, positive batch limits and backlog_bytes >= org_backlog_bytes",
            ));
        }
        if self.lifecycle.shutdown_worst_case() > LifecycleSettings::SHUTDOWN_BUDGET {
            return Err(Error::string(
                "settings.lifecycle: 2 * drain_ms + background_ms + registry_ms + 2000 must not exceed 45000",
            ));
        }
        if self.ingest.max_inflated_bytes > self.ingest.body_budget_bytes {
            return Err(Error::string(
                "settings.ingest.body_budget_bytes must hold at least one inflated envelope",
            ));
        }
        if self.logs.reconcile_max_objects == 0
            || self.logs.reconcile_timeout_ms == 0
            || self.logs.reconcile_concurrency == 0
            || self.auth.password_concurrency == 0
            || self.logs.search.max_active_queries == 0
            || self.logs.search.concurrency == 0
            || self.logs.max_attribute_bytes == 0
            || self.logs.max_record_bytes == 0
            || self.logs.max_body_bytes == 0
            || self.logs.max_attributes == 0
            || self.logs.search.max_rows == 0
            || self.logs.search.max_output_bytes < 1_024
            || self.logs.tail.replay_max_output_bytes < 1_024
            || self.query_admission.org_active_queries == 0
            || self.query_admission.org_queries_per_window == 0
            || self.query_admission.mcp_calls_per_window == 0
            || self.query_admission.window_ms == 0
            || self.lifecycle.max_active_requests == 0
            || !(1..=65_536).contains(&self.lifecycle.max_cached_orgs)
            || self.disk.scan_interval_secs == 0
            || self.disk.max_bytes == 0
            || self.disk.max_entries == 0
            || self.ingest.rate_per_second == 0
            || self.ingest.rate_burst == 0
            || self.ingest.rate_max_orgs == 0
        {
            return Err(Error::string(
                "admission and log query limits must be positive",
            ));
        }
        Ok(())
    }

    pub fn min_sqlite_version(&self) -> &str {
        self.min_sqlite_version.as_deref().unwrap_or("3.51.3")
    }
}

/// Application-owned backup sets. One worker; every limit fails explicitly.
#[derive(Clone, Debug, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct BackupSettings {
    pub interval_secs: u64,
    pub initial_delay_secs: u64,
    /// Budget for one member snapshot, seal and upload, or one member restore.
    pub deadline_secs: u64,
    pub max_snapshot_bytes: u64,
    pub max_object_bytes: usize,
    /// Scratch directories allowed at once: the running attempt plus the newest retained failures.
    pub max_scratch_dirs: usize,
    pub retention_days: u32,
    /// Collection attempts per cycle while the control structure keeps changing.
    pub revision_attempts: u32,
}

impl Default for BackupSettings {
    fn default() -> Self {
        Self {
            interval_secs: 3_600,
            initial_delay_secs: 300,
            deadline_secs: 180,
            max_snapshot_bytes: 512 << 20,
            max_object_bytes: 256 << 20,
            max_scratch_dirs: 2,
            retention_days: 14,
            revision_attempts: 3,
        }
    }
}

impl BackupSettings {
    pub fn validate(&self) -> bool {
        (1..=86_400).contains(&self.interval_secs)
            && self.initial_delay_secs <= 86_400
            && (1..=3_600).contains(&self.deadline_secs)
            && ((1 << 20)..=(16 << 30)).contains(&self.max_snapshot_bytes)
            && self.max_object_bytes >= 1 << 10
            && self.max_object_bytes as u64 <= self.max_snapshot_bytes
            && (1..=16).contains(&self.max_scratch_dirs)
            && (1..=365).contains(&self.retention_days)
            && (1..=10).contains(&self.revision_attempts)
    }

    pub fn limits(&self) -> crate::backup::Limits {
        crate::backup::Limits {
            max_snapshot_bytes: self.max_snapshot_bytes,
            max_object_bytes: self.max_object_bytes,
            deadline: Duration::from_secs(self.deadline_secs),
            max_scratch_dirs: self.max_scratch_dirs,
            retain_failures: Duration::from_secs(2 * self.interval_secs),
        }
    }
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StorageSettings {
    pub prefix: String,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct DiskSettings {
    pub max_bytes: u64,
    pub min_free_bytes: u64,
    pub max_entries: usize,
    pub scan_interval_secs: u64,
}

impl Default for DiskSettings {
    fn default() -> Self {
        Self {
            max_bytes: 8 << 30,
            min_free_bytes: 2 << 30,
            max_entries: 16_384,
            scan_interval_secs: 2,
        }
    }
}

#[derive(Clone, Debug, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct AuthSettings {
    pub password_concurrency: usize,
    pub session_ttl_secs: u64,
    pub secure_cookies: bool,
    /// Browser origin accepted on cookie-authenticated unsafe requests.
    pub origin: String,
    pub failed_login_delay_ms: u64,
    /// Organizations one account may create. Each one holds tenant files
    /// until its deletion finishes, so the limit bounds disk entries per account.
    pub max_created_orgs: u32,
}

impl Default for AuthSettings {
    fn default() -> Self {
        Self {
            password_concurrency: 8,
            session_ttl_secs: 14 * 24 * 3600,
            secure_cookies: true,
            origin: "https://postdeploy.dev".to_owned(),
            failed_login_delay_ms: 250,
            max_created_orgs: 5,
        }
    }
}

#[derive(Clone, Debug, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct IngestSettings {
    pub max_wire_bytes: usize,
    pub max_inflated_bytes: usize,
    /// Total bytes of request bodies held in memory at once.
    pub body_budget_bytes: usize,
    pub max_items: usize,
    pub max_events: usize,
    pub max_logs: usize,
    pub max_event_bytes: usize,
    /// Concurrent error commits. Logs use a separate pipeline budget.
    pub error_lane: usize,
    pub invalid_key_delay_ms: u64,
    /// Sustained ingestion requests per second for one organization.
    pub rate_per_second: u32,
    /// Requests one organization may send at once above the sustained rate.
    pub rate_burst: u32,
    /// Organizations with a partly used request budget held in memory.
    pub rate_max_orgs: usize,
}

impl Default for IngestSettings {
    fn default() -> Self {
        Self {
            max_wire_bytes: 1 << 20,
            max_inflated_bytes: 4 << 20,
            body_budget_bytes: 64 << 20,
            max_items: 400,
            max_events: 100,
            max_logs: 1_000,
            max_event_bytes: 1 << 20,
            error_lane: 16,
            invalid_key_delay_ms: 250,
            rate_per_second: 50,
            rate_burst: 100,
            rate_max_orgs: 65_536,
        }
    }
}

#[derive(Clone, Debug, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct LogSettings {
    pub batch_max_bytes: usize,
    /// Age after the first committed entry at which a batch is sealed for
    /// archiving.
    pub batch_max_age_ms: u64,
    pub batch_max_entries: usize,
    pub max_object_bytes: usize,
    /// Encrypted acknowledged log bytes waiting in SQLite for archiving,
    /// across all organizations.
    pub backlog_bytes: usize,
    /// The same bound for one organization.
    pub org_backlog_bytes: usize,
    /// Archive scheduler period. At most five seconds.
    pub archive_tick_ms: u64,
    /// Organizations that may hold unarchived log batches at once. Each one
    /// keeps a small archive scheduling entry in memory.
    pub max_pending_orgs: usize,
    pub upload_concurrency: usize,
    pub upload_attempts: u32,
    pub upload_deadline_ms: u64,
    pub retention_secs: u64,
    pub max_body_bytes: usize,
    pub max_attributes: usize,
    pub max_attribute_bytes: usize,
    pub max_record_bytes: usize,
    pub search: SearchSettings,
    pub tail: TailSettings,
    pub reconcile_max_objects: usize,
    pub reconcile_timeout_ms: u64,
    pub reconcile_concurrency: usize,
    pub sweep_interval_secs: u64,
    pub sweep_batch: usize,
}

impl Default for LogSettings {
    fn default() -> Self {
        Self {
            batch_max_bytes: 1 << 20,
            batch_max_age_ms: 240_000,
            batch_max_entries: 5_000,
            max_object_bytes: 4 << 20,
            backlog_bytes: 1 << 30,
            org_backlog_bytes: 64 << 20,
            archive_tick_ms: 5_000,
            max_pending_orgs: 16_384,
            upload_concurrency: 8,
            upload_attempts: 3,
            upload_deadline_ms: 10_000,
            retention_secs: 90 * 24 * 3600,
            max_body_bytes: 16 << 10,
            max_attributes: 64,
            max_attribute_bytes: 4_096,
            max_record_bytes: 65_536,
            search: SearchSettings::default(),
            tail: TailSettings::default(),
            reconcile_max_objects: 128,
            reconcile_timeout_ms: 2_000,
            reconcile_concurrency: 2,
            sweep_interval_secs: 300,
            sweep_batch: 500,
        }
    }
}

impl LogSettings {
    pub fn record_byte_limit(&self) -> usize {
        self.max_record_bytes
            .min(self.batch_max_bytes)
            .min(self.max_object_bytes)
            .min(self.search.max_output_bytes.saturating_sub(512))
            .min(self.tail.replay_max_output_bytes.saturating_sub(512))
    }

    pub fn batch_max_age(&self) -> Duration {
        Duration::from_millis(self.batch_max_age_ms)
    }
    pub fn upload_deadline(&self) -> Duration {
        Duration::from_millis(self.upload_deadline_ms)
    }
    pub fn retention(&self) -> Duration {
        Duration::from_secs(self.retention_secs)
    }
}

#[derive(Clone, Debug, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct SearchSettings {
    pub max_active_queries: usize,
    pub max_objects: usize,
    pub max_scan_bytes: u64,
    pub max_rows: usize,
    pub max_output_bytes: usize,
    pub concurrency: usize,
    pub timeout_ms: u64,
}

impl Default for SearchSettings {
    fn default() -> Self {
        Self {
            max_active_queries: 4,
            max_objects: 64,
            max_scan_bytes: 64 << 20,
            max_rows: 200,
            max_output_bytes: 1 << 20,
            concurrency: 4,
            timeout_ms: 10_000,
        }
    }
}

/// Per-organization budgets for expensive reads and MCP calls. The server-wide
/// active limit is `logs.search.max_active_queries`.
#[derive(Clone, Debug, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct QueryAdmissionSettings {
    pub org_active_queries: usize,
    pub org_queries_per_window: u32,
    pub mcp_calls_per_window: u32,
    pub window_ms: u64,
}

impl Default for QueryAdmissionSettings {
    fn default() -> Self {
        Self {
            org_active_queries: 2,
            org_queries_per_window: 30,
            mcp_calls_per_window: 120,
            window_ms: 60_000,
        }
    }
}

#[derive(Clone, Debug, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct TailSettings {
    pub max_viewers: usize,
    pub org_max_viewers: usize,
    pub replay_max_objects: usize,
    pub replay_max_bytes: u64,
    pub replay_max_output_bytes: usize,
    pub channel_capacity: usize,
    pub access_recheck_secs: u64,
    pub keep_alive_secs: u64,
}

impl Default for TailSettings {
    fn default() -> Self {
        Self {
            max_viewers: 64,
            org_max_viewers: 16,
            replay_max_objects: 32,
            replay_max_bytes: 32 << 20,
            replay_max_output_bytes: 1 << 20,
            channel_capacity: 64,
            access_recheck_secs: 60,
            keep_alive_secs: 15,
        }
    }
}

/// Technical safety limits per organization and UTC day. Plan limits are
/// monthly and live in [`crate::billing`]; the defaults equal them so a daily
/// total alone never refuses work the plan allows.
#[derive(Clone, Debug, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct QuotaSettings {
    pub daily_errors: u64,
    pub daily_logs: u64,
    pub daily_log_bytes: u64,
}

impl Default for QuotaSettings {
    fn default() -> Self {
        Self {
            daily_errors: crate::billing::MONTHLY_ERRORS,
            daily_logs: crate::billing::MONTHLY_LOG_BYTES,
            daily_log_bytes: crate::billing::MONTHLY_LOG_BYTES,
        }
    }
}

#[derive(Clone, Debug, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct BillingSettings {
    pub api_base: String,
    pub request_timeout_ms: u64,
}

impl Default for BillingSettings {
    fn default() -> Self {
        Self {
            api_base: crate::billing::stripe::DEFAULT_API_BASE.to_owned(),
            request_timeout_ms: 10_000,
        }
    }
}

#[derive(Clone, Debug, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct LifecycleSettings {
    pub max_active_requests: usize,
    pub max_cached_orgs: usize,
    pub request_timeout_ms: u64,
    pub drain_ms: u64,
    pub background_ms: u64,
    pub registry_ms: u64,
}

impl Default for LifecycleSettings {
    fn default() -> Self {
        Self {
            max_active_requests: 128,
            max_cached_orgs: 4_096,
            request_timeout_ms: 30_000,
            drain_ms: 10_000,
            background_ms: 10_000,
            registry_ms: 10_000,
        }
    }
}

impl LifecycleSettings {
    /// Ceiling for `Runtime::shutdown`. The compose `stop_grace_period` of 60 s
    /// leaves time above it for open connections to close and the process to exit.
    pub const SHUTDOWN_BUDGET: Duration = Duration::from_secs(45);
    /// How long a shutdown step waits for cancelled work after its deadline.
    pub const CANCEL_WAIT: Duration = Duration::from_secs(1);

    /// Log archive close and request drain each take up to `drain_ms`; the
    /// archive and background steps each add one `CANCEL_WAIT`.
    pub fn shutdown_worst_case(&self) -> Duration {
        let ms = Duration::from_millis;
        ms(self.drain_ms)
            .saturating_mul(2)
            .saturating_add(ms(self.background_ms))
            .saturating_add(ms(self.registry_ms))
            .saturating_add(Self::CANCEL_WAIT.saturating_mul(2))
    }
}

#[cfg(test)]
mod tests {
    #[tokio::test]
    async fn backup_settings_reject_an_object_cap_above_the_snapshot_cap() {
        let env = crate::testing::TestEnv::new("settings-backup-limits");
        let result = env
            .boot_memory(|settings| {
                settings["backup"] = serde_json::json!({
                    "max_snapshot_bytes": 1u64 << 20,
                    "max_object_bytes": 2u64 << 20,
                });
            })
            .await;
        let error = result.err().expect("invalid backup limits refuse boot");
        assert_eq!(error.to_string(), "backup limits are invalid");
    }

    #[tokio::test]
    async fn production_requires_an_https_public_url_without_a_trailing_slash() {
        let env = crate::testing::TestEnv::new("settings-public-url");
        let config = env.config("test/settings-public-url/", |_| {}).await;
        let base: super::Settings = serde_json::from_value(config.settings.unwrap()).unwrap();
        let production = |url: &str| {
            let mut settings = base.clone();
            settings.notifications.public_url = url.to_owned();
            settings
                .validate_production()
                .map_err(|error| error.to_string())
        };
        let refused = Err(
            "production settings.notifications.public_url must be an https origin without a trailing slash"
                .to_owned(),
        );

        assert_eq!(production("https://postdeploy.dev"), Ok(()));
        assert_eq!(production("http://127.0.0.1:5167"), refused);
        assert_eq!(production("https://postdeploy.dev/"), refused);
    }

    #[tokio::test]
    async fn lifecycle_settings_reject_deadlines_over_the_shutdown_budget() {
        let env = crate::testing::TestEnv::new("settings-shutdown-budget");
        let result = env
            .boot_memory(|settings| {
                settings["lifecycle"] = serde_json::json!({
                    "drain_ms": 15_000,
                    "background_ms": 10_000,
                    "registry_ms": 10_000,
                });
            })
            .await;
        let error = result.err().expect("deadlines over the budget refuse boot");
        assert_eq!(
            error.to_string(),
            "settings.lifecycle: 2 * drain_ms + background_ms + registry_ms + 2000 must not exceed 45000"
        );
    }
}
