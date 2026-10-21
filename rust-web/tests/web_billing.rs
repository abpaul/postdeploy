mod support;

use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};

use axum::{
    extract::{Path, State},
    http::StatusCode as AxumStatus,
    routing::{get, post},
    Form, Json, Router,
};
use loco_rs::{app::Hooks, boot::BootResult};
use postdeploy::testing::{serve, TestApp, TestEnv};
use reqwest::{header, Client, StatusCode};
use serde_json::{json, Value};
use support::Api;

const ORIGIN: &str = "http://127.0.0.1:5167";
const PRICE: &str = "price_annualfixture";

fn http() -> Client {
    Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .unwrap()
}

async fn stop(boot: BootResult, server: tokio::task::JoinHandle<()>) {
    server.abort();
    TestApp::on_shutdown(&boot.app_context).await;
}

async fn page(client: &Client, base: &str, path: &str, api: &Api) -> (StatusCode, String) {
    let response = client
        .get(format!("{base}{path}"))
        .header(header::COOKIE, api.cookie.as_deref().unwrap())
        .send()
        .await
        .unwrap();
    let status = response.status();
    assert_eq!(response.headers()[header::CACHE_CONTROL], "no-store");
    (status, response.text().await.unwrap())
}

fn form(client: &Client, base: &str, path: &str, api: &Api) -> reqwest::RequestBuilder {
    client
        .post(format!("{base}{path}"))
        .header(header::ORIGIN, ORIGIN)
        .header(header::COOKIE, api.cookie.as_deref().unwrap())
        .form(&[("_csrf_token", api.csrf.as_deref().unwrap())])
}

#[tokio::test]
async fn billing_page_shows_the_single_plan_usage_and_owner_only_actions() {
    let env = TestEnv::new("web-billing-page");
    let boot = env.boot_memory(|_| {}).await.unwrap();
    let (base, server) = serve(&boot).await;
    let client = http();
    let owner = Api::signup(&base, "billing-owner@example.test").await;
    let member = Api::signup(&base, "billing-member@example.test").await;
    let (status, created) = owner.post("/api/orgs", json!({"name": "Billing UI"})).await;
    assert_eq!(status, StatusCode::CREATED);
    let org = created["id"].as_str().unwrap();
    let (status, _) = owner
        .post(
            &format!("/api/orgs/{org}/members"),
            json!({"email": "billing-member@example.test", "role": "member"}),
        )
        .await;
    assert_eq!(status, StatusCode::CREATED);
    let path = format!("/dashboard/orgs/{org}/billing");

    let (status, owner_page) = page(&client, &base, &path, &owner).await;
    assert_eq!(status, StatusCode::OK);
    for expected in [
        "Trial active",
        "$449/year",
        "100 GB",
        "1,000,000",
        "90 days",
        "No card required",
        "Subscriptions are temporarily unavailable",
        "Usage alerts are sent at 70%, 90%, and 100%",
    ] {
        assert!(owner_page.contains(expected), "missing {expected}");
    }
    assert!(owner_page.contains("aria-valuemax=\"1000000\""));
    assert!(owner_page.contains("aria-valuemax=\"100000000000\""));
    assert!(!owner_page.contains("$29"));
    assert!(!owner_page.contains("billing-checkout"));

    let (status, member_page) = page(&client, &base, &path, &member).await;
    assert_eq!(status, StatusCode::OK);
    assert!(member_page.contains("Only the organization owner can subscribe"));
    assert!(!member_page.contains("action=\"/dashboard/orgs/"));

    let settings = format!("/dashboard/orgs/{org}/settings");
    let (status, settings_page) = page(&client, &base, &settings, &owner).await;
    assert_eq!(status, StatusCode::OK);
    assert!(settings_page.contains(&format!("href=\"{path}\"")));
    stop(boot, server).await;
}

#[derive(Clone, Default)]
struct FakeStripe {
    sessions: Arc<Mutex<Vec<HashMap<String, String>>>>,
}

