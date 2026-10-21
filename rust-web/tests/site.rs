mod support;

use loco_rs::{app::Hooks, boot::BootResult};
use postdeploy::testing::{serve, TestApp, TestEnv};
use reqwest::{header, Client, StatusCode};
use serde_json::{json, Value};
use support::Api;

const PUBLIC_URL: &str = "http://127.0.0.1:5167";

struct Site {
    boot: BootResult,
    server: tokio::task::JoinHandle<()>,
    base: String,
    http: Client,
}

struct Fetched {
    status: StatusCode,
    headers: header::HeaderMap,
    body: String,
}

impl Site {
    /// Boots with the application's default log retention instead of the
    /// shorter retention in the test configuration.
    async fn start(name: &str) -> Self {
        Self::start_with(name, |s| {
            s["logs"].as_object_mut().unwrap().remove("retention_secs");
        })
        .await
    }

    async fn start_with(name: &str, settings: impl FnOnce(&mut Value)) -> Self {
        let _ = tracing_subscriber::fmt()
            .with_env_filter("off,postdeploy=error")
            .with_test_writer()
            .try_init();
        let env = TestEnv::new(name);
        let boot = env.boot_memory(settings).await.unwrap();
        let (base, server) = serve(&boot).await;
        let http = Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .unwrap();
        Self {
            boot,
            server,
            base,
            http,
        }
    }

    async fn fetch_with(&self, path: &str, cookie: Option<&str>) -> Fetched {
        let mut request = self.http.get(format!("{}{path}", self.base));
        if let Some(cookie) = cookie {
            request = request.header(header::COOKIE, cookie);
        }
        let response = request.send().await.unwrap();
        Fetched {
            status: response.status(),
            headers: response.headers().clone(),
            body: response.text().await.unwrap(),
        }
    }

    async fn fetch(&self, path: &str) -> Fetched {
        self.fetch_with(path, None).await
    }

    async fn page(&self, path: &str) -> String {
        let page = self.fetch(path).await;
        assert_eq!(page.status, StatusCode::OK, "GET {path}");
        assert!(
            page.headers[header::CONTENT_TYPE]
                .to_str()
                .unwrap()
                .starts_with("text/html"),
            "GET {path} is HTML"
        );
        assert!(!page.body.contains("{{"), "GET {path} renders templates");
        page.body
    }

    async fn form(&self, path: &str, api: &Api, json: bool) -> reqwest::Response {
        self.form_fields(path, api, &[], json).await
    }

    async fn form_fields(
        &self,
        path: &str,
        api: &Api,
        fields: &[(&str, &str)],
        json: bool,
    ) -> reqwest::Response {
        let mut values = fields.to_vec();
        values.push(("_csrf_token", api.csrf.as_deref().unwrap()));
        let mut request = self
            .http
            .post(format!("{}{path}", self.base))
            .header(header::ORIGIN, PUBLIC_URL)
            .header(header::COOKIE, api.cookie.as_deref().unwrap())
            .form(&values);
        if json {
            request = request.header(header::ACCEPT, "application/json");
        }
        request.send().await.unwrap()
    }

    async fn json(&self, path: &str, api: &Api) -> Value {
        let response = self.fetch_with(path, api.cookie.as_deref()).await;
        assert_eq!(response.status, StatusCode::OK, "GET {path}");
        serde_json::from_str(&response.body).unwrap()
    }

    async fn stop(self) {
        self.server.abort();
        TestApp::on_shutdown(&self.boot.app_context).await;
    }
}

fn occurrences(haystack: &str, needle: &str) -> usize {
    haystack.matches(needle).count()
}

fn between<'a>(text: &'a str, start: &str, end: &str) -> &'a str {
    text.split_once(start)
        .and_then(|(_, rest)| rest.split_once(end))
        .map(|(value, _)| value)
        .unwrap_or_else(|| panic!("text contains {start}...{end}"))
}

fn title(html: &str) -> &str {
    html.split_once("<title>")
        .and_then(|(_, rest)| rest.split_once("</title>"))
        .map(|(title, _)| title)
        .expect("page has a title")
}

#[tokio::test]
async fn home_states_positioning_and_trial_cta() {
    let site = Site::start("site-home").await;
    let home = site.page("/").await;
    for expected in [
        "Your coding agent can read your code. Now it can read production.",
        "Start 14-day free trial",
        "No credit card. $449 per year per organization after the trial.",
        "claude mcp add --transport http postdeploy http://127.0.0.1:5167/mcp",
        "codex mcp add postdeploy --url http://127.0.0.1:5167/mcp",
        "$449 per year for one organization, every feature included.",
        "1 million per month",
        "100 GB per month",
        "90 days",
        "href=\"/docs/quickstart\"",
        "href=\"/docs/api\"",
        "href=\"/pricing\"",
        "href=\"/privacy\"",
        "href=\"/sign-in\"",
    ] {
        assert!(home.contains(expected), "home contains {expected}");
    }
    let hero = between(&home, "id=\"home-hero\"", "</section>");
    assert_eq!(occurrences(hero, "href=\"/register\""), 1, "one hero CTA");
    assert_eq!(occurrences(hero, "<a "), 2, "hero CTA and agent setup link");
    assert!(
        hero.contains("href=\"/docs/agents\""),
        "hero links agent setup"
    );
    assert!(
        !home.contains("href=\"/dashboard\""),
        "signed-out home has no dashboard link"
    );
    assert_eq!(
        title(&home),
        "PostDeploy: production errors and logs for your coding agent"
    );
    assert!(home.contains("<meta name=\"description\" content=\"Errors, logs and deployments from your existing Sentry SDK, read by your coding agent over MCP. $449 per year per organization. 14-day free trial, no credit card.\">"));
    assert!(home.contains(&format!("<link rel=\"canonical\" href=\"{PUBLIC_URL}/\">")));
    assert!(home.contains("<meta property=\"og:title\" content=\"PostDeploy: production errors and logs for your coding agent\">"));
    assert!(home.contains("<link rel=\"stylesheet\" href=\"/css/site.css\">"));
    assert!(!home.contains("name=\"robots\""), "home is indexable");
    assert_eq!(occurrences(&home, "<h1"), 1, "one h1");
    assert_eq!(
        occurrences(&home, "<script src=\"http"),
        0,
        "no third-party script"
    );
    let stylesheet = site.fetch("/css/site.css").await;
    assert_eq!(stylesheet.status, StatusCode::OK, "site.css is served");
    assert_eq!(stylesheet.headers[header::CONTENT_TYPE], "text/css");
    site.stop().await;
}

