//! Maps a Sentry error event to the compact issue fields and a scrubbed payload.
//! Grouping follows the PostDeploy rules: a custom fingerprint, then
//! in-app exception frames, then the normalized message.

use std::sync::LazyLock;

use regex::Regex;
use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::{
    domain::{Environment, ProjectId},
    ingest::{envelope::normalize_event_id, interfaces, policy::IngestionPolicy, receipt::Reason},
};

const MAX_TEXT: usize = 1_024;
const MAX_FINGERPRINT_PARTS: usize = 16;
const MAX_SIGNATURE_FRAMES: usize = 8;

/// One accepted error event. The payload is the scrubbed SDK JSON that is stored in R2.
pub struct ErrorEvent {
    pub event_id: String,
    pub level: &'static str,
    pub title: String,
    pub culprit: Option<String>,
    pub fingerprint: String,
    pub release: Option<String>,
    pub trace_id: Option<String>,
    pub request_id: Option<String>,
    pub service: Option<String>,
    pub occurred_us: i64,
    pub payload: Vec<u8>,
}

impl std::fmt::Debug for ErrorEvent {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ErrorEvent")
            .field("event_id", &self.event_id)
            .field("payload_bytes", &self.payload.len())
            .finish_non_exhaustive()
    }
}

pub fn map(
    raw: &[u8],
    envelope_event_id: Option<&str>,
    project: ProjectId,
    environment: &Environment,
    received_us: i64,
    max_bytes: usize,
    policy: &IngestionPolicy,
) -> Result<ErrorEvent, Reason> {
    if raw.len() > max_bytes {
        return Err(Reason::TooLarge);
    }
    let mut event: Value = serde_json::from_slice(raw).map_err(|_| Reason::Malformed)?;
    if !event.is_object() {
        return Err(Reason::Malformed);
    }
    if let Some(user) = event.get_mut("user").and_then(Value::as_object_mut) {
        user.remove("ip_address");
    }
    policy.redactor().value(&mut event);

    let event_id = event
        .get("event_id")
        .and_then(Value::as_str)
        .and_then(normalize_event_id)
        .or_else(|| envelope_event_id.map(str::to_owned))
        .ok_or(Reason::MissingEventId)?;
    if interfaces::values(&event, "exception")
        .iter()
        .filter_map(|exception| exception.get("type").and_then(Value::as_str))
        .any(|kind| policy.excludes_exception(kind))
    {
        return Err(Reason::ExceptionTypeExcluded);
    }
    if !policy.samples_error(&event_id) {
        return Err(Reason::SampleRate);
    }
    let level = level(event.get("level").and_then(Value::as_str));
    let outer = interfaces::values(&event, "exception").last();
    let frames: Vec<Frame<'_>> = interfaces::primary_frames(&event)
        .iter()
        .map(frame)
        .collect();
    let in_app: Vec<&Frame<'_>> = frames.iter().rev().filter(|f| f.in_app).collect();
    let message = message(&event);
    let kind = outer
        .and_then(|e| e.get("type"))
        .and_then(Value::as_str)
        .unwrap_or("");
    let value = outer
        .and_then(|e| e.get("value"))
        .and_then(Value::as_str)
        .unwrap_or("");

    let tail = [project.0.to_string(), environment.as_str().to_owned()];
    let input: Vec<String> = if let Some(parts) = custom_fingerprint(&event) {
        parts
    } else if !in_app.is_empty() {
        let signature = in_app
            .iter()
            .take(MAX_SIGNATURE_FRAMES)
            .map(|f| format!("{}@{}", f.function.unwrap_or("<anonymous>"), f.path()))
            .collect::<Vec<_>>()
            .join("\n");
        vec![kind.to_owned(), signature]
    } else {
        let text = message
            .clone()
            .or_else(|| match (kind, value) {
                ("", "") => None,
                ("", v) => Some(v.to_owned()),
                (k, "") => Some(k.to_owned()),
                (k, v) => Some(format!("{k}: {v}")),
            })
            .unwrap_or_default();
        vec![level.to_owned(), normalize_message(&text)]
    };
    let fingerprint = digest(input.iter().chain(tail.iter()));

    let title = match (kind, value) {
        ("", "") => message
            .as_deref()
            .map(str::trim)
            .filter(|m| !m.is_empty())
            .unwrap_or("Unknown error")
            .to_owned(),
        ("", v) => v.to_owned(),
        (k, "") => k.to_owned(),
        (k, v) => format!("{k}: {v}"),
    };
    let culprit = in_app.first().map(|f| match (f.path(), f.function) {
        ("", Some(function)) => function.to_owned(),
        (path, function) => format!("{path}:{}", function.unwrap_or("<anonymous>")),
    });
    let release = event
        .get("release")
        .and_then(Value::as_str)
        .map(|r| clip(r, 200));
    let trace_id = event
        .pointer("/contexts/trace/trace_id")
        .and_then(Value::as_str)
        .filter(|t| t.len() == 32 && t.bytes().all(|b| b.is_ascii_hexdigit()))
        .map(str::to_ascii_lowercase);
    let request_id = interfaces::request_id(&event).map(str::to_owned);
    let service = interfaces::service(&event).map(str::to_owned);
    let occurred_us = timestamp_micros(event.get("timestamp"))
        .filter(|&ts| ts <= received_us + MAX_FUTURE_SKEW_US)
        .unwrap_or(received_us);

    let payload = serde_json::to_vec(&event).map_err(|_| Reason::Malformed)?;
    if payload.len() > max_bytes {
        return Err(Reason::TooLarge);
    }
    Ok(ErrorEvent {
        event_id,
        level,
        title: clip(&title, MAX_TEXT),
        culprit: culprit.map(|c| clip(&c, MAX_TEXT)),
        fingerprint,
        release,
        trace_id,
        request_id,
        service,
        occurred_us,
        payload,
    })
}

