//! Public pages. Plan numbers come from the billing constants and retention
//! from the running settings, so the copy matches the deployed service.

use std::sync::OnceLock;

use axum::{
    http::{header, Method, StatusCode},
    response::{IntoResponse, Response},
    routing::get,
};
use loco_rs::controller::Routes;
use serde::Serialize;
use serde_json::{json, Value};

use crate::{
    agent_access::Scope,
    agent_policy::{route_access, RouteAccess},
    billing::{MONTHLY_ERRORS, MONTHLY_LOG_BYTES, PLAN_PRICE_CENTS, TRIAL_SECS},
};

use super::{page::Web, policy};

pub struct PublicPage {
    pub path: &'static str,
    template: &'static str,
    title: fn(&Plan) -> String,
    description: fn(&Plan) -> String,
}

pub static PAGES: [PublicPage; 10] = [
    PublicPage {
        path: "/",
        template: "site/home.html",
        title: |_| "PostDeploy: production errors and logs for your coding agent".into(),
        description: |plan| {
            format!(
                "Errors, logs and deployments from your existing Sentry SDK, read by your coding agent over MCP. {} per year per organization. {}-day free trial, no credit card.",
                plan.price, plan.trial_days
            )
        },
    },
    PublicPage {
        path: "/pricing",
        template: "site/pricing.html",
        title: |plan| {
            format!(
                "Pricing: {} per year per organization | PostDeploy",
                plan.price
            )
        },
        description: |plan| {
            let retention = if plan.error_retention_days == plan.log_retention_days {
                format!("{}-day retention", plan.log_retention_days)
            } else {
                format!(
                    "{}-day error retention, {}-day log retention",
                    plan.error_retention_days, plan.log_retention_days
                )
            };
            format!(
                "One PostDeploy plan: {} per year per organization, billed annually. {} of logs and {} error events per month, {retention}, unlimited projects and members.",
                plan.price, plan.log_volume, plan.errors
            )
        },
    },
    PublicPage {
        path: "/docs",
        template: "site/docs/index.html",
        title: |_| "Documentation | PostDeploy".into(),
        description: |_| {
            "Send your first error, connect a coding agent, call the HTTP API, and learn how usage and retention work.".into()
        },
    },
    PublicPage {
        path: "/docs/quickstart",
        template: "site/docs/quickstart.html",
        title: |_| "Quickstart: send your first error | PostDeploy".into(),
        description: |_| {
            "Create a source, add its DSN to a Sentry SDK, and confirm that the first error arrives. Includes the tested SDK versions.".into()
        },
    },
    PublicPage {
        path: "/docs/agents",
        template: "site/docs/agents.html",
        title: |_| "Connect a coding agent | PostDeploy".into(),
        description: |_| {
            "Connect an MCP client with OAuth or an API key, choose its access scopes, and run a first investigation.".into()
        },
    },
    PublicPage {
        path: "/docs/api",
        template: "site/docs/api.html",
        title: |_| "HTTP API | PostDeploy".into(),
        description: |_| {
            "Authenticate with a bearer token and read issues, logs, deployments and usage over HTTP.".into()
        },
    },
    PublicPage {
        path: "/docs/usage-and-retention",
        template: "site/docs/usage.html",
        title: |_| "Usage, limits and data retention | PostDeploy".into(),
        description: |_| {
            "What counts toward the plan, what happens at a limit or after the trial, where data is stored and how long it is kept.".into()
        },
    },
    PublicPage {
        path: "/privacy",
        template: "site/privacy.html",
        title: |_| "Privacy and data handling | PostDeploy".into(),
        description: |_| {
            "What PostDeploy stores, what it redacts before storage, where data is stored and how long it is kept.".into()
        },
    },
    PublicPage {
        path: "/terms",
        template: "site/terms.html",
        title: |_| "Terms of service | PostDeploy".into(),
        description: |_| {
            "PostDeploy terms of service: the trial, annual billing, monthly allowances, data deletion, and no promised service level.".into()
        },
    },
    PublicPage {
        path: "/about",
        template: "site/about.html",
        title: |_| "About PostDeploy | PostDeploy".into(),
        description: |_| "Who PostDeploy is for and who builds and runs it.".into(),
    },
];

/// Elixir documentation paths whose content moved to a page here.
const MOVED: [(&str, &str); 3] = [
    ("/docs/get-started", "/docs/quickstart"),
    ("/docs/mcp", "/docs/agents"),
    ("/docs/projects-and-keys", "/docs/quickstart"),
];

pub fn routes(routes: Routes) -> Routes {
    let routes = PAGES.iter().fold(routes, |routes, page| {
        routes.add(page.path, get(move |web: Web| show(web, page)))
    });
    MOVED
        .into_iter()
        .fold(routes, |routes, (from, to)| {
            routes.add(
                from,
                get(move || async move {
                    (StatusCode::MOVED_PERMANENTLY, [(header::LOCATION, to)])
                }),
            )
        })
        .add("/sitemap.xml", get(sitemap))
        .add("/robots.txt", get(robots))
        .add("/llms.txt", get(llms))
}

fn text(content_type: &'static str, body: String) -> Response {
    (
        [
            (header::CONTENT_TYPE, content_type),
            (header::CACHE_CONTROL, "public, max-age=3600"),
        ],
        body,
    )
        .into_response()
}

