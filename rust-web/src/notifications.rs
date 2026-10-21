//! Email and signed webhook notifications for new issues, regressions and
//! published reports.
//!
//! Work is durable in the organization's tenant database and holds only
//! references: an event id, a destination and the issue or report id. Message
//! text is built at delivery time from current metadata and the R2 report body,
//! then discarded. Delivery is at-least-once; recipients deduplicate with the
//! stable event id. No tenant handle is held during R2, DNS, SMTP or HTTP I/O.

use std::{
    fmt,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    str::FromStr,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc,
    },
    time::Duration,
};

use aes_gcm::{
    aead::{Aead, KeyInit, Payload},
    Aes256Gcm, Nonce,
};
use base64::{
    engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD},
    Engine,
};
use credseal::SecretString;
use futures::{stream, StreamExt};
use hmac::{Hmac, Mac};
use lettre::{
    message::{Mailbox, MultiPart, SinglePart},
    transport::smtp::authentication::Credentials,
    AsyncSmtpTransport, AsyncTransport, Message, Tokio1Executor,
};
use rand::RngCore;
use sea_orm::{
    ConnectionTrait, DatabaseConnection, DatabaseTransaction, QueryResult, SqliteTransactionMode,
    TransactionOptions, TransactionTrait,
};
use serde::{de::IntoDeserializer, Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest, Sha256};
use tenant_sqlite_loco::TenantPools;
use url::{Host, Url};

use crate::{
    account_settings::{AccountMail, AccountMessage, MailFailure},
    domain::{now_micros, now_secs, OrgId, ProjectId, UserId},
    error::{ApiError, ApiResult},
    identity::access::OrgAccess,
    reports::{self, Evidence, EvidenceFacts, IssueFacts, ReportDocument, ReportId, ReportMeta},
    runtime::sql,
    store::ObjectStore,
};

const MAX_URL_BYTES: usize = 2048;
const MAX_WEBHOOKS: i64 = 20;
const MAX_RESOLVED_ADDRS: usize = 8;
const WEBHOOK_SUMMARY_CHARS: usize = 2_000;
const USER_AGENT: &str = "PostDeploy-Webhooks/1";

#[derive(Clone, Debug, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct NotificationSettings {
    /// Dashboard origin used in links, such as `https://postdeploy.dev`.
    pub public_url: String,
    /// Work items claimed per run.
    pub batch: usize,
    pub concurrency: usize,
    pub max_attempts: u32,
    pub backoff_base_ms: u64,
    pub backoff_max_ms: u64,
    /// A claimed item becomes due again after this lease, for example after a crash.
    pub lease_ms: u64,
    /// Pending and in-flight items per organization. New work beyond this is dropped and counted.
    pub max_queued: i64,
    pub attempt_timeout_ms: u64,
    pub connect_timeout_ms: u64,
    pub resolve_timeout_ms: u64,
    pub retain_finished_secs: u64,
    pub sweep_batch: i64,
}

impl Default for NotificationSettings {
    fn default() -> Self {
        Self {
            public_url: "https://postdeploy.dev".to_owned(),
            batch: 16,
            concurrency: 4,
            max_attempts: 6,
            backoff_base_ms: 30_000,
            backoff_max_ms: 3_600_000,
            lease_ms: 300_000,
            max_queued: 1_000,
            attempt_timeout_ms: 15_000,
            connect_timeout_ms: 5_000,
            resolve_timeout_ms: 2_000,
            retain_finished_secs: 7 * 24 * 3600,
            sweep_batch: 500,
        }
    }
}

impl NotificationSettings {
    fn backoff_micros(&self, attempts: u32) -> i64 {
        let factor = 1u64 << attempts.saturating_sub(1).min(20);
        let ms = self
            .backoff_base_ms
            .saturating_mul(factor)
            .min(self.backoff_max_ms);
        (ms as i64).saturating_mul(1_000)
    }

    fn attempt_timeout(&self) -> Duration {
        Duration::from_millis(self.attempt_timeout_ms)
    }
}

/// Outbound mail server. Loaded from Credseal; the password never reaches Loco configuration.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SmtpConfig {
    pub host: String,
    pub port: u16,
    pub tls: SmtpTls,
    pub username: String,
    pub password: SecretString,
    /// Sender mailbox, such as `PostDeploy <alerts@postdeploy.dev>`.
    pub from: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SmtpTls {
    /// TLS from the first byte, usually port 465.
    Implicit,
    /// STARTTLS is required, usually port 587.
    Starttls,
    #[cfg(test)]
    #[serde(skip)]
    Plaintext,
}

#[derive(Debug, thiserror::Error)]
#[error("notification configuration: {0}")]
pub struct ConfigError(&'static str);

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EventKind {
    IssueNew,
    IssueRegression,
    ReportPublished,
}

impl EventKind {
    const ALL: [Self; 3] = [Self::IssueNew, Self::IssueRegression, Self::ReportPublished];

    fn bit(self) -> i64 {
        match self {
            Self::IssueNew => 1,
            Self::IssueRegression => 2,
            Self::ReportPublished => 4,
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::IssueNew => "issue_new",
            Self::IssueRegression => "issue_regression",
            Self::ReportPublished => "report_published",
        }
    }

    fn parse(value: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|kind| kind.as_str() == value)
    }

    fn webhook_type(self) -> &'static str {
        match self {
            Self::IssueNew => "issue.new",
            Self::IssueRegression => "issue.regression",
            Self::ReportPublished => "report.published",
        }
    }

    fn mask(kinds: &[Self]) -> ApiResult<i64> {
        let mask = kinds.iter().fold(0, |mask, kind| mask | kind.bit());
        if mask == 0 {
            return Err(ApiError::BadRequest("events_required"));
        }
        Ok(mask)
    }

    fn from_mask(mask: i64) -> Vec<Self> {
        Self::ALL
            .into_iter()
            .filter(|kind| mask & kind.bit() != 0)
            .collect()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Notice {
    NewIssue {
        project: ProjectId,
        issue: i64,
    },
    Regression {
        project: ProjectId,
        issue: i64,
        at: i64,
    },
    Report {
        project: ProjectId,
        report: ReportId,
    },
}

impl Notice {
    fn kind(&self) -> EventKind {
        match self {
            Self::NewIssue { .. } => EventKind::IssueNew,
            Self::Regression { .. } => EventKind::IssueRegression,
            Self::Report { .. } => EventKind::ReportPublished,
        }
    }

    fn project(&self) -> ProjectId {
        match self {
            Self::NewIssue { project, .. }
            | Self::Regression { project, .. }
            | Self::Report { project, .. } => *project,
        }
    }

    fn event_id(&self, org: &OrgId) -> String {
        let subject = match self {
            Self::NewIssue { issue, .. } => issue.to_string(),
            Self::Regression { issue, at, .. } => format!("{issue}:{at}"),
            Self::Report { report, .. } => report.to_string(),
        };
        let digest = Sha256::new()
            .chain_update(org.as_str())
            .chain_update([0])
            .chain_update(self.kind().as_str())
            .chain_update([0])
            .chain_update(subject)
            .finalize();
        format!("evt_{}", &hex::encode(digest)[..32])
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
pub struct EnqueueOutcome {
    /// Destinations subscribed to this event. Zero means notifications are not configured.
    pub destinations: u32,
    pub queued: u32,
    pub duplicate: u32,
    /// Dropped because the organization's queue is full.
    pub dropped: u32,
    /// The work could not be recorded. The caller's transaction is unaffected.
    pub failed: bool,
}

#[derive(Debug, Default)]
pub struct NotificationMetrics {
    pub enqueued: AtomicU64,
    pub duplicates: AtomicU64,
    pub dropped_overflow: AtomicU64,
    pub enqueue_failures: AtomicU64,
    pub attempts: AtomicU64,
    pub delivered: AtomicU64,
    pub retried: AtomicU64,
    pub failed_permanent: AtomicU64,
    pub failed_exhausted: AtomicU64,
    pub not_configured: AtomicU64,
    pub unsafe_destinations: AtomicU64,
}

fn bump(counter: &AtomicU64, by: u64) {
    counter.fetch_add(by, Ordering::Relaxed);
}

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize)]
#[serde(transparent)]
pub struct DestinationId(String);

impl DestinationId {
    fn generate() -> Self {
        Self(format!("d{}", uuid::Uuid::now_v7().simple()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl FromStr for DestinationId {
    type Err = ();

    fn from_str(value: &str) -> Result<Self, ()> {
        let valid = value.len() == 33
            && value.starts_with('d')
            && value[1..]
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b));
        valid.then(|| Self(value.to_owned())).ok_or(())
    }
}

impl<'de> Deserialize<'de> for DestinationId {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        String::deserialize(deserializer)?
            .parse()
            .map_err(|()| serde::de::Error::custom("invalid destination id"))
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EmailSubscription {
    pub events: Vec<EventKind>,
    pub project_id: Option<i64>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct WebhookInput {
    pub url: String,
    pub events: Vec<EventKind>,
    pub project_id: Option<i64>,
}

impl fmt::Debug for WebhookInput {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("WebhookInput")
            .field("events", &self.events)
            .field("project_id", &self.project_id)
            .finish_non_exhaustive()
    }
}

/// A destination as members see it. Webhook URLs and secrets are never returned.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct DestinationView {
    pub id: DestinationId,
    pub kind: &'static str,
    pub events: Vec<EventKind>,
    pub project_id: Option<i64>,
    pub user_id: Option<i64>,
    pub url_hint: Option<String>,
    pub created_at: i64,
    pub delivered: i64,
    pub failed: i64,
    pub dropped: i64,
    pub not_configured: i64,
    pub last_outcome: Option<String>,
    pub last_attempt_at: Option<i64>,
}

/// Returned once at creation. The signing secret cannot be read again.
#[derive(Debug)]
pub struct CreatedWebhook {
    pub destination: DestinationView,
    pub signing_secret: SecretString,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
pub struct RunSummary {
    pub claimed: u32,
    pub delivered: u32,
    pub retried: u32,
    pub failed: u32,
    pub not_configured: u32,
    pub swept: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Outcome {
    Delivered,
    Retryable(&'static str),
    Permanent(&'static str),
    NotConfigured,
}

fn secret_string(value: String) -> SecretString {
    let deserializer: serde::de::value::StringDeserializer<serde::de::value::Error> =
        value.into_deserializer();
    SecretString::deserialize(deserializer).expect("a string deserializes into SecretString")
}

enum CipherField {
    Url,
    Secret,
}

impl CipherField {
    fn label(self) -> &'static str {
        match self {
            Self::Url => "url",
            Self::Secret => "secret",
        }
    }
}

struct DataKey(Aes256Gcm);

impl DataKey {
    fn from_base64(key: &SecretString) -> Result<Self, ConfigError> {
        let mut bytes = STANDARD
            .decode(key.expose_secret())
            .map_err(|_| ConfigError("data key must be Base64"))?;
        let cipher =
            Aes256Gcm::new_from_slice(&bytes).map_err(|_| ConfigError("data key must be 32 bytes"));
        bytes.fill(0);
        Ok(Self(cipher?))
    }

    fn aad(org: &OrgId, destination: &DestinationId, field: CipherField) -> String {
        let field = field.label();
        format!(
            "postdeploy/notification/v1/{org}/{}/{field}",
            destination.as_str()
        )
    }

    fn seal(
        &self,
        org: &OrgId,
        destination: &DestinationId,
        field: CipherField,
        plaintext: &[u8],
    ) -> Vec<u8> {
        let aad = Self::aad(org, destination, field);
        let mut nonce = [0u8; 12];
        rand::rng().fill_bytes(&mut nonce);
        let sealed = self
            .0
            .encrypt(
                Nonce::from_slice(&nonce),
                Payload {
                    msg: plaintext,
                    aad: aad.as_bytes(),
                },
            )
            .expect("AES-GCM encryption of a bounded message");
        [nonce.as_slice(), &sealed].concat()
    }

    fn open(
        &self,
        org: &OrgId,
        destination: &DestinationId,
        field: CipherField,
        blob: &[u8],
    ) -> Option<SecretString> {
        let aad = Self::aad(org, destination, field);
        let (nonce, sealed) = blob.split_at_checked(12)?;
        let plain = self
            .0
            .decrypt(
                Nonce::from_slice(nonce),
                Payload {
                    msg: sealed,
                    aad: aad.as_bytes(),
                },
            )
            .ok()?;
        String::from_utf8(plain).ok().map(secret_string)
    }
}

enum Egress {
    Public,
    /// Test receivers on loopback, resolved only through this table.
    #[cfg(test)]
    Test(std::sync::RwLock<std::collections::HashMap<String, IpAddr>>),
}

impl Egress {
    fn permits(&self, ip: IpAddr) -> bool {
        match self {
            Self::Public => is_public(ip),
            #[cfg(test)]
            Self::Test(_) => is_public(ip) || ip.is_loopback(),
        }
    }

    fn allows_http(&self) -> bool {
        match self {
            Self::Public => false,
            #[cfg(test)]
            Self::Test(_) => true,
        }
    }

    async fn lookup(
        &self,
        domain: &str,
        port: u16,
        timeout: Duration,
    ) -> Result<Vec<IpAddr>, Outcome> {
        match self {
            Self::Public => {
                match tokio::time::timeout(timeout, tokio::net::lookup_host((domain, port))).await {
                    Ok(Ok(addrs)) => Ok(addrs.map(|addr| addr.ip()).collect()),
                    Ok(Err(_)) => Err(Outcome::Retryable("dns_failed")),
                    Err(_) => Err(Outcome::Retryable("dns_timeout")),
                }
            }
            #[cfg(test)]
            Self::Test(hosts) => hosts
                .read()
                .expect("test hosts lock")
                .get(domain)
                .map(|ip| vec![*ip])
                .ok_or(Outcome::Retryable("dns_failed")),
        }
    }
}

fn is_public(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => public_v4(v4),
        IpAddr::V6(v6) => match v6.to_ipv4_mapped() {
            Some(v4) => public_v4(v4),
            None => public_v6(v6),
        },
    }
}

fn public_v4(ip: Ipv4Addr) -> bool {
    let [a, b, c, _] = ip.octets();
    !(a == 0
        || a == 10
        || a == 127
        || a >= 224
        || (a == 100 && (64..128).contains(&b))
        || (a == 169 && b == 254)
        || (a == 172 && (16..32).contains(&b))
        || (a == 192 && b == 0 && (c == 0 || c == 2))
        || (a == 192 && b == 88 && c == 99)
        || (a == 192 && b == 168)
        || (a == 198 && (b == 18 || b == 19))
        || (a == 198 && b == 51 && c == 100)
        || (a == 203 && b == 0 && c == 113))
}

fn public_v6(ip: Ipv6Addr) -> bool {
    let s = ip.segments();
    let global_unicast = s[0] & 0xe000 == 0x2000;
    let special = (s[0] == 0x2001 && s[1] < 0x0200)
        || (s[0] == 0x2001 && s[1] == 0x0db8)
        || s[0] == 0x2002
        || (s[0] == 0x3fff && s[1] & 0xf000 == 0);
    global_unicast && !special
}

fn parse_webhook_url(raw: &str, egress: &Egress) -> Result<Url, &'static str> {
    if raw.len() > MAX_URL_BYTES {
        return Err("invalid_webhook_url");
    }
    let url = Url::parse(raw.trim()).map_err(|_| "invalid_webhook_url")?;
    let scheme_ok = url.scheme() == "https" || (url.scheme() == "http" && egress.allows_http());
    if !scheme_ok || !url.username().is_empty() || url.password().is_some() {
        return Err("unsafe_webhook_url");
    }
    if url.fragment().is_some() || url.port_or_known_default().is_none() {
        return Err("invalid_webhook_url");
    }
    match url.host() {
        Some(Host::Ipv4(ip)) if !egress.permits(IpAddr::V4(ip)) => Err("unsafe_webhook_url"),
        Some(Host::Ipv6(ip)) if !egress.permits(IpAddr::V6(ip)) => Err("unsafe_webhook_url"),
        Some(Host::Domain(domain))
            if matches!(egress, Egress::Public)
                && (domain == "localhost" || domain.ends_with(".localhost")) =>
        {
            Err("unsafe_webhook_url")
        }
        Some(_) => Ok(url),
        None => Err("invalid_webhook_url"),
    }
}

fn url_hint(url: &Url) -> String {
    let port = url
        .port()
        .map(|port| format!(":{port}"))
        .unwrap_or_default();
    format!(
        "{}://{}{port}/…",
        url.scheme(),
        url.host_str().unwrap_or("")
    )
}

/// `PostDeploy-Signature: t=<unix seconds>,v1=<hex>` where the MAC is
/// HMAC-SHA256 keyed with the signing secret over `<timestamp>.<raw body>`.
fn signature(secret: &str, timestamp: i64, body: &[u8]) -> String {
    let mut mac = <Hmac<Sha256> as Mac>::new_from_slice(secret.as_bytes())
        .expect("HMAC accepts any key length");
    mac.update(timestamp.to_string().as_bytes());
    mac.update(b".");
    mac.update(body);
    hex::encode(mac.finalize().into_bytes())
}

struct Mailer {
    transport: AsyncSmtpTransport<Tokio1Executor>,
    from: Mailbox,
}

impl Mailer {
    fn new(config: &SmtpConfig, timeout: Duration) -> Result<Self, ConfigError> {
        let from: Mailbox = config
            .from
            .parse()
            .map_err(|_| ConfigError("smtp.from must be a mailbox"))?;
        if config.host.trim().is_empty() || config.username.is_empty() {
            return Err(ConfigError("smtp requires a host and username"));
        }
        let builder = match config.tls {
            SmtpTls::Implicit => AsyncSmtpTransport::<Tokio1Executor>::relay(&config.host),
            SmtpTls::Starttls => AsyncSmtpTransport::<Tokio1Executor>::starttls_relay(&config.host),
            #[cfg(test)]
            SmtpTls::Plaintext => Ok(AsyncSmtpTransport::<Tokio1Executor>::builder_dangerous(
                &config.host,
            )),
        }
        .map_err(|_| ConfigError("smtp tls setup failed"))?;
        let transport = builder
            .port(config.port)
            .credentials(Credentials::new(
                config.username.clone(),
                config.password.expose_secret().to_owned(),
            ))
            .timeout(Some(timeout))
            .build();
        Ok(Self { transport, from })
    }

    async fn send(&self, to: &str, content: &EmailContent, message_id: Option<String>) -> Outcome {
        let Ok(to) = to.parse::<Mailbox>() else {
            return Outcome::Permanent("invalid_recipient");
        };
        let message = Message::builder()
            .from(self.from.clone())
            .to(to)
            .subject(&content.subject)
            .message_id(message_id);
        let message = match &content.html {
            Some(html) => message.multipart(MultiPart::alternative_plain_html(
                content.text.clone(),
                html.clone(),
            )),
            None => message.singlepart(SinglePart::plain(content.text.clone())),
        };
        let Ok(message) = message else {
            return Outcome::Permanent("invalid_message");
        };
        match self.transport.send(message).await {
            Ok(_) => Outcome::Delivered,
            Err(error) if error.is_permanent() => Outcome::Permanent("smtp_rejected"),
            Err(error) if error.is_timeout() => Outcome::Retryable("smtp_timeout"),
            Err(error) if error.is_transient() => Outcome::Retryable("smtp_deferred"),
            Err(_) => Outcome::Retryable("smtp_unavailable"),
        }
    }
}

struct EmailContent {
    subject: String,
    text: String,
    html: Option<String>,
}

fn escape(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for c in value.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            c => out.push(c),
        }
    }
    out
}

fn one_line(value: &str, max_chars: usize) -> String {
    value
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .take(max_chars)
        .collect()
}

fn micros_utc(micros: i64) -> String {
    chrono::DateTime::from_timestamp_micros(micros)
        .map(|t| t.format("%Y-%m-%d %H:%M UTC").to_string())
        .unwrap_or_default()
}

struct Links<'a> {
    base: &'a str,
    org: &'a OrgId,
    project: ProjectId,
}

impl Links<'_> {
    fn issue(&self, id: i64) -> String {
        format!(
            "{}/dashboard/orgs/{}/projects/{}/observe/issues/{id}",
            self.base, self.org, self.project.0
        )
    }

    fn event(&self, issue: i64, event: &str, source: Option<i64>) -> String {
        match source {
            Some(source) => format!("{}?event={event}&source={source}", self.issue(issue)),
            None => format!("{}?event={event}", self.issue(issue)),
        }
    }

    fn log(&self, cursor: &str) -> String {
        format!(
            "{}/dashboard/orgs/{}/projects/{}/logs?cursor={cursor}",
            self.base, self.org, self.project.0
        )
    }

    fn report(&self, id: &ReportId) -> String {
        format!(
            "{}/dashboard/orgs/{}/projects/{}/reports/{id}",
            self.base, self.org, self.project.0
        )
    }

    fn evidence(&self, evidence: &Evidence) -> String {
        match evidence {
            Evidence::Issue { issue_id } => self.issue(*issue_id),
            Evidence::Event {
                issue_id,
                event_id,
                source_id,
            } => self.event(*issue_id, event_id, *source_id),
            Evidence::Log { cursor } => self.log(&cursor.to_string()),
        }
    }
}