fn level(value: Option<&str>) -> &'static str {
    match value {
        Some("fatal") => "fatal",
        Some("warning") => "warning",
        Some("info" | "debug" | "log") => "info",
        _ => "error",
    }
}

struct Frame<'a> {
    function: Option<&'a str>,
    file: Option<&'a str>,
    in_app: bool,
}

impl Frame<'_> {
    fn path(&self) -> &str {
        normalize_path(self.file.unwrap_or(""))
    }
}

fn frame(value: &Value) -> Frame<'_> {
    let abs_path = value.get("abs_path").and_then(Value::as_str);
    let file = abs_path.or_else(|| value.get("filename").and_then(Value::as_str));
    let explicit = value.get("in_app").and_then(Value::as_bool);
    let toolchain = abs_path.is_some_and(|p| {
        ["/.cargo/registry/", "/rustc/", "/rustlib/"]
            .iter()
            .any(|marker| p.contains(marker))
    });
    let in_app = match explicit {
        Some(true) => !toolchain,
        Some(false) => false,
        None => file.is_some_and(inferred_in_app),
    };
    Frame {
        function: value.get("function").and_then(Value::as_str),
        file,
        in_app,
    }
}

fn inferred_in_app(file: &str) -> bool {
    const EXTERNAL: &[&str] = &[
        "/node_modules/",
        "/dist/",
        "/vendor/",
        "/.pnpm/",
        "/@postdeploy/sdk",
    ];
    !(matches!(
        file,
        "<anonymous>" | "native code" | "[native code]" | "<unknown>"
    ) || EXTERNAL.iter().any(|marker| file.contains(marker))
        || ["node:", "webpack://", "internal/"]
            .iter()
            .any(|prefix| file.starts_with(prefix))
        || !(file.contains('/') || file.contains('\\')))
}

