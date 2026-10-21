use std::{
    collections::{HashMap, VecDeque},
    fmt,
    str::FromStr,
    sync::{Arc, Mutex},
    time::Duration,
};

use bytes::Bytes;
use futures::{stream, StreamExt};
use sea_orm::{
    ConnectionTrait, DatabaseConnection, SqliteTransactionMode, TransactionOptions,
    TransactionTrait,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use sourcemap::SourceMap;
use tenant_sqlite_loco::TenantPools;
use tokio::{
    sync::{OwnedSemaphorePermit, Semaphore},
    time::Instant,
};

use crate::{
    domain::{now_micros, OrgId, ProjectId, UserId},
    error::{ApiError, ApiResult},
    identity::access::OrgAccess,
    ingest::{event::clip, interfaces},
    runtime::sql,
    scrub,
    store::ObjectStore,
};

const MAX_NAME_BYTES: usize = 512;
const MAX_RELEASE_BYTES: usize = 200;
const MAX_DIST_BYTES: usize = 64;
const MAX_DEBUG_IMAGES: usize = 100;
const MAX_PAGE: u32 = 100;
const READ_CONCURRENCY: usize = 2;

#[derive(Clone, Debug, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct ReleaseSettings {
    /// Largest accepted source map, before and after scrubbing.
    pub max_artifact_bytes: usize,
    /// Bounds the decoded token table, which dominates parse memory.
    pub max_mappings_bytes: usize,
    pub max_sources: usize,
    pub max_names: usize,
    pub max_artifacts_per_project: u64,
    /// Concurrent decompress-and-parse tasks across all requests.
    pub parse_concurrency: usize,
    pub parse_wait_ms: u64,
    pub symbolicate_deadline_ms: u64,
    pub max_frames: usize,
    pub max_files_per_event: usize,
    pub max_maps_per_event: usize,
    pub context_lines: u32,
    pub max_context_line_chars: usize,
    /// Budget for decoded tokens, strings, and source line indexes.
    pub cache_bytes: usize,
}

impl Default for ReleaseSettings {
    fn default() -> Self {
        Self {
            max_artifact_bytes: 16 << 20,
            max_mappings_bytes: 4 << 20,
            max_sources: 10_000,
            max_names: 200_000,
            max_artifacts_per_project: 10_000,
            parse_concurrency: 2,
            parse_wait_ms: 5_000,
            symbolicate_deadline_ms: 5_000,
            max_frames: 250,
            max_files_per_event: 32,
            max_maps_per_event: 8,
            context_lines: 5,
            max_context_line_chars: 200,
            cache_bytes: 64 << 20,
        }
    }
}

impl ReleaseSettings {
    pub fn validate(&self) -> bool {
        (1..=64 << 20).contains(&self.max_artifact_bytes)
            && (1..=16 << 20).contains(&self.max_mappings_bytes)
            && self.max_mappings_bytes <= self.max_artifact_bytes
            && (1..=50_000).contains(&self.max_sources)
            && (1..=500_000).contains(&self.max_names)
            && (1..=100_000).contains(&self.max_artifacts_per_project)
            && (1..=8).contains(&self.parse_concurrency)
            && (1..=30_000).contains(&self.parse_wait_ms)
            && (1..=30_000).contains(&self.symbolicate_deadline_ms)
            && (1..=1_000).contains(&self.max_frames)
            && (1..=64).contains(&self.max_files_per_event)
            && (1..=32).contains(&self.max_maps_per_event)
            && self.context_lines <= 10
            && (1..=1_000).contains(&self.max_context_line_chars)
            && self.cache_bytes <= 256 << 20
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize)]
#[serde(transparent)]
pub struct ArtifactId(String);

