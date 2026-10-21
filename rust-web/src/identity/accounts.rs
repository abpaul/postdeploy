use std::time::Duration;

use sea_orm::ConnectionTrait;
use serde::Serialize;
use zeroize::Zeroizing;

use crate::{
    domain::{now_secs, UserId},
    error::{ApiError, ApiResult},
    identity::{access::Session, random_token, token_hash},
    runtime::{sql, Runtime},
};

const DUMMY_PASSWORD_HASH: &str = "$argon2id$v=19$m=19456,t=2,p=1$UG9zdERlcGxveUR1bW15IQ$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

#[derive(Debug, Serialize)]
pub struct User {
    pub id: UserId,
    pub email: String,
}

/// A new session. `token` goes only into the cookie.
pub struct SessionGrant {
    pub user: User,
    pub token: String,
    pub csrf_token: String,
    pub max_age: u64,
}

pub(crate) fn normalize_email(email: &str) -> ApiResult<String> {
    let email = email.trim().to_ascii_lowercase();
    let valid = email.len() <= 254
        && email.split_once('@').is_some_and(|(local, domain)| {
            !local.is_empty() && domain.contains('.') && !domain.starts_with('.')
        });
    valid
        .then_some(email)
        .ok_or(ApiError::BadRequest("invalid_email"))
}

async fn in_password_lane<T: Send + 'static>(
    rt: &Runtime,
    work: impl FnOnce() -> T + Send + 'static,
) -> ApiResult<T> {
    let permit = rt
        .admission
        .password_lane()
        .ok_or(ApiError::Unavailable("auth_overloaded"))?;
    tokio::task::spawn_blocking(move || {
        let _permit = permit;
        work()
    })
    .await
    .map_err(|_| ApiError::Internal("password task".into()))
}

pub(crate) async fn hash(rt: &Runtime, password: Zeroizing<String>) -> ApiResult<String> {
    in_password_lane(rt, move || loco_rs::hash::hash_password(&password))
        .await?
        .map_err(|_| ApiError::Internal("password hash".into()))
}

