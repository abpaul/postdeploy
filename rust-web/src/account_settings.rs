//! Plaintext tokens exist only in the outgoing mail text and the user's
//! request; the control database stores SHA-256 hashes. Every token is consumed
//! by one conditional `UPDATE ... RETURNING`, so concurrent uses yield one
//! success. Links use the configured auth origin, never the request host.

use async_trait::async_trait;
use credseal::SecretString;
use sea_orm::{
    ConnectionTrait, DatabaseTransaction, QueryResult, SqliteTransactionMode, TransactionOptions,
    TransactionTrait,
};
use serde::{Deserialize, Serialize};

use crate::{
    domain::{now_secs, OrgId, Role, UserId},
    error::{ApiError, ApiResult},
    identity::{
        access::{authorize, OrgAccess, Session},
        accounts::{hash, normalize_email},
        orgs::{self, clean_name, OrgSummary},
        random_token, token_hash,
    },
    runtime::{sql, Runtime},
};

pub const CONFIRM_ACCOUNT_PATH: &str = "/confirm";
pub const CONFIRM_EMAIL_PATH: &str = "/confirm/email";
pub const RESET_PASSWORD_PATH: &str = "/reset/complete";
pub const ACCEPT_INVITATION_PATH: &str = "/invitations/accept";

const RESEND_INTERVAL_SECS: i64 = 60;
const INVITATION_TTL_SECS: i64 = 7 * 24 * 3600;
const MAX_PENDING_INVITATIONS: i64 = 50;
const MAX_NAME_CHARS: usize = 100;

/// A plaintext token received from a link. Deserialize it straight from the
/// form or query; it has no `Display` or `Serialize`.
#[derive(Deserialize)]
#[serde(transparent)]
pub struct AccountToken(String);

impl std::fmt::Debug for AccountToken {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("AccountToken([REDACTED])")
    }
}

/// One security email. `text` holds a single-use link, so it is never logged,
/// queued or stored.
pub struct AccountMessage {
    pub to: String,
    pub subject: String,
    text: String,
}

impl AccountMessage {
    pub(crate) fn new(to: String, subject: impl Into<String>, text: String) -> Self {
        Self {
            to,
            subject: subject.into(),
            text,
        }
    }

    pub fn text(&self) -> &str {
        &self.text
    }
}

impl std::fmt::Debug for AccountMessage {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AccountMessage")
            .field("to", &self.to)
            .field("subject", &self.subject)
            .finish_non_exhaustive()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MailFailure {
    NotConfigured,
    Rejected,
    Unavailable,
}

impl From<MailFailure> for ApiError {
    fn from(failure: MailFailure) -> Self {
        match failure {
            MailFailure::NotConfigured => ApiError::Unavailable("email_not_configured"),
            MailFailure::Rejected => ApiError::BadRequest("email_rejected"),
            MailFailure::Unavailable => ApiError::Unavailable("email_unavailable"),
        }
    }
}

#[async_trait]
pub trait AccountMail: Send + Sync {
    fn configured(&self) -> bool;
    async fn send(&self, message: AccountMessage) -> Result<(), MailFailure>;
}

#[derive(Debug, Serialize)]
pub struct Account {
    pub id: UserId,
    pub email: String,
    pub name: Option<String>,
    pub confirmed: bool,
    /// New address awaiting confirmation. The current `email` stays active until then.
    pub pending_email: Option<String>,
    pub created_at: i64,
}

#[derive(Debug, Serialize)]
pub struct TeamMember {
    pub user_id: UserId,
    pub email: String,
    pub name: Option<String>,
    pub role: Role,
    pub joined_at: i64,
}

#[derive(Debug, Serialize)]
pub struct Invitation {
    pub id: i64,
    pub email: String,
    pub role: Role,
    pub invited_by: Option<UserId>,
    pub created_at: i64,
    pub expires_at: i64,
}

#[derive(Clone, Copy)]
enum Purpose {
    ConfirmAccount,
    ChangeEmail,
    ResetPassword,
}

impl Purpose {
    fn as_str(self) -> &'static str {
        match self {
            Self::ConfirmAccount => "confirm_account",
            Self::ChangeEmail => "change_email",
            Self::ResetPassword => "reset_password",
        }
    }

    fn ttl_secs(self) -> i64 {
        match self {
            Self::ConfirmAccount | Self::ChangeEmail => 24 * 3600,
            Self::ResetPassword => 3600,
        }
    }