impl ArtifactId {
    fn generate() -> Self {
        Self(format!("a{}", uuid::Uuid::now_v7().simple()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl FromStr for ArtifactId {
    type Err = ();

    fn from_str(value: &str) -> Result<Self, ()> {
        let valid = value.len() == 33
            && value.starts_with('a')
            && value[1..]
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b));
        valid.then(|| Self(value.to_owned())).ok_or(())
    }
}

impl fmt::Display for ArtifactId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl<'de> Deserialize<'de> for ArtifactId {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        String::deserialize(deserializer)?
            .parse()
            .map_err(|()| serde::de::Error::custom("invalid artifact id"))
    }
}

fn release_text(value: &str, max: usize) -> Option<String> {
    let valid = !value.is_empty()
        && value.len() <= max
        && !matches!(value, "." | ".." | " ")
        && !value
            .chars()
            .any(|c| c.is_control() || c == '/' || c == '\\');
    valid.then(|| value.to_owned())
}

/// The URL path of the generated file a map applies to, as `~/path`. Scheme
/// and host are dropped so one upload serves every origin of the asset.
pub fn artifact_name(raw: &str) -> Option<String> {
    let raw = raw.trim();
    if raw.is_empty() || raw.len() > MAX_NAME_BYTES || raw.contains('\\') {
        return None;
    }
    if raw.chars().any(char::is_control) {
        return None;
    }
    let path = if let Some(rest) = raw.strip_prefix("~/") {
        rest
    } else if let Some(scheme) = raw.find("://") {
        let after = &raw[scheme + 3..];
        &after[after.find('/')? + 1..]
    } else {
        raw.trim_start_matches('/')
    };
    let path = &path[..path.find(['?', '#']).unwrap_or(path.len())];
    let valid = !path.is_empty()
        && path
            .split('/')
            .all(|segment| !matches!(segment, "" | "." | ".."));
    valid.then(|| format!("~/{path}"))
}

fn mappable(file: &str) -> bool {
    file.starts_with('/') || file.starts_with("~/") || file.contains("://")
}

fn basename(name: &str) -> &str {
    name.rsplit('/').next().unwrap_or(name)
}

fn debug_id(raw: &str) -> Option<String> {
    uuid::Uuid::parse_str(raw.trim())
        .ok()
        .map(|id| id.hyphenated().to_string())
}

/// Untrusted upload parameters. The controller passes the body as received,
/// after decoding any content encoding within `max_artifact_bytes`.
#[derive(Clone)]
pub struct UploadRequest {
    pub project: ProjectId,
    pub release: Option<String>,
    pub dist: Option<String>,
    /// The generated file URL or path that the map applies to.
    pub name: String,
    pub debug_id: Option<String>,
    pub body: Bytes,
}

impl fmt::Debug for UploadRequest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("UploadRequest")
            .field("project", &self.project)
            .field("body_bytes", &self.body.len())
            .finish_non_exhaustive()
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Artifact {
    pub id: ArtifactId,
    pub project_id: ProjectId,
    pub release: Option<String>,
    pub dist: Option<String>,
    pub name: String,
    pub debug_id: Option<String>,
    pub sha256: String,
    /// Size of the stored, scrubbed map JSON.
    pub size: i64,
    pub stored_bytes: i64,
    pub uploaded_by: UserId,
    pub created_at: i64,
}

#[derive(Debug, Serialize)]
pub struct Uploaded {
    pub artifact: Artifact,
    /// False when an identical map was already stored for the same target.
    pub created: bool,
}

#[derive(Debug, Serialize)]
pub struct ReleaseSummary {
    pub release: String,
    pub dist: Option<String>,
    pub artifact_count: i64,
    pub last_uploaded: i64,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ArtifactQuery {
    pub release: Option<String>,
    pub dist: Option<String>,
    pub limit: Option<u32>,
    pub before: Option<ArtifactId>,
}

#[derive(Debug, Serialize)]
pub struct ArtifactPage {
    pub artifacts: Vec<Artifact>,
    pub next: Option<ArtifactId>,
}

#[derive(Deserialize, Serialize)]
struct MapDocument {
    version: u8,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    file: Option<String>,
    #[serde(
        rename = "sourceRoot",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    source_root: Option<String>,
    sources: Option<Vec<Option<String>>>,
    #[serde(
        rename = "sourcesContent",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    sources_content: Option<Vec<Option<String>>>,
    #[serde(default)]
    names: Vec<String>,
    mappings: Option<String>,
    #[serde(
        rename = "debugId",
        alias = "debug_id",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    debug_id: Option<String>,
    #[serde(
        rename = "ignoreList",
        alias = "x_google_ignoreList",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    ignore_list: Option<Vec<u32>>,
    #[serde(default, skip_serializing)]
    sections: Option<serde::de::IgnoredAny>,
}

fn scrub_lines(content: &str) -> String {
    let mut out = String::with_capacity(content.len());
    let mut rest = content;
    while let Some(end) = rest.find(['\n', '\r']) {
        out.push_str(&scrub::BUILT_IN.text(&rest[..end]));
        out.push_str(&rest[end..=end]);
        rest = &rest[end + 1..];
    }
    out.push_str(&scrub::BUILT_IN.text(rest));
    out
}

struct Prepared {
    json: Vec<u8>,
    compressed: Vec<u8>,
    sha256: String,
    debug_id: Option<String>,
}

#[derive(Debug, PartialEq, Eq)]
enum MapRejected {
    Invalid,
    Unsupported,
    TooLarge,
}

fn prepare(body: &[u8], settings: &ReleaseSettings) -> Result<Prepared, MapRejected> {
    if body.len() > settings.max_artifact_bytes {
        return Err(MapRejected::TooLarge);
    }
    let mut map: MapDocument = serde_json::from_slice(body).map_err(|_| MapRejected::Invalid)?;
    if map.sections.is_some() {
        return Err(MapRejected::Unsupported);
    }
    let (Some(sources), Some(mappings)) = (&map.sources, &map.mappings) else {
        return Err(MapRejected::Invalid);
    };
    if map.version != 3 {
        return Err(MapRejected::Invalid);
    }
    if mappings.len() > settings.max_mappings_bytes
        || sources.len() > settings.max_sources
        || map.names.len() > settings.max_names
    {
        return Err(MapRejected::TooLarge);
    }
    if map
        .sources_content
        .as_ref()
        .is_some_and(|content| content.len() > sources.len())
    {
        return Err(MapRejected::Invalid);
    }
    for source in map.sources.iter_mut().flatten().flatten() {
        if let std::borrow::Cow::Owned(clean) = scrub::BUILT_IN.text(source) {
            *source = clean;
        }
    }
    for content in map.sources_content.iter_mut().flatten().flatten() {
        *content = scrub_lines(content);
    }
    for value in [&mut map.file, &mut map.source_root].into_iter().flatten() {
        *value = scrub::BUILT_IN.text(value).into_owned();
    }
    let embedded = match map.debug_id.as_deref() {
        Some(raw) => Some(debug_id(raw).ok_or(MapRejected::Invalid)?),
        None => None,
    };
    let json = serde_json::to_vec(&map).map_err(|_| MapRejected::Invalid)?;
    if json.len() > settings.max_artifact_bytes {
        return Err(MapRejected::TooLarge);
    }
    SourceMap::from_slice(&json).map_err(|_| MapRejected::Invalid)?;
    let compressed = zstd::stream::encode_all(&json[..], 3).map_err(|_| MapRejected::Invalid)?;
    let sha256 = hex::encode(Sha256::digest(&json));
    Ok(Prepared {
        json,
        compressed,
        sha256,
        debug_id: embedded,
    })
}

struct Target {
    project: ProjectId,
    release: Option<String>,
    dist: String,
    name: String,
    debug_id: Option<String>,
}

fn target(request: &UploadRequest) -> ApiResult<Target> {
    let release = match request.release.as_deref() {
        Some(raw) => Some(
            release_text(raw.trim(), MAX_RELEASE_BYTES)
                .ok_or(ApiError::BadRequest("invalid_release"))?,
        ),
        None => None,
    };
    let dist = match request.dist.as_deref() {
        Some(raw) => {
            release_text(raw.trim(), MAX_DIST_BYTES).ok_or(ApiError::BadRequest("invalid_dist"))?
        }
        None => String::new(),
    };
    let name = artifact_name(&request.name).ok_or(ApiError::BadRequest("invalid_name"))?;
    let debug_id = match request.debug_id.as_deref() {
        Some(raw) => Some(debug_id(raw).ok_or(ApiError::BadRequest("invalid_debug_id"))?),
        None => None,
    };
    Ok(Target {
        project: request.project,
        release,
        dist,
        name,
        debug_id,
    })
}

pub struct Releases {
    control: DatabaseConnection,
    tenants: TenantPools,
    store: ObjectStore,
    settings: ReleaseSettings,
    parse: Arc<Semaphore>,
    upload_bodies: Arc<Semaphore>,
    symbolications: Arc<Semaphore>,
    cache: Mutex<MapCache>,
}

const ARTIFACT_COLUMNS: &str =
    "id, project_id, release, dist, name, debug_id, sha256, raw_bytes, stored_bytes, uploaded_by, created_at";

fn artifact_row(row: &sea_orm::QueryResult) -> Result<Artifact, sea_orm::DbErr> {
    let id: String = row.try_get("", "id")?;
    let dist: String = row.try_get("", "dist")?;
    Ok(Artifact {
        id: id
            .parse()
            .map_err(|()| sea_orm::DbErr::Custom("stored artifact id".into()))?,
        project_id: ProjectId(row.try_get("", "project_id")?),
        release: row.try_get("", "release")?,
        dist: (!dist.is_empty()).then_some(dist),
        name: row.try_get("", "name")?,
        debug_id: row.try_get("", "debug_id")?,
        sha256: row.try_get("", "sha256")?,
        size: row.try_get("", "raw_bytes")?,
        stored_bytes: row.try_get("", "stored_bytes")?,
        uploaded_by: UserId(row.try_get("", "uploaded_by")?),
        created_at: row.try_get("", "created_at")?,
    })
}

fn object_key(org: &OrgId, project: ProjectId, id: &ArtifactId) -> String {
    format!("releases/v1/{org}/{}/{id}.map.zst", project.0)
}

async fn existing_target<C: ConnectionTrait>(
    conn: &C,
    target: &Target,
    debug_id: Option<&str>,
) -> ApiResult<Option<Artifact>> {
    let row = conn
        .query_one_raw(sql(
            &format!(
                "SELECT {ARTIFACT_COLUMNS} FROM release_artifacts WHERE project_id = ? AND (
                    (release IS NOT NULL AND release = ? AND dist = ? AND name = ?)
                    OR (debug_id IS NOT NULL AND debug_id = ?)) LIMIT 1"
            ),
            vec![
                target.project.0.into(),
                target.release.clone().into(),
                target.dist.clone().into(),
                target.name.clone().into(),
                debug_id.map(str::to_owned).into(),
            ],
        ))
        .await?;
    Ok(row.as_ref().map(artifact_row).transpose()?)
}

fn reuse(
    existing: Artifact,
    sha256: &str,
    target: &Target,
    debug_id: Option<&str>,
) -> ApiResult<Uploaded> {
    let same = existing.sha256 == sha256
        && existing.release == target.release
        && existing.dist.as_deref().unwrap_or("") == target.dist
        && existing.name == target.name
        && existing.debug_id.as_deref() == debug_id;
    if same {
        Ok(Uploaded {
            artifact: existing,
            created: false,
        })
    } else {
        Err(ApiError::Conflict("artifact_exists"))
    }
}

impl Releases {
    pub fn new(
        control: DatabaseConnection,
        tenants: TenantPools,
        store: ObjectStore,
        settings: ReleaseSettings,
    ) -> Self {
        Self {
            parse: Arc::new(Semaphore::new(settings.parse_concurrency.max(1))),
            upload_bodies: Arc::new(Semaphore::new(settings.parse_concurrency.max(1))),
            symbolications: Arc::new(Semaphore::new(settings.parse_concurrency.max(1))),
            cache: Mutex::new(MapCache::default()),
            control,
            tenants,
            store,
            settings,
        }
    }

