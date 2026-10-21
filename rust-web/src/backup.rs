//! Encrypted SQLite backup objects of the control database and organization databases.
//!
//! Object layout: `MAGIC || VERSION || nonce || AES-256-GCM(zstd(snapshot)) || tag`.
//! The associated data binds purpose, format version, scope and object key, so an
//! object decrypts only as the database and key it was written for.
//!
//! One worker exists per process. A member attempt owns the worker lease until
//! the attempt task and its blocking seal both end, so a timeout or a cancelled
//! caller never lets a second snapshot or seal overlap the first.

use std::{
    fs::{self, File, OpenOptions},
    io::{self, Read, Write},
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};

use aes_gcm::{
    aead::{AeadCore, AeadInPlace, KeyInit, OsRng},
    Aes256Gcm, Nonce, Tag,
};
use base64::Engine as _;
use bytes::Bytes;
use credseal::SecretString;
use sea_orm::{
    sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions},
    ConnectionTrait, DatabaseBackend, DatabaseConnection, SqlxSqliteConnector, Statement,
};
use sha2::{Digest, Sha256};
use tenant_sqlite_loco::TenantPools;
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use tokio_util::sync::CancellationToken;
use zeroize::Zeroizing;

use crate::{
    domain::OrgId,
    store::{Created, Faults, ObjectStore, StoreError},
};

const MAGIC: &[u8; 8] = b"PDBACKUP";
const VERSION: u8 = 1;
const NONCE_LEN: usize = 12;
const TAG_LEN: usize = 16;
const HEADER_LEN: usize = MAGIC.len() + 1 + NONCE_LEN;
const PURPOSE: &[u8] = b"postdeploy-sqlite-backup";
const COMPRESSION_LEVEL: i32 = 3;
/// Caps the zstd decoder window at 8 MiB. Level 3 never needs more.
const WINDOW_LOG_MAX: u32 = 23;

/// What a backup object holds. Part of the authenticated data.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Scope {
    Control,
    Organization(OrgId),
    Manifest,
}

impl Scope {
    fn label(&self) -> String {
        match self {
            Self::Control => "control".to_owned(),
            Self::Organization(org) => format!("org/{org}"),
            Self::Manifest => "manifest".to_owned(),
        }
    }
}

/// A live database to snapshot. Organization snapshots lease the tenant through
/// the installed registry and release it before encryption and object I/O.
#[derive(Clone)]
pub enum Source {
    Control(DatabaseConnection),
    Organization { pools: TenantPools, org: OrgId },
}

