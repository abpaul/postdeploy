//! One ingestion policy per organization, inherited by every project. Built-in
//! credential redaction always applies; the policy adds field names, log
//! levels, excluded exception types and sampling.

use serde::{Deserialize, Serialize, Serializer};
use serde_json::Value;
use sha2::{Digest, Sha256};

use sea_orm::ConnectionTrait;

use crate::{
    domain::now_secs,
    error::{ApiError, ApiResult},
    identity::access::OrgAccess,
    logs::record::LogLevel,
    runtime::{sql, Runtime},
    scrub::{FieldName, Redactor},
};

pub const MAX_SENSITIVE_FIELDS: usize = 32;
pub const MAX_EXCLUDED_TYPES: usize = 32;
pub const MAX_EXCEPTION_TYPE_BYTES: usize = 128;
const MAX_LEVEL_ENTRIES: usize = 12;

/// Field names ingestion reads to identify, group and store items. An extra
/// sensitive name that is part of one of them would filter that field.
const STRUCTURAL_KEYS: &[&str] = &[
    "event_id",
    "level",
    "message",
    "formatted",
    "logentry",
    "exception",
    "values",
    "type",
    "value",
    "stacktrace",
    "frames",
    "function",
    "filename",
    "abs_path",
    "in_app",
    "threads",
    "crashed",
    "current",
    "fingerprint",
    "sentry.release",
    "timestamp",
    "contexts",
    "trace_id",
    "span_id",
    "tags",
    "request",
    "headers",
    "http.request.header.x_request_id",
    "request.id",
    "request_id",
    "service.name",
    "body",
    "items",
    "attributes",
    "unit",
    "environment",
    "ip_address",
];

fn structural(name: &FieldName) -> bool {
    STRUCTURAL_KEYS
        .iter()
        .any(|key| key.contains(name.as_str()))
}

const LEVELS: [LogLevel; 6] = [
    LogLevel::Trace,
    LogLevel::Debug,
    LogLevel::Info,
    LogLevel::Warn,
    LogLevel::Error,
    LogLevel::Fatal,
];

/// Log levels that are stored. Serialized as level names in severity order.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LevelSet(u8);

impl LevelSet {
    pub const ALL: Self = Self(0b11_1111);

    pub fn contains(self, level: LogLevel) -> bool {
        self.0 & level.bit() != 0
    }

    pub fn names(self) -> Vec<&'static str> {
        LEVELS
            .into_iter()
            .filter(|level| self.contains(*level))
            .map(LogLevel::as_str)
            .collect()
    }
}

impl Serialize for LevelSet {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        self.names().serialize(serializer)
    }
}

/// A whole percentage from 0 to 100.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(transparent)]
pub struct Percent(u8);

impl Percent {
    pub const ALL: Self = Self(100);

    fn parse(value: i64) -> Option<Self> {
        u8::try_from(value).ok().filter(|v| *v <= 100).map(Self)
    }

    pub fn value(self) -> u8 {
        self.0
    }
}

/// An exception type name matched exactly against every exception of an event.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(transparent)]
pub struct ExceptionType(String);

