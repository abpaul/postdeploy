use sea_orm::ConnectionTrait;

use crate::{
    account_settings::{AccountMail, AccountMessage, MailFailure},
    domain::{now_secs, OrgId},
    error::{ApiError, ApiResult},
    runtime::{sql, Runtime},
};

use super::{annual_price_label, TRIAL_SECS};

pub const NOTICE_LEAD_SECS: i64 = 3 * 86_400;
const MAX_ATTEMPTS: i64 = 8;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TrialNotice {
    EndsSoon,
    Ended,
}

impl TrialNotice {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::EndsSoon => "ends_soon",
            Self::Ended => "ended",
        }
    }
}

/// The notice due at `now` for an organization that has never had a paid period.
/// A stored `paid_until` of any time means the organization is not on the trial path.
/// At `created_at + TRIAL_SECS` the trial is over, so the ended notice replaces ends-soon.
/// The ended notice expires after `NOTICE_LEAD_SECS`, so trials that ended before
/// notices existed are never emailed.
pub fn due(created_at: i64, paid_until: Option<i64>, now: i64) -> Option<TrialNotice> {
    if paid_until.is_some() {
        return None;
    }
    let trial_end = created_at.saturating_add(TRIAL_SECS);
    if now >= trial_end.saturating_add(NOTICE_LEAD_SECS) {
        None
    } else if now >= trial_end {
        Some(TrialNotice::Ended)
    } else if now >= trial_end.saturating_sub(NOTICE_LEAD_SECS) {
        Some(TrialNotice::EndsSoon)
    } else {
        None
    }
}

pub fn ends_soon_subject() -> String {
    format!(
        "Your PostDeploy trial ends in {} days",
        NOTICE_LEAD_SECS / 86_400
    )
}

pub fn ended_subject() -> &'static str {
    "Your PostDeploy trial has ended"
}

pub fn ends_soon_body(name: &str, ends_at: i64, url: &str) -> String {
    format!(
        "The PostDeploy trial for {name} ends on {}.\n\n\
         After that time, PostDeploy stops accepting new errors and logs. \
         Stored data stays readable until it expires.\n\n\
         The plan is {} per organization.\n\n\
         Subscribe on the billing page: {url}\n",
        stamp(ends_at),
        annual_price_label(),
    )
}

pub fn ended_body(name: &str, url: &str) -> String {
    format!(
        "PostDeploy is refusing new errors and logs for {name} from now. \
         Stored data stays readable until it expires.\n\n\
         Subscribe on the billing page: {url}\n"
    )
}

fn stamp(secs: i64) -> String {
    chrono::DateTime::from_timestamp(secs, 0)
        .map(|time| time.format("%Y-%m-%d %H:%M:%S UTC").to_string())
        .unwrap_or_default()
}

fn billing_url(rt: &Runtime, org: &OrgId) -> String {
    format!(
        "{}/dashboard/orgs/{org}/billing",
        rt.settings.notifications.public_url.trim_end_matches('/')
    )
}

enum Delivery {
    Delivered,
    NotConfigured,
    Failed,
    Retry,
}

/// Emails the notice due for one organization. Each notice is sent at most once
/// across complete runs. Returns 1 when a notice reaches a final state.
pub async fn deliver(rt: &Runtime, mail: &dyn AccountMail, org: &OrgId) -> ApiResult<u32> {
    deliver_at(rt, mail, org, now_secs()).await
}

pub async fn deliver_at(
    rt: &Runtime,
    mail: &dyn AccountMail,
    org: &OrgId,
    now: i64,
) -> ApiResult<u32> {
    let Some(row) = rt
        .control
        .query_one_raw(sql(
            "SELECT o.created_at, o.name, o.lifecycle, b.paid_until
             FROM organizations o
             LEFT JOIN billing_accounts b ON b.org_id = o.id
             WHERE o.id = ?",
            vec![org.as_str().into()],
        ))
        .await?
    else {
        return Ok(0);
    };
    let lifecycle: String = row.try_get("", "lifecycle")?;
    if lifecycle != "active" {
        return Ok(0);
    }
    let created_at: i64 = row.try_get("", "created_at")?;
    let name: String = row.try_get("", "name")?;
    let paid_until: Option<i64> = row.try_get("", "paid_until")?;
    let Some(notice) = due(created_at, paid_until, now) else {
        return Ok(0);
    };
    rt.control
        .execute_raw(sql(
            "INSERT INTO trial_notices (org_id, notice, state, attempts, next_attempt_at)
             VALUES (?, ?, 'pending', 0, ?)
             ON CONFLICT (org_id, notice) DO NOTHING",
            vec![org.as_str().into(), notice.as_str().into(), now.into()],
        ))
        .await?;
    let claimed = rt
        .control
        .query_one_raw(sql(
            "SELECT state, attempts, next_attempt_at FROM trial_notices
             WHERE org_id = ? AND notice = ?",
            vec![org.as_str().into(), notice.as_str().into()],
        ))
        .await?
        .ok_or(ApiError::Internal("trial notice row".into()))?;
    let state: String = claimed.try_get("", "state")?;
    let attempts: i64 = claimed.try_get("", "attempts")?;
    let next_attempt_at: i64 = claimed.try_get("", "next_attempt_at")?;
    if state != "pending" || next_attempt_at > now {
        return Ok(0);
    }
    let owners = rt
        .control
        .query_all_raw(sql(
            "SELECT u.email FROM memberships m
             JOIN users u ON u.id = m.user_id
             JOIN organizations o ON o.id = m.org_id
             WHERE m.org_id = ? AND m.role = 'owner' AND o.lifecycle = 'active'
             ORDER BY u.id",
            vec![org.as_str().into()],
        ))
        .await?;
    let mut recipients = Vec::with_capacity(owners.len());
    for row in owners {
        recipients.push(row.try_get::<String>("", "email")?);
    }
    let ends_at = created_at.saturating_add(TRIAL_SECS);
    let url = billing_url(rt, org);
    let (subject, text) = match notice {
        TrialNotice::EndsSoon => (ends_soon_subject(), ends_soon_body(&name, ends_at, &url)),
        TrialNotice::Ended => (ended_subject().to_owned(), ended_body(&name, &url)),
    };
    let delivery = if !mail.configured() {
        Delivery::NotConfigured
    } else if recipients.is_empty() {
        Delivery::Failed
    } else {
        let mut delivery = Delivery::Delivered;
        for to in &recipients {
            match mail
                .send(AccountMessage::new(
                    to.clone(),
                    subject.clone(),
                    text.clone(),
                ))
                .await
            {
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
    let attempts = attempts + 1;
    let (state, next) = match delivery {
        Delivery::Delivered => ("delivered", now),
        Delivery::NotConfigured => ("not_configured", now),
        Delivery::Failed => ("failed", now),
        Delivery::Retry if attempts >= MAX_ATTEMPTS => ("failed", now),
        Delivery::Retry => ("pending", now + 60 * (1 << attempts.min(6))),
    };
    rt.control
        .execute_raw(sql(
            "UPDATE trial_notices SET state = ?, attempts = ?, next_attempt_at = ?,
                finished_at = CASE WHEN ? = 'pending' THEN NULL ELSE ? END
             WHERE org_id = ? AND notice = ?",
            vec![
                state.into(),
                attempts.into(),
                next.into(),
                state.into(),
                now.into(),
                org.as_str().into(),
                notice.as_str().into(),
            ],
        ))
        .await?;
    Ok(u32::from(state != "pending"))
}
