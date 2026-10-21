pub mod access;
pub mod accounts;
pub mod orgs;
pub mod projects;

use base64::Engine as _;
use sha2::{Digest, Sha256};

pub(crate) fn random_token() -> String {
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(rand::random::<[u8; 32]>())
}

pub(crate) fn token_hash(token: &str) -> Vec<u8> {
    Sha256::digest(token.as_bytes()).to_vec()
}
