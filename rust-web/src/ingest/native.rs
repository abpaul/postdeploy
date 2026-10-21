use serde_json::{json, Map, Value};

const MAX_ITEMS: usize = 100;
const MAX_CAUSE_DEPTH: usize = 5;

pub struct NativeEnvelope {
    /// The key the SDK wrote into the envelope header, if any.
    pub header_key: Option<String>,
    /// Sentry event JSON, one per accepted native item.
    pub events: Vec<Vec<u8>>,
    pub dropped: u32,
}

#[derive(Debug, PartialEq, Eq)]
pub struct Malformed;

pub fn parse(raw: &[u8]) -> Result<NativeEnvelope, Malformed> {
    let envelope: Value = serde_json::from_slice(raw).map_err(|_| Malformed)?;
    let header = envelope
        .get("header")
        .and_then(Value::as_object)
        .ok_or(Malformed)?;
    let items = envelope
        .get("items")
        .and_then(Value::as_array)
        .ok_or(Malformed)?;
    if items.is_empty() || items.len() > MAX_ITEMS {
        return Err(Malformed);
    }
    let sdk = header
        .get("sdk")
        .and_then(Value::as_object)
        .ok_or(Malformed)?;
    let sdk = json!({
        "name": sdk.get("name").and_then(Value::as_str).ok_or(Malformed)?,
        "version": sdk.get("version").and_then(Value::as_str).ok_or(Malformed)?,
    });
    let mut events = Vec::new();
    let mut dropped = 0;
    for item in items {
        match item.as_object().and_then(|item| to_sentry(item, &sdk)) {
            Some(event) => events.push(serde_json::to_vec(&event).map_err(|_| Malformed)?),
            None => dropped += 1,
        }
    }
    Ok(NativeEnvelope {
        header_key: header.get("key").and_then(Value::as_str).map(str::to_owned),
        events,
        dropped,
    })
}

pub(crate) fn to_sentry(item: &Map<String, Value>, sdk: &Value) -> Option<Value> {
    let id = item.get("id")?.as_str()?;
    let event_id =
        crate::ingest::envelope::normalize_event_id(id.strip_prefix("err_").unwrap_or(id))?;
    let mut event = json!({
        "event_id": event_id,
        "timestamp": item.get("timestamp")?.as_str()?,
        "level": item.get("level").and_then(Value::as_str).unwrap_or("error"),
        "sdk": sdk,
    });
    for key in [
        "release",
        "message",
        "fingerprint",
        "breadcrumbs",
        "contexts",
        "tags",
        "user",
    ] {
        if let Some(value) = item.get(key).filter(|v| !v.is_null()) {
            event[key] = value.clone();
        }
    }
    match item.get("type").and_then(Value::as_str) {
        Some("exception") => {
            let mut chain = Vec::new();
            let mut next = item.get("exception").filter(|e| e.is_object());
            while let Some(exception) = next.filter(|_| chain.len() < MAX_CAUSE_DEPTH) {
                chain.push(exception);
                next = exception.get("cause").filter(|e| e.is_object());
            }
            let outer = chain.first()?;
            outer.get("type")?.as_str()?;
            let mut values: Vec<Value> = chain.iter().rev().map(|e| exception(e)).collect();
            if let Some(mechanism) = item.get("mechanism").and_then(Value::as_str) {
                values.last_mut()?["mechanism"] = json!({ "type": mechanism });
            }
            event["exception"] = json!({ "values": values });
        }
        Some("message") => {
            item.get("message")?.as_str()?;
        }
        _ => return None,
    }
    Some(event)
}

/// Native SDKs list the innermost call first and name the path `file`.
/// Sentry lists the innermost call last and names it `filename`.
fn exception(native: &Value) -> Value {
    let frames: Vec<Value> = native
        .pointer("/stacktrace/frames")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .rev()
        .filter_map(Value::as_object)
        .map(|frame| {
            let mut out = Map::new();
            for (from, to) in [
                ("file", "filename"),
                ("function", "function"),
                ("lineno", "lineno"),
                ("colno", "colno"),
                ("in_app", "in_app"),
                ("pre_context", "pre_context"),
                ("context_line", "context_line"),
                ("post_context", "post_context"),
            ] {
                if let Some(value) = frame.get(from).filter(|v| !v.is_null()) {
                    out.insert(to.to_owned(), value.clone());
                }
            }
            Value::Object(out)
        })
        .collect();
    let mut out = json!({ "type": native.get("type"), "value": native.get("value") });
    if !frames.is_empty() {
        out["stacktrace"] = json!({ "frames": frames });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_a_native_exception_chain_to_sentry_order() {
        let raw = json!({
            "header": {"key": null, "sdk": {"name": "postdeploy-elixir", "version": "0.4.0", "platform": null}, "sent_at": null},
            "items": [
                {"id": "err_01920000-0000-7000-8000-000000000001", "type": "exception", "timestamp": "2026-10-16T08:00:00Z",
                 "level": "error", "release": "shop@2", "mechanism": "plug",
                 "contexts": {"request": {"headers": {"x-request-id": "req-9"}}},
                 "exception": {"type": "Shop.PaymentError", "value": "card declined",
                    "stacktrace": {"frames": [
                        {"function": "Shop.Pay.charge/2", "file": "lib/shop/pay.ex", "lineno": 12, "in_app": true},
                        {"function": "Plug.Conn.run/2", "file": "lib/plug/conn.ex", "lineno": 3}]},
                    "cause": {"type": "Mint.TransportError", "value": "timeout"}}},
                {"id": "not-an-id", "type": "message", "timestamp": "2026-10-16T08:00:00Z", "message": "x"}
            ]
        });
        let parsed = parse(&serde_json::to_vec(&raw).unwrap()).unwrap();
        assert_eq!((parsed.events.len(), parsed.dropped), (1, 1));
        let event: Value = serde_json::from_slice(&parsed.events[0]).unwrap();
        assert_eq!(event["event_id"], "01920000000070008000000000000001");
        assert_eq!(
            event["exception"]["values"][0]["type"],
            "Mint.TransportError"
        );
        let outer = &event["exception"]["values"][1];
        assert_eq!(outer["mechanism"], json!({"type": "plug"}));
        assert_eq!(
            outer["stacktrace"]["frames"],
            json!([
                {"function": "Plug.Conn.run/2", "filename": "lib/plug/conn.ex", "lineno": 3},
                {"function": "Shop.Pay.charge/2", "filename": "lib/shop/pay.ex", "lineno": 12, "in_app": true}
            ])
        );
        assert_eq!(
            event["contexts"]["request"]["headers"]["x-request-id"],
            "req-9"
        );
    }
}
