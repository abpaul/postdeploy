use sea_orm_migration::prelude::*;

#[derive(DeriveMigrationName)]
pub struct Migration;

#[async_trait::async_trait]
impl MigrationTrait for Migration {
    fn use_transaction(&self) -> Option<bool> {
        Some(true)
    }

    async fn up(&self, manager: &SchemaManager) -> Result<(), DbErr> {
        let db = manager.get_connection();
        db.execute_unprepared(
            "ALTER TABLE organizations ADD COLUMN lifecycle TEXT NOT NULL DEFAULT 'active'
                 CHECK (lifecycle IN ('active', 'deleting'));
             CREATE INDEX organizations_lifecycle ON organizations(lifecycle, id);
             CREATE TABLE organization_deletions (
                 org_id TEXT PRIMARY KEY REFERENCES organizations(id) ON DELETE CASCADE,
                 requested_by INTEGER NOT NULL REFERENCES users(id),
                 requested_at INTEGER NOT NULL,
                 attempted_at INTEGER NOT NULL DEFAULT 0,
                 phase INTEGER NOT NULL DEFAULT 0 CHECK (phase BETWEEN 0 AND 5),
                 after_key TEXT
             ) STRICT;",
        )
        .await?;
        for table in [
            "memberships",
            "projects",
            "sources",
            "ingest_keys",
            "oauth_grants",
            "oauth_codes",
        ] {
            db.execute_unprepared(&format!(
                "CREATE TRIGGER {table}_active_organization BEFORE INSERT ON {table}
                 WHEN NOT EXISTS (SELECT 1 FROM organizations WHERE id = NEW.org_id AND lifecycle = 'active')
                 BEGIN SELECT RAISE(ABORT, 'organization unavailable'); END;"
            )).await?;
        }
        Ok(())
    }

    async fn down(&self, manager: &SchemaManager) -> Result<(), DbErr> {
        let db = manager.get_connection();
        for table in [
            "memberships",
            "projects",
            "sources",
            "ingest_keys",
            "oauth_grants",
            "oauth_codes",
        ] {
            db.execute_unprepared(&format!("DROP TRIGGER {table}_active_organization;"))
                .await?;
        }
        db.execute_unprepared(
            "DROP TABLE organization_deletions;
             DROP INDEX organizations_lifecycle;
             ALTER TABLE organizations DROP COLUMN lifecycle;",
        )
        .await?;
        Ok(())
    }
}