#[tokio::test]
async fn plan_copy_follows_running_retention() {
    let site = Site::start_with("site-split-retention", |s| {
        s["logs"]["retention_secs"] = json!(30 * 86_400);
    })
    .await;
    let home = site.page("/").await;
    assert!(
        home.contains("Errors 90 days, logs 30 days"),
        "home retention"
    );
    let pricing = site.page("/pricing").await;
    assert!(pricing.contains("<meta name=\"description\" content=\"One PostDeploy plan: $449 per year per organization, billed annually. 100 GB of logs and 1 million error events per month, 90-day error retention, 30-day log retention, unlimited projects and members.\">"));
    site.stop().await;
}

#[tokio::test]
async fn agent_docs_list_client_commands() {
    let site = Site::start("site-agent-docs").await;
    let docs = site.page("/docs/agents").await;
    for expected in [
        "claude mcp add --transport http postdeploy http://127.0.0.1:5167/mcp",
        "codex mcp add postdeploy --url http://127.0.0.1:5167/mcp",
        "codex mcp login postdeploy",
        "\"url\": \"http://127.0.0.1:5167/mcp\"",
    ] {
        assert!(docs.contains(expected), "agent docs contain {expected}");
    }
    site.stop().await;
}

#[tokio::test]
async fn signed_in_home_links_dashboard() {
    let site = Site::start("site-home-signed-in").await;
    let api = Api::signup(&site.base, "home-visitor@example.invalid").await;
    let home = site.fetch_with("/", api.cookie.as_deref()).await;
    assert_eq!(home.status, StatusCode::OK);
    assert!(home.body.contains("href=\"/dashboard\""), "dashboard link");
    assert!(
        !home.body.contains("href=\"/sign-in\""),
        "signed-in home has no sign-in link"
    );
    site.stop().await;
}

#[tokio::test]
async fn console_pages_are_not_indexed() {
    let site = Site::start("site-console-noindex").await;
    let api = Api::signup(&site.base, "noindex@example.invalid").await;
    let dashboard = site.fetch_with("/dashboard", api.cookie.as_deref()).await;
    assert_eq!(dashboard.status, StatusCode::OK);
    assert!(dashboard
        .body
        .contains("<meta name=\"robots\" content=\"noindex\">"));
    site.stop().await;
}

const PUBLIC_PAGES: [(&str, &str); 10] = [
    (
        "/",
        "PostDeploy: production errors and logs for your coding agent",
    ),
    (
        "/pricing",
        "Pricing: $449 per year per organization | PostDeploy",
    ),
    ("/docs", "Documentation | PostDeploy"),
    (
        "/docs/quickstart",
        "Quickstart: send your first error | PostDeploy",
    ),
    ("/docs/agents", "Connect a coding agent | PostDeploy"),
    ("/docs/api", "HTTP API | PostDeploy"),
    (
        "/docs/usage-and-retention",
        "Usage, limits and data retention | PostDeploy",
    ),
    ("/privacy", "Privacy and data handling | PostDeploy"),
    ("/terms", "Terms of service | PostDeploy"),
    ("/about", "About PostDeploy | PostDeploy"),
];

#[tokio::test]
async fn public_pages_have_title_canonical_and_one_h1() {
    let site = Site::start("site-page-metadata").await;
    for (path, expected) in PUBLIC_PAGES {
        let fetched = site.fetch(path).await;
        assert!(
            fetched.headers.get(header::SET_COOKIE).is_none(),
            "{path} sets no cookie"
        );
        let page = site.page(path).await;
        assert_eq!(title(&page), expected, "title of {path}");
        assert!(
            page.contains(&format!(
                "<link rel=\"canonical\" href=\"{PUBLIC_URL}{path}\">"
            )),
            "canonical of {path}"
        );
        assert!(
            page.contains("<meta name=\"description\" content=\""),
            "description of {path}"
        );
        assert_eq!(occurrences(&page, "<h1"), 1, "one h1 on {path}");
        assert_eq!(
            occurrences(&page, "<script src=\"http"),
            0,
            "no third-party script on {path}"
        );
        assert!(
            page.contains("id=\"site-main\""),
            "{path} uses the public layout"
        );
    }
    site.stop().await;
}

