use sea_orm_migration::prelude::*;

#[derive(DeriveMigrationName)]
pub struct Migration;

const UP: &str = r"
CREATE TABLE ingest_outcomes_daily (
    day TEXT NOT NULL,
    category TEXT NOT NULL CHECK (category IN ('error', 'log', 'other')),
    outcome TEXT NOT NULL
        CHECK (outcome IN ('accepted', 'duplicate', 'filtered', 'sampled', 'unsupported', 'invalid')),
    reason TEXT NOT NULL,
    count INTEGER NOT NULL CHECK (count > 0),
    PRIMARY KEY (day, category, reason)
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
            .execute_unprepared("DROP TABLE ingest_outcomes_daily;")
            .await?;
        Ok(())
    }
}
