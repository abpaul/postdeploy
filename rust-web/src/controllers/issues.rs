use axum::{
    extract::{Path, Query, State},
    routing::get,
    Json,
};
use loco_rs::{app::AppContext, controller::Routes};
use serde::Deserialize;
use serde_json::{json, Value};

use crate::{
    error::ApiResult,
    identity::access::OrgAccess,
    issues::{self, EventRef, IssueQuery},
    runtime::Runtime,
};

#[derive(Deserialize)]
struct StatusBody {
    status: String,
}

#[derive(Deserialize)]
struct Limit {
    limit: Option<u32>,
}

#[derive(Deserialize)]
struct SourceQuery {
    source: Option<i64>,
}

async fn list(
    State(ctx): State<AppContext>,
    access: OrgAccess,
    Query(query): Query<IssueQuery>,
) -> ApiResult<Json<Value>> {
    let (issues, next) = issues::list(&Runtime::get(&ctx), &access, query).await?;
    Ok(Json(json!({ "issues": issues, "next": next })))
}

async fn show(
    State(ctx): State<AppContext>,
    access: OrgAccess,
    Path((_, id)): Path<(String, i64)>,
) -> ApiResult<Json<Value>> {
    let (issue, latest) = issues::get(&Runtime::get(&ctx), &access, id).await?;
    Ok(Json(json!({ "issue": issue, "latest_event": latest })))
}

async fn update(
    State(ctx): State<AppContext>,
    access: OrgAccess,
    Path((_, id)): Path<(String, i64)>,
    Json(body): Json<StatusBody>,
) -> ApiResult<Json<Value>> {
    let issue = issues::set_status(&Runtime::get(&ctx), &access, id, &body.status).await?;
    Ok(Json(json!(issue)))
}

async fn events(
    State(ctx): State<AppContext>,
    access: OrgAccess,
    Path((_, id)): Path<(String, i64)>,
    Query(limit): Query<Limit>,
) -> ApiResult<Json<Value>> {
    let events = issues::events(&Runtime::get(&ctx), &access, id, limit.limit).await?;
    Ok(Json(json!({ "events": events })))
}

async fn event(
    State(ctx): State<AppContext>,
    access: OrgAccess,
    Path((_, id, event_id)): Path<(String, i64, String)>,
    Query(query): Query<SourceQuery>,
) -> ApiResult<Json<Value>> {
    let selector = EventRef {
        event_id,
        source: query.source,
    };
    let (event, payload) =
        issues::event_payload(&Runtime::get(&ctx), &access, id, &selector).await?;
    Ok(Json(json!({ "event": event, "payload": payload })))
}

pub fn routes() -> Routes {
    Routes::new()
        .prefix("/api/orgs/{org}/issues")
        .add("/", get(list))
        .add("/{issue}", get(show).patch(update))
        .add("/{issue}/events", get(events))
        .add("/{issue}/events/{event}", get(event))
}
