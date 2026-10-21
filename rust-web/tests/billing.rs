mod support;

use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::Duration,
};

use axum::{
    extract::{Path, Query, State},
    http::{HeaderMap, StatusCode as AxumStatus},
    response::{IntoResponse, Response},
    routing::{get, post},
    Form, Json, Router,
};
use hmac::{Hmac, Mac};
use loco_rs::{
    app::Hooks,
    boot::{BootResult, StartMode},
    environment::Environment,
};
use postdeploy::{
    account_settings::{AccountMail, AccountMessage, MailFailure},
    billing::{self, alerts, notices},
    domain::{now_secs, utc_day, OrgId},
    runtime::{sql, Runtime},
    testing::{serve, TestApp, TestEnv},
};
use reqwest::StatusCode;
use sea_orm::ConnectionTrait;
use serde_json::{json, Value};
use sha2::Sha256;
use support::*;

const SECRET_KEY: &str = "sk_test_isolatedfixture";
const WEBHOOK_SECRET: &str = "whsec_isolatedfixture";
const PRICE: &str = "price_annualfixture";
const YEAR: i64 = 365 * 86_400;

#[derive(Default)]
struct FakeState {
    prices: HashMap<String, Value>,
    sessions: HashMap<String, Value>,
    subscriptions: HashMap<String, Value>,
    invoices: Vec<Value>,
    idempotent: HashMap<String, Value>,
    created_sessions: Vec<HashMap<String, String>>,
    idempotency_keys: Vec<String>,
    portal_customers: Vec<String>,
    unauthenticated: usize,
    wrong_version: usize,
    slow_creates: usize,
    truncated_invoices: bool,
    invoice_cursors: Vec<Option<String>>,
}

#[derive(Clone)]
struct Fake(Arc<Mutex<FakeState>>);

fn checked(state: &mut FakeState, headers: &HeaderMap) -> bool {
    if headers.get("authorization").and_then(|v| v.to_str().ok())
        != Some(&format!("Bearer {SECRET_KEY}"))
    {
        state.unauthenticated += 1;
        return false;
    }
    if headers.get("stripe-version").and_then(|v| v.to_str().ok()) != Some("2026-09-30.endive") {
        state.wrong_version += 1;
        return false;
    }
    true
}

fn found(value: Option<Value>) -> Response {
    match value {
        Some(value) => Json(value).into_response(),
        None => (
            AxumStatus::NOT_FOUND,
            Json(json!({"error": {"type": "invalid_request_error"}})),
        )
            .into_response(),
    }
}

