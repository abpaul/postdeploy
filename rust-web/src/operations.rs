use std::{
    path::{Path, PathBuf},
    sync::Arc,
};

use async_trait::async_trait;
use loco_rs::{
    app::AppContext,
    task::{Task, TaskInfo, Tasks, Vars},
    Error, Result,
};
use sea_orm::ConnectionTrait;

use crate::{
    backup_sets::{Cycle, SetId},
    runtime::Runtime,
    services::Services,
};

pub fn register(tasks: &mut Tasks) {
    tasks.register(Operation::Migrate);
    tasks.register(Operation::Backup);
    tasks.register(Operation::Restore);
    tasks.register(Operation::Sets);
}

enum Operation {
    Migrate,
    Backup,
    Restore,
    Sets,
}

impl Operation {
    async fn execute(&self, ctx: &AppContext, vars: &Vars) -> Result<()> {
        let runtime = Runtime::get(ctx);
        let services = Services::get(ctx);
        match self {
            Self::Backup => {
                reject_unknown(vars, &[])?;
                services
                    .backups
                    .recover(&runtime)
                    .await
                    .map_err(Error::wrap)?;
                let refused = match services.backups.run_once(&runtime).await {
                    Cycle::Complete(manifest) => {
                        let summary = serde_json::json!({
                            "set": manifest.set,
                            "organizations": manifest.organizations.len(),
                            "raw_bytes": manifest.raw_bytes(),
                            "sealed_bytes": manifest.sealed_bytes(),
                        });
                        println!("{summary}");
                        return Ok(());
                    }
                    Cycle::Failed { stage, error } => format!("backup failed at {stage}: {error}"),
                    Cycle::Busy => "backup worker is busy".to_owned(),
                    Cycle::Changed { attempts } => {
                        format!(
                            "control structure changed in {attempts} attempts; no set was written"
                        )
                    }
                };
                return Err(Error::string(&refused));
            }
            Self::Restore => {
                reject_unknown(vars, &["set", "destination"])?;
                let set = SetId::parse(vars.cli_arg("set")?)
                    .ok_or_else(|| Error::string("set must be a backup set id"))?;
                let destination =
                    offline_destination(&runtime, Path::new(vars.cli_arg("destination")?)).await?;
                let report = services
                    .backups
                    .restore(&runtime, set, &destination)
                    .await
                    .map_err(Error::wrap)?;
                println!("{}", serde_json::to_string(&report).map_err(Error::wrap)?);
            }
            Self::Sets => {
                reject_unknown(vars, &["set"])?;
                if let Some(set) = vars.cli.get("set") {
                    let set = SetId::parse(set)
                        .ok_or_else(|| Error::string("set must be a backup set id"))?;
                    let manifest = services
                        .backups
                        .verify(&runtime, set)
                        .await
                        .map_err(Error::wrap)?;
                    let summary = serde_json::json!({
                        "set": manifest.set,
                        "verified": true,
                        "completed_at_us": manifest.completed_at_us,
                        "control_captured_at_us": manifest.control.captured_at_us,
                        "organizations": manifest.organizations.keys().collect::<Vec<_>>(),
                        "raw_bytes": manifest.raw_bytes(),
                        "sealed_bytes": manifest.sealed_bytes(),
                    });
                    println!("{summary}");
                } else {
                    for listed in services.backups.list(&runtime).await.map_err(Error::wrap)? {
                        println!("{}", serde_json::to_string(&listed).map_err(Error::wrap)?);
                    }
                }
            }
            Self::Migrate => unreachable!(),
        }
        Ok(())
    }
}

#[async_trait]
impl Task for Operation {
    fn task(&self) -> TaskInfo {
        let (name, detail) = match self {
            Self::Migrate => (
                "control-migrate",
                "Migrate the control database while holding the exclusive owner lock",
            ),
            Self::Backup => (
                "backup",
                "Write one complete encrypted backup set while the server is stopped",
            ),
            Self::Restore => (
                "restore",
                "Restore set:<id> destination:<new-offline-directory>",
            ),
            Self::Sets => (
                "backup-sets",
                "List backup sets in R2 newest first, or verify set:<id> without control data",
            ),
        };
        TaskInfo {
            name: name.to_owned(),
            detail: detail.to_owned(),
        }
    }

    async fn run(&self, ctx: &AppContext, vars: &Vars) -> Result<()> {
        if ctx.shared_store.contains::<Arc<Runtime>>() {
            return Err(Error::string(
                "operator tasks require a fresh offline context",
            ));
        }
        if matches!(self, Self::Migrate) {
            reject_unknown(vars, &[])?;
            let _owner = crate::app::claim_operation(ctx)?;
            let result = loco_rs::db::migrate::<migration::ControlMigrator>(&ctx.db).await;
            let closed = ctx.db.close_by_ref().await.map_err(Error::wrap);
            result?;
            closed?;
            println!("control migrations complete");
            return Ok(());
        }
        let runtime = start_offline(ctx).await?;
        let result = self.execute(ctx, vars).await;
        runtime.shutdown().await;
        result
    }
}

