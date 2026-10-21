use std::{fmt, str::FromStr};

use serde::{Deserialize, Serialize};
use tenant_sqlite_loco::TenantId;

/// Organization identity. Also names the organization's tenant database file.
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize)]
#[serde(transparent)]
pub struct OrgId(String);

impl OrgId {
    pub fn generate() -> Self {
        Self(format!("o{}", uuid::Uuid::now_v7().simple()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub(crate) fn tenant(&self) -> TenantId {
        TenantId::new(self.0.clone()).expect("OrgId is a valid tenant id by construction")
    }
}

impl FromStr for OrgId {
    type Err = ();

    fn from_str(value: &str) -> Result<Self, ()> {
        let valid = value.len() == 33
            && value.starts_with('o')
            && value[1..]
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b));
        valid.then(|| Self(value.to_owned())).ok_or(())
    }
}

impl fmt::Display for OrgId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl<'de> Deserialize<'de> for OrgId {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = String::deserialize(deserializer)?;
        value
            .parse()
            .map_err(|()| serde::de::Error::custom("invalid organization id"))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(transparent)]
pub struct UserId(pub i64);

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ProjectId(pub i64);

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(transparent)]
pub struct SourceId(pub i64);

/// Source environment, such as `production`. Groups issues and partitions log objects.
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize)]
#[serde(transparent)]
pub struct Environment(String);

impl Environment {
    pub fn parse(value: &str) -> Option<Self> {
        let value = value.trim().to_ascii_lowercase();
        let valid = !value.is_empty()
            && value.len() <= 32
            && value
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-' || b == b'_');
        valid.then_some(Self(value))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for Environment {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    Owner,
    Admin,
    Member,
}

impl Role {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Owner => "owner",
            Self::Admin => "admin",
            Self::Member => "member",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "owner" => Some(Self::Owner),
            "admin" => Some(Self::Admin),
            "member" => Some(Self::Member),
            _ => None,
        }
    }

    pub fn can_manage(self) -> bool {
        matches!(self, Self::Owner | Self::Admin)
    }
}

pub fn now_micros() -> i64 {
    chrono::Utc::now().timestamp_micros()
}

pub fn now_secs() -> i64 {
    chrono::Utc::now().timestamp()
}

pub fn utc_day(micros: i64) -> String {
    chrono::DateTime::from_timestamp_micros(micros)
        .unwrap_or_default()
        .format("%Y%m%d")
        .to_string()
}
