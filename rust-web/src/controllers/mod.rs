pub mod api_keys;
pub mod auth;
pub mod billing;
pub mod diagnostics;
pub mod health;
pub mod ingest;
pub mod issues;
pub mod logs;
pub mod orgs;
pub mod release_artifacts;

use axum::{
    extract::{FromRequestParts, Query},
    http::request::Parts,
};
use serde::{de::DeserializeOwned, Deserialize};

use crate::{error::ApiError, identity::projects::PageRequest};

/// A page of a list in ascending id order: `after` and `limit`. Any other
/// parameter, or a value that is malformed or out of range, is a JSON 400
/// `invalid_pagination`.
pub struct PageAfter(pub PageRequest);

/// A page of a list in descending id order: `before` and `limit`, validated
/// like [`PageAfter`].
pub struct PageBefore(pub PageRequest);

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct After {
    after: Option<i64>,
    limit: Option<i64>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Before {
    before: Option<i64>,
    limit: Option<i64>,
}

fn page_query<T: DeserializeOwned>(parts: &Parts) -> Result<T, ApiError> {
    Query::<T>::try_from_uri(&parts.uri)
        .map(|Query(query)| query)
        .map_err(|_| ApiError::BadRequest("invalid_pagination"))
}

impl<S: Send + Sync> FromRequestParts<S> for PageAfter {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, _: &S) -> Result<Self, Self::Rejection> {
        let After { after, limit } = page_query(parts)?;
        PageRequest::new(after, limit).map(Self)
    }
}

impl<S: Send + Sync> FromRequestParts<S> for PageBefore {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, _: &S) -> Result<Self, Self::Rejection> {
        let Before { before, limit } = page_query(parts)?;
        PageRequest::new(before, limit).map(Self)
    }
}