/// Argon2id is the only hash this service writes. Imported accounts can still
/// hold a bcrypt hash, which is replaced by Argon2id on the first correct login.
enum StoredPassword<'a> {
    Argon2(&'a str),
    Bcrypt(&'a str),
    Invalid,
}

impl<'a> StoredPassword<'a> {
    fn parse(stored: &'a str) -> Self {
        if stored.starts_with("$argon2id$") {
            Self::Argon2(stored)
        } else if ["$2a$", "$2b$", "$2y$"]
            .iter()
            .any(|prefix| stored.starts_with(prefix))
        {
            Self::Bcrypt(stored)
        } else {
            Self::Invalid
        }
    }
}

enum Checked {
    Rejected,
    Current,
    Upgrade(String),
}

fn check(password: &str, stored: &str) -> Result<Checked, ApiError> {
    let matched = match StoredPassword::parse(stored) {
        StoredPassword::Argon2(hash) => loco_rs::hash::verify_password(password, hash),
        StoredPassword::Bcrypt(hash) => {
            if !bcrypt::verify(password, hash).unwrap_or(false) {
                return Ok(Checked::Rejected);
            }
            return loco_rs::hash::hash_password(password)
                .map(Checked::Upgrade)
                .map_err(|_| ApiError::Internal("password hash".into()));
        }
        StoredPassword::Invalid => {
            let _ = loco_rs::hash::verify_password(password, DUMMY_PASSWORD_HASH);
            false
        }
    };
    Ok(if matched {
        Checked::Current
    } else {
        Checked::Rejected
    })
}

pub async fn signup(rt: &Runtime, email: &str, password: &str) -> ApiResult<SessionGrant> {
    let email = normalize_email(email)?;
    rt.password_policy.validate(password).await?;
    let password_hash = hash(rt, Zeroizing::new(password.to_owned())).await?;
    let row = rt
        .control
        .query_one_raw(sql(
            "INSERT INTO users (email, password_hash, created_at) VALUES (?, ?, ?)
             ON CONFLICT (email) DO NOTHING RETURNING id",
            vec![
                email.clone().into(),
                password_hash.clone().into(),
                now_secs().into(),
            ],
        ))
        .await?
        .ok_or(ApiError::Conflict("email_taken"))?;
    let user = User {
        id: UserId(row.try_get("", "id")?),
        email,
    };
    start_session(
        rt,
        Verified {
            user,
            password_hash,
        },
    )
    .await
}

pub async fn login(rt: &Runtime, email: &str, password: &str) -> ApiResult<SessionGrant> {
    let verified = verify(rt, email, password).await?;
    start_session(rt, verified).await
}

/// A user whose submitted password matched `password_hash` as stored.
struct Verified {
    user: User,
    password_hash: String,
}

async fn verify(rt: &Runtime, email: &str, password: &str) -> ApiResult<Verified> {
    let email = normalize_email(email).unwrap_or_default();
    let row = rt
        .control
        .query_one_raw(sql(
            "SELECT id, password_hash FROM users WHERE email = ?",
            vec![email.clone().into()],
        ))
        .await?;
    let (id, stored) = match row {
        Some(row) => (
            Some(row.try_get::<i64>("", "id")?),
            row.try_get::<String>("", "password_hash")?,
        ),
        None => (None, DUMMY_PASSWORD_HASH.to_owned()),
    };
    let password = Zeroizing::new(password.to_owned());
    let checked = {
        let (password, stored) = (password.clone(), stored.clone());
        in_password_lane(rt, move || check(&password, &stored)).await??
    };
    let verified = match (id, checked) {
        (Some(id), Checked::Current) => Some(Verified {
            user: User {
                id: UserId(id),
                email,
            },
            password_hash: stored,
        }),
        (Some(id), Checked::Upgrade(argon)) => {
            upgrade(
                rt,
                User {
                    id: UserId(id),
                    email,
                },
                &stored,
                argon,
                password,
            )
            .await?
        }
        _ => None,
    };
    match verified {
        Some(verified) => Ok(verified),
        None => {
            tokio::time::sleep(Duration::from_millis(
                rt.settings.auth.failed_login_delay_ms,
            ))
            .await;
            Err(ApiError::Unauthorized)
        }
    }
}

/// Replaces a verified bcrypt hash by compare-and-set. When another request
/// changed the hash first, the password must also match the stored hash:
/// a concurrent correct login passes, a concurrent reset does not.
async fn upgrade(
    rt: &Runtime,
    user: User,
    bcrypt: &str,
    argon: String,
    password: Zeroizing<String>,
) -> ApiResult<Option<Verified>> {
    let replaced = rt
        .control
        .execute_raw(sql(
            "UPDATE users SET password_hash = ? WHERE id = ? AND password_hash = ?",
            vec![argon.clone().into(), user.id.0.into(), bcrypt.into()],
        ))
        .await?;
    if replaced.rows_affected() == 1 {
        return Ok(Some(Verified {
            user,
            password_hash: argon,
        }));
    }
    let Some(row) = rt
        .control
        .query_one_raw(sql(
            "SELECT password_hash FROM users WHERE id = ?",
            vec![user.id.0.into()],
        ))
        .await?
    else {
        return Ok(None);
    };
    let current: String = row.try_get("", "password_hash")?;
    if !matches!(StoredPassword::parse(&current), StoredPassword::Argon2(_)) {
        return Ok(None);
    }
    let matched = {
        let current = current.clone();
        in_password_lane(rt, move || {
            loco_rs::hash::verify_password(&password, &current)
        })
        .await?
    };
    Ok(matched.then_some(Verified {
        user,
        password_hash: current,
    }))
}

/// Inserts the session only while the stored hash is still the one the
/// password matched, so a password reset committed after verification wins.
async fn start_session(rt: &Runtime, verified: Verified) -> ApiResult<SessionGrant> {
    let Verified {
        user,
        password_hash,
    } = verified;
    let token = random_token();
    let csrf_token = random_token();
    let max_age = rt.settings.auth.session_ttl_secs;
    let now = now_secs();
    let inserted = rt
        .control
        .execute_raw(sql(
            "INSERT INTO sessions (token_hash, user_id, csrf_token, created_at, expires_at)
             SELECT ?, id, ?, ?, ? FROM users WHERE id = ? AND password_hash = ?",
            vec![
                token_hash(&token).into(),
                csrf_token.clone().into(),
                now.into(),
                (now + max_age as i64).into(),
                user.id.0.into(),
                password_hash.into(),
            ],
        ))
        .await?;
    if inserted.rows_affected() == 0 {
        return Err(ApiError::Unauthorized);
    }
    Ok(SessionGrant {
        user,
        token,
        csrf_token,
        max_age,
    })
}

pub async fn logout(rt: &Runtime, session: &Session) -> ApiResult<()> {
    rt.control
        .execute_raw(sql(
            "DELETE FROM sessions WHERE id = ?",
            vec![session.id.into()],
        ))
        .await?;
    Ok(())
}

pub fn session_cookie(rt: &Runtime, token: &str, max_age: u64) -> String {
    let secure = if rt.settings.auth.secure_cookies {
        "; Secure"
    } else {
        ""
    };
    format!(
        "{}={token}; Path=/; HttpOnly; SameSite=Lax; Max-Age={max_age}{secure}",
        crate::identity::access::SESSION_COOKIE
    )
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use async_trait::async_trait;
    use sea_orm::ConnectionTrait;

    use super::*;
    use crate::account_settings::{
        self, AccountMail, AccountMessage, AccountToken, MailFailure, RESET_PASSWORD_PATH,
    };

    const OLD_PASSWORD: &str = "correct horse battery";

    #[derive(Default)]
    struct Inbox(Mutex<Vec<String>>);

    #[async_trait]
    impl AccountMail for Inbox {
        fn configured(&self) -> bool {
            true
        }

        async fn send(&self, message: AccountMessage) -> Result<(), MailFailure> {
            self.0.lock().unwrap().push(message.text().to_owned());
            Ok(())
        }
    }

    impl Inbox {
        fn reset_token(&self) -> AccountToken {
            let text = self.0.lock().unwrap().last().cloned().expect("reset mail");
            let marker = format!("{RESET_PASSWORD_PATH}?token=");
            let start = text.find(&marker).expect("reset link") + marker.len();
            let token: String = text[start..]
                .chars()
                .take_while(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_')
                .collect();
            serde_json::from_value(serde_json::json!(token)).unwrap()
        }
    }

    async fn sessions(rt: &Runtime, user: UserId) -> i64 {
        rt.control
            .query_one_raw(sql(
                "SELECT count(*) FROM sessions WHERE user_id = ?",
                vec![user.0.into()],
            ))
            .await
            .unwrap()
            .unwrap()
            .try_get_by_index(0)
            .unwrap()
    }

    #[tokio::test]
    async fn a_login_verified_before_a_reset_cannot_start_a_session_after_it() {
        let env = crate::testing::TestEnv::new("login-reset-race");
        let boot = env.boot_memory(|_| {}).await.unwrap();
        let rt = Runtime::get(&boot.app_context);
        let user = signup(&rt, "racer@example.test", OLD_PASSWORD)
            .await
            .unwrap()
            .user
            .id;
        let inbox = Inbox::default();
        account_settings::request_password_reset(&rt, &inbox, "racer@example.test")
            .await
            .unwrap();

        let verified = verify(&rt, "racer@example.test", OLD_PASSWORD)
            .await
            .unwrap();
        let new_password: credseal::SecretString =
            serde_json::from_value(serde_json::json!("brand new password ok")).unwrap();
        account_settings::reset_password(&rt, &inbox.reset_token(), &new_password)
            .await
            .unwrap();
        let late = start_session(&rt, verified).await;

        assert!(matches!(late, Err(ApiError::Unauthorized)), "late login");
        assert_eq!(sessions(&rt, user).await, 0);
        rt.shutdown().await;
    }
}
