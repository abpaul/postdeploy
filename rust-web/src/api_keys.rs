//! Organization API keys for agents and CI. The control database stores only
//! the SHA-256 hash of a key; `create` returns the secret once.

use sea_orm::{ConnectionTrait, DatabaseConnection};
use serde::{ser::SerializeStruct, Deserialize, Serialize, Serializer};

use crate::{
    agent_access::{AgentPrincipal, BearerError, Credential, Scope, ScopeSet, Secret},
    domain::{now_secs, OrgId, UserId},
    error::{ApiError, ApiResult},
    identity::{
        access::{authorize, OrgAccess},
        projects::PageRequest,
    },
    runtime::{sql, Runtime},
};

const DEFAULT_EXPIRY_DAYS: i64 = 30;
const MAX_EXPIRY_DAYS: i64 = 90;
const MAX_NAME_CHARS: usize = 100;
const HINT_CHARS: usize = 4;
const MAX_ACTIVE_KEYS: i64 = 50;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NewApiKey {
    pub name: String,
    /// Absent means read-only access.
    #[serde(default)]
    pub scopes: Option<Vec<String>>,
    #[serde(default)]
    pub expires_in_days: Option<i64>,
}

#[derive(Debug, PartialEq, Eq, Serialize)]
pub struct ApiKeySummary {
    pub id: i64,
    pub user_id: UserId,
    pub email: String,
    pub name: String,
    pub hint: String,
    pub scopes: ScopeSet,
    pub created_at: i64,
    pub expires_at: i64,
    pub last_used_at: Option<i64>,
}

/// The creation result: the only value that serializes the secret.
#[derive(Debug)]
pub struct CreatedApiKey {
    pub key: ApiKeySummary,
    pub secret: Secret,
}

impl Serialize for CreatedApiKey {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut body = serializer.serialize_struct("CreatedApiKey", 2)?;
        body.serialize_field("key", &self.key)?;
        body.serialize_field("secret", self.secret.expose())?;
        body.end()
    }
}

fn clean_name(name: &str) -> ApiResult<String> {
    let name = name.trim();
    let valid =
        (1..=MAX_NAME_CHARS).contains(&name.chars().count()) && !name.chars().any(char::is_control);
    valid
        .then(|| name.to_owned())
        .ok_or(ApiError::BadRequest("invalid_name"))
}

fn requested_scopes(access: &OrgAccess, scopes: Option<&[String]>) -> ApiResult<ScopeSet> {
    let scopes = match scopes {
        None => ScopeSet::read_only(),
        Some(list)
            if list
                .iter()
                .any(|scope| scope.is_empty() || scope.contains(' ')) =>
        {
            return Err(ApiError::BadRequest("invalid_scope"))
        }
        Some(list) => {
            ScopeSet::parse(&list.join(" ")).ok_or(ApiError::BadRequest("invalid_scope"))?
        }
    };
    if !access.role.can_manage() && scopes.iter().any(Scope::needs_manager) {
        return Err(ApiError::BadRequest("invalid_scope"));
    }
    Ok(scopes)
}

pub async fn create(
    rt: &Runtime,
    access: &OrgAccess,
    input: NewApiKey,
) -> ApiResult<CreatedApiKey> {
    let name = clean_name(&input.name)?;
    let scopes = requested_scopes(access, input.scopes.as_deref())?;
    let days = input.expires_in_days.unwrap_or(DEFAULT_EXPIRY_DAYS);
    if !(1..=MAX_EXPIRY_DAYS).contains(&days) {
        return Err(ApiError::BadRequest("invalid_expiry"));
    }
    let secret = Secret::new_api_key();
    let exposed = secret.expose();
    let hint = exposed[exposed.len() - HINT_CHARS..].to_owned();
    let created_at = now_secs();
    let expires_at = created_at + days * 86_400;
    let row = rt
        .control
        .query_one_raw(sql(
            "INSERT INTO agent_api_keys (org_id, user_id, name, key_hash, hint, scopes, created_at, expires_at)
             SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8
             WHERE EXISTS (SELECT 1 FROM memberships WHERE org_id = ?1 AND user_id = ?2)
               AND (SELECT COUNT(*) FROM agent_api_keys
                    WHERE org_id = ?1 AND user_id = ?2 AND revoked_at IS NULL AND expires_at > ?7) < ?9
             RETURNING id, (SELECT email FROM users WHERE id = ?2) AS email",
            vec![
                access.org.as_str().into(),
                access.user.0.into(),
                name.clone().into(),
                secret.hash().into(),
                hint.clone().into(),
                scopes.to_string().into(),
                created_at.into(),
                expires_at.into(),
                MAX_ACTIVE_KEYS.into(),
            ],
        ))
        .await?;
    let Some(row) = row else {
        authorize(rt, access.user, &access.org).await?;
        return Err(ApiError::Conflict("api_key_limit"));
    };
    Ok(CreatedApiKey {
        key: ApiKeySummary {
            id: row.try_get("", "id")?,
            user_id: access.user,
            email: row.try_get("", "email")?,
            name,
            hint,
            scopes,
            created_at,
            expires_at,
            last_used_at: None,
        },
        secret,
    })
}