impl Source {
    pub fn scope(&self) -> Scope {
        match self {
            Self::Control(_) => Scope::Control,
            Self::Organization { org, .. } => Scope::Organization(org.clone()),
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub struct Limits {
    /// Largest snapshot written, uploaded, or restored.
    pub max_snapshot_bytes: u64,
    /// Largest sealed object uploaded or downloaded.
    pub max_object_bytes: usize,
    /// Wall-clock budget for one member backup or restore, including object I/O.
    pub deadline: Duration,
    /// Scratch directories allowed at once: the running attempt plus the newest failures kept for diagnosis.
    pub max_scratch_dirs: usize,
    /// Age after which a failed attempt's scratch directory is deleted.
    pub retain_failures: Duration,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Backup {
    pub scope: Scope,
    pub key: String,
    /// Time just before the snapshot read began. Commits after it may or may not be in it.
    pub captured_at_us: i64,
    pub snapshot_bytes: u64,
    pub object_bytes: u64,
    pub snapshot_sha256: String,
    pub object_sha256: String,
}

#[derive(Debug, PartialEq, Eq)]
pub struct Restored {
    pub path: PathBuf,
    pub snapshot_bytes: u64,
    pub snapshot_sha256: String,
    pub object_sha256: String,
}

#[derive(Debug, thiserror::Error)]
pub enum BackupError {
    #[error("backup data key must be Base64 of 32 bytes")]
    InvalidKey,
    #[error("backup scratch {0} must be an existing UTF-8 directory path, not a symlink")]
    UnsafeScratch(PathBuf),
    #[error("snapshot exceeds {0} bytes")]
    SnapshotTooLarge(u64),
    #[error("backup object exceeds {0} bytes")]
    ObjectTooLarge(usize),
    #[error("backup object {0} not found")]
    Missing(String),
    #[error("backup object {0} already exists")]
    Exists(String),
    #[error("backup object is malformed")]
    Malformed,
    #[error("backup object failed authentication")]
    Authentication,
    #[error("restore destination {0} already exists")]
    DestinationExists(PathBuf),
    #[error("restored database is invalid: {0}")]
    Invalid(String),
    #[error("backup operation timed out")]
    Timeout,
    #[error("a previous backup attempt still holds the backup worker")]
    Busy,
    #[error("backup worker failed")]
    Worker,
    #[error("organization {org}: {detail}")]
    Organization { org: OrgId, detail: String },
    #[error("tenant: {0}")]
    Tenant(#[from] tenant_sqlite_loco::Error),
    #[error("database: {0}")]
    Database(#[from] sea_orm::DbErr),
    #[error("object store: {0}")]
    Store(StoreError),
    #[error("{path}: {source}")]
    Io { path: PathBuf, source: io::Error },
}

impl From<StoreError> for BackupError {
    fn from(error: StoreError) -> Self {
        match error {
            StoreError::TooLarge(limit) => Self::ObjectTooLarge(limit),
            other => Self::Store(other),
        }
    }
}

/// Exclusive right to run backup attempts. Clones of the permit travel with
/// the attempt task and its blocking seal, so a lease with a live clone has an
/// attempt in flight and refuses to start another.
pub struct Worker(Arc<OwnedSemaphorePermit>);

pub struct Backups {
    scratch: PathBuf,
    limits: Limits,
    cipher: Aes256Gcm,
    worker: Arc<Semaphore>,
}

impl std::fmt::Debug for Backups {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Backups")
            .field("scratch", &self.scratch)
            .field("limits", &self.limits)
            .finish_non_exhaustive()
    }
}

impl Backups {
    pub fn new(
        scratch: impl Into<PathBuf>,
        limits: Limits,
        data_key: &SecretString,
    ) -> Result<Self, BackupError> {
        let scratch = scratch.into();
        check_scratch(&scratch)?;
        Ok(Self {
            scratch,
            limits,
            cipher: cipher(data_key)?,
            worker: Arc::new(Semaphore::new(1)),
        })
    }

    pub fn limits(&self) -> Limits {
        self.limits
    }

    pub fn scratch_root(&self) -> &Path {
        &self.scratch
    }

    /// Takes the single backup worker, or reports `Busy` while an earlier
    /// attempt, including one that timed out, is still running.
    pub fn lease(&self) -> Result<Worker, BackupError> {
        self.worker
            .clone()
            .try_acquire_owned()
            .map(|permit| Worker(Arc::new(permit)))
            .map_err(|_| BackupError::Busy)
    }

    pub async fn idle(&self) {
        drop(self.worker.acquire().await);
    }

    /// Snapshots `source` with `VACUUM INTO`, then compresses, encrypts and
    /// creates the object at `key`. A cancelled attempt never starts an upload;
    /// an upload already in flight is abandoned. A failed attempt keeps its
    /// scratch directory for diagnosis until a later attempt needs the slot or
    /// it is older than `retain_failures`.
    pub async fn backup(
        &self,
        worker: &Worker,
        source: Source,
        store: &ObjectStore,
        key: String,
    ) -> Result<Backup, BackupError> {
        if Arc::strong_count(&worker.0) > 1 {
            return Err(BackupError::Busy);
        }
        let work = self.claim_scratch(&source.scope())?;
        let cancel = CancellationToken::new();
        let _cancel_when_dropped = cancel.clone().drop_guard();
        let attempt = Attempt {
            work,
            source,
            store: store.with_timeout(self.limits.deadline),
            key,
            cipher: self.cipher.clone(),
            limits: self.limits,
            permit: worker.0.clone(),
            cancel: cancel.clone(),
        };
        let mut task = tokio::spawn(attempt.run());
        let result = match tokio::time::timeout(self.limits.deadline, &mut task).await {
            Ok(joined) => joined.unwrap_or(Err(BackupError::Worker)),
            Err(_) => {
                cancel.cancel();
                Err(BackupError::Timeout)
            }
        };
        if result.is_err() {
            if let Err(error) = self.prune_scratch() {
                tracing::warn!(%error, "retained backup scratch could not be pruned");
            }
        }
        result
    }

    /// Fetches the object at `key`, authenticates it as `scope`, and writes the
    /// snapshot to `target`, a new file. A failure after the file is created
    /// leaves it for diagnosis.
    pub async fn restore(
        &self,
        store: &ObjectStore,
        scope: &Scope,
        key: &str,
        target: &Path,
    ) -> Result<Restored, BackupError> {
        if fs::symlink_metadata(target).is_ok() {
            return Err(BackupError::DestinationExists(target.to_path_buf()));
        }
        let limits = self.limits;
        let store = store.with_timeout(limits.deadline);
        let cipher = self.cipher.clone();
        tokio::time::timeout(limits.deadline, async {
            let body = store
                .get(key, limits.max_object_bytes)
                .await?
                .ok_or_else(|| BackupError::Missing(key.to_owned()))?;
            let object_sha256 = hex::encode(Sha256::digest(&body));
            let aad = associated_data(scope, key);
            let path = target.to_path_buf();
            let (snapshot_bytes, snapshot_sha256) =
                blocking(move || unseal_into(body, &cipher, &aad, &path, limits)).await?;
            Ok(Restored {
                path: target.to_path_buf(),
                snapshot_bytes,
                snapshot_sha256,
                object_sha256,
            })
        })
        .await
        .unwrap_or(Err(BackupError::Timeout))
    }

    /// Seals a small document, such as a set manifest, with the backup codec.
    pub fn seal_bytes(&self, scope: &Scope, key: &str, plain: &[u8]) -> Result<Bytes, BackupError> {
        let compressed =
            zstd::encode_all(plain, COMPRESSION_LEVEL).map_err(|source| BackupError::Io {
                path: PathBuf::from(key),
                source,
            })?;
        let nonce = Aes256Gcm::generate_nonce(&mut OsRng);
        let mut body = Vec::with_capacity(HEADER_LEN + compressed.len() + TAG_LEN);
        body.extend_from_slice(MAGIC);
        body.push(VERSION);
        body.extend_from_slice(&nonce);
        body.extend_from_slice(&compressed);
        let tag = self
            .cipher
            .encrypt_in_place_detached(
                &nonce,
                &associated_data(scope, key),
                &mut body[HEADER_LEN..],
            )
            .map_err(|_| BackupError::ObjectTooLarge(body.len()))?;
        body.extend_from_slice(&tag);
        Ok(Bytes::from(body))
    }

    /// Opens a document sealed with [`Self::seal_bytes`] for the same scope and key.
    pub fn unseal_bytes(
        &self,
        scope: &Scope,
        key: &str,
        body: Bytes,
        max_bytes: usize,
    ) -> Result<Vec<u8>, BackupError> {
        let mut body = Vec::from(body);
        let tag_at = authenticate(&mut body, &self.cipher, &associated_data(scope, key))?;
        let mut decoder = zstd::Decoder::with_buffer(&body[HEADER_LEN..tag_at])
            .map_err(|_| BackupError::Malformed)?;
        decoder
            .window_log_max(WINDOW_LOG_MAX)
            .map_err(|_| BackupError::Malformed)?;
        let mut plain = Vec::new();
        decoder
            .take(max_bytes as u64 + 1)
            .read_to_end(&mut plain)
            .map_err(|_| BackupError::Malformed)?;
        if plain.len() > max_bytes {
            return Err(BackupError::ObjectTooLarge(max_bytes));
        }
        Ok(plain)
    }

    /// Deletes the scratch directories of attempts that started at or after
    /// `since_us`. Holding an idle `worker` proves none of them is running.
    pub fn discard_scratch_since(
        &self,
        worker: &Worker,
        since_us: i64,
    ) -> Result<usize, BackupError> {
        if Arc::strong_count(&worker.0) > 1 {
            return Err(BackupError::Busy);
        }
        check_scratch(&self.scratch)?;
        let mut removed = 0;
        for dir in scratch_dirs(&self.scratch)? {
            if dir.created_at_us >= since_us {
                remove_scratch(&dir.path)?;
                removed += 1;
            }
        }
        Ok(removed)
    }

    /// Keeps the newest `max_scratch_dirs - 1` directories younger than
    /// `retain_failures`, so one slot is always free for the next attempt.
    fn prune_scratch(&self) -> Result<(), BackupError> {
        check_scratch(&self.scratch)?;
        let kept = self.limits.max_scratch_dirs.saturating_sub(1);
        let oldest_kept = crate::domain::now_micros()
            - i64::try_from(self.limits.retain_failures.as_micros()).unwrap_or(i64::MAX);
        for (newest_first, dir) in scratch_dirs(&self.scratch)?.into_iter().enumerate() {
            if newest_first >= kept || dir.created_at_us < oldest_kept {
                remove_scratch(&dir.path)?;
            }
        }
        Ok(())
    }

    fn claim_scratch(&self, scope: &Scope) -> Result<PathBuf, BackupError> {
        self.prune_scratch()?;
        let name = format!(
            "{}-{}",
            scope.label().replace('/', "-"),
            uuid::Uuid::now_v7().simple()
        );
        let dir = self.scratch.join(name);
        let mut builder = fs::DirBuilder::new();
        #[cfg(unix)]
        std::os::unix::fs::DirBuilderExt::mode(&mut builder, 0o700);
        builder.create(&dir).map_err(io_at(&dir))?;
        Ok(dir)
    }
}

/// Deletes the retained scratch directories of `org`. A running attempt for
/// the organization loses its snapshot and fails.
pub fn remove_organization_scratch(scratch: &Path, org: &OrgId) -> Result<usize, BackupError> {
    if fs::symlink_metadata(scratch).is_err() {
        return Ok(0);
    }
    check_scratch(scratch)?;
    let label = Scope::Organization(org.clone()).label().replace('/', "-");
    let mut removed = 0;
    for dir in scratch_dirs(scratch)? {
        if dir.label == label {
            remove_scratch(&dir.path)?;
            removed += 1;
        }
    }
    Ok(removed)
}

pub fn scratch_root(tenant_root: &Path) -> Option<PathBuf> {
    Some(tenant_root.parent()?.join("backup-scratch"))
}

/// A directory named `<scope label>-<UUIDv7>` by `claim_scratch`.
struct ScratchDir {
    path: PathBuf,
    label: String,
    created_at_us: i64,
}

/// Directories created by `claim_scratch`, newest first. Other entries are ignored.
fn scratch_dirs(root: &Path) -> Result<Vec<ScratchDir>, BackupError> {
    let mut dirs = Vec::new();
    for entry in fs::read_dir(root).map_err(io_at(root))? {
        let entry = entry.map_err(io_at(root))?;
        if !entry.file_type().map_err(io_at(root))?.is_dir() {
            continue;
        }
        let name = entry.file_name();
        let Some((label, id)) = name.to_str().and_then(|name| name.rsplit_once('-')) else {
            continue;
        };
        let Some(created_at_us) = uuid::Uuid::try_parse(id)
            .ok()
            .filter(|id| id.get_version_num() == 7)
            .and_then(|id| id.get_timestamp())
            .map(|ts| {
                let (secs, nanos) = ts.to_unix();
                secs as i64 * 1_000_000 + i64::from(nanos / 1_000)
            })
        else {
            continue;
        };
        dirs.push(ScratchDir {
            path: entry.path(),
            label: label.to_owned(),
            created_at_us,
        });
    }
    dirs.sort_by_key(|dir| std::cmp::Reverse(dir.created_at_us));
    Ok(dirs)
}

fn remove_scratch(path: &Path) -> Result<(), BackupError> {
    match fs::remove_dir_all(path) {
        Err(error) if error.kind() != io::ErrorKind::NotFound => Err(io_at(path)(error)),
        _ => Ok(()),
    }
}

struct Attempt {
    work: PathBuf,
    source: Source,
    store: ObjectStore,
    key: String,
    cipher: Aes256Gcm,
    limits: Limits,
    permit: Arc<OwnedSemaphorePermit>,
    cancel: CancellationToken,
}

impl Attempt {
    async fn run(self) -> Result<Backup, BackupError> {
        let result = self.upload().await;
        match &result {
            Ok(_) => fs::remove_dir_all(&self.work).map_err(io_at(&self.work))?,
            Err(error) => {
                tracing::warn!(scratch = %self.work.display(), error = %error, "backup failed; scratch retained");
            }
        }
        result
    }

    async fn upload(&self) -> Result<Backup, BackupError> {
        let scope = self.source.scope();
        let snapshot = self.work.join("snapshot.db");
        let captured_at_us = crate::domain::now_micros();
        snapshot_into(&self.source, &snapshot, self.limits.max_snapshot_bytes).await?;
        if self.cancel.is_cancelled() {
            return Err(BackupError::Timeout);
        }
        let aad = associated_data(&scope, &self.key);
        let (cipher, limits, permit) = (self.cipher.clone(), self.limits, self.permit.clone());
        let faults = self.store.faults().cloned();
        let sealed = blocking(move || {
            let _permit = permit;
            if let Some(faults) = &faults {
                Faults::wait_for_backup_seal(faults);
            }
            seal(&snapshot, &cipher, &aad, limits)
        })
        .await?;
        if self.cancel.is_cancelled() {
            return Err(BackupError::Timeout);
        }
        let object_bytes = sealed.body.len() as u64;
        let object_sha256 = hex::encode(Sha256::digest(&sealed.body));
        let created = tokio::select! {
            biased;
            () = self.cancel.cancelled() => return Err(BackupError::Timeout),
            created = self.store.put_if_absent(&self.key, sealed.body) => created?,
        };
        if created == Created::Exists {
            return Err(BackupError::Exists(self.key.clone()));
        }
        Ok(Backup {
            scope,
            key: self.key.clone(),
            captured_at_us,
            snapshot_bytes: sealed.snapshot_bytes,
            object_bytes,
            snapshot_sha256: sealed.snapshot_sha256,
            object_sha256,
        })
    }
}

/// Makes SQLite temporary files land on the data volume. SQLite reads
/// `SQLITE_TMPDIR` for each temporary file and silently uses `/tmp` when the
/// directory is missing, so a configured directory must exist before any
/// snapshot. Production requires `<data root>/sqlite-tmp`.
pub fn prepare_sqlite_temp(
    configured: Option<&std::ffi::OsStr>,
    data_root: &Path,
    production: bool,
) -> Result<(), String> {
    let required = data_root.join("sqlite-tmp");
    let Some(configured) = configured else {
        return if production {
            Err(format!(
                "production requires SQLITE_TMPDIR={}",
                required.display()
            ))
        } else {
            Ok(())
        };
    };
    let configured = Path::new(configured);
    if production && configured != required {
        return Err(format!(
            "production requires SQLITE_TMPDIR={}",
            required.display()
        ));
    }
    let mut builder = fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    std::os::unix::fs::DirBuilderExt::mode(&mut builder, 0o700);
    builder.create(configured).map_err(|_| {
        format!(
            "SQLITE_TMPDIR {} could not be created",
            configured.display()
        )
    })?;
    match fs::symlink_metadata(configured) {
        Ok(meta) if meta.is_dir() => Ok(()),
        _ => Err(format!(
            "SQLITE_TMPDIR {} must be a directory",
            configured.display()
        )),
    }
}

fn check_scratch(path: &Path) -> Result<(), BackupError> {
    let real_dir = fs::symlink_metadata(path).is_ok_and(|meta| meta.is_dir());
    if real_dir && path.to_str().is_some() {
        Ok(())
    } else {
        Err(BackupError::UnsafeScratch(path.to_path_buf()))
    }
}

fn cipher(data_key: &SecretString) -> Result<Aes256Gcm, BackupError> {
    let raw = Zeroizing::new(
        base64::engine::general_purpose::STANDARD
            .decode(data_key.expose_secret())
            .map_err(|_| BackupError::InvalidKey)?,
    );
    Aes256Gcm::new_from_slice(&raw).map_err(|_| BackupError::InvalidKey)
}

fn associated_data(scope: &Scope, key: &str) -> Vec<u8> {
    let mut aad = PURPOSE.to_vec();
    aad.extend_from_slice(&[0, VERSION, 0]);
    aad.extend_from_slice(scope.label().as_bytes());
    aad.push(0);
    aad.extend_from_slice(key.as_bytes());
    aad
}

async fn snapshot_into(source: &Source, path: &Path, max_bytes: u64) -> Result<(), BackupError> {
    match source {
        Source::Control(db) => vacuum_into(db, path, max_bytes).await,
        Source::Organization { pools, org } => {
            let handle = pools.registry().open_existing(&org.tenant()).await?;
            vacuum_into(&handle, path, max_bytes).await
        }
    }
}

async fn vacuum_into(
    db: &DatabaseConnection,
    path: &Path,
    max_bytes: u64,
) -> Result<(), BackupError> {
    let pages = pragma(db, "page_count").await?;
    let page_size = pragma(db, "page_size").await?;
    if pages.saturating_mul(page_size) > max_bytes {
        return Err(BackupError::SnapshotTooLarge(max_bytes));
    }
    let target = path
        .to_str()
        .ok_or_else(|| BackupError::UnsafeScratch(path.to_path_buf()))?;
    db.execute_raw(Statement::from_sql_and_values(
        DatabaseBackend::Sqlite,
        "VACUUM INTO ?",
        [target.into()],
    ))
    .await?;
    Ok(())
}

async fn pragma(db: &DatabaseConnection, name: &str) -> Result<u64, BackupError> {
    let row = db
        .query_one_raw(Statement::from_string(
            DatabaseBackend::Sqlite,
            format!("PRAGMA {name}"),
        ))
        .await?
        .ok_or_else(|| BackupError::Invalid(format!("PRAGMA {name} returned no row")))?;
    let value: i64 = row.try_get_by_index(0)?;
    Ok(value.max(0) as u64)
}

struct Sealed {
    body: Bytes,
    snapshot_bytes: u64,
    snapshot_sha256: String,
}

fn seal(
    snapshot: &Path,
    cipher: &Aes256Gcm,
    aad: &[u8],
    limits: Limits,
) -> Result<Sealed, BackupError> {
    let too_large = || BackupError::ObjectTooLarge(limits.max_object_bytes);
    let meta = fs::symlink_metadata(snapshot).map_err(io_at(snapshot))?;
    if !meta.is_file() {
        return Err(BackupError::Invalid(
            "snapshot is not a regular file".to_owned(),
        ));
    }
    if meta.len() > limits.max_snapshot_bytes {
        return Err(BackupError::SnapshotTooLarge(limits.max_snapshot_bytes));
    }
    let capacity = limits
        .max_object_bytes
        .checked_sub(TAG_LEN)
        .filter(|&capacity| capacity > HEADER_LEN)
        .ok_or_else(too_large)?;
    let nonce = Aes256Gcm::generate_nonce(&mut OsRng);
    let mut body = Vec::with_capacity((HEADER_LEN + meta.len() as usize / 2).min(capacity));
    body.extend_from_slice(MAGIC);
    body.push(VERSION);
    body.extend_from_slice(&nonce);
    let mut encoder = zstd::Encoder::new(
        Capped {
            inner: body,
            capacity,
        },
        COMPRESSION_LEVEL,
    )
    .map_err(io_at(snapshot))?;
    let mut file = Hashing {
        inner: File::open(snapshot).map_err(io_at(snapshot))?,
        digest: Sha256::new(),
    };
    let read = io::copy(
        &mut (&mut file).take(limits.max_snapshot_bytes + 1),
        &mut encoder,
    );
    let finished = read.and_then(|read| encoder.finish().map(|capped| (read, capped.inner)));
    let (snapshot_bytes, mut body) = finished.map_err(|error| match error.kind() {
        io::ErrorKind::FileTooLarge => too_large(),
        _ => io_at(snapshot)(error),
    })?;
    if snapshot_bytes > limits.max_snapshot_bytes {
        return Err(BackupError::SnapshotTooLarge(limits.max_snapshot_bytes));
    }
    let tag = cipher
        .encrypt_in_place_detached(&nonce, aad, &mut body[HEADER_LEN..])
        .map_err(|_| too_large())?;
    body.extend_from_slice(&tag);
    Ok(Sealed {
        body: Bytes::from(body),
        snapshot_bytes,
        snapshot_sha256: hex::encode(file.digest.finalize()),
    })
}

/// Checks the header and decrypts in place. Returns where the tag starts.
fn authenticate(body: &mut [u8], cipher: &Aes256Gcm, aad: &[u8]) -> Result<usize, BackupError> {
    if body.len() < HEADER_LEN + TAG_LEN
        || &body[..MAGIC.len()] != MAGIC
        || body[MAGIC.len()] != VERSION
    {
        return Err(BackupError::Malformed);
    }
    let tag_at = body.len() - TAG_LEN;
    let nonce = *Nonce::from_slice(&body[MAGIC.len() + 1..HEADER_LEN]);
    let tag = *Tag::from_slice(&body[tag_at..]);
    cipher
        .decrypt_in_place_detached(&nonce, aad, &mut body[HEADER_LEN..tag_at], &tag)
        .map_err(|_| BackupError::Authentication)?;
    Ok(tag_at)
}

fn unseal_into(
    body: Bytes,
    cipher: &Aes256Gcm,
    aad: &[u8],
    target: &Path,
    limits: Limits,
) -> Result<(u64, String), BackupError> {
    let mut body = Vec::from(body);
    let tag_at = authenticate(&mut body, cipher, aad)?;
    let mut decoder =
        zstd::Decoder::with_buffer(&body[HEADER_LEN..tag_at]).map_err(io_at(target))?;
    decoder
        .window_log_max(WINDOW_LOG_MAX)
        .map_err(io_at(target))?;
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    let file = options.open(target).map_err(|error| match error.kind() {
        io::ErrorKind::AlreadyExists => BackupError::DestinationExists(target.to_path_buf()),
        _ => io_at(target)(error),
    })?;
    let mut file = Hashing {
        inner: file,
        digest: Sha256::new(),
    };
    let written = io::copy(&mut decoder.take(limits.max_snapshot_bytes + 1), &mut file)
        .map_err(io_at(target))?;
    if written > limits.max_snapshot_bytes {
        return Err(BackupError::SnapshotTooLarge(limits.max_snapshot_bytes));
    }
    file.inner.sync_all().map_err(io_at(target))?;
    Ok((written, hex::encode(file.digest.finalize())))
}

pub(crate) async fn open_read_only(path: &Path) -> Result<DatabaseConnection, BackupError> {
    let options = SqliteConnectOptions::new()
        .filename(path)
        .read_only(true)
        .immutable(true);
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(options)
        .await
        .map_err(|error| BackupError::Invalid(format!("open: {error}")))?;
    Ok(SqlxSqliteConnector::from_sqlx_sqlite_pool(pool))
}

/// Migrates an offline organization file and marks it restored: its first use
/// reconciles logs with R2, and orphan payload cleanup stays held. Returns the
/// marking time.
pub(crate) async fn mark_restored_organization(
    path: &Path,
    snapshot_captured_at_us: i64,
) -> Result<i64, BackupError> {
    let options = SqliteConnectOptions::new()
        .filename(path)
        .journal_mode(sea_orm::sqlx::sqlite::SqliteJournalMode::Delete)
        .foreign_keys(true);
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(options)
        .await
        .map_err(|error| BackupError::Invalid(format!("open: {error}")))?;
    let db = SqlxSqliteConnector::from_sqlx_sqlite_pool(pool);
    let marked_at = crate::domain::now_micros();
    let result = async {
        loco_rs::db::migrate::<migration::OrgMigrator>(&db)
            .await
            .map_err(|error| BackupError::Invalid(format!("migrate: {error}")))?;
        db.execute_raw(Statement::from_sql_and_values(
            DatabaseBackend::Sqlite,
            "UPDATE restore_state SET logs_reconcile_required = 1, orphan_cleanup_held = 1,
                scan_after = NULL, conflict = NULL, marked_at = ?, snapshot_captured_at = ? WHERE id = 1",
            [marked_at.into(), snapshot_captured_at_us.into()],
        ))
        .await?;
        Ok(marked_at)
    }
    .await;
    db.close().await?;
    result
}

/// Integrity, foreign keys and applied migrations of an offline file.
pub(crate) async fn validate(path: &Path) -> Result<(), BackupError> {
    let db = open_read_only(path).await?;
    let result = check(&db).await;
    db.close().await?;
    result
}

async fn check(db: &DatabaseConnection) -> Result<(), BackupError> {
    let query = |sql: &str| Statement::from_string(DatabaseBackend::Sqlite, sql);
    let integrity: Vec<String> = db
        .query_all_raw(query("PRAGMA integrity_check"))
        .await?
        .iter()
        .map(|row| row.try_get_by_index(0))
        .collect::<Result<_, _>>()?;
    if integrity != ["ok"] {
        return Err(BackupError::Invalid(format!(
            "integrity_check: {}",
            integrity.join("; ")
        )));
    }
    if !db
        .query_all_raw(query("PRAGMA foreign_key_check"))
        .await?
        .is_empty()
    {
        return Err(BackupError::Invalid(
            "foreign_key_check reported rows".to_owned(),
        ));
    }
    let migrations: i64 = db
        .query_one_raw(query("SELECT count(*) FROM seaql_migrations"))
        .await?
        .ok_or_else(|| BackupError::Invalid("no migration count".to_owned()))?
        .try_get_by_index(0)?;
    if migrations == 0 {
        return Err(BackupError::Invalid("no applied migrations".to_owned()));
    }
    Ok(())
}

pub(crate) fn sidecar(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path.as_os_str().to_owned();
    name.push(suffix);
    PathBuf::from(name)
}

async fn blocking<T: Send + 'static>(
    work: impl FnOnce() -> Result<T, BackupError> + Send + 'static,
) -> Result<T, BackupError> {
    tokio::task::spawn_blocking(work)
        .await
        .map_err(|_| BackupError::Worker)?
}

pub(crate) fn io_at(path: &Path) -> impl FnOnce(io::Error) -> BackupError + '_ {
    move |source| BackupError::Io {
        path: path.to_path_buf(),
        source,
    }
}

struct Capped {
    inner: Vec<u8>,
    capacity: usize,
}

impl io::Write for Capped {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        if self.inner.len() + buf.len() > self.capacity {
            return Err(io::ErrorKind::FileTooLarge.into());
        }
        self.inner.extend_from_slice(buf);
        Ok(buf.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

struct Hashing<T> {
    inner: T,
    digest: Sha256,
}

impl<T: Read> Read for Hashing<T> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let n = self.inner.read(buf)?;
        self.digest.update(&buf[..n]);
        Ok(n)
    }
}

impl<T: Write> Write for Hashing<T> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let n = self.inner.write(buf)?;
        self.digest.update(&buf[..n]);
        Ok(n)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.inner.flush()
    }
}

#[cfg(test)]
mod tests {
    use std::{
        net::TcpListener,
        sync::{atomic::Ordering, Arc},
    };

