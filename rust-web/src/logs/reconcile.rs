//! Reconciliation after a supported offline restore. A restored organization
//! database can be older than R2, so log admission and log reads stay closed
//! until one complete, content-verified pass over the organization's log
//! prefix finishes.
//!
//! The pass resumes from a cursor stored in `restore_state`. Each batch
//! object must decode with its own key, organization, object id and digest.
//! A known archived row must carry the same digest; a sealed row accepts only
//! identical content or a strict extension of its entries; a missing row is
//! inserted with the object's original id and its historic usage, without
//! current admission limits. Any other relation is a recorded conflict that
//! keeps the organization closed. Nothing is overwritten or deleted. An
//! object outside the batch key layout cannot be mapped to a cursor id and is
//! also a conflict.

use std::{
    collections::HashSet,
    sync::{atomic::Ordering, Mutex},
    time::Duration,
};

use sea_orm::{ConnectionTrait, TransactionTrait};
use tokio::{sync::Semaphore, time::Instant};

use crate::{
    billing::alerts::Metric,
    domain::{now_micros, OrgId},
    error::ApiError,
    logs::{
        object::{BatchHeader, LogEntry, Partition},
        read::CursorEpoch,
        storage::{
            fetch_batch, immediate, insert_runs, load_sealed, restore_flag, settle_existing,
            ArchiveError, Loaded, RestoreFlag,
        },
    },
    quota::{add_usage, month_usage, Usage},
    runtime::{sql, Runtime},
};

const PAGE: usize = 1_000;

pub struct Reconciliation {
    running: Mutex<HashSet<OrgId>>,
    slots: Semaphore,
}

impl Reconciliation {
    pub fn new(concurrency: usize) -> Self {
        Self {
            running: Mutex::default(),
            slots: Semaphore::new(concurrency.max(1)),
        }
    }

    pub fn cached_orgs(&self) -> usize {
        self.running.lock().expect("reconciliation lock").len()
    }
}

struct Running<'a> {
    reconciliation: &'a Reconciliation,
    org: OrgId,
}