async fn price(Path(id): Path<String>) -> (AxumStatus, Json<Value>) {
    (
        AxumStatus::OK,
        Json(json!({
            "id": id,
            "object": "price",
            "active": true,
            "currency": "usd",
            "unit_amount": 44_900,
            "type": "recurring",
            "recurring": {"interval": "year", "interval_count": 1}
        })),
    )
}

async fn checkout(
    State(fake): State<FakeStripe>,
    Form(form): Form<HashMap<String, String>>,
) -> Json<Value> {
    fake.sessions.lock().unwrap().push(form.clone());
    Json(json!({
        "id": "cs_test_billing_ui",
        "object": "checkout.session",
        "mode": "subscription",
        "status": "open",
        "url": "https://checkout.stripe.test/cs_test_billing_ui",
        "client_reference_id": form.get("client_reference_id"),
        "customer": null,
        "subscription": null,
        "expires_at": chrono::Utc::now().timestamp() + 86_400
    }))
}

async fn fake_stripe() -> (FakeStripe, String) {
    let fake = FakeStripe::default();
    let router = Router::new()
        .route("/v1/prices/{id}", get(price))
        .route("/v1/checkout/sessions", post(checkout))
        .with_state(fake.clone());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    tokio::spawn(async move {
        let _ = axum::serve(listener, router).await;
    });
    (fake, base)
}

#[tokio::test]
async fn checkout_requires_owner_csrf_and_redirects_to_the_validated_provider_url() {
    let env = TestEnv::new("web-billing-checkout");
    let (fake, stripe) = fake_stripe().await;
    env.with_stripe(json!({
        "secret_key": "sk_test_billing_ui_fixture",
        "webhook_secret": "whsec_billing_ui_fixture",
        "price_id": PRICE
    }));
    let boot = env
        .boot_memory(|settings| settings["billing"]["api_base"] = json!(stripe))
        .await
        .unwrap();
    let (base, server) = serve(&boot).await;
    let client = http();
    let owner = Api::signup(&base, "checkout-owner@example.test").await;
    let member = Api::signup(&base, "checkout-member@example.test").await;
    let (status, created) = owner
        .post("/api/orgs", json!({"name": "Checkout UI"}))
        .await;
    assert_eq!(status, StatusCode::CREATED);
    let org = created["id"].as_str().unwrap();
    let (status, _) = owner
        .post(
            &format!("/api/orgs/{org}/members"),
            json!({"email": "checkout-member@example.test", "role": "member"}),
        )
        .await;
    assert_eq!(status, StatusCode::CREATED);
    let path = format!("/dashboard/orgs/{org}/billing");
    let action = format!("{path}/checkout");

    let (status, owner_page) = page(&client, &base, &path, &owner).await;
    assert_eq!(status, StatusCode::OK);
    assert!(owner_page.contains(&format!("action=\"{action}\"")));
    assert!(owner_page.contains("Checkout starts the paid annual term today."));

    let missing_csrf = client
        .post(format!("{base}{action}"))
        .header(header::ORIGIN, ORIGIN)
        .header(header::COOKIE, owner.cookie.as_deref().unwrap())
        .send()
        .await
        .unwrap();
    assert_eq!(missing_csrf.status(), StatusCode::FORBIDDEN);

    let forbidden = form(&client, &base, &action, &member).send().await.unwrap();
    assert_eq!(forbidden.status(), StatusCode::FORBIDDEN);
    assert!(fake.sessions.lock().unwrap().is_empty());

    let response = form(&client, &base, &action, &owner).send().await.unwrap();
    assert_eq!(response.status(), StatusCode::SEE_OTHER);
    assert_eq!(
        response.headers()[header::LOCATION],
        "https://checkout.stripe.test/cs_test_billing_ui"
    );
    assert_eq!(response.headers()[header::CACHE_CONTROL], "no-store");
    {
        let sessions = fake.sessions.lock().unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0]["line_items[0][price]"], PRICE);
        assert_eq!(sessions[0]["line_items[0][quantity]"], "1");
        assert_eq!(sessions[0]["mode"], "subscription");
    }
    stop(boot, server).await;
}
