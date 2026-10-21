//! Session-only API key management. Bearer credentials cannot reach these
//! routes; see `agent_policy`.

use axum::{
    extract::{Path, State},
    http::{header, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
    routing::get,
    Json,
};
use loco_rs::{app::AppContext, controller::Routes};
use serde_json::json;

use super::PageBefore;
use crate::{
    api_keys::{self, NewApiKey},
    error::ApiResult,
    identity::access::OrgAccess,
    runtime::Runtime,
};

async fn create(
    State(ctx): State<AppContext>,
    access: OrgAccess,
    Json(body): Json<NewApiKey>,
) -> ApiResult<Response> {
    let created = api_keys::create(&Runtime::get(&ctx), &access, body).await?;
    let mut response = (StatusCode::CREATED, Json(created)).into_response();
    let headers = response.headers_mut();
    headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    headers.insert(header::PRAGMA, HeaderValue::from_static("no-cache"));
    Ok(response)
}

async fn list(
    State(ctx): State<AppContext>,
    access: OrgAccess,
    PageBefore(page): PageBefore,
) -> ApiResult<Json<serde_json::Value>> {
    let (keys, next) = api_keys::list(&Runtime::get(&ctx), &access, &page).await?;
    Ok(Json(json!({ "keys": keys, "next": next })))
}

async fn show(
    State(ctx): State<AppContext>,
    access: OrgAccess,
    Path((_, id)): Path<(String, i64)>,
) -> ApiResult<Json<serde_json::Value>> {
    let key = api_keys::get(&Runtime::get(&ctx), &access, id).await?;
    Ok(Json(json!({ "key": key })))
}

async fn revoke(
    State(ctx): State<AppContext>,
    access: OrgAccess,
    Path((_, id)): Path<(String, i64)>,
) -> ApiResult<StatusCode> {
    api_keys::revoke(&Runtime::get(&ctx), &access, id).await?;
    Ok(StatusCode::NO_CONTENT)
}

pub fn routes() -> Routes {
    Routes::new()
        .prefix("/api/orgs/{org}/api-keys")
        .add("/", get(list).post(create))
        .add("/{key}", get(show).delete(revoke))
}
