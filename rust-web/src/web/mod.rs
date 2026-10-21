mod auth;
mod billing;
mod dashboard;
mod oauth;
mod org;
mod page;
mod policy;
mod project;
mod site;

use std::sync::Arc;

use axum::{
    body::Bytes,
    extract::Extension,
    routing::{get, post},
    Router,
};
use loco_rs::controller::{
    views::{engines::TeraView, ViewEngine},
    Routes,
};
use tower_http::services::{ServeDir, ServeFile};

use self::{auth::Confirm, page::Web, policy::RegistrationGate};

pub fn routes() -> Routes {
    let org = "/dashboard/orgs/{org}";
    let project = "/dashboard/orgs/{org}/projects/{project}";
    site::routes(Routes::new())
        .add("/sign-in", get(auth::sign_in_form).post(auth::sign_in))
        .add("/register", get(auth::register_form).post(auth::register))
        .add("/sign-out", post(auth::sign_out))
        .add("/reset", get(auth::reset_form).post(auth::reset))
        .add(
            "/reset/complete",
            get(auth::reset_complete_form).post(auth::reset_complete),
        )
        .add(
            "/confirm",
            get(|web: Web| auth::confirm_form(web, Confirm::Account))
                .post(|web: Web, body: Bytes| auth::confirm(web, Confirm::Account, body)),
        )
        .add(
            "/confirm/email",
            get(|web: Web| auth::confirm_form(web, Confirm::EmailChange))
                .post(|web: Web, body: Bytes| auth::confirm(web, Confirm::EmailChange, body)),
        )
        .add(
            "/invitations/accept",
            get(auth::invitation_form).post(auth::accept_invitation),
        )
        .add("/dashboard", get(dashboard::index))
        .add("/dashboard/account", get(dashboard::account))
        .add("/dashboard/account/name", post(dashboard::account_name))
        .add("/dashboard/account/email", post(dashboard::account_email))
        .add(
            "/dashboard/account/confirmation",
            post(dashboard::account_confirmation),
        )
        .add(
            "/dashboard/orgs/new",
            get(dashboard::new_org_form).post(dashboard::new_org),
        )
        .add(org, get(dashboard::org_home))
        .add(&format!("{org}/open"), get(dashboard::open_project))
        .add(
            &format!("{org}/projects"),
            get(org::projects).post(org::create_project),
        )
        .add(&format!("{org}/team"), get(org::team).post(org::invite))
        .add(&format!("{org}/team/{{user}}/role"), post(org::set_role))
        .add(
            &format!("{org}/team/{{user}}/remove"),
            post(org::remove_member),
        )
        .add(
            &format!("{org}/team/{{user}}/transfer"),
            post(org::transfer),
        )
        .add(
            &format!("{org}/team/invitations/{{id}}/revoke"),
            post(org::revoke_invitation),
        )
        .add(&format!("{org}/settings"), get(org::settings))
        .add(&format!("{org}/settings/name"), post(org::rename))
        .add(
            &format!("{org}/settings/ingestion"),
            get(org::ingestion).post(org::save_ingestion),
        )
        .add(
            &format!("{org}/settings/api-keys"),
            post(org::create_api_key),
        )
        .add(
            &format!("{org}/settings/api-keys/{{key}}/revoke"),
            post(org::revoke_api_key),
        )
        .add(&format!("{org}/billing"), get(billing::show))
        .add(&format!("{org}/billing/checkout"), post(billing::checkout))
        .add(&format!("{org}/billing/portal"), post(billing::portal))
        .add(&format!("{org}/billing/refresh"), post(billing::refresh))
        .add(&format!("{org}/delete"), post(org::delete))
        .add(
            &format!("{org}/settings/notifications"),
            get(org::notifications),
        )
        .add(
            &format!("{org}/settings/notifications/email"),
            post(org::add_email),
        )
        .add(
            &format!("{org}/settings/notifications/webhook"),
            post(org::add_webhook),
        )
        .add(
            &format!("{org}/settings/notifications/{{destination}}/delete"),
            post(org::delete_destination),
        )
        .add(
            &format!("{org}/access/grants/{{grant}}/revoke"),
            post(org::revoke_grant),
        )
        .add(project, get(project::report))
        .add(
            &format!("{project}/reports/{{report}}"),
            get(project::report_by_id),
        )
        .add(&format!("{project}/observe"), get(project::issues))
        .add(
            &format!("{project}/observe/issues/{{issue}}"),
            get(project::issue),
        )
        .add(
            &format!("{project}/observe/issues/{{issue}}/{{action}}"),
            post(project::set_issue_status),
        )
        .add(&format!("{project}/logs"), get(project::logs))
        .add(&format!("{project}/deployments"), get(project::deployments))
        .add(
            &format!("{project}/sources"),
            get(project::sources).post(project::create_source),
        )
        .add(
            &format!("{project}/sources/{{source}}"),
            get(project::source),
        )
        .add(
            &format!("{project}/sources/{{source}}/status"),
            get(project::source_status),
        )
        .add(
            &format!("{project}/sources/{{source}}/test-event"),
            post(project::send_test_event),
        )
        .add(
            &format!("{project}/sources/{{source}}/rotate"),
            post(project::rotate_source),
        )
        .add(
            &format!("{project}/sources/{{source}}/revoke"),
            post(project::revoke_source),
        )
        .add(&format!("{project}/access"), get(project::access))
        .add(
            &format!("{project}/access/grants/{{grant}}/revoke"),
            post(project::revoke_grant),
        )
        .add(
            "/.well-known/oauth-authorization-server",
            get(oauth::authorization_server),
        )
        .add(
            "/.well-known/oauth-protected-resource/mcp",
            get(oauth::protected_resource),
        )
        .add("/oauth/register", post(oauth::register))
        .add(
            "/oauth/authorize",
            get(oauth::authorize_form).post(oauth::authorize),
        )
        .add("/oauth/token", post(oauth::token))
        .add("/oauth/revoke", post(oauth::revoke))
}

const STATIC_ROOT: &str = "assets/static";
const STATIC_FILES: [&str; 5] = [
    "/favicon.svg",
    "/favicon.ico",
    "/favicon-16x16.png",
    "/favicon-32x32.png",
    "/apple-touch-icon.png",
];
const STATIC_DIRS: [&str; 6] = ["/css", "/fonts", "/js", "/brand", "/images", "/licenses"];

/// Adds the Tera view engine for `assets/views`, the files under
/// `assets/static` that pages link, the registration limiter, and the HTML 404
/// page for unknown routes.
pub fn install(router: Router) -> loco_rs::Result<Router> {
    let views = TeraView::build()?;
    page::keep_views(views.clone());
    let mut router = router;
    for file in STATIC_FILES {
        router = router.route_service(file, ServeFile::new(format!("{STATIC_ROOT}{file}")));
    }
    for dir in STATIC_DIRS {
        router = router.nest_service(
            dir,
            ServeDir::new(format!("{STATIC_ROOT}{dir}")).fallback(get(page::not_found)),
        );
    }
    Ok(router
        .fallback(page::not_found)
        .layer(Extension(Arc::new(RegistrationGate::default())))
        .layer(Extension(ViewEngine::from(views))))
}
