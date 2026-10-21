use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::{
    ingest::{
        event::clip,
        policy::IngestionPolicy,
        receipt::{Category, Reason, Receipt},
    },
    scrub,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LogLevel {
    Trace,
    Debug,
    Info,
    Warn,
    Error,
    Fatal,
}

impl LogLevel {
    pub fn parse(value: &str) -> Option<Self> {
        match value.to_ascii_lowercase().as_str() {
            "trace" => Some(Self::Trace),
            "debug" => Some(Self::Debug),
            "info" => Some(Self::Info),
            "warn" | "warning" => Some(Self::Warn),
            "error" => Some(Self::Error),
            "fatal" => Some(Self::Fatal),
            _ => None,
        }
    }

    pub fn bit(self) -> u8 {
        1 << (self as u8)
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Trace => "trace",
            Self::Debug => "debug",
            Self::Info => "info",
            Self::Warn => "warn",
            Self::Error => "error",
            Self::Fatal => "fatal",
        }
    }
}

/// Log message text. Debug output reports only the size, so the text cannot
/// reach operational logs through formatting.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct LogBody(Box<str>);

impl LogBody {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Debug for LogBody {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "[log body: {} bytes]", self.0.len())
    }
}

#[derive(Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(transparent)]
pub struct LogAttributes(Map<String, Value>);

impl LogAttributes {
    pub fn get_str(&self, key: &str) -> Option<&str> {
        self.0.get(key)?.get("value")?.as_str()
    }

    pub fn as_map(&self) -> &Map<String, Value> {
        &self.0
    }
}

impl std::fmt::Debug for LogAttributes {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "[log attributes: {} keys]", self.0.len())
    }
}

/// One accepted log entry. Timestamps are Unix microseconds.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct LogRecord {
    pub ts: i64,
    /// Server receive time. Retention is measured from this value.
    pub rt: i64,
    pub level: LogLevel,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub trace_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub span_id: Option<String>,
    pub body: LogBody,
    #[serde(default)]
    pub attributes: LogAttributes,
}

impl LogRecord {
    pub fn approx_bytes(&self) -> usize {
        serialized_bytes(self).saturating_add(1)
    }

    pub(crate) fn sanitized(&self, limits: &ParseLimits) -> Self {
        Self {
            body: LogBody(
                clip(
                    &scrub::BUILT_IN.text(self.body.as_str()),
                    limits.max_body_bytes,
                )
                .into_boxed_str(),
            ),
            attributes: attributes(
                self.attributes.0.clone(),
                limits,
                scrub::BUILT_IN,
                Parameters::Stored,
            )
            .0,
            ..self.clone()
        }
    }
}

