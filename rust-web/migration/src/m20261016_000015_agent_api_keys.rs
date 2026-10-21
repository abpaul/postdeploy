use sea_orm_migration::prelude::*;

#[derive(DeriveMigrationName)]
pub struct Migration;

const UP: &str = r"
CREATE TABLE IF NOT EXISTS agent_api_keys (
    id INTEGER PRIMARY KEY,
    org_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    key_hash BLOB NOT NULL UNIQUE CHECK (length(key_hash) = 32),
    hint TEXT NOT NULL,
    scopes TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL CHECK (expires_at > created_at),
    revoked_at INTEGER
) STRICT;
CREATE INDEX IF NOT EXISTS agent_api_keys_org ON agent_api_keys(org_id, id);
CREATE INDEX IF NOT EXISTS agent_api_keys_user ON agent_api_keys(user_id);
";

const DOWN: &str = "DROP TABLE IF EXISTS agent_api_keys;";

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
