use sea_orm_migration::prelude::*;

#[derive(DeriveMigrationName)]
pub struct Migration;

const TABLES: &str = r"
CREATE TABLE IF NOT EXISTS account_tokens (
    id INTEGER PRIMARY KEY,
    token_hash BLOB NOT NULL UNIQUE,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    purpose TEXT NOT NULL CHECK (purpose IN ('confirm_account', 'change_email', 'reset_password')),
    email TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    consumed_at INTEGER
) STRICT;
CREATE INDEX IF NOT EXISTS account_tokens_user ON account_tokens(user_id, purpose);
CREATE INDEX IF NOT EXISTS account_tokens_expiry ON account_tokens(expires_at);

CREATE TABLE IF NOT EXISTS invitations (
    id INTEGER PRIMARY KEY,
    token_hash BLOB NOT NULL UNIQUE,
    org_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    email TEXT NOT NULL,
    role TEXT NOT NULL CHECK (role IN ('admin', 'member')),
    invited_by INTEGER REFERENCES users(id) ON DELETE SET NULL,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    accepted_at INTEGER,
    accepted_by INTEGER REFERENCES users(id) ON DELETE SET NULL,
    revoked_at INTEGER
) STRICT;
CREATE UNIQUE INDEX IF NOT EXISTS invitations_pending
    ON invitations(org_id, email) WHERE accepted_at IS NULL AND revoked_at IS NULL;
CREATE INDEX IF NOT EXISTS invitations_expiry ON invitations(expires_at);
";

const DOWN: &str = r"
DROP TABLE IF EXISTS invitations;
DROP TABLE IF EXISTS account_tokens;
ALTER TABLE users DROP COLUMN confirmed_at;
ALTER TABLE users DROP COLUMN name;
";

#[async_trait::async_trait]
impl MigrationTrait for Migration {
    async fn up(&self, manager: &SchemaManager) -> Result<(), DbErr> {
        let db = manager.get_connection();
        if !manager.has_column("users", "name").await? {
            db.execute_unprepared("ALTER TABLE users ADD COLUMN name TEXT")
                .await?;
        }
        if !manager.has_column("users", "confirmed_at").await? {
            db.execute_unprepared("ALTER TABLE users ADD COLUMN confirmed_at INTEGER")
                .await?;
        }
        db.execute_unprepared(TABLES).await?;
        Ok(())
    }

    async fn down(&self, manager: &SchemaManager) -> Result<(), DbErr> {
        manager.get_connection().execute_unprepared(DOWN).await?;
        Ok(())
    }
}