#[tokio::test]
async fn pricing_shows_one_annual_plan() {
    let site = Site::start("site-pricing").await;
    let pricing = site.page("/pricing").await;
    for expected in [
        "$449",
        "per organization, billed annually",
        "14-day free trial",
        "100 GB",
        "1 million",
        "90 days",
        "Unlimited projects",
        "href=\"/docs/usage-and-retention\"",
        "<meta name=\"description\" content=\"One PostDeploy plan: $449 per year per organization, billed annually. 100 GB of logs and 1 million error events per month, 90-day retention, unlimited projects and members.\">",
    ] {
        assert!(pricing.contains(expected), "pricing contains {expected}");
    }
    for refused in [
        "$449/month",
        "$449 per month",
        "/mo",
        "monthly plan",
        "$29",
        "2,900",
    ] {
        assert!(
            !pricing.contains(refused),
            "pricing must not contain {refused}"
        );
    }
    site.stop().await;
}

/// Each paragraph of the usage page with the test that proves it.
const USAGE_CLAIMS: &[(&str, &str, &str)] = &[
    (
        "Each organization can store 1 million error events and 100 GB of logs per calendar month (UTC).",
        "tests/billing.rs",
        "monthly_error_allowance_spans_days_admits_exactly_the_remainder_and_survives_restart",
    ),
    (
        "Log usage counts the bytes of each accepted log entry once.",
        "tests/billing.rs",
        "monthly_log_bytes_count_raw_log_usage_once_and_refuse_the_overflowing_batch",
    ),
    (
        "Items that your filters or sampling refuse do not count toward usage.",
        "tests/privacy.rs",
        "filters_and_zero_or_full_sampling_refuse_items_without_billing_them",
    ),
    (
        "When an allowance is used up, ingestion answers <code>429</code> with <code>Retry-After</code> until the next month starts, and stores nothing from that request.",
        "tests/log_storage.rs",
        "quota_refusal_returns_429_and_changes_no_usage",
    ),
    (
        "Owners get an email when usage reaches 70%, 90% and 100% of an allowance.",
        "tests/billing.rs",
        "usage_alerts_email_each_owner_once_and_retry_after_mail_outages",
    ),
    (
        "Each organization also has a request rate limit. Over it, ingestion answers <code>429 rate_limited</code> with <code>Retry-After</code>.",
        "tests/privacy.rs",
        "the_organization_rate_gate_limits_isolates_bounds_and_recovers",
    ),
    (
        "When the trial ends without a subscription, ingestion answers <code>429 subscription_required</code>. Stored errors and logs stay readable until they expire.",
        "tests/billing.rs",
        "trial_ends_at_its_exact_second_and_expired_telemetry_adds_nothing_while_reads_remain",
    ),
    (
        "Errors are kept 90 days from the time PostDeploy receives them.",
        "tests/agent_hardening.rs",
        "expired_errors_are_hidden_before_the_retention_sweep",
    ),
    (
        "Logs are kept 90 days from the time PostDeploy receives them, even when the log entry carries an older timestamp.",
        "tests/diagnostics.rs",
        "ingested_logs_keep_old_event_times_within_receive_retention",
    ),
    (
        "A success response means the logs are committed to the server's SQLite database. They survive a server restart before they reach R2.",
        "tests/log_storage.rs",
        "acknowledged_logs_survive_kill_and_restart_without_r2",
    ),
    (
        "If R2 is unreachable, logs stay in SQLite and stay searchable. When an organization's unarchived logs reach the backlog limit, ingestion answers <code>503 log_backlog_full</code> until archiving catches up.",
        "tests/log_storage.rs",
        "organization_backlog_limit_refuses_with_503_and_unchanged_usage",
    ),
    (
        "Owners and admins set those filters on the <strong>Data controls</strong> settings page: extra sensitive field names, stored log levels, excluded exception types, and error and log sampling.",
        "tests/privacy.rs",
        "the_dashboard_shows_and_saves_the_ingestion_policy",
    ),
    (
        "The billing page and the <code>get_usage</code> MCP tool show this month's usage against each allowance.",
        "tests/web_billing.rs",
        "billing_page_shows_the_single_plan_usage_and_owner_only_actions",
    ),
    (
        "Subscribing from the billing page starts ingestion again for the same organization.",
        "tests/billing.rs",
        "only_owners_check_out_and_paid_time_comes_from_verified_paid_annual_invoices",
    ),
    (
        "Searches and agent tools do not return data past retention, even before the deletion job removes it.",
        "tests/agent_hardening.rs",
        "expired_errors_are_hidden_before_the_retention_sweep",
    ),
    (
        "Each organization has its own SQLite database on the server. Error payloads are stored in Cloudflare R2 before ingestion answers success.",
        "tests/flow.rs",
        "error_ingest_stores_payloads_in_r2_and_refuses_with_503_while_r2_is_unreachable",
    ),
    (
        "If R2 is unreachable, PostDeploy stores no error events and answers <code>503 ingest_unavailable</code>. Whether the event is sent again depends on the SDK.",
        "tests/flow.rs",
        "error_ingest_stores_payloads_in_r2_and_refuses_with_503_while_r2_is_unreachable",
    ),
    (
        "The server writes log batches to R2 within five minutes when R2 is reachable. Logs that are not yet in R2 are lost if the server's disk is lost.",
        "tests/site.rs",
        "production_refuses_log_archiving_slower_than_five_minutes",
    ),
    (
        "A log search reads a bounded part of the history per request. When the response sets <code>coverage.truncated_by</code>, pass <code>next</code> as <code>before</code> to continue further back.",
        "tests/log_review.rs",
        "an_empty_search_page_keeps_the_first_unscanned_object_on_timeout",
    ),
    (
        "The server writes encrypted backup sets of every organization database to R2.",
        "tests/backup_sets.rs",
        "an_online_set_restores_committed_wal_rows_exactly_while_ingestion_keeps_succeeding",
    ),
    (
        "A restore task rebuilds the databases from one backup set while the server is stopped.",
        "tests/backup_sets.rs",
        "the_offline_restore_task_writes_the_set_and_refuses_a_live_server",
    ),
    (
        BACKUP_RETENTION,
        "tests/backup_sets.rs",
        "retention_keeps_the_newest_valid_set_and_deletes_only_old_sets_under_backups_sets",
    ),
];

