//! Encryption of acknowledged log entries that wait in SQLite for archiving.
//! The record is redacted before it reaches this module. Each sealed value is
//! `nonce || AES-256-GCM(record JSON) || tag`. The associated data binds the
//! organization, object, entry position and the entry's partition columns, so
//! a moved or relabelled row fails to open.

use aes_gcm::{
    aead::{Aead, KeyInit, Payload},
    Aes256Gcm, Nonce,
};
use base64::Engine as _;
use credseal::SecretString;
use rand::RngCore;
use zeroize::Zeroizing;

use crate::{
    domain::OrgId,
    logs::{object::LogEntry, record::LogRecord},
};

const NONCE_LEN: usize = 12;
/// Bytes a sealed value adds to the record JSON.
pub const OVERHEAD: usize = NONCE_LEN + 16;

pub struct PendingCipher(Aes256Gcm);

#[derive(Debug, thiserror::Error)]
#[error("pending log entry failed authentication")]
pub struct Corrupt;

#[derive(Debug, thiserror::Error)]
#[error("credentials.security.data_key must be Base64 of 32 bytes")]
pub struct InvalidKey;

/// Position and partition of one pending entry.
pub struct Slot<'a> {
    pub org: &'a OrgId,
    pub object_id: i64,
    pub entry: u32,
    pub project: i64,
    pub source: i64,
    pub environment: &'a str,
    pub billable_bytes: u64,
}

impl Slot<'_> {
    fn aad(&self) -> String {
        format!(
            "postdeploy/log-pending/v1/{}/{}/{}/{}/{}/{}/{}",
            self.org,
            self.object_id,
            self.entry,
            self.project,
            self.source,
            self.environment,
            self.billable_bytes
        )
    }
}

impl PendingCipher {
    pub fn from_base64(key: &SecretString) -> Result<Self, InvalidKey> {
        let raw = Zeroizing::new(
            base64::engine::general_purpose::STANDARD
                .decode(key.expose_secret())
                .map_err(|_| InvalidKey)?,
        );
        Aes256Gcm::new_from_slice(&raw)
            .map(Self)
            .map_err(|_| InvalidKey)
    }

    pub fn seal(&self, slot: &Slot<'_>, record_json: &[u8]) -> Vec<u8> {
        let mut nonce = [0u8; NONCE_LEN];
        rand::rng().fill_bytes(&mut nonce);
        let aad = slot.aad();
        let ciphertext = self
            .0
            .encrypt(
                Nonce::from_slice(&nonce),
                Payload {
                    msg: record_json,
                    aad: aad.as_bytes(),
                },
            )
            .expect("AES-GCM encryption of a bounded record");
        let mut sealed = nonce.to_vec();
        sealed.extend_from_slice(&ciphertext);
        sealed
    }

    pub fn open(&self, slot: &Slot<'_>, sealed: &[u8]) -> Result<LogEntry, Corrupt> {
        if sealed.len() < OVERHEAD {
            return Err(Corrupt);
        }
        let (nonce, ciphertext) = sealed.split_at(NONCE_LEN);
        let aad = slot.aad();
        let plaintext = Zeroizing::new(
            self.0
                .decrypt(
                    Nonce::from_slice(nonce),
                    Payload {
                        msg: ciphertext,
                        aad: aad.as_bytes(),
                    },
                )
                .map_err(|_| Corrupt)?,
        );
        let record: LogRecord = serde_json::from_slice(&plaintext).map_err(|_| Corrupt)?;
        Ok(LogEntry {
            project: crate::domain::ProjectId(slot.project),
            source: crate::domain::SourceId(slot.source),
            environment: slot.environment.to_owned(),
            billable_bytes: slot.billable_bytes,
            record,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cipher() -> PendingCipher {
        PendingCipher(Aes256Gcm::new_from_slice(&[9u8; 32]).unwrap())
    }

    #[test]
    fn sealed_entries_open_only_at_their_own_position_and_partition() {
        let org = OrgId::generate();
        let slot = |entry, project| Slot {
            org: &org,
            object_id: 7,
            entry,
            project,
            source: 3,
            environment: "production",
            billable_bytes: 42,
        };
        let json = br#"{"ts":1,"rt":2,"level":"info","body":"pending-marker","attributes":{}}"#;
        let sealed = cipher().seal(&slot(0, 5), json);
        assert!(!sealed
            .windows(b"pending-marker".len())
            .any(|w| w == b"pending-marker"));
        let entry = cipher().open(&slot(0, 5), &sealed).unwrap();
        assert_eq!(entry.record.body.as_str(), "pending-marker");
        assert_eq!(entry.project.0, 5);
        assert!(cipher().open(&slot(1, 5), &sealed).is_err());
        assert!(cipher().open(&slot(0, 6), &sealed).is_err());
        let mut tampered = sealed.clone();
        *tampered.last_mut().unwrap() ^= 1;
        assert!(cipher().open(&slot(0, 5), &tampered).is_err());
    }
}
