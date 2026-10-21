//! Immutable R2 log objects: key layout and the compressed NDJSON codec.
//! Each object holds one organization batch: a [`BatchHeader`] line with the
//! metadata row identity and a digest of the entry lines, then one
//! [`LogEntry`] per line.

use std::io::Read;

use bytes::Bytes;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::{
    domain::{Environment, OrgId, ProjectId, SourceId},
    logs::record::LogRecord,
};

pub const BLOOM_BYTES: usize = 256;

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Partition {
    pub org: OrgId,
    pub project: ProjectId,
    pub source: SourceId,
    pub environment: Environment,
}

impl Partition {
    pub fn org_prefix(org: &OrgId) -> String {
        format!("logs/v1/{org}/")
    }

    /// `logs/v1/{org}/v2/{yyyymmddhh}/{batch}.ndjson.zst`. Batch keys stay
    /// below the organization prefix that deletion fences and cleans.
    pub fn batch_key(org: &OrgId, opened_us: i64) -> String {
        let hour = chrono::DateTime::from_timestamp_micros(opened_us)
            .unwrap_or_default()
            .format("%Y%m%d%H");
        format!(
            "logs/v1/{org}/v2/{hour}/{}.ndjson.zst",
            uuid::Uuid::now_v7().simple()
        )
    }
}

/// One accepted log entry of a batch with its own partition.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct LogEntry {
    pub project: ProjectId,
    pub source: SourceId,
    pub environment: String,
    /// Accepted bytes billed for this entry: [`LogRecord::approx_bytes`].
    pub billable_bytes: u64,
    pub record: LogRecord,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct BatchHeader {
    pub v: u8,
    pub key: String,
    pub org: OrgId,
    pub object_id: i64,
    pub usage_day: String,
    pub opened_at: i64,
    pub count: u32,
    pub raw_bytes: u64,
    pub min_ts: i64,
    pub max_ts: i64,
    pub received_at: i64,
    pub level_mask: u8,
    pub trace_bloom: String,
    /// SHA-256 of the canonical entry lines.
    pub sha256: String,
}

impl BatchHeader {
    pub fn bloom(&self) -> Vec<u8> {
        hex::decode(&self.trace_bloom).unwrap_or_else(|_| vec![0xff; BLOOM_BYTES])
    }

    pub fn digest(&self) -> Vec<u8> {
        hex::decode(&self.sha256).unwrap_or_default()
    }
}

/// The metadata row a batch object belongs to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BatchIdentity {
    pub org: OrgId,
    pub object_id: i64,
    pub key: String,
    pub usage_day: String,
    pub opened_at: i64,
}

impl BatchIdentity {
    pub fn matches(&self, header: &BatchHeader) -> bool {
        header.org == self.org
            && header.object_id == self.object_id
            && header.key == self.key
            && header.usage_day == self.usage_day
            && header.opened_at == self.opened_at
    }
}

/// Entry metadata summarized over a batch or a contiguous run.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Summary {
    pub min_ts: i64,
    pub max_ts: i64,
    pub received_at: i64,
    pub level_mask: u8,
    pub raw_bytes: u64,
    pub bloom: Vec<u8>,
}

impl Summary {
    pub fn of<'a>(records: impl IntoIterator<Item = (&'a LogRecord, u64)>) -> Self {
        let mut summary = Self {
            min_ts: i64::MAX,
            max_ts: i64::MIN,
            received_at: i64::MIN,
            level_mask: 0,
            raw_bytes: 0,
            bloom: vec![0; BLOOM_BYTES],
        };
        for (record, billable) in records {
            summary.min_ts = summary.min_ts.min(record.ts);
            summary.max_ts = summary.max_ts.max(record.ts);
            summary.received_at = summary.received_at.max(record.rt);
            summary.level_mask |= record.level.bit();
            summary.raw_bytes = summary.raw_bytes.saturating_add(billable);
            if let Some(trace) = &record.trace_id {
                bloom_insert(&mut summary.bloom, trace);
            }
        }
        summary
    }
}

pub struct EncodedBatch {
    pub header: BatchHeader,
    pub body: Bytes,
}

pub fn entry_lines(entries: &[LogEntry]) -> std::io::Result<Vec<u8>> {
    let mut lines = Vec::new();
    for entry in entries {
        serde_json::to_writer(&mut lines, entry)?;
        lines.push(b'\n');
    }
    Ok(lines)
}