    fn path(self) -> &'static str {
        match self {
            Self::ConfirmAccount => CONFIRM_ACCOUNT_PATH,
            Self::ChangeEmail => CONFIRM_EMAIL_PATH,
            Self::ResetPassword => RESET_PASSWORD_PATH,
        }
    }

    fn subject(self) -> &'static str {
        match self {
            Self::ConfirmAccount => "Confirm your PostDeploy email address",
            Self::ChangeEmail => "Confirm your new PostDeploy email address",
            Self::ResetPassword => "Reset your PostDeploy password",
        }
    }

    fn lead(self) -> &'static str {
        match self {
            Self::ConfirmAccount => "Open this link while signed in to confirm your email address. It expires in 24 hours.",
            Self::ChangeEmail => {
                "Open this link while signed in to make this your PostDeploy email address. \
                 Your current address stays active until you do. It expires in 24 hours."
            }
            Self::ResetPassword => {
                "Open this link to choose a new password. It expires in 1 hour and signs out every session."
            }
        }
    }
}

fn immediate() -> TransactionOptions {
    TransactionOptions {
        sqlite_transaction_mode: Some(SqliteTransactionMode::Immediate),
        ..TransactionOptions::default()
    }
}

fn link(rt: &Runtime, path: &str, token: &str) -> String {
    format!(
        "{}{path}?token={token}",
        rt.settings.auth.origin.trim_end_matches('/')
    )
}

fn clean_display_name(name: &str) -> ApiResult<Option<String>> {
    let name = name.trim();
    if name.chars().count() > MAX_NAME_CHARS || name.chars().any(char::is_control) {
        return Err(ApiError::BadRequest("invalid_name"));
    }
    Ok((!name.is_empty()).then(|| name.to_owned()))
}

fn stored_role(row: &QueryResult) -> ApiResult<Role> {
    let role: String = row.try_get("", "role")?;
    Role::parse(&role).ok_or(ApiError::Internal("stored role".into()))
}

pub async fn account(rt: &Runtime, session: &Session) -> ApiResult<Account> {
    let now = now_secs();
    let row = rt
        .control
        .query_one_raw(sql(
            "SELECT u.id, u.email, u.name, u.confirmed_at, u.created_at,
                    (SELECT t.email FROM account_tokens t
                     WHERE t.user_id = u.id AND t.purpose = 'change_email'
                       AND t.consumed_at IS NULL AND t.expires_at > ?
                     ORDER BY t.id DESC LIMIT 1) AS pending_email
             FROM users u WHERE u.id = ?",
            vec![now.into(), session.user.0.into()],
        ))
        .await?
        .ok_or(ApiError::Unauthorized)?;
    Ok(Account {
        id: UserId(row.try_get("", "id")?),
        email: row.try_get("", "email")?,
        name: row.try_get("", "name")?,
        confirmed: row.try_get::<Option<i64>>("", "confirmed_at")?.is_some(),
        pending_email: row.try_get("", "pending_email")?,
        created_at: row.try_get("", "created_at")?,
    })
}

pub async fn update_name(rt: &Runtime, session: &Session, name: &str) -> ApiResult<Account> {
    let name = clean_display_name(name)?;
    rt.control
        .execute_raw(sql(
            "UPDATE users SET name = ? WHERE id = ?",
            vec![name.into(), session.user.0.into()],
        ))
        .await?;
    account(rt, session).await
}

async fn issue_token(
    rt: &Runtime,
    user: UserId,
    purpose: Purpose,
    email: &str,
) -> ApiResult<(i64, String)> {
    let now = now_secs();
    let txn = rt.control.begin_with_options(immediate()).await?;
    let recent = txn
        .query_one_raw(sql(
            "SELECT 1 FROM account_tokens WHERE user_id = ? AND purpose = ? AND created_at > ? LIMIT 1",
            vec![user.0.into(), purpose.as_str().into(), (now - RESEND_INTERVAL_SECS).into()],
        ))
        .await?;
    if recent.is_some() {
        return Err(ApiError::Conflict("email_recently_sent"));
    }
    txn.execute_raw(sql(
        "UPDATE account_tokens SET consumed_at = ? WHERE user_id = ? AND purpose = ? AND consumed_at IS NULL",
        vec![now.into(), user.0.into(), purpose.as_str().into()],
    ))
    .await?;
    let token = random_token();
    let row = txn
        .query_one_raw(sql(
            "INSERT INTO account_tokens (token_hash, user_id, purpose, email, created_at, expires_at)
             VALUES (?, ?, ?, ?, ?, ?) RETURNING id",
            vec![
                token_hash(&token).into(),
                user.0.into(),
                purpose.as_str().into(),
                email.into(),
                now.into(),
                (now + purpose.ttl_secs()).into(),
            ],
        ))
        .await?
        .ok_or(ApiError::Internal("account token insert".into()))?;
    let id: i64 = row.try_get("", "id")?;
    txn.commit().await?;
    Ok((id, token))
}