impl Drop for Running<'_> {
    fn drop(&mut self) {
        self.reconciliation
            .running
            .lock()
            .expect("reconciliation lock")
            .remove(&self.org);
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum Outcome {
    Complete,
    Incomplete,
    Conflict(String),
}

/// Runs one bounded restore pass for `org`.
pub async fn restore(rt: &Runtime, org: &OrgId) -> Result<Outcome, ApiError> {
    let Ok(_slot) = rt.reconciliation.slots.try_acquire() else {
        return Ok(Outcome::Incomplete);
    };
    if !rt
        .reconciliation
        .running
        .lock()
        .expect("reconciliation lock")
        .insert(org.clone())
    {
        return Ok(Outcome::Incomplete);
    }
    let _running = Running {
        reconciliation: &rt.reconciliation,
        org: org.clone(),
    };
    let after = {
        let _write = rt.quotas.write(org).await?;
        let handle = rt.tenant(org).await?;
        match restore_flag(&*handle).await? {
            RestoreFlag::Clear => return Ok(Outcome::Complete),
            RestoreFlag::Conflict(reason) => return Ok(Outcome::Conflict(reason)),
            RestoreFlag::Required => {}
        }
        handle
            .execute_raw(sql(
                "UPDATE log_objects SET state = 'sealed' WHERE state = 'open'",
                vec![],
            ))
            .await?;
        handle
            .query_one_raw(sql(
                "SELECT scan_after FROM restore_state WHERE id = 1",
                vec![],
            ))
            .await?
            .map(|row| row.try_get::<Option<String>>("", "scan_after"))
            .transpose()?
            .flatten()
    };
    let budget = Instant::now() + Duration::from_millis(rt.settings.logs.reconcile_timeout_ms);
    let outcome = pass(rt, org, after, budget).await?;
    if let Outcome::Conflict(reason) = &outcome {
        rt.metrics.archive_conflicts.fetch_add(1, Ordering::Relaxed);
        tracing::error!(org = %org, reason, "log restore reconciliation conflict");
        let handle = rt.tenant(org).await?;
        handle
            .execute_raw(sql(
                "UPDATE restore_state SET conflict = ? WHERE id = 1",
                vec![reason.clone().into()],
            ))
            .await?;
    }
    Ok(outcome)
}

/// Reconciles keys in listing order until the listing ends or `budget`
/// passes. The budget is checked between keys, so every pass makes progress
/// even when one object takes longer than the budget; each object's I/O stays
/// bounded by the store timeout. The scan position is saved after every
/// reconciled object. A crash between insert and checkpoint repeats at most
/// one object idempotently.
async fn pass(
    rt: &Runtime,
    org: &OrgId,
    mut after: Option<String>,
    budget: Instant,
) -> Result<Outcome, ApiError> {
    let prefix = Partition::org_prefix(org);
    let batches = format!("{prefix}v2/");
    let limit = rt.settings.logs.reconcile_max_objects;
    let mut listed = 0;
    while listed < limit {
        let page = rt
            .store
            .list_page(&prefix, after.as_deref(), PAGE.min(limit - listed))
            .await
            .map_err(|_| ApiError::Unavailable("log_restore_pending"))?;
        if page.keys.iter().any(|key| !key.starts_with(&batches)) {
            return Ok(Outcome::Conflict("unmapped_format1_object".into()));
        }
        let complete = page.next.is_none();
        for (index, key) in page.keys.iter().enumerate() {
            listed += 1;
            if let Some(reason) = reconcile_key(rt, org, key).await? {
                return Ok(Outcome::Conflict(reason.into()));
            }
            save_progress(rt, org, key).await?;
            if Instant::now() >= budget && index + 1 < page.keys.len() {
                return Ok(Outcome::Incomplete);
            }
        }
        if let Some(last) = page.keys.last() {
            save_progress(rt, org, last).await?;
            after = Some(last.clone());
        }
        if complete {
            finish(rt, org).await?;
            return Ok(Outcome::Complete);
        }
        if Instant::now() >= budget {
            return Ok(Outcome::Incomplete);
        }
    }
    Ok(Outcome::Incomplete)
}

async fn save_progress(rt: &Runtime, org: &OrgId, after: &str) -> Result<(), ApiError> {
    let handle = rt.tenant(org).await?;
    handle
        .execute_raw(sql(
            "UPDATE restore_state SET scan_after = ? WHERE id = 1",
            vec![after.into()],
        ))
        .await?;
    Ok(())
}

/// Returns a conflict reason, or `None` when the object is reconciled.
async fn reconcile_key(
    rt: &Runtime,
    org: &OrgId,
    key: &str,
) -> Result<Option<&'static str>, ApiError> {
    let (remote, stored) = match fetch_batch(rt, key).await {
        Ok(Some(found)) => found,
        Ok(None) => return Ok(None),
        Err(ArchiveError::Conflict(reason)) => return Ok(Some(reason)),
        Err(_) => return Err(ApiError::Unavailable("log_restore_pending")),
    };
    let header = &remote.header;
    if header.key != key || header.org != *org {
        return Ok(Some("remote_identity_mismatch"));
    }
    let local = {
        let handle = rt.tenant(org).await?;
        let by_id = handle
            .query_one_raw(sql(
                "SELECT object_key, format, state, entry_count, content_sha256 FROM log_objects WHERE id = ?",
                vec![header.object_id.into()],
            ))
            .await?;
        let by_key = handle
            .query_one_raw(sql(
                "SELECT id FROM log_objects WHERE object_key = ?",
                vec![key.into()],
            ))
            .await?
            .map(|row| row.try_get::<i64>("", "id"))
            .transpose()?;
        if by_key.is_some_and(|id| id != header.object_id) {
            return Ok(Some("object_id_reused"));
        }
        by_id
    };
    let Some(row) = local else {
        insert_archived(rt, header, &remote.entries, stored).await?;
        return Ok(None);
    };
    let local_key: String = row.try_get("", "object_key")?;
    let format: i32 = row.try_get("", "format")?;
    let state: String = row.try_get("", "state")?;
    if local_key != key || format != 2 {
        return Ok(Some("object_id_reused"));
    }
    if state == "archived" {
        let digest: Option<Vec<u8>> = row.try_get("", "content_sha256")?;
        let count: i64 = row.try_get("", "entry_count")?;
        let same = digest.as_deref() == Some(header.digest().as_slice())
            && count == i64::from(header.count);
        return Ok((!same).then_some("archived_content_mismatch"));
    }
    match load_sealed(rt, org, header.object_id).await? {
        Loaded::Batch(batch) => match settle_existing(rt, &batch, &remote, stored).await {
            Ok(_) => Ok(None),
            Err(ArchiveError::Conflict(reason)) => Ok(Some(reason)),
            Err(ArchiveError::Corrupt) => Ok(Some("pending_entry_corrupt")),
            Err(ArchiveError::Database(error)) => Err(error),
            Err(ArchiveError::Store) => Err(ApiError::Unavailable("log_restore_pending")),
        },
        Loaded::Corrupt => Ok(Some("pending_entry_corrupt")),
        Loaded::Gone => Err(ApiError::Unavailable("log_restore_pending")),
    }
}