const BACKUP_RETENTION: &str = "Backup sets keep copies of deleted and expired data for 14 days. The first successful backup after that deletes them.";

/// The attribute lines directly above `fn {test}(` in `source`.
fn test_attributes<'a>(source: &'a str, test: &str) -> Option<Vec<&'a str>> {
    let (before, _) = source.split_once(&format!("fn {test}("))?;
    let (above, _) = before.rsplit_once('\n')?;
    Some(
        above
            .lines()
            .rev()
            .map(str::trim)
            .take_while(|line| line.starts_with("#[") || line.starts_with("///"))
            .filter(|line| line.starts_with("#["))
            .collect(),
    )
}

#[tokio::test]
async fn usage_page_matches_behavior() {
    let site = Site::start("site-usage").await;
    let usage = site.page("/docs/usage-and-retention").await;
    let body = between(&usage, "<article", "</article>");
    let paragraphs: std::collections::BTreeSet<&str> = body
        .split("<p>")
        .skip(1)
        .filter_map(|rest| rest.split_once("</p>").map(|(text, _)| text))
        .collect();
    let claimed: std::collections::BTreeSet<&str> = USAGE_CLAIMS
        .iter()
        .map(|(sentence, _, _)| *sentence)
        .collect();
    assert_eq!(paragraphs, claimed, "every usage paragraph has a proof");
    for (sentence, file, test) in USAGE_CLAIMS {
        let source = std::fs::read_to_string(file).expect("proof file");
        let attributes = test_attributes(&source, test)
            .unwrap_or_else(|| panic!("{file} has the proof {test} for: {sentence}"));
        assert!(
            attributes
                .iter()
                .any(|line| line.starts_with("#[tokio::test") || *line == "#[test]"),
            "{file}::{test} is a test: {attributes:?}"
        );
        assert!(
            !attributes.iter().any(|line| line.starts_with("#[ignore")),
            "{file}::{test} runs in the default suite"
        );
    }
    site.stop().await;
}

#[test]
fn proof_lookup_rejects_ignored_and_missing_tests() {
    let source = "#[tokio::test]\n#[ignore = \"needs R2\"]\nasync fn uses_r2() {}\n\n/// Docs.\n#[test]\nfn local() {}\n";
    assert_eq!(
        test_attributes(source, "uses_r2"),
        Some(vec!["#[ignore = \"needs R2\"]", "#[tokio::test]"])
    );
    assert_eq!(test_attributes(source, "local"), Some(vec!["#[test]"]));
    assert_eq!(test_attributes(source, "missing"), None);
}

#[tokio::test]
async fn privacy_and_terms_name_processors_storage_and_backup_retention() {
    let site = Site::start("site-privacy-terms").await;
    let privacy = site.page("/privacy").await;
    for expected in [
        "PostDeploy sends account email (address confirmation, password reset and invitations), usage alerts, and issue and report notifications through an email delivery provider. The provider receives each recipient address and the message content.",
        "Error payloads, archived log batches, uploaded source maps, the content of published reports and backup sets are stored in Cloudflare R2.",
        "<li>Notification settings: which members get email notifications, and the webhook URLs you add with their signing secrets. Full webhook URLs and secrets are stored encrypted. The host of each URL is stored in plain text to label it.</li>",
        "<li>Invitations: the invited email address and role.</li>",
        "<li>OAuth clients that agents register: the client name, its redirect URLs and the scopes it requests.</li>",
        "<li>Source maps that you upload and reports that you or your agents publish.</li>",
    ] {
        assert!(privacy.contains(expected), "privacy states: {expected}");
    }
    for path in ["/privacy", "/terms", "/docs/usage-and-retention"] {
        let page = site.page(path).await;
        assert_eq!(occurrences(&page, BACKUP_RETENTION), 1, "{path}");
    }
    site.stop().await;
}

#[tokio::test]
async fn production_refuses_log_archiving_slower_than_five_minutes() {
    use loco_rs::{boot::StartMode, environment::Environment};
    let env = TestEnv::new("site-archive-bound");
    let config = env
        .config("test/site-archive-bound/", |s| {
            s["logs"]["batch_max_age_ms"] = serde_json::json!(300_000);
            s["notifications"]["public_url"] = serde_json::json!("https://postdeploy.test");
        })
        .await;
    let error = TestApp::boot(StartMode::ServerOnly, &Environment::Production, config)
        .await
        .err()
        .expect("production boot must fail");
    assert!(
        error
            .to_string()
            .contains("production log archiving must fit five minutes"),
        "{error}"
    );
}

fn internal_links(html: &str) -> Vec<String> {
    html.split("href=\"/")
        .skip(1)
        .filter_map(|rest| rest.split('"').next())
        .map(|path| format!("/{}", path.split('#').next().unwrap_or_default()))
        .filter(|path| {
            !path.starts_with("/css/")
                && !path.starts_with("/favicon")
                && path != "/apple-touch-icon.png"
        })
        .collect()
}

