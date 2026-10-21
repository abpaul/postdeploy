use sea_orm_migration::prelude::*;

#[derive(DeriveMigrationName)]
pub struct Migration;

const UP: &str = r"
CREATE TABLE IF NOT EXISTS oauth_clients (
    id TEXT PRIMARY KEY,
    name TEXT,
    redirect_uris TEXT NOT NULL,
    scopes TEXT NOT NULL,
    created_at INTEGER NOT NULL
) STRICT;
CREATE INDEX IF NOT EXISTS oauth_clients_created ON oauth_clients(created_at);

CREATE TABLE IF NOT EXISTS oauth_consents (
    handle_hash BLOB PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    client_id TEXT NOT NULL REFERENCES oauth_clients(id) ON DELETE CASCADE,
    redirect_uri TEXT NOT NULL,
    code_challenge TEXT NOT NULL,
    scopes TEXT NOT NULL,
    state TEXT,
    resource TEXT NOT NULL,
    expires_at INTEGER NOT NULL
) STRICT;
CREATE INDEX IF NOT EXISTS oauth_consents_expiry ON oauth_consents(expires_at);
CREATE INDEX IF NOT EXISTS oauth_consents_client ON oauth_consents(client_id);
CREATE INDEX IF NOT EXISTS oauth_consents_user ON oauth_consents(user_id);

CREATE TABLE IF NOT EXISTS oauth_grants (
    id INTEGER PRIMARY KEY,
    client_id TEXT NOT NULL REFERENCES oauth_clients(id) ON DELETE CASCADE,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    org_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    scopes TEXT NOT NULL,
    resource TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    revoked_at INTEGER
) STRICT;
CREATE INDEX IF NOT EXISTS oauth_grants_client ON oauth_grants(client_id);
CREATE INDEX IF NOT EXISTS oauth_grants_user ON oauth_grants(user_id);
CREATE INDEX IF NOT EXISTS oauth_grants_org ON oauth_grants(org_id);

CREATE TABLE IF NOT EXISTS oauth_codes (
    code_hash BLOB PRIMARY KEY,
    client_id TEXT NOT NULL REFERENCES oauth_clients(id) ON DELETE CASCADE,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    org_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    redirect_uri TEXT NOT NULL,
    code_challenge TEXT NOT NULL,
    scopes TEXT NOT NULL,
    resource TEXT NOT NULL,
    expires_at INTEGER NOT NULL,
    grant_id INTEGER
) STRICT;
CREATE INDEX IF NOT EXISTS oauth_codes_expiry ON oauth_codes(expires_at);
CREATE INDEX IF NOT EXISTS oauth_codes_client ON oauth_codes(client_id);
CREATE INDEX IF NOT EXISTS oauth_codes_user ON oauth_codes(user_id);
CREATE INDEX IF NOT EXISTS oauth_codes_org ON oauth_codes(org_id);

CREATE TABLE IF NOT EXISTS oauth_tokens (
    token_hash BLOB PRIMARY KEY,
    grant_id INTEGER NOT NULL REFERENCES oauth_grants(id) ON DELETE CASCADE,
    kind TEXT NOT NULL CHECK (kind IN ('access', 'refresh')),
    expires_at INTEGER NOT NULL,
    rotated_at INTEGER
) STRICT;
CREATE INDEX IF NOT EXISTS oauth_tokens_grant ON oauth_tokens(grant_id);
CREATE INDEX IF NOT EXISTS oauth_tokens_expiry ON oauth_tokens(expires_at);
";

const DOWN: &str = r"
DROP TABLE IF EXISTS oauth_tokens;
DROP TABLE IF EXISTS oauth_codes;
DROP TABLE IF EXISTS oauth_grants;
DROP TABLE IF EXISTS oauth_consents;
DROP TABLE IF EXISTS oauth_clients;
";

#[async_trait::async_trait]
impl MigrationTrait for Migration {
    async fn up(&self, manager: &SchemaManager) -> Result<(), DbErr> {
        manager.get_connection().execute_unprepared(UP).await?;
        Ok(())
    }

    async fn down(&self, manager: &SchemaManager) -> Result<(), DbErr> {
        manager.get_connection().execute_unprepared(DOWN).await?;
        Ok(())
    }
}
