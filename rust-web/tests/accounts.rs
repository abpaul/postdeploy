use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use credseal::SecretString;
use loco_rs::{app::Hooks, boot::BootResult};
use postdeploy::{
    account_settings::{self as accounts, AccountMail, AccountMessage, AccountToken, MailFailure},
    domain::{OrgId, Role, UserId},
    error::ApiError,
    identity::{
        access::{authorize, OrgAccess, Session},
        accounts as core, orgs,
    },
    runtime::{sql, Runtime},
    testing::{serve, TestApp, TestEnv},
};
use sea_orm::ConnectionTrait;
use serde_json::json;
use sha2::{Digest, Sha256};

const PASSWORD: &str = "correct horse battery";
const ORIGIN: &str = "https://accounts.example.test";

/// Local mail receiver. Holds messages in memory, as the SMTP transport would
/// deliver them, so tests read the link the user would click.
struct Inbox {
    configured: bool,
    failure: Option<MailFailure>,
    messages: Mutex<Vec<(String, String, String)>>,
}

impl Inbox {
    fn new() -> Self {
        Self {
            configured: true,
            failure: None,
            messages: Mutex::default(),
        }
    }

    fn count(&self) -> usize {
        self.messages.lock().unwrap().len()
    }

    /// Recipient and plaintext token of the latest message.
    fn last(&self, path: &str) -> (String, String) {
        let messages = self.messages.lock().unwrap();
        let (to, _, text) = messages.last().expect("a message was delivered");
        let prefix = format!("{ORIGIN}{path}?token=");
        let start = text
            .find(&prefix)
            .expect("link uses the configured origin and path")
            + prefix.len();
        let token: String = text[start..]
            .chars()
            .take_while(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_')
            .collect();
        assert_eq!(token.len(), 43, "256-bit URL-safe token");
        (to.clone(), token)
    }
}

#[async_trait]
impl AccountMail for Inbox {
    fn configured(&self) -> bool {
        self.configured
    }

