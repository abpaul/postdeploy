use sea_orm::ConnectionTrait;
use serde::{Deserialize, Serialize};

use crate::{
    domain::{now_micros, Environment, ProjectId},
    error::{ApiError, ApiResult},
    identity::access::OrgAccess,
    runtime::{sql, Runtime},
};

pub const MAX_PAGE: u32 = 50;
const MAX_VERSION_BYTES: usize = 200;
const MAX_FUTURE_US: i64 = 300_000_000;

#[derive(Debug, Deserialize)]
pub struct NewDeployment {
    pub environment: String,
    pub version: String,
    /// Full 40- or 64-character hexadecimal commit SHA.
    pub commit_sha: Option<String>,
    /// Unix microseconds. Default: the time the request is received.
    pub deployed_at: Option<i64>,
}

#[derive(Clone, Debug, Serialize)]
pub struct Deployment {
    pub id: i64,
    pub project_id: i64,
    pub environment: String,
    pub version: String,
    pub commit_sha: Option<String>,
    pub deployed_at: i64,
    pub recorded_at: i64,
    pub recorded_by: i64,
}

#[derive(Debug, Default, Deserialize)]
pub struct DeploymentQuery {
    pub environment: Option<String>,
    pub limit: Option<u32>,
    pub before: Option<String>,
}

/// `d1.{deployed_at}.{id}`, newest first.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DeploymentCursor {
    deployed_at: i64,
    id: i64,
}

impl DeploymentCursor {
    pub fn parse(value: &str) -> Option<Self> {
        let (deployed_at, id) = value.strip_prefix("d1.")?.split_once('.')?;
        let cursor = Self {
            deployed_at: deployed_at.parse().ok()?,
            id: id.parse().ok()?,
        };
        (cursor.id > 0 && cursor.deployed_at >= 0).then_some(cursor)
    }
}

impl std::fmt::Display for DeploymentCursor {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "d1.{}.{}", self.deployed_at, self.id)
    }
}

pub(crate) const COLUMNS: &str =
    "id, project_id, environment, version, commit_sha, deployed_at, recorded_at, recorded_by";

pub(crate) fn row(row: &sea_orm::QueryResult) -> Result<Deployment, sea_orm::DbErr> {
    Ok(Deployment {
        id: row.try_get("", "id")?,
        project_id: row.try_get("", "project_id")?,
        environment: row.try_get("", "environment")?,
        version: row.try_get("", "version")?,
        commit_sha: row.try_get("", "commit_sha")?,
        deployed_at: row.try_get("", "deployed_at")?,
        recorded_at: row.try_get("", "recorded_at")?,
        recorded_by: row.try_get("", "recorded_by")?,
    })
}

fn version(value: &str) -> ApiResult<String> {
    let value = value.trim();
    let valid = !value.is_empty()
        && value.len() <= MAX_VERSION_BYTES
        && !value.chars().any(char::is_control);
    valid
        .then(|| value.to_owned())
        .ok_or(ApiError::BadRequest("invalid_version"))
}

fn commit_sha(value: Option<&str>) -> ApiResult<Option<String>> {
    value
        .map(|sha| {
            let valid = matches!(sha.len(), 40 | 64) && sha.bytes().all(|b| b.is_ascii_hexdigit());
            valid
                .then(|| sha.to_ascii_lowercase())
                .ok_or(ApiError::BadRequest("invalid_commit_sha"))
        })
        .transpose()
}

pub(crate) async fn require_project(
    rt: &Runtime,
    access: &OrgAccess,
    project: ProjectId,
) -> ApiResult<()> {
    rt.control
        .query_one_raw(sql(
            "SELECT 1 AS found FROM projects WHERE id = ? AND org_id = ?",
            vec![project.0.into(), access.org.as_str().into()],
        ))
        .await?
        .map(|_| ())
        .ok_or(ApiError::NotFound)
}

