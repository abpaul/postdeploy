use std::{
    collections::HashMap,
    fs::File,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex, OnceLock, Weak,
    },
    time::Duration,
};

use async_trait::async_trait;
use axum::{
    extract::{Request, State},
    middleware::Next,
    response::{IntoResponse, Response},
};
use loco_rs::{
    app::{AppContext, Hooks, Initializer},
    bgworker::Queue,
    boot::{create_app, BootResult, StartMode},
    config::Config,
    controller::AppRoutes,
    environment::Environment,
    task::Tasks,
    Error, Result,
};
use migration::{ControlMigrator, MigratorTrait, OrgMigrator};
use sea_orm::{
    sqlx::sqlite::{SqliteJournalMode, SqliteSynchronous},
    ConnectOptions, ConnectionTrait, Database,
};
use tenant_sqlite_loco::{Synchronous, TenantInitializer, TenantPools};

use crate::{
    controllers,
    credentials::Credentials,
    error::ApiError,
    runtime::{sql, Runtime},
    settings::Settings,
    store::ObjectStore,
};

pub struct App;

pub struct RootLock {
    owner: Arc<RootOwner>,
    runtime_claimed: bool,
}

struct RootOwner {
    _tenant_file: File,
    _control_file: File,
    runtime_claimed: AtomicBool,
}

struct PendingRootLock(RootLock);

type OwnerKey = (PathBuf, PathBuf);
static OWNERS: OnceLock<Mutex<HashMap<OwnerKey, Weak<RootOwner>>>> = OnceLock::new();

impl Drop for RootLock {
    fn drop(&mut self) {
        if self.runtime_claimed {
            self.owner.runtime_claimed.store(false, Ordering::Release);
        }
    }
}

async fn acquire_owner(ctx: &AppContext, settings: &Settings) -> Result<RootLock> {
    let root = &settings.tenants.root;
    std::fs::create_dir_all(root)
        .map_err(|error| Error::string(&format!("tenant root: {error}")))?;
    let root = root.canonicalize().map_err(Error::wrap)?;
    let rows = ctx
        .db
        .query_all_raw(sql("PRAGMA database_list", vec![]))
        .await
        .map_err(Error::wrap)?;
    let control = rows
        .iter()
        .find_map(|row| {
            (row.try_get::<String>("", "name").ok()?.as_str() == "main")
                .then(|| row.try_get::<String>("", "file").ok())
                .flatten()
        })
        .filter(|path| !path.is_empty())
        .ok_or_else(|| Error::string("control database needs an on-disk path"))?;
    let control = Path::new(&control).canonicalize().map_err(Error::wrap)?;
    let mut owners = OWNERS
        .get_or_init(Mutex::default)
        .lock()
        .map_err(|_| Error::string("owner lock cache is unavailable"))?;
    owners.retain(|_, owner| owner.strong_count() > 0);
    let key = (root.clone(), control.clone());
    if let Some(owner) = owners.get(&key).and_then(Weak::upgrade) {
        if owner.runtime_claimed.load(Ordering::Acquire) {
            return Err(Error::string(
                "tenant root is owned by another running process",
            ));
        }
        return Ok(RootLock {
            owner,
            runtime_claimed: false,
        });
    }
    let tenant_file = File::create(root.join(".owner.lock")).map_err(Error::wrap)?;
    tenant_file
        .try_lock()
        .map_err(|_| Error::string("tenant root is owned by another running process"))?;
    let mut lock_name = control.as_os_str().to_os_string();
    lock_name.push(".owner.lock");
    let control_file = File::create(PathBuf::from(lock_name)).map_err(Error::wrap)?;
    control_file
        .try_lock()
        .map_err(|_| Error::string("control database is owned by another running process"))?;
    let owner = Arc::new(RootOwner {
        _tenant_file: tenant_file,
        _control_file: control_file,
        runtime_claimed: AtomicBool::new(false),
    });
    owners.insert(key, Arc::downgrade(&owner));
    Ok(RootLock {
        owner,
        runtime_claimed: false,
    })
}

struct PendingStore(ObjectStore);