async fn get_price(
    State(fake): State<Fake>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Response {
    let mut state = fake.0.lock().unwrap();
    if !checked(&mut state, &headers) {
        return AxumStatus::UNAUTHORIZED.into_response();
    }
    found(state.prices.get(&id).cloned())
}

async fn create_session(
    State(fake): State<Fake>,
    headers: HeaderMap,
    Form(form): Form<HashMap<String, String>>,
) -> Response {
    let (session, slow) = {
        let mut state = fake.0.lock().unwrap();
        if !checked(&mut state, &headers) {
            return AxumStatus::UNAUTHORIZED.into_response();
        }
        let key = headers
            .get("idempotency-key")
            .and_then(|v| v.to_str().ok())
            .unwrap_or_default()
            .to_owned();
        state.idempotency_keys.push(key.clone());
        if let Some(previous) = state.idempotent.get(&key) {
            return Json(previous.clone()).into_response();
        }
        let id = format!("cs_test_{}", state.created_sessions.len() + 1);
        let session = json!({
            "id": id, "object": "checkout.session", "mode": form["mode"],
            "status": "open", "url": format!("https://checkout.stripe.test/{id}"),
            "client_reference_id": form.get("client_reference_id"),
            "customer": form.get("customer"), "subscription": null,
            "expires_at": now_secs() + 86_400,
        });
        state.created_sessions.push(form);
        state.sessions.insert(id, session.clone());
        state.idempotent.insert(key, session.clone());
        let slow = state.slow_creates > 0;
        state.slow_creates = state.slow_creates.saturating_sub(1);
        (session, slow)
    };
    if slow {
        tokio::time::sleep(Duration::from_millis(1_500)).await;
    }
    Json(session).into_response()
}

async fn get_session(
    State(fake): State<Fake>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Response {
    let mut state = fake.0.lock().unwrap();
    if !checked(&mut state, &headers) {
        return AxumStatus::UNAUTHORIZED.into_response();
    }
    found(state.sessions.get(&id).cloned())
}

async fn create_portal(
    State(fake): State<Fake>,
    headers: HeaderMap,
    Form(form): Form<HashMap<String, String>>,
) -> Response {
    let mut state = fake.0.lock().unwrap();
    if !checked(&mut state, &headers) {
        return AxumStatus::UNAUTHORIZED.into_response();
    }
    state.portal_customers.push(form["customer"].clone());
    Json(json!({"url": format!("https://billing.stripe.test/{}", form["customer"])}))
        .into_response()
}

async fn get_subscription(
    State(fake): State<Fake>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Response {
    let mut state = fake.0.lock().unwrap();
    if !checked(&mut state, &headers) {
        return AxumStatus::UNAUTHORIZED.into_response();
    }
    found(state.subscriptions.get(&id).cloned())
}

async fn get_invoice(
    State(fake): State<Fake>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Response {
    let mut state = fake.0.lock().unwrap();
    if !checked(&mut state, &headers) {
        return AxumStatus::UNAUTHORIZED.into_response();
    }
    found(
        state
            .invoices
            .iter()
            .find(|invoice| invoice["id"] == id)
            .cloned(),
    )
}

async fn list_invoices(
    State(fake): State<Fake>,
    headers: HeaderMap,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    let mut state = fake.0.lock().unwrap();
    if !checked(&mut state, &headers) {
        return AxumStatus::UNAUTHORIZED.into_response();
    }
    state
        .invoice_cursors
        .push(query.get("starting_after").cloned());
    let data: Vec<Value> = state
        .invoices
        .iter()
        .filter(|invoice| {
            invoice["parent"]["subscription_details"]["subscription"] == query["subscription"]
                && query
                    .get("status")
                    .is_none_or(|status| invoice["status"] == *status)
        })
        .cloned()
        .collect();
    Json(json!({"object": "list", "data": data, "has_more": state.truncated_invoices}))
        .into_response()
}

impl Fake {
    async fn start() -> (Self, String) {
        let fake = Self(Arc::default());
        fake.price(PRICE, 44_900, "usd", "year", 1);
        let router = Router::new()
            .route("/v1/prices/{id}", get(get_price))
            .route("/v1/checkout/sessions", post(create_session))
            .route("/v1/checkout/sessions/{id}", get(get_session))
            .route("/v1/billing_portal/sessions", post(create_portal))
            .route("/v1/subscriptions/{id}", get(get_subscription))
            .route("/v1/invoices", get(list_invoices))
            .route("/v1/invoices/{id}", get(get_invoice))
            .with_state(fake.clone());
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        tokio::spawn(async move {
            let _ = axum::serve(listener, router).await;
        });
        (fake, base)
    }

    fn price(&self, id: &str, amount: i64, currency: &str, interval: &str, count: u32) {
        self.0.lock().unwrap().prices.insert(
            id.to_owned(),
            json!({"id": id, "object": "price", "active": true, "currency": currency,
                "unit_amount": amount, "type": "recurring",
                "recurring": {"interval": interval, "interval_count": count}}),
        );
    }

    fn complete(&self, session: &str, customer: &str, subscription: &str) {
        let mut state = self.0.lock().unwrap();
        let entry = state.sessions.get_mut(session).unwrap();
        entry["status"] = json!("complete");
        entry["customer"] = json!(customer);
        entry["subscription"] = json!(subscription);
        state.subscriptions.insert(
            subscription.to_owned(),
            json!({"id": subscription, "object": "subscription", "customer": customer,
                "status": "active", "cancel_at_period_end": false}),
        );
    }

    fn session(&self, id: &str, value: Value) {
        self.0.lock().unwrap().sessions.insert(id.to_owned(), value);
    }

    fn subscription(&self, id: &str, customer: &str, status: &str, cancel_at_period_end: bool) {
        self.0.lock().unwrap().subscriptions.insert(
            id.to_owned(),
            json!({"id": id, "object": "subscription", "customer": customer,
                "status": status, "cancel_at_period_end": cancel_at_period_end}),
        );
    }

    #[allow(clippy::too_many_arguments)]
    fn invoice(
        &self,
        id: &str,
        customer: &str,
        subscription: &str,
        status: &str,
        price: &str,
        quantity: u64,
        currency: &str,
        start: i64,
        end: i64,
    ) {
        let total = 44_900 * quantity as i64;
        let (paid, remaining) = if status == "paid" {
            (total, 0)
        } else {
            (0, total)
        };
        self.0.lock().unwrap().invoices.push(json!({
            "id": id, "object": "invoice", "customer": customer, "status": status,
            "currency": currency, "total": total, "amount_due": total,
            "amount_paid": paid, "amount_remaining": remaining,
            "post_payment_credit_notes_amount": 0,
            "parent": {"type": "subscription_details", "subscription_details": {"subscription": subscription}},
            "lines": {"object": "list", "has_more": false, "data": [{
                "amount": 44_900 * quantity as i64, "currency": currency, "quantity": quantity,
                "period": {"start": start, "end": end},
                "pricing": {"type": "price_details", "price_details": {"price": price}},
            }]},
        }));
    }

    fn patch_invoice(&self, id: &str, patch: impl FnOnce(&mut Value)) {
        let mut state = self.0.lock().unwrap();
        patch(
            state
                .invoices
                .iter_mut()
                .find(|invoice| invoice["id"] == id)
                .unwrap(),
        );
    }

    fn state<T>(&self, read: impl FnOnce(&FakeState) -> T) -> T {
        read(&self.0.lock().unwrap())
    }
}

fn sign(body: &str, at: i64) -> String {
    let mut mac = Hmac::<Sha256>::new_from_slice(WEBHOOK_SECRET.as_bytes()).unwrap();
    mac.update(format!("{at}.{body}").as_bytes());
    format!("t={at},v1={}", hex::encode(mac.finalize().into_bytes()))
}

fn event(id: &str, kind: &str, object: &str, object_id: &str) -> String {
    json!({"id": id, "object": "event", "type": kind, "livemode": false,
        "data": {"object": {"id": object_id, "object": object}}})
    .to_string()
}

async fn deliver(base: &str, body: &str, signature: &str) -> (StatusCode, Value) {
    let response = reqwest::Client::new()
        .post(format!("{base}/webhooks/stripe"))
        .header("stripe-signature", signature)
        .header("content-type", "application/json")
        .body(body.to_owned())
        .send()
        .await
        .unwrap();
    let status = response.status();
    (status, response.json().await.unwrap_or(Value::Null))
}

async fn webhook(base: &str, body: &str) -> (StatusCode, Value) {
    deliver(base, body, &sign(body, now_secs())).await
}

struct Ingested {
    status: StatusCode,
    retry_after: Option<String>,
    rate_limits: Option<String>,
    body: Value,
}

async fn ingest(base: &str, project: i64, key: &str, body: Vec<u8>) -> Ingested {
    let response = reqwest::Client::new()
        .post(format!("{base}/api/{project}/envelope/"))
        .header(
            "x-sentry-auth",
            format!("Sentry sentry_version=7, sentry_key={key}, sentry_client=test/1"),
        )
        .body(body)
        .send()
        .await
        .unwrap();
    let header = |name: &str| {
        response
            .headers()
            .get(name)
            .map(|v| v.to_str().unwrap().to_owned())
    };
    let (retry_after, rate_limits) = (header("retry-after"), header("x-sentry-rate-limits"));
    let status = response.status();
    Ingested {
        status,
        retry_after,
        rate_limits,
        body: response.json().await.unwrap_or(Value::Null),
    }
}

fn event_id(n: u32) -> String {
    format!("{n:032x}")
}

async fn set_created(rt: &Runtime, org: &str, created_at: i64) {
    rt.control
        .execute_raw(sql(
            "UPDATE organizations SET created_at = ? WHERE id = ?",
            vec![created_at.into(), org.into()],
        ))
        .await
        .unwrap();
}

async fn tenant_scalar(rt: &Runtime, org: &str, query: &str) -> i64 {
    let tenant = rt.tenant(&org.parse::<OrgId>().unwrap()).await.unwrap();
    tenant
        .query_one_raw(sql(query, vec![]))
        .await
        .unwrap()
        .unwrap()
        .try_get_by_index::<i64>(0)
        .unwrap()
}

async fn alerts(rt: &Runtime, org: &str) -> Vec<(String, i64, String)> {
    let tenant = rt.tenant(&org.parse::<OrgId>().unwrap()).await.unwrap();
    let month = &utc_day(chrono::Utc::now().timestamp_micros())[..6];
    tenant
        .query_all_raw(sql(
            "SELECT metric, percent, state FROM usage_alerts WHERE month = ? ORDER BY metric, percent",
            vec![month.into()],
        ))
        .await
        .unwrap()
        .iter()
        .map(|row| {
            (
                row.try_get("", "metric").unwrap(),
                row.try_get("", "percent").unwrap(),
                row.try_get("", "state").unwrap(),
            )
        })
        .collect()
}

async fn seed_usage(rt: &Runtime, org: &str, day: &str, category: &str, accepted: i64, bytes: i64) {
    let tenant = rt.tenant(&org.parse::<OrgId>().unwrap()).await.unwrap();
    tenant
        .execute_raw(sql(
            "INSERT INTO usage_daily (day, category, accepted, bytes) VALUES (?, ?, ?, ?)",
            vec![day.into(), category.into(), accepted.into(), bytes.into()],
        ))
        .await
        .unwrap();
}

fn other_days() -> (String, String) {
    let today = utc_day(chrono::Utc::now().timestamp_micros());
    let same_month = if &today[6..] == "01" {
        format!("{}02", &today[..6])
    } else {
        format!("{}01", &today[..6])
    };
    let first = chrono::NaiveDate::parse_from_str(&format!("{}01", &today[..6]), "%Y%m%d").unwrap();
    let previous = (first - chrono::Duration::days(1))
        .format("%Y%m%d")
        .to_string();
    (same_month, previous)
}

fn seconds_to_next_month() -> i64 {
    use chrono::Datelike;
    let now = chrono::Utc::now();
    let (year, month) = if now.month() == 12 {
        (now.year() + 1, 1)
    } else {
        (now.year(), now.month() + 1)
    };
    chrono::NaiveDate::from_ymd_opt(year, month, 1)
        .unwrap()
        .and_hms_opt(0, 0, 0)
        .unwrap()
        .and_utc()
        .timestamp()
        - now.timestamp()
}

async fn stop(boot: BootResult, server: tokio::task::JoinHandle<()>) {
    server.abort();
    TestApp::on_shutdown(&boot.app_context).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn trial_ends_at_its_exact_second_and_expired_telemetry_adds_nothing_while_reads_remain() {
    let env = TestEnv::new("billing-trial-boundary");
    let boot = env.boot_memory(|_| {}).await.unwrap();
    let (base, server) = serve(&boot).await;
    let rt = Runtime::get(&boot.app_context);
    let api = Api::signup(&base, "trial-owner@example.test").await;
    let (org, project, dsn) = api.setup_source("Trial").await;
    let key = dsn_key(&dsn);

    let (status, shown) = api.get(&format!("/api/orgs/{org}")).await;
    assert_eq!(status, StatusCode::OK);
    let created = shown["created_at"].as_i64().unwrap();
    let (status, billing) = api.get(&format!("/api/orgs/{org}/billing")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        billing["entitlement"],
        json!({"state": "trial", "ends_at": created + 1_209_600})
    );
    assert_eq!(billing["trial_ends_at"], json!(created + 1_209_600));
    assert_eq!(billing["blocker"], json!("billing_unconfigured"));
    assert_eq!(billing["plan"]["price_cents"], json!(44_900));
    assert_eq!(billing["plan"]["interval"], json!("year"));
    let (status, body) = api
        .post(&format!("/api/orgs/{org}/billing/checkout"), json!({}))
        .await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body["error"], json!("billing_unconfigured"));

    let accepted = ingest(
        &base,
        project,
        &key,
        envelope(Some(&event_id(1)), &["first log"]),
    )
    .await;
    assert_eq!(accepted.status, StatusCode::OK, "{}", accepted.body);

    set_created(&rt, &org, now_secs() - 1_209_600 + 120).await;
    let last_trial_minutes = ingest(&base, project, &key, envelope(Some(&event_id(2)), &[])).await;
    assert_eq!(last_trial_minutes.status, StatusCode::OK);

    set_created(&rt, &org, now_secs() - 1_209_600).await;
    let puts = rt
        .store
        .counters()
        .puts
        .load(std::sync::atomic::Ordering::Relaxed);
    let refused = ingest(
        &base,
        project,
        &key,
        envelope(Some(&event_id(3)), &["late log"]),
    )
    .await;
    assert_eq!(refused.status, StatusCode::TOO_MANY_REQUESTS);
    assert_eq!(refused.body, json!({"error": "subscription_required"}));
    assert_eq!(refused.retry_after.as_deref(), Some("600"));
    assert_eq!(
        refused.rate_limits.as_deref(),
        Some("600::organization:subscription_required")
    );
    assert_eq!(
        rt.store
            .counters()
            .puts
            .load(std::sync::atomic::Ordering::Relaxed),
        puts
    );
    assert_eq!(
        tenant_scalar(&rt, &org, "SELECT COUNT(*) FROM events").await,
        2
    );
    assert_eq!(
        tenant_scalar(&rt, &org, "SELECT COUNT(*) FROM log_objects").await,
        1
    );
    assert_eq!(
        tenant_scalar(
            &rt,
            &org,
            "SELECT COALESCE(SUM(accepted), 0) FROM usage_daily WHERE category = 'error'"
        )
        .await,
        2
    );

    let (status, issues) = api.get(&format!("/api/orgs/{org}/issues")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(issues["issues"].as_array().unwrap().len(), 1, "{issues}");
    let (status, logs) = api.get(&format!("/api/orgs/{org}/logs?q=first")).await;
    assert_eq!(status, StatusCode::OK, "{logs}");
    assert!(logs.to_string().contains("first log"), "{logs}");
    let (status, usage) = api.get(&format!("/api/orgs/{org}/usage")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        usage["entitlement"]["state"],
        json!("subscription_required")
    );
    assert_eq!(usage["errors"]["used"], json!(2));
    assert_eq!(usage["errors"]["limit"], json!(1_000_000));
    assert_eq!(usage["log_bytes"]["limit"], json!(100_000_000_000u64));
    stop(boot, server).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn monthly_error_allowance_spans_days_admits_exactly_the_remainder_and_survives_restart() {
    let env = TestEnv::new("billing-monthly-errors");
    let lanes = |s: &mut Value| s["ingest"]["error_lane"] = json!(32);
    let boot = env.boot_memory(lanes).await.unwrap();
    let (base, server) = serve(&boot).await;
    let rt = Runtime::get(&boot.app_context);
    let api = Api::signup(&base, "monthly-owner@example.test").await;
    let (org, project, dsn) = api.setup_source("Monthly").await;
    let key = dsn_key(&dsn);
    let (same_month, previous_month) = other_days();
    seed_usage(&rt, &org, &same_month, "error", 999_990, 0).await;
    seed_usage(&rt, &org, &previous_month, "error", 5_000_000, 0).await;

    let first = ingest(&base, project, &key, envelope(Some(&event_id(1)), &[])).await;
    assert_eq!(first.status, StatusCode::OK);
    let retry = ingest(&base, project, &key, envelope(Some(&event_id(1)), &[])).await;
    assert_eq!(retry.status, StatusCode::OK);
    let (_, usage) = api.get(&format!("/api/orgs/{org}/usage")).await;
    assert_eq!(usage["errors"]["used"], json!(999_991));
    assert_eq!(usage["errors"]["thresholds_reached"], json!([70, 90]));

    let sends = (2..22).map(|n| {
        let base = base.clone();
        let key = key.clone();
        tokio::spawn(async move {
            ingest(&base, project, &key, envelope(Some(&event_id(n)), &[])).await
        })
    });
    let results: Vec<Ingested> = futures::future::join_all(sends)
        .await
        .into_iter()
        .map(Result::unwrap)
        .collect();
    let ok = results
        .iter()
        .filter(|r| r.status == StatusCode::OK)
        .count();
    let refused: Vec<&Ingested> = results
        .iter()
        .filter(|r| r.status == StatusCode::TOO_MANY_REQUESTS)
        .collect();
    let statuses: Vec<(StatusCode, Value)> =
        results.iter().map(|r| (r.status, r.body.clone())).collect();
    assert_eq!((ok, refused.len()), (9, 11), "{statuses:?}");
    let expected = seconds_to_next_month();
    for refusal in &refused {
        assert_eq!(
            refusal.body,
            json!({"error": "monthly_quota_exceeded", "categories": "error"})
        );
        let retry: i64 = refusal.retry_after.as_deref().unwrap().parse().unwrap();
        assert!(
            (expected - 5..=expected + 1).contains(&retry),
            "{retry} vs {expected}"
        );
        assert_eq!(
            refusal.rate_limits.as_deref(),
            Some(format!("{retry}:error:organization:usage_exceeded").as_str())
        );
    }
    assert_eq!(
        tenant_scalar(&rt, &org, "SELECT COUNT(*) FROM events").await,
        10
    );
    let at_cap_retry = ingest(&base, project, &key, envelope(Some(&event_id(1)), &[])).await;
    assert_eq!(at_cap_retry.status, StatusCode::OK);
    let (_, usage) = api.get(&format!("/api/orgs/{org}/usage")).await;
    assert_eq!(usage["errors"]["used"], json!(1_000_000));
    assert_eq!(usage["errors"]["thresholds_reached"], json!([70, 90, 100]));
    stop(boot, server).await;

    let boot = env.boot_memory(lanes).await.unwrap();
    let (base, server) = serve(&boot).await;
    let rt = Runtime::get(&boot.app_context);
    let after_restart = ingest(&base, project, &key, envelope(Some(&event_id(99)), &[])).await;
    assert_eq!(after_restart.status, StatusCode::TOO_MANY_REQUESTS);
    assert_eq!(after_restart.body["error"], json!("monthly_quota_exceeded"));
    let logs_still_flow = ingest(
        &base,
        project,
        &key,
        envelope(None, &["log after error cap"]),
    )
    .await;
    assert_eq!(logs_still_flow.status, StatusCode::OK);
    assert_eq!(
        tenant_scalar(&rt, &org, "SELECT COUNT(*) FROM events").await,
        10
    );
    assert_eq!(alerts(&rt, &org).await.len(), 3);
    eventually(Duration::from_secs(15), || async {
        alerts(&rt, &org).await
            == vec![
                ("errors".to_owned(), 70, "not_configured".to_owned()),
                ("errors".to_owned(), 90, "not_configured".to_owned()),
                ("errors".to_owned(), 100, "not_configured".to_owned()),
            ]
    })
    .await;
    stop(boot, server).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn monthly_log_bytes_count_raw_log_usage_once_and_refuse_the_overflowing_batch() {
    let env = TestEnv::new("billing-monthly-logs");
    let boot = env.boot_memory(|_| {}).await.unwrap();
    let (base, server) = serve(&boot).await;
    let rt = Runtime::get(&boot.app_context);
    let api = Api::signup(&base, "logs-owner@example.test").await;
    let (roomy, roomy_project, roomy_dsn) = api.setup_source("Roomy").await;
    let (full, full_project, full_dsn) = api.setup_source("Full").await;
    let (same_month, previous_month) = other_days();
    seed_usage(&rt, &roomy, &same_month, "log", 10, 99_999_000_000).await;
    seed_usage(&rt, &roomy, &same_month, "log_adopted", 10, 99_999_000_000).await;
    seed_usage(&rt, &roomy, &previous_month, "log", 10, 200_000_000_000).await;
    seed_usage(&rt, &full, &same_month, "log", 10, 99_999_999_990).await;

    let accepted = ingest(
        &base,
        roomy_project,
        &dsn_key(&roomy_dsn),
        envelope(None, &["fits"]),
    )
    .await;
    assert_eq!(accepted.status, StatusCode::OK, "{}", accepted.body);
    let raw = tenant_scalar(&rt, &roomy, "SELECT raw_bytes FROM log_objects").await;
    let (_, usage) = api.get(&format!("/api/orgs/{roomy}/usage")).await;
    assert_eq!(usage["log_bytes"]["used"], json!(99_999_000_000i64 + raw));
    assert_eq!(usage["log_bytes"]["thresholds_reached"], json!([70, 90]));

    let refused = ingest(
        &base,
        full_project,
        &dsn_key(&full_dsn),
        envelope(None, &["over the allowance"]),
    )
    .await;
    assert_eq!(refused.status, StatusCode::TOO_MANY_REQUESTS);
    assert_eq!(
        refused.body,
        json!({"error": "monthly_quota_exceeded", "categories": "log_item"})
    );
    assert!(refused
        .rate_limits
        .unwrap()
        .ends_with(":log_item:organization:usage_exceeded"));
    assert_eq!(
        tenant_scalar(&rt, &full, "SELECT COUNT(*) FROM log_objects").await,
        0
    );
    let errors_still_flow = ingest(
        &base,
        full_project,
        &dsn_key(&full_dsn),
        envelope(Some(&event_id(7)), &[]),
    )
    .await;
    assert_eq!(errors_still_flow.status, StatusCode::OK);
    let states = |rows: Vec<(String, i64, String)>| -> Vec<(String, i64)> {
        rows.into_iter()
            .map(|(metric, percent, _)| (metric, percent))
            .collect()
    };
    assert_eq!(
        states(alerts(&rt, &roomy).await),
        vec![("log_bytes".to_owned(), 70), ("log_bytes".to_owned(), 90)]
    );
    assert_eq!(
        states(alerts(&rt, &full).await),
        vec![("log_bytes".to_owned(), 70), ("log_bytes".to_owned(), 90)],
        "an oversized batch does not exhaust the remaining ten bytes"
    );
    stop(boot, server).await;
}

#[derive(Default)]
struct CapturedMail {
    sent: Mutex<Vec<(String, String, String)>>,
    unavailable: std::sync::atomic::AtomicBool,
}

#[async_trait::async_trait]
impl AccountMail for CapturedMail {
    fn configured(&self) -> bool {
        true
    }

    async fn send(&self, message: AccountMessage) -> Result<(), MailFailure> {
        if self
            .unavailable
            .swap(false, std::sync::atomic::Ordering::SeqCst)
        {
            return Err(MailFailure::Unavailable);
        }
        self.sent.lock().unwrap().push((
            message.to.clone(),
            message.subject.to_owned(),
            message.text().to_owned(),
        ));
        Ok(())
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn usage_alerts_email_each_owner_once_and_retry_after_mail_outages() {
    let env = TestEnv::new("billing-usage-alert-mail");
    let boot = env.boot_memory(|_| {}).await.unwrap();
    let (base, server) = serve(&boot).await;
    let rt = Runtime::get(&boot.app_context);
    let owner = Api::signup(&base, "alert-owner@example.test").await;
    Api::signup(&base, "alert-admin@example.test").await;
    let (org, project, dsn) = owner.setup_source("Alerting org").await;
    let (status, _) = owner
        .post(
            &format!("/api/orgs/{org}/members"),
            json!({"email": "alert-admin@example.test", "role": "admin"}),
        )
        .await;
    assert_eq!(status, StatusCode::CREATED);
    let (same_month, _) = other_days();
    seed_usage(&rt, &org, &same_month, "error", 699_999, 0).await;
    let sent = ingest(
        &base,
        project,
        &dsn_key(&dsn),
        envelope(Some(&event_id(1)), &[]),
    )
    .await;
    assert_eq!(sent.status, StatusCode::OK);
    let later = now_secs() + 3_600;
    let tenant = rt.tenant(&org.parse::<OrgId>().unwrap()).await.unwrap();
    tenant
        .execute_raw(sql(
            "UPDATE usage_alerts SET state = 'pending', next_attempt_at = ?, finished_at = NULL",
            vec![later.into()],
        ))
        .await
        .unwrap();
    drop(tenant);
    let org_id: OrgId = org.parse().unwrap();
    let mail = CapturedMail::default();
    mail.unavailable
        .store(true, std::sync::atomic::Ordering::SeqCst);
    assert_eq!(
        alerts::deliver_at(&rt, &mail, &org_id, later + 1)
            .await
            .unwrap(),
        0
    );
    assert_eq!(
        alerts(&rt, &org).await,
        vec![("errors".to_owned(), 70, "pending".to_owned())]
    );
    assert_eq!(
        alerts::deliver_at(&rt, &mail, &org_id, later + 60)
            .await
            .unwrap(),
        0
    );
    assert_eq!(
        alerts::deliver_at(&rt, &mail, &org_id, later + 600)
            .await
            .unwrap(),
        1
    );
    assert_eq!(
        alerts::deliver_at(&rt, &mail, &org_id, later + 900)
            .await
            .unwrap(),
        0
    );
    let sent = mail.sent.lock().unwrap().clone();
    assert_eq!(sent.len(), 1);
    let (to, subject, text) = &sent[0];
    assert_eq!(to, "alert-owner@example.test");
    assert_eq!(
        subject,
        "PostDeploy: 70% of this month's error allowance used"
    );
    assert!(
        text.starts_with("Alerting org has used 700000 errors of 1000000 errors in "),
        "{text}"
    );
    assert!(
        text.contains(&format!("http://127.0.0.1:5167/dashboard/orgs/{org}")),
        "{text}"
    );
    assert_eq!(
        alerts(&rt, &org).await,
        vec![("errors".to_owned(), 70, "delivered".to_owned())]
    );
    stop(boot, server).await;
}

#[tokio::test]
async fn production_refuses_a_custom_stripe_api_base() {
    let env = TestEnv::new("billing-production-api-base");
    let config = env
        .config("test/billing-production-api-base/", |s| {
            s["billing"]["api_base"] = json!("http://127.0.0.1:9");
            s["notifications"]["public_url"] = json!("https://postdeploy.test");
        })
        .await;
    let error = TestApp::boot(StartMode::ServerOnly, &Environment::Production, config)
        .await
        .err()
        .expect("production boot must fail");
    assert!(
        error
            .to_string()
            .contains("production refuses a custom settings.billing.api_base"),
        "{error}"
    );
}

struct Billed {
    env: TestEnv,
    boot: BootResult,
    server: tokio::task::JoinHandle<()>,
    base: String,
    fake: Fake,
    rt: Arc<Runtime>,
}

async fn billed(name: &str, timeout_ms: u64) -> Billed {
    let env = TestEnv::new(name);
    let (fake, stripe) = Fake::start().await;
    env.with_stripe(
        json!({"secret_key": SECRET_KEY, "webhook_secret": WEBHOOK_SECRET, "price_id": PRICE}),
    );
    let boot = env
        .boot_memory(|s| {
            s["billing"]["api_base"] = json!(stripe);
            s["billing"]["request_timeout_ms"] = json!(timeout_ms);
        })
        .await
        .unwrap();
    let (base, server) = serve(&boot).await;
    let rt = Runtime::get(&boot.app_context);
    Billed {
        env,
        boot,
        server,
        base,
        fake,
        rt,
    }
}

async fn entitlement(api: &Api, org: &str) -> Value {
    let (status, billing) = api.get(&format!("/api/orgs/{org}/billing")).await;
    assert_eq!(status, StatusCode::OK);
    billing["entitlement"].clone()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn only_owners_check_out_and_paid_time_comes_from_verified_paid_annual_invoices() {
    let b = billed("billing-checkout-webhooks", 10_000).await;
    let owner = Api::signup(&b.base, "owner@example.test").await;
    let admin = Api::signup(&b.base, "admin@example.test").await;
    let (org, project, dsn) = owner.setup_source("Paying").await;
    let key = dsn_key(&dsn);
    let (status, _) = owner
        .post(
            &format!("/api/orgs/{org}/members"),
            json!({"email": "admin@example.test", "role": "admin"}),
        )
        .await;
    assert_eq!(status, StatusCode::CREATED);
    let (status, _) = admin
        .post(&format!("/api/orgs/{org}/billing/checkout"), json!({}))
        .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let (status, _) = admin
        .post(&format!("/api/orgs/{org}/billing/portal"), json!({}))
        .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(b.fake.state(|s| s.created_sessions.len()), 0);

    let (status, checkout) = owner
        .post(&format!("/api/orgs/{org}/billing/checkout"), json!({}))
        .await;
    assert_eq!(status, StatusCode::OK, "{checkout}");
    assert_eq!(
        checkout["url"],
        json!("https://checkout.stripe.test/cs_test_1")
    );
    let (status, again) = owner
        .post(&format!("/api/orgs/{org}/billing/checkout"), json!({}))
        .await;
    assert_eq!(
        (status, again["url"].clone()),
        (StatusCode::OK, checkout["url"].clone())
    );
    let form = b.fake.state(|s| s.created_sessions[0].clone());
    assert_eq!(b.fake.state(|s| s.created_sessions.len()), 1);
    assert_eq!(form["mode"], "subscription");
    assert_eq!(form["line_items[0][price]"], PRICE);
    assert_eq!(form["line_items[0][quantity]"], "1");
    assert_eq!(form["client_reference_id"], org);
    assert_eq!(
        form["success_url"],
        format!("http://127.0.0.1:5167/dashboard/orgs/{org}?billing=success")
    );
    assert!(b
        .fake
        .state(|s| s.idempotency_keys[0].starts_with("checkout-")));
    assert_eq!(
        b.fake.state(|s| (s.unauthenticated, s.wrong_version)),
        (0, 0)
    );

    set_created(&b.rt, &org, now_secs() - 2 * 1_209_600).await;
    assert_eq!(
        entitlement(&owner, &org).await["state"],
        json!("subscription_required")
    );
    let now = now_secs();
    b.fake.complete("cs_test_1", "cus_paying", "sub_paying");
    b.fake.invoice(
        "in_paid",
        "cus_paying",
        "sub_paying",
        "paid",
        PRICE,
        1,
        "usd",
        now - 60,
        now - 60 + YEAR,
    );
    assert_eq!(
        entitlement(&owner, &org).await["state"],
        json!("subscription_required"),
        "a completed checkout grants nothing before verification"
    );

    let invoice_first = event("evt_invoice", "invoice.paid", "invoice", "in_paid");
    let (status, _) = webhook(&b.base, &invoice_first).await;
    assert_eq!(status, StatusCode::OK);
    let (status, _) = webhook(
        &b.base,
        &event(
            "evt_sub",
            "customer.subscription.created",
            "subscription",
            "sub_paying",
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        entitlement(&owner, &org).await["state"],
        json!("subscription_required")
    );

    let completed = event(
        "evt_checkout",
        "checkout.session.completed",
        "checkout.session",
        "cs_test_1",
    );
    let tampered = completed.replace("cs_test_1", "cs_test_9");
    let (status, body) = deliver(&b.base, &tampered, &sign(&completed, now_secs())).await;
    assert_eq!(
        (status, body["error"].clone()),
        (StatusCode::BAD_REQUEST, json!("invalid_signature"))
    );
    let (status, _) = deliver(&b.base, &completed, &sign(&completed, now_secs() - 301)).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let (status, _) = deliver(&b.base, &completed, "t=1,v1=00").await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(
        entitlement(&owner, &org).await["state"],
        json!("subscription_required")
    );
    let refused = ingest(&b.base, project, &key, envelope(Some(&event_id(1)), &[])).await;
    assert_eq!(refused.body["error"], json!("subscription_required"));

    let (status, body) = webhook(&b.base, &completed).await;
    assert_eq!((status, body), (StatusCode::OK, json!({"received": true})));
    assert_eq!(
        entitlement(&owner, &org).await,
        json!({"state": "paid", "until": now - 60 + YEAR})
    );
    let (status, body) = webhook(&b.base, &completed).await;
    assert_eq!(
        (status, body),
        (StatusCode::OK, json!({"received": true, "duplicate": true}))
    );
    let (status, _) = deliver(&b.base, &tampered, &sign(&completed, now_secs())).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let accepted = ingest(&b.base, project, &key, envelope(Some(&event_id(2)), &[])).await;
    assert_eq!(accepted.status, StatusCode::OK);
    let (status, body) = owner
        .post(&format!("/api/orgs/{org}/billing/checkout"), json!({}))
        .await;
    assert_eq!(
        (status, body["error"].clone()),
        (StatusCode::CONFLICT, json!("subscription_exists"))
    );
    let (status, portal) = owner
        .post(&format!("/api/orgs/{org}/billing/portal"), json!({}))
        .await;
    assert_eq!(
        (status, portal["url"].clone()),
        (
            StatusCode::OK,
            json!("https://billing.stripe.test/cus_paying")
        )
    );

    b.fake.invoice(
        "in_renewal_failed",
        "cus_paying",
        "sub_paying",
        "open",
        PRICE,
        1,
        "usd",
        now - 60 + YEAR,
        now - 60 + 2 * YEAR,
    );
    b.fake
        .subscription("sub_paying", "cus_paying", "past_due", false);
    let (status, _) = webhook(
        &b.base,
        &event(
            "evt_failed",
            "invoice.payment_failed",
            "invoice",
            "in_renewal_failed",
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        entitlement(&owner, &org).await,
        json!({"state": "paid", "until": now - 60 + YEAR})
    );

    b.fake
        .subscription("sub_paying", "cus_paying", "active", true);
    webhook(
        &b.base,
        &event(
            "evt_cancel",
            "customer.subscription.updated",
            "subscription",
            "sub_paying",
        ),
    )
    .await;
    b.fake
        .subscription("sub_paying", "cus_paying", "canceled", false);
    webhook(
        &b.base,
        &event(
            "evt_deleted",
            "customer.subscription.deleted",
            "subscription",
            "sub_paying",
        ),
    )
    .await;
    let (_, billing) = owner.get(&format!("/api/orgs/{org}/billing")).await;
    assert_eq!(
        billing["entitlement"],
        json!({"state": "paid", "until": now - 60 + YEAR})
    );
    assert_eq!(billing["subscription"]["status"], json!("canceled"));
    let receipts: i64 =
        b.rt.control
            .query_one_raw(sql(
                "SELECT COUNT(*) FROM billing_events WHERE processed_at IS NOT NULL",
                vec![],
            ))
            .await
            .unwrap()
            .unwrap()
            .try_get_by_index(0)
            .unwrap();
    assert_eq!(receipts, 6);
    let _ = &b.env;
    stop(b.boot, b.server).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wrong_plans_foreign_sessions_and_other_customers_never_grant_paid_time() {
    let b = billed("billing-isolation", 10_000).await;
    let first = Api::signup(&b.base, "first@example.test").await;
    let second = Api::signup(&b.base, "second@example.test").await;
    let (org_a, ..) = first.setup_source("A").await;
    let (org_b, ..) = second.setup_source("B").await;
    for org in [&org_a, &org_b] {
        set_created(&b.rt, org, now_secs() - 2 * 1_209_600).await;
    }
    let now = now_secs();

    let (status, _) = first
        .post(&format!("/api/orgs/{org_a}/billing/checkout"), json!({}))
        .await;
    assert_eq!(status, StatusCode::OK);
    b.fake.complete("cs_test_1", "cus_a", "sub_a");
    for (id, price, quantity, currency, length) in [
        ("in_wrong_price", "price_monthly", 1, "usd", YEAR),
        ("in_two_seats", PRICE, 2, "usd", YEAR),
        ("in_euro", PRICE, 1, "eur", YEAR),
        ("in_month", PRICE, 1, "usd", 31 * 86_400),
        ("in_zero_price", PRICE, 1, "usd", YEAR),
        ("in_unsettled", PRICE, 1, "usd", YEAR),
    ] {
        b.fake.invoice(
            id,
            "cus_a",
            "sub_a",
            "paid",
            price,
            quantity,
            currency,
            now - 60,
            now - 60 + length,
        );
    }
    b.fake.patch_invoice("in_zero_price", |invoice| {
        invoice["lines"]["data"][0]["amount"] = json!(0);
        invoice["total"] = json!(0);
        invoice["amount_due"] = json!(0);
        invoice["amount_paid"] = json!(0);
    });
    b.fake.patch_invoice("in_unsettled", |invoice| {
        invoice["amount_remaining"] = json!(100)
    });
    b.fake.invoice(
        "in_open",
        "cus_a",
        "sub_a",
        "open",
        PRICE,
        1,
        "usd",
        now - 60,
        now - 60 + YEAR,
    );
    let (status, _) = webhook(
        &b.base,
        &event(
            "evt_a",
            "checkout.session.completed",
            "checkout.session",
            "cs_test_1",
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (_, billing) = first.get(&format!("/api/orgs/{org_a}/billing")).await;
    assert_eq!(
        billing["entitlement"]["state"],
        json!("subscription_required")
    );
    assert_eq!(billing["subscription"]["status"], json!("active"));
    assert_eq!(billing["subscription"]["paid_until"], Value::Null);

    b.fake.session(
        "cs_forged",
        json!({"id": "cs_forged", "mode": "subscription", "status": "complete",
            "client_reference_id": org_b, "customer": "cus_a", "subscription": "sub_a",
            "expires_at": now + 3600, "url": null}),
    );
    b.fake.invoice(
        "in_valid_a",
        "cus_a",
        "sub_a",
        "paid",
        PRICE,
        1,
        "usd",
        now - 60,
        now - 60 + YEAR,
    );
    b.fake.patch_invoice("in_valid_a", |invoice| {
        invoice["total"] = json!(0);
        invoice["amount_due"] = json!(0);
        invoice["amount_paid"] = json!(0);
        invoice["total_discount_amounts"] = json!([{"amount": 44_900, "discount": "di_forever"}]);
    });
    let (status, _) = webhook(
        &b.base,
        &event(
            "evt_forged",
            "checkout.session.completed",
            "checkout.session",
            "cs_forged",
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (_, billing_b) = second.get(&format!("/api/orgs/{org_b}/billing")).await;
    assert_eq!(billing_b["subscription"], Value::Null);
    assert_eq!(
        billing_b["entitlement"]["state"],
        json!("subscription_required")
    );

    let (status, _) = second
        .post(&format!("/api/orgs/{org_b}/billing/checkout"), json!({}))
        .await;
    assert_eq!(status, StatusCode::OK);
    b.fake.complete("cs_test_2", "cus_a", "sub_b_on_a");
    let (status, _) = webhook(
        &b.base,
        &event(
            "evt_b",
            "checkout.session.completed",
            "checkout.session",
            "cs_test_2",
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (_, billing_b) = second.get(&format!("/api/orgs/{org_b}/billing")).await;
    assert_eq!(
        billing_b["subscription"],
        Value::Null,
        "a customer belongs to one organization"
    );
    let (status, _) = second.get(&format!("/api/orgs/{org_a}/billing")).await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    let (status, billing) = first
        .post(&format!("/api/orgs/{org_a}/billing/refresh"), json!({}))
        .await;
    assert_eq!(status, StatusCode::OK, "{billing}");
    assert_eq!(
        billing["entitlement"],
        json!({"state": "paid", "until": now - 60 + YEAR})
    );

    let third = Api::signup(&b.base, "credit@example.test").await;
    let (org_c, ..) = third.setup_source("C").await;
    set_created(&b.rt, &org_c, now_secs() - 2 * 1_209_600).await;
    let (status, _) = third
        .post(&format!("/api/orgs/{org_c}/billing/checkout"), json!({}))
        .await;
    assert_eq!(status, StatusCode::OK);
    b.fake.complete("cs_test_3", "cus_c", "sub_c");
    b.fake.invoice(
        "in_credit_c",
        "cus_c",
        "sub_c",
        "paid",
        PRICE,
        1,
        "usd",
        now - 60,
        now - 60 + YEAR,
    );
    b.fake.patch_invoice("in_credit_c", |invoice| {
        invoice["amount_due"] = json!(0);
        invoice["amount_paid"] = json!(0);
        invoice["starting_balance"] = json!(-44_900);
    });
    let (status, _) = webhook(
        &b.base,
        &event("evt_c", "invoice.paid", "invoice", "in_credit_c"),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (status, _) = webhook(
        &b.base,
        &event(
            "evt_c_checkout",
            "checkout.session.completed",
            "checkout.session",
            "cs_test_3",
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        entitlement(&third, &org_c).await,
        json!({"state": "paid", "until": now - 60 + YEAR})
    );
    stop(b.boot, b.server).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn truncated_invoice_history_without_a_verified_term_fails_and_stays_retryable() {
    let b = billed("billing-truncated-history", 10_000).await;
    let owner = Api::signup(&b.base, "history@example.test").await;
    let (org, ..) = owner.setup_source("History").await;
    set_created(&b.rt, &org, now_secs() - 2 * 1_209_600).await;
    let now = now_secs();
    let (status, _) = owner
        .post(&format!("/api/orgs/{org}/billing/checkout"), json!({}))
        .await;
    assert_eq!(status, StatusCode::OK);
    b.fake.complete("cs_test_1", "cus_history", "sub_history");
    b.fake.invoice(
        "in_old_monthly",
        "cus_history",
        "sub_history",
        "paid",
        "price_monthly",
        1,
        "usd",
        now - 60,
        now - 60 + 31 * 86_400,
    );
    b.fake.0.lock().unwrap().truncated_invoices = true;
    let completed = event(
        "evt_history",
        "checkout.session.completed",
        "checkout.session",
        "cs_test_1",
    );
    let (status, body) = webhook(&b.base, &completed).await;
    assert_eq!(
        (status, body),
        (
            StatusCode::SERVICE_UNAVAILABLE,
            json!({"error": "billing_history_incomplete"})
        )
    );
    let cursors = b.fake.state(|s| s.invoice_cursors.clone());
    assert_eq!(cursors.len(), 10);
    assert_eq!(cursors[0], None);
    assert_eq!(cursors[1].as_deref(), Some("in_old_monthly"));
    assert_eq!(
        entitlement(&owner, &org).await["state"],
        json!("subscription_required")
    );

    b.fake.invoice(
        "in_annual",
        "cus_history",
        "sub_history",
        "paid",
        PRICE,
        1,
        "usd",
        now - 60,
        now - 60 + YEAR,
    );
    let (status, body) = webhook(&b.base, &completed).await;
    assert_eq!((status, body), (StatusCode::OK, json!({"received": true})));
    assert_eq!(
        entitlement(&owner, &org).await,
        json!({"state": "paid", "until": now - 60 + YEAR})
    );
    stop(b.boot, b.server).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn checkout_recovers_a_session_stripe_created_when_the_local_request_failed() {
    let b = billed("billing-checkout-recovery", 1_000).await;
    let owner = Api::signup(&b.base, "recovery@example.test").await;
    let (org, ..) = owner.setup_source("Recovery").await;
    b.fake.0.lock().unwrap().slow_creates = 1;
    let (status, body) = owner
        .post(&format!("/api/orgs/{org}/billing/checkout"), json!({}))
        .await;
    assert_eq!(
        (status, body["error"].clone()),
        (
            StatusCode::SERVICE_UNAVAILABLE,
            json!("billing_provider_unavailable")
        )
    );
    assert_eq!(b.fake.state(|s| s.created_sessions.len()), 1);
    assert_eq!(
        delete_form(&owner, &org, "Recovery").await,
        (
            StatusCode::CONFLICT,
            json!({"error":"billing_checkout_pending"})
        )
    );
    let (status, body) = owner
        .post(&format!("/api/orgs/{org}/billing/checkout"), json!({}))
        .await;
    assert_eq!(
        (status, body["url"].clone()),
        (
            StatusCode::OK,
            json!("https://checkout.stripe.test/cs_test_1")
        )
    );
    assert_eq!(b.fake.state(|s| s.created_sessions.len()), 1);
    let keys = b.fake.state(|s| s.idempotency_keys.clone());
    assert_eq!(keys.len(), 2);
    assert_eq!(keys[0], keys[1]);

    b.fake.price(PRICE, 4_900, "usd", "month", 1);
    let other = Api::signup(&b.base, "badprice@example.test").await;
    let (org2, ..) = other.setup_source("Bad price").await;
    let (status, body) = other
        .post(&format!("/api/orgs/{org2}/billing/checkout"), json!({}))
        .await;
    assert_eq!(
        (status, body["error"].clone()),
        (
            StatusCode::SERVICE_UNAVAILABLE,
            json!("billing_price_invalid")
        )
    );
    assert_eq!(b.fake.state(|s| s.created_sessions.len()), 1);
    stop(b.boot, b.server).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn pending_completed_checkout_is_canonical_even_in_final_minute_or_after_local_expiry() {
    let b = billed("billing-pending-expiry", 10_000).await;
    let api = Api::signup(&b.base, "pending@example.test").await;
    for (n, expires) in [(1, now_secs() + 30), (2, now_secs() - 60)] {
        let (org, ..) = api.setup_source(&format!("Pending {n}")).await;
        let path = format!("/api/orgs/{org}/billing/checkout");
        assert_eq!(api.post(&path, json!({})).await.0, StatusCode::OK);
        let session = format!("cs_test_{n}");
        b.fake
            .complete(&session, &format!("cus_{n}"), &format!("sub_{n}"));
        b.fake.0.lock().unwrap().sessions.get_mut(&session).unwrap()["expires_at"] = json!(expires);
        b.rt.control
            .execute_raw(sql(
                "UPDATE billing_checkouts SET expires_at = ?, created_at = ? WHERE org_id = ?",
                vec![
                    expires.into(),
                    (if n == 1 {
                        now_secs()
                    } else {
                        now_secs() - 90_000
                    })
                    .into(),
                    org.clone().into(),
                ],
            ))
            .await
            .unwrap();
        let (status, body) = api.post(&path, json!({})).await;
        assert_eq!(
            (status, body),
            (StatusCode::CONFLICT, json!({"error":"subscription_exists"}))
        );
        assert_eq!(b.fake.state(|s| s.created_sessions.len()), n);
        let (_, account) = api.get(&format!("/api/orgs/{org}/billing")).await;
        assert_eq!(account["subscription"]["status"], "active");
    }
    stop(b.boot, b.server).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn open_checkout_near_expiry_blocks_new_subscription_until_canonical_expiration() {
    let b = billed("billing-open-expiry", 10_000).await;
    let api = Api::signup(&b.base, "open@example.test").await;
    let (org, ..) = api.setup_source("Open checkout").await;
    let path = format!("/api/orgs/{org}/billing/checkout");
    assert_eq!(api.post(&path, json!({})).await.0, StatusCode::OK);
    b.fake
        .0
        .lock()
        .unwrap()
        .sessions
        .get_mut("cs_test_1")
        .unwrap()["expires_at"] = json!(now_secs() + 30);
    b.rt.control
        .execute_raw(sql(
            "UPDATE billing_checkouts SET expires_at = ? WHERE org_id = ?",
            vec![(now_secs() - 1).into(), org.clone().into()],
        ))
        .await
        .unwrap();
    let (status, body) = api.post(&path, json!({})).await;
    assert_eq!(
        (status, body),
        (
            StatusCode::CONFLICT,
            json!({"error":"billing_checkout_pending"})
        )
    );
    assert_eq!(b.fake.state(|s| s.created_sessions.len()), 1);
    b.fake
        .0
        .lock()
        .unwrap()
        .sessions
        .get_mut("cs_test_1")
        .unwrap()["status"] = json!("expired");
    assert_eq!(api.post(&path, json!({})).await.0, StatusCode::OK);
    assert_eq!(b.fake.state(|s| s.created_sessions.len()), 2);
    stop(b.boot, b.server).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn credited_settled_invoice_grants_the_same_year_before_or_after_first_sync() {
    let b = billed("billing-credit-order", 10_000).await;
    let api = Api::signup(&b.base, "credit-order@example.test").await;
    let start = now_secs() - 60;
    for (n, credit_first) in [(1, true), (2, false)] {
        let (org, ..) = api.setup_source(&format!("Credit {n}")).await;
        set_created(&b.rt, &org, now_secs() - 3_000_000).await;
        assert_eq!(
            api.post(&format!("/api/orgs/{org}/billing/checkout"), json!({}))
                .await
                .0,
            StatusCode::OK
        );
        b.fake.complete(
            &format!("cs_test_{n}"),
            &format!("cus_credit{n}"),
            &format!("sub_credit{n}"),
        );
        let invoice = format!("in_credit{n}");
        b.fake.invoice(
            &invoice,
            &format!("cus_credit{n}"),
            &format!("sub_credit{n}"),
            "paid",
            PRICE,
            1,
            "usd",
            start,
            start + YEAR,
        );
        if credit_first {
            b.fake.patch_invoice(&invoice, |i| {
                i["post_payment_credit_notes_amount"] = json!(44_900)
            });
        }
        let path = format!("/api/orgs/{org}/billing/refresh");
        assert_eq!(api.post(&path, json!({})).await.0, StatusCode::OK);
        b.fake.patch_invoice(&invoice, |i| {
            i["post_payment_credit_notes_amount"] = json!(44_900)
        });
        let (status, account) = api.post(&path, json!({})).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(
            account["entitlement"],
            json!({"state":"paid","until":start+YEAR})
        );
    }
    stop(b.boot, b.server).await;
}

async fn delete_form(api: &Api, org: &str, name: &str) -> (StatusCode, Value) {
    let http = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .unwrap();
    let r = http
        .post(format!("{}/dashboard/orgs/{org}/delete", api.base))
        .header("cookie", api.cookie.as_deref().unwrap())
        .header("origin", "http://127.0.0.1:5167")
        .form(&[
            ("confirmed_name", name),
            ("_csrf_token", api.csrf.as_deref().unwrap()),
        ])
        .send()
        .await
        .unwrap();
    (r.status(), r.json().await.unwrap_or(Value::Null))
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn deletion_requires_canonical_nonrenewal_and_preserves_access_when_refused() {
    let b = billed("billing-deletion", 10_000).await;
    let api = Api::signup(&b.base, "delete-billed@example.test").await;
    let (org, ..) = api.setup_source("Billed deletion").await;
    assert_eq!(
        api.post(&format!("/api/orgs/{org}/billing/checkout"), json!({}))
            .await
            .0,
        StatusCode::OK
    );
    b.fake.complete("cs_test_1", "cus_delete", "sub_delete");
    let (status, body) = delete_form(&api, &org, "Billed deletion").await;
    assert_eq!(
        (status, body),
        (
            StatusCode::CONFLICT,
            json!({"error":"billing_subscription_renewing"})
        )
    );
    assert_eq!(
        api.get(&format!("/api/orgs/{org}/projects")).await.0,
        StatusCode::OK
    );
    let row = b.rt.control.query_one_raw(sql(
        "SELECT lifecycle, (SELECT COUNT(*) FROM memberships WHERE org_id = o.id) AS members, (SELECT COUNT(*) FROM projects WHERE org_id = o.id) AS projects, (SELECT COUNT(*) FROM organization_deletions WHERE org_id = o.id) AS jobs FROM organizations o WHERE id = ?", vec![org.clone().into()]
    )).await.unwrap().unwrap();
    assert_eq!(row.try_get::<String>("", "lifecycle").unwrap(), "active");
    assert_eq!(row.try_get::<i64>("", "members").unwrap(), 1);
    assert_eq!(row.try_get::<i64>("", "projects").unwrap(), 1);
    assert_eq!(row.try_get::<i64>("", "jobs").unwrap(), 0);
    b.rt.control
        .execute_raw(sql(
            "UPDATE billing_accounts SET cancel_at_period_end = 1 WHERE org_id = ?",
            vec![org.clone().into()],
        ))
        .await
        .unwrap();
    assert_eq!(
        delete_form(&api, &org, "Billed deletion").await.0,
        StatusCode::CONFLICT
    );
    b.fake.0.lock().unwrap().subscriptions.remove("sub_delete");
    assert_eq!(
        delete_form(&api, &org, "Billed deletion").await,
        (
            StatusCode::SERVICE_UNAVAILABLE,
            json!({"error":"billing_provider_unavailable"})
        )
    );
    assert_eq!(
        api.get(&format!("/api/orgs/{org}/projects")).await.0,
        StatusCode::OK
    );
    b.fake
        .subscription("sub_delete", "cus_delete", "active", true);
    assert_eq!(
        delete_form(&api, &org, "Billed deletion").await.0,
        StatusCode::SEE_OTHER
    );
    stop(b.boot, b.server).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn mixed_envelope_quota_refusal_stores_neither_category_on_retries() {
    let env = TestEnv::new("billing-mixed-refusal");
    let boot = env.boot_memory(|_| {}).await.unwrap();
    let (base, server) = serve(&boot).await;
    let rt = Runtime::get(&boot.app_context);
    let api = Api::signup(&base, "mixed@example.test").await;
    let (day, _) = other_days();
    for (name, category, accepted, bytes, expected) in [
        ("Errors full", "error", 1_000_000, 0, "error"),
        ("Logs full", "log", 1, 100_000_000_000, "log_item"),
    ] {
        let (org, project, dsn) = api.setup_source(name).await;
        seed_usage(&rt, &org, &day, category, accepted, bytes).await;
        for _ in 0..2 {
            let result = ingest(
                &base,
                project,
                &dsn_key(&dsn),
                envelope(Some(&event_id(900)), &["must not persist"]),
            )
            .await;
            assert_eq!(result.status, StatusCode::TOO_MANY_REQUESTS);
            assert_eq!(
                result.body,
                json!({"error":"monthly_quota_exceeded", "categories":expected})
            );
            assert_eq!(
                tenant_scalar(&rt, &org, "SELECT COUNT(*) FROM events").await,
                0
            );
            assert_eq!(
                tenant_scalar(&rt, &org, "SELECT COUNT(*) FROM log_objects").await,
                0
            );
            let (_, usage) = api.get(&format!("/api/orgs/{org}/usage")).await;
            assert_eq!(
                usage["errors"]["used"],
                json!(if category == "error" { 1_000_000 } else { 0 })
            );
            assert_eq!(usage["log_bytes"]["used"], json!(bytes));
        }
    }
    stop(boot, server).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn refused_oversized_error_batch_alerts_only_committed_thresholds() {
    let env = TestEnv::new("billing-alert-boundary");
    let boot = env.boot_memory(|_| {}).await.unwrap();
    let (base, server) = serve(&boot).await;
    let rt = Runtime::get(&boot.app_context);
    let api = Api::signup(&base, "boundary@example.test").await;
    let (org, project, dsn) = api.setup_source("Boundary").await;
    let (day, _) = other_days();
    seed_usage(&rt, &org, &day, "error", 999_999, 0).await;
    let mut body = envelope(Some(&event_id(901)), &[]);
    let extra = envelope(Some(&event_id(902)), &[]);
    let after_header = extra.iter().position(|b| *b == b'\n').unwrap() + 1;
    body.extend_from_slice(&extra[after_header..]);
    assert_eq!(
        ingest(&base, project, &dsn_key(&dsn), body).await.status,
        StatusCode::TOO_MANY_REQUESTS
    );
    assert_eq!(
        alerts(&rt, &org)
            .await
            .into_iter()
            .map(|(_, p, _)| p)
            .collect::<Vec<_>>(),
        vec![70, 90]
    );
    assert_eq!(
        ingest(
            &base,
            project,
            &dsn_key(&dsn),
            envelope(Some(&event_id(903)), &[])
        )
        .await
        .status,
        StatusCode::OK
    );
    assert_eq!(
        alerts(&rt, &org)
            .await
            .into_iter()
            .map(|(_, p, _)| p)
            .collect::<Vec<_>>(),
        vec![70, 90, 100]
    );
    stop(boot, server).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn deletion_and_inflight_checkout_share_the_same_critical_section() {
    let b = billed("billing-delete-checkout-race", 10_000).await;
    let api = Api::signup(&b.base, "delete-race@example.test").await;
    let (org, ..) = api.setup_source("Checkout race").await;
    b.fake.0.lock().unwrap().slow_creates = 1;
    let checkout_api = api.clone();
    let path = format!("/api/orgs/{org}/billing/checkout");
    let checkout = tokio::spawn(async move { checkout_api.post(&path, json!({})).await });
    tokio::time::timeout(Duration::from_secs(5), async {
        while b.fake.state(|s| s.created_sessions.len()) == 0 {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .unwrap();
    let deleted = delete_form(&api, &org, "Checkout race").await;
    assert_eq!(checkout.await.unwrap().0, StatusCode::OK);
    assert_eq!(
        deleted,
        (
            StatusCode::CONFLICT,
            json!({"error":"billing_checkout_pending"})
        )
    );
    assert_eq!(b.fake.state(|s| s.created_sessions.len()), 1);
    assert_eq!(
        api.get(&format!("/api/orgs/{org}/projects")).await.0,
        StatusCode::OK
    );
    stop(b.boot, b.server).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn deletion_accepts_terminal_subscriptions_and_refuses_unknown_provider_state() {
    let b = billed("billing-delete-terminal", 10_000).await;
    let api = Api::signup(&b.base, "delete-terminal@example.test").await;
    for (n, status, cancel, expected) in [
        (1, "canceled", false, StatusCode::SEE_OTHER),
        (2, "incomplete_expired", false, StatusCode::SEE_OTHER),
        (
            3,
            "unrecognized_status",
            true,
            StatusCode::SERVICE_UNAVAILABLE,
        ),
        (4, "past_due", false, StatusCode::CONFLICT),
    ] {
        let name = format!("Terminal {n}");
        let (org, ..) = api.setup_source(&name).await;
        assert_eq!(
            api.post(&format!("/api/orgs/{org}/billing/checkout"), json!({}))
                .await
                .0,
            StatusCode::OK
        );
        b.fake.complete(
            &format!("cs_test_{n}"),
            &format!("cus_term{n}"),
            &format!("sub_term{n}"),
        );
        b.fake.subscription(
            &format!("sub_term{n}"),
            &format!("cus_term{n}"),
            status,
            cancel,
        );
        let (actual, body) = delete_form(&api, &org, &name).await;
        assert_eq!(actual, expected, "{body}");
        if expected == StatusCode::SERVICE_UNAVAILABLE {
            assert_eq!(body, json!({"error":"billing_provider_unknown"}));
        }
        if expected != StatusCode::SEE_OTHER {
            assert_eq!(
                api.get(&format!("/api/orgs/{org}/projects")).await.0,
                StatusCode::OK
            );
        }
    }
    stop(b.boot, b.server).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn mixed_envelope_reservation_counts_identical_new_error_ids_once() {
    let env = TestEnv::new("billing-mixed-dedup");
    let boot = env.boot_memory(|_| {}).await.unwrap();
    let (base, server) = serve(&boot).await;
    let rt = Runtime::get(&boot.app_context);
    let api = Api::signup(&base, "mixed-dedup@example.test").await;
    let (org, project, dsn) = api.setup_source("Mixed dedup").await;
    let (day, _) = other_days();
    seed_usage(&rt, &org, &day, "error", 999_999, 0).await;
    let mut body = envelope(Some(&event_id(990)), &["one log"]);
    let extra = envelope(Some(&event_id(990)), &[]);
    let after_header = extra.iter().position(|b| *b == b'\n').unwrap() + 1;
    body.extend_from_slice(&extra[after_header..]);
    let result = ingest(&base, project, &dsn_key(&dsn), body).await;
    assert_eq!(result.status, StatusCode::OK, "{}", result.body);
    assert_eq!(
        tenant_scalar(&rt, &org, "SELECT COUNT(*) FROM events").await,
        1
    );
    assert_eq!(
        tenant_scalar(&rt, &org, "SELECT COUNT(*) FROM log_objects").await,
        1
    );
    let (_, usage) = api.get(&format!("/api/orgs/{org}/usage")).await;
    assert_eq!(usage["errors"]["used"], 1_000_000);
    stop(boot, server).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_linked_subscription_blocks_checkout_during_failed_sync_and_unknown_status() {
    let b = billed("billing-linked-sync-failure", 10_000).await;
    let api = Api::signup(&b.base, "sync-recovery@example.test").await;
    let (org, ..) = api.setup_source("Sync recovery").await;
    let path = format!("/api/orgs/{org}/billing/checkout");
    assert_eq!(api.post(&path, json!({})).await.0, StatusCode::OK);
    b.fake.complete("cs_test_1", "cus_sync", "sub_sync");
    b.fake.0.lock().unwrap().subscriptions.remove("sub_sync");
    let body = event(
        "evt_failed_sync",
        "checkout.session.completed",
        "checkout.session",
        "cs_test_1",
    );
    assert_eq!(
        webhook(&b.base, &body).await.0,
        StatusCode::SERVICE_UNAVAILABLE
    );
    assert_eq!(
        api.post(&path, json!({})).await,
        (StatusCode::CONFLICT, json!({"error":"subscription_exists"}))
    );
    assert_eq!(b.fake.state(|state| state.created_sessions.len()), 1);
    b.fake
        .subscription("sub_sync", "cus_sync", "future_status", false);
    assert_eq!(
        api.post(&format!("/api/orgs/{org}/billing/refresh"), json!({}))
            .await
            .0,
        StatusCode::OK
    );
    assert_eq!(api.post(&path, json!({})).await.0, StatusCode::CONFLICT);
    assert_eq!(b.fake.state(|state| state.created_sessions.len()), 1);
    b.fake
        .subscription("sub_sync", "cus_sync", "canceled", false);
    assert_eq!(
        api.post(&format!("/api/orgs/{org}/billing/refresh"), json!({}))
            .await
            .0,
        StatusCode::OK
    );
    assert_eq!(api.post(&path, json!({})).await.0, StatusCode::OK);
    assert_eq!(b.fake.state(|state| state.created_sessions.len()), 2);
    stop(b.boot, b.server).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_timed_out_checkout_recovers_after_the_provider_idempotency_window() {
    let b = billed("billing-stale-attempt", 1_000).await;
    let api = Api::signup(&b.base, "stale-attempt@example.test").await;
    let (org, ..) = api.setup_source("Stale attempt").await;
    let path = format!("/api/orgs/{org}/billing/checkout");
    b.fake.0.lock().unwrap().slow_creates = 1;
    assert_eq!(
        api.post(&path, json!({})).await.0,
        StatusCode::SERVICE_UNAVAILABLE
    );
    b.rt.control
        .execute_raw(sql(
            "UPDATE billing_checkouts SET created_at = ? WHERE org_id = ?",
            vec![(now_secs() - 26 * 3_600).into(), org.clone().into()],
        ))
        .await
        .unwrap();
    {
        let mut state = b.fake.0.lock().unwrap();
        state.idempotent.clear();
        let old = state.sessions.get_mut("cs_test_1").unwrap();
        old["status"] = json!("expired");
        old["expires_at"] = json!(now_secs() - 3_600);
        old["url"] = Value::Null;
    }
    let expected = (
        StatusCode::OK,
        json!({"url":"https://checkout.stripe.test/cs_test_2"}),
    );
    assert_eq!(api.post(&path, json!({})).await, expected);
    assert_eq!(api.post(&path, json!({})).await, expected);
    assert_eq!(b.fake.state(|state| state.created_sessions.len()), 2);
    let keys = b.fake.state(|state| state.idempotency_keys.clone());
    assert_eq!(keys.len(), 2);
    assert_eq!(keys[0], keys[1]);
    let row = b.rt.control.query_one_raw(sql("SELECT COUNT(*) AS n, MAX(session_id) AS session FROM billing_checkouts WHERE org_id = ?", vec![org.into()])).await.unwrap().unwrap();
    assert_eq!(row.try_get::<i64>("", "n").unwrap(), 1);
    assert_eq!(row.try_get::<String>("", "session").unwrap(), "cs_test_2");
    stop(b.boot, b.server).await;
}

fn sent(mail: &CapturedMail) -> Vec<(String, String, String)> {
    std::mem::take(&mut *mail.sent.lock().unwrap())
}

async fn trial_mailbox(
    name: &str,
) -> (
    TestEnv,
    BootResult,
    String,
    tokio::task::JoinHandle<()>,
    std::sync::Arc<Runtime>,
) {
    let env = TestEnv::new(name);
    let boot = env.boot_memory(|_| {}).await.unwrap();
    let (base, server) = serve(&boot).await;
    let rt = Runtime::get(&boot.app_context);
    (env, boot, base, server, rt)
}

fn billing_page(rt: &Runtime, org: &str) -> String {
    format!(
        "{}/dashboard/orgs/{org}/billing",
        rt.settings.notifications.public_url.trim_end_matches('/')
    )
}

#[tokio::test]
async fn trial_notice_selection_for_each_window() {
    let (env, boot, base, server, rt) = trial_mailbox("trial-notice-window").await;
    let owner = Api::signup(&base, "window-owner@example.test").await;
    let (org, _, _) = owner.setup_source("Window").await;
    let created = 1_700_000_000;
    set_created(&rt, &org, created).await;
    let org_id: OrgId = org.parse().unwrap();
    let ends = created + billing::TRIAL_SECS;
    let soon = ends - notices::NOTICE_LEAD_SECS;
    assert_eq!(notices::due(created, None, soon - 1), None);
    assert_eq!(
        notices::due(created, None, soon),
        Some(notices::TrialNotice::EndsSoon)
    );
    assert_eq!(
        notices::due(created, None, ends - 1),
        Some(notices::TrialNotice::EndsSoon)
    );
    assert_eq!(
        notices::due(created, None, ends),
        Some(notices::TrialNotice::Ended)
    );
    assert_eq!(notices::due(created, Some(ends), soon), None);
    assert_eq!(
        notices::due(created, None, ends + notices::NOTICE_LEAD_SECS - 1),
        Some(notices::TrialNotice::Ended)
    );
    assert_eq!(
        notices::due(created, None, ends + notices::NOTICE_LEAD_SECS),
        None
    );
    let mail = CapturedMail::default();
    let url = billing_page(&rt, &org);
    assert!(sent(&mail).is_empty());
    notices::deliver_at(&rt, &mail, &org_id, soon - 1)
        .await
        .unwrap();
    assert!(sent(&mail).is_empty());
    notices::deliver_at(&rt, &mail, &org_id, soon)
        .await
        .unwrap();
    let soon_mail = sent(&mail);
    let soon_body = notices::ends_soon_body("Window", ends, &url);
    assert_eq!(soon_mail.len(), 1, "{soon_mail:?}");
    assert_eq!(soon_mail[0].0, "window-owner@example.test");
    assert_eq!(soon_mail[0].1, "Your PostDeploy trial ends in 3 days");
    assert_eq!(soon_mail[0].1, notices::ends_soon_subject());
    assert_eq!(soon_mail[0].2, soon_body);
    assert!(soon_body.contains(&billing::annual_price_label()));
    notices::deliver_at(&rt, &mail, &org_id, ends)
        .await
        .unwrap();
    let ended_mail = sent(&mail);
    let ended_body = notices::ended_body("Window", &url);
    assert_eq!(ended_mail.len(), 1, "{ended_mail:?}");
    assert_eq!(ended_mail[0].1, "Your PostDeploy trial has ended");
    assert_eq!(ended_mail[0].2, ended_body);
    assert!(!ended_body.contains('$'));
    notices::deliver_at(&rt, &mail, &org_id, ends + 86_400)
        .await
        .unwrap();
    assert!(sent(&mail).is_empty());
    stop(boot, server).await;
    drop(env);
}

#[tokio::test]
async fn trial_that_ended_long_ago_gets_no_notice() {
    let (env, boot, base, server, rt) = trial_mailbox("trial-notice-old").await;
    let owner = Api::signup(&base, "old-owner@example.test").await;
    let (org, _, _) = owner.setup_source("Old").await;
    let created = 1_700_000_000;
    set_created(&rt, &org, created).await;
    let org_id: OrgId = org.parse().unwrap();
    let mail = CapturedMail::default();
    let long_after = created + billing::TRIAL_SECS + 30 * 86_400;
    notices::deliver_at(&rt, &mail, &org_id, long_after)
        .await
        .unwrap();
    assert!(sent(&mail).is_empty());
    stop(boot, server).await;
    drop(env);
}

#[tokio::test]
async fn trial_notice_is_sent_at_most_once() {
    let (env, boot, base, server, rt) = trial_mailbox("trial-notice-once").await;
    let owner = Api::signup(&base, "once-owner@example.test").await;
    let (org, _, _) = owner.setup_source("Once").await;
    let created = 1_700_000_000;
    set_created(&rt, &org, created).await;
    let org_id: OrgId = org.parse().unwrap();
    let soon = created + billing::TRIAL_SECS - notices::NOTICE_LEAD_SECS;
    let mail = CapturedMail::default();
    notices::deliver_at(&rt, &mail, &org_id, soon)
        .await
        .unwrap();
    notices::deliver_at(&rt, &mail, &org_id, soon + 30)
        .await
        .unwrap();
    let messages = sent(&mail);
    assert_eq!(messages.len(), 1, "{messages:?}");
    assert_eq!(messages[0].1, notices::ends_soon_subject());
    stop(boot, server).await;
    drop(env);
}

#[tokio::test]
async fn subscribed_orgs_receive_no_trial_notice() {
    let (env, boot, base, server, rt) = trial_mailbox("trial-notice-paid").await;
    let owner = Api::signup(&base, "paid-owner@example.test").await;
    let (org, _, _) = owner.setup_source("Paid").await;
    let created = 1_700_000_000;
    set_created(&rt, &org, created).await;
    let until = created + billing::TRIAL_SECS + 86_400;
    rt.control
        .execute_raw(sql(
            "INSERT INTO billing_accounts (org_id, stripe_customer_id, paid_until, synced_at)
             VALUES (?, ?, ?, ?)",
            vec![
                org.clone().into(),
                format!("cus_{org}").into(),
                until.into(),
                until.into(),
            ],
        ))
        .await
        .unwrap();
    let org_id: OrgId = org.parse().unwrap();
    let soon = created + billing::TRIAL_SECS - notices::NOTICE_LEAD_SECS;
    let mail = CapturedMail::default();
    notices::deliver_at(&rt, &mail, &org_id, soon)
        .await
        .unwrap();
    notices::deliver_at(&rt, &mail, &org_id, created + billing::TRIAL_SECS)
        .await
        .unwrap();
    assert!(sent(&mail).is_empty());
    stop(boot, server).await;
    drop(env);
}

#[tokio::test]
async fn trial_notices_go_to_owners_only() {
    let (env, boot, base, server, rt) = trial_mailbox("trial-notice-owners").await;
    let owner = Api::signup(&base, "owners-owner@example.test").await;
    Api::signup(&base, "owners-admin@example.test").await;
    let (org, _, _) = owner.setup_source("Owners").await;
    let (status, _) = owner
        .post(
            &format!("/api/orgs/{org}/members"),
            json!({"email": "owners-admin@example.test", "role": "admin"}),
        )
        .await;
    assert_eq!(status, StatusCode::CREATED);
    let created = 1_700_000_000;
    set_created(&rt, &org, created).await;
    let org_id: OrgId = org.parse().unwrap();
    let soon = created + billing::TRIAL_SECS - notices::NOTICE_LEAD_SECS;
    let mail = CapturedMail::default();
    notices::deliver_at(&rt, &mail, &org_id, soon)
        .await
        .unwrap();
    let messages = sent(&mail);
    assert_eq!(messages.len(), 1, "{messages:?}");
    assert_eq!(messages[0].0, "owners-owner@example.test");
    stop(boot, server).await;
    drop(env);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn stripe_sync_never_moves_stored_paid_time_back() {
    let b = billed("billing-no-rewind", 10_000).await;
    let owner = Api::signup(&b.base, "rewind@example.test").await;
    let (org, ..) = owner.setup_source("Rewind").await;
    let (status, _) = owner
        .post(&format!("/api/orgs/{org}/billing/checkout"), json!({}))
        .await;
    assert_eq!(status, StatusCode::OK);
    let now = now_secs();
    b.fake.complete("cs_test_1", "cus_rewind", "sub_rewind");
    b.fake.invoice(
        "in_rewind",
        "cus_rewind",
        "sub_rewind",
        "paid",
        PRICE,
        1,
        "usd",
        now - 60,
        now - 60 + YEAR,
    );
    let completed = event(
        "evt_rewind",
        "checkout.session.completed",
        "checkout.session",
        "cs_test_1",
    );
    let (status, _) = webhook(&b.base, &completed).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        entitlement(&owner, &org).await,
        json!({"state": "paid", "until": now - 60 + YEAR})
    );
    let later = now + 2 * YEAR;
    b.rt.control
        .execute_raw(sql(
            "UPDATE billing_accounts SET paid_until = ? WHERE org_id = ?",
            vec![later.into(), org.clone().into()],
        ))
        .await
        .unwrap();
    let (status, billing) = owner
        .post(&format!("/api/orgs/{org}/billing/refresh"), json!({}))
        .await;
    assert_eq!(status, StatusCode::OK, "{billing}");
    assert_eq!(
        billing["entitlement"],
        json!({"state": "paid", "until": later})
    );
}