#[tokio::test]
async fn internal_links_resolve() {
    let site = Site::start("site-links").await;
    let mut links = std::collections::BTreeSet::new();
    for (path, _) in PUBLIC_PAGES {
        links.extend(internal_links(&site.page(path).await));
    }
    assert!(links.contains("/docs/usage-and-retention"), "{links:?}");
    for link in &links {
        let response = site.fetch(link).await;
        assert_eq!(response.status, StatusCode::OK, "GET {link}");
    }
    site.stop().await;
}

#[tokio::test]
async fn sitemap_lists_exact_public_routes() {
    let site = Site::start("site-sitemap").await;
    let sitemap = site.fetch("/sitemap.xml").await;
    assert_eq!(sitemap.status, StatusCode::OK);
    assert_eq!(sitemap.headers[header::CONTENT_TYPE], "application/xml");
    assert!(sitemap
        .body
        .starts_with("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"));
    let listed: std::collections::BTreeSet<&str> = sitemap
        .body
        .split("<loc>")
        .skip(1)
        .filter_map(|rest| rest.split_once("</loc>").map(|(loc, _)| loc))
        .collect();
    let expected: std::collections::BTreeSet<&str> = [
        "http://127.0.0.1:5167/",
        "http://127.0.0.1:5167/pricing",
        "http://127.0.0.1:5167/docs",
        "http://127.0.0.1:5167/docs/quickstart",
        "http://127.0.0.1:5167/docs/agents",
        "http://127.0.0.1:5167/docs/api",
        "http://127.0.0.1:5167/docs/usage-and-retention",
        "http://127.0.0.1:5167/privacy",
        "http://127.0.0.1:5167/terms",
        "http://127.0.0.1:5167/about",
    ]
    .into();
    assert_eq!(listed, expected);
    assert_eq!(occurrences(&sitemap.body, "<url>"), 10);
    site.stop().await;
}

#[tokio::test]
async fn robots_and_llms_are_plain_text() {
    let site = Site::start("site-robots").await;
    let robots = site.fetch("/robots.txt").await;
    assert_eq!(robots.status, StatusCode::OK);
    assert_eq!(
        robots.headers[header::CONTENT_TYPE],
        "text/plain; charset=utf-8"
    );
    assert_eq!(
        robots.body,
        "User-agent: *\nDisallow: /dashboard\nDisallow: /oauth/\nDisallow: /api/\nDisallow: /sign-out\n\nSitemap: http://127.0.0.1:5167/sitemap.xml\n"
    );
    let llms = site.fetch("/llms.txt").await;
    assert_eq!(llms.status, StatusCode::OK);
    assert_eq!(
        llms.headers[header::CONTENT_TYPE],
        "text/plain; charset=utf-8"
    );
    for expected in [
        "# PostDeploy\n",
        "MCP server: http://127.0.0.1:5167/mcp",
        "http://127.0.0.1:5167/docs/quickstart",
        "http://127.0.0.1:5167/docs/agents",
        "http://127.0.0.1:5167/docs/api",
        "http://127.0.0.1:5167/docs/usage-and-retention",
    ] {
        assert!(llms.body.contains(expected), "llms.txt contains {expected}");
    }
    site.stop().await;
}

#[tokio::test]
async fn removed_surfaces_return_404() {
    let site = Site::start("site-removed").await;
    for path in [
        "/status/x",
        "/h/abc",
        "/m.js",
        "/monitoring",
        "/free-uptime-monitoring",
        "/analytics",
        "/blog",
        "/changelog",
        "/alternatives",
        "/product-facts.json",
    ] {
        assert_eq!(
            site.fetch(path).await.status,
            StatusCode::NOT_FOUND,
            "GET {path}"
        );
    }
    for (path, location) in [
        ("/docs/mcp", "/docs/agents"),
        ("/docs/get-started", "/docs/quickstart"),
        ("/docs/projects-and-keys", "/docs/quickstart"),
    ] {
        let moved = site.fetch(path).await;
        assert_eq!(moved.status, StatusCode::MOVED_PERMANENTLY, "GET {path}");
        assert_eq!(moved.headers[header::LOCATION], location, "GET {path}");
    }
    site.stop().await;
}