fn evidence_line(facts: &EvidenceFacts) -> String {
    match (&facts.evidence, &facts.issue, &facts.log) {
        (Evidence::Issue { .. }, Some(issue), _) => format!(
            "Issue #{}: {} ({}, {}, {} events, last seen {})",
            issue.id,
            one_line(&issue.title, 200),
            issue.level,
            issue.status,
            issue.event_count,
            micros_utc(issue.last_seen)
        ),
        (Evidence::Event { event_id, .. }, Some(issue), _) => format!(
            "Event {event_id} of issue #{}: {}",
            issue.id,
            one_line(&issue.title, 200)
        ),
        (Evidence::Log { cursor }, _, Some(log)) => format!(
            "Log entry {cursor} ({} to {})",
            micros_utc(log.min_ts),
            micros_utc(log.max_ts)
        ),
        (Evidence::Issue { issue_id } | Evidence::Event { issue_id, .. }, None, _) => {
            format!("Issue #{issue_id} (no longer available)")
        }
        (Evidence::Log { cursor }, _, None) => format!("Log entry {cursor} (expired)"),
    }
}

fn issue_email(
    kind: EventKind,
    project: &str,
    issue: &IssueFacts,
    links: &Links<'_>,
) -> EmailContent {
    let label = match kind {
        EventKind::IssueRegression => "Regression",
        _ => "New issue",
    };
    let title = one_line(&issue.title, 200);
    let url = links.issue(issue.id);
    let facts = format!(
        "Project: {project}\nEnvironment: {}\nLevel: {}\nEvents: {}\nFirst seen: {}\nLast seen: {}",
        issue.environment,
        issue.level,
        issue.event_count,
        micros_utc(issue.first_seen),
        micros_utc(issue.last_seen)
    );
    let culprit = issue
        .culprit
        .as_deref()
        .map(|c| one_line(c, 300))
        .unwrap_or_default();
    EmailContent {
        subject: format!("[PostDeploy] {label}: {title}"),
        text: format!("{label}: {title}\n{culprit}\n\n{facts}\n\nOpen issue: {url}\n"),
        html: Some(format!(
            "<h2>{}: {}</h2><p>{}</p><pre style=\"white-space:pre-wrap;font-family:inherit\">{}</pre><p><a href=\"{}\">Open issue</a></p>",
            label,
            escape(&title),
            escape(&culprit),
            escape(&facts),
            escape(&url)
        )),
    }
}

fn report_email(
    project: &str,
    document: &ReportDocument,
    evidence: &[EvidenceFacts],
    links: &Links<'_>,
) -> EmailContent {
    let title = one_line(&document.title, 200);
    let url = links.report(&document.id);
    let mut text = format!("{title}\nProject: {project}\n\n{}\n", document.summary);
    let mut html = format!(
        "<h2>{}</h2><p>Project: {}</p><pre style=\"white-space:pre-wrap;font-family:inherit\">{}</pre>",
        escape(&title),
        escape(project),
        escape(&document.summary)
    );
    for (index, finding) in document.findings.iter().enumerate() {
        let lines: Vec<(String, String)> = evidence
            .iter()
            .filter(|facts| facts.finding as usize == index)
            .map(|facts| (evidence_line(facts), links.evidence(&facts.evidence)))
            .collect();
        text.push_str(&format!(
            "\n[{}] {}\n{}\n",
            finding.severity.as_str(),
            finding.title,
            finding.detail
        ));
        html.push_str(&format!(
            "<h3>[{}] {}</h3><pre style=\"white-space:pre-wrap;font-family:inherit\">{}</pre><ul>",
            finding.severity.as_str(),
            escape(&finding.title),
            escape(&finding.detail)
        ));
        for (line, link) in lines {
            text.push_str(&format!("  - {line}\n    {link}\n"));
            html.push_str(&format!(
                "<li><a href=\"{}\">{}</a></li>",
                escape(&link),
                escape(&line)
            ));
        }
        html.push_str("</ul>");
    }
    text.push_str(&format!("\nOpen report: {url}\n"));
    html.push_str(&format!(
        "<p><a href=\"{}\">Open report</a></p>",
        escape(&url)
    ));
    EmailContent {
        subject: format!("[PostDeploy] Report: {title}"),
        text,
        html: Some(html),
    }
}

fn issue_json(issue: &IssueFacts, links: &Links<'_>) -> serde_json::Value {
    json!({
        "id": issue.id,
        "title": one_line(&issue.title, 200),
        "culprit": issue.culprit.as_deref().map(|c| one_line(c, 300)),
        "level": issue.level,
        "status": issue.status,
        "environment": issue.environment,
        "event_count": issue.event_count,
        "first_seen": issue.first_seen,
        "last_seen": issue.last_seen,
        "url": links.issue(issue.id),
    })
}

fn report_json(
    report: &ReportMeta,
    document: &ReportDocument,
    links: &Links<'_>,
) -> serde_json::Value {
    json!({
        "id": report.id,
        "title": one_line(&document.title, 200),
        "summary": document.summary.chars().take(WEBHOOK_SUMMARY_CHARS).collect::<String>(),
        "finding_count": report.finding_count,
        "evidence_count": report.evidence_count,
        "author_id": report.author_id,
        "created_at": report.created_at,
        "url": links.report(&report.id),
    })
}

enum Destination {
    Email { user: UserId },
    Webhook { url: Vec<u8>, secret: Vec<u8> },
}

enum Subject {
    Issue(IssueFacts),
    Report {
        meta: ReportMeta,
        key: String,
        evidence: Vec<EvidenceFacts>,
    },
    Missing,
}

struct Claimed {
    id: i64,
    event_id: String,
    kind: EventKind,
    project: ProjectId,
    attempts: u32,
    destination_id: DestinationId,
    destination: Option<Destination>,
    subject: Subject,
}

/// Notification service. Constructing it starts no task; the runtime owner
/// calls [`Notifications::run_pending_for_org`].
#[derive(Clone)]
pub struct Notifications(Arc<Inner>);

struct Inner {
    control: DatabaseConnection,
    tenants: TenantPools,
    store: ObjectStore,
    key: DataKey,
    mailer: Option<Mailer>,
    egress: Egress,
    settings: NotificationSettings,
    base_url: String,
    metrics: NotificationMetrics,
}

