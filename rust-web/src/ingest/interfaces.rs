//! Readers for the parts of a Sentry event that SDKs encode differently.
//! `exception`, `threads` and `breadcrumbs` arrive either as an array
//! (sentry-elixir 14) or as `{"values": [...]}` (Python, Ruby, JavaScript).

use serde_json::Value;

const MAX_IDENTIFIER: usize = 200;

pub fn values<'a>(event: &'a Value, interface: &str) -> &'a [Value] {
    match event.get(interface) {
        Some(Value::Array(values)) => values,
        Some(Value::Object(map)) => map
            .get("values")
            .and_then(Value::as_array)
            .map_or(&[], Vec::as_slice),
        _ => &[],
    }
}

/// Frames of one exception or thread, oldest call first.
pub fn frames(item: &Value) -> &[Value] {
    item.pointer("/stacktrace/frames")
        .and_then(Value::as_array)
        .map_or(&[], Vec::as_slice)
}

/// Primary frames, oldest call first. Prefer the outermost exception with
/// frames, then a crashed thread, then a current thread.
pub fn primary_frames(event: &Value) -> &[Value] {
    values(event, "exception")
        .iter()
        .rev()
        .map(frames)
        .find(|frames| !frames.is_empty())
        .or_else(|| {
            ["crashed", "current"].iter().find_map(|flag| {
                values(event, "threads")
                    .iter()
                    .filter(|thread| thread.get(*flag).and_then(Value::as_bool) == Some(true))
                    .map(frames)
                    .find(|frames| !frames.is_empty())
            })
        })
        .unwrap_or_default()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Identifier {
    RequestId,
    Service,
    Release,
}

impl Identifier {
    pub const fn keys(self) -> &'static [&'static str] {
        match self {
            Self::RequestId => &[
                "request_id",
                "request.id",
                "http.request.header.x-request-id",
            ],
            Self::Service => &["service.name", "service"],
            Self::Release => &["sentry.release", "release"],
        }
    }

    pub fn find<'a>(self, lookup: impl Fn(&str) -> Option<&'a Value>) -> Option<&'a str> {
        self.keys().iter().find_map(|key| {
            let value = lookup(key)?;
            let text = match value {
                Value::Array(items) if items.len() == 1 => items[0].as_str(),
                other => other.as_str(),
            }?;
            Some(text.trim()).filter(|text| !text.is_empty() && text.len() <= MAX_IDENTIFIER)
        })
    }
}

pub fn request_id(event: &Value) -> Option<&str> {
    Identifier::RequestId
        .find(|key| event.get("tags").and_then(|tags| tag(tags, key)))
        .or_else(|| header(event.pointer("/request/headers")?, "x-request-id"))
        .or_else(|| header(event.pointer("/contexts/request/headers")?, "x-request-id"))
}

pub fn service(event: &Value) -> Option<&str> {
    Identifier::Service.find(|key| event.get("tags").and_then(|tags| tag(tags, key)))
}

/// Tags are a map, or a list of `[key, value]` pairs in some SDKs.
fn tag<'a>(tags: &'a Value, key: &str) -> Option<&'a Value> {
    match tags {
        Value::Object(map) => map.get(key),
        Value::Array(pairs) => pairs
            .iter()
            .find_map(|pair| match pair.as_array()?.as_slice() {
                [name, value] if name.as_str() == Some(key) => Some(value),
                _ => None,
            }),
        _ => None,
    }
}

fn header<'a>(headers: &'a Value, name: &str) -> Option<&'a str> {
    let value = match headers {
        Value::Object(map) => map
            .iter()
            .find(|(key, _)| key.eq_ignore_ascii_case(name))
            .map(|(_, value)| value),
        Value::Array(pairs) => pairs
            .iter()
            .find_map(|pair| match pair.as_array()?.as_slice() {
                [key, value] if key.as_str().is_some_and(|k| k.eq_ignore_ascii_case(name)) => {
                    Some(value)
                }
                _ => None,
            }),
        _ => None,
    }?;
    value
        .as_str()
        .map(str::trim)
        .filter(|text| !text.is_empty() && text.len() <= MAX_IDENTIFIER)
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn reads_array_and_values_interfaces() {
        let elixir =
            json!({"exception": [{"type": "RuntimeError"}], "breadcrumbs": [{"message": "a"}]});
        let python = json!({"exception": {"values": [{"type": "ValueError"}]}});
        assert_eq!(values(&elixir, "exception")[0]["type"], "RuntimeError");
        assert_eq!(values(&elixir, "breadcrumbs")[0]["message"], "a");
        assert_eq!(values(&python, "exception")[0]["type"], "ValueError");
        assert_eq!(values(&python, "threads").len(), 0);
    }

    #[test]
    fn primary_frames_preserve_order_and_skip_empty_stacks() {
        for wrapped in [false, true] {
            let exceptions = json!([
                {"stacktrace": {"frames": [{"function": "inner_exception"}]}},
                {"stacktrace": {"frames": [{"function": "entry"}, {"function": "failure"}]}},
                {"type": "NoStack"}
            ]);
            let threads = json!([
                {"crashed": true},
                {"crashed": true, "stacktrace": {"frames": [{"function": "crashed"}]}},
                {"current": true, "stacktrace": {"frames": [{"function": "current"}]}}
            ]);
            let mut event = json!({
                "exception": if wrapped { json!({"values": exceptions}) } else { exceptions },
                "threads": if wrapped { json!({"values": threads}) } else { threads }
            });
            assert_eq!(
                primary_frames(&event),
                [json!({"function": "entry"}), json!({"function": "failure"})]
            );
            event.as_object_mut().unwrap().remove("exception");
            assert_eq!(primary_frames(&event), [json!({"function": "crashed"})]);
            let threads = if wrapped {
                &mut event["threads"]["values"]
            } else {
                &mut event["threads"]
            };
            threads.as_array_mut().unwrap().remove(1);
            assert_eq!(primary_frames(&event), [json!({"function": "current"})]);
        }
        assert!(primary_frames(&json!({"exception": [{"type": "NoStack"}]})).is_empty());
    }

    #[test]
    fn request_id_comes_from_tags_then_headers() {
        let tagged = json!({"tags": {"request_id": "req-1"}, "request": {"headers": {"X-Request-Id": "req-2"}}});
        let sentry = json!({"request": {"headers": [["X-Request-ID", "req-3"]]}});
        let native = json!({"contexts": {"request": {"headers": {"x-request-id": "req-4"}}}});
        assert_eq!(request_id(&tagged), Some("req-1"));
        assert_eq!(request_id(&sentry), Some("req-3"));
        assert_eq!(request_id(&native), Some("req-4"));
        assert_eq!(request_id(&json!({"tags": {"request_id": " "}})), None);
        assert_eq!(
            service(&json!({"tags": [["service.name", "billing"]]})),
            Some("billing")
        );
    }
}
