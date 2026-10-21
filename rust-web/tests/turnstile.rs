use std::sync::Arc;

use loco_rs::{
    app::{AppContext, Hooks},
    boot::BootResult,
};
use postdeploy::{
    credentials::TurnstileCredentials,
    services::Services,
    testing::{serve, TestApp, TestEnv},
    turnstile::Turnstile,
};
use reqwest::{header, Client, StatusCode};
use serde_json::json;

const SITE_KEY: &str = "1x00000000000000000000AA";
const PASS_SECRET: &str = "1x0000000000000000000000000000000AA";
const FAIL_SECRET: &str = "2x0000000000000000000000000000000AA";
const DUMMY_TOKEN: &str = "XXXX.DUMMY.TOKEN.XXXX";

fn credentials(secret: &str) -> TurnstileCredentials {
    serde_json::from_value(json!({"site_key": SITE_KEY, "secret_key": secret})).unwrap()
}

fn install(ctx: &AppContext, secret: &str) {
    let services = Services::get(ctx);
    ctx.shared_store.insert(Arc::new(Services {
        billing: services.billing.clone(),
        turnstile: Some(Turnstile::new(&credentials(secret)).unwrap()),
        oauth: services.oauth.clone(),
        notifications: services.notifications.clone(),
        reports: services.reports.clone(),
        account_mail: services.account_mail.clone(),
        backups: services.backups.clone(),
    }));
}

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

#[tokio::test]
async fn configured_browser_and_json_auth_reject_missing_and_oversized_tokens() {
    let env = TestEnv::new("turnstile-auth-boundary");
    let boot = env.boot_memory(|_| {}).await.unwrap();
    install(&boot.app_context, PASS_SECRET);
    let (base, server) = serve(&boot).await;
    let client = http();
    for path in ["/sign-in", "/register", "/reset"] {
        let response = client.get(format!("{base}{path}")).send().await.unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let cookie = response
            .headers()
            .get_all(header::SET_COOKIE)
            .iter()
            .filter_map(|value| value.to_str().ok())
            .find(|value| value.starts_with("pd_preauth="))
            .unwrap()
            .split(';')
            .next()
            .unwrap()
            .to_owned();
        let body = response.text().await.unwrap();
        assert!(body.contains(&format!("data-sitekey=\"{SITE_KEY}\"")));
        assert!(body.contains("https://challenges.cloudflare.com/turnstile/v0/api.js"));
        assert!(!body.contains(PASS_SECRET));
        let csrf = body
            .split_once("name=\"_csrf_token\" value=\"")
            .unwrap()
            .1
            .split('"')
            .next()
            .unwrap();
        if path == "/sign-in" {
            assert!(body.contains("novalidate"));
            let empty = client
                .post(format!("{base}{path}"))
                .header(header::ORIGIN, "http://127.0.0.1:5167")
                .header(header::COOKIE, &cookie)
                .form(&[("_csrf_token", csrf), ("email", ""), ("password", "")])
                .send()
                .await
                .unwrap();
            assert_eq!(empty.status(), StatusCode::UNPROCESSABLE_ENTITY);
            let empty = empty.text().await.unwrap();
            assert!(empty.contains("id=\"email-error\" role=\"alert\""));
            assert!(empty.contains("id=\"password-error\" role=\"alert\""));
            assert_eq!(empty.matches(">is required</p>").count(), 2);
        }
        for token in ["".to_owned(), "x".repeat(2049)] {
            let mut fields = vec![
                ("_csrf_token", csrf),
                ("email", "turnstile@example.invalid"),
                ("password", "correct horse battery"),
                ("password_confirmation", "correct horse battery"),
            ];
            if !token.is_empty() {
                fields.push(("cf-turnstile-response", &token));
            }
            let response = client
                .post(format!("{base}{path}"))
                .header(header::ORIGIN, "http://127.0.0.1:5167")
                .header(header::COOKIE, &cookie)
                .form(&fields)
                .send()
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::SEE_OTHER);
            assert_eq!(response.headers()[header::LOCATION], path);
            assert!(!response.headers().contains_key("authorization"));
        }
    }
    for path in ["/api/auth/signup", "/api/auth/login"] {
        for token in ["".to_owned(), "x".repeat(2049)] {
            let mut fields =
                json!({"email": "turnstile@example.invalid", "password": "correct horse battery"});
            if !token.is_empty() {
                fields["cf_turnstile_response"] = json!(token);
            }
            let response = client
                .post(format!("{base}{path}"))
                .json(&fields)
                .send()
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::BAD_REQUEST);
            assert_eq!(
                response.json::<serde_json::Value>().await.unwrap(),
                json!({"error":"security_check_failed"})
            );
        }
    }
    stop(boot, server).await;
}

#[tokio::test]
#[ignore = "calls the official Cloudflare testing Siteverify API"]
async fn official_cloudflare_testing_api_accepts_dummy_and_rejects_failure_key() {
    let pass = Turnstile::new(&credentials(PASS_SECRET)).unwrap();
    assert!(pass.verify(DUMMY_TOKEN, None).await);
    let fail = Turnstile::new(&credentials(FAIL_SECRET)).unwrap();
    assert!(!fail.verify(DUMMY_TOKEN, None).await);
    assert!(!pass.verify("", None).await);
    let env = TestEnv::new("turnstile-official-api");
    let boot = env.boot_memory(|_| {}).await.unwrap();
    install(&boot.app_context, FAIL_SECRET);
    let (base, server) = serve(&boot).await;
    let client = http();
    let rejected = client.post(format!("{base}/api/auth/signup"))
        .json(&json!({"email":"official-turnstile@example.invalid", "password":"correct horse battery", "cf_turnstile_response":DUMMY_TOKEN}))
        .send().await.unwrap();
    assert_eq!(rejected.status(), StatusCode::BAD_REQUEST);
    assert_eq!(
        rejected.json::<serde_json::Value>().await.unwrap(),
        json!({"error":"security_check_failed"})
    );
    install(&boot.app_context, PASS_SECRET);
    let accepted = client.post(format!("{base}/api/auth/signup"))
        .json(&json!({"email":"official-turnstile@example.invalid", "password":"correct horse battery", "cf_turnstile_response":DUMMY_TOKEN}))
        .send().await.unwrap();
    assert_eq!(accepted.status(), StatusCode::CREATED);
    assert!(accepted.headers().contains_key(header::SET_COOKIE));
    stop(boot, server).await;
}