/// Inserts a verified R2 batch that the restored database does not know, at
/// its original id, and repairs its historic usage.
async fn insert_archived(
    rt: &Runtime,
    header: &BatchHeader,
    entries: &[LogEntry],
    stored: u64,
) -> Result<(), ApiError> {
    let org = &header.org;
    let _write = rt.quotas.write(org).await?;
    let handle = rt.tenant(org).await?;
    let txn = handle.begin_with_options(immediate()).await?;
    txn.execute_raw(sql(
        "INSERT INTO log_objects (id, object_key, project_id, source_id, environment, min_ts, max_ts,
            received_at, entry_count, level_mask, trace_bloom, raw_bytes, stored_bytes, adopted, format,
            state, opened_at, archived_at, usage_day, pending_bytes, content_sha256)
         VALUES (?, ?, 0, 0, '', ?, ?, ?, ?, ?, ?, ?, ?, 1, 2, 'archived', ?, ?, ?, 0, ?)",
        vec![
            header.object_id.into(),
            header.key.clone().into(),
            header.min_ts.into(),
            header.max_ts.into(),
            header.received_at.into(),
            i64::from(header.count).into(),
            i32::from(header.level_mask).into(),
            header.bloom().into(),
            (header.raw_bytes as i64).into(),
            (stored as i64).into(),
            header.opened_at.into(),
            now_micros().into(),
            header.usage_day.clone().into(),
            header.digest().into(),
        ],
    ))
    .await?;
    insert_runs(&txn, header.object_id, 0, entries).await?;
    let day = &header.usage_day;
    add_usage(&txn, day, "log", u64::from(header.count), header.raw_bytes).await?;
    add_usage(
        &txn,
        day,
        "log_adopted",
        u64::from(header.count),
        header.raw_bytes,
    )
    .await?;
    let month = month_usage(&txn, day).await?;
    crate::billing::alerts::record(&txn, day, Metric::LogBytes, month.log_bytes).await?;
    txn.commit().await?;
    drop(handle);
    rt.quotas.committed(
        org,
        day,
        Usage {
            errors: 0,
            logs: u64::from(header.count),
            log_bytes: header.raw_bytes,
        },
    );
    rt.metrics.objects_adopted.fetch_add(1, Ordering::Relaxed);
    rt.metrics
        .logs_adopted
        .fetch_add(u64::from(header.count), Ordering::Relaxed);
    Ok(())
}

/// Advances the id sequence past every known object, starts a new cursor
/// epoch and reopens the organization for log admission and reads. The lost
/// database may have issued positions above every object R2 still holds, so
/// cursors from before the restore are rejected rather than resumed. Each
/// activation of a restored file finishes once and gets its own epoch.
/// Orphan cleanup stays held.
async fn finish(rt: &Runtime, org: &OrgId) -> Result<(), ApiError> {
    let _write = rt.quotas.write(org).await?;
    let handle = rt.tenant(org).await?;
    let txn = handle.begin_with_options(immediate()).await?;
    let max: i64 = txn
        .query_one_raw(sql(
            "SELECT COALESCE(MAX(id), 0) AS id FROM log_objects",
            vec![],
        ))
        .await?
        .map(|row| row.try_get("", "id"))
        .transpose()?
        .unwrap_or(0);
    let updated = txn
        .execute_raw(sql(
            "UPDATE sqlite_sequence SET seq = MAX(seq, ?) WHERE name = 'log_objects'",
            vec![max.into()],
        ))
        .await?
        .rows_affected();
    if updated == 0 && max > 0 {
        txn.execute_raw(sql(
            "INSERT INTO sqlite_sequence (name, seq) VALUES ('log_objects', ?)",
            vec![max.into()],
        ))
        .await?;
    }
    let epoch = CursorEpoch::fresh();
    txn.execute_raw(sql(
        "UPDATE restore_state SET logs_reconcile_required = 0, scan_after = NULL, conflict = NULL,
            cursor_epoch = ? WHERE id = 1",
        vec![epoch.stored().into()],
    ))
    .await?;
    txn.commit().await?;
    tracing::info!(org = %org, max_object = max, cursor_epoch = ?epoch,
        "log restore reconciliation complete");
    Ok(())
}