impl ExceptionType {
    fn parse(raw: &str) -> Option<Self> {
        let name = raw.trim();
        let valid = !name.is_empty()
            && name.len() <= MAX_EXCEPTION_TYPE_BYTES
            && !name.chars().any(char::is_control);
        valid.then(|| Self(name.to_owned()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct IngestionPolicy {
    pub sensitive_fields: Vec<FieldName>,
    pub log_levels: LevelSet,
    pub excluded_exception_types: Vec<ExceptionType>,
    pub error_sample_percent: Percent,
    pub log_sample_percent: Percent,
}

impl Default for IngestionPolicy {
    fn default() -> Self {
        Self {
            sensitive_fields: Vec::new(),
            log_levels: LevelSet::ALL,
            excluded_exception_types: Vec::new(),
            error_sample_percent: Percent::ALL,
            log_sample_percent: Percent::ALL,
        }
    }
}

/// The input is not a valid policy document.
#[derive(Debug, PartialEq, Eq)]
pub struct InvalidPolicy;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Document {
    sensitive_fields: Vec<String>,
    log_levels: Vec<String>,
    excluded_exception_types: Vec<String>,
    error_sample_percent: i64,
    log_sample_percent: i64,
}

fn unique<T: PartialEq>(items: impl IntoIterator<Item = Option<T>>) -> Option<Vec<T>> {
    let mut out = Vec::new();
    for item in items {
        let item = item?;
        if !out.contains(&item) {
            out.push(item);
        }
    }
    Some(out)
}

impl IngestionPolicy {
    /// Parses the API body and the stored document. Every field is required;
    /// duplicates collapse and names are normalized.
    pub fn parse(value: Value) -> Result<Self, InvalidPolicy> {
        let document: Document = serde_json::from_value(value).map_err(|_| InvalidPolicy)?;
        if document.sensitive_fields.len() > MAX_SENSITIVE_FIELDS
            || document.excluded_exception_types.len() > MAX_EXCLUDED_TYPES
            || document.log_levels.len() > MAX_LEVEL_ENTRIES
        {
            return Err(InvalidPolicy);
        }
        let sensitive_fields = unique(
            document
                .sensitive_fields
                .iter()
                .map(|f| FieldName::parse(f).filter(|name| !structural(name))),
        )
        .ok_or(InvalidPolicy)?;
        let excluded_exception_types = unique(
            document
                .excluded_exception_types
                .iter()
                .map(|t| ExceptionType::parse(t)),
        )
        .ok_or(InvalidPolicy)?;
        let mut levels = 0u8;
        for name in &document.log_levels {
            levels |= LogLevel::parse(name).ok_or(InvalidPolicy)?.bit();
        }
        Ok(Self {
            sensitive_fields,
            log_levels: LevelSet(levels),
            excluded_exception_types,
            error_sample_percent: Percent::parse(document.error_sample_percent)
                .ok_or(InvalidPolicy)?,
            log_sample_percent: Percent::parse(document.log_sample_percent).ok_or(InvalidPolicy)?,
        })
    }

    /// Reads a stored document; `None` is an organization without a policy row.
    pub fn from_stored(stored: Option<&str>) -> Result<Self, InvalidPolicy> {
        match stored {
            None => Ok(Self::default()),
            Some(text) => Self::parse(serde_json::from_str(text).map_err(|_| InvalidPolicy)?),
        }
    }

    pub fn redactor(&self) -> Redactor<'_> {
        Redactor::new(&self.sensitive_fields)
    }

    pub fn excludes_exception(&self, kind: &str) -> bool {
        self.excluded_exception_types
            .iter()
            .any(|excluded| excluded.as_str() == kind)
    }

    /// Error sampling hashes the event ID, so retries of one event always get
    /// the same decision.
    pub fn samples_error(&self, event_id: &str) -> bool {
        let digest = Sha256::digest(event_id.as_bytes());
        let bucket = u64::from_be_bytes(digest[..8].try_into().expect("eight bytes")) % 100;
        bucket < u64::from(self.error_sample_percent.value())
    }

    /// Logs have no stable identity; each entry gets an independent draw.
    pub fn samples_log(&self) -> bool {
        match self.log_sample_percent.value() {
            100 => true,
            0 => false,
            percent => rand::random_range(0..100u8) < percent,
        }
    }
}

pub const INVALID: &str = "ingestion_policy_invalid";

/// A stored policy as read surfaces show it. A stored document that fails
/// validation is reported, never replaced with defaults.
#[derive(Debug)]
pub enum PolicyState {
    Valid(IngestionPolicy),
    Invalid,
}

impl Serialize for PolicyState {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            Self::Valid(policy) => policy.serialize(serializer),
            Self::Invalid => serde_json::json!({ "error": INVALID }).serialize(serializer),
        }
    }
}

#[derive(Debug, Serialize)]
pub struct StoredPolicy {
    pub policy: PolicyState,
    pub updated_at: Option<i64>,
}

pub async fn load(rt: &Runtime, access: &OrgAccess) -> ApiResult<StoredPolicy> {
    let row = rt
        .control
        .query_one_raw(sql(
            "SELECT policy, updated_at FROM ingestion_policies WHERE org_id = ?",
            vec![access.org.as_str().into()],
        ))
        .await?;
    let (text, updated_at) = match row {
        Some(row) => (
            Some(row.try_get::<String>("", "policy")?),
            Some(row.try_get::<i64>("", "updated_at")?),
        ),
        None => (None, None),
    };
    let policy = IngestionPolicy::from_stored(text.as_deref())
        .map_or(PolicyState::Invalid, PolicyState::Valid);
    Ok(StoredPolicy { policy, updated_at })
}

pub async fn save(rt: &Runtime, access: &OrgAccess, input: Value) -> ApiResult<StoredPolicy> {
    access.require_manage()?;
    let policy = IngestionPolicy::parse(input)
        .map_err(|_| ApiError::BadRequest("invalid_ingestion_policy"))?;
    let document = serde_json::to_string(&policy)
        .map_err(|error| ApiError::internal("ingestion policy encoding", error))?;
    let updated_at = now_secs();
    rt.control
        .execute_raw(sql(
            "INSERT INTO ingestion_policies (org_id, policy, updated_at, updated_by)
             SELECT id, ?, ?, ? FROM organizations WHERE id = ? AND lifecycle = 'active'
             ON CONFLICT (org_id) DO UPDATE SET policy = excluded.policy,
                updated_at = excluded.updated_at, updated_by = excluded.updated_by",
            vec![
                document.into(),
                updated_at.into(),
                access.user.0.into(),
                access.org.as_str().into(),
            ],
        ))
        .await?;
    Ok(StoredPolicy {
        policy: PolicyState::Valid(policy),
        updated_at: Some(updated_at),
    })
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn error_sampling_is_a_pure_function_of_the_event_id() {
        let policy = IngestionPolicy {
            error_sample_percent: Percent(50),
            ..IngestionPolicy::default()
        };
        let ids: Vec<String> = (0..20).map(|i| format!("{i:032x}")).collect();
        let kept: Vec<bool> = ids.iter().map(|id| policy.samples_error(id)).collect();
        assert_eq!(kept.iter().filter(|keep| **keep).count(), 11);
        let none = IngestionPolicy {
            error_sample_percent: Percent(0),
            ..IngestionPolicy::default()
        };
        assert!(ids.iter().all(|id| !none.samples_error(id)));
        assert!(ids
            .iter()
            .all(|id| IngestionPolicy::default().samples_error(id)));
    }

    #[test]
    fn stored_documents_round_trip_and_invalid_ones_fail() {
        let policy = IngestionPolicy::parse(json!({
            "sensitive_fields": ["SSN-Number"], "log_levels": ["error"],
            "excluded_exception_types": ["Timeout"],
            "error_sample_percent": 10, "log_sample_percent": 0
        }))
        .unwrap();
        let stored = serde_json::to_string(&policy).unwrap();
        assert_eq!(
            stored,
            r#"{"sensitive_fields":["ssn_number"],"log_levels":["error"],"excluded_exception_types":["Timeout"],"error_sample_percent":10,"log_sample_percent":0}"#
        );
        assert_eq!(IngestionPolicy::from_stored(Some(&stored)), Ok(policy));
        assert_eq!(
            IngestionPolicy::from_stored(None),
            Ok(IngestionPolicy::default())
        );
        assert_eq!(
            IngestionPolicy::from_stored(Some("{\"sensitive_fields\":[]}")),
            Err(InvalidPolicy)
        );
    }
}