    pub fn upload_slot(&self) -> ApiResult<OwnedSemaphorePermit> {
        self.upload_bodies
            .clone()
            .try_acquire_owned()
            .map_err(|_| ApiError::Unavailable("releases_busy"))
    }

    async fn require_project(&self, org: &OrgId, project: ProjectId) -> ApiResult<()> {
        self.control
            .query_one_raw(sql(
                "SELECT 1 AS found FROM projects WHERE id = ? AND org_id = ?",
                vec![project.0.into(), org.as_str().into()],
            ))
            .await?
            .map(|_| ())
            .ok_or(ApiError::NotFound)
    }

    async fn tenant(&self, org: &OrgId) -> ApiResult<tenant_sqlite_loco::TenantHandle> {
        crate::organization_lifecycle::active_tenant(&self.control, &self.tenants, org).await
    }

    async fn blocking<T: Send + 'static>(
        &self,
        work: impl FnOnce() -> T + Send + 'static,
    ) -> ApiResult<T> {
        let wait = Duration::from_millis(self.settings.parse_wait_ms);
        let permit = tokio::time::timeout(wait, self.parse.clone().acquire_owned())
            .await
            .map_err(|_| ApiError::Unavailable("releases_busy"))?
            .map_err(|_| ApiError::Unavailable("releases_busy"))?;
        tokio::task::spawn_blocking(move || {
            let _permit = permit;
            work()
        })
        .await
        .map_err(|_| ApiError::Internal("source map task".into()))
    }