/// Runs for every CLI command: validates settings, loads Credseal credentials
/// and builds the object store, and replaces the control pool with FULL
/// connections. `store` is `None` in the application, which uses R2.
pub async fn prepare(mut ctx: AppContext, store: Option<ObjectStore>) -> Result<AppContext> {
    let settings = Settings::from_context(&ctx)?;
    let owner = acquire_owner(&ctx, &settings).await?;
    ctx.shared_store.insert(PendingRootLock(owner));
    let store = match store {
        Some(store) => store,
        None => {
            let credentials =
                Credentials::load(&settings.credentials_file, &ctx.environment.to_string())?;
            let store = ObjectStore::r2(
                &credentials.r2,
                &settings.storage.prefix,
                Duration::from_secs(30),
            )
            .map_err(|error| Error::string(&format!("object store: {error}")))?;
            ctx.shared_store.insert(Arc::new(credentials));
            store
        }
    };
    ctx.db = connect_control(&ctx).await?;
    check_sqlite(&ctx.db, settings.min_sqlite_version()).await?;
    ctx.shared_store.insert(PendingStore(store));
    Ok(ctx)
}

/// Runs once when the application boots: takes the tenant root lock and
/// constructs the single tenant registry and the runtime.
pub fn start_runtime(ctx: &AppContext) -> Result<()> {
    if ctx.shared_store.contains::<Arc<Runtime>>() {
        return Err(Error::string("runtime is already started"));
    }
    let settings = Settings::from_context(ctx)?;
    let store = ctx
        .shared_store
        .remove::<PendingStore>()
        .ok_or_else(|| Error::string("object store was not prepared"))?
        .0;
    let owner = claim_operation(ctx)?;

    let mut config = settings.tenants.to_config(&ctx.config.database);
    config.synchronous = Synchronous::Full;
    config.run_on_start = Some(crate::error_retention::TENANT_RUN_ON_START.to_owned());
    let registry = tenant_sqlite_loco::Registry::new(config, |db| {
        Box::pin(async move {
            crate::error_retention::initialize_tenant(db).await?;
            loco_rs::db::migrate::<OrgMigrator>(db).await
        })
    })
    .map_err(Error::wrap)?;
    let tenants = TenantPools::from_registry(Arc::new(registry));
    let password_policy = match ctx
        .shared_store
        .get::<Arc<crate::password_policy::PasswordPolicy>>()
    {
        Some(policy) => policy,
        None => Arc::new(crate::password_policy::PasswordPolicy::new()?),
    };
    let credentials = ctx
        .shared_store
        .get::<Arc<crate::credentials::Credentials>>()
        .ok_or_else(|| Error::string("typed credentials are not installed"))?;
    let pending_cipher =
        crate::logs::pending::PendingCipher::from_base64(&credentials.security.data_key)
            .map_err(|error| Error::string(&error.to_string()))?;
    let runtime = Runtime::new(
        settings,
        ctx.db.clone(),
        tenants,
        store,
        owner,
        password_policy,
        pending_cipher,
    );
    runtime
        .disk
        .refresh()
        .map_err(|_| Error::string("local storage scan failed"))?;
    let oauth =
        crate::agent_access::OAuthService::new(ctx.db.clone(), runtime.settings.oauth.clone())
            .map_err(Error::string)?;
    ctx.shared_store.insert(oauth);
    let runtime = Arc::new(runtime);
    crate::services::Services::install(ctx, &runtime)?;
    ctx.shared_store.insert(runtime);
    Ok(())
}

pub(crate) fn claim_operation(ctx: &AppContext) -> Result<RootLock> {
    let mut owner = ctx
        .shared_store
        .remove::<PendingRootLock>()
        .ok_or_else(|| Error::string("database ownership was not prepared"))?
        .0;
    owner
        .owner
        .runtime_claimed
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .map_err(|_| Error::string("tenant root is owned by another running process"))?;
    owner.runtime_claimed = true;

    Ok(owner)
}

async fn connect_control(ctx: &AppContext) -> Result<sea_orm::DatabaseConnection> {
    let database = &ctx.config.database;
    let mut options = ConnectOptions::new(&database.uri);
    options
        .max_connections(database.max_connections)
        .min_connections(database.min_connections)
        .connect_timeout(Duration::from_millis(database.connect_timeout))
        .idle_timeout(Duration::from_millis(database.idle_timeout))
        .sqlx_logging(false)
        .map_sqlx_sqlite_opts(|options| {
            options
                .journal_mode(SqliteJournalMode::Wal)
                .synchronous(SqliteSynchronous::Full)
                .foreign_keys(true)
                .busy_timeout(Duration::from_secs(5))
        });
    let db = Database::connect(options).await.map_err(Error::wrap)?;
    ctx.db.close_by_ref().await.map_err(Error::wrap)?;
    Ok(db)
}

