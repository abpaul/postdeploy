use sea_orm_migration::prelude::*;

#[derive(DeriveMigrationName)]
pub struct Migration;

const UP: &str = "
CREATE TRIGGER IF NOT EXISTS agent_api_keys_active_organization BEFORE INSERT ON agent_api_keys
WHEN NOT EXISTS (SELECT 1 FROM organizations WHERE id = NEW.org_id AND lifecycle = 'active')
BEGIN SELECT RAISE(ABORT, 'organization unavailable'); END;
";

const DOWN: &str = "DROP TRIGGER IF EXISTS agent_api_keys_active_organization;";

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
