//! Test harness. Each test gets its own control database, tenant root and
//! object store prefix under a preserved run directory. The in-memory store is
//! selected only by `TestApp`, never by the application hooks.

use std::{
    collections::HashMap,
    net::SocketAddr,
    path::{Path, PathBuf},
    sync::{Arc, Mutex, OnceLock},
    time::Duration,
};

use async_trait::async_trait;
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
use migration::ControlMigrator;

use crate::{
    app::{self, App},
    settings::Settings,
    store::{Faults, ObjectStore},
};

static STORES: OnceLock<Mutex<HashMap<PathBuf, ObjectStore>>> = OnceLock::new();
static STRIPE: OnceLock<Mutex<HashMap<PathBuf, serde_json::Value>>> = OnceLock::new();

fn stripe_fixtures() -> &'static Mutex<HashMap<PathBuf, serde_json::Value>> {
    STRIPE.get_or_init(Mutex::default)
}

fn stores() -> &'static Mutex<HashMap<PathBuf, ObjectStore>> {
    STORES.get_or_init(Mutex::default)
}

/// Hooks identical to [`App`] except that the object store is the explicit
/// in-memory store registered for this test's tenant root.
pub struct TestApp;

struct CleanBreachChecker;

#[async_trait]
impl crate::password_policy::BreachChecker for CleanBreachChecker {
    async fn pwned(
        &self,
        _prefix: &str,
        _suffix: &str,
    ) -> std::result::Result<bool, crate::password_policy::BreachUnavailable> {
        Ok(false)
    }
}

#[async_trait]
impl Hooks for TestApp {
    fn app_name() -> &'static str {
        App::app_name()
    }

    fn app_version() -> String {
        App::app_version()
    }

    async fn boot(
        mode: StartMode,
        environment: &Environment,
        config: Config,
    ) -> Result<BootResult> {
        create_app::<Self, ControlMigrator>(mode, environment, config).await
    }

    async fn after_context(ctx: AppContext) -> Result<AppContext> {
        ctx.shared_store.insert(Arc::new(
            crate::password_policy::PasswordPolicy::with_checker(Arc::new(CleanBreachChecker)),
        ));
        use base64::Engine as _;
        use serde::Deserialize as _;
        let secret = |value: &str| {
            credseal::SecretString::deserialize(serde::de::value::StrDeserializer::<
                serde::de::value::Error,
            >::new(value))
            .expect("isolated fixture secret")
        };
        let settings = Settings::from_context(&ctx)?;
        let stripe = stripe_fixtures()
            .lock()
            .expect("stripe fixture registry")
            .get(&settings.tenants.root)
            .cloned()
            .map(serde_json::from_value)
            .transpose()
            .map_err(|error| Error::string(&format!("stripe test fixture: {error}")))?;
        ctx.shared_store
            .insert(Arc::new(crate::credentials::Credentials {
                r2: crate::credentials::R2Credentials {
                    endpoint: "https://00000000000000000000000000000000.r2.cloudflarestorage.com"
                        .into(),
                    bucket: "explicit-memory-test".into(),
                    access_key_id: secret("isolated-memory-fixture"),
                    secret_access_key: secret("isolated-memory-fixture"),
                },
                security: crate::credentials::Security {
                    data_key: secret(&base64::engine::general_purpose::STANDARD.encode([7; 32])),
                },
                smtp: None,
                turnstile: None,
                stripe,
            }));
        let store = stores()
            .lock()
            .expect("store registry")
            .get(&settings.tenants.root)
            .cloned()
            .ok_or_else(|| Error::string("no test store registered for this tenant root"))?;
        app::prepare(ctx, Some(store)).await
    }

    async fn before_run(ctx: &AppContext) -> Result<()> {
        App::before_run(ctx).await
    }

    async fn initializers(ctx: &AppContext) -> Result<Vec<Box<dyn Initializer>>> {
        Ok(app::tenant_initializer(ctx))
    }

    fn routes(_ctx: &AppContext) -> AppRoutes {
        app::app_routes()
    }

    async fn after_routes(router: axum::Router, ctx: &AppContext) -> Result<axum::Router> {
        app::install_routes(router, ctx).await
    }

    async fn on_shutdown(ctx: &AppContext) {
        App::on_shutdown(ctx).await;
    }

    async fn connect_workers(_ctx: &AppContext, _queue: &Queue) -> Result<()> {
        Ok(())
    }

    fn register_tasks(_tasks: &mut Tasks) {}

    async fn truncate(_ctx: &AppContext) -> Result<()> {
        Ok(())
    }

    async fn seed(_ctx: &AppContext, _base: &Path) -> Result<()> {
        Ok(())
    }
}

