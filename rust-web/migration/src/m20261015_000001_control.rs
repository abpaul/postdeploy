use sea_orm_migration::prelude::*;

#[derive(DeriveMigrationName)]
pub struct Migration;

const UP: &str = r"
CREATE TABLE users (
    id INTEGER PRIMARY KEY,
    email TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    created_at INTEGER NOT NULL
) STRICT;

CREATE TABLE sessions (
    id INTEGER PRIMARY KEY,
    token_hash BLOB NOT NULL UNIQUE,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    csrf_token TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL
) STRICT;
CREATE INDEX sessions_user ON sessions(user_id);
CREATE INDEX sessions_expiry ON sessions(expires_at);

CREATE TABLE organizations (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    created_by INTEGER NOT NULL REFERENCES users(id),
    created_at INTEGER NOT NULL
) STRICT;

CREATE TABLE memberships (
    org_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role TEXT NOT NULL CHECK (role IN ('owner', 'admin', 'member')),
    created_at INTEGER NOT NULL,
    PRIMARY KEY (org_id, user_id)
) STRICT;
CREATE INDEX memberships_user ON memberships(user_id);

CREATE TABLE projects (
    id INTEGER PRIMARY KEY,
    org_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    created_at INTEGER NOT NULL
) STRICT;
CREATE INDEX projects_org ON projects(org_id);

CREATE TABLE sources (
    id INTEGER PRIMARY KEY,
    org_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    environment TEXT NOT NULL,
    created_at INTEGER NOT NULL
) STRICT;
CREATE INDEX sources_project ON sources(project_id);

CREATE TABLE ingest_keys (
    id INTEGER PRIMARY KEY,
    org_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    source_id INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
    key_hash BLOB NOT NULL UNIQUE,
    key_hint TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    revoked_at INTEGER
) STRICT;
CREATE INDEX ingest_keys_source ON ingest_keys(source_id);
";

const DOWN: &str = r"
DROP TABLE ingest_keys;
DROP TABLE sources;
DROP TABLE projects;
DROP TABLE memberships;
DROP TABLE organizations;
DROP TABLE sessions;
DROP TABLE users;
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
