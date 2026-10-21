//! Which organization routes accept a bearer credential, and the scopes each
//! one requires. Every scope in a requirement must be granted. A route that is
//! not listed here refuses bearers.

use axum::http::Method;
use loco_rs::controller::AppRoutes;

use crate::agent_access::Scope::{self, *};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RouteAccess {
    Bearer(&'static [Scope]),
    SessionOnly,
}

struct OrgRoute {
    method: Method,
    path: &'static str,
    access: RouteAccess,
}

const fn bearer(method: Method, path: &'static str, scopes: &'static [Scope]) -> OrgRoute {
    OrgRoute {
        method,
        path,
        access: RouteAccess::Bearer(scopes),
    }
}

const fn session(method: Method, path: &'static str) -> OrgRoute {
    OrgRoute {
        method,
        path,
        access: RouteAccess::SessionOnly,
    }
}

/// Dashboard pages authenticate with the session cookie only.
const DASHBOARD: &str = "/dashboard/orgs/{org}";

const API: &[OrgRoute] = &[
    session(Method::GET, "/api/orgs/{org}"),
    session(Method::GET, "/api/orgs/{org}/members"),
    session(Method::POST, "/api/orgs/{org}/members"),
    session(Method::DELETE, "/api/orgs/{org}/members/{user}"),
    bearer(Method::GET, "/api/orgs/{org}/projects", &[ProjectsRead]),
    bearer(Method::POST, "/api/orgs/{org}/projects", &[ProjectsWrite]),
    bearer(
        Method::GET,
        "/api/orgs/{org}/projects/{project}/sources",
        &[ProjectsRead],
    ),
    bearer(
        Method::POST,
        "/api/orgs/{org}/projects/{project}/sources",
        &[ProjectsWrite],
    ),
    bearer(
        Method::POST,
        "/api/orgs/{org}/sources/{source}/keys",
        &[ProjectsWrite],
    ),
    bearer(
        Method::DELETE,
        "/api/orgs/{org}/sources/{source}/keys/{key}",
        &[ProjectsWrite],
    ),
    bearer(
        Method::GET,
        "/api/orgs/{org}/ingestion-policy",
        &[ProjectsRead],
    ),
    session(Method::PUT, "/api/orgs/{org}/ingestion-policy"),
    session(Method::GET, "/api/orgs/{org}/billing"),
    bearer(Method::GET, "/api/orgs/{org}/usage", &[ProjectsRead]),
    session(Method::POST, "/api/orgs/{org}/billing/checkout"),
    session(Method::POST, "/api/orgs/{org}/billing/portal"),
    session(Method::POST, "/api/orgs/{org}/billing/refresh"),
    bearer(Method::GET, "/api/orgs/{org}/issues", &[IssuesRead]),
    bearer(Method::GET, "/api/orgs/{org}/issues/{issue}", &[IssuesRead]),
    bearer(
        Method::PATCH,
        "/api/orgs/{org}/issues/{issue}",
        &[IssuesTriage],
    ),
    bearer(
        Method::GET,
        "/api/orgs/{org}/issues/{issue}/events",
        &[IssuesRead],
    ),
    bearer(
        Method::GET,
        "/api/orgs/{org}/issues/{issue}/events/{event}",
        &[IssuesRead],
    ),
    bearer(
        Method::GET,
        "/api/orgs/{org}/projects/{project}/deployments",
        &[ProjectsRead],
    ),
    bearer(
        Method::POST,
        "/api/orgs/{org}/projects/{project}/deployments",
        &[DeploymentsWrite],
    ),
    bearer(
        Method::GET,
        "/api/orgs/{org}/deployments/{deployment}/comparison",
        &[IssuesRead],
    ),
    bearer(
        Method::GET,
        "/api/orgs/{org}/issues/{issue}/recurrence",
        &[IssuesRead],
    ),
    bearer(
        Method::GET,
        "/api/orgs/{org}/issues/{issue}/context",
        &[IssuesRead, LogsRead],
    ),
    bearer(Method::GET, "/api/orgs/{org}/logs", &[LogsRead]),
    session(Method::GET, "/api/orgs/{org}/logs/tail"),
    bearer(Method::GET, "/api/orgs/{org}/logs/storage", &[LogsRead]),
    bearer(
        Method::GET,
        "/api/orgs/{org}/projects/{project}/artifacts",
        &[ProjectsRead],
    ),
    bearer(
        Method::POST,
        "/api/orgs/{org}/projects/{project}/artifacts",
        &[ProjectsWrite],
    ),
    bearer(
        Method::GET,
        "/api/orgs/{org}/projects/{project}/releases",
        &[ProjectsRead],
    ),
    bearer(
        Method::GET,
        "/api/orgs/{org}/artifacts/{artifact}",
        &[ProjectsRead],
    ),
    bearer(
        Method::DELETE,
        "/api/orgs/{org}/artifacts/{artifact}",
        &[ProjectsWrite],
    ),
    session(Method::GET, "/api/orgs/{org}/api-keys"),
    session(Method::POST, "/api/orgs/{org}/api-keys"),
    session(Method::GET, "/api/orgs/{org}/api-keys/{key}"),
    session(Method::DELETE, "/api/orgs/{org}/api-keys/{key}"),
];

pub fn route_access(method: &Method, path: &str) -> Option<RouteAccess> {
    if path == DASHBOARD || path.starts_with(&format!("{DASHBOARD}/")) {
        return Some(RouteAccess::SessionOnly);
    }
    API.iter()
        .find(|route| route.method == method && route.path == path)
        .map(|route| route.access)
}

/// Organization routes of `routes` without an access rule, as `METHOD path`.
pub fn unmapped_org_routes(routes: &AppRoutes) -> Vec<String> {
    routes
        .collect()
        .iter()
        .filter(|route| route.uri.contains("{org}"))
        .flat_map(|route| {
            route
                .actions
                .iter()
                .filter(|method| route_access(method, &route.uri).is_none())
                .map(|method| format!("{method} {}", route.uri))
                .collect::<Vec<_>>()
        })
        .collect()
}

/// Table rows that match no route of `routes`, as `METHOD path`.
pub fn stale_rules(routes: &AppRoutes) -> Vec<String> {
    let collected = routes.collect();
    API.iter()
        .filter(|rule| {
            !collected
                .iter()
                .any(|route| route.uri == rule.path && route.actions.contains(&rule.method))
        })
        .map(|rule| format!("{} {}", rule.method, rule.path))
        .collect()
}

#[cfg(test)]
mod tests {
    use axum::routing::get;
    use loco_rs::controller::Routes;

    use super::*;

    #[test]
    fn every_organization_route_has_an_access_rule() {
        let routes = crate::app::app_routes();
        assert_eq!(unmapped_org_routes(&routes), Vec::<String>::new());
        assert_eq!(stale_rules(&routes), Vec::<String>::new());
    }

    #[test]
    fn a_new_unmapped_organization_route_fails_the_coverage_check() {
        let routes = crate::app::app_routes().add_route(
            Routes::new()
                .prefix("/api/orgs/{org}")
                .add("/exports", get(|| async { "" }).post(|| async { "" })),
        );
        assert_eq!(
            unmapped_org_routes(&routes),
            vec![
                "GET /api/orgs/{org}/exports".to_owned(),
                "POST /api/orgs/{org}/exports".to_owned()
            ]
        );
    }
}
