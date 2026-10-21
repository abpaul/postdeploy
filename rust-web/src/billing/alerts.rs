use sea_orm::ConnectionTrait;

use crate::{
    account_settings::{AccountMail, AccountMessage, MailFailure},
    domain::{now_secs, utc_day, OrgId},
    error::{ApiError, ApiResult},
    quota::month_usage,
    runtime::{sql, Runtime},
};

use super::{next_month_start, MONTHLY_ERRORS, MONTHLY_LOG_BYTES, THRESHOLDS};

const BATCH: i64 = 10;
const MAX_ATTEMPTS: i64 = 8;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Metric {
    Errors,
    LogBytes,
}

impl Metric {
    fn as_str(self) -> &'static str {
        match self {
            Self::Errors => "errors",
            Self::LogBytes => "log_bytes",
        }
    }

    fn parse(value: &str) -> Option<Self> {
        match value {
            "errors" => Some(Self::Errors),
            "log_bytes" => Some(Self::LogBytes),
            _ => None,
        }
    }

    fn limit(self) -> u64 {
        match self {
            Self::Errors => MONTHLY_ERRORS,
            Self::LogBytes => MONTHLY_LOG_BYTES,
        }
    }

    fn subject(self, percent: u8) -> &'static str {
        match (self, percent) {
            (Self::Errors, 70) => "PostDeploy: 70% of this month's error allowance used",
            (Self::Errors, 90) => "PostDeploy: 90% of this month's error allowance used",
            (Self::Errors, _) => "PostDeploy: monthly error allowance reached",
            (Self::LogBytes, 70) => "PostDeploy: 70% of this month's log allowance used",
            (Self::LogBytes, 90) => "PostDeploy: 90% of this month's log allowance used",
            (Self::LogBytes, _) => "PostDeploy: monthly log allowance reached",
        }
    }

    fn amount(self, value: u64) -> String {
        match self {
            Self::Errors => format!("{value} errors"),
            Self::LogBytes => format!("{:.1} GB of logs", value as f64 / 1e9),
        }
    }
}

/// Thresholds that `used` has reached against `limit`.
pub fn reached(used: u64, limit: u64) -> impl Iterator<Item = u8> {
    THRESHOLDS
        .into_iter()
        .filter(move |percent| u128::from(used) * 100 >= u128::from(limit) * u128::from(*percent))
}

/// Records every threshold that the month's committed `used` total has
/// reached. Call inside the transaction that commits that usage.
pub async fn record<C: ConnectionTrait>(
    conn: &C,
    day: &str,
    metric: Metric,
    used: u64,
) -> Result<(), sea_orm::DbErr> {
    for percent in reached(used, metric.limit()) {
        insert(conn, day, metric, percent).await?;
    }
    Ok(())
}

/// Records thresholds reached by committed usage after an allowance refusal.
pub async fn record_exhausted(rt: &Runtime, org: &OrgId, received: i64, metric: Metric) {
    let result = async {
        let handle = rt.tenant(org).await?;
        let day = utc_day(received);
        let usage = month_usage(&*handle, &day).await?;
        let used = match metric {
            Metric::Errors => usage.errors,
            Metric::LogBytes => usage.log_bytes,
        };
        record(&*handle, &day, metric, used).await?;
        Ok::<_, ApiError>(())
    }
    .await;
    if let Err(error) = result {
        tracing::warn!(org = %org, %error, "usage alert could not be recorded");
    }
}

async fn insert<C: ConnectionTrait>(
    conn: &C,
    day: &str,
    metric: Metric,
    percent: u8,
) -> Result<(), sea_orm::DbErr> {
    let now = now_secs();
    conn.execute_raw(sql(
        "INSERT INTO usage_alerts (month, metric, percent, reached_at, next_attempt_at)
         VALUES (?, ?, ?, ?, ?) ON CONFLICT (month, metric, percent) DO NOTHING",
        vec![
            day[..6].into(),
            metric.as_str().into(),
            i32::from(percent).into(),
            now.into(),
            now.into(),
        ],
    ))
    .await?;
    Ok(())
}

struct Due {
    month: String,
    metric: Metric,
    percent: u8,
    attempts: i64,
}

enum Delivery {
    Delivered,
    NotConfigured,
    Failed,
    Retry,
}

/// Emails due alerts of one organization to its owners. Returns how many
/// alerts reached a final state.
pub async fn deliver(rt: &Runtime, mail: &dyn AccountMail, org: &OrgId) -> ApiResult<u32> {
    deliver_at(rt, mail, org, now_secs()).await
}

