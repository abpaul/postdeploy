use sea_orm_migration::prelude::*;

#[derive(DeriveMigrationName)]
pub struct Migration;

const UP: &str = "
CREATE INDEX log_entry_runs_source ON log_entry_runs(project_id, source_id);
CREATE INDEX log_objects_source ON log_objects(project_id, source_id);
";

const DOWN: &str = "
DROP INDEX log_objects_source;
DROP INDEX log_entry_runs_source;
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