fn immediate() -> TransactionOptions {
    TransactionOptions {
        sqlite_transaction_mode: Some(SqliteTransactionMode::Immediate),
        ..TransactionOptions::default()
    }
}

impl Notifications {
    /// `data_key` is the Credseal `security.data_key`. Without `smtp`, email
    /// work finishes as not configured.
    pub fn new(
        control: DatabaseConnection,
        tenants: TenantPools,
        store: ObjectStore,
        data_key: &SecretString,
        smtp: Option<&SmtpConfig>,
        settings: NotificationSettings,
    ) -> Result<Self, ConfigError> {
        Self::build(
            control,
            tenants,
            store,
            data_key,
            smtp,
            settings,
            Egress::Public,
        )
    }

    fn build(
        control: DatabaseConnection,
        tenants: TenantPools,
        store: ObjectStore,
        data_key: &SecretString,
        smtp: Option<&SmtpConfig>,
        settings: NotificationSettings,
        egress: Egress,
    ) -> Result<Self, ConfigError> {
        let base = Url::parse(&settings.public_url)
            .map_err(|_| ConfigError("public_url must be a URL"))?;
        let loopback = base.host_str().is_some_and(|host| {
            host == "localhost"
                || host
                    .parse::<std::net::IpAddr>()
                    .is_ok_and(|ip| ip.is_loopback())
        });
        if !(base.scheme() == "https" || (base.scheme() == "http" && loopback))
            || base.host().is_none()
            || base.path() != "/"
            || base.query().is_some()
            || base.fragment().is_some()
            || !base.username().is_empty()
            || base.password().is_some()
        {
            return Err(ConfigError(
                "public_url must be an https origin or http loopback origin",
            ));
        }
        if settings.batch == 0
            || settings.concurrency == 0
            || settings.max_attempts == 0
            || settings.max_queued <= 0
        {
            return Err(ConfigError(
                "batch, concurrency, max_attempts and max_queued must be positive",
            ));
        }
        let mailer = smtp
            .map(|config| Mailer::new(config, settings.attempt_timeout()))
            .transpose()?;
        Ok(Self(Arc::new(Inner {
            control,
            tenants,
            store,
            key: DataKey::from_base64(data_key)?,
            mailer,
            egress,
            base_url: base.as_str().trim_end_matches('/').to_owned(),
            settings,
            metrics: NotificationMetrics::default(),
        })))
    }

    pub fn metrics(&self) -> &NotificationMetrics {
        &self.0.metrics
    }

    fn links<'a>(&'a self, org: &'a OrgId, project: ProjectId) -> Links<'a> {
        Links {
            base: &self.0.base_url,
            org,
            project,
        }
    }

    async fn project_filter(&self, org: &OrgId, project: Option<i64>) -> ApiResult<()> {
        match project {
            Some(project) => {
                reports::project_in_org(&self.0.control, org, ProjectId(project)).await
            }
            None => Ok(()),
        }
    }

    /// Subscribes the caller's own account email. Replaces an existing subscription.
    pub async fn subscribe_email(
        &self,
        access: &OrgAccess,
        input: EmailSubscription,
    ) -> ApiResult<DestinationView> {
        let events = EventKind::mask(&input.events)?;
        self.project_filter(&access.org, input.project_id).await?;
        let handle = crate::organization_lifecycle::active_tenant(
            &self.0.control,
            &self.0.tenants,
            &access.org,
        )
        .await?;
        let row = handle
            .query_one_raw(sql(
                "INSERT INTO notification_destinations (id, kind, user_id, events, project_id, created_by, created_at)
                 VALUES (?, 'email', ?, ?, ?, ?, ?)
                 ON CONFLICT (user_id) WHERE kind = 'email'
                 DO UPDATE SET events = excluded.events, project_id = excluded.project_id
                 RETURNING *",
                vec![
                    DestinationId::generate().as_str().into(),
                    access.user.0.into(),
                    events.into(),
                    input.project_id.into(),
                    access.user.0.into(),
                    now_micros().into(),
                ],
            ))
            .await?
            .ok_or(ApiError::Internal("email subscription upsert".into()))?;
        destination_view(&row)
    }

