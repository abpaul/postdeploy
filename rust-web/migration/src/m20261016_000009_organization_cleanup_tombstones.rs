use sea_orm_migration::{
    prelude::*,
    sea_orm::{DbBackend, Statement},
};

#[derive(DeriveMigrationName)]
pub struct Migration;

#[async_trait::async_trait]
impl MigrationTrait for Migration {
    fn use_transaction(&self) -> Option<bool> {
        Some(true)
    }

    async fn up(&self, manager: &SchemaManager) -> Result<(), DbErr> {
        let db = manager.get_connection();
        let source = columns(db, "organization_deletions").await?;
        let has_attempted = source.iter().any(|name| name == "attempted_at");
        let mut expected_source = vec![
            "after_key",
            "org_id",
            "phase",
            "requested_at",
            "requested_by",
        ];
        if has_attempted {
            expected_source.push("attempted_at");
        }
        expected_source.sort_unstable();
        if source != expected_source {
            return Err(DbErr::Custom(
                "unexpected organization deletion source schema".into(),
            ));
        }
        if manager.has_table("organization_cleanup").await? {
            let expected = [
                "after_key",
                "attempted_at",
                "local_removed",
                "org_id",
                "phase",
                "requested_at",
            ];
            if columns(db, "organization_cleanup").await? != expected {
                return Err(DbErr::Custom(
                    "unexpected organization cleanup recovery schema".into(),
                ));
            }
            let count = db
                .query_one_raw(Statement::from_string(
                    DbBackend::Sqlite,
                    "SELECT COUNT(*) AS n FROM organization_cleanup",
                ))
                .await?
                .ok_or_else(|| DbErr::Custom("organization cleanup recovery count missing".into()))?
                .try_get::<i64>("", "n")?;
            if count != 0 {
                return Err(DbErr::Custom(
                    "organization cleanup recovery table is not empty".into(),
                ));
            }
        }
        db.execute_unprepared(
            "CREATE TABLE IF NOT EXISTS organization_cleanup (
                 org_id TEXT PRIMARY KEY,
                 requested_at INTEGER NOT NULL,
                 attempted_at INTEGER NOT NULL DEFAULT 0,
                 phase INTEGER NOT NULL DEFAULT 0 CHECK (phase BETWEEN 0 AND 5),
                 after_key TEXT,
                 local_removed INTEGER NOT NULL DEFAULT 0 CHECK (local_removed IN (0, 1))
             ) STRICT;",
        )
        .await?;
        let attempted = if has_attempted { "attempted_at" } else { "0" };
        db.execute_unprepared(&format!(
            "INSERT INTO organization_cleanup (org_id, requested_at, attempted_at, phase, after_key)
                 SELECT org_id, requested_at, {attempted}, phase, after_key FROM organization_deletions;
             DROP TABLE organization_deletions;
             ALTER TABLE organization_cleanup RENAME TO organization_deletions;
             CREATE INDEX organization_deletions_schedule
                 ON organization_deletions(attempted_at, requested_at, org_id);"
        )).await?;
        Ok(())
    }

    async fn down(&self, _manager: &SchemaManager) -> Result<(), DbErr> {
        Err(DbErr::Custom(
            "organization cleanup tombstones cannot be discarded by rollback".into(),
        ))
    }
}

async fn columns(db: &SchemaManagerConnection<'_>, table: &str) -> Result<Vec<String>, DbErr> {
    let rows = db
        .query_all_raw(Statement::from_string(
            DbBackend::Sqlite,
            format!("PRAGMA table_info({table})"),
        ))
        .await?;
    let mut names = rows
        .iter()
        .map(|row| row.try_get::<String>("", "name"))
        .collect::<Result<Vec<_>, _>>()?;
    names.sort_unstable();
    Ok(names)
}