/// Records a deployment. Returns the stored row and whether this call created
/// it. Repeating a request returns the same row; the same identity with a
/// different commit is a conflict.
pub async fn record(
    rt: &Runtime,
    access: &OrgAccess,
    project: ProjectId,
    input: NewDeployment,
) -> ApiResult<(Deployment, bool)> {
    access.require_manage()?;
    let environment = Environment::parse(&input.environment)
        .ok_or(ApiError::BadRequest("invalid_environment"))?;
    let version = version(&input.version)?;
    let commit_sha = commit_sha(input.commit_sha.as_deref())?;
    let now = now_micros();
    let deployed_at = input.deployed_at.unwrap_or(now);
    if !(0..=now + MAX_FUTURE_US).contains(&deployed_at) {
        return Err(ApiError::BadRequest("invalid_deployed_at"));
    }
    require_project(rt, access, project).await?;
    let handle = rt.tenant(&access.org).await?;
    let inserted = handle
        .execute_raw(sql(
            "INSERT INTO deployments (project_id, environment, version, commit_sha, deployed_at, recorded_at, recorded_by)
             VALUES (?, ?, ?, ?, ?, ?, ?)
             ON CONFLICT (project_id, environment, version, deployed_at) DO NOTHING",
            vec![
                project.0.into(),
                environment.as_str().into(),
                version.clone().into(),
                commit_sha.clone().into(),
                deployed_at.into(),
                now.into(),
                access.user.0.into(),
            ],
        ))
        .await?;
    let stored = handle
        .query_one_raw(sql(
            &format!(
                "SELECT {COLUMNS} FROM deployments
                 WHERE project_id = ? AND environment = ? AND version = ? AND deployed_at = ?"
            ),
            vec![
                project.0.into(),
                environment.as_str().into(),
                version.into(),
                deployed_at.into(),
            ],
        ))
        .await?
        .ok_or(ApiError::Internal("deployment upsert".into()))?;
    drop(handle);
    let stored = row(&stored)?;
    if stored.commit_sha != commit_sha {
        return Err(ApiError::Conflict("deployment_exists"));
    }
    Ok((stored, inserted.rows_affected() == 1))
}

/// Newest deployment first. `next` is the `before` value for the next page.
pub async fn list(
    rt: &Runtime,
    access: &OrgAccess,
    project: ProjectId,
    query: DeploymentQuery,
) -> ApiResult<(Vec<Deployment>, Option<String>)> {
    require_project(rt, access, project).await?;
    let limit = query.limit.unwrap_or(20).clamp(1, MAX_PAGE);
    let mut conditions = vec!["project_id = ?"];
    let mut values: Vec<sea_orm::Value> = vec![project.0.into()];
    if let Some(environment) = &query.environment {
        let environment =
            Environment::parse(environment).ok_or(ApiError::BadRequest("invalid_environment"))?;
        conditions.push("environment = ?");
        values.push(environment.as_str().into());
    }
    if let Some(before) = &query.before {
        let cursor =
            DeploymentCursor::parse(before).ok_or(ApiError::BadRequest("invalid_cursor"))?;
        conditions.push("(deployed_at < ? OR (deployed_at = ? AND id < ?))");
        values.extend([
            cursor.deployed_at.into(),
            cursor.deployed_at.into(),
            cursor.id.into(),
        ]);
    }
    values.push((i64::from(limit) + 1).into());
    let handle = rt.tenant(&access.org).await?;
    let rows = handle
        .query_all_raw(sql(
            &format!(
                "SELECT {COLUMNS} FROM deployments WHERE {} ORDER BY deployed_at DESC, id DESC LIMIT ?",
                conditions.join(" AND ")
            ),
            values,
        ))
        .await?;
    drop(handle);
    let mut deployments: Vec<Deployment> = rows.iter().map(row).collect::<Result<_, _>>()?;
    let next = (deployments.len() > limit as usize).then(|| {
        deployments.truncate(limit as usize);
        deployments.last().map(|d| {
            DeploymentCursor {
                deployed_at: d.deployed_at,
                id: d.id,
            }
            .to_string()
        })
    });
    Ok((deployments, next.flatten()))
}