    use base64::engine::general_purpose::STANDARD;
    use serde::Deserialize as _;
    use tenant_sqlite_loco::{Config, Synchronous};
    use tokio::sync::oneshot;

    use super::*;
    use crate::credentials::R2Credentials;

    fn secret(value: &str) -> SecretString {
        let value = serde::de::value::StrDeserializer::<serde::de::value::Error>::new(value);
        SecretString::deserialize(value).unwrap()
    }

    fn generated_key() -> SecretString {
        secret(&STANDARD.encode(Aes256Gcm::generate_key(&mut OsRng)))
    }

    fn limits() -> Limits {
        Limits {
            max_snapshot_bytes: 8 << 20,
            max_object_bytes: 8 << 20,
            deadline: Duration::from_secs(30),
            max_scratch_dirs: 4,
            retain_failures: Duration::from_secs(3_600),
        }
    }

    fn memory_store() -> ObjectStore {
        ObjectStore::memory("test/", Duration::from_secs(5), Arc::default()).unwrap()
    }

    /// Test databases stay on disk after the run. `POSTDEPLOY_TEST_DATA` selects the root.
    fn test_dir() -> PathBuf {
        let root = std::env::var_os("POSTDEPLOY_TEST_DATA")
            .map(PathBuf::from)
            .unwrap_or_else(std::env::temp_dir);
        let dir = root.join(format!("backup-{}", uuid::Uuid::now_v7().simple()));
        for child in ["tenants", "scratch", "restored"] {
            fs::create_dir_all(dir.join(child)).unwrap();
        }
        dir
    }

