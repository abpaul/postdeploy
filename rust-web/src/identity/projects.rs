//! Projects, sources and ingestion keys. Keys are stored only as SHA-256
//! hashes; the DSN is shown once, when the key is created.

use sea_orm::{ConnectionTrait, SqliteTransactionMode, TransactionOptions, TransactionTrait};
use serde::Serialize;

use crate::{
    domain::{now_secs, Environment, OrgId, ProjectId, SourceId},
    error::{ApiError, ApiResult},
    identity::{access::OrgAccess, token_hash},
    runtime::{sql, Runtime},
};

#[derive(Debug, Serialize)]
pub struct Project {
    pub id: ProjectId,
    pub name: String,
}

#[derive(Debug, Serialize)]
pub struct Source {
    pub id: SourceId,
    pub project_id: ProjectId,
    pub name: String,
    pub environment: Environment,
    pub keys: Vec<KeyInfo>,
}

#[derive(Debug, Serialize)]
pub struct KeyInfo {
    pub id: i64,
    pub hint: String,
    pub revoked: bool,
}

/// A newly created key. `dsn` contains the secret and is returned only once.
#[derive(Serialize)]
pub struct NewKey {
    pub key: KeyInfo,
    pub dsn: String,
}

fn clean_name(name: &str) -> ApiResult<String> {
    let name = name.trim();
    (1..=100)
        .contains(&name.chars().count())
        .then(|| name.to_owned())
        .ok_or(ApiError::BadRequest("invalid_name"))
}

const DEFAULT_PAGE: usize = 25;
const MAX_PAGE: i64 = 100;

/// One bounded page of an id-ordered list. `cursor` is the `next` value of the
/// previous page.
#[derive(Clone, Copy, Debug)]
pub struct PageRequest {
    cursor: Option<i64>,
    limit: usize,
}

impl PageRequest {
    pub fn new(cursor: Option<i64>, limit: Option<i64>) -> ApiResult<Self> {
        let limit = match limit {
            None => DEFAULT_PAGE,
            Some(n @ 1..=MAX_PAGE) => n as usize,
            Some(_) => return Err(ApiError::BadRequest("invalid_pagination")),
        };
        if cursor.is_some_and(|id| id < 1) {
            return Err(ApiError::BadRequest("invalid_pagination"));
        }
        Ok(Self { cursor, limit })
    }

    pub fn cursor(&self) -> Option<i64> {
        self.cursor
    }

    pub fn limit(&self) -> usize {
        self.limit
    }
}

/// Splits one extra row off `rows` and returns the `next` cursor it implies.
fn finish_page<T>(mut rows: Vec<T>, limit: usize, id: impl Fn(&T) -> i64) -> (Vec<T>, Option<i64>) {
    if rows.len() <= limit {
        return (rows, None);
    }
    rows.truncate(limit);
    let next = rows.last().map(id);
    (rows, next)
}

fn project_rows(rows: &[sea_orm::QueryResult]) -> ApiResult<Vec<Project>> {
    rows.iter()
        .map(|row| {
            Ok(Project {
                id: ProjectId(row.try_get("", "id")?),
                name: row.try_get("", "name")?,
            })
        })
        .collect()
}

pub async fn list(rt: &Runtime, access: &OrgAccess) -> ApiResult<Vec<Project>> {
    let rows = rt
        .control
        .query_all_raw(sql(
            "SELECT id, name FROM projects WHERE org_id = ? ORDER BY id",
            vec![access.org.as_str().into()],
        ))
        .await?;
    project_rows(&rows)
}

pub async fn page(
    rt: &Runtime,
    access: &OrgAccess,
    request: &PageRequest,
) -> ApiResult<(Vec<Project>, Option<i64>)> {
    let limit = request.limit;
    let rows = rt
        .control
        .query_all_raw(sql(
            "SELECT id, name FROM projects WHERE org_id = ? AND id > ? ORDER BY id LIMIT ?",
            vec![
                access.org.as_str().into(),
                request.cursor.unwrap_or(0).into(),
                (limit as i64 + 1).into(),
            ],
        ))
        .await?;
    Ok(finish_page(project_rows(&rows)?, limit, |project| {
        project.id.0
    }))
}

pub async fn find(rt: &Runtime, access: &OrgAccess, name: &str) -> ApiResult<Option<Project>> {
    let rows = rt
        .control
        .query_all_raw(sql(
            "SELECT id, name FROM projects WHERE org_id = ? AND name = ?",
            vec![access.org.as_str().into(), name.into()],
        ))
        .await?;
    Ok(project_rows(&rows)?.pop())
}