enum LinkRow {
    Token(i64),
    Invitation(i64),
}

async fn deliver_or_revoke(
    rt: &Runtime,
    mail: &dyn AccountMail,
    row: LinkRow,
    message: AccountMessage,
) -> ApiResult<()> {
    let Err(failure) = mail.send(message).await else {
        return Ok(());
    };
    let (delete, id) = match row {
        LinkRow::Token(id) => ("DELETE FROM account_tokens WHERE id = ?", id),
        LinkRow::Invitation(id) => ("DELETE FROM invitations WHERE id = ?", id),
    };
    rt.control.execute_raw(sql(delete, vec![id.into()])).await?;
    Err(failure.into())
}

async fn send_token(
    rt: &Runtime,
    mail: &dyn AccountMail,
    user: UserId,
    purpose: Purpose,
    to: &str,
) -> ApiResult<()> {
    if !mail.configured() {
        return Err(MailFailure::NotConfigured.into());
    }
    let (id, token) = issue_token(rt, user, purpose, to).await?;
    let text = format!(
        "{}\n\n{}\n\nIf you did not ask for this, ignore this email.\n",
        purpose.lead(),
        link(rt, purpose.path(), &token)
    );
    let message = AccountMessage {
        to: to.to_owned(),
        subject: purpose.subject().to_owned(),
        text,
    };
    deliver_or_revoke(rt, mail, LinkRow::Token(id), message).await
}

pub async fn send_account_confirmation(
    rt: &Runtime,
    mail: &dyn AccountMail,
    session: &Session,
) -> ApiResult<()> {
    let current = account(rt, session).await?;
    if current.confirmed {
        return Err(ApiError::Conflict("already_confirmed"));
    }
    send_token(
        rt,
        mail,
        current.id,
        Purpose::ConfirmAccount,
        &current.email,
    )
    .await
}

async fn consume(
    txn: &DatabaseTransaction,
    purpose: Purpose,
    token: &AccountToken,
    user: Option<UserId>,
    require_current_email: bool,
) -> ApiResult<(UserId, String)> {
    let now = now_secs();
    let mut query = String::from(
        "UPDATE account_tokens SET consumed_at = ?
         WHERE token_hash = ? AND purpose = ? AND consumed_at IS NULL AND expires_at > ?",
    );
    let mut values: Vec<sea_orm::Value> = vec![
        now.into(),
        token_hash(&token.0).into(),
        purpose.as_str().into(),
        now.into(),
    ];
    if let Some(user) = user {
        query.push_str(" AND user_id = ?");
        values.push(user.0.into());
    }
    if require_current_email {
        query.push_str(
            " AND email = (SELECT u.email FROM users u WHERE u.id = account_tokens.user_id)",
        );
    }
    query.push_str(" RETURNING user_id, email");
    let row = txn
        .query_one_raw(sql(&query, values))
        .await?
        .ok_or(ApiError::NotFound)?;
    Ok((
        UserId(row.try_get("", "user_id")?),
        row.try_get("", "email")?,
    ))
}

pub async fn confirm_account(
    rt: &Runtime,
    session: &Session,
    token: &AccountToken,
) -> ApiResult<Account> {
    let txn = rt.control.begin_with_options(immediate()).await?;
    consume(
        &txn,
        Purpose::ConfirmAccount,
        token,
        Some(session.user),
        true,
    )
    .await?;
    txn.execute_raw(sql(
        "UPDATE users SET confirmed_at = COALESCE(confirmed_at, ?) WHERE id = ?",
        vec![now_secs().into(), session.user.0.into()],
    ))
    .await?;
    txn.commit().await?;
    account(rt, session).await
}

async fn email_in_use(conn: &impl ConnectionTrait, email: &str, except: UserId) -> ApiResult<bool> {
    Ok(conn
        .query_one_raw(sql(
            "SELECT 1 FROM users WHERE email = ? AND id <> ?",
            vec![email.into(), except.0.into()],
        ))
        .await?
        .is_some())
}

