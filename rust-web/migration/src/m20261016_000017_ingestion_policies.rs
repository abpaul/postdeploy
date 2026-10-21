use sea_orm_migration::prelude::*;

#[derive(DeriveMigrationName)]
pub struct Migration;

const UP: &str = r"
CREATE TABLE ingestion_policies (
    org_id TEXT PRIMARY KEY REFERENCES organizations(id) ON DELETE CASCADE,
    policy TEXT NOT NULL CHECK (json_valid(policy)),
    updated_at INTEGER NOT NULL,
    updated_by INTEGER NOT NULL
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
            .execute_unprepared("DROP TABLE ingestion_policies;")
            .await?;
        Ok(())
    }
}
