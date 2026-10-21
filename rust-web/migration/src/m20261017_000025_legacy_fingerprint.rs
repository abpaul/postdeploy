use sea_orm_migration::prelude::*;

#[derive(DeriveMigrationName)]
pub struct Migration;

const UP: &str = "
ALTER TABLE issues ADD COLUMN legacy_fingerprint TEXT;
CREATE UNIQUE INDEX issues_legacy_fingerprint
    ON issues(project_id, environment, legacy_fingerprint) WHERE legacy_fingerprint IS NOT NULL;
";

const DOWN: &str = "
DROP INDEX issues_legacy_fingerprint;
ALTER TABLE issues DROP COLUMN legacy_fingerprint;
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