pub async fn request_email_change(
    rt: &Runtime,
    mail: &dyn AccountMail,
    session: &Session,
    new_email: &str,
) -> ApiResult<()> {
    let email = normalize_email(new_email)?;
    let current = account(rt, session).await?;
    if email == current.email {
        return Err(ApiError::BadRequest("email_unchanged"));
    }
    if email_in_use(&rt.control, &email, current.id).await? {
        return Err(ApiError::Conflict("email_taken"));
    }
    send_token(rt, mail, current.id, Purpose::ChangeEmail, &email).await
}

pub async fn confirm_email_change(
    rt: &Runtime,
    session: &Session,
    token: &AccountToken,
) -> ApiResult<Account> {
    let txn = rt.control.begin_with_options(immediate()).await?;
    let (user, email) =
        consume(&txn, Purpose::ChangeEmail, token, Some(session.user), false).await?;
    if email_in_use(&txn, &email, user).await? {
        return Err(ApiError::Conflict("email_taken"));
    }
    let now = now_secs();
    txn.execute_raw(sql(
        "UPDATE users SET email = ?, confirmed_at = ? WHERE id = ?",
        vec![email.into(), now.into(), user.0.into()],
    ))
    .await?;
    txn.execute_raw(sql(
        "UPDATE account_tokens SET consumed_at = ? WHERE user_id = ? AND consumed_at IS NULL",
        vec![now.into(), user.0.into()],
    ))
    .await?;
    txn.commit().await?;
    account(rt, session).await
}

/// Returns `Ok` for unknown addresses and for requests inside the resend
/// interval, so the response does not reveal whether an account exists.
pub async fn request_password_reset(
    rt: &Runtime,
    mail: &dyn AccountMail,
    email: &str,
) -> ApiResult<()> {
    if !mail.configured() {
        return Err(MailFailure::NotConfigured.into());
    }
    let Ok(email) = normalize_email(email) else {
        return Ok(());
    };
    let Some(row) = rt
        .control
        .query_one_raw(sql(
            "SELECT id FROM users WHERE email = ?",
            vec![email.clone().into()],
        ))
        .await?
    else {
        return Ok(());
    };
    let user = UserId(row.try_get("", "id")?);
    match send_token(rt, mail, user, Purpose::ResetPassword, &email).await {
        Err(ApiError::Conflict("email_recently_sent")) => Ok(()),
        other => other,
    }
}

/// Sets a new password, signs out every session of the account and voids its
/// other reset links, OAuth grants and API keys.
pub async fn reset_password(
    rt: &Runtime,
    token: &AccountToken,
    password: &SecretString,
) -> ApiResult<()> {
    rt.password_policy
        .validate(password.expose_secret())
        .await?;
    let password_hash = hash(
        rt,
        zeroize::Zeroizing::new(password.expose_secret().to_owned()),
    )
    .await?;
    let txn = rt.control.begin_with_options(immediate()).await?;
    let (user, _) = consume(&txn, Purpose::ResetPassword, token, None, true).await?;
    txn.execute_raw(sql(
        "UPDATE users SET password_hash = ? WHERE id = ?",
        vec![password_hash.into(), user.0.into()],
    ))
    .await?;
    txn.execute_raw(sql(
        "DELETE FROM sessions WHERE user_id = ?",
        vec![user.0.into()],
    ))
    .await?;
    txn.execute_raw(sql(
        "UPDATE oauth_grants SET revoked_at = COALESCE(revoked_at, ?) WHERE user_id = ?",
        vec![now_secs().into(), user.0.into()],
    ))
    .await?;
    txn.execute_raw(sql(
        "UPDATE agent_api_keys SET revoked_at = COALESCE(revoked_at, ?) WHERE user_id = ?",
        vec![now_secs().into(), user.0.into()],
    ))
    .await?;
    txn.execute_raw(sql(
        "UPDATE account_tokens SET consumed_at = ? WHERE user_id = ? AND purpose = 'reset_password' AND consumed_at IS NULL",
        vec![now_secs().into(), user.0.into()],
    ))
    .await?;
    txn.commit().await?;
    Ok(())
}

