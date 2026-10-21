//! Deletes expired log objects in bounded batches. `received_at` is the newest
//! receive time in an object, so a row expires only when every entry is past
//! retention. R2 is deleted first for every state, including batches that
//! were never marked archived, so an object uploaded before a crash cannot
//! outlive its metadata. A crash between the two steps only repeats work.
//! Reads enforce retention per entry independently of this sweep.

use std::sync::{atomic::Ordering, Arc};

use futures::StreamExt;
use sea_orm::{ConnectionTrait, TransactionTrait};

use crate::{
    domain::{now_micros, OrgId},
    error::ApiError,
    runtime::{sql, Runtime},
};

pub async fn sweep_org(rt: &Runtime, org: &OrgId) -> Result<usize, ApiError> {
    let cutoff = now_micros() - rt.settings.logs.retention().as_micros() as i64;
    let handle = rt.tenant(org).await?;
    let rows = handle
        .query_all_raw(sql(
            "SELECT id, object_key FROM log_objects WHERE received_at < ? ORDER BY received_at LIMIT ?",
            vec![cutoff.into(), (rt.settings.logs.sweep_batch as i64).into()],
        ))
        .await?;
    drop(handle);
    let expired: Vec<(i64, String)> = rows
        .iter()
        .map(|row| Ok((row.try_get("", "id")?, row.try_get("", "object_key")?)))
        .collect::<Result<_, sea_orm::DbErr>>()?;
    let deleted: Vec<i64> = futures::stream::iter(expired)
        .map(|(id, key)| async move { rt.store.delete(&key).await.ok().map(|()| id) })
        .buffer_unordered(8)
        .filter_map(|id| async move { id })
        .collect()
        .await;
    if deleted.is_empty() {
        crate::logs::storage::resync(rt, org).await?;
        return Ok(0);
    }
    let placeholders = vec!["?"; deleted.len()].join(",");
    let ids: Vec<sea_orm::Value> = deleted.iter().map(|id| (*id).into()).collect();
    let removed = {
        let _write = rt.quotas.write(org).await?;
        let handle = rt.tenant(org).await?;
        let txn = handle
            .begin_with_options(crate::logs::storage::immediate())
            .await?;
        let mut values = ids.clone();
        values.push(cutoff.into());
        let doomed = format!("id IN ({placeholders}) AND received_at < ?");
        for table in ["log_entries_pending", "log_entry_runs"] {
            txn.execute_raw(sql(
                &format!(
                    "DELETE FROM {table} WHERE object_id IN (SELECT id FROM log_objects WHERE {doomed})"
                ),
                values.clone(),
            ))
            .await?;
        }
        let removed = txn
            .execute_raw(sql(
                &format!("DELETE FROM log_objects WHERE {doomed}"),
                values,
            ))
            .await?
            .rows_affected() as usize;
        txn.commit().await?;
        removed
    };
    crate::logs::storage::resync(rt, org).await?;
    rt.metrics
        .objects_expired
        .fetch_add(removed as u64, Ordering::Relaxed);
    Ok(removed)
}

pub async fn sweep_loop(rt: Arc<Runtime>) {
    let period = std::time::Duration::from_secs(rt.settings.logs.sweep_interval_secs.max(1));
    let mut ticker = tokio::time::interval(period);
    let mut after = String::new();
    loop {
        tokio::select! {
            () = rt.cancel.cancelled() => return,
            _ = ticker.tick() => {}
        }
        let rows = match rt.control.query_all_raw(sql(
            "SELECT id FROM organizations WHERE lifecycle = 'active' AND id > ? ORDER BY id LIMIT 200",
            vec![after.clone().into()],
        )).await {
            Ok(rows) => rows,
            Err(error) => {
                tracing::error!(%error, "retention sweep could not list organizations");
                continue;
            }
        };
        let orgs: Result<Vec<OrgId>, _> = rows
            .iter()
            .map(|row| {
                let value: String = row.try_get("", "id")?;
                value
                    .parse()
                    .map_err(|()| sea_orm::DbErr::Custom("invalid organization id".into()))
            })
            .collect();
        let orgs = match orgs {
            Ok(orgs) => orgs,
            Err(error) => {
                tracing::error!(%error, "retention sweep could not decode organizations");
                continue;
            }
        };
        after = if orgs.len() == 200 {
            orgs.last().expect("nonempty page").as_str().to_owned()
        } else {
            String::new()
        };
        for org in orgs {
            if rt.cancel.is_cancelled() {
                return;
            }
            if let Err(error) = sweep_org(&rt, &org).await {
                tracing::warn!(org = %org, %error, "retention sweep failed");
            }
        }
    }
}