pub async fn deliver_at(
    rt: &Runtime,
    mail: &dyn AccountMail,
    org: &OrgId,
    now: i64,
) -> ApiResult<u32> {
    let rows = {
        let handle = rt.tenant(org).await?;
        handle
            .query_all_raw(sql(
                "SELECT month, metric, percent, attempts FROM usage_alerts
                 WHERE state = 'pending' AND next_attempt_at <= ?
                 ORDER BY month, metric, percent LIMIT ?",
                vec![now.into(), BATCH.into()],
            ))
            .await?
    };
    let mut due = Vec::with_capacity(rows.len());
    for row in rows {
        let metric: String = row.try_get("", "metric")?;
        due.push(Due {
            month: row.try_get("", "month")?,
            metric: Metric::parse(&metric)
                .ok_or(ApiError::Internal("usage alert metric".into()))?,
            percent: u8::try_from(row.try_get::<i64>("", "percent")?)
                .map_err(|error| ApiError::internal("usage alert percent", error))?,
            attempts: row.try_get("", "attempts")?,
        });
    }
    if due.is_empty() {
        return Ok(0);
    }
    let owners = rt
        .control
        .query_all_raw(sql(
            "SELECT u.email, o.name FROM memberships m JOIN users u ON u.id = m.user_id
             JOIN organizations o ON o.id = m.org_id
             WHERE m.org_id = ? AND m.role = 'owner' AND o.lifecycle = 'active' ORDER BY u.id",
            vec![org.as_str().into()],
        ))
        .await?;
    let mut recipients = Vec::with_capacity(owners.len());
    let mut name = String::new();
    for row in owners {
        recipients.push(row.try_get::<String>("", "email")?);
        name = row.try_get("", "name")?;
    }
    let mut finished = 0;
    for alert in due {
        let used = {
            let handle = rt.tenant(org).await?;
            month_usage(&*handle, &format!("{}01", alert.month)).await?
        };
        let used = match alert.metric {
            Metric::Errors => used.errors,
            Metric::LogBytes => used.log_bytes,
        };
        let delivery = if !mail.configured() {
            Delivery::NotConfigured
        } else if recipients.is_empty() {
            Delivery::Failed
        } else {
            let text = message(rt, org, &name, &alert, used);
            let mut delivery = Delivery::Delivered;
            for to in &recipients {
                let message = AccountMessage::new(
                    to.clone(),
                    alert.metric.subject(alert.percent),
                    text.clone(),
                );
                match mail.send(message).await {
                    Ok(()) => {}
                    Err(MailFailure::Rejected) => delivery = Delivery::Failed,
                    Err(MailFailure::NotConfigured) => delivery = Delivery::NotConfigured,
                    Err(MailFailure::Unavailable) => {
                        delivery = Delivery::Retry;
                        break;
                    }
                }
            }
            delivery
        };
        let attempts = alert.attempts + 1;
        let (state, next) = match delivery {
            Delivery::Delivered => ("delivered", now),
            Delivery::NotConfigured => ("not_configured", now),
            Delivery::Failed => ("failed", now),
            Delivery::Retry if attempts >= MAX_ATTEMPTS => ("failed", now),
            Delivery::Retry => ("pending", now + 60 * (1 << attempts.min(6))),
        };
        let handle = rt.tenant(org).await?;
        handle
            .execute_raw(sql(
                "UPDATE usage_alerts SET state = ?, attempts = ?, next_attempt_at = ?,
                    finished_at = CASE WHEN ? = 'pending' THEN NULL ELSE ? END
                 WHERE month = ? AND metric = ? AND percent = ?",
                vec![
                    state.into(),
                    attempts.into(),
                    next.into(),
                    state.into(),
                    now.into(),
                    alert.month.clone().into(),
                    alert.metric.as_str().into(),
                    i32::from(alert.percent).into(),
                ],
            ))
            .await?;
        if state != "pending" {
            finished += 1;
        }
    }
    Ok(finished)
}

fn message(rt: &Runtime, org: &OrgId, name: &str, alert: &Due, used: u64) -> String {
    let month = format!("{}-{}", &alert.month[..4], &alert.month[4..6]);
    let resets = chrono::DateTime::from_timestamp(month_reset(&alert.month), 0)
        .unwrap_or_default()
        .format("%Y-%m-%d");
    let refused = match alert.metric {
        Metric::Errors => "new errors",
        Metric::LogBytes => "new logs",
    };
    format!(
        "{name} has used {} of {} in {month} (UTC), {}% of the monthly allowance.\n\n\
         When the allowance is used up, PostDeploy refuses {refused} until it resets on {resets} at 00:00 UTC. \
         Data already stored stays available.\n\n\
         Usage and billing: {}/dashboard/orgs/{org}\n",
        alert.metric.amount(used),
        alert.metric.amount(alert.metric.limit()),
        alert.percent,
        rt.settings.notifications.public_url.trim_end_matches('/'),
    )
}

fn month_reset(month: &str) -> i64 {
    let first = chrono::NaiveDate::parse_from_str(&format!("{month}01"), "%Y%m%d")
        .map(|date| {
            date.and_hms_opt(0, 0, 0)
                .unwrap_or_default()
                .and_utc()
                .timestamp()
        })
        .unwrap_or_default();
    next_month_start(first)
}