pub async fn rename_org(rt: &Runtime, access: &OrgAccess, name: &str) -> ApiResult<OrgSummary> {
    access.require_manage()?;
    let name = clean_name(name)?;
    rt.control
        .execute_raw(sql(
            "UPDATE organizations SET name = ? WHERE id = ?",
            vec![name.into(), access.org.as_str().into()],
        ))
        .await?;
    orgs::get(rt, access).await
}

pub async fn team(rt: &Runtime, access: &OrgAccess) -> ApiResult<Vec<TeamMember>> {
    let rows = rt
        .control
        .query_all_raw(sql(
            "SELECT m.user_id, u.email, u.name, m.role, m.created_at FROM memberships m
             JOIN users u ON u.id = m.user_id WHERE m.org_id = ? ORDER BY m.created_at, m.user_id",
            vec![access.org.as_str().into()],
        ))
        .await?;
    rows.iter()
        .map(|row| {
            Ok(TeamMember {
                user_id: UserId(row.try_get("", "user_id")?),
                email: row.try_get("", "email")?,
                name: row.try_get("", "name")?,
                role: stored_role(row)?,
                joined_at: row.try_get("", "created_at")?,
            })
        })
        .collect()
}

async fn role_in(txn: &DatabaseTransaction, org: &OrgId, user: UserId) -> ApiResult<Option<Role>> {
    txn.query_one_raw(sql(
        "SELECT role FROM memberships WHERE org_id = ? AND user_id = ?",
        vec![org.as_str().into(), user.0.into()],
    ))
    .await?
    .map(|row| stored_role(&row))
    .transpose()
}

async fn set_role(
    txn: &DatabaseTransaction,
    org: &OrgId,
    user: UserId,
    role: Role,
) -> ApiResult<()> {
    txn.execute_raw(sql(
        "UPDATE memberships SET role = ? WHERE org_id = ? AND user_id = ?",
        vec![role.as_str().into(), org.as_str().into(), user.0.into()],
    ))
    .await?;
    Ok(())
}

/// Changes a member to `admin` or `member`. Ownership moves only through
/// [`transfer_ownership`].
pub async fn set_member_role(
    rt: &Runtime,
    access: &OrgAccess,
    target: UserId,
    role: Role,
) -> ApiResult<()> {
    access.require_manage()?;
    if role == Role::Owner {
        return Err(ApiError::BadRequest("use_transfer"));
    }
    let txn = rt.control.begin_with_options(immediate()).await?;
    let caller = role_in(&txn, &access.org, access.user)
        .await?
        .ok_or(ApiError::Forbidden)?;
    if !caller.can_manage() {
        return Err(ApiError::Forbidden);
    }
    let current = role_in(&txn, &access.org, target)
        .await?
        .ok_or(ApiError::NotFound)?;
    if current == Role::Owner {
        if caller != Role::Owner {
            return Err(ApiError::Forbidden);
        }
        let owners: i64 = txn
            .query_one_raw(sql(
                "SELECT COUNT(*) AS n FROM memberships WHERE org_id = ? AND role = 'owner'",
                vec![access.org.as_str().into()],
            ))
            .await?
            .ok_or(ApiError::Internal("owner count".into()))?
            .try_get("", "n")?;
        if owners <= 1 {
            return Err(ApiError::Conflict("last_owner"));
        }
    }
    set_role(&txn, &access.org, target, role).await?;
    txn.commit().await?;
    Ok(())
}

/// Makes `target` an owner and the calling owner an admin in one transaction.
pub async fn transfer_ownership(rt: &Runtime, access: &OrgAccess, target: UserId) -> ApiResult<()> {
    if access.role != Role::Owner {
        return Err(ApiError::Forbidden);
    }
    if target == access.user {
        return Err(ApiError::BadRequest("self_transfer"));
    }
    let txn = rt.control.begin_with_options(immediate()).await?;
    if role_in(&txn, &access.org, access.user).await? != Some(Role::Owner) {
        return Err(ApiError::Forbidden);
    }
    role_in(&txn, &access.org, target)
        .await?
        .ok_or(ApiError::NotFound)?;
    set_role(&txn, &access.org, target, Role::Owner).await?;
    set_role(&txn, &access.org, access.user, Role::Admin).await?;
    txn.commit().await?;
    Ok(())
}

fn invitation(row: &QueryResult) -> ApiResult<Invitation> {
    Ok(Invitation {
        id: row.try_get("", "id")?,
        email: row.try_get("", "email")?,
        role: stored_role(row)?,
        invited_by: row.try_get::<Option<i64>>("", "invited_by")?.map(UserId),
        created_at: row.try_get("", "created_at")?,
        expires_at: row.try_get("", "expires_at")?,
    })
}