async fn check_sqlite(db: &sea_orm::DatabaseConnection, minimum: &str) -> Result<()> {
    let row = db
        .query_one_raw(sql("SELECT sqlite_version() AS version", vec![]))
        .await
        .map_err(Error::wrap)?
        .ok_or_else(|| Error::string("sqlite_version() returned no row"))?;
    let version: String = row.try_get("", "version").map_err(Error::wrap)?;
    let parse = |v: &str| {
        v.split('.')
            .map(|p| p.parse::<u32>().unwrap_or(0))
            .collect::<Vec<_>>()
    };
    if parse(&version) < parse(minimum) {
        return Err(Error::string(&format!(
            "SQLite {version} is older than the required {minimum}"
        )));
    }
    Ok(())
}

async fn gate(State(rt): State<Arc<Runtime>>, request: Request, next: Next) -> Response {
    if !matches!(
        *request.method(),
        axum::http::Method::GET | axum::http::Method::HEAD | axum::http::Method::OPTIONS
    ) && !rt.disk.permits_write()
    {
        return ApiError::Unavailable("local_storage_pressure").into_response();
    }
    let Some(guard) = rt.gate.enter() else {
        return ApiError::Unavailable(if rt.gate.is_open() {
            "server_overloaded"
        } else {
            "shutting_down"
        })
        .into_response();
    };
    let method = request.method().clone();
    let path = request.uri().path().to_owned();
    let started = std::time::Instant::now();
    let timeout = Duration::from_millis(rt.settings.lifecycle.request_timeout_ms);
    let response = match tokio::time::timeout(timeout, next.run(request)).await {
        Ok(response) => response,
        Err(_) => ApiError::Unavailable("request_timeout").into_response(),
    };
    tracing::info!(%method, %path, status = response.status().as_u16(), ms = started.elapsed().as_millis() as u64, "request");
    drop(guard);
    response
}

pub fn start_background(rt: &Arc<Runtime>) {
    let deleting = rt.clone();
    rt.spawn_background(async move {
        deleting
            .organization_lifecycle
            .run(deleting.cancel.clone(), deleting.gate.clone())
            .await;
    });
    let orphans = rt.clone();
    rt.spawn_background(async move {
        orphans
            .orphan_retention
            .run(orphans.cancel.clone(), orphans.gate.clone())
            .await;
    });
    rt.spawn_background(crate::disk::monitor(rt.clone()));
    let retention = rt.clone();
    rt.spawn_background(async move {
        retention
            .error_retention
            .run(retention.cancel.clone(), retention.gate.clone())
            .await;
    });
    rt.spawn_background(crate::logs::storage::run(rt.clone()));
    rt.spawn_background(crate::logs::retention::sweep_loop(rt.clone()));
    let repair = rt.clone();
    rt.spawn_background(async move {
        loop {
            let orgs = tokio::select! {
                () = repair.cancel.cancelled() => return,
                orgs = repair.next_dirty() => orgs,
            };
            for org in orgs {
                if let Err(error) = repair.quotas.ensure_ready(&repair, &org).await {
                    tracing::warn!(org = %org, %error, "organization readiness repair failed");
                    repair.requeue_dirty(&org);
                    if !matches!(
                        error,
                        crate::error::ApiError::Unavailable(
                            "reconciling" | "org_cache_overloaded" | "log_restore_pending"
                        )
                    ) {
                        tokio::select! {
                            () = repair.cancel.cancelled() => return,
                            () = tokio::time::sleep(Duration::from_secs(5)) => {}
                        }
                    }
                }
            }
            tokio::select! {
                () = repair.cancel.cancelled() => return,
                () = tokio::time::sleep(Duration::from_millis(100)) => {}
            }
        }
    });
    let boot = rt.clone();
    rt.spawn_background(async move {
        let mut after = None;
        loop {
            let orgs = tokio::select! {
                () = boot.cancel.cancelled() => return,
                result = crate::identity::orgs::page_ids(&boot, after.as_ref(), 200) => match result {
                    Ok(orgs) => orgs,
                    Err(error) => {
                        tracing::error!(%error, "startup readiness could not list organizations");
                        tokio::select! {
                            () = boot.cancel.cancelled() => return,
                            () = tokio::time::sleep(Duration::from_secs(5)) => {}
                        }
                        continue;
                    }
                }
            };
            let complete = orgs.len() < 200;
            after = orgs.last().cloned();
            for org in orgs {
                let result = tokio::select! {
                    () = boot.cancel.cancelled() => return,
                    result = boot.quotas.ensure_ready(&boot, &org) => result,
                };
                if let Err(error) = result {
                    tracing::warn!(org = %org, %error, "startup readiness failed");
                    boot.requeue_dirty(&org);
                }
            }
            if complete {
                return;
            }
            tokio::select! {
                () = boot.cancel.cancelled() => return,
                () = tokio::time::sleep(Duration::from_millis(100)) => {}
            }
        }
    });
}

