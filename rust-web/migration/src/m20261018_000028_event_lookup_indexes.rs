use sea_orm_migration::prelude::*;

#[derive(DeriveMigrationName)]
pub struct Migration;

const UP: &str = r"
CREATE INDEX events_issue_occurred ON events(issue_id, occurred_at);
CREATE INDEX events_issue_event ON events(issue_id, event_id, received_at);
";

const DOWN: &str = r"
DROP INDEX events_issue_event;
DROP INDEX events_issue_occurred;
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
