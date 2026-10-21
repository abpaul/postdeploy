//! Per-request accounting of ingested items. Every item that is not stored
//! has exactly one reason; accepted items that were shortened to fit a bound
//! also carry a reason. Reason codes are a closed set, so receipts, counters
//! and logs never echo client text.

use std::collections::BTreeMap;

use sea_orm::ConnectionTrait;
use serde::Serialize;

use crate::{
    domain::OrgId,
    error::ApiResult,
    runtime::{sql, Runtime},
};

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Category {
    Error,
    Log,
    Other,
}

impl Category {
    const ALL: [Self; 3] = [Self::Error, Self::Log, Self::Other];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Error => "error",
            Self::Log => "log",
            Self::Other => "other",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    Accepted,
    Duplicate,
    Filtered,
    Sampled,
    Unsupported,
    Invalid,
}

impl Outcome {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Accepted => "accepted",
            Self::Duplicate => "duplicate",
            Self::Filtered => "filtered",
            Self::Sampled => "sampled",
            Self::Unsupported => "unsupported",
            Self::Invalid => "invalid",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Reason {
    Malformed,
    MissingEventId,
    TooLarge,
    InvalidEntry,
    RecordTooLarge,
    ExceptionTypeExcluded,
    LevelDisabled,
    SampleRate,
    DuplicateEventId,
    UnsupportedItemType,
    BodyTruncated,
    AttributeDropped,
    TimestampAdjusted,
}

impl Reason {
    const ALL: [Self; 13] = [
        Self::Malformed,
        Self::MissingEventId,
        Self::TooLarge,
        Self::InvalidEntry,
        Self::RecordTooLarge,
        Self::ExceptionTypeExcluded,
        Self::LevelDisabled,
        Self::SampleRate,
        Self::DuplicateEventId,
        Self::UnsupportedItemType,
        Self::BodyTruncated,
        Self::AttributeDropped,
        Self::TimestampAdjusted,
    ];

    pub fn code(self) -> &'static str {
        match self {
            Self::Malformed => "malformed",
            Self::MissingEventId => "missing_event_id",
            Self::TooLarge => "too_large",
            Self::InvalidEntry => "invalid_entry",
            Self::RecordTooLarge => "record_too_large",
            Self::ExceptionTypeExcluded => "exception_type_excluded",
            Self::LevelDisabled => "level_disabled",
            Self::SampleRate => "sample_rate",
            Self::DuplicateEventId => "duplicate_event_id",
            Self::UnsupportedItemType => "unsupported_item_type",
            Self::BodyTruncated => "body_truncated",
            Self::AttributeDropped => "attribute_dropped",
            Self::TimestampAdjusted => "timestamp_adjusted",
        }
    }