pub(crate) fn serialized_bytes(value: &impl Serialize) -> usize {
    struct Counter(usize);
    impl std::io::Write for Counter {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            self.0 = self.0.saturating_add(bytes.len());
            Ok(bytes.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    let mut counter = Counter(0);
    serde_json::to_writer(&mut counter, value).expect("log JSON serialization");
    counter.0
}

pub struct ParseLimits {
    pub max_body_bytes: usize,
    pub max_attributes: usize,
    pub max_attribute_bytes: usize,
    pub max_record_bytes: usize,
}

const MAX_ATTRIBUTE_KEY_BYTES: usize = 128;
const TEMPLATE: &str = "sentry.message.template";
const PARAMETER: &str = "sentry.message.parameter.";
/// Redaction reads this far past the stored body length, so a credential
/// that crosses the clip point is still recognized whole and its stored
/// prefix is filtered.
const REDACTION_LOOKAHEAD_BYTES: usize = 1024;

#[derive(Deserialize, Serialize)]
#[serde(tag = "type", content = "value", rename_all = "lowercase")]
enum Attribute {
    String(String),
    Boolean(bool),
    Integer(i64),
    Double(f64),
    Array(Vec<Value>),
}

fn primitive_kind(value: &Value) -> Option<u8> {
    match value {
        Value::String(_) => Some(0),
        Value::Bool(_) => Some(1),
        Value::Number(n) if n.is_i64() => Some(2),
        Value::Number(n) if n.is_f64() => Some(3),
        _ => None,
    }
}

/// Whether template parameters are judged in their template, against the
/// body the SDK formatted from it. A stored record already carries the
/// result, and its redacted template may number the parameters differently
/// from the original, so a read does not judge again.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Parameters<'b> {
    Judge { body: &'b str },
    Stored,
}

fn attributes(
    input: Map<String, Value>,
    limits: &ParseLimits,
    redactor: scrub::Redactor<'_>,
    parameters: Parameters<'_>,
) -> (LogAttributes, u64) {
    let mut output = Map::new();
    let mut dropped = 0;
    let named = redactor.names_secret(
        input
            .iter()
            .map(|(key, value)| (key, value.get("value").and_then(Value::as_str))),
    );
    let exposed = match parameters {
        Parameters::Judge { body } => exposed_parameters(&input, body, redactor),
        Parameters::Stored => Default::default(),
    };
    for (key, value) in input {
        if output.len() >= limits.max_attributes
            || serialized_bytes(&value) > limits.max_attribute_bytes
        {
            dropped += 1;
            continue;
        }
        let unit = value
            .get("unit")
            .and_then(Value::as_str)
            .filter(|unit| {
                matches!(
                    *unit,
                    "nanosecond"
                        | "microsecond"
                        | "millisecond"
                        | "second"
                        | "minute"
                        | "hour"
                        | "day"
                        | "week"
                        | "bit"
                        | "byte"
                        | "kilobyte"
                        | "kibibyte"
                        | "megabyte"
                        | "mebibyte"
                        | "gigabyte"
                        | "gibibyte"
                        | "terabyte"
                        | "tebibyte"
                        | "petabyte"
                        | "pebibyte"
                        | "exabyte"
                        | "exbibyte"
                        | "ratio"
                        | "percent"
                )
            })
            .map(str::to_owned);
        let Ok(mut attribute) = serde_json::from_value::<Attribute>(value) else {
            dropped += 1;
            continue;
        };
        if let Attribute::Array(values) = &attribute {
            let kind = values.first().and_then(primitive_kind);
            if !values.is_empty()
                && (kind.is_none() || values.iter().any(|v| primitive_kind(v) != kind))
            {
                dropped += 1;
                continue;
            }
        }
        if redactor.is_sensitive_key(&key)
            || named && key.eq_ignore_ascii_case("value")
            || exposed.contains(&key)
        {
            attribute = Attribute::String(scrub::FILTERED.to_owned());
        } else {
            match &mut attribute {
                Attribute::String(value) => *value = redactor.text(value).into_owned(),
                Attribute::Array(values) => {
                    for value in values {
                        if let Value::String(value) = value {
                            *value = redactor.text(value).into_owned();
                        }
                    }
                }
                _ => {}
            }
        }
        let key = redactor.text(&key).into_owned();
        if key.len() > MAX_ATTRIBUTE_KEY_BYTES {
            dropped += 1;
            continue;
        }
        let mut value = serde_json::to_value(attribute).expect("attribute serialization");
        if let Some(unit) = unit {
            value
                .as_object_mut()
                .expect("attribute object")
                .insert("unit".into(), Value::String(unit));
        }
        let pair = serde_json::json!({&key: &value});
        if serialized_bytes(&pair) <= limits.max_attribute_bytes {
            output.insert(key, value);
        } else {
            dropped += 1;
        }
    }
    (LogAttributes(output), dropped)
}

/// The `sentry.message.parameter.<slot>` attributes that the
/// `sentry.message.template` attribute puts in a credential position, and a
/// `value` parameter that a `name`, `key` or `property` parameter labels as
/// a credential, as for `params` objects.
fn exposed_parameters(
    input: &Map<String, Value>,
    body: &str,
    redactor: scrub::Redactor<'_>,
) -> std::collections::HashSet<String> {
    let Some(template) = input
        .get(TEMPLATE)
        .and_then(|value| value.get("value"))
        .and_then(Value::as_str)
    else {
        return Default::default();
    };
    let params: Vec<(&String, scrub::Slot<'_>, &Value)> = input
        .iter()
        .filter_map(|(key, value)| {
            let slot = scrub::Slot::parse(key.strip_prefix(PARAMETER)?);
            Some((key, slot, value.get("value")?))
        })
        .collect();
    let slots: Vec<(scrub::Slot<'_>, &Value)> = params
        .iter()
        .map(|(_, slot, value)| (*slot, *value))
        .collect();
    let names: Vec<(String, Option<&str>)> = params
        .iter()
        .filter_map(|(_, slot, value)| match slot {
            scrub::Slot::Name(name) => Some(((*name).to_owned(), value.as_str())),
            scrub::Slot::Index(_) => None,
        })
        .collect();
    let named = redactor.names_secret(names.iter().map(|(name, value)| (name, *value)));
    params
        .iter()
        .zip(redactor.exposed_parameters(template, &slots, Some(body)))
        .filter(|((_, slot, _), exposed)| {
            *exposed
                || named
                    && matches!(slot, scrub::Slot::Name(name) if name.eq_ignore_ascii_case("value"))
        })
        .map(|((key, _, _), _)| (*key).clone())
        .collect()
}

/// The `log` item payload is not a JSON object with an `items` array.
#[derive(Debug, PartialEq, Eq)]
pub struct InvalidLogItem;

#[derive(Deserialize)]
struct Container {
    items: Vec<Value>,
}

/// Parses one `log` item payload into the entries the policy keeps. Every
/// other entry, and every bounded change to a kept entry, is counted in
/// `receipt`. An unreadable container is an error.
pub fn parse_item(
    payload: &[u8],
    received_us: i64,
    limits: &ParseLimits,
    policy: &IngestionPolicy,
    receipt: &mut Receipt,
) -> Result<Vec<LogRecord>, InvalidLogItem> {
    let container: Container = serde_json::from_slice(payload).map_err(|_| InvalidLogItem)?;
    let mut records = Vec::new();
    for item in container.items {
        match entry(item, received_us, limits, policy, receipt) {
            Ok(record) => records.push(record),
            Err(reason) => receipt.record(Category::Log, reason, 1),
        }
    }
    Ok(records)
}

fn entry(
    item: Value,
    received_us: i64,
    limits: &ParseLimits,
    policy: &IngestionPolicy,
    receipt: &mut Receipt,
) -> Result<LogRecord, Reason> {
    let Value::Object(mut item) = item else {
        return Err(Reason::InvalidEntry);
    };
    let attribute_input = item.remove("attributes");
    let level = item
        .get("level")
        .and_then(Value::as_str)
        .and_then(LogLevel::parse)
        .ok_or(Reason::InvalidEntry)?;
    let body = item
        .get("body")
        .and_then(Value::as_str)
        .ok_or(Reason::InvalidEntry)?;
    if !policy.log_levels.contains(level) {
        return Err(Reason::LevelDisabled);
    }
    if !policy.samples_log() {
        return Err(Reason::SampleRate);
    }
    let redactor = policy.redactor();
    let window = clip(body, limits.max_body_bytes + REDACTION_LOOKAHEAD_BYTES);
    let redacted = redactor.text(&window);
    let clipped = clip(&redacted, limits.max_body_bytes);
    let body_truncated = window.len() < body.len() || clipped.len() < redacted.len();
    let mut ts =
        crate::ingest::event::timestamp_micros(item.get("timestamp")).unwrap_or(received_us);
    let timestamp_adjusted = ts > received_us + crate::ingest::event::MAX_FUTURE_SKEW_US;
    if timestamp_adjusted {
        ts = received_us;
    }
    let hex_id = |key: &str, len: usize| {
        item.get(key)
            .and_then(Value::as_str)
            .filter(|v| v.len() == len && v.bytes().all(|b| b.is_ascii_hexdigit()))
            .map(str::to_ascii_lowercase)
    };
    let trace_id = hex_id("trace_id", 32);
    let span_id = hex_id("span_id", 16);
    let (attributes, attributes_dropped) = match attribute_input {
        Some(Value::Object(map)) => attributes(map, limits, redactor, Parameters::Judge { body }),
        _ => (LogAttributes::default(), 0),
    };
    let record = LogRecord {
        ts,
        rt: received_us,
        level,
        trace_id,
        span_id,
        body: LogBody(clipped.into_boxed_str()),
        attributes,
    };
    if record.approx_bytes() > limits.max_record_bytes {
        return Err(Reason::RecordTooLarge);
    }
    receipt.record(
        Category::Log,
        Reason::BodyTruncated,
        u64::from(body_truncated),
    );
    receipt.record(
        Category::Log,
        Reason::TimestampAdjusted,
        u64::from(timestamp_adjusted),
    );
    receipt.record(Category::Log, Reason::AttributeDropped, attributes_dropped);
    Ok(record)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_entries_scrubs_and_counts_invalid() {
        let payload = serde_json::json!({"items": [
            {"timestamp": 1_000.5, "level": "warn", "body": "token=abc123 login",
             "trace_id": "0123456789ABCDEF0123456789abcdef",
             "attributes": {"user.password": {"type": "string", "value": "pw"},
                            "sentry.release": {"type": "string", "value": "web@1"}}},
            {"timestamp": 1_000.0, "level": "loud", "body": "x"},
            {"timestamp": 1_000.0, "level": "info"}
        ]});
        let limits = ParseLimits {
            max_body_bytes: 100,
            max_attributes: 8,
            max_attribute_bytes: 4096,
            max_record_bytes: 65_536,
        };
        let mut receipt = Receipt::default();
        let records = parse_item(
            &serde_json::to_vec(&payload).unwrap(),
            1_000_000_000,
            &limits,
            &IngestionPolicy::default(),
            &mut receipt,
        )
        .unwrap();
        let mut expected = Receipt::default();
        expected.record(Category::Log, Reason::InvalidEntry, 2);
        assert_eq!((records.len(), receipt), (1, expected));
        let record = &records[0];
        assert_eq!(record.ts, 1_000_500_000);
        assert_eq!(record.level, LogLevel::Warn);
        assert_eq!(record.body.as_str(), "token=[Filtered] login");
        assert_eq!(
            record.trace_id.as_deref(),
            Some("0123456789abcdef0123456789abcdef")
        );
        assert_eq!(
            record.attributes.get_str("user.password"),
            Some("[Filtered]")
        );
        assert_eq!(record.attributes.get_str("sentry.release"), Some("web@1"));
        assert_eq!(format!("{:?}", record.body), "[log body: 22 bytes]");
    }

    #[test]
    fn template_parameters_in_credential_positions_are_filtered() {
        let string = |value: &str| serde_json::json!({"type": "string", "value": value});
        let payload = serde_json::json!({"items": [
            {"level": "error", "body": "db login failed password=hunter2 for ada",
             "attributes": {
                "sentry.message.template": string("db login failed password=%s for %s"),
                "sentry.message.parameter.0": string("hunter2"),
                "sentry.message.parameter.1": string("ada")}},
            {"level": "info", "body": "token_count: 5",
             "attributes": {
                "sentry.message.template": string("%(name)s: %(count)s"),
                "sentry.message.parameter.name": string("token_count"),
                "sentry.message.parameter.count": {"type": "integer", "value": 5}}},
            {"level": "warn", "body": "GET /cb?next=%2Fhome failed, password: hunter2",
             "attributes": {
                "sentry.message.template": string("GET /cb?next=%2Fhome failed, password: {}"),
                "sentry.message.parameter.0": string("hunter2")}},
            {"level": "warn", "body": "auth failed for Request { id: 7 }: token=abc retry=3",
             "attributes": {
                "sentry.message.template": string("auth failed for {:?}: token={} retry={}"),
                "sentry.message.parameter.0": string("Request { id: 7 }"),
                "sentry.message.parameter.1": string("abc")}},
            {"level": "warn", "body": "Authorization abc",
             "attributes": {
                "sentry.message.template": string("%(key)s %(value)s"),
                "sentry.message.parameter.key": string("Authorization"),
                "sentry.message.parameter.value": string("abc")}}
        ]});
        let limits = ParseLimits {
            max_body_bytes: 100,
            max_attributes: 8,
            max_attribute_bytes: 4096,
            max_record_bytes: 65_536,
        };
        let records = parse_item(
            &serde_json::to_vec(&payload).unwrap(),
            1_000_000_000,
            &limits,
            &IngestionPolicy::default(),
            &mut Receipt::default(),
        )
        .unwrap();
        let parameters: Vec<Value> = records
            .iter()
            .map(|record| {
                let map = record.attributes.as_map();
                serde_json::json!([
                    map.get("sentry.message.parameter.0")
                        .or(map.get("sentry.message.parameter.name"))
                        .or(map.get("sentry.message.parameter.key")),
                    map.get("sentry.message.parameter.1")
                        .or(map.get("sentry.message.parameter.count"))
                        .or(map.get("sentry.message.parameter.value")),
                ])
            })
            .collect();
        assert_eq!(
            parameters,
            [
                serde_json::json!([string("[Filtered]"), string("ada")]),
                serde_json::json!([string("token_count"), {"type": "integer", "value": 5}]),
                serde_json::json!([string("[Filtered]"), null]),
                serde_json::json!([string("[Filtered]"), string("[Filtered]")]),
                serde_json::json!([string("Authorization"), string("[Filtered]")]),
            ]
        );
        for record in &records {
            assert_eq!(&record.sanitized(&limits), record);
        }
    }

    #[test]
    fn keeps_old_event_times_and_replaces_far_future_ones() {
        let received = 10_000_000_000_000;
        let payload = serde_json::json!({"items": [
            {"timestamp": 1_000.0, "level": "info", "body": "old"},
            {"timestamp": 10_000_301.0, "level": "info", "body": "future"}
        ]});
        let limits = ParseLimits {
            max_body_bytes: 100,
            max_attributes: 8,
            max_attribute_bytes: 4096,
            max_record_bytes: 65_536,
        };
        let mut receipt = Receipt::default();
        let records = parse_item(
            &serde_json::to_vec(&payload).unwrap(),
            received,
            &limits,
            &IngestionPolicy::default(),
            &mut receipt,
        )
        .unwrap();
        let times: Vec<(i64, i64)> = records.iter().map(|r| (r.ts, r.rt)).collect();
        assert_eq!(times, [(1_000_000_000, received), (received, received)]);
        let mut expected = Receipt::default();
        expected.record(Category::Log, Reason::TimestampAdjusted, 1);
        assert_eq!(receipt, expected);
    }
}
