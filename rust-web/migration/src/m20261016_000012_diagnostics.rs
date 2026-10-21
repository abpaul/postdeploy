use sea_orm_migration::prelude::*;

#[derive(DeriveMigrationName)]
pub struct Migration;

const UP: &str = r"
CREATE TABLE deployments (
    id INTEGER PRIMARY KEY,
    project_id INTEGER NOT NULL,
    environment TEXT NOT NULL,
    version TEXT NOT NULL,
    commit_sha TEXT CHECK (commit_sha IS NULL OR length(commit_sha) IN (40, 64)),
    deployed_at INTEGER NOT NULL,
    recorded_at INTEGER NOT NULL,
    recorded_by INTEGER NOT NULL,
    UNIQUE (project_id, environment, version, deployed_at)
) STRICT;
CREATE INDEX deployments_timeline ON deployments(project_id, environment, deployed_at);
ALTER TABLE issues ADD COLUMN resolved_at INTEGER;
ALTER TABLE events ADD COLUMN request_id TEXT;
ALTER TABLE events ADD COLUMN service TEXT;
ALTER TABLE events ADD COLUMN regression INTEGER CHECK (regression IN (0, 1));
CREATE INDEX events_project_occurred ON events(project_id, occurred_at);
ALTER TABLE report_evidence ADD COLUMN source_id INTEGER;
UPDATE report_evidence
SET source_id = (
    SELECT e.source_id FROM events e JOIN reports r ON r.id = report_evidence.report_id
    WHERE e.issue_id = report_evidence.issue_id AND e.event_id = report_evidence.event_id
        AND e.project_id = r.project_id
)
WHERE kind = 'event' AND (
    SELECT COUNT(*) FROM events e JOIN reports r ON r.id = report_evidence.report_id
    WHERE e.issue_id = report_evidence.issue_id AND e.event_id = report_evidence.event_id
        AND e.project_id = r.project_id
) = 1;
";

const DOWN: &str = r"
ALTER TABLE report_evidence DROP COLUMN source_id;
DROP INDEX events_project_occurred;
ALTER TABLE events DROP COLUMN regression;
ALTER TABLE events DROP COLUMN service;
ALTER TABLE events DROP COLUMN request_id;
ALTER TABLE issues DROP COLUMN resolved_at;
DROP TABLE deployments;
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