pub async fn invitations(rt: &Runtime, access: &OrgAccess) -> ApiResult<Vec<Invitation>> {
    access.require_manage()?;
    let rows = rt
        .control
        .query_all_raw(sql(
            "SELECT id, email, role, invited_by, created_at, expires_at FROM invitations
             WHERE org_id = ? AND accepted_at IS NULL AND revoked_at IS NULL AND expires_at > ?
             ORDER BY created_at, id",
            vec![access.org.as_str().into(), now_secs().into()],
        ))
        .await?;
    rows.iter().map(invitation).collect()
}

/// Invites an address as `admin` or `member`. Replaces a pending invitation
/// for the same address. Requires a manager with a confirmed address.
pub async fn invite(
    rt: &Runtime,
    mail: &dyn AccountMail,
    access: &OrgAccess,
    email: &str,
    role: Role,
) -> ApiResult<Invitation> {
    access.require_manage()?;
    if role == Role::Owner {
        return Err(ApiError::BadRequest("invalid_role"));
    }
    let email = normalize_email(email)?;
    let inviter = rt
        .control
        .query_one_raw(sql(
            "SELECT confirmed_at FROM users WHERE id = ?",
            vec![access.user.0.into()],
        ))
        .await?
        .ok_or(ApiError::Unauthorized)?;
    if inviter
        .try_get::<Option<i64>>("", "confirmed_at")?
        .is_none()
    {
        return Err(ApiError::Conflict("email_not_confirmed"));
    }
    if !mail.configured() {
        return Err(MailFailure::NotConfigured.into());
    }
    let org = orgs::get(rt, access).await?;
    let now = now_secs();
    let org_id = access.org.as_str();
    let txn = rt.control.begin_with_options(immediate()).await?;
    let member = txn
        .query_one_raw(sql(
            "SELECT 1 FROM memberships m JOIN users u ON u.id = m.user_id WHERE m.org_id = ? AND u.email = ?",
            vec![org_id.into(), email.clone().into()],
        ))
        .await?;
    if member.is_some() {
        return Err(ApiError::Conflict("already_member"));
    }
    let recent = txn
        .query_one_raw(sql(
            "SELECT 1 FROM invitations WHERE org_id = ? AND email = ? AND created_at > ? LIMIT 1",
            vec![
                org_id.into(),
                email.clone().into(),
                (now - RESEND_INTERVAL_SECS).into(),
            ],
        ))
        .await?;
    if recent.is_some() {
        return Err(ApiError::Conflict("email_recently_sent"));
    }
    let pending: i64 = txn
        .query_one_raw(sql(
            "SELECT COUNT(*) AS n FROM invitations
             WHERE org_id = ? AND email <> ? AND accepted_at IS NULL AND revoked_at IS NULL AND expires_at > ?",
            vec![org_id.into(), email.clone().into(), now.into()],
        ))
        .await?
        .ok_or(ApiError::Internal("invitation count".into()))?
        .try_get("", "n")?;
    if pending >= MAX_PENDING_INVITATIONS {
        return Err(ApiError::Conflict("too_many_invitations"));
    }
    txn.execute_raw(sql(
        "UPDATE invitations SET revoked_at = ? WHERE org_id = ? AND email = ? AND accepted_at IS NULL AND revoked_at IS NULL",
        vec![now.into(), org_id.into(), email.clone().into()],
    ))
    .await?;
    let token = random_token();
    let row = txn
        .query_one_raw(sql(
            "INSERT INTO invitations (token_hash, org_id, email, role, invited_by, created_at, expires_at)
             VALUES (?, ?, ?, ?, ?, ?, ?)
             RETURNING id, email, role, invited_by, created_at, expires_at",
            vec![
                token_hash(&token).into(),
                org_id.into(),
                email.clone().into(),
                role.as_str().into(),
                access.user.0.into(),
                now.into(),
                (now + INVITATION_TTL_SECS).into(),
            ],
        ))
        .await?
        .ok_or(ApiError::Internal("invitation insert".into()))?;
    let created = invitation(&row)?;
    txn.commit().await?;
    let text = format!(
        "You are invited to join {} on PostDeploy as {}.\n\nSign in or create an account with this address, \
         confirm it, then open this link. It expires in 7 days.\n\n{}\n\nIf you did not expect this, ignore this email.\n",
        org.name,
        role.as_str(),
        link(rt, ACCEPT_INVITATION_PATH, &token),
    );
    let message = AccountMessage {
        to: email,
        subject: "You are invited to PostDeploy".to_owned(),
        text,
    };
    deliver_or_revoke(rt, mail, LinkRow::Invitation(created.id), message).await?;
    Ok(created)
}