    fn parse(code: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|reason| reason.code() == code)
    }

    /// `Accepted` reasons mark a stored item clipped to fit a bound.
    pub fn outcome(self) -> Outcome {
        match self {
            Self::Malformed
            | Self::MissingEventId
            | Self::TooLarge
            | Self::InvalidEntry
            | Self::RecordTooLarge => Outcome::Invalid,
            Self::ExceptionTypeExcluded | Self::LevelDisabled => Outcome::Filtered,
            Self::SampleRate => Outcome::Sampled,
            Self::DuplicateEventId => Outcome::Duplicate,
            Self::UnsupportedItemType => Outcome::Unsupported,
            Self::BodyTruncated | Self::AttributeDropped | Self::TimestampAdjusted => {
                Outcome::Accepted
            }
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Receipt {
    accepted: [u64; 3],
    reasons: BTreeMap<(Category, Reason), u64>,
}

#[derive(Debug, Default, Serialize, PartialEq, Eq)]
pub struct Counts {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub accepted: Option<u64>,
    pub duplicate: u64,
    pub filtered: u64,
    pub sampled: u64,
    pub unsupported: u64,
    pub invalid: u64,
    pub reasons: BTreeMap<&'static str, u64>,
}

/// Counts for the error, log and other categories.
#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct Report {
    pub error: Counts,
    pub log: Counts,
    pub other: Counts,
}

impl Receipt {
    pub fn accept(&mut self, category: Category, count: u64) {
        self.accepted[category as usize] += count;
    }

    pub fn record(&mut self, category: Category, reason: Reason, count: u64) {
        if count > 0 {
            *self.reasons.entry((category, reason)).or_default() += count;
        }
    }

    pub fn invalid(&self, category: Category) -> u64 {
        self.counts(category, None).invalid
    }

    fn counts(&self, category: Category, accepted: Option<u64>) -> Counts {
        let mut counts = Counts {
            accepted,
            ..Counts::default()
        };
        for ((_, reason), count) in self.reasons.iter().filter(|((c, _), _)| *c == category) {
            counts.reasons.insert(reason.code(), *count);
            match reason.outcome() {
                Outcome::Accepted => {}
                Outcome::Duplicate => counts.duplicate += count,
                Outcome::Filtered => counts.filtered += count,
                Outcome::Sampled => counts.sampled += count,
                Outcome::Unsupported => counts.unsupported += count,
                Outcome::Invalid => counts.invalid += count,
            }
        }
        counts
    }

    fn report(&self, with_accepted: bool) -> Report {
        let [error, log, other] = Category::ALL.map(|category| {
            self.counts(
                category,
                with_accepted.then_some(self.accepted[category as usize]),
            )
        });
        Report { error, log, other }
    }

    /// The response body section for one request.
    pub fn response(&self) -> Report {
        self.report(true)
    }

    /// Adds the reason counts to the organization's daily counters.
    pub async fn persist(&self, rt: &Runtime, org: &OrgId, day: &str) -> ApiResult<()> {
        if self.reasons.is_empty() {
            return Ok(());
        }
        let rows = vec!["(?, ?, ?, ?, ?)"; self.reasons.len()].join(", ");
        let mut values: Vec<sea_orm::Value> = Vec::with_capacity(self.reasons.len() * 5);
        for ((category, reason), count) in &self.reasons {
            values.extend([
                day.into(),
                category.as_str().into(),
                reason.outcome().as_str().into(),
                reason.code().into(),
                i64::try_from(*count).unwrap_or(i64::MAX).into(),
            ]);
        }
        let handle = rt.tenant(org).await?;
        handle
            .execute_raw(sql(
                &format!(
                    "INSERT INTO ingest_outcomes_daily (day, category, outcome, reason, count)
                     VALUES {rows}
                     ON CONFLICT (day, category, reason) DO UPDATE SET count = count + excluded.count"
                ),
                values,
            ))
            .await?;
        Ok(())
    }
}

/// Sums of the persisted counters from `first_day` to `last_day` inclusive.
pub async fn refused_between(
    conn: &impl ConnectionTrait,
    first_day: &str,
    last_day: &str,
) -> ApiResult<Report> {
    let rows = conn
        .query_all_raw(sql(
            "SELECT category, reason, SUM(count) AS count FROM ingest_outcomes_daily
             WHERE day >= ? AND day <= ? GROUP BY category, reason",
            vec![first_day.into(), last_day.into()],
        ))
        .await?;
    let mut receipt = Receipt::default();
    for row in rows {
        let category: String = row.try_get("", "category")?;
        let code: String = row.try_get("", "reason")?;
        let count: i64 = row.try_get("", "count")?;
        let category = Category::ALL
            .into_iter()
            .find(|c| c.as_str() == category)
            .ok_or_else(|| crate::error::ApiError::Internal("stored outcome category".into()))?;
        let reason = Reason::parse(&code)
            .ok_or_else(|| crate::error::ApiError::Internal("stored outcome reason".into()))?;
        receipt.record(category, reason, u64::try_from(count).unwrap_or(0));
    }
    Ok(receipt.report(false))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_reason_code_round_trips() {
        for reason in Reason::ALL {
            assert_eq!(Reason::parse(reason.code()), Some(reason));
        }
        assert_eq!(Reason::parse("Malformed"), None);
    }
}
