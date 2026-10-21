use axum::{
    body::Bytes,
    extract::Path,
    http::{header, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
};
use serde_json::json;

use crate::{
    billing::{self as billing_service, BillingStatus, Entitlement, UsageReport},
    error::ApiError,
};

use super::{
    page::{Fields, Flash, Web, WebError, WebResult},
    policy,
};

fn date(secs: i64) -> String {
    policy::format_micros(secs.saturating_mul(1_000_000))
}

fn count(value: u64) -> String {
    let digits = value.to_string();
    let mut out = String::with_capacity(digits.len() + digits.len() / 3);
    for (index, digit) in digits.chars().enumerate() {
        if index > 0 && (digits.len() - index).is_multiple_of(3) {
            out.push(',');
        }
        out.push(digit);
    }
    out
}

fn bytes(value: u64) -> String {
    if value >= 1_000_000_000 {
        decimal(value, 1_000_000_000, "GB")
    } else if value >= 1_000_000 {
        decimal(value, 1_000_000, "MB")
    } else if value >= 1_000 {
        decimal(value, 1_000, "KB")
    } else {
        format!("{value} B")
    }
}

fn decimal(value: u64, unit: u64, suffix: &str) -> String {
    if value.is_multiple_of(unit) {
        format!("{} {suffix}", value / unit)
    } else {
        format!("{:.2} {suffix}", value as f64 / unit as f64)
    }
}

fn percent(used: u64, limit: u64) -> u64 {
    if limit == 0 {
        return 0;
    }
    used.saturating_mul(100).div_ceil(limit).min(100)
}

fn subscription_label(status: Option<&str>) -> &'static str {
    match status {
        Some("active") => "Active",
        Some("trialing") => "Trialing",
        Some("past_due") => "Payment past due",
        Some("unpaid") => "Payment required",
        Some("incomplete") => "Setup incomplete",
        Some("paused") => "Paused",
        Some("canceled" | "incomplete_expired") => "Ended",
        Some(_) => "Updating",
        None => "Not linked",
    }
}

fn status_view(status: &BillingStatus) -> serde_json::Value {
    match status.entitlement {
        Entitlement::Trial { ends_at } => json!({
            "state": "trial",
            "title": "Trial active",
            "detail": format!("Full access through {}. No card required.", date(ends_at)),
        }),
        Entitlement::Paid { until } => json!({
            "state": "paid",
            "title": "Subscribed",
            "detail": format!("Paid access through {}.", date(until)),
        }),
        Entitlement::SubscriptionRequired { since } => json!({
            "state": "expired",
            "title": "Subscription required",
            "detail": format!("Access ended {}. New telemetry is paused; existing data remains available.", date(since)),
        }),
    }
}

async fn billing_page(web: &Web, org: &str) -> WebResult<super::page::Page> {
    let cx = web.member(org).await?;
    let status = web.svc.billing.status(&web.rt, &cx.access).await?;
    let usage = billing_service::usage(&web.rt, &cx.access).await?;
    let provider_available = status.blocker.is_none();
    let owner = status.can_manage;
    let linked = status.subscription.is_some();
    let mut page = web.org_page(&cx, "Billing", "billing");
    page.set("billing_status", status_view(&status))
        .set(
            "subscription",
            status.subscription.as_ref().map(|subscription| {
                json!({
                    "status": subscription_label(subscription.status.as_deref()),
                    "renews": subscription.paid_until.map(date),
                    "cancel_at_period_end": subscription.cancel_at_period_end,
                })
            }),
        )
        .set("billing_owner", owner)
        .set("billing_available", provider_available)
        .set(
            "checkout_action",
            if status.can_checkout {
                format!("{}/billing/checkout", cx.base)
            } else {
                String::new()
            },
        )
        .set(
            "portal_action",
            if owner && provider_available && linked {
                format!("{}/billing/portal", cx.base)
            } else {
                String::new()
            },
        )
        .set(
            "refresh_action",
            if owner && provider_available {
                format!("{}/billing/refresh", cx.base)
            } else {
                String::new()
            },
        )
        .set(
            "plan",
            json!({
                "price": format!("${}/year", status.plan.price_cents / 100),
                "log_bytes": bytes(status.plan.monthly_log_bytes),
                "errors": count(status.plan.monthly_errors),
            }),
        )
        .set("usage", usage_view(&usage));
    Ok(page)
}