pub async fn revoke_invitation(rt: &Runtime, access: &OrgAccess, id: i64) -> ApiResult<()> {
    access.require_manage()?;
    let revoked = rt
        .control
        .execute_raw(sql(
            "UPDATE invitations SET revoked_at = ?
             WHERE id = ? AND org_id = ? AND accepted_at IS NULL AND revoked_at IS NULL",
            vec![now_secs().into(), id.into(), access.org.as_str().into()],
        ))
        .await?;
    if revoked.rows_affected() == 0 {
        return Err(ApiError::NotFound);
    }
    Ok(())
}

/// Accepts an invitation for the signed-in account. The account address must
/// be confirmed and equal to the invited address; a mismatch leaves the token
/// usable by the right account.
pub async fn accept_invitation(
    rt: &Runtime,
    session: &Session,
    token: &AccountToken,
) -> ApiResult<OrgSummary> {
    let now = now_secs();
    let hash = token_hash(&token.0);
    let txn = rt.control.begin_with_options(immediate()).await?;
    let user = txn
        .query_one_raw(sql(
            "SELECT email, confirmed_at FROM users WHERE id = ?",
            vec![session.user.0.into()],
        ))
        .await?
        .ok_or(ApiError::Unauthorized)?;
    if user.try_get::<Option<i64>>("", "confirmed_at")?.is_none() {
        return Err(ApiError::Conflict("email_not_confirmed"));
    }
    let email: String = user.try_get("", "email")?;
    let accepted = txn
        .query_one_raw(sql(
            "UPDATE invitations SET accepted_at = ?, accepted_by = ?
             WHERE token_hash = ? AND email = ? AND accepted_at IS NULL AND revoked_at IS NULL AND expires_at > ?
             RETURNING org_id, role",
            vec![now.into(), session.user.0.into(), hash.clone().into(), email.into(), now.into()],
        ))
        .await?;
    let Some(accepted) = accepted else {
        let pending = txn
            .query_one_raw(sql(
                "SELECT 1 FROM invitations
                 WHERE token_hash = ? AND accepted_at IS NULL AND revoked_at IS NULL AND expires_at > ?",
                vec![hash.into(), now.into()],
            ))
            .await?;
        return Err(match pending {
            Some(_) => ApiError::Conflict("invitation_email_mismatch"),
            None => ApiError::NotFound,
        });
    };
    let org: String = accepted.try_get("", "org_id")?;
    let org: OrgId = org
        .parse()
        .map_err(|()| ApiError::Internal("stored organization id".into()))?;
    txn.execute_raw(sql(
        "INSERT INTO memberships (org_id, user_id, role, created_at) VALUES (?, ?, ?, ?)
         ON CONFLICT (org_id, user_id) DO NOTHING",
        vec![
            org.as_str().into(),
            session.user.0.into(),
            stored_role(&accepted)?.as_str().into(),
            now.into(),
        ],
    ))
    .await?;
    txn.commit().await?;
    orgs::get(rt, &authorize(rt, session.user, &org).await?).await
}

/// Deletes at most `limit` expired account tokens and unaccepted invitations.
/// Accepted invitations stay as membership history.
pub async fn sweep_tokens(rt: &Runtime, limit: i64) -> ApiResult<u64> {
    let now = now_secs();
    let tokens = rt
        .control
        .execute_raw(sql(
            "DELETE FROM account_tokens WHERE id IN
             (SELECT id FROM account_tokens WHERE expires_at <= ? ORDER BY expires_at LIMIT ?)",
            vec![now.into(), limit.into()],
        ))
        .await?;
    let invitations = rt
        .control
        .execute_raw(sql(
            "DELETE FROM invitations WHERE id IN
             (SELECT id FROM invitations WHERE expires_at <= ? AND accepted_at IS NULL ORDER BY expires_at LIMIT ?)",
            vec![now.into(), limit.into()],
        ))
        .await?;
    Ok(tokens.rows_affected() + invitations.rows_affected())
}
