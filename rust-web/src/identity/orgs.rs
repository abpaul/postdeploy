use sea_orm::{ConnectionTrait, TransactionTrait};
use serde::Serialize;

use crate::{
    domain::{now_secs, OrgId, Role, UserId},
    error::{ApiError, ApiResult},
    identity::access::OrgAccess,
    runtime::{sql, Runtime},
};

#[derive(Debug, Serialize)]
pub struct OrgSummary {
    pub id: OrgId,
    pub name: String,
    pub role: Role,
    pub created_at: i64,
}

#[derive(Debug, Serialize)]
pub struct Member {
    pub user_id: UserId,
    pub email: String,
    pub role: Role,
}

pub(crate) fn clean_name(name: &str) -> ApiResult<String> {
    let name = name.trim();
    (1..=100)
        .contains(&name.chars().count())
        .then(|| name.to_owned())
        .ok_or(ApiError::BadRequest("invalid_name"))
}

/// The only operation that provisions a tenant database. The file is created
/// and migrated first; the control rows that make it reachable follow.
pub async fn create(rt: &Runtime, user: UserId, name: &str) -> ApiResult<OrgSummary> {
    let name = clean_name(name)?;
    // One process owns the data, so this serializes the limit check with the insert.
    static CREATE: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
    let _serial = CREATE.lock().await;
    let created: i64 = rt
        .control
        .query_one_raw(sql(
            "SELECT COUNT(*) AS n FROM organizations WHERE created_by = ?",
            vec![user.0.into()],
        ))
        .await?
        .ok_or(ApiError::Internal("organization count".into()))?
        .try_get("", "n")?;
    if created >= i64::from(rt.settings.auth.max_created_orgs) {
        return Err(ApiError::Conflict("organization_limit"));
    }
    let org = OrgId::generate();
    let handle = rt.tenants.registry().provision(&org.tenant()).await?;
    drop(handle);
    let now = now_secs();
    let txn = rt.control.begin().await?;
    txn.execute_raw(sql(
        "INSERT INTO organizations (id, name, created_by, created_at) VALUES (?, ?, ?, ?)",
        vec![
            org.as_str().into(),
            name.clone().into(),
            user.0.into(),
            now.into(),
        ],
    ))
    .await?;
    txn.execute_raw(sql(
        "INSERT INTO memberships (org_id, user_id, role, created_at) VALUES (?, ?, 'owner', ?)",
        vec![org.as_str().into(), user.0.into(), now.into()],
    ))
    .await?;
    txn.commit().await?;
    Ok(OrgSummary {
        id: org,
        name,
        role: Role::Owner,
        created_at: now,
    })
}

pub async fn list(rt: &Runtime, user: UserId) -> ApiResult<Vec<OrgSummary>> {
    let rows = rt
        .control
        .query_all_raw(sql(
            "SELECT o.id, o.name, o.created_at, m.role FROM memberships m JOIN organizations o ON o.id = m.org_id
             WHERE m.user_id = ? AND o.lifecycle = 'active' ORDER BY o.created_at, o.id",
            vec![user.0.into()],
        ))
        .await?;
    rows.iter().map(summary).collect()
}

pub async fn get(rt: &Runtime, access: &OrgAccess) -> ApiResult<OrgSummary> {
    let row = rt
        .control
        .query_one_raw(sql(
            "SELECT o.id, o.name, o.created_at, m.role FROM memberships m JOIN organizations o ON o.id = m.org_id
             WHERE m.user_id = ? AND o.id = ? AND o.lifecycle = 'active'",
            vec![access.user.0.into(), access.org.as_str().into()],
        ))
        .await?
        .ok_or(ApiError::NotFound)?;
    summary(&row)
}

fn summary(row: &sea_orm::QueryResult) -> ApiResult<OrgSummary> {
    let id: String = row.try_get("", "id")?;
    let role: String = row.try_get("", "role")?;
    Ok(OrgSummary {
        id: id
            .parse()
            .map_err(|()| ApiError::Internal("stored organization id".into()))?,
        name: row.try_get("", "name")?,
        role: Role::parse(&role).ok_or(ApiError::Internal("stored role".into()))?,
        created_at: row.try_get("", "created_at")?,
    })
}