async fn sitemap(web: Web) -> Response {
    let urls: String = PAGES
        .iter()
        .map(|page| format!("  <url><loc>{}{}</loc></url>\n", origin(&web), page.path))
        .collect();
    text(
        "application/xml",
        format!("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n{urls}</urlset>\n"),
    )
}

async fn robots(web: Web) -> Response {
    text(
        "text/plain; charset=utf-8",
        format!(
            "User-agent: *\nDisallow: /dashboard\nDisallow: /oauth/\nDisallow: /api/\nDisallow: /sign-out\n\nSitemap: {}/sitemap.xml\n",
            origin(&web)
        ),
    )
}

async fn llms(web: Web) -> Response {
    let origin = origin(&web);
    text(
        "text/plain; charset=utf-8",
        format!(
            "# PostDeploy\n\n\
             > Production debugging built for AI agents. PostDeploy stores application errors, structured logs and deployments, and serves them to coding agents over MCP and HTTP.\n\n\
             MCP server: {mcp}\n\n\
             ## Docs\n\n\
             - [Quickstart]({origin}/docs/quickstart): create a source and send the first error with a Sentry SDK.\n\
             - [Connect a coding agent]({origin}/docs/agents): MCP with OAuth, API keys and access scopes.\n\
             - [HTTP API]({origin}/docs/api): bearer authentication and the organization endpoints.\n\
             - [Usage, limits and data retention]({origin}/docs/usage-and-retention): allowances, refusals and retention.\n",
            mcp = web.rt.settings.oauth.resource,
        ),
    )
}

fn origin(web: &Web) -> &str {
    web.rt.settings.oauth.issuer.trim_end_matches('/')
}

fn dollars(cents: i64) -> String {
    match cents % 100 {
        0 => format!("${}", cents / 100),
        rest => format!("${}.{rest:02}", cents / 100),
    }
}

fn count(value: u64) -> String {
    match value % 1_000_000 {
        0 => format!("{} million", value / 1_000_000),
        _ => value.to_string(),
    }
}

/// The plan as public pages state it: billing constants and running settings.
#[derive(Serialize)]
struct Plan {
    price: String,
    trial_days: i64,
    errors: String,
    log_volume: String,
    error_retention_days: u64,
    log_retention_days: u64,
    backup_retention_days: u32,
    mcp_url: String,
    public_url: String,
}

impl Plan {
    fn new(web: &Web) -> Self {
        let settings = &web.rt.settings;
        Self {
            price: dollars(PLAN_PRICE_CENTS),
            trial_days: TRIAL_SECS / 86_400,
            errors: count(MONTHLY_ERRORS),
            log_volume: format!("{} GB", MONTHLY_LOG_BYTES / 1_000_000_000),
            error_retention_days: settings.error_retention.event_days.into(),
            log_retention_days: settings.logs.retention().as_secs() / 86_400,
            backup_retention_days: settings.backup.retention_days,
            mcp_url: settings.oauth.resource.clone(),
            public_url: origin(web).to_owned(),
        }
    }
}

fn scopes() -> Vec<Value> {
    Scope::ALL
        .into_iter()
        .map(|scope| {
            let mut row = policy::scope_row(scope);
            row["manager"] = json!(scope.needs_manager());
            row
        })
        .collect()
}

/// The organization API routes from the application route table, split by
/// whether a bearer credential may call them.
fn api_routes() -> &'static Value {
    static ROUTES: OnceLock<Value> = OnceLock::new();
    ROUTES.get_or_init(|| {
        let mut routes: Vec<(String, Method)> = crate::app::app_routes()
            .collect()
            .into_iter()
            .filter(|route| route.uri.starts_with("/api/orgs"))
            .flat_map(|route| {
                let path = route.uri.trim_end_matches('/').to_owned();
                route
                    .actions
                    .into_iter()
                    .map(move |method| (path.clone(), method))
            })
            .collect();
        routes.sort_by(|a, b| (&a.0, a.1.as_str()).cmp(&(&b.0, b.1.as_str())));
        routes.dedup();
        let (mut bearer, mut session) = (Vec::new(), Vec::new());
        for (path, method) in routes {
            match route_access(&method, &path) {
                Some(RouteAccess::Bearer(required)) => bearer.push(json!({
                    "method": method.as_str(),
                    "path": path,
                    "scopes": required.iter().map(|scope| scope.as_str()).collect::<Vec<_>>(),
                })),
                Some(RouteAccess::SessionOnly) | None => {
                    session.push(json!({"method": method.as_str(), "path": path}));
                }
            }
        }
        json!({"bearer": bearer, "session": session})
    })
}

async fn show(web: Web, page: &'static PublicPage) -> Response {
    let signed_in = web.session().await.is_some();
    let plan = Plan::new(&web);
    let mut view = web.public_page(&(page.title)(&plan));
    view.set("description", (page.description)(&plan))
        .set("canonical", format!("{}{}", origin(&web), page.path))
        .set("current", page.path)
        .set("signed_in", signed_in)
        .set("docs", page.path.starts_with("/docs"))
        .set("plan", json!(plan))
        .set("scopes", scopes())
        .set("api_routes", api_routes().clone());
    web.render(view, page.template)
}