    /// Validates, scrubs and stores one source map. The R2 object key is
    /// generated, never derived from the request, and is never overwritten.
    pub async fn upload(&self, access: &OrgAccess, request: UploadRequest) -> ApiResult<Uploaded> {
        access.require_manage()?;
        let target = target(&request)?;
        if request.body.len() > self.settings.max_artifact_bytes {
            return Err(ApiError::TooLarge);
        }
        self.require_project(&access.org, target.project).await?;
        let settings = self.settings.clone();
        let body = request.body;
        let prepared = self
            .blocking(move || prepare(&body, &settings))
            .await?
            .map_err(|rejected| match rejected {
                MapRejected::Invalid => ApiError::BadRequest("invalid_source_map"),
                MapRejected::Unsupported => ApiError::BadRequest("unsupported_source_map"),
                MapRejected::TooLarge => ApiError::TooLarge,
            })?;
        let debug_id = match (&target.debug_id, &prepared.debug_id) {
            (Some(given), Some(embedded)) if given != embedded => {
                return Err(ApiError::BadRequest("debug_id_mismatch"))
            }
            (Some(id), _) | (None, Some(id)) => Some(id.clone()),
            (None, None) => None,
        };
        if target.release.is_none() && debug_id.is_none() {
            return Err(ApiError::BadRequest("release_or_debug_id_required"));
        }

        {
            let handle = self.tenant(&access.org).await?;
            if let Some(existing) = existing_target(&*handle, &target, debug_id.as_deref()).await? {
                return reuse(existing, &prepared.sha256, &target, debug_id.as_deref());
            }
        }

        let id = ArtifactId::generate();
        let key = object_key(&access.org, target.project, &id);
        let stored_bytes = prepared.compressed.len() as i64;
        let _pending = self.store.pending(&key);
        self.store
            .put(&key, prepared.compressed.into())
            .await
            .map_err(|_| ApiError::Unavailable("store_unavailable"))?;

        let artifact = Artifact {
            id: id.clone(),
            project_id: target.project,
            release: target.release.clone(),
            dist: (!target.dist.is_empty()).then(|| target.dist.clone()),
            name: target.name.clone(),
            debug_id: debug_id.clone(),
            sha256: prepared.sha256.clone(),
            size: prepared.json.len() as i64,
            stored_bytes,
            uploaded_by: access.user,
            created_at: now_micros(),
        };
        let recorded = self.record(&access.org, &target, &artifact, &key).await;
        match recorded {
            Ok(None) => Ok(Uploaded {
                artifact,
                created: true,
            }),
            Ok(Some(existing)) => {
                self.discard(&access.org, &key).await;
                reuse(existing, &prepared.sha256, &target, debug_id.as_deref())
            }
            Err(error) => {
                self.discard(&access.org, &key).await;
                Err(error)
            }
        }
    }

    async fn record(
        &self,
        org: &OrgId,
        target: &Target,
        artifact: &Artifact,
        key: &str,
    ) -> ApiResult<Option<Artifact>> {
        let handle = self.tenant(org).await?;
        let txn = handle
            .begin_with_options(TransactionOptions {
                sqlite_transaction_mode: Some(SqliteTransactionMode::Immediate),
                ..TransactionOptions::default()
            })
            .await?;
        if let Some(existing) = existing_target(&txn, target, artifact.debug_id.as_deref()).await? {
            txn.rollback().await?;
            return Ok(Some(existing));
        }
        let count = txn
            .query_one_raw(sql(
                "SELECT COUNT(*) AS n FROM release_artifacts WHERE project_id = ?",
                vec![target.project.0.into()],
            ))
            .await?
            .ok_or(ApiError::Internal("artifact count".into()))?;
        let count: i64 = count.try_get("", "n")?;
        if count as u64 >= self.settings.max_artifacts_per_project {
            txn.rollback().await?;
            return Err(ApiError::Conflict("artifact_limit"));
        }
        txn.execute_raw(sql(
            "INSERT INTO release_artifacts (id, project_id, release, dist, name, debug_id, sha256,
                object_key, raw_bytes, stored_bytes, uploaded_by, created_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            vec![
                artifact.id.as_str().into(),
                artifact.project_id.0.into(),
                artifact.release.clone().into(),
                target.dist.clone().into(),
                artifact.name.clone().into(),
                artifact.debug_id.clone().into(),
                artifact.sha256.clone().into(),
                key.into(),
                artifact.size.into(),
                artifact.stored_bytes.into(),
                artifact.uploaded_by.0.into(),
                artifact.created_at.into(),
            ],
        ))
        .await?;
        txn.commit().await?;
        Ok(None)
    }

    async fn discard(&self, org: &OrgId, key: &str) {
        crate::orphan_retention::discard(
            &self.control,
            &self.tenants,
            &self.store,
            org,
            crate::orphan_retention::ObjectKind::Release,
            key,
        )
        .await;
    }

    pub async fn get(&self, access: &OrgAccess, id: &ArtifactId) -> ApiResult<Artifact> {
        let handle = self.tenant(&access.org).await?;
        let row = handle
            .query_one_raw(sql(
                &format!("SELECT {ARTIFACT_COLUMNS} FROM release_artifacts WHERE id = ?"),
                vec![id.as_str().into()],
            ))
            .await?
            .ok_or(ApiError::NotFound)?;
        Ok(artifact_row(&row)?)
    }

    pub async fn delete(&self, access: &OrgAccess, id: &ArtifactId) -> ApiResult<()> {
        access.require_manage()?;
        let artifact = self.get(access, id).await?;
        let key = object_key(&access.org, artifact.project_id, id);
        self.store
            .delete(&key)
            .await
            .map_err(|_| ApiError::Unavailable("store_unavailable"))?;
        let handle = self.tenant(&access.org).await?;
        handle
            .execute_raw(sql(
                "DELETE FROM release_artifacts WHERE id = ?",
                vec![id.as_str().into()],
            ))
            .await?;
        self.cache.lock().expect("map cache").remove(id);
        Ok(())
    }

    /// Newest first. `next` is the `before` value for the following page.
    pub async fn list(
        &self,
        access: &OrgAccess,
        project: ProjectId,
        query: ArtifactQuery,
    ) -> ApiResult<ArtifactPage> {
        self.require_project(&access.org, project).await?;
        let limit = query.limit.unwrap_or(50).clamp(1, MAX_PAGE);
        let release = match query.release.as_deref() {
            Some(raw) => Some(
                release_text(raw.trim(), MAX_RELEASE_BYTES)
                    .ok_or(ApiError::BadRequest("invalid_release"))?,
            ),
            None => None,
        };
        let dist = match query.dist.as_deref() {
            Some(raw) => Some(
                release_text(raw.trim(), MAX_DIST_BYTES)
                    .ok_or(ApiError::BadRequest("invalid_dist"))?,
            ),
            None => None,
        };
        let before = query.before.as_ref().map(ArtifactId::as_str);
        let handle = self.tenant(&access.org).await?;
        let rows = handle
            .query_all_raw(sql(
                &format!(
                    "SELECT {ARTIFACT_COLUMNS} FROM release_artifacts
                     WHERE project_id = ? AND (? IS NULL OR release = ?) AND (? IS NULL OR dist = ?)
                       AND (? IS NULL OR id < ?)
                     ORDER BY id DESC LIMIT ?"
                ),
                vec![
                    project.0.into(),
                    release.clone().into(),
                    release.into(),
                    dist.clone().into(),
                    dist.into(),
                    before.into(),
                    before.into(),
                    i64::from(limit + 1).into(),
                ],
            ))
            .await?;
        drop(handle);
        let mut artifacts: Vec<Artifact> =
            rows.iter().map(artifact_row).collect::<Result<_, _>>()?;
        let next = (artifacts.len() > limit as usize).then(|| {
            artifacts.truncate(limit as usize);
            artifacts.last().map(|a| a.id.clone())
        });
        Ok(ArtifactPage {
            artifacts,
            next: next.flatten(),
        })
    }

