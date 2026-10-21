use sea_orm_migration::prelude::*;

#[derive(DeriveMigrationName)]
pub struct Migration;

const UP: &str = r"
CREATE TABLE release_artifacts (
    id TEXT PRIMARY KEY,
    project_id INTEGER NOT NULL,
    release TEXT,
    dist TEXT NOT NULL,
    name TEXT NOT NULL,
    debug_id TEXT,
    sha256 TEXT NOT NULL,
    object_key TEXT NOT NULL UNIQUE,
    raw_bytes INTEGER NOT NULL,
    stored_bytes INTEGER NOT NULL,
    uploaded_by INTEGER NOT NULL,
    created_at INTEGER NOT NULL,
    CHECK (release IS NOT NULL OR debug_id IS NOT NULL),
    UNIQUE (project_id, release, dist, name)
) STRICT;
CREATE UNIQUE INDEX release_artifacts_debug_id ON release_artifacts(project_id, debug_id)
    WHERE debug_id IS NOT NULL;
CREATE INDEX release_artifacts_project ON release_artifacts(project_id, id);
";

const DOWN: &str = r"
DROP TABLE release_artifacts;
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