/// Fails with `project_exists` when the organization has a project with this name.
pub async fn create(rt: &Runtime, access: &OrgAccess, name: &str) -> ApiResult<Project> {
    access.require_manage()?;
    let name = clean_name(name)?;
    let row = rt
        .control
        .query_one_raw(sql(
            "INSERT INTO projects (id, org_id, name, created_at) VALUES (
                MAX((SELECT COALESCE(MAX(id), 0) FROM projects),
                    (SELECT COALESCE(MAX(floor), 0) FROM id_floor WHERE name = 'projects')) + 1, ?, ?, ?)
             ON CONFLICT (org_id, name) DO NOTHING RETURNING id",
            vec![
                access.org.as_str().into(),
                name.clone().into(),
                now_secs().into(),
            ],
        ))
        .await?
        .ok_or(ApiError::Conflict("project_exists"))?;
    Ok(Project {
        id: ProjectId(row.try_get("", "id")?),
        name,
    })
}

async fn require_project<C: ConnectionTrait>(
    conn: &C,
    org: &OrgId,
    project: ProjectId,
) -> ApiResult<()> {
    conn.query_one_raw(sql(
        "SELECT 1 AS ok FROM projects WHERE id = ? AND org_id = ?",
        vec![project.0.into(), org.as_str().into()],
    ))
    .await?
    .map(|_| ())
    .ok_or(ApiError::NotFound)
}

fn assemble(
    project: ProjectId,
    rows: &[sea_orm::QueryResult],
    keys: &[sea_orm::QueryResult],
) -> ApiResult<Vec<Source>> {
    let mut out = Vec::new();
    for row in rows {
        let id: i64 = row.try_get("", "id")?;
        let environment: String = row.try_get("", "environment")?;
        let mut source_keys = Vec::new();
        for key in keys {
            if key.try_get::<i64>("", "source_id")? == id {
                source_keys.push(KeyInfo {
                    id: key.try_get("", "id")?,
                    hint: key.try_get("", "key_hint")?,
                    revoked: key.try_get::<Option<i64>>("", "revoked_at")?.is_some(),
                });
            }
        }
        out.push(Source {
            id: SourceId(id),
            project_id: project,
            name: row.try_get("", "name")?,
            environment: Environment::parse(&environment)
                .ok_or(ApiError::Internal("stored environment".into()))?,
            keys: source_keys,
        });
    }
    Ok(out)
}

/// Sources of `rows` with their keys. `rows` holds at most one page plus one.
async fn with_keys(
    rt: &Runtime,
    project: ProjectId,
    rows: &[sea_orm::QueryResult],
) -> ApiResult<Vec<Source>> {
    if rows.is_empty() {
        return Ok(Vec::new());
    }
    let ids = rows
        .iter()
        .map(|row| row.try_get::<i64>("", "id").map(sea_orm::Value::from))
        .collect::<Result<Vec<_>, _>>()?;
    let keys = rt
        .control
        .query_all_raw(sql(
            &format!(
                "SELECT id, source_id, key_hint, revoked_at FROM ingest_keys WHERE source_id IN ({}) ORDER BY id",
                vec!["?"; ids.len()].join(", ")
            ),
            ids,
        ))
        .await?;
    assemble(project, rows, &keys)
}

pub async fn sources(
    rt: &Runtime,
    access: &OrgAccess,
    project: ProjectId,
) -> ApiResult<Vec<Source>> {
    require_project(&rt.control, &access.org, project).await?;
    let rows = rt
        .control
        .query_all_raw(sql(
            "SELECT id, name, environment FROM sources WHERE project_id = ? AND org_id = ? ORDER BY id",
            vec![project.0.into(), access.org.as_str().into()],
        ))
        .await?;
    let keys = rt
        .control
        .query_all_raw(sql(
            "SELECT id, source_id, key_hint, revoked_at FROM ingest_keys WHERE project_id = ? AND org_id = ? ORDER BY id",
            vec![project.0.into(), access.org.as_str().into()],
        ))
        .await?;
    assemble(project, &rows, &keys)
}

pub async fn source_page(
    rt: &Runtime,
    access: &OrgAccess,
    project: ProjectId,
    request: &PageRequest,
) -> ApiResult<(Vec<Source>, Option<i64>)> {
    require_project(&rt.control, &access.org, project).await?;
    let limit = request.limit;
    let rows = rt
        .control
        .query_all_raw(sql(
            "SELECT id, name, environment FROM sources WHERE project_id = ? AND org_id = ? AND id > ?
             ORDER BY id LIMIT ?",
            vec![
                project.0.into(),
                access.org.as_str().into(),
                request.cursor.unwrap_or(0).into(),
                (limit as i64 + 1).into(),
            ],
        ))
        .await?;
    Ok(finish_page(
        with_keys(rt, project, &rows).await?,
        limit,
        |source| source.id.0,
    ))
}