    struct Fixture {
        dir: PathBuf,
        pools: TenantPools,
        org: OrgId,
        key: SecretString,
    }

    impl Fixture {
        async fn new() -> Self {
            let dir = test_dir();
            let mut config = Config::new(dir.join("tenants"));
            config.synchronous = Synchronous::Full;
            let pools = TenantPools::new::<migration::OrgMigrator>(config).unwrap();
            let org = OrgId::generate();
            drop(pools.registry().provision(&org.tenant()).await.unwrap());
            Self {
                dir,
                pools,
                org,
                key: generated_key(),
            }
        }

        fn backups(&self, limits: Limits) -> Backups {
            Backups::new(self.dir.join("scratch"), limits, &self.key).unwrap()
        }

        fn source(&self) -> Source {
            Source::Organization {
                pools: self.pools.clone(),
                org: self.org.clone(),
            }
        }

        fn scope(&self) -> Scope {
            Scope::Organization(self.org.clone())
        }

        fn object_key(&self) -> String {
            format!("backups/sets/unit/org/{}.pdbk", self.org)
        }

        fn restored(&self, name: &str) -> PathBuf {
            self.dir.join("restored").join(name)
        }

        fn tenant_file(&self, suffix: &str) -> PathBuf {
            sidecar(&self.pools.registry().path(&self.org.tenant()), suffix)
        }