const SUMMARY: &str =
    "SELECT k.id, k.user_id, u.email, k.name, k.hint, k.scopes, k.created_at, k.expires_at,
            k.last_used_at
     FROM agent_api_keys k JOIN users u ON u.id = k.user_id";

fn summary(row: &sea_orm::QueryResult) -> ApiResult<ApiKeySummary> {
    Ok(ApiKeySummary {
        id: row.try_get("", "id")?,
        user_id: UserId(row.try_get("", "user_id")?),
        email: row.try_get("", "email")?,
        name: row.try_get("", "name")?,
        hint: row.try_get("", "hint")?,
        scopes: ScopeSet::parse(&row.try_get::<String>("", "scopes")?)
            .ok_or(ApiError::Internal("stored api key scopes".into()))?,
        created_at: row.try_get("", "created_at")?,
        expires_at: row.try_get("", "expires_at")?,
        last_used_at: row.try_get("", "last_used_at")?,
    })
}

/// Unrevoked keys, newest first. Members see their own keys; managers see
/// every key of the organization. `next` is the `before` value of the next page.
pub async fn list(
    rt: &Runtime,
    access: &OrgAccess,
    page: &PageRequest,
) -> ApiResult<(Vec<ApiKeySummary>, Option<i64>)> {
    let limit = page.limit();
    let rows = rt
        .control
        .query_all_raw(sql(
            &format!(
                "{SUMMARY} WHERE k.org_id = ? AND k.revoked_at IS NULL AND (? OR k.user_id = ?) AND k.id < ?
                 ORDER BY k.id DESC LIMIT ?"
            ),
            vec![
                access.org.as_str().into(),
                access.role.can_manage().into(),
                access.user.0.into(),
                page.cursor().unwrap_or(i64::MAX).into(),
                (limit as i64 + 1).into(),
            ],
        ))
        .await?;
    let mut keys = rows.iter().map(summary).collect::<ApiResult<Vec<_>>>()?;
    let next = (keys.len() > limit).then(|| {
        keys.truncate(limit);
        keys.last().map(|key| key.id)
    });
    Ok((keys, next.flatten()))
}

pub async fn get(rt: &Runtime, access: &OrgAccess, id: i64) -> ApiResult<ApiKeySummary> {
    let row = rt
        .control
        .query_one_raw(sql(
            &format!(
                "{SUMMARY} WHERE k.id = ? AND k.org_id = ? AND k.revoked_at IS NULL AND (? OR k.user_id = ?)"
            ),
            vec![
                id.into(),
                access.org.as_str().into(),
                access.role.can_manage().into(),
                access.user.0.into(),
            ],
        ))
        .await?
        .ok_or(ApiError::NotFound)?;
    summary(&row)
}

/// Revokes a key the caller may manage. Repeating the call succeeds.
pub async fn revoke(rt: &Runtime, access: &OrgAccess, id: i64) -> ApiResult<()> {
    let result = rt
        .control
        .execute_raw(sql(
            "UPDATE agent_api_keys SET revoked_at = COALESCE(revoked_at, ?)
             WHERE id = ? AND org_id = ? AND (? OR user_id = ?)",
            vec![
                now_secs().into(),
                id.into(),
                access.org.as_str().into(),
                access.role.can_manage().into(),
                access.user.0.into(),
            ],
        ))
        .await?;
    if result.rows_affected() == 0 {
        return Err(ApiError::NotFound);
    }
    Ok(())
}

/// Resolves an unrevoked, unexpired key. A key whose user left the
/// organization is `NoMembership`.
pub(crate) async fn authenticate(
    db: &DatabaseConnection,
    key: &Secret,
) -> Result<AgentPrincipal, BearerError> {
    let row = db
        .query_one_raw(sql(
            "SELECT k.id, k.user_id, k.org_id, k.scopes, m.role
             FROM agent_api_keys k
             LEFT JOIN memberships m ON m.org_id = k.org_id AND m.user_id = k.user_id
             WHERE k.key_hash = ? AND k.revoked_at IS NULL AND k.expires_at > ?",
            vec![key.hash().into(), now_secs().into()],
        ))
        .await?
        .ok_or(BearerError::Invalid)?;
    if row.try_get::<Option<String>>("", "role")?.is_none() {
        return Err(BearerError::NoMembership);
    }
    let org: String = row.try_get("", "org_id")?;
    Ok(AgentPrincipal {
        user: UserId(row.try_get("", "user_id")?),
        org: org
            .parse::<OrgId>()
            .map_err(|()| BearerError::Internal("stored api key organization".into()))?,
        scopes: ScopeSet::parse(&row.try_get::<String>("", "scopes")?)
            .ok_or_else(|| BearerError::Internal("stored api key scopes".into()))?,
        credential: Credential::ApiKey(row.try_get("", "id")?),
    })
}
