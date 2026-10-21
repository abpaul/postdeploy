use sea_orm_migration::prelude::*;

#[derive(DeriveMigrationName)]
pub struct Migration;

const UP: &str = r"
CREATE TABLE billing_accounts (
    org_id TEXT PRIMARY KEY REFERENCES organizations(id) ON DELETE CASCADE,
    stripe_customer_id TEXT NOT NULL UNIQUE,
    stripe_subscription_id TEXT UNIQUE,
    subscription_status TEXT,
    cancel_at_period_end INTEGER NOT NULL DEFAULT 0 CHECK (cancel_at_period_end IN (0, 1)),
    paid_until INTEGER,
    synced_at INTEGER NOT NULL
) STRICT;

CREATE TABLE billing_checkouts (
    id TEXT PRIMARY KEY,
    org_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    created_at INTEGER NOT NULL,
    session_id TEXT UNIQUE,
    expires_at INTEGER,
    completed_at INTEGER
) STRICT;
CREATE INDEX billing_checkouts_org ON billing_checkouts(org_id, created_at);

CREATE TABLE billing_events (
    event_id TEXT PRIMARY KEY,
    event_type TEXT NOT NULL,
    received_at INTEGER NOT NULL,
    processed_at INTEGER
) STRICT;
CREATE INDEX billing_events_received ON billing_events(received_at);
";

const DOWN: &str = r"
DROP TABLE billing_events;
DROP TABLE billing_checkouts;
DROP TABLE billing_accounts;
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
