use std::sync::Arc;

use axum::{
    body::Bytes,
    extract::State,
    http::HeaderMap,
    routing::{get, post},
    Json,
};
use loco_rs::{app::AppContext, controller::Routes};
use serde_json::json;

use crate::{
    billing::{self, Billing},
    error::ApiResult,
    identity::access::OrgAccess,
    runtime::Runtime,
};

fn service(ctx: &AppContext) -> Arc<Billing> {
    ctx.shared_store
        .get::<Arc<Billing>>()
        .expect("billing is installed with the application services")
}

async fn status(
    State(ctx): State<AppContext>,
    access: OrgAccess,
) -> ApiResult<Json<billing::BillingStatus>> {
    Ok(Json(
        service(&ctx).status(&Runtime::get(&ctx), &access).await?,
    ))
}

async fn usage(
    State(ctx): State<AppContext>,
    access: OrgAccess,
) -> ApiResult<Json<billing::UsageReport>> {
    Ok(Json(billing::usage(&Runtime::get(&ctx), &access).await?))
}

async fn checkout(
    State(ctx): State<AppContext>,
    access: OrgAccess,
) -> ApiResult<Json<serde_json::Value>> {
    let url = service(&ctx).checkout(&Runtime::get(&ctx), &access).await?;
    Ok(Json(json!({ "url": url })))
}

async fn portal(
    State(ctx): State<AppContext>,
    access: OrgAccess,
) -> ApiResult<Json<serde_json::Value>> {
    let url = service(&ctx).portal(&Runtime::get(&ctx), &access).await?;
    Ok(Json(json!({ "url": url })))
}

async fn refresh(
    State(ctx): State<AppContext>,
    access: OrgAccess,
) -> ApiResult<Json<billing::BillingStatus>> {
    Ok(Json(
        service(&ctx).refresh(&Runtime::get(&ctx), &access).await?,
    ))
}

/// Stripe webhook. Authenticated only by the signature over the raw body.
async fn webhook(
    State(ctx): State<AppContext>,
    headers: HeaderMap,
    body: Bytes,
) -> ApiResult<Json<serde_json::Value>> {
    let signature = headers
        .get("stripe-signature")
        .and_then(|value| value.to_str().ok());
    Ok(Json(
        service(&ctx)
            .webhook(&Runtime::get(&ctx), signature, &body)
            .await?,
    ))
}

pub fn routes() -> Routes {
    Routes::new()
        .add("/api/orgs/{org}/billing", get(status))
        .add("/api/orgs/{org}/usage", get(usage))
        .add("/api/orgs/{org}/billing/checkout", post(checkout))
        .add("/api/orgs/{org}/billing/portal", post(portal))
        .add("/api/orgs/{org}/billing/refresh", post(refresh))
        .add("/webhooks/stripe", post(webhook))
}