async fn start_offline(ctx: &AppContext) -> Result<Arc<Runtime>> {
    if let Err(error) = crate::app::start_runtime(ctx) {
        if let Some(runtime) = ctx.shared_store.get::<Arc<Runtime>>() {
            runtime.shutdown().await;
        } else if let Err(close_error) = ctx.db.close_by_ref().await {
            tracing::error!(%close_error, "operator control database close failed");
        }
        return Err(error);
    }
    Ok(Runtime::get(ctx))
}

fn reject_unknown(vars: &Vars, allowed: &[&str]) -> Result<()> {
    if vars.cli.keys().any(|key| !allowed.contains(&key.as_str())) {
        return Err(Error::string("unknown task argument"));
    }
    Ok(())
}

async fn offline_destination(runtime: &Runtime, destination: &Path) -> Result<PathBuf> {
    let parent = destination
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .ok_or_else(|| Error::string("destination needs an existing parent directory"))?;
    let name = destination
        .file_name()
        .ok_or_else(|| Error::string("destination needs a directory name"))?;
    let parent = parent
        .canonicalize()
        .map_err(|_| Error::string("destination parent must exist"))?;
    let destination = parent.join(name);
    let tenants = runtime
        .settings
        .tenants
        .root
        .canonicalize()
        .map_err(Error::wrap)?;
    let rows = runtime
        .control
        .query_all_raw(crate::runtime::sql("PRAGMA database_list", vec![]))
        .await
        .map_err(Error::wrap)?;
    let control = rows
        .iter()
        .find_map(|row| {
            (row.try_get::<String>("", "name").ok()?.as_str() == "main")
                .then(|| row.try_get::<String>("", "file").ok())
                .flatten()
        })
        .ok_or_else(|| Error::string("control database path is unavailable"))?;
    let control = Path::new(&control).canonicalize().map_err(Error::wrap)?;
    let control_parent = control
        .parent()
        .ok_or_else(|| Error::string("control database needs a parent"))?;
    if destination.starts_with(tenants) || destination.starts_with(control_parent) {
        return Err(Error::string(
            "restore destination must be outside the active tenant and control directories",
        ));
    }
    Ok(destination)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn task_refuses_a_live_context_and_keeps_the_server_available() {
        let env = crate::testing::TestEnv::new("operator-live-context");
        let boot = env.boot_memory(|_| {}).await.unwrap();
        let (base, server) = crate::testing::serve(&boot).await;
        let mut tasks = Tasks::default();
        register(&mut tasks);
        let error = tasks
            .run(&boot.app_context, "backup", &Vars::default())
            .await
            .unwrap_err();
        assert_eq!(
            error.to_string(),
            "operator tasks require a fresh offline context"
        );
        let response = reqwest::get(format!("{base}/healthz")).await.unwrap();
        assert_eq!(response.status(), reqwest::StatusCode::OK);
        assert_eq!(
            response.json::<serde_json::Value>().await.unwrap(),
            serde_json::json!({"status": "ok", "backups": {"state": "ok", "last_complete_age_secs": null}})
        );
        Runtime::get(&boot.app_context).shutdown().await;
        server.abort();
        let _ = server.await;
    }

    #[tokio::test]
    async fn startup_requires_applied_control_migrations_when_automatic_migrations_are_disabled() {
        use loco_rs::{app::Hooks, boot::StartMode, environment::Environment};

        let fresh = crate::testing::TestEnv::new("operator-unmigrated-control");
        let mut config = fresh
            .config("test/operator-unmigrated-control/", |_| {})
            .await;
        config.database.auto_migrate = false;
        let fresh_result =
            crate::testing::TestApp::boot(StartMode::ServerOnly, &Environment::Test, config).await;
        assert!(
            fresh_result.is_err(),
            "fresh control database must not start without migrations"
        );

        let env = crate::testing::TestEnv::new("operator-pending-control-migration");
        let migrated = env.boot_memory(|_| {}).await.unwrap();
        Runtime::get(&migrated.app_context).shutdown().await;
        let control = sea_orm::Database::connect(format!(
            "sqlite://{}?mode=rw",
            env.dir.join("control.sqlite").display()
        ))
        .await
        .unwrap();
        let deleted = control.execute_unprepared(
            "DELETE FROM seaql_migrations WHERE version = (SELECT version FROM seaql_migrations ORDER BY version DESC LIMIT 1)",
        ).await.unwrap();
        assert_eq!(deleted.rows_affected(), 1);
        control.close().await.unwrap();
        let mut config = env
            .config("test/operator-pending-control-migration/", |_| {})
            .await;
        config.database.auto_migrate = false;
        let result =
            crate::testing::TestApp::boot(StartMode::ServerOnly, &Environment::Test, config).await;
        match result {
            Err(error) => println!("pending control migration startup refused: {error}"),
            Ok(boot) => {
                let (base, server) = crate::testing::serve(&boot).await;
                let response = reqwest::get(format!("{base}/healthz")).await.unwrap();
                let status = response.status();
                let body = response.json::<serde_json::Value>().await.unwrap();
                Runtime::get(&boot.app_context).shutdown().await;
                server.abort();
                let _ = server.await;
                panic!("pending control migration startup succeeded; health status={status}, body={body}");
            }
        }
    }
}
