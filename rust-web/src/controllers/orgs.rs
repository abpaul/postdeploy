use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::{delete, get, post},
    Json,
};
use loco_rs::{app::AppContext, controller::Routes};
use serde::Deserialize;
use serde_json::json;

use super::PageAfter;
use crate::{
    domain::{ProjectId, Role, SourceId, UserId},
    error::{ApiError, ApiResult},
    identity::{
        access::{OrgAccess, Session},
        orgs, projects,
    },
    ingest::policy::{self, StoredPolicy},
    runtime::Runtime,
};

#[derive(Deserialize)]
struct NameBody {
    name: String,
}

#[derive(Deserialize)]
struct MemberBody {
    email: String,
    role: String,
}

#[derive(Deserialize)]
struct SourceBody {
    name: String,
    environment: String,
}

async fn list(
    State(ctx): State<AppContext>,
    session: Session,
) -> ApiResult<Json<serde_json::Value>> {
    let orgs = orgs::list(&Runtime::get(&ctx), session.user).await?;
    Ok(Json(json!({ "orgs": orgs })))
}

async fn create(
    State(ctx): State<AppContext>,
    session: Session,
    Json(body): Json<NameBody>,
) -> ApiResult<Response> {
    let org = orgs::create(&Runtime::get(&ctx), session.user, &body.name).await?;
    Ok((StatusCode::CREATED, Json(org)).into_response())
}

async fn show(State(ctx): State<AppContext>, access: OrgAccess) -> ApiResult<Response> {
    Ok(Json(orgs::get(&Runtime::get(&ctx), &access).await?).into_response())
}

async fn members(
    State(ctx): State<AppContext>,
    access: OrgAccess,
) -> ApiResult<Json<serde_json::Value>> {
    let members = orgs::members(&Runtime::get(&ctx), &access).await?;
    Ok(Json(json!({ "members": members })))
}

async fn add_member(
    State(ctx): State<AppContext>,
    access: OrgAccess,
    Json(body): Json<MemberBody>,
) -> ApiResult<Response> {
    let role = Role::parse(&body.role).ok_or(ApiError::BadRequest("invalid_role"))?;
    let member = orgs::add_member(&Runtime::get(&ctx), &access, &body.email, role).await?;
    Ok((StatusCode::CREATED, Json(member)).into_response())
}

async fn remove_member(
    State(ctx): State<AppContext>,
    access: OrgAccess,
    Path((_, user)): Path<(String, i64)>,
) -> ApiResult<StatusCode> {
    orgs::remove_member(&Runtime::get(&ctx), &access, UserId(user)).await?;
    Ok(StatusCode::NO_CONTENT)
}

async fn list_projects(
    State(ctx): State<AppContext>,
    access: OrgAccess,
    PageAfter(page): PageAfter,
) -> ApiResult<Json<serde_json::Value>> {
    let (projects, next) = projects::page(&Runtime::get(&ctx), &access, &page).await?;
    Ok(Json(json!({ "projects": projects, "next": next })))
}

async fn create_project(
    State(ctx): State<AppContext>,
    access: OrgAccess,
    Json(body): Json<NameBody>,
) -> ApiResult<Response> {
    let project = projects::create(&Runtime::get(&ctx), &access, &body.name).await?;
    Ok((StatusCode::CREATED, Json(project)).into_response())
}

async fn list_sources(
    State(ctx): State<AppContext>,
    access: OrgAccess,
    Path((_, project)): Path<(String, i64)>,
    PageAfter(page): PageAfter,
) -> ApiResult<Json<serde_json::Value>> {
    let (sources, next) =
        projects::source_page(&Runtime::get(&ctx), &access, ProjectId(project), &page).await?;
    Ok(Json(json!({ "sources": sources, "next": next })))
}

async fn create_source(
    State(ctx): State<AppContext>,
    access: OrgAccess,
    Path((_, project)): Path<(String, i64)>,
    Json(body): Json<SourceBody>,
) -> ApiResult<Response> {
    let (source, key) = projects::create_source(
        &Runtime::get(&ctx),
        &access,
        ProjectId(project),
        &body.name,
        &body.environment,
    )
    .await?;
    Ok((
        StatusCode::CREATED,
        Json(json!({ "source": source, "key": key.key, "dsn": key.dsn })),
    )
        .into_response())
}

async fn create_key(
    State(ctx): State<AppContext>,
    access: OrgAccess,
    Path((_, source)): Path<(String, i64)>,
) -> ApiResult<Response> {
    let key = projects::create_key(&Runtime::get(&ctx), &access, SourceId(source)).await?;
    Ok((StatusCode::CREATED, Json(key)).into_response())
}

async fn revoke_key(
    State(ctx): State<AppContext>,
    access: OrgAccess,
    Path((_, source, key)): Path<(String, i64, i64)>,
) -> ApiResult<StatusCode> {
    projects::revoke_key(&Runtime::get(&ctx), &access, SourceId(source), key).await?;
    Ok(StatusCode::NO_CONTENT)
}

async fn ingestion_policy(
    State(ctx): State<AppContext>,
    access: OrgAccess,
) -> ApiResult<Json<StoredPolicy>> {
    Ok(Json(policy::load(&Runtime::get(&ctx), &access).await?))
}

async fn set_ingestion_policy(
    State(ctx): State<AppContext>,
    access: OrgAccess,
    Json(body): Json<serde_json::Value>,
) -> ApiResult<Json<StoredPolicy>> {
    Ok(Json(
        policy::save(&Runtime::get(&ctx), &access, body).await?,
    ))
}

pub fn routes() -> Routes {
    Routes::new()
        .prefix("/api/orgs")
        .add("/", get(list).post(create))
        .add("/{org}", get(show))
        .add("/{org}/members", get(members).post(add_member))
        .add("/{org}/members/{user}", delete(remove_member))
        .add("/{org}/projects", get(list_projects).post(create_project))
        .add(
            "/{org}/projects/{project}/sources",
            get(list_sources).post(create_source),
        )
        .add("/{org}/sources/{source}/keys", post(create_key))
        .add("/{org}/sources/{source}/keys/{key}", delete(revoke_key))
        .add(
            "/{org}/ingestion-policy",
            get(ingestion_policy).put(set_ingestion_policy),
        )
}
