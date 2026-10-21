//! Request principals. `Session` authenticates a dashboard user; `OrgAccess`
//! authorizes that user for one organization. Ingestion keys never produce either.

use axum::{
    extract::{FromRequestParts, MatchedPath, RawPathParams},
    http::{request::Parts, Method},
};
use loco_rs::app::AppContext;
use sea_orm::ConnectionTrait;
use subtle::ConstantTimeEq;

use crate::{
    agent_policy::{route_access, RouteAccess},
    domain::{now_secs, OrgId, Role, UserId},
    error::{ApiError, ApiResult},
    identity::token_hash,
    runtime::{sql, Runtime},
};

pub const SESSION_COOKIE: &str = "pd_session";

#[derive(Clone)]
pub struct Session {
    pub id: i64,
    pub user: UserId,
    pub email: String,
    pub csrf_token: String,
}

impl std::fmt::Debug for Session {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Session")
            .field("id", &self.id)
            .field("user", &self.user)
            .finish_non_exhaustive()
    }
}

#[derive(Clone, Debug)]
pub struct OrgAccess {
    pub user: UserId,
    pub org: OrgId,
    pub role: Role,
}

impl OrgAccess {
    pub fn require_manage(&self) -> ApiResult<()> {
        if self.role.can_manage() {
            Ok(())
        } else {
            Err(ApiError::Forbidden)
        }
    }
}

/// Checks current membership. Call for every operation, including long-lived reads.
pub async fn authorize(rt: &Runtime, user: UserId, org: &OrgId) -> ApiResult<OrgAccess> {
    let row = rt
        .control
        .query_one_raw(sql(
            "SELECT m.role FROM memberships m JOIN organizations o ON o.id = m.org_id
             WHERE m.org_id = ? AND m.user_id = ? AND o.lifecycle = 'active'",
            vec![org.as_str().into(), user.0.into()],
        ))
        .await?
        .ok_or(ApiError::NotFound)?;
    let role: String = row.try_get("", "role")?;
    Ok(OrgAccess {
        user,
        org: org.clone(),
        role: Role::parse(&role).ok_or(ApiError::Internal("membership role".into()))?,
    })
}

pub(crate) fn cookie_value<'a>(parts: &'a Parts, name: &str) -> Option<&'a str> {
    parts
        .headers
        .get_all(axum::http::header::COOKIE)
        .iter()
        .filter_map(|value| value.to_str().ok())
        .flat_map(|value| value.split(';'))
        .filter_map(|pair| pair.trim().split_once('='))
        .find(|(key, _)| *key == name)
        .map(|(_, value)| value)
}

pub(crate) async fn resolve_session(rt: &Runtime, token: &str) -> ApiResult<Session> {
    let row = rt
        .control
        .query_one_raw(sql(
            "SELECT s.id, s.user_id, s.csrf_token, u.email FROM sessions s JOIN users u ON u.id = s.user_id
             WHERE s.token_hash = ? AND s.expires_at > ?",
            vec![token_hash(token).into(), now_secs().into()],
        ))
        .await?
        .ok_or(ApiError::Unauthorized)?;
    Ok(Session {
        id: row.try_get("", "id")?,
        user: UserId(row.try_get("", "user_id")?),
        email: row.try_get("", "email")?,
        csrf_token: row.try_get("", "csrf_token")?,
    })
}

fn check_unsafe_request(rt: &Runtime, parts: &Parts, session: &Session) -> ApiResult<()> {
    if matches!(parts.method, Method::GET | Method::HEAD | Method::OPTIONS) {
        return Ok(());
    }
    let header = |name: &str| parts.headers.get(name).and_then(|v| v.to_str().ok());
    if header("origin").is_some_and(|origin| origin != rt.settings.auth.origin) {
        return Err(ApiError::Forbidden);
    }
    if header("sec-fetch-site").is_some_and(|site| !matches!(site, "same-origin" | "none")) {
        return Err(ApiError::Forbidden);
    }
    let supplied = header("x-csrf-token").unwrap_or("");
    if supplied
        .as_bytes()
        .ct_eq(session.csrf_token.as_bytes())
        .into()
    {
        Ok(())
    } else {
        Err(ApiError::Forbidden)
    }
}

impl FromRequestParts<AppContext> for Session {
    type Rejection = ApiError;

    async fn from_request_parts(
        parts: &mut Parts,
        ctx: &AppContext,
    ) -> Result<Self, Self::Rejection> {
        if let Some(session) = parts.extensions.get::<Session>() {
            return Ok(session.clone());
        }
        let rt = Runtime::get(ctx);
        let token = cookie_value(parts, SESSION_COOKIE).ok_or(ApiError::Unauthorized)?;
        let session = resolve_session(&rt, token).await?;
        check_unsafe_request(&rt, parts, &session)?;
        parts.extensions.insert(session.clone());
        Ok(session)
    }
}

impl FromRequestParts<AppContext> for OrgAccess {
    type Rejection = ApiError;

    async fn from_request_parts(
        parts: &mut Parts,
        ctx: &AppContext,
    ) -> Result<Self, Self::Rejection> {
        let params = RawPathParams::from_request_parts(parts, ctx)
            .await
            .map_err(|_| ApiError::NotFound)?;
        let org = params
            .iter()
            .find(|(name, _)| *name == "org")
            .and_then(|(_, value)| value.parse::<OrgId>().ok())
            .ok_or(ApiError::NotFound)?;
        if let Some(header) = parts.headers.get(axum::http::header::AUTHORIZATION) {
            let token = header
                .to_str()
                .ok()
                .and_then(|value| value.strip_prefix("Bearer "))
                .ok_or(ApiError::Unauthorized)?;
            let oauth = ctx
                .shared_store
                .get::<crate::agent_access::OAuthService>()
                .ok_or_else(|| ApiError::Internal("OAuth service is missing".into()))?;
            let principal = crate::agent_access::authenticate(&oauth, token).await?;
            if principal.org != org {
                return Err(ApiError::NotFound);
            }
            let path = parts
                .extensions
                .get::<MatchedPath>()
                .map(MatchedPath::as_str)
                .ok_or(ApiError::Forbidden)?;
            let Some(RouteAccess::Bearer(required)) = route_access(&parts.method, path) else {
                return Err(ApiError::Forbidden);
            };
            let access = authorize(&Runtime::get(ctx), principal.user, &org).await?;
            principal
                .permits(required, access.role)
                .map_err(|_| ApiError::Forbidden)?;
            return Ok(access);
        }
        let session = Session::from_request_parts(parts, ctx).await?;
        authorize(&Runtime::get(ctx), session.user, &org).await
    }
}