fn normalize_path(path: &str) -> &str {
    let path = match path.find("://") {
        Some(scheme) => {
            let after = &path[scheme + 3..];
            match after.find('/') {
                Some(slash) => &after[slash..],
                None => "/",
            }
        }
        None => path,
    };
    let end = path.find(['?', '#']).unwrap_or(path.len());
    &path[..end]
}

fn message(event: &Value) -> Option<String> {
    let from = |value: &Value| match value {
        Value::String(s) => Some(s.clone()),
        Value::Object(map) => map
            .get("formatted")
            .or_else(|| map.get("message"))
            .and_then(Value::as_str)
            .map(str::to_owned),
        _ => None,
    };
    event
        .get("message")
        .and_then(from)
        .or_else(|| event.get("logentry").and_then(from))
        .filter(|m| !m.is_empty())
        .map(|m| clip(&m, 4_096))
}

fn custom_fingerprint(event: &Value) -> Option<Vec<String>> {
    let parts = event.get("fingerprint")?.as_array()?;
    if parts.is_empty() {
        return None;
    }
    let mut out = Vec::new();
    for part in parts.iter().take(MAX_FINGERPRINT_PARTS) {
        let part = part.as_str()?;
        if part.replace(' ', "") == "{{default}}" {
            return None;
        }
        out.push(clip(part, 256));
    }
    Some(out)
}

static UUID: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)\b[0-9a-f]{8}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{12}\b")
        .expect("valid regex")
});
static TIMESTAMP: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"\b\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?)?",
    )
    .expect("valid regex")
});
static HEX: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)\b[0-9a-f]{8,}\b").expect("valid regex"));
static NUMBER: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"-?\b\d+(?:\.\d+)?\b").expect("valid regex"));
static SPACE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\s+").expect("valid regex"));

pub fn normalize_message(message: &str) -> String {
    let text = UUID.replace_all(message, "<uuid>");
    let text = TIMESTAMP.replace_all(&text, "<ts>");
    let text = HEX.replace_all(&text, "<hex>");
    let text = NUMBER.replace_all(&text, "<num>");
    SPACE.replace_all(&text, " ").trim().to_owned()
}

fn digest<'a>(parts: impl Iterator<Item = &'a String>) -> String {
    let mut hasher = Sha256::new();
    for (index, part) in parts.enumerate() {
        if index > 0 {
            hasher.update([0u8]);
        }
        hasher.update(part.as_bytes());
    }
    format!("sha256:{}", hex::encode(hasher.finalize()))
}

pub fn clip(value: &str, max: usize) -> String {
    if value.len() <= max {
        return value.to_owned();
    }
    let mut end = max;
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    value[..end].to_owned()
}

/// Client timestamps later than this past receive time are stored as receive time.
pub(crate) const MAX_FUTURE_SKEW_US: i64 = 300_000_000;

