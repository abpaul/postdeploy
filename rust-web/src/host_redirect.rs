use std::sync::Arc;

use axum::{
    extract::Request,
    http::{header, HeaderValue, StatusCode},
    middleware::Next,
    response::{IntoResponse, Response},
    Router,
};
use loco_rs::{Error, Result};
use serde::Deserialize;

/// A host that answers only with a redirect to `target`, keeping the path and
/// query. `308` keeps the method and body, which SDKs posting to a renamed
/// ingest host rely on.
#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HostRedirect {
    pub host: String,
    pub target: String,
    pub status: u16,
}

impl HostRedirect {
    pub fn validate(&self) -> Result<()> {
        let host_ok = !self.host.is_empty()
            && self
                .host
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'.' || b == b'-');
        let target_ok = self
            .target
            .strip_prefix("https://")
            .is_some_and(|rest| !rest.is_empty() && !rest.contains(['/', '?', '#']));
        if !host_ok || !target_ok || !matches!(self.status, 301 | 308) {
            return Err(Error::string(&format!(
                "invalid settings.host_redirects entry for host {:?}: host must be lowercase, target an https origin without a path, status 301 or 308",
                self.host
            )));
        }
        Ok(())
    }
}

pub fn install(router: Router, redirects: &[HostRedirect]) -> Router {
    if redirects.is_empty() {
        return router;
    }
    let redirects: Arc<[HostRedirect]> = redirects.into();
    router.layer(axum::middleware::from_fn(
        move |request: Request, next: Next| {
            let redirects = redirects.clone();
            async move { redirect(&redirects, request, next).await }
        },
    ))
}

async fn redirect(redirects: &[HostRedirect], request: Request, next: Next) -> Response {
    let host = request
        .headers()
        .get(header::HOST)
        .and_then(|value| value.to_str().ok())
        .map(|value| {
            value
                .split(':')
                .next()
                .unwrap_or(value)
                .to_ascii_lowercase()
        });
    let Some(rule) = host.and_then(|host| redirects.iter().find(|rule| rule.host == host)) else {
        return next.run(request).await;
    };
    let path = request
        .uri()
        .path_and_query()
        .map_or("/", |path| path.as_str());
    let status = StatusCode::from_u16(rule.status).unwrap_or(StatusCode::MOVED_PERMANENTLY);
    match HeaderValue::from_str(&format!("{}{path}", rule.target)) {
        Ok(location) => (status, [(header::LOCATION, location)]).into_response(),
        Err(_) => StatusCode::BAD_REQUEST.into_response(),
    }
}

#[cfg(test)]
mod tests {
    use axum::{body::Body, routing::any};
    use tower::ServiceExt;

    use super::*;

    fn rules() -> Vec<HostRedirect> {
        vec![
            HostRedirect {
                host: "alplus.dev".into(),
                target: "https://postdeploy.dev".into(),
                status: 301,
            },
            HostRedirect {
                host: "ingest.alplus.dev".into(),
                target: "https://ingest.postdeploy.dev".into(),
                status: 308,
            },
        ]
    }

    async fn call(method: &str, host: &str, uri: &str) -> (u16, Option<String>, String) {
        let app = install(Router::new().fallback(any(|| async { "app" })), &rules());
        let response = app
            .oneshot(
                Request::builder()
                    .method(method)
                    .uri(uri)
                    .header(header::HOST, host)
                    .body(Body::from("{}"))
                    .unwrap(),
            )
            .await
            .unwrap();
        let status = response.status().as_u16();
        let location = response
            .headers()
            .get(header::LOCATION)
            .map(|value| value.to_str().unwrap().to_owned());
        let body = axum::body::to_bytes(response.into_body(), 1024)
            .await
            .unwrap();
        (status, location, String::from_utf8(body.to_vec()).unwrap())
    }

    #[tokio::test]
    async fn legacy_hosts_redirect_with_path_and_query_and_other_hosts_reach_the_app() {
        assert_eq!(
            call("GET", "alplus.dev", "/pricing?x=1").await,
            (
                301,
                Some("https://postdeploy.dev/pricing?x=1".into()),
                String::new()
            )
        );
        assert_eq!(
            call(
                "POST",
                "INGEST.alplus.dev:443",
                "/api/1/envelope/?sentry_key=x"
            )
            .await,
            (
                308,
                Some("https://ingest.postdeploy.dev/api/1/envelope/?sentry_key=x".into()),
                String::new()
            )
        );
        assert_eq!(
            call("GET", "postdeploy.dev", "/pricing").await,
            (200, None, "app".into())
        );
    }

    #[test]
    fn invalid_rules_are_refused() {
        for (host, target, status) in [
            ("Alplus.dev", "https://postdeploy.dev", 301),
            ("alplus.dev", "http://postdeploy.dev", 301),
            ("alplus.dev", "https://postdeploy.dev/x", 301),
            ("alplus.dev", "https://postdeploy.dev", 302),
        ] {
            let rule = HostRedirect {
                host: host.into(),
                target: target.into(),
                status,
            };
            assert!(rule.validate().is_err(), "{host} {target} {status}");
        }
        assert!(rules().iter().all(|rule| rule.validate().is_ok()));
    }
}