#[tokio::test]
async fn first_event_onboarding() {
    let site = Site::start("site-onboarding").await;
    let api = Api::signup(&site.base, "onboarding@example.invalid").await;
    let (status, org) = api.post("/api/orgs", json!({"name": "Onboarding"})).await;
    assert_eq!(status, StatusCode::CREATED);
    let org = org["id"].as_str().unwrap().to_owned();
    let (status, project) = api
        .post(&format!("/api/orgs/{org}/projects"), json!({"name": "web"}))
        .await;
    assert_eq!(status, StatusCode::CREATED);
    let project = project["id"].as_i64().unwrap();
    let sources = format!("/dashboard/orgs/{org}/projects/{project}/sources");

    let created = site
        .form_fields(
            &sources,
            &api,
            &[("name", "api"), ("environment", "production")],
            false,
        )
        .await;
    assert_eq!(created.status(), StatusCode::CREATED);
    let page = created.text().await.unwrap();
    let dsn = between(&page, "id=\"source-dsn-value\"", "</p>")
        .rsplit_once('>')
        .unwrap()
        .1
        .trim()
        .to_owned();
    assert!(
        dsn.starts_with("http://") && dsn.ends_with(&format!("@127.0.0.1:5167/{project}")),
        "{dsn}"
    );
    for expected in [
        "No event received yet",
        "No error received yet",
        "No log received yet",
        "Send test event",
        "enableLogs: true",
        &format!("dsn: \"{dsn}\","),
        &format!("sentry_sdk.init(dsn=\"{dsn}\")"),
        &format!("config.dsn = \"{dsn}\""),
        &format!("config :sentry, dsn: \"{dsn}\""),
        "href=\"/docs/quickstart\"",
        "href=\"/docs/agents\"",
    ] {
        assert!(page.contains(expected), "DSN page contains {expected}");
    }
    assert!(
        !page.contains("Accepting events"),
        "no arrival claim before an event"
    );
    assert!(
        page.contains("<section id=\"source-agent\" hidden"),
        "agent step waits for the first event"
    );
    let status_url = between(&page, "data-status-url=\"", "\"").to_owned();
    let source_path = status_url.strip_suffix("/status").unwrap().to_owned();
    assert!(
        source_path.starts_with(&format!("{sources}/")),
        "{source_path}"
    );
    assert_eq!(
        site.json(&status_url, &api).await,
        json!({"errors_received": false, "logs_received": false})
    );
    for expected in [
        "<p id=\"source-answer\" data-arrival-answer ",
        "This page checks every 3 seconds for 10 minutes until the first error arrives.",
        &format!("<p data-arrival-stopped=\"timeout\" hidden class=\"mt-1 text-body text-text-secondary\">This page stopped checking after 10 minutes. <a href=\"{source_path}\""),
        &format!("<p data-arrival-stopped=\"error\" hidden class=\"mt-1 text-body text-text-secondary\">This page stopped checking because a status check failed. <a href=\"{source_path}\""),
        "Copy the DSN first. It is not shown again.",
    ] {
        assert!(page.contains(expected), "DSN page contains {expected}");
    }
    let script = site.fetch("/js/console.js").await;
    assert_eq!(script.status, StatusCode::OK);
    for expected in [
        "document.querySelector(\"[data-arrival-answer]\")",
        "answer.textContent = \"Events received\"",
        "stop(\"error\")",
        "stop(\"timeout\")",
        "[data-arrival-stopped=\"${reason}\"]",
    ] {
        assert!(
            script.body.contains(expected),
            "console.js contains {expected}"
        );
    }

    let sent = site
        .form(&format!("{source_path}/test-event"), &api, false)
        .await;
    assert_eq!(sent.status(), StatusCode::SEE_OTHER);
    assert_eq!(sent.headers()[header::LOCATION], source_path.as_str());
    assert_eq!(
        site.json(&status_url, &api).await,
        json!({"errors_received": true, "logs_received": false})
    );
    let (status, issues) = api.get(&format!("/api/orgs/{org}/issues")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(issues["issues"].as_array().unwrap().len(), 1, "{issues}");
    assert_eq!(
        issues["issues"][0]["title"],
        json!("PostDeploy test event"),
        "{issues}"
    );
    assert_eq!(
        issues["issues"][0]["environment"],
        json!("production"),
        "{issues}"
    );

    let fetched = site
        .form(&format!("{source_path}/test-event"), &api, true)
        .await;
    assert_eq!(fetched.status(), StatusCode::OK);
    assert_eq!(
        fetched.json::<Value>().await.unwrap(),
        json!({"stored": true, "message": "Test event stored. It is in Issues as \"PostDeploy test event\"."})
    );

    let (status, _) = support::post_envelope(
        &site.base,
        project,
        &support::dsn_key(&dsn),
        support::envelope(None, &["first onboarding log"]),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        site.json(&status_url, &api).await,
        json!({"errors_received": true, "logs_received": true})
    );

    let shown = site.fetch_with(&source_path, api.cookie.as_deref()).await;
    assert_eq!(shown.status, StatusCode::OK);
    for expected in [
        "Events received",
        "Connect your agent",
        "href=\"/docs/agents\"",
        &format!("href=\"/dashboard/orgs/{org}/settings\""),
        &format!("href=\"/dashboard/orgs/{org}/projects/{project}/observe\""),
    ] {
        assert!(
            shown.body.contains(expected),
            "source page contains {expected}"
        );
    }
    for refused in [
        "No event received yet",
        "No error received yet",
        "No log received yet",
        "Accepting events",
        "<section id=\"source-agent\" hidden",
        "data-arrival-stopped",
        "Copy the DSN first.",
    ] {
        assert!(
            !shown.body.contains(refused),
            "source page must not contain {refused}"
        );
    }
    let listed = site.fetch_with(&sources, api.cookie.as_deref()).await;
    assert!(
        listed.body.contains(">Active<"),
        "sources list shows the key state"
    );
    assert!(!listed.body.contains("Accepting events"));
    site.stop().await;
}

#[tokio::test]
async fn expired_trial_refuses_the_test_event() {
    use postdeploy::runtime::Runtime;
    use sea_orm::ConnectionTrait;
    let site = Site::start("site-onboarding-expired").await;
    let api = Api::signup(&site.base, "expired-onboarding@example.invalid").await;
    let (org, project, _) = api.setup_source("Expired").await;
    let rt = Runtime::get(&site.boot.app_context);
    rt.control
        .execute_raw(postdeploy::runtime::sql(
            "UPDATE organizations SET created_at = created_at - 1209600 WHERE id = ?",
            vec![org.clone().into()],
        ))
        .await
        .unwrap();
    let sources = format!("/dashboard/orgs/{org}/projects/{project}/sources");
    let listed = site.fetch_with(&sources, api.cookie.as_deref()).await;
    let source_path = between(&listed.body, &format!("href=\"{sources}/"), "\"");
    let source_path = format!("{sources}/{source_path}");
    let refused = site
        .form(&format!("{source_path}/test-event"), &api, true)
        .await;
    assert_eq!(refused.status(), StatusCode::OK);
    assert_eq!(
        refused.json::<Value>().await.unwrap(),
        json!({"stored": false, "message": "The trial has ended. Subscribe on the billing page to accept events again."})
    );
    let (_, issues) = api.get(&format!("/api/orgs/{org}/issues")).await;
    assert_eq!(issues["issues"], json!([]));
    site.stop().await;
}

const ALL_SCOPES: [&str; 7] = [
    "issues:read",
    "issues:triage",
    "logs:read",
    "projects:read",
    "projects:write",
    "reports:write",
    "deployments:write",
];

async fn full_scope_key(api: &Api, org: &str) -> String {
    let (status, created) = api
        .post(
            &format!("/api/orgs/{org}/api-keys"),
            json!({"name": "all scopes", "scopes": ALL_SCOPES}),
        )
        .await;
    assert_eq!(status, StatusCode::CREATED, "{created}");
    created["secret"].as_str().unwrap().to_owned()
}

async fn issue_count(api: &Api, org: &str) -> usize {
    let (status, issues) = api.get(&format!("/api/orgs/{org}/issues")).await;
    assert_eq!(status, StatusCode::OK);
    issues["issues"].as_array().unwrap().len()
}

#[tokio::test]
async fn only_managers_send_test_events() {
    let site = Site::start("site-test-event-access").await;
    let owner = Api::signup(&site.base, "test-event-owner@example.invalid").await;
    let mut member = Api::signup(&site.base, "test-event-member@example.invalid").await;
    let (org, project, _) = owner.setup_source("Access").await;
    let (status, _) = owner
        .post(
            &format!("/api/orgs/{org}/members"),
            json!({"email": "test-event-member@example.invalid", "role": "member"}),
        )
        .await;
    assert_eq!(status, StatusCode::CREATED);
    let (status, _) = member
        .auth(
            "login",
            "test-event-member@example.invalid",
            support::PASSWORD,
        )
        .await;
    assert_eq!(status, StatusCode::OK);
    let (_, sources) = owner
        .get(&format!("/api/orgs/{org}/projects/{project}/sources"))
        .await;
    let source = sources["sources"][0]["id"].as_i64().unwrap();
    let source_path = format!("/dashboard/orgs/{org}/projects/{project}/sources/{source}");
    let action = format!("{source_path}/test-event");

    let member_page = site
        .fetch_with(&source_path, member.cookie.as_deref())
        .await;
    assert_eq!(member_page.status, StatusCode::OK);
    assert!(!member_page.body.contains("Send test event"));
    assert!(!member_page.body.contains(&action));
    let owner_page = site.fetch_with(&source_path, owner.cookie.as_deref()).await;
    assert!(owner_page.body.contains("Send test event"));
    assert!(owner_page
        .body
        .contains(&format!("action=\"{action}\" data-test-event")));

    let refused = site.form(&action, &member, true).await;
    assert_eq!(refused.status(), StatusCode::FORBIDDEN, "member");
    assert_eq!(issue_count(&owner, &org).await, 0);

    let post =
        |cookie: Option<&str>, csrf: Option<&str>, origin: Option<&str>, bearer: Option<&str>| {
            let mut fields = Vec::new();
            if let Some(csrf) = csrf {
                fields.push(("_csrf_token", csrf.to_owned()));
            }
            let mut request = site
                .http
                .post(format!("{}{action}", site.base))
                .header(header::ACCEPT, "application/json")
                .form(&fields);
            if let Some(cookie) = cookie {
                request = request.header(header::COOKIE, cookie);
            }
            if let Some(origin) = origin {
                request = request.header(header::ORIGIN, origin);
            }
            if let Some(bearer) = bearer {
                request = request.header(header::AUTHORIZATION, format!("Bearer {bearer}"));
            }
            request.send()
        };
    let cookie = owner.cookie.as_deref();
    let csrf = owner.csrf.as_deref();
    let missing_csrf = post(cookie, None, Some(PUBLIC_URL), None).await.unwrap();
    assert_eq!(
        missing_csrf.status(),
        StatusCode::FORBIDDEN,
        "no CSRF token"
    );
    let cross_origin = post(cookie, csrf, Some("https://evil.example"), None)
        .await
        .unwrap();
    assert_eq!(
        cross_origin.status(),
        StatusCode::FORBIDDEN,
        "foreign origin"
    );
    let key = full_scope_key(&owner, &org).await;
    let bearer = post(None, None, Some(PUBLIC_URL), Some(&key))
        .await
        .unwrap();
    assert_eq!(bearer.status(), StatusCode::SEE_OTHER, "bearer key");
    assert_eq!(bearer.headers()[header::LOCATION], "/sign-in");
    assert_eq!(issue_count(&owner, &org).await, 0);

    let stored = site.form(&action, &owner, true).await;
    assert_eq!(stored.status(), StatusCode::OK, "owner");
    assert_eq!(stored.json::<Value>().await.unwrap()["stored"], json!(true));
    assert_eq!(issue_count(&owner, &org).await, 1);
    site.stop().await;
}

/// `(method, path, scopes markup)` rows of the docs table with `id`.
fn endpoint_rows(page: &str, id: &str) -> Vec<(String, String, String)> {
    between(page, &format!("<table id=\"{id}\">"), "</table>")
        .split("<tr><td>")
        .skip(1)
        .map(|row| {
            let cells: Vec<&str> = row
                .split("</td>")
                .map(|cell| cell.trim_start_matches("<td>"))
                .collect();
            let path = cells[1]
                .strip_prefix("<code>")
                .and_then(|path| path.strip_suffix("</code>"))
                .expect("path cell is code");
            (
                cells[0].to_owned(),
                path.to_owned(),
                cells
                    .get(2)
                    .filter(|cell| !cell.starts_with("</tr>"))
                    .copied()
                    .unwrap_or_default()
                    .to_owned(),
            )
        })
        .collect()
}

#[tokio::test]
async fn api_docs_split_endpoints_by_what_a_full_scope_key_can_call() {
    let site = Site::start("site-api-endpoints").await;
    let owner = Api::signup(&site.base, "api-docs@example.invalid").await;
    let (org, project, _) = owner.setup_source("Docs").await;
    let (_, sources) = owner
        .get(&format!("/api/orgs/{org}/projects/{project}/sources"))
        .await;
    let source = sources["sources"][0]["id"].as_i64().unwrap();
    let key = full_scope_key(&owner, &org).await;
    let page = site.page("/docs/api").await;
    let bearer = endpoint_rows(&page, "bearer-endpoints");
    let session = endpoint_rows(&page, "session-endpoints");
    assert!(
        bearer.contains(&(
            "GET".into(),
            "/api/orgs/{org}/issues/{issue}/context".into(),
            "<code>issues:read</code>, <code>logs:read</code>".into()
        )),
        "{bearer:?}"
    );
    for row in [
        ("GET", "/api/orgs"),
        ("GET", "/api/orgs/{org}"),
        ("GET", "/api/orgs/{org}/members"),
        ("POST", "/api/orgs/{org}/api-keys"),
        ("GET", "/api/orgs/{org}/billing"),
        ("PUT", "/api/orgs/{org}/ingestion-policy"),
    ] {
        assert!(
            session
                .iter()
                .any(|(method, path, _)| (method.as_str(), path.as_str()) == row),
            "{row:?} is session-only: {session:?}"
        );
    }
    assert_eq!(bearer.len() + session.len(), 41, "every /api/orgs route");
    let call = |method: &str, path: &str| {
        let url = format!(
            "{}{}",
            site.base,
            path.replace("{org}", &org)
                .replace("{project}", &project.to_string())
                .replace("{source}", &source.to_string())
                .replace(['{', '}'], "")
        );
        let request = site
            .http
            .request(method.parse().unwrap(), url)
            .header(header::AUTHORIZATION, format!("Bearer {key}"));
        let request = if method == "GET" || method == "DELETE" {
            request
        } else {
            request.json(&json!({}))
        };
        request.send()
    };
    for (method, path, _) in &bearer {
        let status = call(method, path).await.unwrap().status();
        assert!(
            status != StatusCode::UNAUTHORIZED && status != StatusCode::FORBIDDEN,
            "{method} {path} accepts the key, got {status}"
        );
    }
    for (method, path, _) in &session {
        let status = call(method, path).await.unwrap().status();
        assert!(
            status == StatusCode::UNAUTHORIZED || status == StatusCode::FORBIDDEN,
            "{method} {path} refuses the key, got {status}"
        );
    }
    site.stop().await;
}

fn shipped_text_files(dir: &std::path::Path, out: &mut Vec<std::path::PathBuf>) {
    for entry in std::fs::read_dir(dir).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            shipped_text_files(&path, out);
        } else if path
            .extension()
            .is_some_and(|ext| ext == "html" || ext == "js" || ext == "md")
        {
            out.push(path);
        }
    }
}

