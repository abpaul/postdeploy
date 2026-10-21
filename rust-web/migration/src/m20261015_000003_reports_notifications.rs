use sea_orm_migration::prelude::*;

#[derive(DeriveMigrationName)]
pub struct Migration;

const UP: &str = r"
CREATE TABLE IF NOT EXISTS reports (
    id TEXT PRIMARY KEY,
    project_id INTEGER NOT NULL,
    author_id INTEGER NOT NULL,
    created_at INTEGER NOT NULL,
    object_key TEXT NOT NULL UNIQUE,
    body_bytes INTEGER NOT NULL,
    finding_count INTEGER NOT NULL,
    evidence_count INTEGER NOT NULL
) STRICT;
CREATE INDEX IF NOT EXISTS reports_project ON reports(project_id, id);

CREATE TABLE IF NOT EXISTS report_evidence (
    report_id TEXT NOT NULL REFERENCES reports(id) ON DELETE CASCADE,
    ordinal INTEGER NOT NULL,
    finding INTEGER NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('issue', 'event', 'log')),
    issue_id INTEGER,
    event_id TEXT,
    log_object_id INTEGER,
    log_entry INTEGER,
    PRIMARY KEY (report_id, ordinal),
    CHECK (
        (kind = 'issue' AND issue_id IS NOT NULL AND event_id IS NULL AND log_object_id IS NULL AND log_entry IS NULL)
        OR (kind = 'event' AND issue_id IS NOT NULL AND event_id IS NOT NULL AND log_object_id IS NULL AND log_entry IS NULL)
        OR (kind = 'log' AND issue_id IS NULL AND event_id IS NULL AND log_object_id IS NOT NULL AND log_entry IS NOT NULL)
    )
) STRICT, WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS report_evidence_issue ON report_evidence(issue_id) WHERE issue_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS notification_destinations (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL CHECK (kind IN ('email', 'webhook')),
    user_id INTEGER,
    url_ciphertext BLOB,
    secret_ciphertext BLOB,
    url_hint TEXT,
    events INTEGER NOT NULL CHECK (events BETWEEN 1 AND 7),
    project_id INTEGER,
    created_by INTEGER NOT NULL,
    created_at INTEGER NOT NULL,
    delivered INTEGER NOT NULL DEFAULT 0,
    failed INTEGER NOT NULL DEFAULT 0,
    dropped INTEGER NOT NULL DEFAULT 0,
    not_configured INTEGER NOT NULL DEFAULT 0,
    last_outcome TEXT,
    last_attempt_at INTEGER,
    CHECK (
        (kind = 'email' AND user_id IS NOT NULL AND url_ciphertext IS NULL AND secret_ciphertext IS NULL)
        OR (kind = 'webhook' AND user_id IS NULL AND url_ciphertext IS NOT NULL AND secret_ciphertext IS NOT NULL AND url_hint IS NOT NULL)
    )
) STRICT;
CREATE UNIQUE INDEX IF NOT EXISTS notification_destinations_email ON notification_destinations(user_id) WHERE kind = 'email';

CREATE TABLE IF NOT EXISTS notification_work (
    id INTEGER PRIMARY KEY,
    event_id TEXT NOT NULL,
    destination_id TEXT NOT NULL REFERENCES notification_destinations(id) ON DELETE CASCADE,
    kind TEXT NOT NULL CHECK (kind IN ('issue_new', 'issue_regression', 'report_published')),
    project_id INTEGER NOT NULL,
    issue_id INTEGER,
    report_id TEXT,
    state TEXT NOT NULL CHECK (state IN ('pending', 'sending', 'delivered', 'failed', 'not_configured')),
    attempts INTEGER NOT NULL,
    next_attempt_at INTEGER NOT NULL,
    last_error TEXT,
    created_at INTEGER NOT NULL,
    finished_at INTEGER,
    UNIQUE (event_id, destination_id),
    CHECK ((kind = 'report_published') = (report_id IS NOT NULL AND issue_id IS NULL))
) STRICT;
CREATE INDEX IF NOT EXISTS notification_work_due ON notification_work(state, next_attempt_at);
CREATE INDEX IF NOT EXISTS notification_work_finished ON notification_work(finished_at) WHERE finished_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS notification_work_destination ON notification_work(destination_id);
";

const DOWN: &str = r"
DROP TABLE notification_work;
DROP TABLE notification_destinations;
DROP TABLE report_evidence;
DROP TABLE reports;
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