        fn scratch_entries(&self) -> Vec<PathBuf> {
            fs::read_dir(self.dir.join("scratch"))
                .unwrap()
                .map(|entry| entry.unwrap().path())
                .collect()
        }

        async fn leased(&self) -> usize {
            self.pools.registry().stats().await.leased_pools
        }

        async fn insert_issue(&self, title: &str) {
            let db = self
                .pools
                .registry()
                .open_existing(&self.org.tenant())
                .await
                .unwrap();
            db.execute_raw(Statement::from_sql_and_values(
                DatabaseBackend::Sqlite,
                "INSERT INTO issues (project_id, environment, fingerprint, title, level, status, \
                 first_seen, last_seen, event_count) VALUES (1, 'production', ?, ?, 'error', 'open', 1, 1, 1)",
                [title.into(), title.into()],
            ))
            .await
            .unwrap();
        }

        async fn live_titles(&self) -> Vec<String> {
            let db = self
                .pools
                .registry()
                .open_existing(&self.org.tenant())
                .await
                .unwrap();
            column(&db, "SELECT title FROM issues ORDER BY id").await
        }

        async fn backup_once(
            &self,
            backups: &Backups,
            store: &ObjectStore,
        ) -> Result<Backup, BackupError> {
            let worker = backups.lease()?;
            backups
                .backup(&worker, self.source(), store, self.object_key())
                .await
        }
    }

    async fn column(db: &DatabaseConnection, sql: &str) -> Vec<String> {
        db.query_all_raw(Statement::from_string(DatabaseBackend::Sqlite, sql))
            .await
            .unwrap()
            .iter()
            .map(|row| row.try_get_by_index(0).unwrap())
            .collect()
    }

    async fn restored_column(path: &Path, sql: &str) -> Vec<String> {
        let db = open_read_only(path).await.unwrap();
        let values = column(&db, sql).await;
        db.close().await.unwrap();
        values
    }

    fn contains(haystack: &[u8], needle: &[u8]) -> bool {
        haystack
            .windows(needle.len())
            .any(|window| window == needle)
    }

