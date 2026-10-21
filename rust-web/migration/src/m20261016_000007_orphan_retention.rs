use sea_orm_migration::prelude::*;

#[derive(DeriveMigrationName)]
pub struct Migration;

#[async_trait::async_trait]
impl MigrationTrait for Migration {
    async fn up(&self, manager: &SchemaManager) -> Result<(), DbErr> {
        manager
            .get_connection()
            .execute_unprepared(
                "CREATE TABLE orphan_scan_cursors (kind TEXT PRIMARY KEY, after_key TEXT) STRICT;
             CREATE INDEX events_payload_key ON events(payload_key);",
            )
            .await?;
        Ok(())
    }

    async fn down(&self, manager: &SchemaManager) -> Result<(), DbErr> {
        manager
            .get_connection()
            .execute_unprepared("DROP INDEX events_payload_key; DROP TABLE orphan_scan_cursors;")
            .await?;
        Ok(())
    }
}