/// Hosts of `<script src>` URLs that leave the site, in any quoting.
fn third_party_scripts(html: &str) -> Vec<String> {
    let script =
        regex::Regex::new(r#"(?i)<script[^>]*\ssrc\s*=\s*["']?(https?:)?//([^/"'\s>]+)"#).unwrap();
    script
        .captures_iter(html)
        .map(|hit| hit[2].to_lowercase())
        .collect()
}

#[test]
fn script_scan_finds_every_quoting_style() {
    assert_eq!(
        third_party_scripts(
            "<script src=\"https://a.example/x.js\"></script><SCRIPT defer src='//b.example/y.js'></SCRIPT><script src=https://c.example/z.js></script><script src=\"/js/console.js\"></script>"
        ),
        ["a.example", "b.example", "c.example"]
    );
}

#[test]
fn shipped_assets_have_no_obsolete_claims() {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let mut files = Vec::new();
    shipped_text_files(&root.join("assets/views"), &mut files);
    shipped_text_files(&root.join("assets/static/js"), &mut files);
    assert!(files.len() > 40, "{} files", files.len());
    let obsolete = regex::RegexBuilder::new(
        include_str!("../scripts/verification/obsolete-claims.pattern").trim(),
    )
    .case_insensitive(true)
    .build()
    .unwrap();
    let turnstile_pages = ["register.html", "reset.html", "sign_in.html"]
        .map(|name| root.join("assets/views/auth").join(name));
    let mut found = Vec::new();
    for file in &files {
        let text = std::fs::read_to_string(file).unwrap();
        for hit in obsolete.find_iter(&text) {
            found.push(format!("{}: {}", file.display(), hit.as_str()));
        }
        for host in third_party_scripts(&text) {
            if host != "challenges.cloudflare.com" || !turnstile_pages.contains(file) {
                found.push(format!("{}: third-party script {host}", file.display()));
            }
        }
    }
    assert_eq!(found, Vec::<String>::new());
}
