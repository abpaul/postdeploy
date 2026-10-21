use sea_orm_migration::prelude::*;

#[derive(DeriveMigrationName)]
pub struct Migration;

const UP: &str = r"
CREATE TABLE trial_notices (
    org_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    notice TEXT NOT NULL CHECK (notice IN ('ends_soon', 'ended')),
    state TEXT NOT NULL CHECK (state IN ('pending', 'delivered', 'failed', 'not_configured')),
    attempts INTEGER NOT NULL,
    next_attempt_at INTEGER NOT NULL,
    finished_at INTEGER,
    PRIMARY KEY (org_id, notice)
) STRICT;
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
        manager
            .get_connection()
            .execute_unprepared("DROP TABLE trial_notices;")
            .await?;
        Ok(())
    }
}