pub async fn members(rt: &Runtime, access: &OrgAccess) -> ApiResult<Vec<Member>> {
    let rows = rt
        .control
        .query_all_raw(sql(
            "SELECT m.user_id, u.email, m.role FROM memberships m JOIN users u ON u.id = m.user_id
             WHERE m.org_id = ? ORDER BY m.created_at, m.user_id",
            vec![access.org.as_str().into()],
        ))
        .await?;
    rows.iter()
        .map(|row| {
            let role: String = row.try_get("", "role")?;
            Ok(Member {
                user_id: UserId(row.try_get("", "user_id")?),
                email: row.try_get("", "email")?,
                role: Role::parse(&role).ok_or(ApiError::Internal("stored role".into()))?,
            })
        })
        .collect()
}

pub async fn add_member(
    rt: &Runtime,
    access: &OrgAccess,
    email: &str,
    role: Role,
) -> ApiResult<Member> {
    access.require_manage()?;
    if role == Role::Owner && access.role != Role::Owner {
        return Err(ApiError::Forbidden);
    }
    let email = email.trim().to_ascii_lowercase();
    let user = rt
        .control
        .query_one_raw(sql(
            "SELECT id FROM users WHERE email = ?",
            vec![email.clone().into()],
        ))
        .await?
        .ok_or(ApiError::NotFound)?;
    let user_id: i64 = user.try_get("", "id")?;
    let inserted = rt
        .control
        .execute_raw(sql(
            "INSERT INTO memberships (org_id, user_id, role, created_at) VALUES (?, ?, ?, ?)
             ON CONFLICT (org_id, user_id) DO NOTHING",
            vec![
                access.org.as_str().into(),
                user_id.into(),
                role.as_str().into(),
                now_secs().into(),
            ],
        ))
        .await?;
    if inserted.rows_affected() == 0 {
        return Err(ApiError::Conflict("already_member"));
    }
    Ok(Member {
        user_id: UserId(user_id),
        email,
        role,
    })
}

pub async fn remove_member(rt: &Runtime, access: &OrgAccess, user: UserId) -> ApiResult<()> {
    access.require_manage()?;
    let txn = rt.control.begin().await?;
    let target = txn
        .query_one_raw(sql(
            "SELECT role FROM memberships WHERE org_id = ? AND user_id = ?",
            vec![access.org.as_str().into(), user.0.into()],
        ))
        .await?
        .ok_or(ApiError::NotFound)?;
    let role: String = target.try_get("", "role")?;
    if role == "owner" {
        if access.role != Role::Owner {
            return Err(ApiError::Forbidden);
        }
        let owners = txn
            .query_one_raw(sql(
                "SELECT COUNT(*) AS n FROM memberships WHERE org_id = ? AND role = 'owner'",
                vec![access.org.as_str().into()],
            ))
            .await?
            .map(|r| r.try_get::<i64>("", "n"))
            .transpose()?
            .unwrap_or(0);
        if owners <= 1 {
            return Err(ApiError::Conflict("last_owner"));
        }
    }
    txn.execute_raw(sql(
        "DELETE FROM memberships WHERE org_id = ? AND user_id = ?",
        vec![access.org.as_str().into(), user.0.into()],
    ))
    .await?;
    for revoke in [
        "UPDATE agent_api_keys SET revoked_at = COALESCE(revoked_at, ?) WHERE org_id = ? AND user_id = ?",
        "UPDATE oauth_grants SET revoked_at = COALESCE(revoked_at, ?) WHERE org_id = ? AND user_id = ?",
    ] {
        txn.execute_raw(sql(
            revoke,
            vec![now_secs().into(), access.org.as_str().into(), user.0.into()],
        ))
        .await?;
    }
    txn.commit().await?;
    Ok(())
}

pub async fn page_ids(rt: &Runtime, after: Option<&OrgId>, limit: usize) -> ApiResult<Vec<OrgId>> {
    let rows = rt
        .control
        .query_all_raw(sql(
            "SELECT id FROM organizations WHERE lifecycle = 'active' AND id > ? ORDER BY id LIMIT ?",
            vec![after.map_or("", OrgId::as_str).into(), (limit.clamp(1, 200) as i64).into()],
        ))
        .await?;
    rows.iter()
        .map(|row| {
            let id: String = row.try_get("", "id")?;
            id.parse()
                .map_err(|()| ApiError::Internal("stored organization id".into()))
        })
        .collect()
}