    #[tokio::test]
    async fn committed_wal_row_restores_and_later_writes_stay_out_of_the_snapshot() {
        let f = Fixture::new().await;
        let store = memory_store();
        f.insert_issue("committed-in-wal").await;
        assert!(contains(
            &fs::read(f.tenant_file("-wal")).unwrap(),
            b"committed-in-wal"
        ));
        assert!(!contains(
            &fs::read(f.tenant_file("")).unwrap(),
            b"committed-in-wal"
        ));

        let backups = f.backups(limits());
        let backup = f.backup_once(&backups, &store).await.unwrap();
        assert_eq!(f.leased().await, 0);
        assert!(f.scratch_entries().is_empty());
        assert_eq!(backup.key, f.object_key());
        let object = store.get(&backup.key, usize::MAX).await.unwrap().unwrap();
        assert_eq!(object.len() as u64, backup.object_bytes);
        assert_eq!(hex::encode(Sha256::digest(&object)), backup.object_sha256);
        assert_eq!(&object[..MAGIC.len()], MAGIC);

        f.insert_issue("after-backup").await;
        let destination = f.restored("org.db");
        let restored = backups
            .restore(&store, &f.scope(), &backup.key, &destination)
            .await
            .unwrap();
        assert_eq!(
            restored,
            Restored {
                path: destination.clone(),
                snapshot_bytes: backup.snapshot_bytes,
                snapshot_sha256: backup.snapshot_sha256.clone(),
                object_sha256: backup.object_sha256.clone(),
            }
        );
        let sql = "SELECT title FROM issues ORDER BY id";
        assert_eq!(
            restored_column(&destination, sql).await,
            ["committed-in-wal"]
        );
        assert_eq!(f.live_titles().await, ["committed-in-wal", "after-backup"]);
        for suffix in ["-wal", "-shm", "-journal"] {
            assert!(fs::symlink_metadata(sidecar(&destination, suffix)).is_err());
        }
    }

    #[tokio::test]
    async fn wrong_key_scope_location_and_tampering_fail_authentication() {
        let f = Fixture::new().await;
        let store = memory_store();
        f.insert_issue("bound").await;
        let backups = f.backups(limits());
        let backup = f.backup_once(&backups, &store).await.unwrap();
        let object = store.get(&backup.key, usize::MAX).await.unwrap().unwrap();
        let moved = format!("backups/sets/unit/org/{}-moved.pdbk", f.org);
        store.put(&moved, object.clone()).await.unwrap();
        let wrong_key = Backups::new(f.dir.join("scratch"), limits(), &generated_key()).unwrap();
        let attempts = [
            (&wrong_key, f.scope(), backup.key.as_str()),
            (
                &backups,
                Scope::Organization(OrgId::generate()),
                backup.key.as_str(),
            ),
            (&backups, Scope::Control, backup.key.as_str()),
            (&backups, Scope::Manifest, backup.key.as_str()),
            (&backups, f.scope(), moved.as_str()),
        ];
        for (index, (backups, scope, object_key)) in attempts.into_iter().enumerate() {
            let destination = f.restored(&format!("rejected-{index}.db"));
            let result = backups
                .restore(&store, &scope, object_key, &destination)
                .await;
            assert!(
                matches!(result, Err(BackupError::Authentication)),
                "{result:?}"
            );
            assert!(fs::symlink_metadata(&destination).is_err());
        }

        let tamper = |at: usize| {
            let mut bytes = object.to_vec();
            bytes[at] ^= 1;
            Bytes::from(bytes)
        };
        for (index, (at, authentication)) in [
            (MAGIC.len() + 1, true),
            (HEADER_LEN + 3, true),
            (object.len() - 1, true),
            (0, false),
        ]
        .into_iter()
        .enumerate()
        {
            store.put(&backup.key, tamper(at)).await.unwrap();
            let destination = f.restored(&format!("tampered-{index}.db"));
            let result = backups
                .restore(&store, &f.scope(), &backup.key, &destination)
                .await;
            if authentication {
                assert!(
                    matches!(result, Err(BackupError::Authentication)),
                    "{result:?}"
                );
            } else {
                assert!(matches!(result, Err(BackupError::Malformed)), "{result:?}");
            }
            assert!(fs::symlink_metadata(&destination).is_err());
        }
        store
            .put(&backup.key, object.slice(..HEADER_LEN + TAG_LEN - 1))
            .await
            .unwrap();
        let result = backups
            .restore(&store, &f.scope(), &backup.key, &f.restored("short.db"))
            .await;
        assert!(matches!(result, Err(BackupError::Malformed)), "{result:?}");

        store.put(&backup.key, object).await.unwrap();
        let destination = f.restored("accepted.db");
        backups
            .restore(&store, &f.scope(), &backup.key, &destination)
            .await
            .unwrap();
        let sql = "SELECT title FROM issues ORDER BY id";
        assert_eq!(restored_column(&destination, sql).await, ["bound"]);
    }

    #[tokio::test]
    async fn existing_targets_and_symlinks_are_preserved() {
        let f = Fixture::new().await;
        let store = memory_store();
        f.insert_issue("live").await;
        let backups = f.backups(limits());
        let backup = f.backup_once(&backups, &store).await.unwrap();

        let existing = f.restored("existing.db");
        fs::write(&existing, b"keep").unwrap();
        let result = backups
            .restore(&store, &f.scope(), &backup.key, &existing)
            .await;
        assert!(
            matches!(&result, Err(BackupError::DestinationExists(path)) if *path == existing),
            "{result:?}"
        );
        assert_eq!(fs::read(&existing).unwrap(), b"keep");

        #[cfg(unix)]
        {
            let target = f.restored("target.txt");
            fs::write(&target, b"target").unwrap();
            let link = f.restored("link.db");
            std::os::unix::fs::symlink(&target, &link).unwrap();
            assert!(matches!(
                backups
                    .restore(&store, &f.scope(), &backup.key, &link)
                    .await,
                Err(BackupError::DestinationExists(_))
            ));
            assert_eq!(fs::read(&target).unwrap(), b"target");
        }

        let live = f.tenant_file("");
        let before = fs::metadata(&live).unwrap().len();
        assert!(matches!(
            backups
                .restore(&store, &f.scope(), &backup.key, &live)
                .await,
            Err(BackupError::DestinationExists(_))
        ));
        assert_eq!(fs::metadata(&live).unwrap().len(), before);
        assert_eq!(f.live_titles().await, ["live"]);
    }

    #[tokio::test]
    async fn byte_limits_fail_before_upload_or_restore_output() {
        let f = Fixture::new().await;
        let store = memory_store();
        f.insert_issue("limits").await;

        let small_snapshot = Limits {
            max_snapshot_bytes: 4096,
            ..limits()
        };
        let result = f.backup_once(&f.backups(small_snapshot), &store).await;
        assert!(
            matches!(result, Err(BackupError::SnapshotTooLarge(4096))),
            "{result:?}"
        );
        assert_eq!(f.leased().await, 0);

        let small_object = Limits {
            max_object_bytes: 256,
            ..limits()
        };
        let result = f.backup_once(&f.backups(small_object), &store).await;
        assert!(
            matches!(result, Err(BackupError::ObjectTooLarge(256))),
            "{result:?}"
        );
        assert_eq!(store.counters().puts.load(Ordering::Relaxed), 0);
        let retained = f.scratch_entries();
        assert_eq!(retained.len(), 2);
        assert!(retained.iter().any(|dir| dir.join("snapshot.db").is_file()));

        let backups = f.backups(limits());
        let backup = f.backup_once(&backups, &store).await.unwrap();
        assert_eq!(f.scratch_entries().len(), 2);

        let destination = f.restored("limited.db");
        let object_limit = Limits {
            max_object_bytes: backup.object_bytes as usize - 1,
            ..limits()
        };
        let result = f
            .backups(object_limit)
            .restore(&store, &f.scope(), &backup.key, &destination)
            .await;
        assert!(
            matches!(result, Err(BackupError::ObjectTooLarge(_))),
            "{result:?}"
        );
        assert!(fs::symlink_metadata(&destination).is_err());

        let result = f
            .backups(small_snapshot)
            .restore(&store, &f.scope(), &backup.key, &destination)
            .await;
        assert!(
            matches!(result, Err(BackupError::SnapshotTooLarge(4096))),
            "{result:?}"
        );
        assert_eq!(fs::metadata(&destination).unwrap().len(), 4097);
    }