    /// Releases of a project that have source maps, most recent upload first.
    pub async fn releases(
        &self,
        access: &OrgAccess,
        project: ProjectId,
        limit: Option<u32>,
    ) -> ApiResult<Vec<ReleaseSummary>> {
        self.require_project(&access.org, project).await?;
        let limit = limit.unwrap_or(50).clamp(1, MAX_PAGE);
        let handle = self.tenant(&access.org).await?;
        let rows = handle
            .query_all_raw(sql(
                "SELECT release, dist, COUNT(*) AS artifact_count, MAX(created_at) AS last_uploaded
                 FROM release_artifacts WHERE project_id = ? AND release IS NOT NULL
                 GROUP BY release, dist ORDER BY last_uploaded DESC LIMIT ?",
                vec![project.0.into(), i64::from(limit).into()],
            ))
            .await?;
        drop(handle);
        rows.iter()
            .map(|row| {
                let dist: String = row.try_get("", "dist")?;
                Ok(ReleaseSummary {
                    release: row.try_get("", "release")?,
                    dist: (!dist.is_empty()).then_some(dist),
                    artifact_count: row.try_get("", "artifact_count")?,
                    last_uploaded: row.try_get("", "last_uploaded")?,
                })
            })
            .collect()
    }

    /// Maps the JavaScript frames of a stored, scrubbed event payload to
    /// original positions. `project` is the event's project. Frames that
    /// cannot be mapped are returned unchanged with the reason in `status`.
    /// Remote source maps are never fetched.
    pub async fn symbolicate(
        &self,
        access: &OrgAccess,
        project: ProjectId,
        payload: &Value,
    ) -> ApiResult<Symbolicated> {
        self.require_project(&access.org, project).await?;
        let _operation = tokio::time::timeout(
            Duration::from_millis(self.settings.parse_wait_ms),
            self.symbolications.clone().acquire_owned(),
        )
        .await
        .map_err(|_| ApiError::Unavailable("releases_busy"))?
        .map_err(|_| ApiError::Unavailable("releases_busy"))?;
        let deadline =
            Instant::now() + Duration::from_millis(self.settings.symbolicate_deadline_ms);
        let event = EventFrames::read(payload, self.settings.max_frames);
        let files = event.files(self.settings.max_files_per_event);
        let resolved = if files.is_empty() {
            HashMap::new()
        } else {
            let handle = self.tenant(&access.org).await?;
            resolve(&*handle, project, &event, &files).await?
        };

        let mut wanted: Vec<Candidate> = Vec::new();
        for candidate in resolved.values() {
            if !wanted.iter().any(|c| c.id == candidate.id) {
                wanted.push(candidate.clone());
            }
        }
        wanted.sort_by(|a, b| a.id.cmp(&b.id));
        let over_budget: Vec<ArtifactId> = wanted
            .iter()
            .skip(self.settings.max_maps_per_event)
            .map(|c| c.id.clone())
            .collect();
        wanted.truncate(self.settings.max_maps_per_event);
        let maps: HashMap<ArtifactId, Result<Arc<SourceMap>, FrameStatus>> = stream::iter(wanted)
            .map(|candidate| async move {
                let loaded = if Instant::now() >= deadline {
                    Err(FrameStatus::DeadlineExceeded)
                } else {
                    tokio::time::timeout_at(deadline, self.load(&access.org, &candidate))
                        .await
                        .unwrap_or(Err(FrameStatus::DeadlineExceeded))
                };
                (candidate.id.clone(), loaded)
            })
            .buffer_unordered(READ_CONCURRENCY)
            .collect()
            .await;

        Ok(event.symbolicate(&self.settings, &files, &resolved, &maps, &over_budget))
    }

    async fn load(
        &self,
        org: &OrgId,
        candidate: &Candidate,
    ) -> Result<Arc<SourceMap>, FrameStatus> {
        if let Some(map) = self.cache.lock().expect("map cache").get(&candidate.id) {
            return Ok(map);
        }
        let expected = format!("releases/v1/{org}/");
        if !candidate.object_key.starts_with(&expected) {
            return Err(FrameStatus::ArtifactUnavailable);
        }
        let stored = usize::try_from(candidate.stored_bytes).unwrap_or(usize::MAX);
        let max_stored = self
            .settings
            .max_artifact_bytes
            .saturating_add(self.settings.max_artifact_bytes / 128)
            .saturating_add(1_024);
        let body = self
            .store
            .get(&candidate.object_key, stored.min(max_stored))
            .await
            .map_err(|_| FrameStatus::ArtifactUnavailable)?
            .ok_or(FrameStatus::ArtifactUnavailable)?;
        let max = self.settings.max_artifact_bytes;
        let sha256 = candidate.sha256.clone();
        let parsed = self
            .blocking(move || -> Result<(SourceMap, usize), FrameStatus> {
                let mut json = Vec::new();
                std::io::Read::read_to_end(
                    &mut std::io::Read::take(
                        zstd::stream::read::Decoder::new(&body[..])
                            .map_err(|_| FrameStatus::MalformedArtifact)?,
                        max as u64 + 1,
                    ),
                    &mut json,
                )
                .map_err(|_| FrameStatus::MalformedArtifact)?;
                if json.len() > max || hex::encode(Sha256::digest(&json)) != sha256 {
                    return Err(FrameStatus::MalformedArtifact);
                }
                let map =
                    SourceMap::from_slice(&json).map_err(|_| FrameStatus::MalformedArtifact)?;
                let weight = map_weight(&map, json.len());
                Ok((map, weight))
            })
            .await
            .map_err(|_| FrameStatus::ArtifactUnavailable)??;
        let (map, size) = parsed;
        let map = Arc::new(map);
        self.cache.lock().expect("map cache").insert(
            candidate.id.clone(),
            map.clone(),
            size,
            self.settings.cache_bytes,
        );
        Ok(map)
    }
}

