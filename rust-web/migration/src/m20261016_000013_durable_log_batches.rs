use sea_orm_migration::prelude::*;

#[derive(DeriveMigrationName)]
pub struct Migration;

const UP: &str = r"
ALTER TABLE log_objects ADD COLUMN format INTEGER NOT NULL DEFAULT 1 CHECK (format IN (1, 2));
ALTER TABLE log_objects ADD COLUMN state TEXT NOT NULL DEFAULT 'archived'
    CHECK (state IN ('open', 'sealed', 'archived'));
ALTER TABLE log_objects ADD COLUMN opened_at INTEGER;
ALTER TABLE log_objects ADD COLUMN archived_at INTEGER;
ALTER TABLE log_objects ADD COLUMN usage_day TEXT;
ALTER TABLE log_objects ADD COLUMN pending_bytes INTEGER NOT NULL DEFAULT 0;
ALTER TABLE log_objects ADD COLUMN content_sha256 BLOB;
CREATE UNIQUE INDEX log_objects_one_open ON log_objects(state) WHERE state = 'open';
CREATE INDEX log_objects_unarchived ON log_objects(state, id) WHERE state != 'archived';

CREATE TABLE log_entries_pending (
    object_id INTEGER NOT NULL REFERENCES log_objects(id) ON DELETE CASCADE,
    entry INTEGER NOT NULL,
    project_id INTEGER NOT NULL,
    source_id INTEGER NOT NULL,
    environment TEXT NOT NULL,
    billable_bytes INTEGER NOT NULL,
    sealed BLOB NOT NULL,
    PRIMARY KEY (object_id, entry)
) STRICT, WITHOUT ROWID;

CREATE TABLE log_entry_runs (
    object_id INTEGER NOT NULL REFERENCES log_objects(id) ON DELETE CASCADE,
    first_entry INTEGER NOT NULL,
    last_entry INTEGER NOT NULL,
    project_id INTEGER NOT NULL,
    source_id INTEGER NOT NULL,
    environment TEXT NOT NULL,
    min_ts INTEGER NOT NULL,
    max_ts INTEGER NOT NULL,
    level_mask INTEGER NOT NULL,
    PRIMARY KEY (object_id, first_entry),
    CHECK (last_entry >= first_entry)
) STRICT, WITHOUT ROWID;
CREATE INDEX log_entry_runs_project ON log_entry_runs(project_id, object_id);

CREATE TABLE restore_state (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    logs_reconcile_required INTEGER NOT NULL CHECK (logs_reconcile_required IN (0, 1)),
    orphan_cleanup_held INTEGER NOT NULL CHECK (orphan_cleanup_held IN (0, 1)),
    scan_after TEXT,
    conflict TEXT,
    marked_at INTEGER
) STRICT;
INSERT INTO restore_state (id, logs_reconcile_required, orphan_cleanup_held) VALUES (1, 0, 0);
";

const DOWN: &str = r"
DROP TABLE restore_state;
DROP INDEX log_entry_runs_project;
DROP TABLE log_entry_runs;
DROP TABLE log_entries_pending;
DROP INDEX log_objects_unarchived;
DROP INDEX log_objects_one_open;
ALTER TABLE log_objects DROP COLUMN content_sha256;
ALTER TABLE log_objects DROP COLUMN pending_bytes;
ALTER TABLE log_objects DROP COLUMN usage_day;
ALTER TABLE log_objects DROP COLUMN archived_at;
ALTER TABLE log_objects DROP COLUMN opened_at;
ALTER TABLE log_objects DROP COLUMN state;
ALTER TABLE log_objects DROP COLUMN format;
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
