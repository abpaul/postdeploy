mod support;

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use loco_rs::{app::Hooks, boot::BootResult};
use postdeploy::{
    agent_access::{AuthorizeRequest, ClientRegistration, TokenForm},
    domain::{now_secs, OrgId, UserId},
    runtime::{sql, Runtime},
    services::Services,
    testing::{serve, TestApp, TestEnv},
};
use reqwest::StatusCode;
use sea_orm::ConnectionTrait;
use serde_json::json;
use sha2::{Digest, Sha256};
use support::Api;

fn shown_time(secs: i64) -> String {
    chrono::DateTime::from_timestamp(secs, 0)
        .unwrap()
        .format("%Y-%m-%d %H:%M UTC")
        .to_string()
}

fn row(html: &str, id: &str) -> String {
    let marker = format!("id=\"{id}\"");
    let start = html
        .find(&marker)
        .unwrap_or_else(|| panic!("missing {marker}"));
    let end = html[start..]
        .find("</tr>")
        .unwrap_or_else(|| panic!("missing row end for {id}"))
        + start;
    html[start..end].to_owned()
}

async fn settings(api: &Api, org: &str) -> String {
    let response = api
        .http
        .get(format!("{}/dashboard/orgs/{org}/settings", api.base))
        .header("cookie", api.cookie.as_deref().unwrap())
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    response.text().await.unwrap()
}

async fn projects(base: &str, org: &str, token: &str) -> StatusCode {
    reqwest::Client::new()
        .get(format!("{base}/api/orgs/{org}/projects"))
        .bearer_auth(token)
        .send()
        .await
        .unwrap()
        .status()
}

async fn stored(rt: &std::sync::Arc<Runtime>, table: &str, id: i64) -> Option<i64> {
    let query = match table {
        "oauth_grants" => "SELECT last_used_at FROM oauth_grants WHERE id = ?",
        "agent_api_keys" => "SELECT last_used_at FROM agent_api_keys WHERE id = ?",
        other => panic!("unexpected table {other}"),
    };
    rt.control
        .query_one_raw(sql(query, vec![id.into()]))
        .await
        .unwrap()
        .unwrap()
        .try_get_by_index(0)
        .unwrap()
}

async fn set_stored(rt: &std::sync::Arc<Runtime>, table: &str, id: i64, at: i64) {
    let query = match table {
        "oauth_grants" => "UPDATE oauth_grants SET last_used_at = ? WHERE id = ?",
        "agent_api_keys" => "UPDATE agent_api_keys SET last_used_at = ? WHERE id = ?",
        other => panic!("unexpected table {other}"),
    };
    rt.control
        .execute_raw(sql(query, vec![at.into(), id.into()]))
        .await
        .unwrap();
}

struct Live {
    env: TestEnv,
    boot: BootResult,
    base: String,
    server: tokio::task::JoinHandle<()>,
    api: Api,
    org: String,
    grant_id: i64,
    key_id: i64,
    access_token: String,
    api_secret: String,
}

impl Live {
    async fn stop(self) {
        TestApp::on_shutdown(&self.boot.app_context).await;
        self.server.abort();
        let _ = self.server.await;
        drop(self.boot);
        drop(self.env);
    }
}