    /// Owners and admins only. The URL is validated without contacting it and
    /// stored encrypted. The signing secret is returned once.
    pub async fn create_webhook(
        &self,
        access: &OrgAccess,
        input: WebhookInput,
    ) -> ApiResult<CreatedWebhook> {
        access.require_manage()?;
        let events = EventKind::mask(&input.events)?;
        let url = parse_webhook_url(&input.url, &self.0.egress).map_err(ApiError::BadRequest)?;
        self.project_filter(&access.org, input.project_id).await?;
        let id = DestinationId::generate();
        let mut raw = [0u8; 32];
        rand::rng().fill_bytes(&mut raw);
        let secret = secret_string(format!("whsec_{}", URL_SAFE_NO_PAD.encode(raw)));
        raw.fill(0);
        let key = &self.0.key;
        let url_ciphertext = key.seal(&access.org, &id, CipherField::Url, url.as_str().as_bytes());
        let secret_ciphertext = key.seal(
            &access.org,
            &id,
            CipherField::Secret,
            secret.expose_secret().as_bytes(),
        );

        let handle = crate::organization_lifecycle::active_tenant(
            &self.0.control,
            &self.0.tenants,
            &access.org,
        )
        .await?;
        let txn = handle.begin_with_options(immediate()).await?;
        let count: i64 = txn
            .query_one_raw(sql(
                "SELECT COUNT(*) AS n FROM notification_destinations WHERE kind = 'webhook'",
                vec![],
            ))
            .await?
            .map(|row| row.try_get("", "n"))
            .transpose()?
            .unwrap_or(0);
        if count >= MAX_WEBHOOKS {
            return Err(ApiError::Conflict("too_many_webhooks"));
        }
        let row = txn
            .query_one_raw(sql(
                "INSERT INTO notification_destinations (id, kind, url_ciphertext, secret_ciphertext, url_hint,
                    events, project_id, created_by, created_at)
                 VALUES (?, 'webhook', ?, ?, ?, ?, ?, ?, ?) RETURNING *",
                vec![
                    id.as_str().into(),
                    url_ciphertext.into(),
                    secret_ciphertext.into(),
                    url_hint(&url).into(),
                    events.into(),
                    input.project_id.into(),
                    access.user.0.into(),
                    now_micros().into(),
                ],
            ))
            .await?
            .ok_or(ApiError::Internal("webhook insert".into()))?;
        txn.commit().await?;
        Ok(CreatedWebhook {
            destination: destination_view(&row)?,
            signing_secret: secret,
        })
    }

    pub async fn destinations(&self, access: &OrgAccess) -> ApiResult<Vec<DestinationView>> {
        let handle = crate::organization_lifecycle::active_tenant(
            &self.0.control,
            &self.0.tenants,
            &access.org,
        )
        .await?;
        handle
            .query_all_raw(sql(
                "SELECT * FROM notification_destinations ORDER BY id",
                vec![],
            ))
            .await?
            .iter()
            .map(destination_view)
            .collect()
    }

    /// Webhooks need an owner or admin. Members may remove their own email subscription.
    pub async fn delete_destination(
        &self,
        access: &OrgAccess,
        id: &DestinationId,
    ) -> ApiResult<()> {
        let handle = crate::organization_lifecycle::active_tenant(
            &self.0.control,
            &self.0.tenants,
            &access.org,
        )
        .await?;
        let txn = handle.begin_with_options(immediate()).await?;
        let row = txn
            .query_one_raw(sql(
                "SELECT kind, user_id FROM notification_destinations WHERE id = ?",
                vec![id.as_str().into()],
            ))
            .await?
            .ok_or(ApiError::NotFound)?;
        let kind: String = row.try_get("", "kind")?;
        let user: Option<i64> = row.try_get("", "user_id")?;
        if kind == "webhook" || user != Some(access.user.0) {
            access.require_manage()?;
        }
        txn.execute_raw(sql(
            "DELETE FROM notification_work WHERE destination_id = ?",
            vec![id.as_str().into()],
        ))
        .await?;
        txn.execute_raw(sql(
            "DELETE FROM notification_destinations WHERE id = ?",
            vec![id.as_str().into()],
        ))
        .await?;
        txn.commit().await?;
        Ok(())
    }

    /// Records work for every matching destination inside the caller's
    /// transaction, under a savepoint. A failure or a full queue is counted and
    /// never fails the caller. Re-enqueueing the same notice is a no-op.
    pub async fn enqueue(
        &self,
        txn: &DatabaseTransaction,
        org: &OrgId,
        notice: &Notice,
    ) -> EnqueueOutcome {
        let metrics = &self.0.metrics;
        let result = async {
            let savepoint = txn.begin().await?;
            let outcome = self.enqueue_in(&savepoint, org, notice).await?;
            savepoint.commit().await?;
            Ok::<_, sea_orm::DbErr>(outcome)
        }
        .await;
        match result {
            Ok(outcome) => {
                bump(&metrics.enqueued, u64::from(outcome.queued));
                bump(&metrics.duplicates, u64::from(outcome.duplicate));
                bump(&metrics.dropped_overflow, u64::from(outcome.dropped));
                outcome
            }
            Err(error) => {
                bump(&metrics.enqueue_failures, 1);
                tracing::warn!(%error, "notification enqueue failed");
                EnqueueOutcome {
                    failed: true,
                    ..EnqueueOutcome::default()
                }
            }
        }
    }

    async fn enqueue_in(
        &self,
        conn: &impl ConnectionTrait,
        org: &OrgId,
        notice: &Notice,
    ) -> Result<EnqueueOutcome, sea_orm::DbErr> {
        let kind = notice.kind();
        let project = notice.project();
        let destinations = conn
            .query_all_raw(sql(
                "SELECT id FROM notification_destinations
                 WHERE (events & ?) != 0 AND (project_id IS NULL OR project_id = ?) ORDER BY id",
                vec![kind.bit().into(), project.0.into()],
            ))
            .await?;
        let mut outcome = EnqueueOutcome {
            destinations: destinations.len() as u32,
            ..EnqueueOutcome::default()
        };
        if destinations.is_empty() {
            return Ok(outcome);
        }
        let active: i64 = conn
            .query_one_raw(sql(
                "SELECT COUNT(*) AS n FROM notification_work WHERE state IN ('pending', 'sending')",
                vec![],
            ))
            .await?
            .map(|row| row.try_get("", "n"))
            .transpose()?
            .unwrap_or(0);
        let mut room = (self.0.settings.max_queued - active).max(0);
        let event_id = notice.event_id(org);
        let (issue, report) = match notice {
            Notice::NewIssue { issue, .. } | Notice::Regression { issue, .. } => {
                (Some(*issue), None)
            }
            Notice::Report { report, .. } => (None, Some(report.as_str().to_owned())),
        };
        let now = now_micros();
        for row in &destinations {
            let destination: String = row.try_get("", "id")?;
            let exists = conn
                .query_one_raw(sql(
                    "SELECT 1 AS found FROM notification_work WHERE event_id = ? AND destination_id = ?",
                    vec![event_id.clone().into(), destination.clone().into()],
                ))
                .await?
                .is_some();
            if exists {
                outcome.duplicate += 1;
                continue;
            }
            if room == 0 {
                outcome.dropped += 1;
                conn.execute_raw(sql(
                    "UPDATE notification_destinations SET dropped = dropped + 1, last_outcome = 'queue_full'
                     WHERE id = ?",
                    vec![destination.into()],
                ))
                .await?;
                continue;
            }
            conn.execute_raw(sql(
                "INSERT INTO notification_work (event_id, destination_id, kind, project_id, issue_id, report_id,
                    state, attempts, next_attempt_at, created_at)
                 VALUES (?, ?, ?, ?, ?, ?, 'pending', 0, ?, ?)",
                vec![
                    event_id.clone().into(),
                    destination.into(),
                    kind.as_str().into(),
                    project.0.into(),
                    issue.into(),
                    report.clone().into(),
                    now.into(),
                    now.into(),
                ],
            ))
            .await?;
            room -= 1;
            outcome.queued += 1;
        }
        Ok(outcome)
    }

    /// Claims due work, delivers it with no tenant handle held, then records
    /// outcomes. Work claimed by a run that crashed becomes due again after the
    /// lease, so delivery is at-least-once.
    pub async fn run_pending_for_org(&self, org: &OrgId) -> ApiResult<RunSummary> {
        let settings = &self.0.settings;
        let (claimed, swept) = self.claim(org).await?;
        let mut summary = RunSummary {
            claimed: claimed.len() as u32,
            swept,
            ..RunSummary::default()
        };
        if claimed.is_empty() {
            return Ok(summary);
        }
        bump(&self.0.metrics.attempts, claimed.len() as u64);
        let deadline =
            settings.attempt_timeout() + Duration::from_millis(settings.resolve_timeout_ms);
        let results: Vec<(Claimed, Outcome)> = stream::iter(claimed)
            .map(|item| async move {
                let outcome = tokio::time::timeout(deadline, self.deliver(org, &item))
                    .await
                    .unwrap_or(Outcome::Retryable("timeout"));
                (item, outcome)
            })
            .buffer_unordered(settings.concurrency)
            .collect()
            .await;
        self.record(org, &results, &mut summary).await?;
        Ok(summary)
    }

    async fn claim(&self, org: &OrgId) -> ApiResult<(Vec<Claimed>, u64)> {
        let settings = &self.0.settings;
        let now = now_micros();
        let handle =
            crate::organization_lifecycle::active_tenant(&self.0.control, &self.0.tenants, org)
                .await?;
        let txn = handle.begin_with_options(immediate()).await?;
        let swept = txn
            .execute_raw(sql(
                "DELETE FROM notification_work WHERE id IN (SELECT id FROM notification_work
                    WHERE finished_at IS NOT NULL AND finished_at < ? ORDER BY finished_at LIMIT ?)",
                vec![
                    (now - (settings.retain_finished_secs as i64).saturating_mul(1_000_000)).into(),
                    settings.sweep_batch.into(),
                ],
            ))
            .await?
            .rows_affected();
        let rows = txn
            .query_all_raw(sql(
                "UPDATE notification_work SET state = 'sending', attempts = attempts + 1, next_attempt_at = ?
                 WHERE id IN (SELECT id FROM notification_work WHERE state IN ('pending', 'sending')
                    AND next_attempt_at <= ? ORDER BY next_attempt_at, id LIMIT ?)
                 RETURNING id, event_id, destination_id, kind, project_id, issue_id, report_id, attempts",
                vec![
                    (now + (settings.lease_ms as i64).saturating_mul(1_000)).into(),
                    now.into(),
                    (settings.batch as i64).into(),
                ],
            ))
            .await?;
        let mut claimed = Vec::with_capacity(rows.len());
        for row in &rows {
            claimed.push(self.load_claimed(&txn, row).await?);
        }
        txn.commit().await?;
        drop(handle);
        Ok((claimed, swept))
    }

    async fn load_claimed(
        &self,
        conn: &impl ConnectionTrait,
        row: &QueryResult,
    ) -> ApiResult<Claimed> {
        let destination_id: String = row.try_get("", "destination_id")?;
        let kind: String = row.try_get("", "kind")?;
        let kind =
            EventKind::parse(&kind).ok_or(ApiError::Internal("stored notification kind".into()))?;
        let destination = conn
            .query_one_raw(sql(
                "SELECT kind, user_id, url_ciphertext, secret_ciphertext FROM notification_destinations WHERE id = ?",
                vec![destination_id.clone().into()],
            ))
            .await?
            .map(|d| -> ApiResult<Destination> {
                let kind: String = d.try_get("", "kind")?;
                Ok(match kind.as_str() {
                    "email" => Destination::Email { user: UserId(d.try_get("", "user_id")?) },
                    _ => Destination::Webhook {
                        url: d.try_get("", "url_ciphertext")?,
                        secret: d.try_get("", "secret_ciphertext")?,
                    },
                })
            })
            .transpose()?;
        let issue: Option<i64> = row.try_get("", "issue_id")?;
        let report: Option<String> = row.try_get("", "report_id")?;
        let subject = match (issue, report) {
            (Some(issue), _) => issue_facts(conn, issue)
                .await?
                .map_or(Subject::Missing, Subject::Issue),
            (None, Some(report)) => match report.parse::<ReportId>() {
                Ok(id) => match reports::load(conn, &id).await? {
                    Some((meta, key, evidence)) => Subject::Report {
                        meta,
                        key,
                        evidence,
                    },
                    None => Subject::Missing,
                },
                Err(()) => Subject::Missing,
            },
            (None, None) => Subject::Missing,
        };
        Ok(Claimed {
            id: row.try_get("", "id")?,
            event_id: row.try_get("", "event_id")?,
            kind,
            project: ProjectId(row.try_get("", "project_id")?),
            attempts: row.try_get::<i64>("", "attempts")? as u32,
            destination_id: destination_id
                .parse()
                .map_err(|()| ApiError::Internal("stored destination id".into()))?,
            destination,
            subject,
        })
    }

    async fn project_name(&self, org: &OrgId, project: ProjectId) -> String {
        let row = self
            .0
            .control
            .query_one_raw(sql(
                "SELECT name FROM projects WHERE id = ? AND org_id = ?",
                vec![project.0.into(), org.as_str().into()],
            ))
            .await;
        match row {
            Ok(Some(row)) => row.try_get("", "name").unwrap_or_default(),
            _ => format!("Project {}", project.0),
        }
    }

    async fn deliver(&self, org: &OrgId, item: &Claimed) -> Outcome {
        let Some(destination) = &item.destination else {
            return Outcome::Permanent("destination_removed");
        };
        let document = match &item.subject {
            Subject::Missing => return Outcome::Permanent("subject_missing"),
            Subject::Issue(_) => None,
            Subject::Report { meta, key, .. } => {
                match reports::read_document(&self.0.store, org, meta, key).await {
                    Ok(document) => Some(document),
                    Err(ApiError::Unavailable("report_body_missing")) => {
                        return Outcome::Permanent("report_missing")
                    }
                    Err(_) => return Outcome::Retryable("store_unavailable"),
                }
            }
        };
        let links = self.links(org, item.project);
        match destination {
            Destination::Email { user } => {
                let Some(mailer) = &self.0.mailer else {
                    return Outcome::NotConfigured;
                };
                let recipient = self
                    .0
                    .control
                    .query_one_raw(sql(
                        "SELECT u.email FROM users u JOIN memberships m ON m.user_id = u.id
                         WHERE m.org_id = ? AND u.id = ?",
                        vec![org.as_str().into(), user.0.into()],
                    ))
                    .await;
                let email: String = match recipient {
                    Ok(Some(row)) => match row.try_get("", "email") {
                        Ok(email) => email,
                        Err(_) => return Outcome::Retryable("control_unavailable"),
                    },
                    Ok(None) => return Outcome::Permanent("recipient_not_member"),
                    Err(_) => return Outcome::Retryable("control_unavailable"),
                };
                let project = self.project_name(org, item.project).await;
                let content = match (&item.subject, &document) {
                    (Subject::Issue(issue), _) => issue_email(item.kind, &project, issue, &links),
                    (Subject::Report { evidence, .. }, Some(document)) => {
                        report_email(&project, document, evidence, &links)
                    }
                    _ => return Outcome::Permanent("subject_missing"),
                };
                let domain = mailer.from.email.domain().to_owned();
                let message_id = format!(
                    "<{}.{}@{domain}>",
                    item.event_id,
                    item.destination_id.as_str()
                );
                mailer.send(&email, &content, Some(message_id)).await
            }
            Destination::Webhook { url, secret } => {
                let key = &self.0.key;
                let id = &item.destination_id;
                let (Some(url), Some(secret)) = (
                    key.open(org, id, CipherField::Url, url),
                    key.open(org, id, CipherField::Secret, secret),
                ) else {
                    return Outcome::Permanent("undecryptable");
                };
                let Ok(url) = parse_webhook_url(url.expose_secret(), &self.0.egress) else {
                    bump(&self.0.metrics.unsafe_destinations, 1);
                    return Outcome::Permanent("unsafe_destination");
                };
                let data = match (&item.subject, &document) {
                    (Subject::Issue(issue), _) => json!({ "issue": issue_json(issue, &links) }),
                    (Subject::Report { meta, .. }, Some(document)) => {
                        json!({ "report": report_json(meta, document, &links) })
                    }
                    _ => return Outcome::Permanent("subject_missing"),
                };
                let mut body = json!({
                    "id": item.event_id,
                    "type": item.kind.webhook_type(),
                    "created_at": now_secs(),
                    "org_id": org,
                    "project_id": item.project,
                });
                if let (Some(body), serde_json::Value::Object(data)) = (body.as_object_mut(), data)
                {
                    body.extend(data);
                }
                let body = serde_json::to_vec(&body).expect("JSON value serializes");
                self.post(&url, &secret, &item.event_id, body).await
            }
        }
    }

    async fn resolve_validated_destination(&self, url: &Url) -> Result<Vec<SocketAddr>, Outcome> {
        let port = url
            .port_or_known_default()
            .ok_or(Outcome::Permanent("invalid_destination"))?;
        let timeout = Duration::from_millis(self.0.settings.resolve_timeout_ms);
        let addrs = match url.host() {
            Some(Host::Ipv4(ip)) => vec![IpAddr::V4(ip)],
            Some(Host::Ipv6(ip)) => vec![IpAddr::V6(ip)],
            Some(Host::Domain(domain)) => self.0.egress.lookup(domain, port, timeout).await?,
            None => return Err(Outcome::Permanent("invalid_destination")),
        };
        if addrs.is_empty() {
            return Err(Outcome::Retryable("dns_empty"));
        }
        if addrs.iter().any(|ip| !self.0.egress.permits(*ip)) {
            bump(&self.0.metrics.unsafe_destinations, 1);
            return Err(Outcome::Permanent("unsafe_destination"));
        }
        Ok(addrs
            .into_iter()
            .take(MAX_RESOLVED_ADDRS)
            .map(|ip| SocketAddr::new(ip, port))
            .collect())
    }

    async fn post(
        &self,
        url: &Url,
        secret: &SecretString,
        event_id: &str,
        body: Vec<u8>,
    ) -> Outcome {
        let addrs = match self.resolve_validated_destination(url).await {
            Ok(addrs) => addrs,
            Err(outcome) => return outcome,
        };
        let settings = &self.0.settings;
        let mut builder = reqwest::Client::builder()
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(Duration::from_millis(settings.connect_timeout_ms))
            .timeout(settings.attempt_timeout())
            .https_only(!self.0.egress.allows_http())
            .user_agent(USER_AGENT);
        if let Some(Host::Domain(domain)) = url.host() {
            builder = builder.resolve_to_addrs(domain, &addrs);
        }
        let Ok(client) = builder.build() else {
            return Outcome::Retryable("client_unavailable");
        };
        let timestamp = now_secs();
        let signed = format!(
            "t={timestamp},v1={}",
            signature(secret.expose_secret(), timestamp, &body)
        );
        let response = client
            .post(url.clone())
            .header(reqwest::header::CONTENT_TYPE, "application/json")
            .header("PostDeploy-Event-Id", event_id)
            .header("PostDeploy-Timestamp", timestamp.to_string())
            .header("PostDeploy-Signature", signed)
            .body(body)
            .send()
            .await;
        match response {
            Ok(response) => {
                let status = response.status();
                drop(response);
                match status.as_u16() {
                    200..=299 => Outcome::Delivered,
                    300..=399 => Outcome::Permanent("http_redirect"),
                    408 => Outcome::Retryable("http_408"),
                    429 => Outcome::Retryable("http_429"),
                    400..=499 => Outcome::Permanent("http_4xx"),
                    _ => Outcome::Retryable("http_5xx"),
                }
            }
            Err(error) if error.is_timeout() => Outcome::Retryable("timeout"),
            Err(error) if error.is_connect() => Outcome::Retryable("connect_failed"),
            Err(_) => Outcome::Retryable("transport_failed"),
        }
    }

    async fn record(
        &self,
        org: &OrgId,
        results: &[(Claimed, Outcome)],
        summary: &mut RunSummary,
    ) -> ApiResult<()> {
        let settings = &self.0.settings;
        let metrics = &self.0.metrics;
        let now = now_micros();
        let handle =
            crate::organization_lifecycle::active_tenant(&self.0.control, &self.0.tenants, org)
                .await?;
        let txn = handle.begin_with_options(immediate()).await?;
        for (item, outcome) in results {
            let exhausted = item.attempts >= settings.max_attempts;
            let (state, error, next, counter): (&str, Option<&str>, i64, Option<&str>) =
                match *outcome {
                    Outcome::Delivered => ("delivered", None, now, Some("delivered")),
                    Outcome::Retryable(code) if !exhausted => (
                        "pending",
                        Some(code),
                        now + settings.backoff_micros(item.attempts),
                        None,
                    ),
                    Outcome::Retryable(code) | Outcome::Permanent(code) => {
                        ("failed", Some(code), now, Some("failed"))
                    }
                    Outcome::NotConfigured => (
                        "not_configured",
                        Some("not_configured"),
                        now,
                        Some("not_configured"),
                    ),
                };
            let finished = (state != "pending").then_some(now);
            let updated = txn
                .execute_raw(sql(
                    "UPDATE notification_work SET state = ?, last_error = ?, next_attempt_at = ?, finished_at = ?
                     WHERE id = ? AND state = 'sending' AND attempts = ?",
                    vec![
                        state.into(),
                        error.into(),
                        next.into(),
                        finished.into(),
                        item.id.into(),
                        i64::from(item.attempts).into(),
                    ],
                ))
                .await?
                .rows_affected();
            if updated == 0 {
                continue;
            }
            let last = error.unwrap_or("delivered");
            let column = counter
                .map(|c| format!(", {c} = {c} + 1"))
                .unwrap_or_default();
            txn.execute_raw(sql(
                &format!(
                    "UPDATE notification_destinations SET last_outcome = ?, last_attempt_at = ?{column} WHERE id = ?"
                ),
                vec![last.into(), now.into(), item.destination_id.as_str().into()],
            ))
            .await?;
            match (*outcome, state) {
                (Outcome::Delivered, _) => {
                    summary.delivered += 1;
                    bump(&metrics.delivered, 1);
                }
                (_, "pending") => {
                    summary.retried += 1;
                    bump(&metrics.retried, 1);
                }
                (Outcome::NotConfigured, _) => {
                    summary.not_configured += 1;
                    bump(&metrics.not_configured, 1);
                }
                (Outcome::Retryable(_), _) => {
                    summary.failed += 1;
                    bump(&metrics.failed_exhausted, 1);
                }
                (Outcome::Permanent(_), _) => {
                    summary.failed += 1;
                    bump(&metrics.failed_permanent, 1);
                }
            }
        }
        txn.commit().await?;
        Ok(())
    }
}

#[async_trait::async_trait]
impl AccountMail for Notifications {
    fn configured(&self) -> bool {
        self.0.mailer.is_some()
    }