pub async fn find_source(
    rt: &Runtime,
    access: &OrgAccess,
    project: ProjectId,
    name: &str,
    environment: Environment,
) -> ApiResult<Option<Source>> {
    let rows = rt
        .control
        .query_all_raw(sql(
            "SELECT id, name, environment FROM sources
             WHERE project_id = ? AND org_id = ? AND name = ? AND environment = ?",
            vec![
                project.0.into(),
                access.org.as_str().into(),
                name.into(),
                environment.as_str().into(),
            ],
        ))
        .await?;
    Ok(with_keys(rt, project, &rows).await?.pop())
}

/// Fails with `source_exists` when the project has a source with this name and
/// environment.
pub async fn create_source(
    rt: &Runtime,
    access: &OrgAccess,
    project: ProjectId,
    name: &str,
    environment: &str,
) -> ApiResult<(Source, NewKey)> {
    access.require_manage()?;
    let name = clean_name(name)?;
    let environment =
        Environment::parse(environment).ok_or(ApiError::BadRequest("invalid_environment"))?;
    let txn = rt
        .control
        .begin_with_options(TransactionOptions {
            sqlite_transaction_mode: Some(SqliteTransactionMode::Immediate),
            ..TransactionOptions::default()
        })
        .await?;
    require_project(&txn, &access.org, project).await?;
    let row = txn
        .query_one_raw(sql(
            "INSERT INTO sources (id, org_id, project_id, name, environment, created_at) VALUES (
                MAX((SELECT COALESCE(MAX(id), 0) FROM sources),
                    (SELECT COALESCE(MAX(floor), 0) FROM id_floor WHERE name = 'sources')) + 1, ?, ?, ?, ?, ?)
             ON CONFLICT (project_id, name, environment) DO NOTHING RETURNING id",
            vec![
                access.org.as_str().into(),
                project.0.into(),
                name.clone().into(),
                environment.as_str().into(),
                now_secs().into(),
            ],
        ))
        .await?
        .ok_or(ApiError::Conflict("source_exists"))?;
    let source = SourceId(row.try_get("", "id")?);
    let key = insert_key(rt, &txn, &access.org, project, source).await?;
    txn.commit().await?;
    Ok((
        Source {
            id: source,
            project_id: project,
            name,
            environment,
            keys: vec![KeyInfo {
                id: key.key.id,
                hint: key.key.hint.clone(),
                revoked: false,
            }],
        },
        key,
    ))
}

pub async fn create_key(rt: &Runtime, access: &OrgAccess, source: SourceId) -> ApiResult<NewKey> {
    access.require_manage()?;
    let txn = rt.control.begin().await?;
    let row = txn
        .query_one_raw(sql(
            "SELECT project_id FROM sources WHERE id = ? AND org_id = ?",
            vec![source.0.into(), access.org.as_str().into()],
        ))
        .await?
        .ok_or(ApiError::NotFound)?;
    let project = ProjectId(row.try_get("", "project_id")?);
    let key = insert_key(rt, &txn, &access.org, project, source).await?;
    txn.commit().await?;
    Ok(key)
}

pub async fn revoke_key(
    rt: &Runtime,
    access: &OrgAccess,
    source: SourceId,
    key: i64,
) -> ApiResult<()> {
    access.require_manage()?;
    let result = rt
        .control
        .execute_raw(sql(
            "UPDATE ingest_keys SET revoked_at = COALESCE(revoked_at, ?) WHERE id = ? AND source_id = ? AND org_id = ?",
            vec![now_secs().into(), key.into(), source.0.into(), access.org.as_str().into()],
        ))
        .await?;
    if result.rows_affected() == 0 {
        return Err(ApiError::NotFound);
    }
    Ok(())
}

async fn insert_key<C: ConnectionTrait>(
    rt: &Runtime,
    conn: &C,
    org: &OrgId,
    project: ProjectId,
    source: SourceId,
) -> ApiResult<NewKey> {
    let secret = hex::encode(rand::random::<[u8; 16]>());
    let hint = secret[..6].to_owned();
    let row = conn
        .query_one_raw(sql(
            "INSERT INTO ingest_keys (org_id, project_id, source_id, key_hash, key_hint, created_at)
             VALUES (?, ?, ?, ?, ?, ?) RETURNING id",
            vec![
                org.as_str().into(),
                project.0.into(),
                source.0.into(),
                token_hash(&secret).into(),
                hint.clone().into(),
                now_secs().into(),
            ],
        ))
        .await?
        .ok_or(ApiError::Internal("key insert".into()))?;
    let origin = &rt.settings.auth.origin;
    let (scheme, host) = origin
        .split_once("://")
        .ok_or(ApiError::Internal("origin setting".into()))?;
    Ok(NewKey {
        key: KeyInfo {
            id: row.try_get("", "id")?,
            hint,
            revoked: false,
        },
        dsn: format!("{scheme}://{secret}@{host}/{}", project.0),
    })
}
