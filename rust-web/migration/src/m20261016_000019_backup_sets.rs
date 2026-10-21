use sea_orm_migration::prelude::*;

#[derive(DeriveMigrationName)]
pub struct Migration;

const BUMP: &str = "BEGIN UPDATE backup_revision SET revision = revision + 1 WHERE id = 1; END;";

/// Writes that change which organizations, projects and sources exist or who owns them.
const STRUCTURAL: [(&str, &str); 8] = [
    ("backup_rev_org_insert", "AFTER INSERT ON organizations"),
    ("backup_rev_org_delete", "AFTER DELETE ON organizations"),
    (
        "backup_rev_org_lifecycle",
        "AFTER UPDATE OF lifecycle ON organizations",
    ),
    ("backup_rev_project_insert", "AFTER INSERT ON projects"),
    ("backup_rev_project_delete", "AFTER DELETE ON projects"),
    (
        "backup_rev_project_owner",
        "AFTER UPDATE OF org_id ON projects",
    ),
    ("backup_rev_source_insert", "AFTER INSERT ON sources"),
    ("backup_rev_source_delete", "AFTER DELETE ON sources"),
];

const SOURCE_OWNER: &str = "CREATE TRIGGER backup_rev_source_owner
    AFTER UPDATE OF org_id, project_id, environment ON sources ";

const TABLES: &str = r"
CREATE TABLE backup_revision (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    revision INTEGER NOT NULL
) STRICT;
INSERT INTO backup_revision (id, revision) VALUES (1, 0);
CREATE TABLE backup_cycles (
    set_id TEXT PRIMARY KEY,
    started_at INTEGER NOT NULL,
    finished_at INTEGER,
    outcome TEXT CHECK (outcome IN ('complete', 'failed', 'busy', 'changed', 'abandoned')),
    stage TEXT,
    detail TEXT,
    attempts INTEGER NOT NULL,
    raw_bytes INTEGER,
    sealed_bytes INTEGER,
    elapsed_ms INTEGER
) STRICT;
CREATE INDEX backup_cycles_started ON backup_cycles(started_at);
";

#[async_trait::async_trait]
impl MigrationTrait for Migration {
    fn use_transaction(&self) -> Option<bool> {
        Some(true)
    }

    async fn up(&self, manager: &SchemaManager) -> Result<(), DbErr> {
        let db = manager.get_connection();
        db.execute_unprepared(TABLES).await?;
        for (name, event) in STRUCTURAL {
            db.execute_unprepared(&format!("CREATE TRIGGER {name} {event} {BUMP}"))
                .await?;
        }
        db.execute_unprepared(&format!("{SOURCE_OWNER}{BUMP}"))
            .await?;
        Ok(())
    }

    async fn down(&self, manager: &SchemaManager) -> Result<(), DbErr> {
        let db = manager.get_connection();
        db.execute_unprepared("DROP TRIGGER backup_rev_source_owner;")
            .await?;
        for (name, _) in STRUCTURAL {
            db.execute_unprepared(&format!("DROP TRIGGER {name};"))
                .await?;
        }
        db.execute_unprepared(
            "DROP INDEX backup_cycles_started; DROP TABLE backup_cycles; DROP TABLE backup_revision;",
        )
        .await?;
        Ok(())
    }
}
