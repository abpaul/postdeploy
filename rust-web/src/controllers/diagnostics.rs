use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    routing::get,
    Json,
};
use loco_rs::{app::AppContext, controller::Routes};
use serde::Deserialize;
use serde_json::{json, Value};

use crate::{
    deployments::{self, DeploymentQuery, NewDeployment},
    diagnostics::{self, CompareOptions, ContextOptions},
    domain::ProjectId,
    error::ApiResult,
    identity::access::OrgAccess,
    issues::EventRef,
    runtime::Runtime,
};

async fn record(
    State(ctx): State<AppContext>,
    access: OrgAccess,
    Path((_, project)): Path<(String, i64)>,
    Json(body): Json<NewDeployment>,
) -> ApiResult<(StatusCode, Json<Value>)> {
    let (deployment, created) =
        deployments::record(&Runtime::get(&ctx), &access, ProjectId(project), body).await?;
    let status = if created {
        StatusCode::CREATED
    } else {
        StatusCode::OK
    };
    Ok((
        status,
        Json(json!({ "deployment": deployment, "created": created })),
    ))
}

async fn list(
    State(ctx): State<AppContext>,
    access: OrgAccess,
    Path((_, project)): Path<(String, i64)>,
    Query(query): Query<DeploymentQuery>,
) -> ApiResult<Json<Value>> {
    let (deployments, next) =
        deployments::list(&Runtime::get(&ctx), &access, ProjectId(project), query).await?;
    Ok(Json(json!({ "deployments": deployments, "next": next })))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CompareQuery {
    window_secs: Option<i64>,
    limit: Option<u32>,
    new_after: Option<i64>,
    regressed_after: Option<i64>,
}

async fn compare(
    State(ctx): State<AppContext>,
    access: OrgAccess,
    Path((_, deployment)): Path<(String, i64)>,
    Query(query): Query<CompareQuery>,
) -> ApiResult<Json<Value>> {
    let options = CompareOptions {
        window_secs: query.window_secs,
        limit: query.limit,
        new_after: query.new_after,
        regressed_after: query.regressed_after,
    };
    let rt = Runtime::get(&ctx);
    let admitted = rt.admission.queries.expensive(&access.org)?;
    let comparison = diagnostics::compare(&rt, &access, &admitted, deployment, options).await?;
    Ok(Json(json!(comparison)))
}

async fn recurrence(
    State(ctx): State<AppContext>,
    access: OrgAccess,
    Path((_, issue)): Path<(String, i64)>,
) -> ApiResult<Json<Value>> {
    let rt = Runtime::get(&ctx);
    let admitted = rt.admission.queries.expensive(&access.org)?;
    let recurrence = diagnostics::recurrence(&rt, &access, &admitted, issue).await?;
    Ok(Json(json!(recurrence)))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ContextQuery {
    event: Option<String>,
    source: Option<i64>,
    window_secs: Option<i64>,
    limit: Option<usize>,
}

async fn context(
    State(ctx): State<AppContext>,
    access: OrgAccess,
    Path((_, issue)): Path<(String, i64)>,
    Query(query): Query<ContextQuery>,
) -> ApiResult<Json<Value>> {
    let options = ContextOptions {
        event: query.event.map(|event_id| EventRef {
            event_id,
            source: query.source,
        }),
        window_secs: query.window_secs,
        limit: query.limit,
    };
    let rt = Runtime::get(&ctx);
    let admitted = rt.admission.queries.expensive(&access.org)?;
    let context = diagnostics::error_context(&rt, &access, &admitted, issue, options).await?;
    Ok(Json(json!(context)))
}

pub fn routes() -> Routes {
    Routes::new()
        .prefix("/api/orgs/{org}")
        .add("/projects/{project}/deployments", get(list).post(record))
        .add("/deployments/{deployment}/comparison", get(compare))
        .add("/issues/{issue}/recurrence", get(recurrence))
        .add("/issues/{issue}/context", get(context))
}
