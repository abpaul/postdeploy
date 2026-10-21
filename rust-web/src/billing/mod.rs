//! Paid time is the latest service-period end of a settled
//! annual-plan invoice and never decreases. Checkout redirects and
//! subscription status grant no access.

pub mod alerts;
pub mod notices;
pub mod stripe;

use std::time::Duration;

use axum::{
    http::{header, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use chrono::{Datelike, TimeZone};
use loco_rs::{Error, Result};
use sea_orm::ConnectionTrait;
use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::{
    credentials::StripeCredentials,
    domain::{now_micros, now_secs, utc_day, OrgId, Role},
    error::{ApiError, ApiResult},
    identity::access::OrgAccess,
    quota::{month_usage, Usage},
    runtime::{sql, Runtime},
    settings::Settings,
};

use self::stripe::{CheckoutRequest, Invoice, Price, Stripe, StripeError};

pub const PLAN_PRICE_CENTS: i64 = 44_900;
pub const PLAN_CURRENCY: &str = "usd";
pub const TRIAL_SECS: i64 = 1_209_600;
pub const MONTHLY_ERRORS: u64 = 1_000_000;
pub const MONTHLY_LOG_BYTES: u64 = 100_000_000_000;
pub const THRESHOLDS: [u8; 3] = [70, 90, 100];
pub const RENEWAL_GRACE_SECS: i64 = 3 * 86_400;
const SUBSCRIPTION_RETRY_SECS: u64 = 600;
const RECEIPT_RETENTION_SECS: i64 = 90 * 86_400;
const YEAR_MIN_SECS: i64 = 365 * 86_400 - 3_600;
const YEAR_MAX_SECS: i64 = 366 * 86_400 + 3_600;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum Entitlement {
    Trial { ends_at: i64 },
    Paid { until: i64 },
    SubscriptionRequired { since: i64 },
}

impl Entitlement {
    /// `created_at` and `paid_until` are Unix seconds. Both periods end at
    /// their boundary second: at `created_at + TRIAL_SECS` the trial is over.
    /// A paid period keeps telemetry for `RENEWAL_GRACE_SECS` after it ends,
    /// because Stripe finalizes a renewal invoice up to an hour after the
    /// period boundary and its webhook can arrive later still.
    pub fn at(created_at: i64, paid_until: Option<i64>, now: i64) -> Self {
        let trial_end = created_at.saturating_add(TRIAL_SECS);
        match paid_until {
            Some(until) if now < until => Self::Paid { until },
            _ if now < trial_end => Self::Trial { ends_at: trial_end },
            Some(until) if now < until.saturating_add(RENEWAL_GRACE_SECS) => Self::Paid { until },
            paid => Self::SubscriptionRequired {
                since: paid.map_or(trial_end, |until| {
                    until.saturating_add(RENEWAL_GRACE_SECS).max(trial_end)
                }),
            },
        }
    }

    pub fn accepts_telemetry(self) -> bool {
        !matches!(self, Self::SubscriptionRequired { .. })
    }
}

/// First and last `usage_daily.day` keys of the UTC month containing `day`.
pub fn month_days(day: &str) -> (String, String) {
    let month = &day[..6];
    (format!("{month}01"), format!("{month}31"))
}

pub fn next_month_start(now: i64) -> i64 {
    let at = chrono::Utc
        .timestamp_opt(now, 0)
        .single()
        .unwrap_or_default();
    let (year, month) = if at.month() == 12 {
        (at.year() + 1, 1)
    } else {
        (at.year(), at.month() + 1)
    };
    chrono::Utc
        .with_ymd_and_hms(year, month, 1, 0, 0, 0)
        .single()
        .map_or(now + 86_400, |start| start.timestamp())
}

/// Ingestion refusals that clients must back off from. Both use 429 with
/// `Retry-After` and `X-Sentry-Rate-Limits` so Sentry SDKs pause sending.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refusal {
    SubscriptionRequired,
    MonthlyQuota { categories: &'static str },
}

impl IntoResponse for Refusal {
    fn into_response(self) -> Response {
        let (retry, categories, reason, body) = match self {
            Self::SubscriptionRequired => (
                SUBSCRIPTION_RETRY_SECS,
                "",
                "subscription_required",
                json!({ "error": "subscription_required" }),
            ),
            Self::MonthlyQuota { categories } => {
                let now = now_secs();
                (
                    u64::try_from(next_month_start(now) - now)
                        .unwrap_or(1)
                        .max(1),
                    categories,
                    "usage_exceeded",
                    json!({ "error": "monthly_quota_exceeded", "categories": categories }),
                )
            }
        };
        let mut response = (StatusCode::TOO_MANY_REQUESTS, Json(body)).into_response();
        let headers = response.headers_mut();
        headers.insert(header::RETRY_AFTER, HeaderValue::from(retry));
        if let Ok(value) =
            HeaderValue::from_str(&format!("{retry}:{categories}:organization:{reason}"))
        {
            headers.insert("x-sentry-rate-limits", value);
        }
        response
    }
}

#[derive(Debug, Serialize)]
pub struct Meter {
    pub used: u64,
    pub limit: u64,
    pub thresholds_reached: Vec<u8>,
}

impl Meter {
    fn new(used: u64, limit: u64) -> Self {
        Self {
            used,
            limit,
            thresholds_reached: alerts::reached(used, limit).collect(),
        }
    }
}

/// Committed usage of the current UTC month.
#[derive(Debug, Serialize)]
pub struct UsageReport {
    pub month: String,
    pub resets_at: i64,
    pub entitlement: Entitlement,
    pub errors: Meter,
    pub log_bytes: Meter,
    pub ingestion: IngestionUsage,
}

/// The effective ingestion policy. Refused items are reported here, apart
/// from the billed meters.
#[derive(Debug, Serialize)]
pub struct IngestionUsage {
    pub policy: crate::ingest::policy::PolicyState,
    pub outcomes: crate::ingest::receipt::Report,
}

pub async fn usage(rt: &Runtime, access: &OrgAccess) -> ApiResult<UsageReport> {
    let account = Account::load(rt, &access.org).await?;
    let now = now_secs();
    let day = utc_day(now_micros());
    let (used, outcomes) = {
        let handle = rt.tenant(&access.org).await?;
        let used: Usage = month_usage(&*handle, &day).await?;
        let (first, last) = month_days(&day);
        let outcomes = crate::ingest::receipt::refused_between(&*handle, &first, &last).await?;
        (used, outcomes)
    };
    Ok(UsageReport {
        month: format!("{}-{}", &day[..4], &day[4..6]),
        resets_at: next_month_start(now),
        entitlement: account.entitlement(now),
        errors: Meter::new(used.errors, MONTHLY_ERRORS),
        log_bytes: Meter::new(used.log_bytes, MONTHLY_LOG_BYTES),
        ingestion: IngestionUsage {
            policy: crate::ingest::policy::load(rt, access).await?.policy,
            outcomes,
        },
    })
}

struct Linked {
    customer: String,
    subscription: Option<String>,
    status: Option<String>,
    cancel_at_period_end: bool,
    paid_until: Option<i64>,
}

struct Account {
    created_at: i64,
    linked: Option<Linked>,
}

impl Account {
    async fn load(rt: &Runtime, org: &OrgId) -> ApiResult<Self> {
        let row = rt
            .control
            .query_one_raw(sql(
                "SELECT o.created_at, b.stripe_customer_id, b.stripe_subscription_id,
                    b.subscription_status, b.cancel_at_period_end, b.paid_until
                 FROM organizations o LEFT JOIN billing_accounts b ON b.org_id = o.id
                 WHERE o.id = ? AND o.lifecycle = 'active'",
                vec![org.as_str().into()],
            ))
            .await?
            .ok_or(ApiError::NotFound)?;
        let customer: Option<String> = row.try_get("", "stripe_customer_id")?;
        let linked = match customer {
            Some(customer) => Some(Linked {
                customer,
                subscription: row.try_get("", "stripe_subscription_id")?,
                status: row.try_get("", "subscription_status")?,
                cancel_at_period_end: row
                    .try_get::<Option<i64>>("", "cancel_at_period_end")?
                    .unwrap_or(0)
                    == 1,
                paid_until: row.try_get("", "paid_until")?,
            }),
            None => None,
        };
        Ok(Self {
            created_at: row.try_get("", "created_at")?,
            linked,
        })
    }

    fn entitlement(&self, now: i64) -> Entitlement {
        Entitlement::at(
            self.created_at,
            self.linked.as_ref().and_then(|linked| linked.paid_until),
            now,
        )
    }

    fn blocks_new_checkout(&self) -> bool {
        self.linked.as_ref().is_some_and(|linked| {
            linked.subscription.is_some()
                && !matches!(
                    linked.status.as_deref(),
                    Some("canceled" | "incomplete_expired")
                )
        })
    }
}

#[derive(Debug, Serialize)]
pub struct Plan {
    pub price_cents: i64,
    pub currency: &'static str,
    pub interval: &'static str,
    pub monthly_errors: u64,
    pub monthly_log_bytes: u64,
    pub trial_days: i64,
}

const PLAN: Plan = Plan {
    price_cents: PLAN_PRICE_CENTS,
    currency: PLAN_CURRENCY,
    interval: "year",
    monthly_errors: MONTHLY_ERRORS,
    monthly_log_bytes: MONTHLY_LOG_BYTES,
    trial_days: TRIAL_SECS / 86_400,
};

/// `$449 per year` from the plan constants. Whole dollar amounts omit cents.
pub fn annual_price_label() -> String {
    let major = PLAN.price_cents.div_euclid(100);
    let minor = PLAN.price_cents.rem_euclid(100);
    let amount = if minor == 0 {
        format!("${major}")
    } else {
        format!("${major}.{minor:02}")
    };
    format!("{amount} per {}", PLAN.interval)
}

#[derive(Debug, Serialize)]
pub struct SubscriptionView {
    pub status: Option<String>,
    pub cancel_at_period_end: bool,
    pub paid_until: Option<i64>,
}

#[derive(Debug, Serialize)]
pub struct BillingStatus {
    pub plan: &'static Plan,
    pub entitlement: Entitlement,
    pub trial_ends_at: i64,
    pub subscription: Option<SubscriptionView>,
    pub can_manage: bool,
    pub can_checkout: bool,
    /// Why checkout and the billing portal are unavailable, if they are.
    pub blocker: Option<&'static str>,
}

#[derive(Deserialize)]
struct Event {
    id: String,
    #[serde(rename = "type")]
    kind: String,
    livemode: bool,
    data: EventData,
}

#[derive(Deserialize)]
struct EventData {
    object: EventObject,
}

#[derive(Deserialize)]
struct EventObject {
    id: String,
    object: String,
}

enum Target<'a> {
    Checkout(&'a str),
    Subscription(&'a str),
    Invoice(&'a str),
}

fn target<'a>(kind: &str, object: &'a EventObject) -> Option<Target<'a>> {
    let id = object.id.as_str();
    match (kind, object.object.as_str()) {
        (
            "checkout.session.completed" | "checkout.session.async_payment_succeeded",
            "checkout.session",
        ) => Some(Target::Checkout(id)),
        (kind, "subscription") if kind.starts_with("customer.subscription.") => {
            Some(Target::Subscription(id))
        }
        (
            "invoice.paid"
            | "invoice.payment_succeeded"
            | "invoice.payment_failed"
            | "invoice.voided"
            | "invoice.marked_uncollectible"
            | "invoice.updated",
            "invoice",
        ) => Some(Target::Invoice(id)),
        _ => None,
    }
}

pub fn plan_price_valid(price: &Price, price_id: &str) -> bool {
    price.id == price_id
        && price.active
        && price.currency == PLAN_CURRENCY
        && price.unit_amount == Some(PLAN_PRICE_CENTS)
        && price
            .recurring
            .as_ref()
            .is_some_and(|recurring| recurring.interval == "year" && recurring.interval_count == 1)
}

/// End of the service year an invoice paid for, if it is a settled invoice for
/// exactly one unit of the annual plan on this customer's subscription.
/// Settlement is Stripe's: discounts and customer credit can leave nothing to
/// collect, so the cash amount is not compared with the list price.
pub fn paid_through(
    invoice: &Invoice,
    price_id: &str,
    customer: &str,
    subscription: &str,
) -> Option<i64> {
    let [line] = invoice.lines.data.as_slice() else {
        return None;
    };
    let price = line
        .pricing
        .as_ref()?
        .price_details
        .as_ref()?
        .price
        .as_str();
    let length = line.period.end - line.period.start;
    let valid = invoice.status.as_deref() == Some("paid")
        && invoice.customer.as_deref() == Some(customer)
        && invoice.subscription() == Some(subscription)
        && invoice.currency == PLAN_CURRENCY
        && !invoice.lines.has_more
        && invoice.amount_remaining == 0
        && price == price_id
        && line.quantity == Some(1)
        && line.amount == PLAN_PRICE_CENTS
        && line.currency == PLAN_CURRENCY
        && (YEAR_MIN_SECS..=YEAR_MAX_SECS).contains(&length);
    valid.then_some(line.period.end)
}

fn provider(error: StripeError) -> ApiError {
    tracing::warn!(%error, "Stripe request failed");
    ApiError::Unavailable("billing_provider_unavailable")
}

pub struct Billing {
    stripe: Option<Stripe>,
    origin: String,
    checkout: tokio::sync::Mutex<()>,
}

impl Billing {
    pub fn new(credentials: Option<&StripeCredentials>, settings: &Settings) -> Result<Self> {
        let stripe = credentials
            .map(|credentials| {
                Stripe::new(
                    credentials,
                    &settings.billing.api_base,
                    Duration::from_millis(settings.billing.request_timeout_ms),
                )
            })
            .transpose()
            .map_err(|error| Error::string(&error))?;
        Ok(Self {
            stripe,
            origin: settings.auth.origin.trim_end_matches('/').to_owned(),
            checkout: tokio::sync::Mutex::new(()),
        })
    }

    fn stripe(&self) -> ApiResult<&Stripe> {
        self.stripe
            .as_ref()
            .ok_or(ApiError::Unavailable("billing_unconfigured"))
    }

    pub async fn status(&self, rt: &Runtime, access: &OrgAccess) -> ApiResult<BillingStatus> {
        let account = Account::load(rt, &access.org).await?;
        let can_checkout =
            access.role == Role::Owner && self.stripe.is_some() && !account.blocks_new_checkout();
        Ok(BillingStatus {
            plan: &PLAN,
            entitlement: account.entitlement(now_secs()),
            trial_ends_at: account.created_at.saturating_add(TRIAL_SECS),
            subscription: account.linked.map(|linked| SubscriptionView {
                status: linked.status,
                cancel_at_period_end: linked.cancel_at_period_end,
                paid_until: linked.paid_until,
            }),
            can_manage: access.role == Role::Owner,
            can_checkout,
            blocker: self.stripe.is_none().then_some("billing_unconfigured"),
        })
    }

    pub async fn checkout(&self, rt: &Runtime, access: &OrgAccess) -> ApiResult<String> {
        require_owner(access)?;
        let stripe = self.stripe()?;
        let _single = self.checkout.lock().await;
        let account = Account::load(rt, &access.org).await?;
        if account.blocks_new_checkout() {
            return Err(ApiError::Conflict("subscription_exists"));
        }
        let price = stripe.price().await.map_err(provider)?;
        if !plan_price_valid(&price, &stripe.price_id) {
            tracing::error!("configured Stripe price does not match the annual plan");
            return Err(ApiError::Unavailable("billing_price_invalid"));
        }
        let now = now_secs();
        let pending = rt
            .control
            .query_all_raw(sql(
                "SELECT id, session_id FROM billing_checkouts
                 WHERE org_id = ? AND completed_at IS NULL
                 ORDER BY created_at DESC, id DESC",
                vec![access.org.as_str().into()],
            ))
            .await?;
        let mut attempt = None;
        let mut reusable = None;
        for row in pending {
            let id: String = row.try_get("", "id")?;
            let session: Option<String> = row.try_get("", "session_id")?;
            match session {
                None => {
                    if attempt.is_some() {
                        return Err(ApiError::Conflict("billing_checkout_pending"));
                    }
                    attempt = Some(id);
                }
                Some(session) => {
                    let current = stripe.checkout(&session).await.map_err(provider)?;
                    match current.status.as_deref() {
                        Some("open") => {
                            if current.expires_at > now + 60 {
                                if let Some(url) = current.url {
                                    reusable.get_or_insert(url);
                                    continue;
                                }
                            }
                            return Err(ApiError::Conflict("billing_checkout_pending"));
                        }
                        Some("complete") => {
                            self.link_checkout(rt, stripe, &session).await?;
                            return Err(ApiError::Conflict("subscription_exists"));
                        }
                        Some("expired") => {}
                        _ => return Err(ApiError::Unavailable("billing_provider_unknown")),
                    }
                }
            }
        }
        if let Some(url) = reusable {
            return Ok(url);
        }
        let attempt = match attempt {
            Some(attempt) => attempt,
            None => {
                let id = uuid::Uuid::now_v7().simple().to_string();
                rt.control
                    .execute_raw(sql(
                        "INSERT INTO billing_checkouts (id, org_id, created_at) VALUES (?, ?, ?)",
                        vec![id.clone().into(), access.org.as_str().into(), now.into()],
                    ))
                    .await?;
                id
            }
        };
        let return_to = format!("{}/dashboard/orgs/{}", self.origin, access.org);
        let session = stripe
            .create_checkout(&CheckoutRequest {
                attempt: &attempt,
                org: access.org.as_str(),
                customer: account
                    .linked
                    .as_ref()
                    .map(|linked| linked.customer.as_str()),
                success_url: &format!("{return_to}?billing=success"),
                cancel_url: &format!("{return_to}?billing=cancelled"),
            })
            .await
            .map_err(provider)?;
        if session.client_reference_id.as_deref() != Some(access.org.as_str()) {
            return Err(ApiError::Internal("checkout session organization".into()));
        }
        rt.control
            .execute_raw(sql(
                "UPDATE billing_checkouts SET session_id = ?, expires_at = ? WHERE id = ?",
                vec![
                    session.id.clone().into(),
                    session.expires_at.into(),
                    attempt.into(),
                ],
            ))
            .await?;
        session
            .url
            .ok_or(ApiError::Internal("checkout session url".into()))
    }

    pub async fn portal(&self, rt: &Runtime, access: &OrgAccess) -> ApiResult<String> {
        require_owner(access)?;
        let stripe = self.stripe()?;
        let account = Account::load(rt, &access.org).await?;
        let linked = account
            .linked
            .ok_or(ApiError::Conflict("no_billing_account"))?;
        stripe
            .portal(
                &linked.customer,
                &format!("{}/dashboard/orgs/{}", self.origin, access.org),
            )
            .await
            .map_err(provider)
    }

    pub(crate) async fn deletion_guard(
        &self,
        rt: &Runtime,
        access: &OrgAccess,
    ) -> ApiResult<tokio::sync::MutexGuard<'_, ()>> {
        require_owner(access)?;
        let owner = crate::identity::access::authorize(rt, access.user, &access.org).await?;
        require_owner(&owner)?;
        let guard = self.checkout.lock().await;
        Account::load(rt, &access.org).await?;
        let pending = rt.control.query_all_raw(sql(
            "SELECT session_id FROM billing_checkouts WHERE org_id = ? AND completed_at IS NULL",
            vec![access.org.as_str().into()],
        )).await?;
        for row in pending {
            let session: Option<String> = row.try_get("", "session_id")?;
            let session = session.ok_or(ApiError::Conflict("billing_checkout_pending"))?;
            let stripe = self.stripe()?;
            let current = stripe.checkout(&session).await.map_err(provider)?;
            match current.status.as_deref() {
                Some("expired") => {}
                Some("complete") => {
                    self.link_checkout(rt, stripe, &session).await?;
                    let account = Account::load(rt, &access.org).await?;
                    if !account.linked.as_ref().is_some_and(|linked| {
                        Some(linked.customer.as_str()) == current.customer.as_deref()
                            && linked.subscription.is_some()
                            && linked.subscription == current.subscription
                    }) {
                        return Err(ApiError::Conflict("billing_checkout_pending"));
                    }
                }
                Some("open") => return Err(ApiError::Conflict("billing_checkout_pending")),
                _ => return Err(ApiError::Unavailable("billing_provider_unknown")),
            }
        }
        let account = Account::load(rt, &access.org).await?;
        if let Some(linked) = account.linked {
            if let Some(id) = linked.subscription {
                let current = self.stripe()?.subscription(&id).await.map_err(provider)?;
                if current.id != id
                    || current.customer != linked.customer
                    || !matches!(
                        current.status.as_str(),
                        "active"
                            | "trialing"
                            | "past_due"
                            | "unpaid"
                            | "incomplete"
                            | "paused"
                            | "canceled"
                            | "incomplete_expired"
                    )
                {
                    return Err(ApiError::Unavailable("billing_provider_unknown"));
                }
                if !matches!(current.status.as_str(), "canceled" | "incomplete_expired")
                    && !current.cancel_at_period_end
                {
                    return Err(ApiError::Conflict("billing_subscription_renewing"));
                }
                rt.control.execute_raw(sql(
                    "UPDATE billing_accounts SET subscription_status = ?, cancel_at_period_end = ?, synced_at = ?
                     WHERE org_id = ? AND stripe_subscription_id = ?",
                    vec![current.status.into(), i32::from(current.cancel_at_period_end).into(), now_secs().into(), access.org.as_str().into(), id.into()],
                )).await?;
            }
        }
        Ok(guard)
    }

    /// Re-reads this organization's checkouts and subscription from Stripe.
    /// Recovers paid time when a webhook was missed or failed locally.
    pub async fn refresh(&self, rt: &Runtime, access: &OrgAccess) -> ApiResult<BillingStatus> {
        require_owner(access)?;
        let _single = self.checkout.lock().await;
        let stripe = self.stripe()?;
        let sessions = rt
            .control
            .query_all_raw(sql(
                "SELECT session_id FROM billing_checkouts
                 WHERE org_id = ? AND session_id IS NOT NULL AND completed_at IS NULL
                 ORDER BY created_at DESC LIMIT 3",
                vec![access.org.as_str().into()],
            ))
            .await?;
        for row in sessions {
            let session: String = row.try_get("", "session_id")?;
            self.link_checkout(rt, stripe, &session).await?;
        }
        let account = Account::load(rt, &access.org).await?;
        if let Some(subscription) = account.linked.and_then(|linked| linked.subscription) {
            sync_subscription(rt, stripe, &subscription).await?;
        }
        self.status(rt, access).await
    }

    /// Verifies and records one Stripe event, then syncs the canonical objects
    /// it names.
    pub async fn webhook(
        &self,
        rt: &Runtime,
        signature: Option<&str>,
        body: &[u8],
    ) -> ApiResult<serde_json::Value> {
        let stripe = self.stripe()?;
        let _single = self.checkout.lock().await;
        let now = now_secs();
        if !signature.is_some_and(|signature| stripe.verify_webhook(signature, body, now)) {
            return Err(ApiError::BadRequest("invalid_signature"));
        }
        let event: Event =
            serde_json::from_slice(body).map_err(|_| ApiError::BadRequest("invalid_event"))?;
        if event.livemode != stripe.live {
            return Err(ApiError::BadRequest("livemode_mismatch"));
        }
        if event.id.is_empty() || event.id.len() > 255 || event.kind.len() > 255 {
            return Err(ApiError::BadRequest("invalid_event"));
        }
        rt.control
            .execute_raw(sql(
                "INSERT INTO billing_events (event_id, event_type, received_at) VALUES (?, ?, ?)
                 ON CONFLICT (event_id) DO NOTHING",
                vec![
                    event.id.clone().into(),
                    event.kind.clone().into(),
                    now.into(),
                ],
            ))
            .await?;
        let processed: Option<i64> = rt
            .control
            .query_one_raw(sql(
                "SELECT processed_at FROM billing_events WHERE event_id = ?",
                vec![event.id.clone().into()],
            ))
            .await?
            .ok_or(ApiError::Internal("billing event receipt".into()))?
            .try_get("", "processed_at")?;
        if processed.is_some() {
            return Ok(json!({ "received": true, "duplicate": true }));
        }
        match target(&event.kind, &event.data.object) {
            Some(Target::Checkout(id)) => self.link_checkout(rt, stripe, id).await?,
            Some(Target::Subscription(id)) => sync_subscription(rt, stripe, id).await?,
            Some(Target::Invoice(id)) => {
                let invoice = stripe.invoice(id).await.map_err(provider)?;
                if let Some(subscription) = invoice.subscription() {
                    sync_subscription(rt, stripe, subscription).await?;
                }
            }
            None => {}
        }
        rt.control
            .execute_raw(sql(
                "UPDATE billing_events SET processed_at = ? WHERE event_id = ?",
                vec![now_secs().into(), event.id.into()],
            ))
            .await?;
        rt.control
            .execute_raw(sql(
                "DELETE FROM billing_events WHERE rowid IN
                    (SELECT rowid FROM billing_events WHERE received_at < ? ORDER BY received_at LIMIT 100)",
                vec![(now - RECEIPT_RETENTION_SECS).into()],
            ))
            .await?;
        Ok(json!({ "received": true }))
    }

    async fn link_checkout(&self, rt: &Runtime, stripe: &Stripe, id: &str) -> ApiResult<()> {
        let session = stripe.checkout(id).await.map_err(provider)?;
        if session.mode != "subscription" || session.status.as_deref() != Some("complete") {
            return Ok(());
        }
        let (Some(org), Some(customer), Some(subscription)) = (
            session
                .client_reference_id
                .as_deref()
                .and_then(|org| org.parse::<OrgId>().ok()),
            session.customer.as_deref(),
            session.subscription.as_deref(),
        ) else {
            return Ok(());
        };
        let ours = rt
            .control
            .query_one_raw(sql(
                "SELECT 1 AS found FROM billing_checkouts WHERE session_id = ? AND org_id = ?",
                vec![session.id.clone().into(), org.as_str().into()],
            ))
            .await?
            .is_some();
        let owner = rt
            .control
            .query_one_raw(sql(
                "SELECT org_id FROM billing_accounts WHERE stripe_customer_id = ?",
                vec![customer.into()],
            ))
            .await?
            .map(|row| row.try_get::<String>("", "org_id"))
            .transpose()?;
        if !ours || owner.is_some_and(|owner| owner != org.as_str()) {
            tracing::warn!(org = %org, "ignored a checkout session outside its organization");
            return Ok(());
        }
        let linked = rt
            .control
            .execute_raw(sql(
                "INSERT INTO billing_accounts (org_id, stripe_customer_id, stripe_subscription_id, synced_at)
                 SELECT ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM organizations WHERE id = ? AND lifecycle = 'active')
                 ON CONFLICT (org_id) DO UPDATE SET
                    stripe_subscription_id = excluded.stripe_subscription_id,
                    subscription_status = CASE WHEN stripe_subscription_id IS excluded.stripe_subscription_id
                        THEN subscription_status ELSE NULL END,
                    cancel_at_period_end = CASE WHEN stripe_subscription_id IS excluded.stripe_subscription_id
                        THEN cancel_at_period_end ELSE 0 END,
                    synced_at = excluded.synced_at
                 WHERE billing_accounts.stripe_customer_id = excluded.stripe_customer_id",
                vec![
                    org.as_str().into(),
                    customer.into(),
                    subscription.into(),
                    now_secs().into(),
                    org.as_str().into(),
                ],
            ))
            .await?;
        if linked.rows_affected() == 0 {
            tracing::warn!(org = %org, "checkout customer differs from the organization's customer");
            return Ok(());
        }
        rt.control
            .execute_raw(sql(
                "UPDATE billing_checkouts SET completed_at = COALESCE(completed_at, ?) WHERE session_id = ?",
                vec![now_secs().into(), session.id.clone().into()],
            ))
            .await?;
        sync_subscription(rt, stripe, subscription).await
    }
}

