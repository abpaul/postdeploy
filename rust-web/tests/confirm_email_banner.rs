mod support;

use std::sync::{
    atomic::{AtomicUsize, Ordering},
    Arc,
};

use async_trait::async_trait;
use loco_rs::app::Hooks;
use postdeploy::{
    account_settings::{AccountMail, AccountMessage, MailFailure},
    runtime::{sql, Runtime},
    services::Services,
    testing::{serve, TestApp, TestEnv},
};
use reqwest::{header, StatusCode};
use sea_orm::ConnectionTrait;
use support::Api;

#[derive(Default)]
struct Inbox(AtomicUsize);

#[async_trait]
impl AccountMail for Inbox {
    fn configured(&self) -> bool {
        true
    }

    async fn send(&self, _: AccountMessage) -> Result<(), MailFailure> {
        self.0.fetch_add(1, Ordering::Relaxed);
        Ok(())
    }
}

async fn page(api: &Api, path: &str) -> String {
    let response = api
        .http
        .get(format!("{}{path}", api.base))
        .header("cookie", api.cookie.as_deref().unwrap())
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK, "{path}");
    response.text().await.unwrap()
}

#[tokio::test]
async fn confirm_email_banner_says_what_confirmation_is_for() {
    let env = TestEnv::new("confirm-email-banner");
    let boot = env.boot_memory(|_| {}).await.unwrap();
    let services = Services::get(&boot.app_context);
    let inbox = Arc::new(Inbox::default());
    boot.app_context.shared_store.insert(Arc::new(Services {
        billing: services.billing.clone(),
        turnstile: None,
        oauth: services.oauth.clone(),
        notifications: services.notifications.clone(),
        reports: services.reports.clone(),
        account_mail: inbox.clone(),
        backups: services.backups.clone(),
    }));
    let (base, server) = serve(&boot).await;
    let api = Api::signup(&base, "banner@example.invalid").await;
    let html = page(&api, "/dashboard").await;
    assert!(html.contains("id=\"confirm-email-banner\""));
    assert!(html.contains("Confirm your email"));
    assert!(html.contains("Required to send or accept invitations."));
    assert!(html.contains("action=\"/dashboard/account/confirmation\""));
    assert!(html.contains("Send link"));
    assert!(!html.contains("activate your workspace"));

    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .unwrap();
    let resent = client
        .post(format!("{base}/dashboard/account/confirmation"))
        .header("cookie", api.cookie.as_deref().unwrap())
        .header("origin", "http://127.0.0.1:5167")
        .form(&[("_csrf_token", api.csrf.as_deref().unwrap())])
        .send()
        .await
        .unwrap();
    assert_eq!(resent.status(), StatusCode::SEE_OTHER);
    assert_eq!(resent.headers()[header::LOCATION], "/dashboard/account");
    assert_eq!(inbox.0.load(Ordering::Relaxed), 1);
    let flash = resent
        .headers()
        .get_all(header::SET_COOKIE)
        .iter()
        .filter_map(|value| value.to_str().ok())
        .find(|value| value.starts_with("pd_flash="))
        .unwrap()
        .split(';')
        .next()
        .unwrap();
    let account = client
        .get(format!("{base}/dashboard/account"))
        .header(
            header::COOKIE,
            format!("{}; {flash}", api.cookie.as_deref().unwrap()),
        )
        .send()
        .await
        .unwrap();
    assert_eq!(account.status(), StatusCode::OK);
    assert!(account
        .text()
        .await
        .unwrap()
        .contains("Confirmation link sent. Check your inbox."));

    let rt = Runtime::get(&boot.app_context);
    rt.control
        .execute_raw(sql(
            "UPDATE users SET confirmed_at = 1 WHERE email = ?",
            vec!["banner@example.invalid".into()],
        ))
        .await
        .unwrap();
    let confirmed = page(&api, "/dashboard").await;
    assert!(!confirmed.contains("id=\"confirm-email-banner\""));

    TestApp::on_shutdown(&boot.app_context).await;
    server.abort();
    let _ = server.await;
    drop(boot);
    drop(env);
}
