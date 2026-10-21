pub use sea_orm_migration::prelude::*;

mod m20261015_000001_control;
mod m20261015_000001_organization;
mod m20261015_000002_agent_access;
mod m20261015_000003_reports_notifications;
mod m20261015_000004_account_settings;
mod m20261015_000005_release_artifacts;
mod m20261015_000006_project_source_names;
mod m20261016_000007_orphan_retention;
mod m20261016_000008_organization_lifecycle;
mod m20261016_000009_organization_cleanup_tombstones;
mod m20261016_000010_billing;
mod m20261016_000011_usage_alerts;
mod m20261016_000012_diagnostics;
mod m20261016_000013_durable_log_batches;
mod m20261016_000014_log_cursor_epoch;
mod m20261016_000015_agent_api_keys;
mod m20261016_000016_agent_api_keys_active_organization;
mod m20261016_000017_ingestion_policies;
mod m20261016_000018_ingest_outcomes;
mod m20261016_000019_backup_sets;
mod m20261016_000020_restore_snapshot_time;
mod m20261017_000021_id_floor;
mod m20261017_000022_id_floor_scan;
mod m20261017_000023_log_source_indexes;
mod m20261017_000024_legacy_import;
mod m20261017_000025_legacy_fingerprint;
mod m20261017_000026_agent_last_used;
mod m20261017_000027_trial_notices;
mod m20261018_000028_event_lookup_indexes;

/// Shared control database: accounts, sessions, organizations, memberships,
/// projects, sources and hashed ingestion keys.
pub struct ControlMigrator;

#[async_trait::async_trait]
impl MigratorTrait for ControlMigrator {
    fn migrations() -> Vec<Box<dyn MigrationTrait>> {
        vec![
            Box::new(m20261015_000001_control::Migration),
            Box::new(m20261015_000002_agent_access::Migration),
            Box::new(m20261015_000004_account_settings::Migration),
            Box::new(m20261015_000006_project_source_names::Migration),
            Box::new(m20261016_000008_organization_lifecycle::Migration),
            Box::new(m20261016_000009_organization_cleanup_tombstones::Migration),
            Box::new(m20261016_000010_billing::Migration),
            Box::new(m20261016_000015_agent_api_keys::Migration),
            Box::new(m20261016_000016_agent_api_keys_active_organization::Migration),
            Box::new(m20261016_000017_ingestion_policies::Migration),
            Box::new(m20261016_000019_backup_sets::Migration),
            Box::new(m20261017_000021_id_floor::Migration),
            Box::new(m20261017_000022_id_floor_scan::Migration),
            Box::new(m20261017_000024_legacy_import::Migration),
            Box::new(m20261017_000026_agent_last_used::Migration),
            Box::new(m20261017_000027_trial_notices::Migration),
        ]
    }
}

/// One database per organization: issues, events, usage and log object metadata.
pub struct OrgMigrator;

#[async_trait::async_trait]
impl MigratorTrait for OrgMigrator {
    fn migrations() -> Vec<Box<dyn MigrationTrait>> {
        vec![
            Box::new(m20261015_000001_organization::Migration),
            Box::new(m20261015_000003_reports_notifications::Migration),
            Box::new(m20261015_000005_release_artifacts::Migration),
            Box::new(m20261016_000007_orphan_retention::Migration),
            Box::new(m20261016_000011_usage_alerts::Migration),
            Box::new(m20261016_000012_diagnostics::Migration),
            Box::new(m20261016_000013_durable_log_batches::Migration),
            Box::new(m20261016_000014_log_cursor_epoch::Migration),
            Box::new(m20261016_000018_ingest_outcomes::Migration),
            Box::new(m20261016_000020_restore_snapshot_time::Migration),
            Box::new(m20261017_000023_log_source_indexes::Migration),
            Box::new(m20261017_000025_legacy_fingerprint::Migration),
            Box::new(m20261018_000028_event_lookup_indexes::Migration),
        ]
    }
}