    async fn send(&self, message: AccountMessage) -> Result<(), MailFailure> {
        let Some(mailer) = &self.0.mailer else {
            return Err(MailFailure::NotConfigured);
        };
        let content = EmailContent {
            subject: message.subject.to_owned(),
            text: message.text().to_owned(),
            html: None,
        };
        let sent = tokio::time::timeout(
            self.0.settings.attempt_timeout(),
            mailer.send(&message.to, &content, None),
        )
        .await;
        match sent.unwrap_or(Outcome::Retryable("smtp_timeout")) {
            Outcome::Delivered => Ok(()),
            Outcome::Permanent(_) => Err(MailFailure::Rejected),
            Outcome::Retryable(_) | Outcome::NotConfigured => Err(MailFailure::Unavailable),
        }
    }
}

async fn issue_facts(conn: &impl ConnectionTrait, issue: i64) -> ApiResult<Option<IssueFacts>> {
    let row = conn
        .query_one_raw(sql(
            "SELECT id, title, culprit, level, status, environment, event_count, first_seen, last_seen
             FROM issues WHERE id = ?",
            vec![issue.into()],
        ))
        .await?;
    row.map(|row| -> ApiResult<IssueFacts> {
        Ok(IssueFacts {
            id: row.try_get("", "id")?,
            title: row.try_get("", "title")?,
            culprit: row.try_get("", "culprit")?,
            level: row.try_get("", "level")?,
            status: row.try_get("", "status")?,
            environment: row.try_get("", "environment")?,
            event_count: row.try_get("", "event_count")?,
            first_seen: row.try_get("", "first_seen")?,
            last_seen: row.try_get("", "last_seen")?,
        })
    })
    .transpose()
}

fn destination_view(row: &QueryResult) -> ApiResult<DestinationView> {
    let id: String = row.try_get("", "id")?;
    let kind: String = row.try_get("", "kind")?;
    Ok(DestinationView {
        id: id
            .parse()
            .map_err(|()| ApiError::Internal("stored destination id".into()))?,
        kind: if kind == "email" { "email" } else { "webhook" },
        events: EventKind::from_mask(row.try_get("", "events")?),
        project_id: row.try_get("", "project_id")?,
        user_id: row.try_get("", "user_id")?,
        url_hint: row.try_get("", "url_hint")?,
        created_at: row.try_get("", "created_at")?,
        delivered: row.try_get("", "delivered")?,
        failed: row.try_get("", "failed")?,
        dropped: row.try_get("", "dropped")?,
        not_configured: row.try_get("", "not_configured")?,
        last_outcome: row.try_get("", "last_outcome")?,
        last_attempt_at: row.try_get("", "last_attempt_at")?,
    })
}

#[cfg(test)]
pub(crate) mod testkit {
    use std::{
        collections::{HashMap, VecDeque},
        net::IpAddr,
        path::{Path, PathBuf},
        sync::{Arc, Mutex, RwLock},
        time::Duration,
    };

    use axum::{body::Bytes, extract::State, http::HeaderMap, http::StatusCode};
    use base64::{engine::general_purpose::STANDARD, Engine};
    use migration::MigratorTrait;
    use sea_orm::{ConnectionTrait, Database, DatabaseConnection, TransactionTrait};
    use tenant_sqlite_loco::{Config, Synchronous, TenantPools};
    use tokio::{
        io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
        net::TcpListener,
        sync::{watch, Notify},
    };

    use super::{
        secret_string, Egress, EnqueueOutcome, Notice, NotificationSettings, Notifications,
        SmtpConfig, SmtpTls,
    };
    use crate::{
        domain::{OrgId, ProjectId, Role, UserId},
        identity::access::OrgAccess,
        reports::Reports,
        runtime::sql,
        store::ObjectStore,
    };

    pub fn data_dir(name: &str) -> PathBuf {
        let root = std::env::var_os("POSTDEPLOY_TEST_DATA")
            .map(PathBuf::from)
            .unwrap_or_else(|| std::env::temp_dir().join("postdeploy-tests"));
        let dir = root.join(format!("{name}-{}", uuid::Uuid::now_v7().simple()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    pub fn settings() -> NotificationSettings {
        NotificationSettings {
            public_url: "https://postdeploy.test".to_owned(),
            backoff_base_ms: 0,
            attempt_timeout_ms: 5_000,
            ..NotificationSettings::default()
        }
    }

    #[derive(Default)]
    pub struct Options {
        pub smtp: Option<SmtpConfig>,
        pub hosts: Option<HashMap<String, IpAddr>>,
        pub settings: Option<NotificationSettings>,
        pub store: Option<ObjectStore>,
    }

    pub struct Env {
        pub dir: PathBuf,
        pub control: DatabaseConnection,
        pub pools: TenantPools,
        pub store: ObjectStore,
        pub notifications: Notifications,
        pub reports: Reports,
    }

    pub fn smtp(port: u16) -> SmtpConfig {
        SmtpConfig {
            host: "127.0.0.1".to_owned(),
            port,
            tls: SmtpTls::Plaintext,
            username: "probe".to_owned(),
            password: secret_string("probe-password".to_owned()),
            from: "PostDeploy <alerts@postdeploy.test>".to_owned(),
        }
    }

    pub async fn open(dir: &Path, options: Options) -> Env {
        let control = Database::connect(format!(
            "sqlite://{}?mode=rwc",
            dir.join("control.db").display()
        ))
        .await
        .unwrap();
        migration::ControlMigrator::up(&control, None)
            .await
            .unwrap();
        let mut config = Config::new(dir.join("tenants"));
        config.synchronous = Synchronous::Full;
        let pools = TenantPools::new::<migration::OrgMigrator>(config).unwrap();
        let store = options.store.unwrap_or_else(|| {
            ObjectStore::memory("test/", Duration::from_secs(5), Arc::default()).unwrap()
        });
        let egress = match options.hosts {
            Some(hosts) => Egress::Test(RwLock::new(hosts)),
            None => Egress::Public,
        };
        let notifications = Notifications::build(
            control.clone(),
            pools.clone(),
            store.clone(),
            &secret_string(STANDARD.encode([7u8; 32])),
            options.smtp.as_ref(),
            options.settings.unwrap_or_else(settings),
            egress,
        )
        .unwrap();
        let reports = Reports::new(
            control.clone(),
            pools.clone(),
            store.clone(),
            notifications.clone(),
        );
        Env {
            dir: dir.to_owned(),
            control,
            pools,
            store,
            notifications,
            reports,
        }
    }

    pub fn loopback(host: &str) -> Option<HashMap<String, IpAddr>> {
        Some(HashMap::from([(
            host.to_owned(),
            IpAddr::from([127, 0, 0, 1]),
        )]))
    }

    impl Env {
        pub async fn shutdown(self) {
            self.pools.registry().shutdown().await.unwrap();
            self.control.close_by_ref().await.unwrap();
        }

        pub fn set_host(&self, host: &str, ip: IpAddr) {
            let Egress::Test(hosts) = &self.notifications.0.egress else {
                panic!("test egress")
            };
            hosts.write().unwrap().insert(host.to_owned(), ip);
        }

        async fn user(&self, email: &str) -> UserId {
            let row = self
                .control
                .query_one_raw(sql(
                    "INSERT INTO users (email, password_hash, created_at) VALUES (?, 'x', 0)
                     ON CONFLICT (email) DO UPDATE SET email = excluded.email RETURNING id",
                    vec![email.into()],
                ))
                .await
                .unwrap()
                .unwrap();
            UserId(row.try_get("", "id").unwrap())
        }

        /// A new organization owned by `email`, with one project and a provisioned tenant.
        pub async fn org(&self, email: &str) -> (OrgAccess, ProjectId) {
            let user = self.user(email).await;
            let org = OrgId::generate();
            self.control
                .execute_raw(sql(
                    "INSERT INTO organizations (id, name, created_by, created_at) VALUES (?, 'Acme', ?, 0)",
                    vec![org.as_str().into(), user.0.into()],
                ))
                .await
                .unwrap();
            let access = self.join(&org, email, Role::Owner).await;
            let project = self.project(&org, "checkout").await;
            drop(
                self.pools
                    .registry()
                    .provision(&org.tenant())
                    .await
                    .unwrap(),
            );
            (access, project)
        }

        pub async fn join(&self, org: &OrgId, email: &str, role: Role) -> OrgAccess {
            let user = self.user(email).await;
            self.control
                .execute_raw(sql(
                    "INSERT INTO memberships (org_id, user_id, role, created_at) VALUES (?, ?, ?, 0)",
                    vec![org.as_str().into(), user.0.into(), role.as_str().into()],
                ))
                .await
                .unwrap();
            OrgAccess {
                user,
                org: org.clone(),
                role,
            }
        }

        pub async fn project(&self, org: &OrgId, name: &str) -> ProjectId {
            let row = self
                .control
                .query_one_raw(sql(
                    "INSERT INTO projects (org_id, name, created_at) VALUES (?, ?, 0) RETURNING id",
                    vec![org.as_str().into(), name.into()],
                ))
                .await
                .unwrap()
                .unwrap();
            ProjectId(row.try_get("", "id").unwrap())
        }

        pub async fn issue(
            &self,
            org: &OrgId,
            project: ProjectId,
            title: &str,
            events: i64,
        ) -> i64 {
            let handle = self
                .pools
                .registry()
                .open_existing(&org.tenant())
                .await
                .unwrap();
            let row = handle
                .query_one_raw(sql(
                    "INSERT INTO issues (project_id, environment, fingerprint, title, culprit, level, status,
                        first_seen, last_seen, event_count) VALUES (?, 'production', ?, ?, 'src/cart.ts:total',
                        'error', 'open', 1760000000000000, 1760003600000000, ?) RETURNING id",
                    vec![project.0.into(), uuid::Uuid::now_v7().to_string().into(), title.into(), events.into()],
                ))
                .await
                .unwrap()
                .unwrap();
            row.try_get("", "id").unwrap()
        }

        pub async fn event(&self, org: &OrgId, project: ProjectId, issue: i64, event_id: &str) {
            self.event_from(org, project, issue, 1, event_id).await;
        }

        pub async fn event_from(
            &self,
            org: &OrgId,
            project: ProjectId,
            issue: i64,
            source: i64,
            event_id: &str,
        ) {
            let handle = self
                .pools
                .registry()
                .open_existing(&org.tenant())
                .await
                .unwrap();
            handle
                .execute_raw(sql(
                    "INSERT INTO events (issue_id, project_id, source_id, event_id, level, occurred_at, received_at,
                        payload_key, payload_bytes) VALUES (?, ?, ?, ?, 'error', 0, 0, 'errors/x', 1)",
                    vec![issue.into(), project.0.into(), source.into(), event_id.into()],
                ))
                .await
                .unwrap();
        }

        pub async fn log_object(&self, org: &OrgId, project: ProjectId, entries: i64) -> i64 {
            let handle = self
                .pools
                .registry()
                .open_existing(&org.tenant())
                .await
                .unwrap();
            let row = handle
                .query_one_raw(sql(
                    "INSERT INTO log_objects (object_key, project_id, source_id, environment, min_ts, max_ts,
                        received_at, entry_count, level_mask, trace_bloom, raw_bytes, stored_bytes, adopted,
                        format, state, opened_at, archived_at, usage_day, pending_bytes)
                     VALUES (?, 0, 0, '', 1760000000000000, 1760000060000000, 0, ?, 8, x'00', 10, 10, 0,
                        2, 'archived', 0, 0, '20251009', 0)
                     RETURNING id",
                    vec![uuid::Uuid::now_v7().to_string().into(), entries.into()],
                ))
                .await
                .unwrap()
                .unwrap();
            let id: i64 = row.try_get("", "id").unwrap();
            handle
                .execute_raw(sql(
                    "INSERT INTO log_entry_runs (object_id, first_entry, last_entry, project_id, source_id,
                        environment, min_ts, max_ts, level_mask)
                     VALUES (?, 0, ?, ?, 1, 'production', 1760000000000000, 1760000060000000, 8)",
                    vec![id.into(), (entries - 1).into(), project.0.into()],
                ))
                .await
                .unwrap();
            id
        }

        pub async fn notify(&self, org: &OrgId, notice: &Notice) -> EnqueueOutcome {
            let handle = self
                .pools
                .registry()
                .open_existing(&org.tenant())
                .await
                .unwrap();
            let txn = handle.begin().await.unwrap();
            let outcome = self.notifications.enqueue(&txn, org, notice).await;
            txn.commit().await.unwrap();
            outcome
        }

        /// `(state, attempts, last_error)` for every work item, oldest first.
        pub async fn work(&self, org: &OrgId) -> Vec<(String, i64, Option<String>)> {
            let handle = self
                .pools
                .registry()
                .open_existing(&org.tenant())
                .await
                .unwrap();
            handle
                .query_all_raw(sql(
                    "SELECT state, attempts, last_error FROM notification_work ORDER BY id",
                    vec![],
                ))
                .await
                .unwrap()
                .iter()
                .map(|row| {
                    (
                        row.try_get("", "state").unwrap(),
                        row.try_get("", "attempts").unwrap(),
                        row.try_get("", "last_error").unwrap(),
                    )
                })
                .collect()
        }