fn require_owner(access: &OrgAccess) -> ApiResult<()> {
    if access.role == Role::Owner {
        Ok(())
    } else {
        Err(ApiError::Forbidden)
    }
}

async fn sync_subscription(rt: &Runtime, stripe: &Stripe, id: &str) -> ApiResult<()> {
    let subscription = stripe.subscription(id).await.map_err(provider)?;
    let owner = rt
        .control
        .query_one_raw(sql(
            "SELECT org_id FROM billing_accounts WHERE stripe_customer_id = ?",
            vec![subscription.customer.clone().into()],
        ))
        .await?;
    let Some(owner) = owner else {
        return Ok(());
    };
    let org: String = owner.try_get("", "org_id")?;
    let paid = stripe
        .paid_invoices(&subscription.id)
        .await
        .map_err(provider)?;
    let paid_until = paid
        .invoices
        .iter()
        .filter_map(|invoice| {
            paid_through(
                invoice,
                &stripe.price_id,
                &subscription.customer,
                &subscription.id,
            )
        })
        .max();
    if !paid.complete {
        tracing::warn!(org = %org, "Stripe invoice history exceeds the pages read");
        if paid_until.is_none() {
            return Err(ApiError::Unavailable("billing_history_incomplete"));
        }
    }
    rt.control
        .execute_raw(sql(
            "UPDATE billing_accounts SET
                paid_until = CASE WHEN ? IS NULL THEN paid_until ELSE MAX(COALESCE(paid_until, 0), ?) END,
                subscription_status = CASE WHEN stripe_subscription_id IS NULL OR stripe_subscription_id = ?
                    THEN ? ELSE subscription_status END,
                cancel_at_period_end = CASE WHEN stripe_subscription_id IS NULL OR stripe_subscription_id = ?
                    THEN ? ELSE cancel_at_period_end END,
                stripe_subscription_id = COALESCE(stripe_subscription_id, ?),
                synced_at = ?
             WHERE org_id = ? AND stripe_customer_id = ?",
            vec![
                paid_until.into(),
                paid_until.into(),
                subscription.id.clone().into(),
                subscription.status.clone().into(),
                subscription.id.clone().into(),
                i64::from(subscription.cancel_at_period_end).into(),
                subscription.id.clone().into(),
                now_secs().into(),
                org.into(),
                subscription.customer.into(),
            ],
        ))
        .await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trial_ends_exactly_fourteen_days_after_creation() {
        let created = 1_790_000_000;
        assert_eq!(
            Entitlement::at(created, None, created + 1_209_599),
            Entitlement::Trial {
                ends_at: 1_791_209_600
            }
        );
        assert_eq!(
            Entitlement::at(created, None, created + 1_209_600),
            Entitlement::SubscriptionRequired {
                since: 1_791_209_600
            }
        );
    }

    #[test]
    fn paid_time_ends_at_its_boundary_and_never_restarts_the_trial() {
        let created = 1_700_000_000;
        assert_eq!(
            Entitlement::at(created, Some(1_800_000_000), 1_799_999_999),
            Entitlement::Paid {
                until: 1_800_000_000
            }
        );
        assert_eq!(
            Entitlement::at(
                created,
                Some(1_800_000_000),
                1_800_000_000 + RENEWAL_GRACE_SECS
            ),
            Entitlement::SubscriptionRequired {
                since: 1_800_000_000 + RENEWAL_GRACE_SECS
            }
        );
        assert_eq!(
            Entitlement::at(created, Some(1_700_000_100), 1_700_000_200),
            Entitlement::Trial {
                ends_at: 1_701_209_600
            }
        );
    }

    #[test]
    fn a_lapsed_paid_period_keeps_telemetry_for_the_renewal_grace_only() {
        let created = 1_700_000_000;
        let until = 1_800_000_000;
        assert_eq!(
            Entitlement::at(created, Some(until), until + RENEWAL_GRACE_SECS - 1),
            Entitlement::Paid { until }
        );
        assert_eq!(
            Entitlement::at(created, Some(until), until + RENEWAL_GRACE_SECS),
            Entitlement::SubscriptionRequired {
                since: until + RENEWAL_GRACE_SECS
            }
        );
        assert_eq!(
            Entitlement::at(created, None, created + TRIAL_SECS + 1),
            Entitlement::SubscriptionRequired {
                since: created + TRIAL_SECS
            }
        );
    }

    #[test]
    fn months_are_utc_calendar_months() {
        assert_eq!(
            month_days("20261016"),
            ("20261001".to_owned(), "20261031".to_owned())
        );
        assert_eq!(next_month_start(1_792_108_800), 1_793_491_200);
        assert_eq!(next_month_start(1_798_761_599), 1_798_761_600);
        assert_eq!(next_month_start(1_798_761_600), 1_801_440_000);
    }

    #[test]
    fn thresholds_count_crossed_percentages_without_overflow() {
        assert_eq!(
            Meter::new(699_999, 1_000_000).thresholds_reached,
            Vec::<u8>::new()
        );
        assert_eq!(Meter::new(700_000, 1_000_000).thresholds_reached, vec![70]);
        assert_eq!(
            Meter::new(100_000_000_000, 100_000_000_000).thresholds_reached,
            vec![70, 90, 100]
        );
    }
}