/// The directory of this test run: `POSTDEPLOY_TEST_ROOT`/`POSTDEPLOY_TEST_RUN`.
pub fn run_dir() -> &'static PathBuf {
    static RUN: OnceLock<PathBuf> = OnceLock::new();
    RUN.get_or_init(|| {
        let base = std::env::var_os("POSTDEPLOY_TEST_ROOT")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                Path::new(env!("CARGO_MANIFEST_DIR")).join("../../.audit/postdeploy-rust/test-runs")
            });
        let run = std::env::var("POSTDEPLOY_TEST_RUN").unwrap_or_else(|_| {
            format!(
                "{}-{}",
                chrono::Utc::now().format("%Y%m%dT%H%M%SZ"),
                std::process::id()
            )
        });
        base.join(run)
    })
}

/// One isolated test environment. Files are preserved after the test.
pub struct TestEnv {
    pub name: String,
    pub dir: PathBuf,
    pub faults: Arc<Faults>,
    pub store: ObjectStore,
}

impl TestEnv {
    pub fn new(name: &str) -> Self {
        let dir = run_dir().join(name);
        std::fs::create_dir_all(&dir).expect("create test directory");
        let dir = dir.canonicalize().expect("canonical test directory");
        let faults = Arc::new(Faults::default());
        let store = ObjectStore::memory(
            &format!("test/{name}/"),
            Duration::from_secs(10),
            faults.clone(),
        )
        .expect("memory store");
        stores()
            .lock()
            .expect("store registry")
            .insert(dir.join("tenants"), store.clone());
        Self {
            name: name.to_owned(),
            dir,
            faults,
            store,
        }
    }

    /// Supplies `[stripe]` test credentials to applications booted from this
    /// environment. Pair it with `settings.billing.api_base` of a local fake.
    pub fn with_stripe(&self, credentials: serde_json::Value) {
        stripe_fixtures()
            .lock()
            .expect("stripe fixture registry")
            .insert(self.tenant_root(), credentials);
    }

    pub fn tenant_root(&self) -> PathBuf {
        self.dir.join("tenants")
    }

    /// Test configuration pointed at this environment. `settings` receives the
    /// JSON `settings` block for test-specific limits.
    pub async fn config(
        &self,
        prefix: &str,
        settings: impl FnOnce(&mut serde_json::Value),
    ) -> Config {
        let mut config = App::load_config(&Environment::Test)
            .await
            .expect("test config");
        config.database.uri = format!(
            "sqlite://{}?mode=rwc",
            self.dir.join("control.sqlite").display()
        );
        let block = config.settings.get_or_insert_with(|| serde_json::json!({}));
        block["tenants"]["root"] = serde_json::json!(self.tenant_root());
        block["storage"]["prefix"] = serde_json::json!(prefix);
        settings(block);
        config
    }

    pub async fn boot_memory(
        &self,
        settings: impl FnOnce(&mut serde_json::Value),
    ) -> Result<BootResult> {
        let config = self.config(&format!("test/{}/", self.name), settings).await;
        TestApp::boot(StartMode::ServerOnly, &Environment::Test, config).await
    }

    /// Boots the production hooks against real R2. Requires `CREDSEAL_MASTER_KEY`
    /// and `POSTDEPLOY_CREDENTIALS_FILE` in the process environment.
    pub async fn boot_r2(
        &self,
        prefix: &str,
        settings: impl FnOnce(&mut serde_json::Value),
    ) -> Result<BootResult> {
        let config = self.config(prefix, settings).await;
        App::boot(StartMode::ServerOnly, &Environment::Test, config).await
    }
}

/// Serves a booted router on an ephemeral loopback port.
pub async fn serve(boot: &BootResult) -> (String, tokio::task::JoinHandle<()>) {
    let router = boot.router.clone().expect("server router");
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind");
    let addr = listener.local_addr().expect("local addr");
    let handle = tokio::spawn(async move {
        let _ = axum::serve(
            listener,
            router.into_make_service_with_connect_info::<SocketAddr>(),
        )
        .await;
    });
    (format!("http://{addr}"), handle)
}