pub fn app_routes() -> AppRoutes {
    AppRoutes::empty()
        .add_route(controllers::health::routes())
        .add_route(controllers::auth::routes())
        .add_route(controllers::orgs::routes())
        .add_route(controllers::billing::routes())
        .add_route(controllers::issues::routes())
        .add_route(controllers::diagnostics::routes())
        .add_route(controllers::logs::routes())
        .add_route(controllers::ingest::routes())
        .add_route(crate::web::routes())
        .add_route(controllers::release_artifacts::routes())
        .add_route(controllers::api_keys::routes())
}

pub async fn install_routes(router: axum::Router, ctx: &AppContext) -> Result<axum::Router> {
    let rt = Runtime::get(ctx);
    let deleting = rt
        .control
        .query_all_raw(sql(
            "SELECT id FROM organizations WHERE lifecycle = 'deleting' ORDER BY id LIMIT 16385",
            vec![],
        ))
        .await
        .map_err(Error::wrap)?;
    if deleting.len() > 16_384 {
        return Err(Error::string(
            "organization deletion write barriers exceed capacity",
        ));
    }
    for row in deleting {
        let stored: String = row.try_get("", "id").map_err(Error::wrap)?;
        let org = stored
            .parse()
            .map_err(|()| Error::string("stored deleting organization id is invalid"))?;
        rt.store.block_org_writes(&org).map_err(|_| {
            Error::string("organization deletion write barrier could not be restored")
        })?;
    }
    crate::backup_sets::raise_restored_id_floors(&rt)
        .await
        .map_err(|error| Error::string(&format!("restored id floor: {error}")))?;
    start_background(&rt);
    let services = crate::services::Services::get(ctx);
    rt.spawn_background(services.backups.clone().run(rt.clone()));
    rt.spawn_background(crate::services::notification_loop(
        rt.clone(),
        services.notifications.clone(),
        services.oauth.clone(),
    ));
    let router = controllers::ingest::with_trailing_slash(router, ctx);
    let router = router.merge(
        crate::mcp::routes(rt.clone(), services.oauth.clone(), services.reports.clone())
            .map_err(Error::string)?,
    );
    let router = crate::web::install(router)?;
    let redirects = rt.settings.host_redirects.clone();
    let router = router.layer(axum::middleware::from_fn_with_state(rt, gate));
    Ok(crate::host_redirect::install(router, &redirects))
}

pub fn tenant_initializer(ctx: &AppContext) -> Vec<Box<dyn Initializer>> {
    vec![Box::new(TenantInitializer::new(
        Runtime::get(ctx).tenants.clone(),
    ))]
}

#[async_trait]
impl Hooks for App {
    fn init_logger(ctx: &AppContext) -> Result<bool> {
        crate::logging::install(ctx)
    }

    fn app_name() -> &'static str {
        env!("CARGO_CRATE_NAME")
    }

    fn app_version() -> String {
        env!("CARGO_PKG_VERSION").to_owned()
    }

    async fn boot(
        mode: StartMode,
        environment: &Environment,
        config: Config,
    ) -> Result<BootResult> {
        create_app::<Self, ControlMigrator>(mode, environment, config).await
    }

    async fn after_context(ctx: AppContext) -> Result<AppContext> {
        prepare(ctx, None).await
    }

    async fn before_run(ctx: &AppContext) -> Result<()> {
        if !ControlMigrator::get_pending_migrations_read_only(&ctx.db)
            .await?
            .is_empty()
        {
            return Err(Error::string(
                "control migrations pending; run approved control-migrate",
            ));
        }
        start_runtime(ctx)
    }

    async fn initializers(ctx: &AppContext) -> Result<Vec<Box<dyn Initializer>>> {
        Ok(tenant_initializer(ctx))
    }

    fn routes(_ctx: &AppContext) -> AppRoutes {
        app_routes()
    }

    async fn after_routes(router: axum::Router, ctx: &AppContext) -> Result<axum::Router> {
        install_routes(router, ctx).await
    }

    async fn on_shutdown(ctx: &AppContext) {
        Runtime::get(ctx).shutdown().await;
    }

    async fn connect_workers(_ctx: &AppContext, _queue: &Queue) -> Result<()> {
        Ok(())
    }

    fn register_tasks(tasks: &mut Tasks) {
        crate::operations::register(tasks);
    }

    async fn truncate(_ctx: &AppContext) -> Result<()> {
        Ok(())
    }

    async fn seed(_ctx: &AppContext, _base: &Path) -> Result<()> {
        Ok(())
    }
}