/// Accepts Unix seconds (with fraction) or RFC 3339 text.
pub fn timestamp_micros(value: Option<&Value>) -> Option<i64> {
    match value? {
        Value::Number(n) => {
            let secs = n.as_f64()?;
            (secs.is_finite() && (0.0..100_000_000_000.0).contains(&secs))
                .then_some((secs * 1_000_000.0) as i64)
        }
        Value::String(s) => {
            let parsed = chrono::DateTime::parse_from_rfc3339(s)
                .map(|t| t.timestamp_micros())
                .or_else(|_| {
                    chrono::NaiveDateTime::parse_from_str(s, "%Y-%m-%dT%H:%M:%S%.f")
                        .map(|t| t.and_utc().timestamp_micros())
                });
            parsed.ok()
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn env() -> Environment {
        Environment::parse("production").unwrap()
    }

    fn mapped(event: Value) -> ErrorEvent {
        map(
            &serde_json::to_vec(&event).unwrap(),
            None,
            ProjectId(7),
            &env(),
            1,
            1 << 20,
            &IngestionPolicy::default(),
        )
        .unwrap()
    }

    #[test]
    fn groups_by_in_app_frames_and_ignores_line_numbers() {
        let event = |line: u32, value: &str| {
            json!({
                "event_id": "0123456789abcdef0123456789abcdef",
                "exception": {"values": [{"type": "TypeError", "value": value, "stacktrace": {"frames": [
                    {"function": "vendor", "abs_path": "/srv/node_modules/x.js", "lineno": 1},
                    {"function": "processOrder", "abs_path": "https://app.test/src/checkout.ts?v=1", "lineno": line}
                ]}}]}
            })
        };
        let a = mapped(event(10, "x is undefined"));
        let b = mapped(event(99, "y is undefined"));
        assert_eq!(a.fingerprint, b.fingerprint);
        assert_eq!(a.title, "TypeError: x is undefined");
        assert_eq!(a.culprit.as_deref(), Some("/src/checkout.ts:processOrder"));
        assert_eq!(a.level, "error");
    }

    #[test]
    fn uses_the_current_thread_stack_when_the_exception_has_none() {
        let event = mapped(json!({"event_id": "0123456789abcdef0123456789abcdef",
        "exception": {"values": [{"type": "Custom", "value": "card declined"}]},
        "threads": {"values": [{"current": true, "stacktrace": {"frames": [
            {"function": "std::rt::lang_start", "abs_path": "/rustc/abc/library/std/src/rt.rs", "in_app": true},
            {"function": "checkout::pay", "abs_path": "/srv/checkout/src/pay.rs", "in_app": true}
        ]}}]}}));
        assert_eq!(
            event.culprit.as_deref(),
            Some("/srv/checkout/src/pay.rs:checkout::pay")
        );
        assert_eq!(event.title, "Custom: card declined");
    }

    #[test]
    fn message_grouping_normalizes_variable_tokens() {
        let a = mapped(
            json!({"event_id": "0123456789abcdef0123456789abcdef", "level": "warning",
            "message": {"formatted": "queue depth is 12 at 2026-10-15T10:00:00Z"}}),
        );
        let b = mapped(
            json!({"event_id": "0123456789abcdef0123456789abcdee", "level": "warning",
            "message": "queue depth is 40 at 2026-10-16T11:00:00Z"}),
        );
        assert_eq!(a.fingerprint, b.fingerprint);
        assert_eq!(a.title, "queue depth is 12 at 2026-10-15T10:00:00Z");
        assert_eq!(
            normalize_message("id 9ec79c33-ec99-42ab-8353-589fcb2e04dc took -1.5"),
            "id <uuid> took <num>"
        );
    }

    #[test]
    fn custom_fingerprint_wins_unless_default_marker() {
        let custom = mapped(json!({"event_id": "0123456789abcdef0123456789abcdef",
            "fingerprint": ["checkout", "timeout"], "message": "a"}));
        let other = mapped(json!({"event_id": "0123456789abcdef0123456789abcdef",
            "fingerprint": ["checkout", "timeout"], "message": "b"}));
        let defaulted = mapped(json!({"event_id": "0123456789abcdef0123456789abcdef",
            "fingerprint": ["{{ default }}"], "message": "b"}));
        assert_eq!(custom.fingerprint, other.fingerprint);
        assert_ne!(custom.fingerprint, defaulted.fingerprint);
    }

    #[test]
    fn scrubs_payload_and_drops_ip_before_storage() {
        let event = mapped(
            json!({"event_id": "0123456789abcdef0123456789abcdef", "message": "m",
            "user": {"id": "42", "ip_address": "10.0.0.1"},
            "request": {"headers": {"Cookie": "sid=abc"}}}),
        );
        let stored: Value = serde_json::from_slice(&event.payload).unwrap();
        assert_eq!(stored["user"], json!({"id": "42"}));
        assert_eq!(stored["request"]["headers"]["Cookie"], "[Filtered]");
    }
}
