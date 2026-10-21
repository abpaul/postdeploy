use std::sync::{
    atomic::{AtomicUsize, Ordering},
    Arc, Mutex,
};

use async_trait::async_trait;
use loco_rs::app::Hooks;
use postdeploy::{
    account_settings::{self, AccountMail, AccountMessage, AccountToken, MailFailure},
    error::ApiError,
    identity::accounts,
    password_policy::{BreachChecker, BreachUnavailable, PasswordPolicy},
    runtime::Runtime,
    testing::{serve, TestApp, TestEnv},
};
use reqwest::StatusCode;
use serde_json::json;

struct Checker {
    result: Result<bool, BreachUnavailable>,
    calls: AtomicUsize,
}

#[derive(Default)]
struct Inbox(Mutex<Option<String>>);

#[async_trait]
impl AccountMail for Inbox {
    fn configured(&self) -> bool {
        true
    }

    async fn send(&self, message: AccountMessage) -> Result<(), MailFailure> {
        let text = message.text();
        let token = text
            .split_once("?token=")
            .unwrap()
            .1
            .chars()
            .take_while(|character| {
                character.is_ascii_alphanumeric() || *character == '-' || *character == '_'
            })
            .collect();
        *self.0.lock().unwrap() = Some(token);
        Ok(())
    }
}

#[async_trait]
impl BreachChecker for Checker {
    async fn pwned(&self, prefix: &str, suffix: &str) -> Result<bool, BreachUnavailable> {
        assert_eq!(prefix.len(), 5);
        assert_eq!(suffix.len(), 35);
        assert!(prefix
            .bytes()
            .chain(suffix.bytes())
            .all(|byte| byte.is_ascii_hexdigit()));
        self.calls.fetch_add(1, Ordering::Relaxed);
        self.result
    }
}

#[tokio::test]
async fn source_denylist_is_case_insensitive_and_checked_before_breach_network() {
    let checker = Arc::new(Checker {
        result: Ok(false),
        calls: AtomicUsize::new(0),
    });
    let policy = PasswordPolicy::with_checker(checker.clone());
    for password in [
        "password1234",
        "123456789012",
        "qwertyuiop123",
        "qwertyuiop1234",
        "admin12345678",
        "letmein12345",
        "welcome12345",
        "iloveyou12345",
        "monkey1234567",
        "dragon12345678",
        "sunshine12345",
        "princess12345",
        "football12345",
        "baseball12345",
        "trustno112345",
        "changeme12345",
        "whatever12345",
        "superman12345",
    ] {
        for password in [password.to_owned(), password.to_uppercase()] {
            assert!(matches!(
                policy.validate(&password).await,
                Err(ApiError::BadRequest("password_common"))
            ));
        }
    }
    for password in ["password", "password123", "12345678901"] {
        assert!(matches!(
            policy.validate(password).await,
            Err(ApiError::BadRequest("password_length"))
        ));
    }
    assert!(matches!(
        policy.validate(&"x".repeat(257)).await,
        Err(ApiError::BadRequest("password_length"))
    ));
    assert_eq!(checker.calls.load(Ordering::Relaxed), 0);
    assert!(matches!(
        policy.validate("monKey1234567").await,
        Err(ApiError::BadRequest("password_common"))
    ));
    assert_eq!(checker.calls.load(Ordering::Relaxed), 0);
    assert!(matches!(
        policy.validate(&"a\u{301}".repeat(6)).await,
        Err(ApiError::BadRequest("password_length"))
    ));
    assert_eq!(checker.calls.load(Ordering::Relaxed), 0);
    assert!(policy.validate("isolated clean fixture").await.is_ok());
    assert_eq!(checker.calls.load(Ordering::Relaxed), 1);
}

#[tokio::test]
async fn breached_passwords_and_breach_outages_fail_closed() {
    let breached = PasswordPolicy::with_checker(Arc::new(Checker {
        result: Ok(true),
        calls: AtomicUsize::new(0),
    }));
    assert!(matches!(
        breached.validate("isolated breached fixture").await,
        Err(ApiError::BadRequest("password_breached"))
    ));
    let unavailable = PasswordPolicy::with_checker(Arc::new(Checker {
        result: Err(BreachUnavailable),
        calls: AtomicUsize::new(0),
    }));
    assert!(matches!(
        unavailable.validate("isolated outage fixture").await,
        Err(ApiError::Unavailable("password_check_unavailable"))
    ));
}

#[tokio::test]
async fn http_signup_rejects_common_password_before_creating_account() {
    let env = TestEnv::new("password-policy-http");
    let boot = env.boot_memory(|_| {}).await.unwrap();
    let (base, server) = serve(&boot).await;
    let client = reqwest::Client::new();
    let rejected = client
        .post(format!("{base}/api/auth/signup"))
        .json(&json!({"email":"password-policy@example.invalid", "password":"Password1234"}))
        .send()
        .await
        .unwrap();
    assert_eq!(rejected.status(), StatusCode::BAD_REQUEST);
    assert_eq!(
        rejected.json::<serde_json::Value>().await.unwrap(),
        json!({"error":"password_common"})
    );
    let accepted = client.post(format!("{base}/api/auth/signup"))
        .json(&json!({"email":"password-policy@example.invalid", "password":"isolated clean fixture"}))
        .send().await.unwrap();
    assert_eq!(accepted.status(), StatusCode::CREATED);
    server.abort();
    TestApp::on_shutdown(&boot.app_context).await;
}

#[tokio::test]
async fn rejected_reset_preserves_the_link_and_existing_password() {
    let env = TestEnv::new("password-policy-reset");
    let boot = env.boot_memory(|_| {}).await.unwrap();
    let rt = Runtime::get(&boot.app_context);
    accounts::signup(
        &rt,
        "reset-policy@example.invalid",
        "original isolated fixture",
    )
    .await
    .unwrap();
    let inbox = Inbox::default();
    account_settings::request_password_reset(&rt, &inbox, "reset-policy@example.invalid")
        .await
        .unwrap();
    let plain_token = zeroize::Zeroizing::new(inbox.0.lock().unwrap().take().unwrap());
    let token: AccountToken = serde_json::from_value(json!(plain_token.as_str())).unwrap();
    let weak = serde_json::from_value(json!("Password1234")).unwrap();
    assert!(matches!(
        account_settings::reset_password(&rt, &token, &weak).await,
        Err(ApiError::BadRequest("password_common"))
    ));
    assert!(accounts::login(
        &rt,
        "reset-policy@example.invalid",
        "original isolated fixture"
    )
    .await
    .is_ok());
    let replacement = serde_json::from_value(json!("replacement isolated fixture")).unwrap();
    account_settings::reset_password(&rt, &token, &replacement)
        .await
        .unwrap();
    assert!(matches!(
        accounts::login(
            &rt,
            "reset-policy@example.invalid",
            "original isolated fixture"
        )
        .await,
        Err(ApiError::Unauthorized)
    ));
    assert!(accounts::login(
        &rt,
        "reset-policy@example.invalid",
        "replacement isolated fixture"
    )
    .await
    .is_ok());
    TestApp::on_shutdown(&boot.app_context).await;
}

#[tokio::test]
#[ignore = "calls the official HIBP range API over HTTPS"]
async fn real_hibp_accepts_a_random_isolated_test_password() {
    let password = zeroize::Zeroizing::new(format!(
        "postdeploy-{}-{}",
        uuid::Uuid::new_v4(),
        uuid::Uuid::new_v4()
    ));
    assert!(PasswordPolicy::new()
        .unwrap()
        .validate(&password)
        .await
        .is_ok());
}
