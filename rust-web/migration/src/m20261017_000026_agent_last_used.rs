use sea_orm_migration::prelude::*;

#[derive(DeriveMigrationName)]
pub struct Migration;

const UP: &str = "
ALTER TABLE oauth_grants ADD COLUMN last_used_at INTEGER;
ALTER TABLE agent_api_keys ADD COLUMN last_used_at INTEGER;
";

const DOWN: &str = "
ALTER TABLE oauth_grants DROP COLUMN last_used_at;
ALTER TABLE agent_api_keys DROP COLUMN last_used_at;
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