fn usage_view(usage: &UsageReport) -> serde_json::Value {
    json!({
        "month": usage.month,
        "resets_at": date(usage.resets_at),
        "errors": {
            "used": count(usage.errors.used),
            "limit": count(usage.errors.limit),
            "percent": percent(usage.errors.used, usage.errors.limit),
            "used_exact": usage.errors.used,
        },
        "logs": {
            "used": bytes(usage.log_bytes.used),
            "limit": bytes(usage.log_bytes.limit),
            "percent": percent(usage.log_bytes.used, usage.log_bytes.limit),
            "used_exact": usage.log_bytes.used,
        },
    })
}

pub async fn show(web: Web, Path(org): Path<String>) -> WebResult {
    let page = billing_page(&web, &org).await?;
    Ok(web.render(page, "settings/billing.html"))
}

fn action_message(error: &ApiError) -> Option<&'static str> {
    match error {
        ApiError::Conflict("subscription_exists") => Some(
            "This organization already has a subscription. Refresh its status or manage billing.",
        ),
        ApiError::Conflict("billing_checkout_pending") => {
            Some("A checkout is already open. Complete it in Stripe, then refresh billing status.")
        }
        ApiError::Conflict("no_billing_account") => {
            Some("Billing is not linked yet. Subscribe before opening the billing portal.")
        }
        ApiError::Unavailable(_) | ApiError::RateLimited { .. } => {
            Some("Billing is temporarily unavailable. Try again later.")
        }
        _ => None,
    }
}

fn external_redirect(url: &str) -> WebResult<Response> {
    let target = policy::client_redirect_target(url)
        .and_then(|target| HeaderValue::from_str(target).ok())
        .ok_or_else(|| {
            tracing::error!("billing service returned a redirect the dashboard refused");
            WebError::Internal
        })?;
    let mut response = StatusCode::SEE_OTHER.into_response();
    response.headers_mut().insert(header::LOCATION, target);
    response
        .headers_mut()
        .insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    Ok(response)
}

enum BillingAction {
    Checkout,
    Portal,
}

async fn action(web: Web, org: String, body: Bytes, action: BillingAction) -> WebResult {
    let fields = Fields::parse(&body);
    let cx = web.member_form(&org, &fields).await?;
    let result = match action {
        BillingAction::Checkout => web.svc.billing.checkout(&web.rt, &cx.access).await,
        BillingAction::Portal => web.svc.billing.portal(&web.rt, &cx.access).await,
    };
    match result {
        Ok(url) => external_redirect(&url),
        Err(error) => match action_message(&error) {
            Some(message) => {
                Ok(web.redirect_flash(&format!("{}/billing", cx.base), Flash::Error, message))
            }
            None => Err(error.into()),
        },
    }
}

pub async fn checkout(web: Web, Path(org): Path<String>, body: Bytes) -> WebResult {
    action(web, org, body, BillingAction::Checkout).await
}

pub async fn portal(web: Web, Path(org): Path<String>, body: Bytes) -> WebResult {
    action(web, org, body, BillingAction::Portal).await
}

pub async fn refresh(web: Web, Path(org): Path<String>, body: Bytes) -> WebResult {
    let fields = Fields::parse(&body);
    let cx = web.member_form(&org, &fields).await?;
    match web.svc.billing.refresh(&web.rt, &cx.access).await {
        Ok(_) => Ok(web.redirect_flash(
            &format!("{}/billing", cx.base),
            Flash::Info,
            "Billing status refreshed.",
        )),
        Err(error) => match action_message(&error) {
            Some(message) => {
                Ok(web.redirect_flash(&format!("{}/billing", cx.base), Flash::Error, message))
            }
            None => Err(error.into()),
        },
    }
}