    async fn send(&self, message: AccountMessage) -> Result<(), MailFailure> {
        if let Some(failure) = self.failure {
            return Err(failure);
        }
        self.messages.lock().unwrap().push((
            message.to.clone(),
            message.subject.clone(),
            message.text().to_owned(),
        ));
        Ok(())
    }
}

fn token(value: &str) -> AccountToken {
    serde_json::from_value(json!(value)).unwrap()
}

fn secret(value: &str) -> SecretString {
    serde_json::from_value(json!(value)).unwrap()
}

struct User {
    session: Session,
    cookie: String,
}

async fn signup(rt: &Runtime, email: &str) -> User {
    let grant = core::signup(rt, email, PASSWORD).await.expect("signup");
    let session = Session {
        id: 0,
        user: grant.user.id,
        email: grant.user.email.clone(),
        csrf_token: grant.csrf_token,
    };
    User {
        session,
        cookie: format!("pd_session={}", grant.token),
    }
}

async fn boot(name: &str) -> (TestEnv, BootResult, Arc<Runtime>) {
    let env = TestEnv::new(name);
    let boot = env
        .boot_memory(|s| s["auth"]["origin"] = json!(ORIGIN))
        .await
        .expect("boot");
    let rt = Runtime::get(&boot.app_context);
    (env, boot, rt)
}

async fn shutdown(boot: &BootResult) {
    TestApp::on_shutdown(&boot.app_context).await;
}

async fn scalar(rt: &Runtime, query: &str, values: Vec<sea_orm::Value>) -> i64 {
    rt.control
        .query_one_raw(sql(query, values))
        .await
        .unwrap()
        .unwrap()
        .try_get_by_index(0)
        .unwrap()
}

/// True when the token text appears anywhere in the control database files.
fn stored_in_files(env: &TestEnv, plaintext: &str) -> bool {
    ["control.sqlite", "control.sqlite-wal"].iter().any(|name| {
        std::fs::read(env.dir.join(name))
            .map(|bytes| {
                bytes
                    .windows(plaintext.len())
                    .any(|w| w == plaintext.as_bytes())
            })
            .unwrap_or(false)
    })
}

#[tokio::test]
async fn account_confirmation_is_hashed_bound_single_use_and_expiring() {
    let (env, boot, rt) = boot("confirm").await;
    let inbox = Inbox::new();
    let alice = signup(&rt, "alice@example.test").await;
    let mallory = signup(&rt, "mallory@example.test").await;

    let fresh = accounts::account(&rt, &alice.session).await.unwrap();
    assert!(!fresh.confirmed, "fresh account is unconfirmed");
    assert_eq!(fresh.name, None);

    accounts::send_account_confirmation(&rt, &inbox, &alice.session)
        .await
        .unwrap();
    let (to, plain) = inbox.last(accounts::CONFIRM_ACCOUNT_PATH);
    assert_eq!(to, "alice@example.test");
    let hashes = scalar(
        &rt,
        "SELECT COUNT(*) FROM account_tokens WHERE token_hash = ?",
        vec![Sha256::digest(plain.as_bytes()).to_vec().into()],
    )
    .await;
    assert_eq!(hashes, 1, "only the SHA-256 hash is stored");
    assert!(
        !stored_in_files(&env, &plain),
        "plaintext token is absent from database files"
    );
    assert_eq!(format!("{:?}", token(&plain)), "AccountToken([REDACTED])");

    let resend = accounts::send_account_confirmation(&rt, &inbox, &alice.session).await;
    assert!(
        matches!(resend, Err(ApiError::Conflict("email_recently_sent"))),
        "resend is throttled"
    );

    let cross = accounts::confirm_account(&rt, &mallory.session, &token(&plain)).await;
    assert!(
        matches!(cross, Err(ApiError::NotFound)),
        "another account cannot use the link"
    );
    let done = accounts::confirm_account(&rt, &alice.session, &token(&plain))
        .await
        .unwrap();
    assert!(
        done.confirmed,
        "owner confirms after a rejected cross-account attempt"
    );
    let replay = accounts::confirm_account(&rt, &alice.session, &token(&plain)).await;
    assert!(
        matches!(replay, Err(ApiError::NotFound)),
        "link is single use"
    );
    let again = accounts::send_account_confirmation(&rt, &inbox, &alice.session).await;
    assert!(matches!(
        again,
        Err(ApiError::Conflict("already_confirmed"))
    ));

    accounts::send_account_confirmation(&rt, &inbox, &mallory.session)
        .await
        .unwrap();
    let (_, stale) = inbox.last(accounts::CONFIRM_ACCOUNT_PATH);
    rt.control
        .execute_raw(sql(
            "UPDATE account_tokens SET expires_at = 0 WHERE user_id = ?",
            vec![mallory.session.user.0.into()],
        ))
        .await
        .unwrap();
    let expired = accounts::confirm_account(&rt, &mallory.session, &token(&stale)).await;
    assert!(
        matches!(expired, Err(ApiError::NotFound)),
        "expired link is rejected"
    );
    assert!(
        !accounts::account(&rt, &mallory.session)
            .await
            .unwrap()
            .confirmed
    );

    let named = accounts::update_name(&rt, &alice.session, "  Alice Liddell ")
        .await
        .unwrap();
    assert_eq!(named.name.as_deref(), Some("Alice Liddell"));
    let bad = accounts::update_name(&rt, &alice.session, "a\u{7}b").await;
    assert!(matches!(bad, Err(ApiError::BadRequest("invalid_name"))));
    let cleared = accounts::update_name(&rt, &alice.session, "  ")
        .await
        .unwrap();
    assert_eq!(cleared.name, None);
    shutdown(&boot).await;
}

#[tokio::test]
async fn email_change_keeps_old_address_until_confirmed() {
    let (_env, boot, rt) = boot("email-change").await;
    let inbox = Inbox::new();
    let alice = signup(&rt, "alice@example.test").await;
    let bob = signup(&rt, "bob@example.test").await;

    let taken =
        accounts::request_email_change(&rt, &inbox, &alice.session, "BOB@example.test").await;
    assert!(matches!(taken, Err(ApiError::Conflict("email_taken"))));
    let same =
        accounts::request_email_change(&rt, &inbox, &alice.session, "alice@example.test").await;
    assert!(matches!(same, Err(ApiError::BadRequest("email_unchanged"))));

    accounts::request_email_change(&rt, &inbox, &alice.session, "Alice.New@Example.test")
        .await
        .unwrap();
    let (to, plain) = inbox.last(accounts::CONFIRM_EMAIL_PATH);
    assert_eq!(to, "alice.new@example.test", "link goes to the new address");
    let pending = accounts::account(&rt, &alice.session).await.unwrap();
    assert_eq!(pending.email, "alice@example.test");
    assert_eq!(
        pending.pending_email.as_deref(),
        Some("alice.new@example.test")
    );
    assert!(
        core::login(&rt, "alice@example.test", PASSWORD)
            .await
            .is_ok(),
        "old address signs in before confirmation"
    );

    let cross = accounts::confirm_email_change(&rt, &bob.session, &token(&plain)).await;
    assert!(
        matches!(cross, Err(ApiError::NotFound)),
        "another account cannot use the link"
    );
    let changed = accounts::confirm_email_change(&rt, &alice.session, &token(&plain))
        .await
        .unwrap();
    assert_eq!(changed.email, "alice.new@example.test");
    assert!(changed.confirmed, "new address is confirmed by the link");
    assert_eq!(changed.pending_email, None);
    assert!(core::login(&rt, "alice.new@example.test", PASSWORD)
        .await
        .is_ok());
    assert!(
        core::login(&rt, "alice@example.test", PASSWORD)
            .await
            .is_err(),
        "old address no longer signs in"
    );
    let replay = accounts::confirm_email_change(&rt, &alice.session, &token(&plain)).await;
    assert!(matches!(replay, Err(ApiError::NotFound)));

    accounts::request_email_change(&rt, &inbox, &bob.session, "carol@example.test")
        .await
        .unwrap();
    let (_, bobs) = inbox.last(accounts::CONFIRM_EMAIL_PATH);
    signup(&rt, "carol@example.test").await;
    let raced = accounts::confirm_email_change(&rt, &bob.session, &token(&bobs)).await;
    assert!(
        matches!(raced, Err(ApiError::Conflict("email_taken"))),
        "address claimed before confirmation"
    );
    assert_eq!(
        accounts::account(&rt, &bob.session).await.unwrap().email,
        "bob@example.test"
    );
    shutdown(&boot).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn password_reset_rotates_password_and_ends_sessions() {
    let (_env, boot, rt) = boot("reset").await;
    let (base, _server) = serve(&boot).await;
    let http = reqwest::Client::new();
    let inbox = Inbox::new();
    let alice = signup(&rt, "alice@example.test").await;
    let session_status = |cookie: String| {
        let http = http.clone();
        let url = format!("{base}/api/auth/session");
        async move {
            http.get(url)
                .header("cookie", cookie)
                .send()
                .await
                .unwrap()
                .status()
                .as_u16()
        }
    };
    assert_eq!(session_status(alice.cookie.clone()).await, 200);

    accounts::request_password_reset(&rt, &inbox, "nobody@example.test")
        .await
        .unwrap();
    accounts::request_password_reset(&rt, &inbox, "not an address")
        .await
        .unwrap();
    assert_eq!(
        inbox.count(),
        0,
        "unknown address sends nothing and reports success"
    );

    accounts::request_password_reset(&rt, &inbox, " ALICE@example.test ")
        .await
        .unwrap();
    let (to, plain) = inbox.last(accounts::RESET_PASSWORD_PATH);
    assert_eq!(to, "alice@example.test");
    accounts::request_password_reset(&rt, &inbox, "alice@example.test")
        .await
        .unwrap();
    assert_eq!(
        inbox.count(),
        1,
        "second request inside the interval sends nothing"
    );

    let short = accounts::reset_password(&rt, &token(&plain), &secret("elevenchars")).await;
    assert!(
        matches!(short, Err(ApiError::BadRequest("password_length"))),
        "core 12-character rule"
    );
    accounts::reset_password(&rt, &token(&plain), &secret("twelve chars"))
        .await
        .unwrap();
    assert_eq!(
        session_status(alice.cookie.clone()).await,
        401,
        "existing session ends after reset"
    );
    assert!(
        core::login(&rt, "alice@example.test", PASSWORD)
            .await
            .is_err(),
        "old password rejected"
    );
    assert!(
        core::login(&rt, "alice@example.test", "twelve chars")
            .await
            .is_ok(),
        "new password accepted"
    );
    let replay = accounts::reset_password(&rt, &token(&plain), &secret("another password")).await;
    assert!(
        matches!(replay, Err(ApiError::NotFound)),
        "reset link is single use"
    );

    rt.control
        .execute_raw(sql(
            "UPDATE account_tokens SET created_at = created_at - 120",
            vec![],
        ))
        .await
        .unwrap();
    accounts::request_password_reset(&rt, &inbox, "alice@example.test")
        .await
        .unwrap();
    let (_, raced) = inbox.last(accounts::RESET_PASSWORD_PATH);
    let racers: Vec<_> = (0..4)
        .map(|_| {
            let (rt, raced) = (rt.clone(), raced.clone());
            tokio::spawn(async move {
                accounts::reset_password(&rt, &token(&raced), &secret("racer password ok")).await
            })
        })
        .collect();
    let mut wins = 0;
    for racer in racers {
        match racer.await.unwrap() {
            Ok(()) => wins += 1,
            Err(error) => assert!(
                matches!(error, ApiError::NotFound),
                "losing racer sees a used link"
            ),
        }
    }
    assert_eq!(wins, 1, "exactly one concurrent reset wins");

    rt.control
        .execute_raw(sql(
            "UPDATE account_tokens SET created_at = created_at - 120",
            vec![],
        ))
        .await
        .unwrap();
    accounts::request_password_reset(&rt, &inbox, "alice@example.test")
        .await
        .unwrap();
    let (_, expired) = inbox.last(accounts::RESET_PASSWORD_PATH);
    rt.control
        .execute_raw(sql("UPDATE account_tokens SET expires_at = 0", vec![]))
        .await
        .unwrap();
    let late = accounts::reset_password(&rt, &token(&expired), &secret("late password ok")).await;
    assert!(
        matches!(late, Err(ApiError::NotFound)),
        "expired reset link rejected"
    );

    let off = Inbox {
        configured: false,
        ..Inbox::new()
    };
    let unknown = accounts::request_password_reset(&rt, &off, "nobody@example.test").await;
    let known = accounts::request_password_reset(&rt, &off, "alice@example.test").await;
    assert!(matches!(
        unknown,
        Err(ApiError::Unavailable("email_not_configured"))
    ));
    assert!(
        matches!(known, Err(ApiError::Unavailable("email_not_configured"))),
        "same failure for every address"
    );

    rt.control
        .execute_raw(sql(
            "UPDATE account_tokens SET created_at = created_at - 120",
            vec![],
        ))
        .await
        .unwrap();
    let before = scalar(&rt, "SELECT COUNT(*) FROM account_tokens", vec![]).await;
    let down = Inbox {
        failure: Some(MailFailure::Unavailable),
        ..Inbox::new()
    };
    let failed = accounts::request_password_reset(&rt, &down, "alice@example.test").await;
    assert!(
        matches!(failed, Err(ApiError::Unavailable("email_unavailable"))),
        "send failure reaches the caller"
    );
    assert_eq!(
        scalar(&rt, "SELECT COUNT(*) FROM account_tokens", vec![]).await,
        before,
        "failed send leaves no token row"
    );
    shutdown(&boot).await;
}

async fn access(rt: &Runtime, user: &User, org: &OrgId) -> OrgAccess {
    authorize(rt, user.session.user, org)
        .await
        .expect("member access")
}

async fn confirm(rt: &Runtime, inbox: &Inbox, user: &User) {
    accounts::send_account_confirmation(rt, inbox, &user.session)
        .await
        .unwrap();
    let (_, plain) = inbox.last(accounts::CONFIRM_ACCOUNT_PATH);
    accounts::confirm_account(rt, &user.session, &token(&plain))
        .await
        .unwrap();
}

fn role_of(team: &[accounts::TeamMember], user: UserId) -> Option<Role> {
    team.iter().find(|m| m.user_id == user).map(|m| m.role)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn invitations_roles_and_ownership_are_scoped() {
    let (_env, boot, rt) = boot("team").await;
    let inbox = Inbox::new();
    let alice = signup(&rt, "alice@example.test").await;
    let bob = signup(&rt, "bob@example.test").await;
    let carol = signup(&rt, "carol@example.test").await;
    let acme = orgs::create(&rt, alice.session.user, "Acme")
        .await
        .unwrap()
        .id;
    let other = orgs::create(&rt, carol.session.user, "Other")
        .await
        .unwrap()
        .id;

    let a = access(&rt, &alice, &acme).await;
    let unconfirmed = accounts::invite(&rt, &inbox, &a, "bob@example.test", Role::Member).await;
    assert!(
        matches!(unconfirmed, Err(ApiError::Conflict("email_not_confirmed"))),
        "unconfirmed manager cannot invite"
    );
    confirm(&rt, &inbox, &alice).await;
    let owner_role = accounts::invite(&rt, &inbox, &a, "bob@example.test", Role::Owner).await;
    assert!(matches!(
        owner_role,
        Err(ApiError::BadRequest("invalid_role"))
    ));

    accounts::invite(&rt, &inbox, &a, "BOB@example.test", Role::Member)
        .await
        .unwrap();
    let (to, plain) = inbox.last(accounts::ACCEPT_INVITATION_PATH);
    assert_eq!(to, "bob@example.test");
    assert_eq!(accounts::invitations(&rt, &a).await.unwrap().len(), 1);

    let early = accounts::accept_invitation(&rt, &bob.session, &token(&plain)).await;
    assert!(
        matches!(early, Err(ApiError::Conflict("email_not_confirmed"))),
        "invitee must confirm first"
    );
    confirm(&rt, &inbox, &carol).await;
    let wrong = accounts::accept_invitation(&rt, &carol.session, &token(&plain)).await;
    assert!(
        matches!(wrong, Err(ApiError::Conflict("invitation_email_mismatch"))),
        "other account cannot accept"
    );
    confirm(&rt, &inbox, &bob).await;
    let racers: Vec<_> = (0..4)
        .map(|_| {
            let (rt, session, plain) = (rt.clone(), bob.session.clone(), plain.clone());
            tokio::spawn(
                async move { accounts::accept_invitation(&rt, &session, &token(&plain)).await },
            )
        })
        .collect();
    let mut joined = Vec::new();
    for racer in racers {
        match racer.await.unwrap() {
            Ok(org) => joined.push(org),
            Err(error) => assert!(
                matches!(error, ApiError::NotFound),
                "losing racer sees a used invitation"
            ),
        }
    }
    assert_eq!(joined.len(), 1, "exactly one concurrent accept wins");
    let joined = joined.pop().unwrap();
    assert_eq!(joined.id, acme);
    assert_eq!(joined.role, Role::Member);
    assert!(
        authorize(&rt, carol.session.user, &acme).await.is_err(),
        "mismatched account gained no membership"
    );
    let replay = accounts::accept_invitation(&rt, &bob.session, &token(&plain)).await;
    assert!(matches!(replay, Err(ApiError::NotFound)));
    assert!(accounts::invitations(&rt, &a).await.unwrap().is_empty());
    let again = accounts::invite(&rt, &inbox, &a, "bob@example.test", Role::Admin).await;
    assert!(matches!(again, Err(ApiError::Conflict("already_member"))));

    let pending = accounts::invite(&rt, &inbox, &a, "dave@example.test", Role::Admin)
        .await
        .unwrap();
    let c_other = access(&rt, &carol, &other).await;
    let cross = accounts::revoke_invitation(&rt, &c_other, pending.id).await;
    assert!(
        matches!(cross, Err(ApiError::NotFound)),
        "revocation is scoped to the organization"
    );
    assert!(
        matches!(accounts::invitations(&rt, &c_other).await, Ok(list) if list.is_empty()),
        "no cross-org listing"
    );
    let (_, dave_token) = inbox.last(accounts::ACCEPT_INVITATION_PATH);
    let dave = signup(&rt, "dave@example.test").await;
    confirm(&rt, &inbox, &dave).await;
    rt.control
        .execute_raw(sql(
            "UPDATE invitations SET expires_at = 0 WHERE id = ?",
            vec![pending.id.into()],
        ))
        .await
        .unwrap();
    let expired = accounts::accept_invitation(&rt, &dave.session, &token(&dave_token)).await;
    assert!(
        matches!(expired, Err(ApiError::NotFound)),
        "expired invitation rejected"
    );
    let fresh = accounts::invite(&rt, &inbox, &a, "dave@example.test", Role::Member).await;
    assert!(matches!(
        fresh,
        Err(ApiError::Conflict("email_recently_sent"))
    ));
    rt.control
        .execute_raw(sql(
            "UPDATE invitations SET created_at = created_at - 120",
            vec![],
        ))
        .await
        .unwrap();
    let reissued = accounts::invite(&rt, &inbox, &a, "dave@example.test", Role::Member)
        .await
        .unwrap();
    accounts::revoke_invitation(&rt, &a, reissued.id)
        .await
        .unwrap();
    let (_, revoked) = inbox.last(accounts::ACCEPT_INVITATION_PATH);
    let after_revoke = accounts::accept_invitation(&rt, &dave.session, &token(&revoked)).await;
    assert!(
        matches!(after_revoke, Err(ApiError::NotFound)),
        "revoked invitation rejected"
    );

    let b = access(&rt, &bob, &acme).await;
    assert!(matches!(
        accounts::set_member_role(&rt, &b, alice.session.user, Role::Member).await,
        Err(ApiError::Forbidden)
    ));
    assert!(
        matches!(
            accounts::rename_org(&rt, &b, "Taken").await,
            Err(ApiError::Forbidden)
        ),
        "member cannot rename"
    );
    assert!(matches!(
        accounts::invitations(&rt, &b).await,
        Err(ApiError::Forbidden)
    ));
    let promote = accounts::set_member_role(&rt, &a, bob.session.user, Role::Owner).await;
    assert!(matches!(promote, Err(ApiError::BadRequest("use_transfer"))));
    let last = accounts::set_member_role(&rt, &a, alice.session.user, Role::Admin).await;
    assert!(
        matches!(last, Err(ApiError::Conflict("last_owner"))),
        "last owner cannot be demoted"
    );
    accounts::set_member_role(&rt, &a, bob.session.user, Role::Admin)
        .await
        .unwrap();
    let b = access(&rt, &bob, &acme).await;
    let admin_on_owner = accounts::set_member_role(&rt, &b, alice.session.user, Role::Member).await;
    assert!(
        matches!(admin_on_owner, Err(ApiError::Forbidden)),
        "admin cannot change an owner"
    );
    let renamed = accounts::rename_org(&rt, &b, "  Acme Inc ").await.unwrap();
    assert_eq!(renamed.name, "Acme Inc");
    let cross_role = accounts::set_member_role(&rt, &c_other, bob.session.user, Role::Member).await;
    assert!(
        matches!(cross_role, Err(ApiError::NotFound)),
        "role change is scoped to the organization"
    );

    let to_outsider = accounts::transfer_ownership(&rt, &a, carol.session.user).await;
    assert!(
        matches!(to_outsider, Err(ApiError::NotFound)),
        "transfer target must be a member"
    );
    assert!(matches!(
        accounts::transfer_ownership(&rt, &b, bob.session.user).await,
        Err(ApiError::Forbidden)
    ));
    accounts::transfer_ownership(&rt, &a, bob.session.user)
        .await
        .unwrap();
    let team = accounts::team(&rt, &b).await.unwrap();
    assert_eq!(role_of(&team, bob.session.user), Some(Role::Owner));
    assert_eq!(role_of(&team, alice.session.user), Some(Role::Admin));
    let stale = accounts::transfer_ownership(&rt, &a, bob.session.user).await;
    assert!(
        matches!(stale, Err(ApiError::Forbidden)),
        "stale owner access is rechecked in the transaction"
    );
    let b = access(&rt, &bob, &acme).await;
    let demote_last = accounts::set_member_role(&rt, &b, bob.session.user, Role::Member).await;
    assert!(matches!(demote_last, Err(ApiError::Conflict("last_owner"))));
    shutdown(&boot).await;
}

#[tokio::test]
async fn migration_reapplies_cleanly() {
    let (env, boot, rt) = boot("migration").await;
    let alice = signup(&rt, "alice@example.test").await;
    rt.control
        .execute_raw(sql(
            "DELETE FROM seaql_migrations WHERE version = 'm20261015_000004_account_settings'",
            vec![],
        ))
        .await
        .unwrap();
    shutdown(&boot).await;
    drop(rt);
    let again = env
        .boot_memory(|s| s["auth"]["origin"] = json!(ORIGIN))
        .await
        .expect("second boot reruns 000004");
    let rt = Runtime::get(&again.app_context);
    let reapplied = scalar(
        &rt,
        "SELECT COUNT(*) FROM seaql_migrations WHERE version = 'm20261015_000004_account_settings'",
        vec![],
    )
    .await;
    assert_eq!(reapplied, 1, "migration recorded after rerun");
    let kept = accounts::account(&rt, &alice.session).await.unwrap();
    assert_eq!(kept.email, "alice@example.test");
    assert!(!kept.confirmed);
    shutdown(&again).await;
}

const LEGACY_PASSWORD: &str = "legacy fixture password";
const LEGACY_2Y: &str = "$2y$10$rIweE249H99lc8Ijz8YADOgY3I1zuhVDoB/WU9Yr3buqGFFPyzo/6";

async fn legacy_user(rt: &Runtime, email: &str, password_hash: &str) {
    rt.control
        .execute_raw(sql(
            "INSERT INTO users (email, password_hash, created_at, confirmed_at) VALUES (?, ?, 1758000000, 1758000000)",
            vec![email.into(), password_hash.into()],
        ))
        .await
        .unwrap();
}

async fn stored_hash(rt: &Runtime, email: &str) -> String {
    rt.control
        .query_one_raw(sql(
            "SELECT password_hash FROM users WHERE email = ?",
            vec![email.into()],
        ))
        .await
        .unwrap()
        .unwrap()
        .try_get("", "password_hash")
        .unwrap()
}

async fn http_login(base: &str, email: &str, password: &str) -> reqwest::StatusCode {
    reqwest::Client::new()
        .post(format!("{base}/api/auth/login"))
        .json(&json!({"email": email, "password": password}))
        .send()
        .await
        .unwrap()
        .status()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn legacy_bcrypt_login_rehashes_once() {
    let (_env, boot, rt) = boot("legacy-bcrypt-rehash").await;
    let (base, server) = serve(&boot).await;
    legacy_user(&rt, "legacy@example.test", LEGACY_2Y).await;

    assert_eq!(
        http_login(&base, "legacy@example.test", LEGACY_PASSWORD).await,
        reqwest::StatusCode::OK
    );
    let upgraded = stored_hash(&rt, "legacy@example.test").await;
    assert!(upgraded.starts_with("$argon2id$"), "{upgraded}");
    assert!(loco_rs::hash::verify_password(LEGACY_PASSWORD, &upgraded));
    assert_eq!(
        http_login(&base, "legacy@example.test", LEGACY_PASSWORD).await,
        reqwest::StatusCode::OK
    );
    assert_eq!(stored_hash(&rt, "legacy@example.test").await, upgraded);
    assert_eq!(
        scalar(&rt, "SELECT count(*) FROM sessions", vec![]).await,
        2
    );
    server.abort();
    shutdown(&boot).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wrong_password_keeps_bcrypt() {
    let (_env, boot, rt) = boot("legacy-bcrypt-wrong").await;
    let (base, server) = serve(&boot).await;
    legacy_user(&rt, "legacy@example.test", LEGACY_2Y).await;

    assert_eq!(
        http_login(&base, "legacy@example.test", "not the legacy password").await,
        reqwest::StatusCode::UNAUTHORIZED
    );
    assert_eq!(stored_hash(&rt, "legacy@example.test").await, LEGACY_2Y);
    assert_eq!(
        scalar(&rt, "SELECT count(*) FROM sessions", vec![]).await,
        0
    );
    server.abort();
    shutdown(&boot).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn concurrent_legacy_logins_keep_a_valid_argon_hash() {
    let (_env, boot, rt) = boot("legacy-bcrypt-concurrent").await;
    let (base, server) = serve(&boot).await;
    legacy_user(&rt, "legacy@example.test", LEGACY_2Y).await;

    let (first, second) = tokio::join!(
        http_login(&base, "legacy@example.test", LEGACY_PASSWORD),
        http_login(&base, "legacy@example.test", LEGACY_PASSWORD)
    );
    assert_eq!(
        (first, second),
        (reqwest::StatusCode::OK, reqwest::StatusCode::OK)
    );
    let stored = stored_hash(&rt, "legacy@example.test").await;
    assert!(stored.starts_with("$argon2id$"), "{stored}");
    assert!(loco_rs::hash::verify_password(LEGACY_PASSWORD, &stored));
    assert_eq!(
        scalar(&rt, "SELECT count(*) FROM sessions", vec![]).await,
        2
    );
    server.abort();
    shutdown(&boot).await;
}