async fn live(name: &str) -> Live {
    let env = TestEnv::new(name);
    let boot = env.boot_memory(|_| {}).await.unwrap();
    let (base, server) = serve(&boot).await;
    let api = Api::signup(&base, &format!("{name}@example.invalid")).await;
    let (org, _, _) = api.setup_source("Last use").await;
    let (_, session) = api.get("/api/auth/session").await;
    let user = UserId(session["user"]["id"].as_i64().unwrap());
    let org_id: OrgId = org.parse().unwrap();
    let oauth = &Services::get(&boot.app_context).oauth;
    let redirect = "http://127.0.0.1:9/callback";
    let client = oauth
        .register_client(ClientRegistration {
            redirect_uris: vec![redirect.into()],
            client_name: Some("Laptop".into()),
            scope: Some("projects:read".into()),
            ..ClientRegistration::default()
        })
        .await
        .unwrap();
    let verifier = "a".repeat(43);
    let resource = Runtime::get(&boot.app_context)
        .settings
        .oauth
        .resource
        .clone();
    let postdeploy::agent_access::Consent::Ready(prompt) = oauth
        .begin_consent(
            user,
            AuthorizeRequest {
                response_type: Some("code".into()),
                client_id: Some(client.client_id.as_str().into()),
                redirect_uri: Some(redirect.into()),
                code_challenge: Some(URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()))),
                code_challenge_method: Some("S256".into()),
                scope: Some("projects:read".into()),
                state: Some("last-used".into()),
                resource: Some(resource.clone()),
            },
        )
        .await
        .unwrap()
    else {
        panic!("the user belongs to an organization");
    };
    let redirect_url = oauth
        .approve_consent(
            user,
            prompt.handle.expose(),
            &org_id,
            prompt.requested.clone(),
        )
        .await
        .unwrap();
    let url = url::Url::parse(&redirect_url).unwrap();
    let code = url
        .query_pairs()
        .find(|(key, _)| key == "code")
        .unwrap()
        .1
        .into_owned();
    let token = oauth
        .token(TokenForm {
            grant_type: Some("authorization_code".into()),
            client_id: Some(client.client_id.as_str().into()),
            code: Some(code.into()),
            redirect_uri: Some(redirect.into()),
            code_verifier: Some(verifier.into()),
            resource: Some(resource),
            ..TokenForm::default()
        })
        .await
        .unwrap();
    let rt = Runtime::get(&boot.app_context);
    let grant_id = rt
        .control
        .query_one_raw(sql(
            "SELECT id FROM oauth_grants WHERE org_id = ? AND revoked_at IS NULL",
            vec![org.clone().into()],
        ))
        .await
        .unwrap()
        .unwrap()
        .try_get_by_index::<i64>(0)
        .unwrap();
    let (status, created) = api
        .post(&format!("/api/orgs/{org}/api-keys"), json!({"name": "CI"}))
        .await;
    assert_eq!(status, StatusCode::CREATED, "{created}");
    Live {
        env,
        boot,
        base,
        server,
        api,
        org,
        grant_id,
        key_id: created["key"]["id"].as_i64().unwrap(),
        access_token: token.access_token.expose().to_owned(),
        api_secret: created["secret"].as_str().unwrap().to_owned(),
    }
}

async fn use_both(live: &Live) {
    assert_eq!(
        projects(&live.base, &live.org, &live.access_token).await,
        StatusCode::OK
    );
    assert_eq!(
        projects(&live.base, &live.org, &live.api_secret).await,
        StatusCode::OK
    );
}

#[tokio::test]
async fn settings_record_last_use_for_oauth_grants_and_api_keys() {
    let live = live("agent-last-used").await;
    let before = settings(&live.api, &live.org).await;
    assert!(!before.contains("Not recorded"));
    assert!(!before.contains("Not used yet"));
    let grant = row(&before, &format!("grant-{}", live.grant_id));
    let key = row(&before, &format!("api-key-{}", live.key_id));
    assert!(grant.contains("Laptop"), "{grant}");
    assert!(grant.contains("Never"), "{grant}");
    assert!(key.contains("Never"), "{key}");

    use_both(&live).await;
    let rt = Runtime::get(&live.boot.app_context);
    let grant_at = stored(&rt, "oauth_grants", live.grant_id).await.unwrap();
    let key_at = stored(&rt, "agent_api_keys", live.key_id).await.unwrap();
    let now = now_secs();
    assert!(
        (now - grant_at).abs() <= 5,
        "grant stamp {grant_at} now {now}"
    );
    assert!((now - key_at).abs() <= 5, "key stamp {key_at} now {now}");

    let after = settings(&live.api, &live.org).await;
    let grant = row(&after, &format!("grant-{}", live.grant_id));
    let key = row(&after, &format!("api-key-{}", live.key_id));
    let grant_text = shown_time(grant_at);
    let key_text = shown_time(key_at);
    assert!(grant.contains(&grant_text), "{grant} expected {grant_text}");
    assert!(key.contains(&key_text), "{key} expected {key_text}");
    assert!(!grant.contains("Never"), "{grant}");
    assert!(!key.contains("Never"), "{key}");
    live.stop().await;
}

#[tokio::test]
async fn last_use_updates_only_when_the_stored_time_is_older_than_60_seconds() {
    let live = live("agent-last-used-throttle").await;
    for (table, id) in [
        ("oauth_grants", live.grant_id),
        ("agent_api_keys", live.key_id),
    ] {
        let recent = now_secs() - 30;
        {
            let rt = Runtime::get(&live.boot.app_context);
            set_stored(&rt, table, id, recent).await;
        }
        use_both(&live).await;
        {
            let rt = Runtime::get(&live.boot.app_context);
            assert_eq!(stored(&rt, table, id).await, Some(recent), "{table}");
        }

        let stale = now_secs() - 61;
        {
            let rt = Runtime::get(&live.boot.app_context);
            set_stored(&rt, table, id, stale).await;
        }
        use_both(&live).await;
        let fresh = {
            let rt = Runtime::get(&live.boot.app_context);
            stored(&rt, table, id).await.unwrap()
        };
        assert_ne!(fresh, stale, "{table}");
        assert!(fresh >= stale + 61, "{table} stored {fresh} after {stale}");
    }
    live.stop().await;
}
