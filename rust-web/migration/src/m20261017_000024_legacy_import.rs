use sea_orm_migration::prelude::*;

#[derive(DeriveMigrationName)]
pub struct Migration;

const UP: &str = "
CREATE TABLE legacy_import_runs (
    source TEXT PRIMARY KEY,
    manifest_sha256 TEXT NOT NULL,
    snapshot_at INTEGER NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('importing', 'complete')),
    completed_at INTEGER
) STRICT;
CREATE TABLE legacy_billing_imports (
    org_id TEXT PRIMARY KEY REFERENCES organizations(id) ON DELETE CASCADE,
    source TEXT NOT NULL,
    stripe_customer_id TEXT NOT NULL,
    stripe_subscription_id TEXT NOT NULL,
    paid_until INTEGER NOT NULL,
    imported_at INTEGER NOT NULL
) STRICT;
";

const DOWN: &str = "
DROP TABLE legacy_billing_imports;
DROP TABLE legacy_import_runs;
";

#[async_trait::async_trait]
impl MigrationTrait for Migration {
    fn use_transaction(&self) -> Option<bool> {
        Some(true)
    }

    async fn up(&self, manager: &SchemaManager) -> Result<(), DbErr> {
        manager.get_connection().execute_unprepared(UP).await?;
        Ok(())
    }

    async fn down(&self, manager: &SchemaManager) -> Result<(), DbErr> {
        manager.get_connection().execute_unprepared(DOWN).await?;
        Ok(())
    }
}
