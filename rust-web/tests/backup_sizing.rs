//! Gate 4 sizing harness. Runs one backup cycle and one set restore against a
//! copy of the final-schema sizing fixture. `POSTDEPLOY_SIZING_FIXTURE` names
//! the retained fixture (never opened in place); `POSTDEPLOY_SIZING_OUT` names
//! the JSON measurement file to write. Build with `--release`.

mod support;

use std::{path::PathBuf, sync::Arc, time::Instant};

use postdeploy::{
    backup_sets::Cycle,
    domain::OrgId,
    logs::pending::{Slot, OVERHEAD},
    runtime::{sql, Runtime},
    settings::BackupSettings,
    testing::TestEnv,
};
use sea_orm::ConnectionTrait;
use serde_json::json;
use sha2::{Digest, Sha256};

const FIXTURE_SHA256: &str = "10bc76cc7f1a3185f6b61544b9788ed719f8f626ffcf53841f6ab91f837b4ac3";
const ORG: &str = "o0123456789abcdef0123456789abcdef";

fn sha256_file(path: &std::path::Path) -> String {
    let mut file = std::fs::File::open(path).unwrap();
    let mut digest = Sha256::new();
    std::io::copy(&mut file, &mut digest).unwrap();
    hex::encode(digest.finalize())
}

struct Fixture {
    env: TestEnv,
    boot: loco_rs::boot::BootResult,
    rt: Arc<Runtime>,
    original: PathBuf,
    resealed: (u64, u64),
    tenant_bytes_incremental_vacuum: u64,
    tenant_bytes_after_migration: u64,
}