    #[tokio::test]
    async fn control_database_uses_the_same_backup_path() {
        let dir = test_dir();
        let path = dir.join("control.db");
        let db = sea_orm::Database::connect(format!("sqlite://{}?mode=rwc", path.display()))
            .await
            .unwrap();
        db.execute_unprepared("PRAGMA journal_mode=WAL")
            .await
            .unwrap();
        loco_rs::db::migrate::<migration::ControlMigrator>(&db)
            .await
            .unwrap();
        let org = OrgId::generate();
        db.execute_unprepared(
            "INSERT INTO users (id, email, password_hash, created_at) VALUES (1, 'owner@example.test', 'x', 1)",
        )
        .await
        .unwrap();
        db.execute_raw(Statement::from_sql_and_values(
            DatabaseBackend::Sqlite,
            "INSERT INTO organizations (id, name, created_by, created_at) VALUES (?, 'Probe Org', 1, 1)",
            [org.as_str().into()],
        ))
        .await
        .unwrap();

        let store = memory_store();
        let backups = Backups::new(dir.join("scratch"), limits(), &generated_key()).unwrap();
        let worker = backups.lease().unwrap();
        let backup = backups
            .backup(
                &worker,
                Source::Control(db.clone()),
                &store,
                "c.pdbk".to_owned(),
            )
            .await
            .unwrap();
        assert_eq!(backup.scope, Scope::Control);

        let as_org = Scope::Organization(org.clone());
        let result = backups
            .restore(
                &store,
                &as_org,
                &backup.key,
                &dir.join("restored").join("as-org.db"),
            )
            .await;
        assert!(
            matches!(result, Err(BackupError::Authentication)),
            "{result:?}"
        );
        let destination = dir.join("restored").join("control.db");
        backups
            .restore(&store, &Scope::Control, &backup.key, &destination)
            .await
            .unwrap();
        let sql = "SELECT id || ':' || name FROM organizations";
        assert_eq!(
            restored_column(&destination, sql).await,
            [format!("{org}:Probe Org")]
        );
        db.close().await.unwrap();
    }

    #[tokio::test]
    async fn sealed_documents_open_only_for_their_scope_and_key() {
        let backups = Backups::new(test_dir().join("scratch"), limits(), &generated_key()).unwrap();
        let body = backups
            .seal_bytes(&Scope::Manifest, "m.pdbk", b"{\"format\":1}")
            .unwrap();
        assert_eq!(
            backups
                .unseal_bytes(&Scope::Manifest, "m.pdbk", body.clone(), 64)
                .unwrap(),
            b"{\"format\":1}"
        );
        assert!(matches!(
            backups.unseal_bytes(&Scope::Manifest, "other.pdbk", body.clone(), 64),
            Err(BackupError::Authentication)
        ));
        assert!(matches!(
            backups.unseal_bytes(&Scope::Control, "m.pdbk", body.clone(), 64),
            Err(BackupError::Authentication)
        ));
        assert!(matches!(
            backups.unseal_bytes(&Scope::Manifest, "m.pdbk", body, 4),
            Err(BackupError::ObjectTooLarge(4))
        ));
    }

