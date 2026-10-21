use axum::{
    body::{to_bytes, Body},
    extract::{Path, Query, State},
    http::{HeaderMap, StatusCode},
    routing::get,
    Json,
};
use loco_rs::{app::AppContext, controller::Routes};
use serde::Deserialize;
use serde_json::{json, Value};

use crate::{
    domain::ProjectId,
    error::{ApiError, ApiResult},
    identity::access::OrgAccess,
    releases::{ArtifactId, ArtifactQuery, UploadRequest},
    runtime::Runtime,
};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct UploadQuery {
    release: Option<String>,
    dist: Option<String>,
    name: String,
    debug_id: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Limit {
    limit: Option<u32>,
}

async fn upload(
    State(ctx): State<AppContext>,
    access: OrgAccess,
    Path((_, project)): Path<(String, i64)>,
    Query(query): Query<UploadQuery>,
    headers: HeaderMap,
    body: Body,
) -> ApiResult<(StatusCode, Json<Value>)> {
    access.require_manage()?;
    if headers
        .get("content-encoding")
        .is_some_and(|value| value != "identity")
    {
        return Err(ApiError::BadRequest("unsupported_content_encoding"));
    }
    let rt = Runtime::get(&ctx);
    let _slot = rt.releases.upload_slot()?;
    let body = to_bytes(body, rt.settings.releases.max_artifact_bytes)
        .await
        .map_err(|_| ApiError::TooLarge)?;
    let result = rt
        .releases
        .upload(
            &access,
            UploadRequest {
                project: ProjectId(project),
                release: query.release,
                dist: query.dist,
                name: query.name,
                debug_id: query.debug_id,
                body,
            },
        )
        .await?;
    let status = if result.created {
        StatusCode::CREATED
    } else {
        StatusCode::OK
    };
    Ok((status, Json(json!(result))))
}

async fn list(
    State(ctx): State<AppContext>,
    access: OrgAccess,
    Path((_, project)): Path<(String, i64)>,
    Query(query): Query<ArtifactQuery>,
) -> ApiResult<Json<Value>> {
    Ok(Json(json!(
        Runtime::get(&ctx)
            .releases
            .list(&access, ProjectId(project), query)
            .await?
    )))
}

async fn releases(
    State(ctx): State<AppContext>,
    access: OrgAccess,
    Path((_, project)): Path<(String, i64)>,
    Query(query): Query<Limit>,
) -> ApiResult<Json<Value>> {
    Ok(Json(
        json!({"releases": Runtime::get(&ctx).releases.releases(&access, ProjectId(project), query.limit).await?}),
    ))
}

async fn show(
    State(ctx): State<AppContext>,
    access: OrgAccess,
    Path((_, artifact)): Path<(String, ArtifactId)>,
) -> ApiResult<Json<Value>> {
    Ok(Json(json!(
        Runtime::get(&ctx).releases.get(&access, &artifact).await?
    )))
}

async fn delete(
    State(ctx): State<AppContext>,
    access: OrgAccess,
    Path((_, artifact)): Path<(String, ArtifactId)>,
) -> ApiResult<StatusCode> {
    Runtime::get(&ctx)
        .releases
        .delete(&access, &artifact)
        .await?;
    Ok(StatusCode::NO_CONTENT)
}

pub fn routes() -> Routes {
    Routes::new()
        .prefix("/api/orgs/{org}")
        .add("/projects/{project}/artifacts", get(list).post(upload))
        .add("/projects/{project}/releases", get(releases))
        .add("/artifacts/{artifact}", get(show).delete(delete))
}
