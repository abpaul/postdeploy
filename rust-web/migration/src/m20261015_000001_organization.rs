use sea_orm_migration::prelude::*;

#[derive(DeriveMigrationName)]
pub struct Migration;

const UP: &str = r"
CREATE TABLE issues (
    id INTEGER PRIMARY KEY,
    project_id INTEGER NOT NULL,
    environment TEXT NOT NULL,
    fingerprint TEXT NOT NULL,
    title TEXT NOT NULL,
    culprit TEXT,
    level TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('open', 'resolved', 'ignored')),
    first_seen INTEGER NOT NULL,
    last_seen INTEGER NOT NULL,
    event_count INTEGER NOT NULL,
    last_release TEXT,
    regressed_at INTEGER,
    UNIQUE (project_id, environment, fingerprint)
) STRICT;
CREATE INDEX issues_project_seen ON issues(project_id, last_seen);
CREATE INDEX issues_seen ON issues(last_seen);

CREATE TABLE events (
    id INTEGER PRIMARY KEY,
    issue_id INTEGER NOT NULL REFERENCES issues(id) ON DELETE CASCADE,
    project_id INTEGER NOT NULL,
    source_id INTEGER NOT NULL,
    event_id TEXT NOT NULL,
    level TEXT NOT NULL,
    release TEXT,
    trace_id TEXT,
    occurred_at INTEGER NOT NULL,
    received_at INTEGER NOT NULL,
    payload_key TEXT NOT NULL,
    payload_bytes INTEGER NOT NULL,
    UNIQUE (source_id, event_id)
) STRICT;
CREATE INDEX events_issue ON events(issue_id, received_at);
CREATE INDEX events_trace ON events(trace_id) WHERE trace_id IS NOT NULL;
CREATE INDEX events_received ON events(received_at);

CREATE TABLE usage_daily (
    day TEXT NOT NULL,
    category TEXT NOT NULL,
    accepted INTEGER NOT NULL,
    bytes INTEGER NOT NULL,
    PRIMARY KEY (day, category)
) STRICT;

CREATE TABLE log_objects (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    object_key TEXT NOT NULL UNIQUE,
    project_id INTEGER NOT NULL,
    source_id INTEGER NOT NULL,
    environment TEXT NOT NULL,
    min_ts INTEGER NOT NULL,
    max_ts INTEGER NOT NULL,
    received_at INTEGER NOT NULL,
    entry_count INTEGER NOT NULL,
    level_mask INTEGER NOT NULL,
    trace_bloom BLOB NOT NULL,
    raw_bytes INTEGER NOT NULL,
    stored_bytes INTEGER NOT NULL,
    adopted INTEGER NOT NULL
) STRICT;
CREATE INDEX log_objects_received ON log_objects(received_at);
CREATE INDEX log_objects_project ON log_objects(project_id, id);
";

const DOWN: &str = r"
DROP TABLE log_objects;
DROP TABLE usage_daily;
DROP TABLE events;
DROP TABLE issues;
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