#[derive(Default)]
struct MapCache {
    entries: HashMap<ArtifactId, (Arc<SourceMap>, usize)>,
    order: VecDeque<ArtifactId>,
    bytes: usize,
}

impl MapCache {
    fn remove(&mut self, id: &ArtifactId) {
        if let Some((_, size)) = self.entries.remove(id) {
            self.bytes -= size;
            self.order.retain(|entry| entry != id);
        }
    }
    fn get(&self, id: &ArtifactId) -> Option<Arc<SourceMap>> {
        self.entries.get(id).map(|(map, _)| map.clone())
    }

    fn insert(&mut self, id: ArtifactId, map: Arc<SourceMap>, size: usize, limit: usize) {
        if size > limit || self.entries.contains_key(&id) {
            return;
        }
        while self.bytes + size > limit {
            let Some(old) = self.order.pop_front() else {
                break;
            };
            if let Some((_, old_size)) = self.entries.remove(&old) {
                self.bytes -= old_size;
            }
        }
        self.bytes += size;
        self.order.push_back(id.clone());
        self.entries.insert(id, (map, size));
    }
}

fn map_weight(map: &SourceMap, json_bytes: usize) -> usize {
    let tokens = map.get_token_count() as usize;
    let strings = (map.get_source_count() as usize).saturating_add(map.get_name_count() as usize);
    json_bytes
        .saturating_mul(20)
        .saturating_add(tokens.saturating_mul(std::mem::size_of::<sourcemap::RawToken>() * 2))
        .saturating_add(strings.saturating_mul(128))
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum FrameStatus {
    Symbolicated,
    /// No uploaded map matches the frame's debug ID, release or file.
    MissingArtifact,
    /// The map does not cover the frame's line and column.
    NoMapping,
    /// The frame has no file, line or column to map.
    NotApplicable,
    ArtifactUnavailable,
    MalformedArtifact,
    DeadlineExceeded,
    /// Beyond the per-event frame, file or map budget.
    Skipped,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum MatchedBy {
    DebugId,
    Url,
    Basename,
}

#[derive(Debug, Serialize)]
pub struct RawFrame {
    pub function: Option<String>,
    pub file: Option<String>,
    pub lineno: Option<u32>,
    pub colno: Option<u32>,
}

#[derive(Debug, Serialize)]
pub struct OriginalFrame {
    pub function: Option<String>,
    pub file: String,
    pub lineno: u32,
    pub colno: u32,
    pub in_app: bool,
    pub pre_context: Vec<String>,
    pub context_line: Option<String>,
    pub post_context: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct SymbolicatedFrame {
    pub status: FrameStatus,
    pub matched_by: Option<MatchedBy>,
    pub artifact_id: Option<ArtifactId>,
    pub raw: RawFrame,
    pub original: Option<OriginalFrame>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum StackOrigin {
    Exception,
    Thread,
}

/// Frames are oldest call first, as SDKs send them.
#[derive(Debug, Serialize)]
pub struct Stack {
    pub origin: StackOrigin,
    pub kind: Option<String>,
    pub value: Option<String>,
    pub frames: Vec<SymbolicatedFrame>,
}

#[derive(Debug, Serialize)]
pub struct Symbolicated {
    pub release: Option<String>,
    pub dist: Option<String>,
    pub stacks: Vec<Stack>,
    pub frames_truncated: bool,
}

struct InputFrame {
    function: Option<String>,
    file: Option<String>,
    lineno: Option<u32>,
    colno: Option<u32>,
}

struct InputStack {
    origin: StackOrigin,
    kind: Option<String>,
    value: Option<String>,
    frames: Vec<InputFrame>,
}

struct EventFrames {
    release: Option<String>,
    dist: String,
    debug_ids: HashMap<String, String>,
    stacks: Vec<InputStack>,
    truncated: bool,
}

fn text(value: Option<&Value>, max: usize) -> Option<String> {
    value.and_then(Value::as_str).map(|s| clip(s, max))
}

fn position(value: Option<&Value>) -> Option<u32> {
    value
        .and_then(Value::as_u64)
        .and_then(|n| u32::try_from(n).ok())
        .filter(|n| *n >= 1)
}

impl EventFrames {
    fn read(payload: &Value, max_frames: usize) -> Self {
        let mut budget = max_frames;
        let mut truncated = false;
        let mut stacks = Vec::new();
        let mut take = |origin: StackOrigin, item: &Value| {
            let frames = interfaces::frames(item);
            if frames.is_empty() {
                return;
            }
            let keep = frames.len().min(budget);
            truncated |= keep < frames.len();
            budget -= keep;
            stacks.push(InputStack {
                origin,
                kind: text(item.get("type"), 1_024),
                value: text(item.get("value"), 1_024),
                frames: frames[frames.len() - keep..]
                    .iter()
                    .map(|frame| InputFrame {
                        function: text(frame.get("function"), 1_024),
                        file: text(frame.get("abs_path"), MAX_NAME_BYTES * 2)
                            .or_else(|| text(frame.get("filename"), MAX_NAME_BYTES * 2)),
                        lineno: position(frame.get("lineno")),
                        colno: position(frame.get("colno")),
                    })
                    .collect(),
            });
        };
        for exception in interfaces::values(payload, "exception") {
            take(StackOrigin::Exception, exception);
        }
        for thread in interfaces::values(payload, "threads") {
            take(StackOrigin::Thread, thread);
        }
        let debug_ids = payload
            .pointer("/debug_meta/images")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .take(MAX_DEBUG_IMAGES)
            .filter(|image| image.get("type").and_then(Value::as_str) == Some("sourcemap"))
            .filter_map(|image| {
                let file = image.get("code_file")?.as_str()?;
                let id = debug_id(image.get("debug_id")?.as_str()?)?;
                Some((file.to_owned(), id))
            })
            .collect();
        Self {
            release: payload
                .get("release")
                .and_then(Value::as_str)
                .and_then(|r| release_text(r, MAX_RELEASE_BYTES)),
            dist: payload
                .get("dist")
                .and_then(Value::as_str)
                .and_then(|d| release_text(d, MAX_DIST_BYTES))
                .unwrap_or_default(),
            debug_ids,
            stacks,
            truncated,
        }
    }

    fn files(&self, max: usize) -> Vec<String> {
        let mut files: Vec<String> = Vec::new();
        for frame in self.stacks.iter().flat_map(|s| &s.frames) {
            let (Some(file), Some(_), Some(_)) = (&frame.file, frame.lineno, frame.colno) else {
                continue;
            };
            if !mappable(file) {
                continue;
            }
            if files.len() == max {
                break;
            }
            if !files.contains(file) {
                files.push(file.clone());
            }
        }
        files
    }

    fn symbolicate(
        self,
        settings: &ReleaseSettings,
        files: &[String],
        resolved: &HashMap<String, Candidate>,
        maps: &HashMap<ArtifactId, Result<Arc<SourceMap>, FrameStatus>>,
        over_budget: &[ArtifactId],
    ) -> Symbolicated {
        let stacks = self
            .stacks
            .into_iter()
            .map(|stack| {
                let mut frames: Vec<SymbolicatedFrame> = Vec::with_capacity(stack.frames.len());
                let mut caller_name: Option<String> = None;
                for input in stack.frames {
                    let mut out = SymbolicatedFrame {
                        status: FrameStatus::NotApplicable,
                        matched_by: None,
                        artifact_id: None,
                        raw: RawFrame {
                            function: input.function,
                            file: input.file,
                            lineno: input.lineno,
                            colno: input.colno,
                        },
                        original: None,
                    };
                    let mut this_name = None;
                    if let (Some(file), Some(line), Some(col)) =
                        (&out.raw.file, out.raw.lineno, out.raw.colno)
                    {
                        if !mappable(file) {
                            out.status = FrameStatus::NotApplicable;
                        } else if !files.contains(file) {
                            out.status = FrameStatus::Skipped;
                        } else if let Some(candidate) = resolved.get(file) {
                            out.matched_by = Some(candidate.matched_by);
                            out.artifact_id = Some(candidate.id.clone());
                            out.status = if over_budget.contains(&candidate.id) {
                                FrameStatus::Skipped
                            } else {
                                match maps.get(&candidate.id) {
                                    Some(Ok(map)) => match original(settings, map, line, col) {
                                        Some((original, name)) => {
                                            out.original = Some(original);
                                            this_name = name;
                                            FrameStatus::Symbolicated
                                        }
                                        None => FrameStatus::NoMapping,
                                    },
                                    Some(Err(status)) => *status,
                                    None => FrameStatus::DeadlineExceeded,
                                }
                            };
                        } else {
                            out.status = FrameStatus::MissingArtifact;
                        }
                    }
                    if let Some(original) = &mut out.original {
                        original.function = caller_name.take().or_else(|| out.raw.function.clone());
                    }
                    caller_name = this_name;
                    frames.push(out);
                }
                Stack {
                    origin: stack.origin,
                    kind: stack.kind,
                    value: stack.value,
                    frames,
                }
            })
            .collect();
        Symbolicated {
            release: self.release,
            dist: (!self.dist.is_empty()).then_some(self.dist),
            stacks,
            frames_truncated: self.truncated,
        }
    }
}

fn original(
    settings: &ReleaseSettings,
    map: &SourceMap,
    line: u32,
    col: u32,
) -> Option<(OriginalFrame, Option<String>)> {
    let token = map.lookup_token(line - 1, col - 1)?;
    if token.get_dst_line() != line - 1 || !token.has_source() {
        return None;
    }
    let file = token.get_source()?.to_owned();
    let src_line = token.get_src_line();
    let width = settings.max_context_line_chars;
    let view = map.get_source_view(token.get_src_id());
    let line_at = |n: u32| view.and_then(|v| v.get_line(n)).map(|l| clip(l, width));
    let context = settings.context_lines;
    let pre_context = (src_line.saturating_sub(context)..src_line)
        .filter_map(line_at)
        .collect();
    let post_context = (src_line + 1..=src_line.saturating_add(context))
        .map_while(line_at)
        .collect();
    Some((
        OriginalFrame {
            function: None,
            in_app: !file.contains("/node_modules/"),
            file,
            lineno: src_line + 1,
            colno: token.get_src_col() + 1,
            context_line: line_at(src_line),
            pre_context,
            post_context,
        },
        token.get_name().map(str::to_owned),
    ))
}

#[derive(Clone)]
struct Candidate {
    id: ArtifactId,
    object_key: String,
    stored_bytes: i64,
    sha256: String,
    matched_by: MatchedBy,
}

fn candidate(
    row: &sea_orm::QueryResult,
    matched_by: MatchedBy,
) -> Result<Candidate, sea_orm::DbErr> {
    let id: String = row.try_get("", "id")?;
    Ok(Candidate {
        id: id
            .parse()
            .map_err(|()| sea_orm::DbErr::Custom("stored artifact id".into()))?,
        object_key: row.try_get("", "object_key")?,
        stored_bytes: row.try_get("", "stored_bytes")?,
        sha256: row.try_get("", "sha256")?,
        matched_by,
    })
}

fn like_suffix(name: &str) -> String {
    let mut pattern = String::from("%/");
    for c in name.chars() {
        if matches!(c, '%' | '_' | '\\') {
            pattern.push('\\');
        }
        pattern.push(c);
    }
    pattern
}

async fn resolve<C: ConnectionTrait>(
    conn: &C,
    project: ProjectId,
    event: &EventFrames,
    files: &[String],
) -> ApiResult<HashMap<String, Candidate>> {
    const COLUMNS: &str = "id, object_key, stored_bytes, sha256";
    let mut resolved = HashMap::new();
    for file in files {
        if let Some(id) = event.debug_ids.get(file) {
            let row = conn
                .query_one_raw(sql(
                    &format!("SELECT {COLUMNS} FROM release_artifacts WHERE project_id = ? AND debug_id = ?"),
                    vec![project.0.into(), id.clone().into()],
                ))
                .await?;
            if let Some(row) = row {
                resolved.insert(file.clone(), candidate(&row, MatchedBy::DebugId)?);
                continue;
            }
        }
        let (Some(release), Some(name)) = (&event.release, artifact_name(file)) else {
            continue;
        };
        let exact = conn
            .query_one_raw(sql(
                &format!(
                    "SELECT {COLUMNS} FROM release_artifacts
                     WHERE project_id = ? AND release = ? AND dist = ? AND name = ?"
                ),
                vec![
                    project.0.into(),
                    release.clone().into(),
                    event.dist.clone().into(),
                    name.clone().into(),
                ],
            ))
            .await?;
        if let Some(row) = exact {
            resolved.insert(file.clone(), candidate(&row, MatchedBy::Url)?);
            continue;
        }
        let rows = conn
            .query_all_raw(sql(
                &format!(
                    "SELECT {COLUMNS} FROM release_artifacts
                     WHERE project_id = ? AND release = ? AND dist = ? AND name LIKE ? ESCAPE '\\' LIMIT 2"
                ),
                vec![
                    project.0.into(),
                    release.clone().into(),
                    event.dist.clone().into(),
                    like_suffix(basename(&name)).into(),
                ],
            ))
            .await?;
        if let [row] = rows.as_slice() {
            resolved.insert(file.clone(), candidate(row, MatchedBy::Basename)?);
        }
    }
    Ok(resolved)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn artifact_names_drop_origin_query_and_reject_traversal() {
        assert_eq!(
            artifact_name("https://cdn.example.com/assets/app-1a2b.js?v=3#x").as_deref(),
            Some("~/assets/app-1a2b.js")
        );
        assert_eq!(
            artifact_name("~/assets/app.js").as_deref(),
            Some("~/assets/app.js")
        );
        assert_eq!(
            artifact_name("/srv/app/dist/app.js").as_deref(),
            Some("~/srv/app/dist/app.js")
        );
        assert_eq!(
            artifact_name("app:///dist/app.js").as_deref(),
            Some("~/dist/app.js")
        );
        assert_eq!(artifact_name("assets/../secret.js"), None);
        assert_eq!(artifact_name("https://host"), None);
        assert_eq!(artifact_name("a\\b.js"), None);
        assert_eq!(artifact_name("~/a//b.js"), None);
        assert_eq!(artifact_name(&"a".repeat(513)), None);
    }

    #[test]
    fn release_rules_follow_sentry() {
        assert_eq!(
            release_text("web@1.2.3+abc", 200).as_deref(),
            Some("web@1.2.3+abc")
        );
        for bad in ["", ".", "..", " ", "a/b", "a\\b", "a\nb", "a\tb"] {
            assert_eq!(release_text(bad, 200), None, "{bad:?}");
        }
    }

    #[test]
    fn scrubbing_keeps_line_count_and_mappings() {
        let body = serde_json::json!({
            "version": 3,
            "sources": ["src/a.ts"],
            "sourcesContent": ["const a = 1;\r\nconst key = 'x';\rheaders.Authorization = `Bearer abcdefghijklmnop`;\nend();"],
            "names": ["a"],
            "mappings": "AAAA,MAAMA;AACN",
            "x_unknown": "dropped"
        });
        let prepared = prepare(
            &serde_json::to_vec(&body).unwrap(),
            &ReleaseSettings::default(),
        )
        .unwrap();
        let stored: Value = serde_json::from_slice(&prepared.json).unwrap();
        assert_eq!(stored["mappings"], "AAAA,MAAMA;AACN");
        assert_eq!(stored["names"], serde_json::json!(["a"]));
        assert_eq!(stored.get("x_unknown"), None);
        let content = stored["sourcesContent"][0].as_str().unwrap();
        assert_eq!(content.matches(['\n', '\r']).count(), 4);
        assert_eq!(
            content,
            "const a = 1;\r\nconst key = 'x';\rheaders.Authorization = `[Filtered]`;\nend();"
        );
        assert!(!content.contains("abcdefghijklmnop"), "{content}");
    }

    #[test]
    fn rejects_index_maps_wrong_versions_and_oversize() {
        let settings = ReleaseSettings {
            max_artifact_bytes: 256,
            ..ReleaseSettings::default()
        };
        let index = br#"{"version":3,"sections":[],"sources":[],"mappings":""}"#;
        assert_eq!(
            prepare(index, &settings).err(),
            Some(MapRejected::Unsupported)
        );
        let v2 = br#"{"version":2,"sources":[],"mappings":""}"#;
        assert_eq!(prepare(v2, &settings).err(), Some(MapRejected::Invalid));
        assert_eq!(
            prepare(b"not json", &settings).err(),
            Some(MapRejected::Invalid)
        );
        let big = format!(
            r#"{{"version":3,"sources":[],"mappings":"{}"}}"#,
            "A".repeat(300)
        );
        assert_eq!(
            prepare(big.as_bytes(), &settings).err(),
            Some(MapRejected::TooLarge)
        );
        let bad_vlq = br#"{"version":3,"sources":["a.js"],"mappings":"!!!!"}"#;
        assert_eq!(
            prepare(bad_vlq, &settings).err(),
            Some(MapRejected::Invalid)
        );
    }

    #[test]
    fn cache_evicts_oldest_within_the_byte_limit() {
        let map = Arc::new(
            SourceMap::from_slice(br#"{"version":3,"sources":[],"names":[],"mappings":""}"#)
                .unwrap(),
        );
        let id = |n: u8| ArtifactId(format!("a{:032x}", n));
        let mut cache = MapCache::default();
        cache.insert(id(1), map.clone(), 40, 100);
        cache.insert(id(2), map.clone(), 40, 100);
        cache.insert(id(3), map.clone(), 40, 100);
        cache.insert(id(4), map, 200, 100);
        assert!(cache.get(&id(1)).is_none());
        assert!(cache.get(&id(2)).is_some() && cache.get(&id(3)).is_some());
        assert!(cache.get(&id(4)).is_none());
        assert_eq!(cache.bytes, 80);
    }
}
