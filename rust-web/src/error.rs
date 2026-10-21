use std::time::Duration;

use axum::{
    http::{header, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use serde_json::json;

/// Errors returned to HTTP callers. Responses carry fixed messages only; causes
/// stay in operational logs, which never receive request bodies.
#[derive(Debug, thiserror::Error)]
pub enum ApiError {
    #[error("bad request: {0}")]
    BadRequest(&'static str),
    #[error("unauthorized")]
    Unauthorized,
    #[error("invalid ingestion key")]
    InvalidKey,
    #[error("forbidden")]
    Forbidden,
    #[error("not found")]
    NotFound,
    #[error("conflict: {0}")]
    Conflict(&'static str),
    #[error("payload too large")]
    TooLarge,
    #[error("unsupported content encoding")]
    UnsupportedEncoding,
    #[error("rate limited")]
    RateLimited {
        retry: Duration,
        categories: &'static str,
    },
    #[error("unavailable: {0}")]
    Unavailable(&'static str),
    #[error("internal: {0}")]
    Internal(String),
}

pub type ApiResult<T> = Result<T, ApiError>;

impl ApiError {
    pub fn internal(context: &str, error: impl std::fmt::Display) -> Self {
        Self::Internal(format!("{context}: {error}"))
    }

    /// The `Retry-After` value in seconds. MCP results carry the same number.
    pub fn retry_after_secs(&self) -> Option<u64> {
        match self {
            Self::RateLimited { retry, .. } => Some(retry.as_secs().max(1)),
            Self::Unavailable(_) => Some(1),
            _ => None,
        }
    }
}

impl From<sea_orm::DbErr> for ApiError {
    fn from(error: sea_orm::DbErr) -> Self {
        Self::internal("database", error)
    }
}

impl From<tenant_sqlite_loco::Error> for ApiError {
    fn from(error: tenant_sqlite_loco::Error) -> Self {
        match error {
            tenant_sqlite_loco::Error::Capacity | tenant_sqlite_loco::Error::Shutdown => {
                Self::Unavailable("tenant_unavailable")
            }
            other => Self::internal("tenant", other),
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let (status, code) = match &self {
            Self::BadRequest(code) => (StatusCode::BAD_REQUEST, *code),
            Self::Unauthorized => (StatusCode::UNAUTHORIZED, "unauthorized"),
            Self::InvalidKey => (StatusCode::UNAUTHORIZED, "invalid_api_key"),
            Self::Forbidden => (StatusCode::FORBIDDEN, "forbidden"),
            Self::NotFound => (StatusCode::NOT_FOUND, "not_found"),
            Self::Conflict(code) => (StatusCode::CONFLICT, *code),
            Self::TooLarge => (StatusCode::PAYLOAD_TOO_LARGE, "body_too_large"),
            Self::UnsupportedEncoding => (
                StatusCode::UNSUPPORTED_MEDIA_TYPE,
                "content_encoding_unsupported",
            ),
            Self::RateLimited { .. } => (StatusCode::TOO_MANY_REQUESTS, "rate_limited"),
            Self::Unavailable(code) => (StatusCode::SERVICE_UNAVAILABLE, *code),
            Self::Internal(cause) => {
                tracing::error!(cause = %cause, "request failed");
                (StatusCode::INTERNAL_SERVER_ERROR, "internal_error")
            }
        };
        let mut response = (status, Json(json!({ "error": code }))).into_response();
        let headers = response.headers_mut();
        if let Some(secs) = self.retry_after_secs() {
            headers.insert(header::RETRY_AFTER, HeaderValue::from(secs));
            if let Self::RateLimited { categories, .. } = &self {
                if let Ok(value) =
                    HeaderValue::from_str(&format!("{secs}:{categories}:organization"))
                {
                    headers.insert("x-sentry-rate-limits", value);
                }
            }
        }
        response
    }
}