pub fn encode_batch(
    identity: &BatchIdentity,
    entries: &[LogEntry],
) -> std::io::Result<EncodedBatch> {
    let lines = entry_lines(entries)?;
    let summary = Summary::of(entries.iter().map(|e| (&e.record, e.billable_bytes)));
    let header = BatchHeader {
        v: 2,
        key: identity.key.clone(),
        org: identity.org.clone(),
        object_id: identity.object_id,
        usage_day: identity.usage_day.clone(),
        opened_at: identity.opened_at,
        count: entries.len() as u32,
        raw_bytes: summary.raw_bytes,
        min_ts: summary.min_ts,
        max_ts: summary.max_ts,
        received_at: summary.received_at,
        level_mask: summary.level_mask,
        trace_bloom: hex::encode(&summary.bloom),
        sha256: hex::encode(Sha256::digest(&lines)),
    };
    let mut raw = serde_json::to_vec(&header)?;
    raw.push(b'\n');
    raw.extend_from_slice(&lines);
    let body = zstd::stream::encode_all(&raw[..], 3)?;
    Ok(EncodedBatch {
        header,
        body: Bytes::from(body),
    })
}

#[derive(Debug, thiserror::Error)]
pub enum DecodeError {
    #[error("object is not valid zstd")]
    Compression,
    #[error("object exceeds the decompressed limit")]
    TooLarge,
    #[error("object header or entry is invalid")]
    Invalid,
}

#[derive(Deserialize)]
struct Version {
    v: u8,
}

/// Decompresses at most `max_raw` bytes and returns the header and entries.
/// A digest or count mismatch is invalid.
pub fn decode(body: &[u8], max_raw: usize) -> Result<(BatchHeader, Vec<LogEntry>), DecodeError> {
    let raw = inflate(body, max_raw)?;
    let (first, rest) = split_header(&raw)?;
    let version: Version = serde_json::from_slice(first).map_err(|_| DecodeError::Invalid)?;
    if version.v != 2 {
        return Err(DecodeError::Invalid);
    }
    parse_batch(first, rest)
}

/// A verified object with its canonical entry lines exactly as
/// stored. Equality with a local batch is decided on these bytes.
pub struct StoredBatch {
    pub header: BatchHeader,
    pub entries: Vec<LogEntry>,
    pub lines: Vec<u8>,
}

pub fn decode_batch(body: &[u8], max_raw: usize) -> Result<StoredBatch, DecodeError> {
    let mut raw = inflate(body, max_raw)?;
    let (first, rest) = split_header(&raw)?;
    let version: Version = serde_json::from_slice(first).map_err(|_| DecodeError::Invalid)?;
    if version.v != 2 {
        return Err(DecodeError::Invalid);
    }
    let (header, entries) = parse_batch(first, rest)?;
    let start = first.len() + 1;
    raw.drain(..start);
    Ok(StoredBatch {
        header,
        entries,
        lines: raw,
    })
}

fn inflate(body: &[u8], max_raw: usize) -> Result<Vec<u8>, DecodeError> {
    let mut raw = Vec::new();
    zstd::stream::read::Decoder::new(body)
        .map_err(|_| DecodeError::Compression)?
        .take(max_raw as u64 + 1)
        .read_to_end(&mut raw)
        .map_err(|_| DecodeError::Compression)?;
    if raw.len() > max_raw {
        return Err(DecodeError::TooLarge);
    }
    Ok(raw)
}

fn split_header(raw: &[u8]) -> Result<(&[u8], &[u8]), DecodeError> {
    let split = raw
        .iter()
        .position(|&b| b == b'\n')
        .ok_or(DecodeError::Invalid)?;
    Ok((&raw[..split], &raw[split + 1..]))
}

fn lines(rest: &[u8]) -> impl Iterator<Item = &[u8]> {
    rest.split(|&b| b == b'\n').filter(|line| !line.is_empty())
}

fn parse_batch(first: &[u8], rest: &[u8]) -> Result<(BatchHeader, Vec<LogEntry>), DecodeError> {
    let header: BatchHeader = serde_json::from_slice(first).map_err(|_| DecodeError::Invalid)?;
    if hex::encode(Sha256::digest(rest)) != header.sha256 {
        return Err(DecodeError::Invalid);
    }
    let entries = lines(rest)
        .map(|line| serde_json::from_slice(line).map_err(|_| DecodeError::Invalid))
        .collect::<Result<Vec<LogEntry>, _>>()?;
    if entries.len() != header.count as usize {
        return Err(DecodeError::Invalid);
    }
    Ok((header, entries))
}

fn bloom_positions(trace: &str) -> [usize; 3] {
    let digest = Sha256::digest(trace.as_bytes());
    let bits = BLOOM_BYTES * 8;
    [0, 2, 4].map(|i| usize::from(u16::from_be_bytes([digest[i], digest[i + 1]])) % bits)
}

pub fn bloom_insert(bloom: &mut [u8], trace: &str) {
    for bit in bloom_positions(trace) {
        bloom[bit / 8] |= 1 << (bit % 8);
    }
}

pub fn bloom_contains(bloom: &[u8], trace: &str) -> bool {
    bloom.len() == BLOOM_BYTES
        && bloom_positions(trace)
            .iter()
            .all(|bit| bloom[bit / 8] & (1 << (bit % 8)) != 0)
}
