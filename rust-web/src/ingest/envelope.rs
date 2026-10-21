use std::io::Read;

use bytes::Bytes;
use serde::Deserialize;

#[derive(Debug, PartialEq, Eq, thiserror::Error)]
pub enum DecodeError {
    #[error("unsupported content encoding")]
    UnsupportedEncoding,
    #[error("body exceeds the inflated limit")]
    TooLarge,
    #[error("invalid compressed body")]
    InvalidCompression,
    #[error("invalid envelope")]
    Invalid,
    #[error("too many envelope items")]
    TooManyItems,
}

pub struct Limits {
    pub max_inflated_bytes: usize,
    pub max_items: usize,
    pub max_events: usize,
}

#[derive(Default)]
pub struct Envelope {
    pub event_id: Option<String>,
    pub events: Vec<Bytes>,
    pub logs: Vec<Bytes>,
    /// Item types this server does not ingest, such as sessions and transactions.
    pub skipped: u32,
}

impl std::fmt::Debug for Envelope {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Envelope")
            .field("events", &self.events.len())
            .field("logs", &self.logs.len())
            .field("skipped", &self.skipped)
            .finish()
    }
}

pub fn inflate(encoding: Option<&str>, body: Bytes, max: usize) -> Result<Bytes, DecodeError> {
    let encoding = encoding.map(|value| value.trim().to_ascii_lowercase());
    let mut out = Vec::new();
    let read = |reader: &mut dyn Read, out: &mut Vec<u8>| {
        reader
            .take(max as u64 + 1)
            .read_to_end(out)
            .map_err(|_| DecodeError::InvalidCompression)?;
        if out.len() > max {
            return Err(DecodeError::TooLarge);
        }
        Ok(())
    };
    match encoding.as_deref() {
        None | Some("" | "identity") => {
            if body.len() > max {
                return Err(DecodeError::TooLarge);
            }
            return Ok(body);
        }
        Some("gzip" | "x-gzip") => {
            read(&mut flate2::read::MultiGzDecoder::new(&body[..]), &mut out)?
        }
        Some("deflate") => {
            if read(&mut flate2::read::ZlibDecoder::new(&body[..]), &mut out).is_err() {
                out.clear();
                read(&mut flate2::read::DeflateDecoder::new(&body[..]), &mut out)?;
            }
        }
        Some(_) => return Err(DecodeError::UnsupportedEncoding),
    }
    Ok(Bytes::from(out.into_boxed_slice()))
}

#[derive(Deserialize)]
struct EnvelopeHeader {
    event_id: Option<String>,
}

#[derive(Deserialize)]
struct ItemHeader {
    #[serde(rename = "type")]
    kind: String,
    length: Option<usize>,
}

pub fn parse(body: &Bytes, limits: &Limits) -> Result<Envelope, DecodeError> {
    let mut rest = body.clone();
    let header = take_line(&mut rest).ok_or(DecodeError::Invalid)?;
    let header: EnvelopeHeader =
        serde_json::from_slice(&header).map_err(|_| DecodeError::Invalid)?;
    let mut envelope = Envelope {
        event_id: header.event_id.and_then(|id| normalize_event_id(&id)),
        ..Envelope::default()
    };
    let mut lines = 0usize;
    while !rest.is_empty() {
        lines += 1;
        if lines > limits.max_items {
            return Err(DecodeError::TooManyItems);
        }
        let line = take_line(&mut rest).ok_or(DecodeError::Invalid)?;
        if line.iter().all(u8::is_ascii_whitespace) {
            continue;
        }
        let item: ItemHeader = serde_json::from_slice(&line).map_err(|_| DecodeError::Invalid)?;
        let payload = match item.length {
            Some(length) => {
                if length > rest.len() {
                    return Err(DecodeError::Invalid);
                }
                let payload = rest.split_to(length);
                match rest.first() {
                    None => {}
                    Some(b'\n') => {
                        let _ = rest.split_to(1);
                    }
                    Some(_) => return Err(DecodeError::Invalid),
                }
                payload
            }
            None => take_line(&mut rest).unwrap_or_default(),
        };
        match item.kind.as_str() {
            "event" => {
                if envelope.events.len() == limits.max_events {
                    return Err(DecodeError::TooManyItems);
                }
                envelope.events.push(payload);
            }
            "log" => envelope.logs.push(payload),
            _ => envelope.skipped += 1,
        }
    }
    Ok(envelope)
}

fn take_line(rest: &mut Bytes) -> Option<Bytes> {
    if rest.is_empty() {
        return None;
    }
    match rest.iter().position(|&b| b == b'\n') {
        Some(at) => {
            let line = rest.split_to(at);
            let _ = rest.split_to(1);
            Some(line)
        }
        None => Some(rest.split_to(rest.len())),
    }
}

/// Sentry event ids are 32 hex digits; SDKs may send the dashed UUID form.
pub fn normalize_event_id(value: &str) -> Option<String> {
    let id: String = value
        .chars()
        .filter(|c| *c != '-')
        .map(|c| c.to_ascii_lowercase())
        .collect();
    (id.len() == 32 && id.bytes().all(|b| b.is_ascii_hexdigit())).then_some(id)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn limits() -> Limits {
        Limits {
            max_inflated_bytes: 1 << 20,
            max_items: 10,
            max_events: 2,
        }
    }

    #[test]
    fn splits_length_prefixed_and_line_items_and_counts_unknown_types() {
        let body = Bytes::from_static(
            b"{\"event_id\":\"9ec79c33-ec99-42ab-8353-589fcb2e04dc\"}\n\
{\"type\":\"event\",\"length\":7}\n{\"a\":1}\n\
{\"type\":\"session\"}\n{\"started\":1}\n\
{\"type\":\"log\"}\n{\"items\":[]}\n",
        );
        let envelope = parse(&body, &limits()).unwrap();
        assert_eq!(
            envelope.event_id.as_deref(),
            Some("9ec79c33ec9942ab8353589fcb2e04dc")
        );
        assert_eq!(envelope.events, vec![Bytes::from_static(b"{\"a\":1}")]);
        assert_eq!(envelope.logs, vec![Bytes::from_static(b"{\"items\":[]}")]);
        assert_eq!(envelope.skipped, 1);
    }

    #[test]
    fn rejects_trailing_bytes_after_length_and_item_floods() {
        let bad = Bytes::from_static(b"{}\n{\"type\":\"event\",\"length\":2}\n{}x\n");
        assert_eq!(parse(&bad, &limits()).unwrap_err(), DecodeError::Invalid);
        let flood = Bytes::from(format!("{{}}\n{}", "{\"type\":\"x\"}\n{}\n".repeat(11)));
        assert_eq!(
            parse(&flood, &limits()).unwrap_err(),
            DecodeError::TooManyItems
        );
    }

    #[test]
    fn inflates_gzip_within_limit_and_rejects_unknown_encodings() {
        use std::io::Write;
        let mut encoder = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
        encoder.write_all(&[b'a'; 100]).unwrap();
        let gz = Bytes::from(encoder.finish().unwrap());
        assert_eq!(inflate(Some("gzip"), gz.clone(), 100).unwrap().len(), 100);
        assert_eq!(
            inflate(Some("gzip"), gz, 99).unwrap_err(),
            DecodeError::TooLarge
        );
        assert_eq!(
            inflate(Some("br"), Bytes::new(), 10).unwrap_err(),
            DecodeError::UnsupportedEncoding
        );
    }
}