        /// Whether any file under this test's directory (SQLite, WAL, SHM) contains `needle`.
        pub fn files_contain(&self, needle: &[u8]) -> bool {
            fn walk(dir: &Path, needle: &[u8]) -> bool {
                std::fs::read_dir(dir).unwrap().any(|entry| {
                    let path = entry.unwrap().path();
                    if path.is_dir() {
                        walk(&path, needle)
                    } else {
                        let bytes = std::fs::read(&path).unwrap();
                        bytes.windows(needle.len()).any(|w| w == needle)
                    }
                })
            }
            walk(&self.dir, needle)
        }
    }

    pub struct Captured {
        pub headers: HeaderMap,
        pub body: Vec<u8>,
    }

    /// Local HTTP receiver. Requests stay in memory only.
    #[derive(Clone)]
    pub struct HttpReceiver {
        pub port: u16,
        pub requests: Arc<Mutex<Vec<Captured>>>,
        statuses: Arc<Mutex<VecDeque<u16>>>,
        hold: Arc<watch::Sender<bool>>,
        pub arrived: Arc<Notify>,
    }

    async fn receive(
        State(receiver): State<HttpReceiver>,
        headers: HeaderMap,
        body: Bytes,
    ) -> StatusCode {
        receiver.requests.lock().unwrap().push(Captured {
            headers,
            body: body.to_vec(),
        });
        receiver.arrived.notify_one();
        let mut held = receiver.hold.subscribe();
        let _ = held.wait_for(|hold| !*hold).await;
        let status = receiver.statuses.lock().unwrap().pop_front().unwrap_or(200);
        StatusCode::from_u16(status).unwrap()
    }

    impl HttpReceiver {
        pub async fn start() -> Self {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let receiver = Self {
                port: listener.local_addr().unwrap().port(),
                requests: Arc::default(),
                statuses: Arc::default(),
                hold: Arc::new(watch::channel(false).0),
                arrived: Arc::default(),
            };
            let router = axum::Router::new()
                .fallback(receive)
                .with_state(receiver.clone());
            tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
            receiver
        }

        pub fn respond(&self, statuses: &[u16]) {
            self.statuses.lock().unwrap().extend(statuses);
        }

        pub fn hold(&self, hold: bool) {
            self.hold.send_replace(hold);
        }

        pub fn count(&self) -> usize {
            self.requests.lock().unwrap().len()
        }
    }

    /// A webhook receiver that does what the delivery contract asks of
    /// customers: it checks the HMAC over `<timestamp>.<raw body>`, refuses
    /// timestamps outside its tolerance, and records each processed event ID
    /// in a file before acting, so a replay is acknowledged without a second
    /// effect, also after a restart. The event ID comes from the signed body.
    #[derive(Clone)]
    pub struct VerifyingReceiver {
        pub port: u16,
        secret: Arc<Mutex<String>>,
        seen_file: PathBuf,
        tolerance_secs: i64,
        clock_offset_secs: Arc<std::sync::atomic::AtomicI64>,
        dedupe: Arc<Mutex<()>>,
        outages: Arc<Mutex<VecDeque<u16>>>,
        pub requests: Arc<Mutex<Vec<Captured>>>,
        pub verdicts: Arc<Mutex<Vec<&'static str>>>,
        pub processed: Arc<Mutex<Vec<String>>>,
    }

    impl VerifyingReceiver {
        fn verify(&self, headers: &HeaderMap, body: &[u8]) -> Result<String, &'static str> {
            let header = |name: &str| headers.get(name).and_then(|v| v.to_str().ok());
            let signed = header("postdeploy-signature").ok_or("invalid_signature")?;
            let (timestamp, signature) = signed
                .strip_prefix("t=")
                .and_then(|rest| rest.split_once(",v1="))
                .ok_or("invalid_signature")?;
            let signature = hex::decode(signature).map_err(|_| "invalid_signature")?;
            let mut mac = <hmac::Hmac<sha2::Sha256> as hmac::Mac>::new_from_slice(
                self.secret.lock().unwrap().as_bytes(),
            )
            .expect("HMAC accepts any key length");
            hmac::Mac::update(&mut mac, timestamp.as_bytes());
            hmac::Mac::update(&mut mac, b".");
            hmac::Mac::update(&mut mac, body);
            hmac::Mac::verify_slice(mac, &signature).map_err(|_| "invalid_signature")?;
            let sent: i64 = timestamp.parse().map_err(|_| "invalid_signature")?;
            let now = crate::domain::now_secs()
                + self
                    .clock_offset_secs
                    .load(std::sync::atomic::Ordering::SeqCst);
            if (now - sent).abs() > self.tolerance_secs {
                return Err("expired_timestamp");
            }
            let event: serde_json::Value =
                serde_json::from_slice(body).map_err(|_| "invalid_body")?;
            event["id"]
                .as_str()
                .map(str::to_owned)
                .ok_or("invalid_body")
        }

        fn seen(&self, id: &str) -> bool {
            std::fs::read_to_string(&self.seen_file)
                .unwrap_or_default()
                .lines()
                .any(|line| line == id)
        }

        fn remember(&self, id: &str) {
            use std::io::Write;
            let mut file = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&self.seen_file)
                .unwrap();
            writeln!(file, "{id}").unwrap();
            file.sync_all().unwrap();
        }

        pub async fn start(seen_file: PathBuf, tolerance_secs: i64) -> Self {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let receiver = Self {
                port: listener.local_addr().unwrap().port(),
                secret: Arc::default(),
                seen_file,
                tolerance_secs,
                clock_offset_secs: Arc::default(),
                dedupe: Arc::default(),
                outages: Arc::default(),
                requests: Arc::default(),
                verdicts: Arc::default(),
                processed: Arc::default(),
            };
            let router = axum::Router::new()
                .fallback(verifying_receive)
                .with_state(receiver.clone());
            tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
            receiver
        }

        pub fn set_secret(&self, secret: &str) {
            *self.secret.lock().unwrap() = secret.to_owned();
        }

        pub fn advance_clock(&self, secs: i64) {
            self.clock_offset_secs
                .store(secs, std::sync::atomic::Ordering::SeqCst);
        }

        pub fn outage(&self, statuses: &[u16]) {
            self.outages.lock().unwrap().extend(statuses);
        }

        pub fn verdicts(&self) -> Vec<&'static str> {
            self.verdicts.lock().unwrap().clone()
        }
    }

    async fn verifying_receive(
        State(receiver): State<VerifyingReceiver>,
        headers: HeaderMap,
        body: Bytes,
    ) -> StatusCode {
        receiver.requests.lock().unwrap().push(Captured {
            headers: headers.clone(),
            body: body.to_vec(),
        });
        let outage = receiver.outages.lock().unwrap().pop_front();
        let (verdict, status) = if let Some(status) = outage {
            ("unavailable", status)
        } else {
            match receiver.verify(&headers, &body) {
                Err(reason) => (reason, 401),
                Ok(id) => {
                    let _dedupe = receiver.dedupe.lock().unwrap();
                    if receiver.seen(&id) {
                        ("duplicate", 200)
                    } else {
                        receiver.remember(&id);
                        receiver.processed.lock().unwrap().push(id);
                        ("processed", 200)
                    }
                }
            }
        };
        receiver.verdicts.lock().unwrap().push(verdict);
        StatusCode::from_u16(status).unwrap()
    }

    /// Undoes quoted-printable soft breaks and `=XX` escapes, as a mail client would.
    fn decode_quoted_printable(raw: &str) -> String {
        let bytes = raw.as_bytes();
        let mut out = Vec::with_capacity(bytes.len());
        let mut i = 0;
        while i < bytes.len() {
            match (bytes[i], bytes.get(i + 1), bytes.get(i + 2)) {
                (b'=', Some(b'\n'), _) => i += 2,
                (b'=', Some(a), Some(b)) if a.is_ascii_hexdigit() && b.is_ascii_hexdigit() => {
                    out.push(
                        u8::from_str_radix(std::str::from_utf8(&[*a, *b]).unwrap(), 16).unwrap(),
                    );
                    i += 3;
                }
                (byte, _, _) => {
                    out.push(byte);
                    i += 1;
                }
            }
        }
        String::from_utf8_lossy(&out).into_owned()
    }

    /// Minimal local SMTP receiver. Messages stay in memory only.
    #[derive(Clone)]
    pub struct SmtpReceiver {
        pub port: u16,
        pub messages: Arc<Mutex<Vec<String>>>,
        mail_replies: Arc<Mutex<VecDeque<&'static str>>>,
    }

    impl SmtpReceiver {
        pub async fn start() -> Self {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let receiver = Self {
                port: listener.local_addr().unwrap().port(),
                messages: Arc::default(),
                mail_replies: Arc::default(),
            };
            let server = receiver.clone();
            tokio::spawn(async move {
                loop {
                    let (socket, _) = listener.accept().await.unwrap();
                    tokio::spawn(server.clone().session(socket));
                }
            });
            receiver
        }

        /// Replies used for upcoming `MAIL FROM` commands instead of `250`.
        pub fn reject_mail(&self, replies: &[&'static str]) {
            self.mail_replies.lock().unwrap().extend(replies);
        }

        async fn session(self, socket: tokio::net::TcpStream) {
            let (read, mut write) = socket.into_split();
            let mut lines = BufReader::new(read).lines();
            write.write_all(b"220 probe ESMTP\r\n").await.unwrap();
            while let Ok(Some(line)) = lines.next_line().await {
                let verb = line.split(' ').next().unwrap_or("").to_ascii_uppercase();
                let reply = match verb.as_str() {
                    "EHLO" | "HELO" => {
                        "250-probe\r\n250-AUTH PLAIN LOGIN\r\n250 8BITMIME".to_owned()
                    }
                    "AUTH" => "235 2.7.0 accepted".to_owned(),
                    "MAIL" => self
                        .mail_replies
                        .lock()
                        .unwrap()
                        .pop_front()
                        .unwrap_or("250 ok")
                        .to_owned(),
                    "RCPT" | "RSET" | "NOOP" => "250 ok".to_owned(),
                    "DATA" => {
                        write.write_all(b"354 go\r\n").await.unwrap();
                        let mut message = String::new();
                        while let Ok(Some(line)) = lines.next_line().await {
                            if line == "." {
                                break;
                            }
                            message.push_str(&line);
                            message.push('\n');
                        }
                        self.messages
                            .lock()
                            .unwrap()
                            .push(decode_quoted_printable(&message));
                        "250 queued".to_owned()
                    }
                    "QUIT" => {
                        let _ = write.write_all(b"221 bye\r\n").await;
                        return;
                    }
                    _ => "502 unsupported".to_owned(),
                };
                if write
                    .write_all(format!("{reply}\r\n").as_bytes())
                    .await
                    .is_err()
                {
                    return;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use std::{net::IpAddr, time::Duration};

    use hmac::{Hmac, Mac};
    use sea_orm::{ConnectionTrait, TransactionTrait};
    use serde_json::{json, Value};
    use sha2::Sha256;

    use super::{testkit::*, *};
    use crate::domain::Role;

    fn webhook(url: String, events: &[EventKind]) -> WebhookInput {
        WebhookInput {
            url,
            events: events.to_vec(),
            project_id: None,
        }
    }

    const ALL: [EventKind; 3] = EventKind::ALL;

    #[tokio::test]
    async fn deleting_organization_is_refused_without_reopening_its_database() {
        let env = open(
            &data_dir("notification-deleting-organization"),
            Options::default(),
        )
        .await;
        let (owner, project) = env.org("deleting-notifications@example.test").await;
        env.notifications
            .subscribe_email(
                &owner,
                EmailSubscription {
                    events: ALL.to_vec(),
                    project_id: None,
                },
            )
            .await
            .unwrap();
        let issue = env.issue(&owner.org, project, "Deletion fixture", 1).await;
        let queued = env
            .notify(&owner.org, &Notice::NewIssue { project, issue })
            .await;
        assert_eq!(queued.queued, 1);
        env.pools
            .registry()
            .evict(&owner.org.tenant())
            .await
            .unwrap();
        env.control
            .execute_raw(sql(
                "UPDATE organizations SET lifecycle = 'deleting' WHERE id = ?",
                vec![owner.org.as_str().into()],
            ))
            .await
            .unwrap();
        assert!(matches!(
            env.notifications.destinations(&owner).await,
            Err(ApiError::NotFound)
        ));
        assert!(matches!(
            env.notifications.run_pending_for_org(&owner.org).await,
            Err(ApiError::NotFound)
        ));
        assert_eq!(
            env.notifications.metrics().attempts.load(Ordering::Relaxed),
            0
        );
        assert_eq!(env.pools.registry().stats().await.retained_pools, 0);
        env.shutdown().await;
    }

    #[test]
    fn signature_matches_an_independent_hmac() {
        assert_eq!(
            signature("whsec_test", 1_700_000_000, br#"{"id":"evt_1"}"#),
            "c89214b5b5da833daed6f0b8c5bb6bd58cea9022bd80ccc78230f3942d632925"
        );
    }

    #[test]
    fn address_policy_admits_only_public_unicast() {
        let cases = [
            ("93.184.215.14", true),
            ("1.1.1.1", true),
            ("2606:4700:4700::1111", true),
            ("127.0.0.1", false),
            ("10.1.2.3", false),
            ("172.16.0.1", false),
            ("192.168.1.1", false),
            ("100.64.0.1", false),
            ("169.254.169.254", false),
            ("0.0.0.0", false),
            ("192.0.2.10", false),
            ("198.18.0.1", false),
            ("224.0.0.1", false),
            ("240.0.0.1", false),
            ("255.255.255.255", false),
            ("::1", false),
            ("::", false),
            ("fe80::1", false),
            ("fc00::1", false),
            ("ff02::1", false),
            ("::ffff:127.0.0.1", false),
            ("::ffff:8.8.8.8", true),
            ("64:ff9b::a9fe:a9fe", false),
            ("2001:db8::1", false),
            ("2002:7f00:1::", false),
            ("2001::1", false),
        ];
        for (ip, expected) in cases {
            assert_eq!(is_public(ip.parse().unwrap()), expected, "{ip}");
        }
    }

    #[test]
    fn webhook_urls_are_checked_without_contacting_them() {
        let public = Egress::Public;
        let check = |url: &str| parse_webhook_url(url, &public).map(|u| u.to_string());
        assert_eq!(
            check("https://hooks.example.com/in?token=abc").unwrap(),
            "https://hooks.example.com/in?token=abc"
        );
        for url in [
            "http://hooks.example.com/in",
            "ftp://hooks.example.com/in",
            "https://user:pw@hooks.example.com/in",
            "https://user@hooks.example.com/in",
            "https://127.0.0.1/in",
            "https://[::1]/in",
            "https://10.1.2.3/in",
            "https://169.254.169.254/latest/meta-data",
            "https://[::ffff:192.168.0.1]/in",
            "https://localhost:8080/in",
            "https://api.localhost/in",
        ] {
            assert_eq!(check(url), Err("unsafe_webhook_url"), "{url}");
        }
        assert_eq!(
            check("https://hooks.example.com/in#x"),
            Err("invalid_webhook_url")
        );
        assert_eq!(check("not a url"), Err("invalid_webhook_url"));
        let url = Url::parse("https://hooks.example.com:8443/secret/path?token=abc").unwrap();
        assert_eq!(url_hint(&url), "https://hooks.example.com:8443/…");
    }

    #[test]
    fn ciphertexts_open_only_for_their_organization_and_field() {
        let key = DataKey::from_base64(&secret_string(STANDARD.encode([9u8; 32]))).unwrap();
        let org = OrgId::generate();
        let destination = DestinationId::generate();
        let sealed = key.seal(
            &org,
            &destination,
            CipherField::Url,
            b"https://hooks.example.com/?token=t",
        );
        let opened = key
            .open(&org, &destination, CipherField::Url, &sealed)
            .unwrap();
        assert_eq!(opened.expose_secret(), "https://hooks.example.com/?token=t");
        assert!(key
            .open(&OrgId::generate(), &destination, CipherField::Url, &sealed)
            .is_none());
        assert!(key
            .open(&org, &destination, CipherField::Secret, &sealed)
            .is_none());
        assert!(DataKey::from_base64(&secret_string(STANDARD.encode([1u8; 16]))).is_err());
    }

    #[tokio::test]
    async fn webhook_is_signed_pinned_and_enqueued_once() {
        let receiver = HttpReceiver::start().await;
        let env = open(
            &data_dir("webhook-signed"),
            Options {
                hosts: loopback("hooks.test"),
                ..Options::default()
            },
        )
        .await;
        let (owner, project) = env.org("owner@example.test").await;
        let created = env
            .notifications
            .create_webhook(
                &owner,
                webhook(
                    format!("http://hooks.test:{}/in?token=supersecret", receiver.port),
                    &ALL,
                ),
            )
            .await
            .unwrap();
        let secret = created.signing_secret.expose_secret().to_owned();
        assert!(
            secret.starts_with("whsec_") && secret.len() == 49,
            "{}",
            secret.len()
        );
        let issue = env
            .issue(&owner.org, project, "TypeError: cart is undefined", 1)
            .await;
        let notice = Notice::NewIssue { project, issue };

        let first = env.notify(&owner.org, &notice).await;
        let second = env.notify(&owner.org, &notice).await;
        assert_eq!(
            first,
            EnqueueOutcome {
                destinations: 1,
                queued: 1,
                ..EnqueueOutcome::default()
            }
        );
        assert_eq!(
            second,
            EnqueueOutcome {
                destinations: 1,
                duplicate: 1,
                ..EnqueueOutcome::default()
            }
        );

        let summary = env
            .notifications
            .run_pending_for_org(&owner.org)
            .await
            .unwrap();
        assert_eq!((summary.claimed, summary.delivered), (1, 1));
        assert_eq!(
            env.notifications
                .run_pending_for_org(&owner.org)
                .await
                .unwrap()
                .claimed,
            0
        );
        assert_eq!(receiver.count(), 1);

        let request = receiver.requests.lock().unwrap().remove(0);
        let header = |name: &str| {
            request
                .headers
                .get(name)
                .unwrap()
                .to_str()
                .unwrap()
                .to_owned()
        };
        let timestamp = header("postdeploy-timestamp");
        let mut mac = <Hmac<Sha256> as Mac>::new_from_slice(secret.as_bytes()).unwrap();
        mac.update(format!("{timestamp}.").as_bytes());
        mac.update(&request.body);
        let expected = hex::encode(mac.finalize().into_bytes());
        assert_eq!(
            header("postdeploy-signature"),
            format!("t={timestamp},v1={expected}")
        );
        let body: Value = serde_json::from_slice(&request.body).unwrap();
        assert_eq!(body["id"], json!(header("postdeploy-event-id")));
        assert_eq!(body["id"], json!(notice.event_id(&owner.org)));
        assert_eq!(body["type"], "issue.new");
        assert_eq!(body["issue"]["title"], "TypeError: cart is undefined");
        assert_eq!(
            body["issue"]["url"],
            json!(format!(
                "https://postdeploy.test/dashboard/orgs/{}/projects/{}/observe/issues/{issue}",
                owner.org, project.0
            ))
        );

        let views = env.notifications.destinations(&owner).await.unwrap();
        assert_eq!(
            views[0].url_hint.as_deref(),
            Some(format!("http://hooks.test:{}/…", receiver.port).as_str())
        );
        assert_eq!(
            (views[0].delivered, views[0].last_outcome.as_deref()),
            (1, Some("delivered"))
        );
        assert!(
            !env.files_contain(b"supersecret"),
            "webhook URL is encrypted at rest"
        );
        assert!(
            !env.files_contain(secret.as_bytes()),
            "signing secret is encrypted at rest"
        );
        assert!(
            !env.files_contain(b"cart is undefined\",\"level"),
            "no message body in SQLite"
        );
        env.shutdown().await;
    }

    async fn replay(port: u16, request: &Captured, body: &[u8]) -> u16 {
        let mut post = reqwest::Client::new().post(format!("http://127.0.0.1:{port}/in"));
        for name in [
            "content-type",
            "postdeploy-event-id",
            "postdeploy-timestamp",
            "postdeploy-signature",
        ] {
            post = post.header(name, request.headers.get(name).unwrap().to_str().unwrap());
        }
        post.body(body.to_vec())
            .send()
            .await
            .unwrap()
            .status()
            .as_u16()
    }

    #[tokio::test]
    async fn a_verifying_receiver_processes_each_event_once_and_rejects_tampering_expiry_and_replay(
    ) {
        let dir = data_dir("webhook-verifying-receiver");
        let seen = dir.join("receiver-seen-event-ids");
        let receiver = VerifyingReceiver::start(seen.clone(), 300).await;
        let env = open(
            &dir,
            Options {
                hosts: loopback("hooks.test"),
                ..Options::default()
            },
        )
        .await;
        let (owner, project) = env.org("owner@example.test").await;
        let created = env
            .notifications
            .create_webhook(
                &owner,
                webhook(format!("http://hooks.test:{}/in", receiver.port), &ALL),
            )
            .await
            .unwrap();
        receiver.set_secret(created.signing_secret.expose_secret());
        let issue = env.issue(&owner.org, project, "Checkout failed", 1).await;
        let notice = Notice::NewIssue { project, issue };
        let event_id = notice.event_id(&owner.org);

        receiver.outage(&[503]);
        env.notify(&owner.org, &notice).await;
        let first = env
            .notifications
            .run_pending_for_org(&owner.org)
            .await
            .unwrap();
        assert_eq!((first.claimed, first.retried), (1, 1));
        tokio::time::sleep(Duration::from_millis(1_100)).await;
        let second = env
            .notifications
            .run_pending_for_org(&owner.org)
            .await
            .unwrap();
        assert_eq!((second.claimed, second.delivered), (1, 1));
        assert_eq!(receiver.verdicts(), ["unavailable", "processed"]);
        assert_eq!(
            *receiver.processed.lock().unwrap(),
            std::slice::from_ref(&event_id)
        );

        let (attempts, delivered) = {
            let mut requests = receiver.requests.lock().unwrap();
            let header =
                |request: &Captured, name: &str| request.headers[name].to_str().unwrap().to_owned();
            let attempts: Vec<(String, String, String, Vec<u8>)> = requests
                .iter()
                .map(|r| {
                    (
                        header(r, "postdeploy-event-id"),
                        header(r, "postdeploy-timestamp"),
                        header(r, "postdeploy-signature"),
                        r.body.clone(),
                    )
                })
                .collect();
            (attempts, requests.remove(1))
        };
        assert_eq!(
            (attempts[0].0.as_str(), attempts[1].0.as_str()),
            (event_id.as_str(), event_id.as_str()),
            "a retry keeps the event ID"
        );
        let body_ids: Vec<Value> = attempts
            .iter()
            .map(|attempt| serde_json::from_slice::<Value>(&attempt.3).unwrap()["id"].clone())
            .collect();
        assert_eq!(body_ids, [json!(event_id), json!(event_id)]);
        assert_ne!(attempts[0].1, attempts[1].1, "a retry has a new timestamp");
        assert_ne!(attempts[0].2, attempts[1].2, "a retry has a new signature");

        assert_eq!(
            replay(receiver.port, &delivered, &delivered.body).await,
            200
        );
        let mut tampered: Value = serde_json::from_slice(&delivered.body).unwrap();
        tampered["issue"]["title"] = json!("Checkout succeeded");
        assert_eq!(
            replay(
                receiver.port,
                &delivered,
                &serde_json::to_vec(&tampered).unwrap()
            )
            .await,
            401
        );
        receiver.advance_clock(301);
        assert_eq!(
            replay(receiver.port, &delivered, &delivered.body).await,
            401
        );
        assert_eq!(
            receiver.verdicts(),
            [
                "unavailable",
                "processed",
                "duplicate",
                "invalid_signature",
                "expired_timestamp"
            ]
        );

        let restarted = VerifyingReceiver::start(seen, 300).await;
        restarted.set_secret(created.signing_secret.expose_secret());
        assert_eq!(
            replay(restarted.port, &delivered, &delivered.body).await,
            200
        );
        assert_eq!(restarted.verdicts(), ["duplicate"]);
        assert_eq!(*receiver.processed.lock().unwrap(), [event_id]);
        assert!(restarted.processed.lock().unwrap().is_empty());
        env.shutdown().await;
    }

    #[tokio::test]
    async fn retries_are_bounded_and_failures_are_counted() {
        let receiver = HttpReceiver::start().await;
        let settings = NotificationSettings {
            max_attempts: 3,
            ..testkit::settings()
        };
        let env = open(
            &data_dir("webhook-retries"),
            Options {
                hosts: loopback("hooks.test"),
                settings: Some(settings),
                ..Options::default()
            },
        )
        .await;
        let (owner, project) = env.org("owner@example.test").await;
        env.notifications
            .create_webhook(
                &owner,
                webhook(format!("http://hooks.test:{}/in", receiver.port), &ALL),
            )
            .await
            .unwrap();
        let issue = env.issue(&owner.org, project, "Timeout", 1).await;
        let run = || env.notifications.run_pending_for_org(&owner.org);

        receiver.respond(&[500, 500, 200]);
        env.notify(&owner.org, &Notice::NewIssue { project, issue })
            .await;
        assert_eq!(run().await.unwrap().retried, 1);
        assert_eq!(run().await.unwrap().retried, 1);
        assert_eq!(run().await.unwrap().delivered, 1);
        assert_eq!(
            env.work(&owner.org).await,
            vec![("delivered".to_owned(), 3, None)]
        );

        receiver.respond(&[503, 503, 503]);
        env.notify(
            &owner.org,
            &Notice::Regression {
                project,
                issue,
                at: 1,
            },
        )
        .await;
        run().await.unwrap();
        run().await.unwrap();
        assert_eq!(run().await.unwrap().failed, 1);
        assert_eq!(run().await.unwrap().claimed, 0);

        receiver.respond(&[400]);
        env.notify(
            &owner.org,
            &Notice::Regression {
                project,
                issue,
                at: 2,
            },
        )
        .await;
        assert_eq!(run().await.unwrap().failed, 1);

        assert_eq!(
            env.work(&owner.org).await,
            vec![
                ("delivered".to_owned(), 3, None),
                ("failed".to_owned(), 3, Some("http_5xx".to_owned())),
                ("failed".to_owned(), 1, Some("http_4xx".to_owned())),
            ]
        );
        assert_eq!(receiver.count(), 7);
        let metrics = env.notifications.metrics();
        let read = |c: &AtomicU64| c.load(Ordering::Relaxed);
        assert_eq!(
            (
                read(&metrics.delivered),
                read(&metrics.retried),
                read(&metrics.failed_exhausted),
                read(&metrics.failed_permanent)
            ),
            (1, 4, 1, 1)
        );
        let view = &env.notifications.destinations(&owner).await.unwrap()[0];
        assert_eq!(
            (view.delivered, view.failed, view.last_outcome.as_deref()),
            (1, 2, Some("http_4xx"))
        );
        env.shutdown().await;
    }

    #[tokio::test]
    async fn pending_and_interrupted_work_resumes_after_restart() {
        let receiver = HttpReceiver::start().await;
        let dir = data_dir("webhook-restart");
        let quick_lease = || NotificationSettings {
            lease_ms: 0,
            ..testkit::settings()
        };
        let env = open(
            &dir,
            Options {
                hosts: loopback("hooks.test"),
                settings: Some(quick_lease()),
                ..Options::default()
            },
        )
        .await;
        let (owner, project) = env.org("owner@example.test").await;
        env.notifications
            .create_webhook(
                &owner,
                webhook(format!("http://hooks.test:{}/in", receiver.port), &ALL),
            )
            .await
            .unwrap();
        let first = env.issue(&owner.org, project, "First", 1).await;
        let second = env.issue(&owner.org, project, "Second", 1).await;
        env.notify(
            &owner.org,
            &Notice::NewIssue {
                project,
                issue: first,
            },
        )
        .await;

        receiver.hold(true);
        let notifications = env.notifications.clone();
        let org = owner.org.clone();
        let interrupted =
            tokio::spawn(async move { notifications.run_pending_for_org(&org).await });
        tokio::time::timeout(Duration::from_secs(5), receiver.arrived.notified())
            .await
            .unwrap();
        interrupted.abort();
        assert!(interrupted.await.unwrap_err().is_cancelled());
        env.notify(
            &owner.org,
            &Notice::NewIssue {
                project,
                issue: second,
            },
        )
        .await;
        assert_eq!(
            env.work(&owner.org).await,
            vec![
                ("sending".to_owned(), 1, None),
                ("pending".to_owned(), 0, None)
            ]
        );
        env.shutdown().await;
        receiver.hold(false);

        let env = open(
            &dir,
            Options {
                hosts: loopback("hooks.test"),
                settings: Some(quick_lease()),
                ..Options::default()
            },
        )
        .await;
        let summary = env
            .notifications
            .run_pending_for_org(&owner.org)
            .await
            .unwrap();
        assert_eq!((summary.claimed, summary.delivered), (2, 2));
        assert_eq!(
            env.work(&owner.org).await,
            vec![
                ("delivered".to_owned(), 2, None),
                ("delivered".to_owned(), 1, None)
            ]
        );
        assert_eq!(
            receiver.count(),
            3,
            "the interrupted item is delivered again: at-least-once"
        );
        let ids: Vec<String> = receiver
            .requests
            .lock()
            .unwrap()
            .iter()
            .map(|r| {
                r.headers["postdeploy-event-id"]
                    .to_str()
                    .unwrap()
                    .to_owned()
            })
            .collect();
        assert_eq!(ids[0], ids[1], "a redelivery keeps its event id");
        env.shutdown().await;
    }

    #[tokio::test]
    async fn slow_delivery_holds_no_tenant_handle() {
        let receiver = HttpReceiver::start().await;
        let env = open(
            &data_dir("webhook-slow"),
            Options {
                hosts: loopback("hooks.test"),
                ..Options::default()
            },
        )
        .await;
        let (owner, project) = env.org("owner@example.test").await;
        env.notifications
            .create_webhook(
                &owner,
                webhook(format!("http://hooks.test:{}/in", receiver.port), &ALL),
            )
            .await
            .unwrap();
        let issue = env.issue(&owner.org, project, "Slow", 1).await;
        env.notify(&owner.org, &Notice::NewIssue { project, issue })
            .await;

        receiver.hold(true);
        let notifications = env.notifications.clone();
        let org = owner.org.clone();
        let run = tokio::spawn(async move { notifications.run_pending_for_org(&org).await });
        tokio::time::timeout(Duration::from_secs(5), receiver.arrived.notified())
            .await
            .unwrap();
        assert_eq!(env.pools.registry().stats().await.leased_pools, 0);
        let write = async {
            let handle = env
                .pools
                .registry()
                .open_existing(&owner.org.tenant())
                .await
                .unwrap();
            let txn = handle.begin().await.unwrap();
            txn.execute_raw(crate::runtime::sql(
                "UPDATE issues SET event_count = 2 WHERE id = ?",
                vec![issue.into()],
            ))
            .await
            .unwrap();
            txn.commit().await.unwrap();
        };
        tokio::time::timeout(Duration::from_secs(2), write)
            .await
            .expect("tenant writable during delivery");
        assert!(!run.is_finished());
        receiver.hold(false);
        assert_eq!(run.await.unwrap().unwrap().delivered, 1);
        env.shutdown().await;
    }

    #[tokio::test]
    async fn unsafe_destinations_get_no_requests() {
        let receiver = HttpReceiver::start().await;
        let env = open(&data_dir("webhook-unsafe"), Options::default()).await;
        let (owner, project) = env.org("owner@example.test").await;
        for url in [
            format!("https://127.0.0.1:{}/in", receiver.port),
            format!("https://localhost:{}/in", receiver.port),
            format!("http://hooks.example.com:{}/in", receiver.port),
            "https://u:p@hooks.example.com/in".to_owned(),
            "https://169.254.169.254/latest/meta-data".to_owned(),
        ] {
            let error = env
                .notifications
                .create_webhook(&owner, webhook(url.clone(), &ALL))
                .await
                .unwrap_err();
            assert!(
                matches!(error, ApiError::BadRequest("unsafe_webhook_url")),
                "{url}: {error:?}"
            );
        }
        let member = env
            .join(&owner.org, "member@example.test", Role::Member)
            .await;
        let error = env
            .notifications
            .create_webhook(
                &member,
                webhook("https://hooks.example.com/in".to_owned(), &ALL),
            )
            .await
            .unwrap_err();
        assert!(matches!(error, ApiError::Forbidden));
        env.shutdown().await;

        let env = open(
            &data_dir("webhook-rebind"),
            Options {
                hosts: loopback("hooks.test"),
                ..Options::default()
            },
        )
        .await;
        let (owner, project_b) = env.org("owner@example.test").await;
        env.notifications
            .create_webhook(
                &owner,
                webhook(format!("http://hooks.test:{}/in", receiver.port), &ALL),
            )
            .await
            .unwrap();
        let issue = env.issue(&owner.org, project_b, "Rebind", 1).await;
        env.notify(
            &owner.org,
            &Notice::NewIssue {
                project: project_b,
                issue,
            },
        )
        .await;
        assert_eq!(
            env.notifications
                .run_pending_for_org(&owner.org)
                .await
                .unwrap()
                .delivered,
            1
        );
        for ip in ["169.254.169.254", "10.0.0.7", "::ffff:192.168.1.1"] {
            env.set_host("hooks.test", ip.parse::<IpAddr>().unwrap());
            env.notify(
                &owner.org,
                &Notice::Regression {
                    project: project_b,
                    issue,
                    at: ip.len() as i64,
                },
            )
            .await;
            assert_eq!(
                env.notifications
                    .run_pending_for_org(&owner.org)
                    .await
                    .unwrap()
                    .failed,
                1,
                "{ip}"
            );
        }
        assert_eq!(
            receiver.count(),
            1,
            "only the delivery before the DNS change reached the receiver"
        );
        let work = env.work(&owner.org).await;
        assert_eq!(
            work[1..].iter().map(|w| w.2.as_deref()).collect::<Vec<_>>(),
            [Some("unsafe_destination"); 3]
        );
        assert_eq!(
            env.notifications
                .metrics()
                .unsafe_destinations
                .load(Ordering::Relaxed),
            3
        );
        let _ = project;
        env.shutdown().await;
    }

    #[tokio::test]
    async fn destinations_are_isolated_between_organizations() {
        let env = open(&data_dir("destinations-isolated"), Options::default()).await;
        let (a, _) = env.org("a@example.test").await;
        let (b, _) = env.org("b@example.test").await;
        let hook = env
            .notifications
            .create_webhook(
                &a,
                webhook("https://hooks.example.com/in?token=t".to_owned(), &ALL),
            )
            .await
            .unwrap();
        let email = env
            .notifications
            .subscribe_email(
                &a,
                EmailSubscription {
                    events: vec![EventKind::ReportPublished],
                    project_id: None,
                },
            )
            .await
            .unwrap();
        assert_eq!(email.events, vec![EventKind::ReportPublished]);

        assert_eq!(env.notifications.destinations(&b).await.unwrap(), vec![]);
        let error = env
            .notifications
            .delete_destination(&b, &hook.destination.id)
            .await
            .unwrap_err();
        assert!(matches!(error, ApiError::NotFound));
        let in_a = env.notifications.destinations(&a).await.unwrap();
        assert_eq!(
            in_a.iter().map(|d| d.kind).collect::<Vec<_>>(),
            ["webhook", "email"]
        );

        let member = env.join(&a.org, "member@example.test", Role::Member).await;
        let error = env
            .notifications
            .delete_destination(&member, &hook.destination.id)
            .await
            .unwrap_err();
        assert!(matches!(error, ApiError::Forbidden));
        let own = env
            .notifications
            .subscribe_email(
                &member,
                EmailSubscription {
                    events: vec![EventKind::IssueNew],
                    project_id: None,
                },
            )
            .await
            .unwrap();
        env.notifications
            .delete_destination(&member, &own.id)
            .await
            .unwrap();
        env.notifications
            .delete_destination(&a, &hook.destination.id)
            .await
            .unwrap();
        assert_eq!(
            env.notifications.destinations(&a).await.unwrap(),
            vec![email]
        );
        env.shutdown().await;
    }

    #[tokio::test]
    async fn email_retries_transient_rejections_and_reports_missing_configuration() {
        let smtp_receiver = SmtpReceiver::start().await;
        let env = open(
            &data_dir("email-issue"),
            Options {
                smtp: Some(smtp(smtp_receiver.port)),
                ..Options::default()
            },
        )
        .await;
        let (owner, project) = env.org("owner@example.test").await;
        env.notifications
            .subscribe_email(
                &owner,
                EmailSubscription {
                    events: vec![EventKind::IssueNew],
                    project_id: None,
                },
            )
            .await
            .unwrap();
        let issue = env.issue(&owner.org, project, "Payment declined", 4).await;
        smtp_receiver.reject_mail(&["451 4.3.0 try later"]);
        env.notify(&owner.org, &Notice::NewIssue { project, issue })
            .await;
        let run = || env.notifications.run_pending_for_org(&owner.org);
        assert_eq!(run().await.unwrap().retried, 1);
        assert_eq!(
            env.work(&owner.org).await,
            vec![("pending".to_owned(), 1, Some("smtp_deferred".to_owned()))]
        );
        assert_eq!(run().await.unwrap().delivered, 1);
        let messages = smtp_receiver.messages.lock().unwrap().clone();
        assert_eq!(messages.len(), 1);
        assert!(
            messages[0].contains("To: owner@example.test"),
            "{}",
            messages[0]
        );
        assert!(
            messages[0].contains("Subject: [PostDeploy] New issue: Payment declined"),
            "{}",
            messages[0]
        );
        assert!(messages[0].contains(&format!(
            "https://postdeploy.test/dashboard/orgs/{}/projects/{}/observe/issues/{issue}",
            owner.org, project.0
        )));
        assert!(messages[0].contains(&format!(
            "Message-ID: <{}.",
            Notice::NewIssue { project, issue }.event_id(&owner.org)
        )));
        env.shutdown().await;

        let env = open(&data_dir("email-unconfigured"), Options::default()).await;
        let (owner, project) = env.org("owner@example.test").await;
        env.notifications
            .subscribe_email(
                &owner,
                EmailSubscription {
                    events: vec![EventKind::IssueNew],
                    project_id: None,
                },
            )
            .await
            .unwrap();
        let issue = env.issue(&owner.org, project, "Payment declined", 1).await;
        env.notify(&owner.org, &Notice::NewIssue { project, issue })
            .await;
        assert_eq!(
            env.notifications
                .run_pending_for_org(&owner.org)
                .await
                .unwrap()
                .not_configured,
            1
        );
        assert_eq!(
            env.work(&owner.org).await,
            vec![(
                "not_configured".to_owned(),
                1,
                Some("not_configured".to_owned())
            )]
        );
        assert_eq!(
            env.notifications.destinations(&owner).await.unwrap()[0].not_configured,
            1
        );
        env.shutdown().await;
    }

    #[tokio::test]
    async fn overflow_and_enqueue_failures_never_fail_the_caller() {
        let settings = NotificationSettings {
            max_queued: 2,
            ..testkit::settings()
        };
        let env = open(
            &data_dir("enqueue-bounds"),
            Options {
                settings: Some(settings),
                ..Options::default()
            },
        )
        .await;
        let (owner, project) = env.org("owner@example.test").await;
        env.notifications
            .create_webhook(
                &owner,
                webhook("https://hooks.example.com/in".to_owned(), &ALL),
            )
            .await
            .unwrap();
        let mut outcomes = Vec::new();
        for title in ["One", "Two", "Three"] {
            let issue = env.issue(&owner.org, project, title, 1).await;
            outcomes.push(
                env.notify(&owner.org, &Notice::NewIssue { project, issue })
                    .await,
            );
        }
        assert_eq!(
            outcomes
                .iter()
                .map(|o| (o.queued, o.dropped))
                .collect::<Vec<_>>(),
            [(1, 0), (1, 0), (0, 1)]
        );
        assert_eq!(
            env.notifications.destinations(&owner).await.unwrap()[0].dropped,
            1
        );
        assert_eq!(
            env.notifications
                .metrics()
                .dropped_overflow
                .load(Ordering::Relaxed),
            1
        );

        let handle = env
            .pools
            .registry()
            .open_existing(&owner.org.tenant())
            .await
            .unwrap();
        handle
            .execute_unprepared(
                "ALTER TABLE notification_work RENAME TO notification_work_unavailable",
            )
            .await
            .unwrap();
        let txn = handle.begin().await.unwrap();
        txn.execute_unprepared(
            "INSERT INTO issues (project_id, environment, fingerprint, title, level, status, first_seen, last_seen,
                event_count) VALUES (1, 'production', 'kept', 'Kept', 'error', 'open', 0, 0, 1)",
        )
        .await
        .unwrap();
        let outcome = env
            .notifications
            .enqueue(&txn, &owner.org, &Notice::NewIssue { project, issue: 99 })
            .await;
        assert!(outcome.failed);
        txn.commit().await.unwrap();
        let kept = handle
            .query_one_raw(crate::runtime::sql(
                "SELECT COUNT(*) AS n FROM issues WHERE fingerprint = 'kept'",
                vec![],
            ))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(kept.try_get::<i64>("", "n").unwrap(), 1);
        assert_eq!(
            env.notifications
                .metrics()
                .enqueue_failures
                .load(Ordering::Relaxed),
            1
        );
        drop(handle);
        env.shutdown().await;
    }
}