/// Copies the fixture as the organization's tenant, adds synthetic control
/// ownership for every project and source id it references, and reseals its
/// opaque pending blobs with the data key at their original lengths so the
/// restore key check can run.
async fn fixture(name: &str) -> Fixture {
    let original = PathBuf::from(std::env::var_os("POSTDEPLOY_SIZING_FIXTURE").unwrap());
    assert_eq!(sha256_file(&original), FIXTURE_SHA256, "retained fixture");
    let env = TestEnv::new(name);
    std::fs::create_dir_all(env.tenant_root()).unwrap();
    let copy = env.tenant_root().join(format!("{ORG}.db"));
    std::fs::copy(&original, &copy).unwrap();
    let offline = sea_orm::Database::connect(format!("sqlite://{}?mode=rw", copy.display()))
        .await
        .unwrap();
    offline
        .execute_unprepared("PRAGMA auto_vacuum = INCREMENTAL; VACUUM;")
        .await
        .unwrap();
    offline.close().await.unwrap();
    let tenant_bytes_incremental_vacuum = std::fs::metadata(&copy).unwrap().len();
    let boot = env
        .boot_memory(|settings| {
            settings["backup"] = json!({"initial_delay_secs": 86_400});
        })
        .await
        .unwrap();
    let rt = Runtime::get(&boot.app_context);
    let org: OrgId = ORG.parse().unwrap();
    rt.control
        .execute_unprepared(&format!(
            "INSERT INTO users (id, email, password_hash, created_at) VALUES (1, 'sizing@example.invalid', 'x', 1);
             INSERT INTO organizations (id, name, created_by, created_at) VALUES ('{ORG}', 'Sizing', 1, 1);"
        ))
        .await
        .unwrap();
    let tenant = rt.tenant(&org).await.unwrap();
    let ids = |query: &str| {
        let tenant = &tenant;
        let query = query.to_owned();
        async move {
            tenant
                .query_all_raw(sql(&query, vec![]))
                .await
                .unwrap()
                .iter()
                .map(|row| row.try_get_by_index::<i64>(0).unwrap())
                .collect::<Vec<_>>()
        }
    };
    let pairs = ids("SELECT DISTINCT source_id * 1000000 + project_id FROM (
            SELECT source_id, project_id FROM log_entry_runs UNION SELECT source_id, project_id FROM events
            UNION SELECT source_id, project_id FROM log_objects UNION SELECT source_id, project_id FROM log_entries_pending)
            WHERE source_id != 0")
    .await;
    let mut projects = ids("SELECT DISTINCT project_id FROM (
            SELECT project_id FROM issues UNION SELECT project_id FROM events UNION SELECT project_id FROM log_entry_runs
            UNION SELECT project_id FROM log_objects UNION SELECT project_id FROM log_entries_pending) WHERE project_id != 0")
    .await;
    projects.sort_unstable();
    drop(tenant);
    for project in &projects {
        rt.control
            .execute_unprepared(&format!(
                "INSERT INTO projects (id, org_id, name, created_at) VALUES ({project}, '{ORG}', 'p{project}', 1)"
            ))
            .await
            .unwrap();
    }
    for pair in &pairs {
        let (source, project) = (pair / 1_000_000, pair % 1_000_000);
        rt.control
            .execute_unprepared(&format!(
                "INSERT INTO sources (id, org_id, project_id, name, environment, created_at)
                 VALUES ({source}, '{ORG}', {project}, 's{source}', 'production', 1)"
            ))
            .await
            .unwrap();
    }

    let tenant = rt.tenant(&org).await.unwrap();
    let mut resealed = (0u64, 0u64);
    let mut after = (i64::MIN, i64::MIN);
    loop {
        let rows = tenant
            .query_all_raw(sql(
                "SELECT object_id, entry, project_id, source_id, environment, billable_bytes, length(sealed) AS n
                 FROM log_entries_pending WHERE (object_id, entry) > (?, ?) ORDER BY object_id, entry LIMIT 2000",
                vec![after.0.into(), after.1.into()],
            ))
            .await
            .unwrap();
        let Some(last) = rows.last() else { break };
        after = (
            last.try_get("", "object_id").unwrap(),
            last.try_get("", "entry").unwrap(),
        );
        for row in &rows {
            let object_id: i64 = row.try_get("", "object_id").unwrap();
            let entry: i64 = row.try_get("", "entry").unwrap();
            let environment: String = row.try_get("", "environment").unwrap();
            let length = row.try_get::<i64>("", "n").unwrap() as usize;
            let skeleton = r#"{"ts":1,"rt":1,"level":"info","body":"","attributes":{}}"#;
            let body = "x".repeat(length - OVERHEAD - skeleton.len());
            let record =
                format!(r#"{{"ts":1,"rt":1,"level":"info","body":"{body}","attributes":{{}}}}"#);
            let sealed = rt.pending_cipher.seal(
                &Slot {
                    org: &org,
                    object_id,
                    entry: entry as u32,
                    project: row.try_get("", "project_id").unwrap(),
                    source: row.try_get("", "source_id").unwrap(),
                    environment: &environment,
                    billable_bytes: row.try_get::<i64>("", "billable_bytes").unwrap() as u64,
                },
                record.as_bytes(),
            );
            assert_eq!(sealed.len(), length, "resealed blob keeps its length");
            tenant
                .execute_raw(sql(
                    "UPDATE log_entries_pending SET sealed = ? WHERE object_id = ? AND entry = ?",
                    vec![sealed.into(), object_id.into(), entry.into()],
                ))
                .await
                .unwrap();
            resealed.0 += 1;
            resealed.1 += length as u64;
        }
    }
    tenant
        .execute_unprepared("PRAGMA wal_checkpoint(TRUNCATE)")
        .await
        .unwrap();
    let page = |name: &str| {
        let tenant = &tenant;
        let name = name.to_owned();
        async move {
            tenant
                .query_one_raw(sql(&format!("PRAGMA {name}"), vec![]))
                .await
                .unwrap()
                .unwrap()
                .try_get_by_index::<i64>(0)
                .unwrap() as u64
        }
    };
    let tenant_bytes_after_migration = page("page_count").await * page("page_size").await;
    drop(tenant);
    Fixture {
        env,
        boot,
        rt,
        original,
        resealed,
        tenant_bytes_incremental_vacuum,
        tenant_bytes_after_migration,
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "gate 4 sizing; requires POSTDEPLOY_SIZING_FIXTURE and POSTDEPLOY_SIZING_OUT"]
async fn final_schema_fixture_backup_and_restore_fit_configured_limits() {
    let out = PathBuf::from(std::env::var_os("POSTDEPLOY_SIZING_OUT").unwrap());
    let name = format!("backup-sizing-{}", uuid::Uuid::now_v7().simple());
    let f = fixture(&name).await;
    let org: OrgId = ORG.parse().unwrap();
    let limits = BackupSettings::default();
    let sets = support::backup_sets(&f.boot);
    let started = Instant::now();
    let cycle = sets.run_once(&f.rt).await;
    let cycle_ms = started.elapsed().as_millis() as u64;
    let Cycle::Complete(manifest) = cycle else {
        panic!("sizing cycle did not complete: {cycle:?}");
    };
    let member = &manifest.organizations[&org];
    assert!(member.snapshot_bytes <= limits.max_snapshot_bytes);
    assert!(member.object_bytes as usize <= limits.max_object_bytes);

    let destination = f.env.dir.join("restored");
    let started = Instant::now();
    let report = support::restore_set(&f.boot, manifest.set, &destination).await;
    let restore_ms = started.elapsed().as_millis() as u64;
    let restored_bytes = std::fs::metadata(&report.organizations[0].path)
        .unwrap()
        .len();
    assert_eq!(restored_bytes, member.snapshot_bytes);
    assert_eq!(
        sha256_file(&f.original),
        FIXTURE_SHA256,
        "retained fixture unchanged"
    );
    let measurement = json!({
        "fixture_sha256": FIXTURE_SHA256,
        "fixture_bytes": std::fs::metadata(&f.original).unwrap().len(),
        "tenant_bytes_incremental_vacuum": f.tenant_bytes_incremental_vacuum,
        "tenant_bytes_after_migration": f.tenant_bytes_after_migration,
        "pending_rows_resealed": f.resealed.0,
        "pending_bytes_resealed": f.resealed.1,
        "org_raw_bytes": member.snapshot_bytes,
        "org_sealed_bytes": member.object_bytes,
        "control_raw_bytes": manifest.control.snapshot_bytes,
        "control_sealed_bytes": manifest.control.object_bytes,
        "set_raw_bytes": manifest.raw_bytes(),
        "set_sealed_bytes": manifest.sealed_bytes(),
        "cycle_ms": cycle_ms,
        "restore_ms": restore_ms,
        "restored_org_bytes": restored_bytes,
        "limits": {
            "max_snapshot_bytes": limits.max_snapshot_bytes,
            "max_object_bytes": limits.max_object_bytes,
            "deadline_secs": limits.deadline_secs,
            "max_scratch_dirs": limits.max_scratch_dirs,
        },
        "rss_note": "process max RSS comes from /usr/bin/time -l around this binary; it includes the in-process server and the memory store holding every sealed object",
    });
    std::fs::write(&out, serde_json::to_vec_pretty(&measurement).unwrap()).unwrap();
    println!("{measurement}");
    f.rt.shutdown().await;
}

/// The same setup without a backup or restore, for the baseline RSS.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "gate 4 sizing baseline; requires POSTDEPLOY_SIZING_FIXTURE"]
async fn final_schema_fixture_setup_without_backup() {
    let name = format!("backup-sizing-baseline-{}", uuid::Uuid::now_v7().simple());
    let f = fixture(&name).await;
    println!(
        "baseline setup resealed_rows={} tenant_bytes_after_migration={}",
        f.resealed.0, f.tenant_bytes_after_migration
    );
    f.rt.shutdown().await;
}
