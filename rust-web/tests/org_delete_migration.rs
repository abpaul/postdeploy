use migration::{ControlMigrator, MigratorTrait};
use postdeploy::{domain::OrgId, runtime::sql, testing::TestEnv};
use sea_orm::{
    sqlx::sqlite::{SqliteJournalMode, SqliteSynchronous},
    ConnectOptions, ConnectionTrait, Database,
};

async fn upgrade_old_schema(name: &str, recovery_table: bool) {
    let env = TestEnv::new(name);
    let mut options = ConnectOptions::new(format!(
        "sqlite://{}?mode=rwc",
        env.dir.join("control.sqlite").display()
    ));
    options
        .min_connections(0)
        .max_connections(1)
        .map_sqlx_sqlite_opts(|options| {
            options
                .foreign_keys(true)
                .journal_mode(SqliteJournalMode::Wal)
                .synchronous(SqliteSynchronous::Full)
        });
    let db = Database::connect(options).await.unwrap();
    ControlMigrator::up(&db, Some(4)).await.unwrap();
    db.execute_unprepared(
        "ALTER TABLE organizations ADD COLUMN lifecycle TEXT NOT NULL DEFAULT 'active'
             CHECK (lifecycle IN ('active', 'deleting'));
         CREATE TABLE organization_deletions (
             org_id TEXT PRIMARY KEY REFERENCES organizations(id) ON DELETE CASCADE,
             requested_by INTEGER NOT NULL REFERENCES users(id),
             requested_at INTEGER NOT NULL,
             phase INTEGER NOT NULL DEFAULT 0 CHECK (phase BETWEEN 0 AND 5),
             after_key TEXT
         ) STRICT;
         INSERT INTO seaql_migrations (version, applied_at)
             VALUES ('m20261016_000008_organization_lifecycle', 0);
         INSERT INTO users (id, email, password_hash, created_at)
             VALUES (1, 'migration-fixture@example.test', 'isolated-hash-fixture', 1);",
    )
    .await
    .unwrap();
    let org = OrgId::generate();
    let cursor = format!("releases/v1/{org}/cursor");
    db.execute_raw(sql(
        "INSERT INTO organizations (id, name, created_by, created_at, lifecycle) VALUES (?, 'Queued fixture', 1, 1, 'deleting')",
        vec![org.as_str().into()],
    )).await.unwrap();
    db.execute_raw(sql(
        "INSERT INTO organization_deletions (org_id, requested_by, requested_at, phase, after_key) VALUES (?, 1, 11, 2, ?)",
        vec![org.as_str().into(), cursor.clone().into()],
    )).await.unwrap();
    if recovery_table {
        db.execute_unprepared(
            "CREATE TABLE organization_cleanup (
                 org_id TEXT PRIMARY KEY, requested_at INTEGER NOT NULL,
                 attempted_at INTEGER NOT NULL DEFAULT 0,
                 phase INTEGER NOT NULL DEFAULT 0 CHECK (phase BETWEEN 0 AND 5),
                 after_key TEXT,
                 local_removed INTEGER NOT NULL DEFAULT 0 CHECK (local_removed IN (0, 1))
             ) STRICT;",
        )
        .await
        .unwrap();
    }
    let snapshot = env.dir.join("preserved-before-upgrade.sqlite");
    db.execute_raw(sql(
        "VACUUM INTO ?",
        vec![snapshot.to_string_lossy().to_string().into()],
    ))
    .await
    .unwrap();
    ControlMigrator::up(&db, None).await.unwrap();
    let row = db.query_one_raw(sql("SELECT requested_at, attempted_at, phase, after_key, local_removed FROM organization_deletions WHERE org_id = ?", vec![org.as_str().into()])).await.unwrap().unwrap();
    assert_eq!(row.try_get::<i64>("", "requested_at").unwrap(), 11);
    assert_eq!(row.try_get::<i64>("", "attempted_at").unwrap(), 0);
    assert_eq!(row.try_get::<i64>("", "phase").unwrap(), 2);
    assert_eq!(row.try_get::<String>("", "after_key").unwrap(), cursor);
    assert_eq!(row.try_get::<i64>("", "local_removed").unwrap(), 0);
    db.execute_raw(sql(
        "DELETE FROM organizations WHERE id = ?",
        vec![org.as_str().into()],
    ))
    .await
    .unwrap();
    assert!(db
        .query_one_raw(sql(
            "SELECT org_id FROM organization_deletions WHERE org_id = ?",
            vec![org.as_str().into()]
        ))
        .await
        .unwrap()
        .is_some());
    ControlMigrator::up(&db, None).await.unwrap();
    assert!(snapshot.is_file());
    db.close().await.unwrap();
}

#[tokio::test]
async fn old_lifecycle_schema_without_attempted_at_preserves_queued_cursor() {
    upgrade_old_schema("org-delete-old-schema-upgrade", false).await;
}

#[tokio::test]
async fn empty_cleanup_table_from_interrupted_upgrade_resumes_without_losing_cursor() {
    upgrade_old_schema("org-delete-empty-recovery-table", true).await;
}
