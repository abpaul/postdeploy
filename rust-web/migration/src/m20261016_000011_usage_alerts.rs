use sea_orm_migration::prelude::*;

#[derive(DeriveMigrationName)]
pub struct Migration;

const UP: &str = r"
CREATE TABLE usage_alerts (
    month TEXT NOT NULL,
    metric TEXT NOT NULL CHECK (metric IN ('errors', 'log_bytes')),
    percent INTEGER NOT NULL CHECK (percent IN (70, 90, 100)),
    reached_at INTEGER NOT NULL,
    state TEXT NOT NULL DEFAULT 'pending'
        CHECK (state IN ('pending', 'delivered', 'failed', 'not_configured')),
    attempts INTEGER NOT NULL DEFAULT 0,
    next_attempt_at INTEGER NOT NULL,
    finished_at INTEGER,
    PRIMARY KEY (month, metric, percent)
) STRICT;
CREATE INDEX usage_alerts_due ON usage_alerts(state, next_attempt_at);
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
            .execute_unprepared("DROP TABLE usage_alerts;")
            .await?;
        Ok(())
    }
}