    #[tokio::test]
    async fn a_timed_out_seal_keeps_the_worker_busy_until_it_ends_and_never_uploads() {
        let f = Fixture::new().await;
        f.insert_issue("held-seal").await;
        let faults = Arc::new(Faults::default());
        let store = ObjectStore::memory("test/", Duration::from_secs(5), faults.clone()).unwrap();
        let backups = f.backups(Limits {
            deadline: Duration::from_millis(300),
            ..limits()
        });
        struct Release(Arc<Faults>);
        impl Drop for Release {
            fn drop(&mut self) {
                self.0.hold_backup_seals(false);
            }
        }
        let _release_on_failure = Release(faults.clone());
        faults.hold_backup_seals(true);
        let held = faults.backup_seal_held.notified();
        let result = f.backup_once(&backups, &store).await;
        assert!(matches!(result, Err(BackupError::Timeout)), "{result:?}");
        tokio::time::timeout(Duration::from_secs(5), held)
            .await
            .unwrap();
        tokio::time::sleep(Duration::from_millis(200)).await;
        assert_eq!(f.scratch_entries().len(), 1);

        let result = f.backup_once(&backups, &store).await;
        assert!(matches!(result, Err(BackupError::Busy)), "{result:?}");
        assert_eq!(
            f.scratch_entries().len(),
            1,
            "a busy worker claims no scratch"
        );

        faults.hold_backup_seals(false);
        tokio::time::timeout(Duration::from_secs(5), backups.idle())
            .await
            .unwrap();
        assert_eq!(store.counters().puts.load(Ordering::SeqCst), 0);
        assert!(store.get(&f.object_key(), 1 << 20).await.unwrap().is_none());
        let retained = f.scratch_entries();
        assert_eq!(retained.len(), 1);
        assert!(retained[0].join("snapshot.db").is_file());

        let backup = f.backup_once(&backups, &store).await.unwrap();
        assert_eq!(backup.key, f.object_key());
        assert_eq!(store.counters().puts.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn the_same_lease_cannot_start_a_second_attempt_while_a_timed_out_seal_runs() {
        let f = Fixture::new().await;
        let faults = Arc::new(Faults::default());
        let store = ObjectStore::memory("test/", Duration::from_secs(5), faults.clone()).unwrap();
        let backups = f.backups(Limits {
            deadline: Duration::from_millis(300),
            ..limits()
        });
        struct Release(Arc<Faults>);
        impl Drop for Release {
            fn drop(&mut self) {
                self.0.hold_backup_seals(false);
            }
        }
        let _release_on_failure = Release(faults.clone());
        faults.hold_backup_seals(true);
        let worker = backups.lease().unwrap();
        let result = backups
            .backup(&worker, f.source(), &store, f.object_key())
            .await;
        assert!(matches!(result, Err(BackupError::Timeout)), "{result:?}");
        tokio::time::sleep(Duration::from_millis(200)).await;
        let result = backups
            .backup(&worker, f.source(), &store, f.object_key())
            .await;
        assert!(matches!(result, Err(BackupError::Busy)), "{result:?}");
        assert_eq!(f.scratch_entries().len(), 1, "no second snapshot started");
        faults.hold_backup_seals(false);
        drop(worker);
        tokio::time::timeout(Duration::from_secs(5), backups.idle())
            .await
            .unwrap();
        assert_eq!(store.counters().puts.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn sqlite_temporary_directory_is_created_and_required_in_production() {
        let root = test_dir();
        let required = root.join("sqlite-tmp");
        assert_eq!(
            prepare_sqlite_temp(None, &root, true),
            Err(format!(
                "production requires SQLITE_TMPDIR={}",
                required.display()
            ))
        );
        assert_eq!(
            prepare_sqlite_temp(Some(std::ffi::OsStr::new("/tmp")), &root, true),
            Err(format!(
                "production requires SQLITE_TMPDIR={}",
                required.display()
            ))
        );
        assert_eq!(prepare_sqlite_temp(None, &root, false), Ok(()));
        assert!(!required.exists());
        assert_eq!(
            prepare_sqlite_temp(Some(required.as_os_str()), &root, true),
            Ok(())
        );
        assert!(fs::symlink_metadata(&required).unwrap().is_dir());
        let file = root.join("not-a-dir");
        fs::write(&file, b"x").unwrap();
        assert_eq!(
            prepare_sqlite_temp(Some(file.as_os_str()), &root, false),
            Err(format!(
                "SQLITE_TMPDIR {} could not be created",
                file.display()
            ))
        );
    }

    struct StalledPut {
        endpoint: String,
        started: oneshot::Receiver<usize>,
        release: oneshot::Sender<()>,
    }

    /// One-shot S3-compatible endpoint that holds a PUT open until released.
    fn stalled_put() -> StalledPut {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = format!("http://{}", listener.local_addr().unwrap());
        let (started_tx, started) = oneshot::channel();
        let (release, release_rx) = oneshot::channel::<()>();
        std::thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            let mut request = Vec::new();
            let mut chunk = [0u8; 16 * 1024];
            let head_end = loop {
                let n = socket.read(&mut chunk).unwrap();
                assert!(n > 0, "connection closed before headers");
                request.extend_from_slice(&chunk[..n]);
                if let Some(at) = request.windows(4).position(|window| window == b"\r\n\r\n") {
                    break at + 4;
                }
            };
            let head = String::from_utf8_lossy(&request[..head_end]).to_ascii_lowercase();
            assert!(head.starts_with("put "), "{head}");
            let length: usize = head
                .lines()
                .find_map(|line| line.strip_prefix("content-length:"))
                .unwrap()
                .trim()
                .parse()
                .unwrap();
            while request.len() < head_end + length {
                let n = socket.read(&mut chunk).unwrap();
                assert!(n > 0, "connection closed before body");
                request.extend_from_slice(&chunk[..n]);
            }
            let _ = started_tx.send(length);
            if release_rx.blocking_recv().is_ok() {
                let _ = socket
                    .write_all(b"HTTP/1.1 200 OK\r\nETag: \"probe\"\r\nContent-Length: 0\r\n\r\n");
            }
        });
        StalledPut {
            endpoint,
            started,
            release,
        }
    }

    fn http_store(endpoint: &str) -> ObjectStore {
        opendal::install_default();
        let credentials = R2Credentials {
            endpoint: endpoint.to_owned(),
            bucket: "probe".to_owned(),
            access_key_id: secret("probe-access"),
            secret_access_key: secret("probe-secret"),
        };
        ObjectStore::r2(&credentials, "test/", Duration::from_secs(30)).unwrap()
    }

    #[tokio::test]
    async fn tenant_is_not_leased_while_a_slow_put_is_in_flight() {
        let f = Fixture::new().await;
        f.insert_issue("before-put").await;
        let StalledPut {
            endpoint,
            started,
            release,
        } = stalled_put();
        let store = http_store(&endpoint);
        let backups = f.backups(limits());
        let backup = f.backup_once(&backups, &store);
        tokio::pin!(backup);
        let uploaded = tokio::select! {
            result = &mut backup => panic!("backup finished before the PUT was held: {result:?}"),
            uploaded = started => uploaded.expect("PUT reached the endpoint"),
        };
        let leased = f.leased().await;
        release.send(()).unwrap();
        let backup = backup.await.unwrap();
        assert_eq!(leased, 0);
        assert_eq!(uploaded as u64, backup.object_bytes);
        assert!(f.scratch_entries().is_empty());
    }

    #[tokio::test]
    async fn deadline_fails_a_stalled_backup_and_the_retained_failure_leaves_a_slot_for_the_next() {
        let f = Fixture::new().await;
        let mut server = stalled_put();
        let store = http_store(&server.endpoint);
        let backups = f.backups(Limits {
            deadline: Duration::from_millis(500),
            max_scratch_dirs: 2,
            ..limits()
        });
        let result = f.backup_once(&backups, &store).await;
        assert!(matches!(result, Err(BackupError::Timeout)), "{result:?}");
        assert!(
            server.started.try_recv().is_ok(),
            "deadline expired during the PUT"
        );
        backups.idle().await;
        assert_eq!(f.leased().await, 0);
        let retained = f.scratch_entries();
        assert_eq!(retained.len(), 1);
        assert!(retained[0].join("snapshot.db").is_file());

        let backup = f.backup_once(&backups, &memory_store()).await.unwrap();
        assert_eq!(backup.key, f.object_key());
        assert_eq!(f.scratch_entries(), retained);
    }

    fn scratch_name(label: &str, age: Duration) -> String {
        let at = std::time::SystemTime::now() - age;
        let since = at.duration_since(std::time::UNIX_EPOCH).unwrap();
        let id = uuid::Uuid::new_v7(uuid::Timestamp::from_unix(
            uuid::NoContext,
            since.as_secs(),
            since.subsec_nanos(),
        ));
        format!("{label}-{}", id.simple())
    }

    #[tokio::test]
    async fn retained_scratch_expires_by_age_and_with_its_organization() {
        let f = Fixture::new().await;
        let scratch = f.dir.join("scratch");
        let org_label = format!("org-{}", f.org);
        let expired = scratch.join(scratch_name(&org_label, Duration::from_secs(7_200)));
        let recent_control = scratch.join(scratch_name("control", Duration::from_secs(60)));
        let recent_org = scratch.join(scratch_name(&org_label, Duration::from_secs(30)));
        let foreign = scratch.join("operator-notes");
        for dir in [&expired, &recent_control, &recent_org, &foreign] {
            fs::create_dir(dir).unwrap();
            fs::write(dir.join("snapshot.db"), b"plaintext").unwrap();
        }
        let names = |entries: Vec<PathBuf>| {
            let mut names: Vec<String> = entries
                .iter()
                .map(|path| path.file_name().unwrap().to_string_lossy().into_owned())
                .collect();
            names.sort();
            names
        };
        let sorted = |paths: &[&PathBuf]| {
            let mut names: Vec<String> = paths
                .iter()
                .map(|path| path.file_name().unwrap().to_string_lossy().into_owned())
                .collect();
            names.sort();
            names
        };

        let backups = f.backups(Limits {
            retain_failures: Duration::from_secs(3_600),
            ..limits()
        });
        f.backup_once(&backups, &memory_store()).await.unwrap();
        assert_eq!(
            names(f.scratch_entries()),
            sorted(&[&recent_control, &recent_org, &foreign])
        );

        assert_eq!(remove_organization_scratch(&scratch, &f.org).unwrap(), 1);
        assert_eq!(
            names(f.scratch_entries()),
            sorted(&[&recent_control, &foreign])
        );

        let worker = backups.lease().unwrap();
        let since = crate::domain::now_micros() - 90_000_000;
        assert_eq!(backups.discard_scratch_since(&worker, since).unwrap(), 1);
        assert_eq!(names(f.scratch_entries()), sorted(&[&foreign]));
    }

    #[test]
    fn invalid_keys_are_rejected_before_any_work_and_never_printed() {
        let dir = test_dir();
        let bad_keys = [
            "not base64!".to_owned(),
            STANDARD.encode([7u8; 31]),
            STANDARD.encode([7u8; 33]),
        ];
        for bad in &bad_keys {
            let error = Backups::new(dir.join("scratch"), limits(), &secret(bad)).unwrap_err();
            assert!(matches!(error, BackupError::InvalidKey));
            assert!(!format!("{error:?} {error}").contains(bad.as_str()));
        }
        assert_eq!(fs::read_dir(dir.join("scratch")).unwrap().count(), 0);
    }
}
