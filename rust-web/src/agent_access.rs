//! OAuth 2.1 authorization for agent access to one organization.
//!
//! Public clients only: authorization code with mandatory PKCE S256, rotating
//! refresh tokens, and narrow dynamic client registration. The control database
//! stores SHA-256 hashes of every code, consent handle, and token.

use std::{collections::BTreeSet, fmt, net::IpAddr};

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use rand::RngCore;
use sea_orm::{
    ConnectionTrait, DatabaseConnection, DatabaseTransaction, DbBackend, DbErr,
    SqliteTransactionMode, Statement, TransactionOptions, TransactionTrait, Value,
};
use serde::{ser::SerializeStruct, Deserialize, Serialize, Serializer};
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;
use url::{Host, Url};

use crate::{
    domain::{now_secs, OrgId, Role, UserId},
    error::ApiError,
};

const MAX_REDIRECT_URIS: usize = 5;
const MAX_URI_BYTES: usize = 1024;
const MAX_CLIENT_NAME_CHARS: usize = 100;
const MAX_STATE_BYTES: usize = 512;
const STALE_CLIENT_BATCH: i64 = 100;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Scope {
    IssuesRead,
    IssuesTriage,
    LogsRead,
    ProjectsRead,
    ProjectsWrite,
    ReportsWrite,
    DeploymentsWrite,
}

impl Scope {
    pub const ALL: [Self; 7] = [
        Self::IssuesRead,
        Self::IssuesTriage,
        Self::LogsRead,
        Self::ProjectsRead,
        Self::ProjectsWrite,
        Self::ReportsWrite,
        Self::DeploymentsWrite,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::IssuesRead => "issues:read",
            Self::IssuesTriage => "issues:triage",
            Self::LogsRead => "logs:read",
            Self::ProjectsRead => "projects:read",
            Self::ProjectsWrite => "projects:write",
            Self::ReportsWrite => "reports:write",
            Self::DeploymentsWrite => "deployments:write",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|scope| scope.as_str() == value)
    }

    pub fn needs_manager(self) -> bool {
        match self {
            Self::IssuesTriage | Self::ProjectsWrite | Self::DeploymentsWrite => true,
            Self::IssuesRead | Self::LogsRead | Self::ProjectsRead | Self::ReportsWrite => false,
        }
    }

    pub fn is_write(self) -> bool {
        match self {
            Self::IssuesTriage
            | Self::ProjectsWrite
            | Self::ReportsWrite
            | Self::DeploymentsWrite => true,
            Self::IssuesRead | Self::LogsRead | Self::ProjectsRead => false,
        }
    }
}

/// A non-empty set of scopes. Serializes as the space-delimited OAuth form.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScopeSet(BTreeSet<Scope>);

impl ScopeSet {
    /// What a credential gets when nobody asked for specific access.
    pub fn read_only() -> Self {
        Self(
            Scope::ALL
                .into_iter()
                .filter(|scope| !scope.is_write())
                .collect(),
        )
    }

    pub fn parse(value: &str) -> Option<Self> {
        let scopes = value
            .split(' ')
            .map(Scope::parse)
            .collect::<Option<BTreeSet<_>>>()?;
        (!scopes.is_empty()).then_some(Self(scopes))
    }

    pub fn contains(&self, scope: Scope) -> bool {
        self.0.contains(&scope)
    }

    pub fn iter(&self) -> impl Iterator<Item = Scope> + '_ {
        self.0.iter().copied()
    }

    fn is_subset(&self, other: &Self) -> bool {
        self.0.is_subset(&other.0)
    }

    fn union(&self, other: &Self) -> Self {
        Self(self.0.union(&other.0).copied().collect())
    }

    fn intersection(&self, other: &Self) -> Option<Self> {
        let common: BTreeSet<Scope> = self.0.intersection(&other.0).copied().collect();
        (!common.is_empty()).then_some(Self(common))
    }
}

impl fmt::Display for ScopeSet {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        for (index, scope) in self.0.iter().enumerate() {
            if index > 0 {
                f.write_str(" ")?;
            }
            f.write_str(scope.as_str())?;
        }
        Ok(())
    }
}

impl Serialize for ScopeSet {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.collect_str(self)
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum SecretKind {
    Access,
    Refresh,
    Code,
    Consent,
    ApiKey,
}

impl SecretKind {
    fn prefix(self) -> &'static str {
        match self {
            Self::Access => "pda_",
            Self::Refresh => "pdr_",
            Self::Code => "pdc_",
            Self::Consent => "pdh_",
            Self::ApiKey => "pdk_",
        }
    }
}

const SECRET_BYTES: usize = 32;
const SECRET_CHARS: usize = 43;

/// A bearer secret: access token, refresh token, authorization code, consent
/// handle, or API key. Debug output is redacted. Only `expose` and the
/// `TokenResponse` and `CreatedApiKey` serializations reveal the value.
#[derive(Clone, PartialEq, Eq, Deserialize)]
#[serde(transparent)]
pub struct Secret(String);

impl From<String> for Secret {
    fn from(value: String) -> Self {
        Self(value)
    }
}

impl From<&str> for Secret {
    fn from(value: &str) -> Self {
        Self(value.to_owned())
    }
}

impl Secret {
    fn generate(kind: SecretKind) -> Self {
        Self(format!("{}{}", kind.prefix(), random_b64(SECRET_BYTES)))
    }

    fn parse(kind: SecretKind, raw: &str) -> Option<Self> {
        let body = raw.strip_prefix(kind.prefix())?;
        let valid = body.len() == SECRET_CHARS
            && body
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_');
        valid.then(|| Self(raw.to_owned()))
    }

    pub(crate) fn new_api_key() -> Self {
        Self::generate(SecretKind::ApiKey)
    }

    pub fn expose(&self) -> &str {
        &self.0
    }

    pub(crate) fn hash(&self) -> Vec<u8> {
        Sha256::digest(self.0.as_bytes()).to_vec()
    }
}

impl fmt::Debug for Secret {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Secret(<redacted>)")
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(transparent)]
pub struct ClientId(String);

impl ClientId {
    fn generate() -> Self {
        Self(format!("pdi_{}", random_b64(16)))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

fn random_b64(len: usize) -> String {
    let mut bytes = vec![0u8; len];
    rand::rng().fill_bytes(&mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
}

#[derive(Clone, Debug, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct OAuthConfig {
    /// Authorization server issuer, for example `https://postdeploy.dev`.
    pub issuer: String,
    /// Canonical protected resource, for example `https://postdeploy.dev/mcp`.
    pub resource: String,
    pub code_ttl_secs: i64,
    pub consent_ttl_secs: i64,
    pub access_ttl_secs: i64,
    pub refresh_ttl_secs: i64,
    /// Registered clients kept at once. Registration fails when full.
    pub max_clients: i64,
    /// A registered client with no grant, code, or consent is removed after this age.
    pub unused_client_secs: i64,
}

impl Default for OAuthConfig {
    fn default() -> Self {
        Self {
            issuer: String::new(),
            resource: String::new(),
            code_ttl_secs: 60,
            consent_ttl_secs: 600,
            access_ttl_secs: 15 * 60,
            refresh_ttl_secs: 7 * 24 * 3600,
            max_clients: 10_000,
            unused_client_secs: 24 * 3600,
        }
    }
}

impl OAuthConfig {
    pub fn validate(&self) -> Result<(), &'static str> {
        let issuer =
            Url::parse(&self.issuer).map_err(|_| "oauth.issuer must be an absolute URL")?;
        if !secure_origin(&issuer)
            || issuer.path() != "/"
            || self.issuer.ends_with('/')
            || issuer.query().is_some()
            || issuer.fragment().is_some()
        {
            return Err("oauth.issuer must be an https origin without a path");
        }
        let resource =
            Url::parse(&self.resource).map_err(|_| "oauth.resource must be an absolute URL")?;
        if !secure_origin(&resource) || resource.fragment().is_some() || resource.query().is_some()
        {
            return Err("oauth.resource must be an https URL without query or fragment");
        }
        let durations = [
            self.code_ttl_secs,
            self.consent_ttl_secs,
            self.access_ttl_secs,
            self.refresh_ttl_secs,
            self.unused_client_secs,
        ];
        if durations.iter().any(|secs| *secs <= 0) || self.max_clients <= 0 {
            return Err("oauth durations and max_clients must be positive");
        }
        Ok(())
    }

    fn endpoint(&self, path: &str) -> String {
        format!("{}{path}", self.issuer)
    }
}

fn secure_origin(url: &Url) -> bool {
    let no_userinfo = url.username().is_empty() && url.password().is_none();
    no_userinfo
        && match url.scheme() {
            "https" => url.host().is_some(),
            "http" => is_loopback(url),
            _ => false,
        }
}

fn is_loopback(url: &Url) -> bool {
    match url.host() {
        Some(Host::Domain(domain)) => domain == "localhost",
        Some(Host::Ipv4(ip)) => IpAddr::V4(ip).is_loopback(),
        Some(Host::Ipv6(ip)) => IpAddr::V6(ip).is_loopback(),
        None => false,
    }
}

fn valid_redirect(raw: &str) -> bool {
    if raw.len() > MAX_URI_BYTES
        || !raw.bytes().all(|b| b.is_ascii_graphic())
        || raw.contains('*')
        || raw.contains('#')
    {
        return false;
    }
    Url::parse(raw).is_ok_and(|url| secure_origin(&url))
}

fn valid_challenge(value: &str) -> bool {
    value.len() == SECRET_CHARS
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

fn valid_verifier(value: &str) -> bool {
    (43..=128).contains(&value.len())
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-._~".contains(&b))
}

fn pkce_matches(verifier: &str, challenge: &str) -> bool {
    let computed = URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));
    computed.as_bytes().ct_eq(challenge.as_bytes()).into()
}

/// OAuth error codes. Every variant except `Internal` maps to an RFC 6749,
/// 7591, or 8707 `error` value.
#[derive(Debug, PartialEq, Eq, thiserror::Error)]
pub enum OAuthError {
    #[error("invalid_request")]
    InvalidRequest,
    #[error("invalid_client")]
    InvalidClient,
    #[error("invalid_grant")]
    InvalidGrant,
    #[error("invalid_scope")]
    InvalidScope,
    #[error("invalid_target")]
    InvalidTarget,
    #[error("unsupported_grant_type")]
    UnsupportedGrantType,
    #[error("unsupported_response_type")]
    UnsupportedResponseType,
    #[error("invalid_redirect_uri")]
    InvalidRedirectUri,
    #[error("invalid_client_metadata")]
    InvalidClientMetadata,
    #[error("access_denied")]
    AccessDenied,
    #[error("temporarily_unavailable")]
    TemporarilyUnavailable,
    #[error("internal: {0}")]
    Internal(String),
}

impl OAuthError {
    pub fn code(&self) -> &'static str {
        match self {
            Self::InvalidRequest => "invalid_request",
            Self::InvalidClient => "invalid_client",
            Self::InvalidGrant => "invalid_grant",
            Self::InvalidScope => "invalid_scope",
            Self::InvalidTarget => "invalid_target",
            Self::UnsupportedGrantType => "unsupported_grant_type",
            Self::UnsupportedResponseType => "unsupported_response_type",
            Self::InvalidRedirectUri => "invalid_redirect_uri",
            Self::InvalidClientMetadata => "invalid_client_metadata",
            Self::AccessDenied => "access_denied",
            Self::TemporarilyUnavailable => "temporarily_unavailable",
            Self::Internal(_) => "server_error",
        }
    }
}

impl From<DbErr> for OAuthError {
    fn from(error: DbErr) -> Self {
        Self::Internal(format!("database: {error}"))
    }
}

impl From<OAuthError> for ApiError {
    fn from(error: OAuthError) -> Self {
        match error {
            OAuthError::Internal(cause) => Self::Internal(cause),
            OAuthError::TemporarilyUnavailable => Self::Unavailable("temporarily_unavailable"),
            other => Self::BadRequest(other.code()),
        }
    }
}

/// Bearer authentication failure. `Invalid` is HTTP 401. `NoMembership` is
/// HTTP 403: the token is live but its user left the organization.
#[derive(Debug, PartialEq, Eq, thiserror::Error)]
pub enum BearerError {
    #[error("invalid bearer token")]
    Invalid,
    #[error("membership removed")]
    NoMembership,
    #[error("internal: {0}")]
    Internal(String),
}

impl From<DbErr> for BearerError {
    fn from(error: DbErr) -> Self {
        Self::Internal(format!("database: {error}"))
    }
}

impl From<BearerError> for ApiError {
    fn from(error: BearerError) -> Self {
        match error {
            BearerError::Invalid => Self::Unauthorized,
            BearerError::NoMembership => Self::Forbidden,
            BearerError::Internal(cause) => Self::Internal(cause),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Credential {
    OAuthGrant(i64),
    ApiKey(i64),
}

/// A live bearer credential for one user in one organization. It holds no
/// role: callers load the current role with every request and pass it to
/// [`AgentPrincipal::permits`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AgentPrincipal {
    pub user: UserId,
    pub org: OrgId,
    pub scopes: ScopeSet,
    pub credential: Credential,
}

const LAST_USE_INTERVAL_SECS: i64 = 60;

pub async fn authenticate(
    oauth: &OAuthService,
    bearer: &str,
) -> Result<AgentPrincipal, BearerError> {
    let principal = match Secret::parse(SecretKind::ApiKey, bearer) {
        Some(key) => crate::api_keys::authenticate(&oauth.db, &key).await,
        None => oauth.authenticate(bearer).await,
    }?;
    record_last_used(&oauth.db, principal.credential).await;
    Ok(principal)
}

/// Writes the observation at most once a minute. A failed write leaves the
/// credential usable: the caller already proved the bearer is valid.
async fn record_last_used(db: &DatabaseConnection, credential: Credential) {
    let now = now_secs();
    let cutoff = now.saturating_sub(LAST_USE_INTERVAL_SECS);
    let (statement, id) = match credential {
        Credential::OAuthGrant(id) => (
            "UPDATE oauth_grants SET last_used_at = ?
             WHERE id = ? AND revoked_at IS NULL
               AND (last_used_at IS NULL OR last_used_at < ?)",
            id,
        ),
        Credential::ApiKey(id) => (
            "UPDATE agent_api_keys SET last_used_at = ?
             WHERE id = ? AND revoked_at IS NULL
               AND (last_used_at IS NULL OR last_used_at < ?)",
            id,
        ),
    };
    if let Err(error) = db
        .execute_raw(stmt(statement, [now.into(), id.into(), cutoff.into()]))
        .await
    {
        tracing::warn!(%error, "agent last use was not recorded");
    }
}

#[derive(Debug, Serialize)]
pub struct GrantSummary {
    pub id: i64,
    pub user_id: UserId,
    pub email: String,
    pub client_name: Option<String>,
    pub scopes: ScopeSet,
    pub created_at: i64,
    pub last_used_at: Option<i64>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Denied {
    MissingScope(Scope),
    Role,
}

impl AgentPrincipal {
    /// Every scope in `required` must be granted, and manager scopes need a
    /// manager `role`.
    pub fn permits(&self, required: &[Scope], role: Role) -> Result<(), Denied> {
        for scope in required {
            if !self.scopes.contains(*scope) {
                return Err(Denied::MissingScope(*scope));
            }
            if scope.needs_manager() && !role.can_manage() {
                return Err(Denied::Role);
            }
        }
        Ok(())
    }
}

#[derive(Debug, Serialize)]
pub struct AuthorizationServerMetadata {
    pub issuer: String,
    pub authorization_endpoint: String,
    pub token_endpoint: String,
    pub revocation_endpoint: String,
    pub registration_endpoint: String,
    pub response_types_supported: [&'static str; 1],
    pub grant_types_supported: [&'static str; 2],
    pub code_challenge_methods_supported: [&'static str; 1],
    pub token_endpoint_auth_methods_supported: [&'static str; 1],
    pub revocation_endpoint_auth_methods_supported: [&'static str; 1],
    pub scopes_supported: Vec<&'static str>,
    pub authorization_response_iss_parameter_supported: bool,
}

#[derive(Debug, Serialize)]
pub struct ProtectedResourceMetadata {
    pub resource: String,
    pub authorization_servers: [String; 1],
    pub scopes_supported: Vec<&'static str>,
    pub bearer_methods_supported: [&'static str; 1],
}

/// RFC 7591 registration request. Unknown metadata is ignored and never fetched.
#[derive(Debug, Default, Deserialize)]
pub struct ClientRegistration {
    #[serde(default)]
    pub redirect_uris: Vec<String>,
    #[serde(default)]
    pub client_name: Option<String>,
    #[serde(default)]
    pub token_endpoint_auth_method: Option<String>,
    #[serde(default)]
    pub grant_types: Option<Vec<String>>,
    #[serde(default)]
    pub response_types: Option<Vec<String>>,
    #[serde(default)]
    pub scope: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct RegisteredClient {
    pub client_id: ClientId,
    pub client_id_issued_at: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub client_name: Option<String>,
    pub redirect_uris: Vec<String>,
    pub grant_types: [&'static str; 2],
    pub response_types: [&'static str; 1],
    pub token_endpoint_auth_method: &'static str,
    pub scope: ScopeSet,
}

#[derive(Debug, Default, Deserialize)]
pub struct AuthorizeRequest {
    pub response_type: Option<String>,
    pub client_id: Option<String>,
    pub redirect_uri: Option<String>,
    pub code_challenge: Option<String>,
    pub code_challenge_method: Option<String>,
    pub scope: Option<String>,
    pub state: Option<String>,
    pub resource: Option<String>,
}

/// A valid authorization request, for a user who can or cannot consent yet.
#[derive(Debug)]
pub enum Consent {
    /// Nothing is stored. The same request starts a consent once the user
    /// belongs to an organization.
    NoOrganization,
    Ready(ConsentPrompt),
}

/// Data for the consent screen. `handle` goes into the CSRF-protected consent
/// form and is valid once, for the same signed-in user. `requested` is what
/// the client asked for; the user may approve any part of `offered`.
#[derive(Debug)]
pub struct ConsentPrompt {
    pub handle: Secret,
    pub client_id: ClientId,
    pub client_name: Option<String>,
    pub redirect_uri: String,
    pub requested: ScopeSet,
    pub offered: ScopeSet,
    pub organizations: Vec<OrgChoice>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OrgChoice {
    pub id: OrgId,
    pub name: String,
    pub role: Role,
}

#[derive(Debug, Default, Deserialize)]
pub struct TokenForm {
    pub grant_type: Option<String>,
    pub client_id: Option<String>,
    pub code: Option<Secret>,
    pub redirect_uri: Option<String>,
    pub code_verifier: Option<Secret>,
    pub refresh_token: Option<Secret>,
    pub resource: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
pub struct RevokeForm {
    pub token: Option<Secret>,
    pub token_type_hint: Option<String>,
    pub client_id: Option<String>,
}

/// The one place that serializes token plaintext, for the token endpoint body.
#[derive(Debug)]
pub struct TokenResponse {
    pub access_token: Secret,
    pub refresh_token: Secret,
    pub expires_in: i64,
    pub scope: ScopeSet,
}

impl Serialize for TokenResponse {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut body = serializer.serialize_struct("TokenResponse", 5)?;
        body.serialize_field("access_token", self.access_token.expose())?;
        body.serialize_field("token_type", "Bearer")?;
        body.serialize_field("expires_in", &self.expires_in)?;
        body.serialize_field("refresh_token", self.refresh_token.expose())?;
        body.serialize_field("scope", &self.scope)?;
        body.end()
    }
}

#[derive(Clone)]
pub struct OAuthService {
    db: DatabaseConnection,
    config: OAuthConfig,
}

impl OAuthService {
    pub fn new(db: DatabaseConnection, config: OAuthConfig) -> Result<Self, &'static str> {
        config.validate()?;
        Ok(Self { db, config })
    }

    pub fn authorization_server_metadata(&self) -> AuthorizationServerMetadata {
        AuthorizationServerMetadata {
            issuer: self.config.issuer.clone(),
            authorization_endpoint: self.config.endpoint("/oauth/authorize"),
            token_endpoint: self.config.endpoint("/oauth/token"),
            revocation_endpoint: self.config.endpoint("/oauth/revoke"),
            registration_endpoint: self.config.endpoint("/oauth/register"),
            response_types_supported: ["code"],
            grant_types_supported: ["authorization_code", "refresh_token"],
            code_challenge_methods_supported: ["S256"],
            token_endpoint_auth_methods_supported: ["none"],
            revocation_endpoint_auth_methods_supported: ["none"],
            scopes_supported: Scope::ALL.map(Scope::as_str).to_vec(),
            authorization_response_iss_parameter_supported: true,
        }
    }

    pub fn protected_resource_metadata(&self) -> ProtectedResourceMetadata {
        ProtectedResourceMetadata {
            resource: self.config.resource.clone(),
            authorization_servers: [self.config.issuer.clone()],
            scopes_supported: Scope::ALL.map(Scope::as_str).to_vec(),
            bearer_methods_supported: ["header"],
        }
    }

    /// Registers a public client. Registration grants no organization access.
    pub async fn register_client(
        &self,
        request: ClientRegistration,
    ) -> Result<RegisteredClient, OAuthError> {
        if request.redirect_uris.is_empty()
            || request.redirect_uris.len() > MAX_REDIRECT_URIS
            || !request.redirect_uris.iter().all(|uri| valid_redirect(uri))
        {
            return Err(OAuthError::InvalidRedirectUri);
        }
        let name_ok = request.client_name.as_deref().is_none_or(|name| {
            !name.trim().is_empty()
                && name.chars().count() <= MAX_CLIENT_NAME_CHARS
                && !name.chars().any(char::is_control)
        });
        let auth_ok = request
            .token_endpoint_auth_method
            .as_deref()
            .is_none_or(|method| method == "none");
        let grants_ok = request.grant_types.as_ref().is_none_or(|grants| {
            grants.iter().any(|grant| grant == "authorization_code")
                && grants
                    .iter()
                    .all(|grant| grant == "authorization_code" || grant == "refresh_token")
        });
        let responses_ok = request
            .response_types
            .as_ref()
            .is_none_or(|types| types.iter().all(|t| t == "code") && !types.is_empty());
        let scopes = match request.scope.as_deref() {
            None => Some(ScopeSet::read_only()),
            Some(scope) => ScopeSet::parse(scope),
        };
        let (true, true, true, true, Some(scopes)) =
            (name_ok, auth_ok, grants_ok, responses_ok, scopes)
        else {
            return Err(OAuthError::InvalidClientMetadata);
        };

        let now = now_secs();
        let client_id = ClientId::generate();
        let redirect_json = serde_json::to_string(&request.redirect_uris)
            .map_err(|error| OAuthError::Internal(format!("encode redirects: {error}")))?;
        let tx = self.begin().await?;
        if self.client_count(&tx).await? >= self.config.max_clients {
            tx.execute_raw(stmt(
                "DELETE FROM oauth_clients WHERE id IN (
                    SELECT c.id FROM oauth_clients c
                    WHERE c.created_at <= ?
                      AND NOT EXISTS (SELECT 1 FROM oauth_grants g WHERE g.client_id = c.id)
                      AND NOT EXISTS (SELECT 1 FROM oauth_codes k WHERE k.client_id = c.id)
                      AND NOT EXISTS (SELECT 1 FROM oauth_consents p WHERE p.client_id = c.id)
                    ORDER BY c.created_at LIMIT ?)",
                [
                    (now - self.config.unused_client_secs).into(),
                    STALE_CLIENT_BATCH.into(),
                ],
            ))
            .await?;
            if self.client_count(&tx).await? >= self.config.max_clients {
                tx.commit().await?;
                return Err(OAuthError::TemporarilyUnavailable);
            }
        }
        tx.execute_raw(stmt(
            "INSERT INTO oauth_clients (id, name, redirect_uris, scopes, created_at)
             VALUES (?, ?, ?, ?, ?)",
            [
                client_id.as_str().into(),
                request.client_name.clone().into(),
                redirect_json.into(),
                scopes.to_string().into(),
                now.into(),
            ],
        ))
        .await?;
        tx.commit().await?;
        Ok(RegisteredClient {
            client_id,
            client_id_issued_at: now,
            client_name: request.client_name,
            redirect_uris: request.redirect_uris,
            grant_types: ["authorization_code", "refresh_token"],
            response_types: ["code"],
            token_endpoint_auth_method: "none",
            scope: scopes,
        })
    }

    /// The name a registered client gave, if any.
    pub async fn client_name(&self, client_id: &str) -> Result<Option<String>, OAuthError> {
        let row = self
            .db
            .query_one_raw(stmt(
                "SELECT name FROM oauth_clients WHERE id = ?",
                [client_id.into()],
            ))
            .await?;
        Ok(match row {
            Some(row) => row.try_get_by_index(0)?,
            None => None,
        })
    }

    /// Validates an authorization request for the signed-in `user` and, when
    /// the user belongs to an organization, stores a pending consent. Errors
    /// here must be shown to the user, not redirected.
    ///
    /// The user may grant every scope their role allows in one of their
    /// organizations, beyond what the client requested. Manager scopes are
    /// still checked against the role on every request.
    pub async fn begin_consent(
        &self,
        user: UserId,
        request: AuthorizeRequest,
    ) -> Result<Consent, OAuthError> {
        let client_id = request.client_id.ok_or(OAuthError::InvalidRequest)?;
        let Some(client) = self
            .db
            .query_one_raw(stmt(
                "SELECT name, redirect_uris, scopes FROM oauth_clients WHERE id = ?",
                [client_id.clone().into()],
            ))
            .await?
        else {
            return Err(OAuthError::InvalidClient);
        };
        let client_name: Option<String> = client.try_get_by_index(0)?;
        let registered: Vec<String> = serde_json::from_str(&client.try_get_by_index::<String>(1)?)
            .map_err(|error| OAuthError::Internal(format!("decode redirects: {error}")))?;
        let client_scopes = parse_stored_scopes(&client.try_get_by_index::<String>(2)?)?;

        let redirect_uri = request.redirect_uri.ok_or(OAuthError::InvalidRequest)?;
        if !registered.contains(&redirect_uri) {
            return Err(OAuthError::InvalidRedirectUri);
        }
        if request.response_type.as_deref() != Some("code") {
            return Err(OAuthError::UnsupportedResponseType);
        }
        let challenge = request.code_challenge.ok_or(OAuthError::InvalidRequest)?;
        if request.code_challenge_method.as_deref() != Some("S256") || !valid_challenge(&challenge)
        {
            return Err(OAuthError::InvalidRequest);
        }
        if request.resource.as_deref() != Some(self.config.resource.as_str()) {
            return Err(OAuthError::InvalidTarget);
        }
        let scopes = match request.scope.as_deref() {
            None => client_scopes
                .intersection(&ScopeSet::read_only())
                .ok_or(OAuthError::InvalidScope)?,
            Some(scope) => ScopeSet::parse(scope).ok_or(OAuthError::InvalidScope)?,
        };
        if !scopes.is_subset(&client_scopes) {
            return Err(OAuthError::InvalidScope);
        }
        if request
            .state
            .as_deref()
            .is_some_and(|state| state.len() > MAX_STATE_BYTES)
        {
            return Err(OAuthError::InvalidRequest);
        }

        let organizations = self
            .db
            .query_all_raw(stmt(
                "SELECT o.id, o.name, m.role FROM memberships m
                 JOIN organizations o ON o.id = m.org_id
                 WHERE m.user_id = ? ORDER BY o.name, o.id",
                [user.0.into()],
            ))
            .await?
            .iter()
            .map(|row| {
                Ok(OrgChoice {
                    id: parse_org(&row.try_get_by_index::<String>(0)?)?,
                    name: row.try_get_by_index(1)?,
                    role: parse_role(&row.try_get_by_index::<String>(2)?)?,
                })
            })
            .collect::<Result<Vec<_>, OAuthError>>()?;
        if organizations.is_empty() {
            return Ok(Consent::NoOrganization);
        }
        let manages_any = organizations.iter().any(|org| org.role.can_manage());
        let grantable = ScopeSet(
            Scope::ALL
                .into_iter()
                .filter(|scope| manages_any || !scope.needs_manager())
                .collect(),
        );
        let offered = scopes.union(&grantable);

        let handle = Secret::generate(SecretKind::Consent);
        self.db
            .execute_raw(stmt(
                "INSERT INTO oauth_consents
                 (handle_hash, user_id, client_id, redirect_uri, code_challenge, scopes, state, resource, expires_at)
                 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                [
                    handle.hash().into(),
                    user.0.into(),
                    client_id.clone().into(),
                    redirect_uri.clone().into(),
                    challenge.into(),
                    offered.to_string().into(),
                    request.state.into(),
                    self.config.resource.clone().into(),
                    (now_secs() + self.config.consent_ttl_secs).into(),
                ],
            ))
            .await?;
        Ok(Consent::Ready(ConsentPrompt {
            handle,
            client_id: ClientId(client_id),
            client_name,
            redirect_uri,
            requested: scopes,
            offered,
            organizations,
        }))
    }

    /// Approves `scopes`, a part of the offered scopes, for one organization
    /// in which `user` is a current member. Returns the client redirect URL
    /// carrying the code.
    pub async fn approve_consent(
        &self,
        user: UserId,
        handle: &str,
        org: &OrgId,
        scopes: ScopeSet,
    ) -> Result<String, OAuthError> {
        let handle =
            Secret::parse(SecretKind::Consent, handle).ok_or(OAuthError::InvalidRequest)?;
        let now = now_secs();
        let tx = self.begin().await?;
        if !has_membership(&tx, user, org).await? {
            return Err(OAuthError::AccessDenied);
        }
        let consent = take_consent(&tx, &handle, user).await?;
        if consent.expires_at <= now {
            tx.commit().await?;
            return Err(OAuthError::InvalidRequest);
        }
        let offered = parse_stored_scopes(&consent.scopes)?;
        if !scopes.is_subset(&offered) {
            return Err(OAuthError::InvalidScope);
        }
        let code = Secret::generate(SecretKind::Code);
        tx.execute_raw(stmt(
            "INSERT INTO oauth_codes
             (code_hash, client_id, user_id, org_id, redirect_uri, code_challenge, scopes, resource, expires_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [
                code.hash().into(),
                consent.client_id.into(),
                user.0.into(),
                org.as_str().into(),
                consent.redirect_uri.clone().into(),
                consent.code_challenge.into(),
                scopes.to_string().into(),
                consent.resource.into(),
                (now + self.config.code_ttl_secs).into(),
            ],
        ))
        .await?;
        tx.commit().await?;
        self.redirect(
            &consent.redirect_uri,
            &[("code", code.expose())],
            consent.state.as_deref(),
        )
    }

    /// Discards a pending consent and returns the `access_denied` redirect URL.
    pub async fn deny_consent(&self, user: UserId, handle: &str) -> Result<String, OAuthError> {
        let handle =
            Secret::parse(SecretKind::Consent, handle).ok_or(OAuthError::InvalidRequest)?;
        let tx = self.begin().await?;
        let consent = take_consent(&tx, &handle, user).await?;
        tx.commit().await?;
        if consent.expires_at <= now_secs() {
            return Err(OAuthError::InvalidRequest);
        }
        self.redirect(
            &consent.redirect_uri,
            &[("error", "access_denied")],
            consent.state.as_deref(),
        )
    }

    pub async fn token(&self, form: TokenForm) -> Result<TokenResponse, OAuthError> {
        match form.grant_type.as_deref() {
            Some("authorization_code") => self.exchange_code(form).await,
            Some("refresh_token") => self.rotate_refresh(form).await,
            Some(_) => Err(OAuthError::UnsupportedGrantType),
            None => Err(OAuthError::InvalidRequest),
        }
    }

    /// Redeems an authorization code once. A replayed code revokes the grant
    /// it produced. Any other mismatch deletes the code.
    pub async fn exchange_code(&self, form: TokenForm) -> Result<TokenResponse, OAuthError> {
        let (Some(client_id), Some(code), Some(redirect_uri), Some(verifier), Some(resource)) = (
            form.client_id,
            form.code,
            form.redirect_uri,
            form.code_verifier,
            form.resource,
        ) else {
            return Err(OAuthError::InvalidRequest);
        };
        if !valid_verifier(verifier.expose()) {
            return Err(OAuthError::InvalidRequest);
        }
        if resource != self.config.resource {
            return Err(OAuthError::InvalidTarget);
        }
        let code =
            Secret::parse(SecretKind::Code, code.expose()).ok_or(OAuthError::InvalidGrant)?;
        let code_hash = code.hash();
        let now = now_secs();
        let tx = self.begin().await?;
        let Some(row) = tx
            .query_one_raw(stmt(
                "SELECT client_id, user_id, org_id, redirect_uri, code_challenge, scopes, resource,
                        expires_at, grant_id
                 FROM oauth_codes WHERE code_hash = ?",
                [code_hash.clone().into()],
            ))
            .await?
        else {
            return Err(OAuthError::InvalidGrant);
        };
        if let Some(grant_id) = row.try_get_by_index::<Option<i64>>(8)? {
            revoke_grant(&tx, grant_id, now).await?;
            tx.commit().await?;
            return Err(OAuthError::InvalidGrant);
        }
        let user = UserId(row.try_get_by_index(1)?);
        let org = parse_org(&row.try_get_by_index::<String>(2)?)?;
        let scopes = parse_stored_scopes(&row.try_get_by_index::<String>(5)?)?;
        let valid = row.try_get_by_index::<String>(0)? == client_id
            && row.try_get_by_index::<String>(3)? == redirect_uri
            && pkce_matches(verifier.expose(), &row.try_get_by_index::<String>(4)?)
            && row.try_get_by_index::<String>(6)? == resource
            && row.try_get_by_index::<i64>(7)? > now
            && has_membership(&tx, user, &org).await?;
        if !valid {
            tx.execute_raw(stmt(
                "DELETE FROM oauth_codes WHERE code_hash = ?",
                [code_hash.into()],
            ))
            .await?;
            tx.commit().await?;
            return Err(OAuthError::InvalidGrant);
        }
        let grant_id: i64 = tx
            .query_one_raw(stmt(
                "INSERT INTO oauth_grants (client_id, user_id, org_id, scopes, resource, created_at)
                 VALUES (?, ?, ?, ?, ?, ?) RETURNING id",
                [
                    client_id.into(),
                    user.0.into(),
                    org.as_str().into(),
                    scopes.to_string().into(),
                    resource.into(),
                    now.into(),
                ],
            ))
            .await?
            .ok_or_else(|| OAuthError::Internal("grant insert returned no id".into()))?
            .try_get_by_index(0)?;
        tx.execute_raw(stmt(
            "UPDATE oauth_codes SET grant_id = ? WHERE code_hash = ?",
            [grant_id.into(), code_hash.into()],
        ))
        .await?;
        let response = self.issue_tokens(&tx, grant_id, scopes, now).await?;
        tx.commit().await?;
        Ok(response)
    }

    /// Rotates a refresh token. Reuse of a rotated refresh token revokes the
    /// whole grant family.
    pub async fn rotate_refresh(&self, form: TokenForm) -> Result<TokenResponse, OAuthError> {
        let (Some(client_id), Some(refresh)) = (form.client_id, form.refresh_token) else {
            return Err(OAuthError::InvalidRequest);
        };
        if form
            .resource
            .is_some_and(|resource| resource != self.config.resource)
        {
            return Err(OAuthError::InvalidTarget);
        }
        let refresh =
            Secret::parse(SecretKind::Refresh, refresh.expose()).ok_or(OAuthError::InvalidGrant)?;
        let now = now_secs();
        let tx = self.begin().await?;
        let Some(row) = tx
            .query_one_raw(stmt(
                "SELECT t.grant_id, t.expires_at, t.rotated_at, g.client_id, g.user_id, g.org_id,
                        g.scopes, g.revoked_at
                 FROM oauth_tokens t JOIN oauth_grants g ON g.id = t.grant_id
                 WHERE t.token_hash = ? AND t.kind = 'refresh'",
                [refresh.hash().into()],
            ))
            .await?
        else {
            return Err(OAuthError::InvalidGrant);
        };
        let grant_id: i64 = row.try_get_by_index(0)?;
        if row.try_get_by_index::<String>(3)? != client_id
            || row.try_get_by_index::<Option<i64>>(7)?.is_some()
        {
            return Err(OAuthError::InvalidGrant);
        }
        if row.try_get_by_index::<Option<i64>>(2)?.is_some() {
            revoke_grant(&tx, grant_id, now).await?;
            tx.commit().await?;
            return Err(OAuthError::InvalidGrant);
        }
        let user = UserId(row.try_get_by_index(4)?);
        let org = parse_org(&row.try_get_by_index::<String>(5)?)?;
        if row.try_get_by_index::<i64>(1)? <= now || !has_membership(&tx, user, &org).await? {
            return Err(OAuthError::InvalidGrant);
        }
        let scopes = parse_stored_scopes(&row.try_get_by_index::<String>(6)?)?;
        tx.execute_raw(stmt(
            "UPDATE oauth_tokens SET rotated_at = ? WHERE token_hash = ?",
            [now.into(), refresh.hash().into()],
        ))
        .await?;
        let response = self.issue_tokens(&tx, grant_id, scopes, now).await?;
        tx.commit().await?;
        Ok(response)
    }

    /// RFC 7009 revocation. Revoking an access or refresh token revokes its
    /// grant family. Unknown tokens and tokens of another client succeed
    /// without effect.
    pub async fn revoke(&self, form: RevokeForm) -> Result<(), OAuthError> {
        let (Some(token), Some(client_id)) = (form.token, form.client_id) else {
            return Err(OAuthError::InvalidRequest);
        };
        let Some(secret) = Secret::parse(SecretKind::Access, token.expose())
            .or_else(|| Secret::parse(SecretKind::Refresh, token.expose()))
        else {
            return Ok(());
        };
        self.db
            .execute_raw(stmt(
                "UPDATE oauth_grants SET revoked_at = ?
                 WHERE revoked_at IS NULL AND client_id = ?
                   AND id = (SELECT grant_id FROM oauth_tokens WHERE token_hash = ?)",
                [now_secs().into(), client_id.into(), secret.hash().into()],
            ))
            .await?;
        Ok(())
    }

    /// Resolves an OAuth access token. DSN keys and refresh tokens never match.
    async fn authenticate(&self, bearer: &str) -> Result<AgentPrincipal, BearerError> {
        let token = Secret::parse(SecretKind::Access, bearer).ok_or(BearerError::Invalid)?;
        let row = self
            .db
            .query_one_raw(stmt(
                "SELECT g.id, g.user_id, g.org_id, g.scopes, g.resource, m.role
                 FROM oauth_tokens t
                 JOIN oauth_grants g ON g.id = t.grant_id
                 LEFT JOIN memberships m ON m.org_id = g.org_id AND m.user_id = g.user_id
                 WHERE t.token_hash = ? AND t.kind = 'access' AND t.expires_at > ?
                   AND g.revoked_at IS NULL",
                [token.hash().into(), now_secs().into()],
            ))
            .await?
            .ok_or(BearerError::Invalid)?;
        if row.try_get_by_index::<String>(4)? != self.config.resource {
            return Err(BearerError::Invalid);
        }
        if row.try_get_by_index::<Option<String>>(5)?.is_none() {
            return Err(BearerError::NoMembership);
        }
        let internal = |error: OAuthError| BearerError::Internal(error.to_string());
        Ok(AgentPrincipal {
            user: UserId(row.try_get_by_index(1)?),
            org: parse_org(&row.try_get_by_index::<String>(2)?).map_err(internal)?,
            scopes: parse_stored_scopes(&row.try_get_by_index::<String>(3)?).map_err(internal)?,
            credential: Credential::OAuthGrant(row.try_get_by_index(0)?),
        })
    }

    pub async fn grants(
        &self,
        user: UserId,
        org: &OrgId,
        before: Option<i64>,
        limit: u32,
    ) -> Result<Vec<GrantSummary>, OAuthError> {
        let role = self.dashboard_role(user, org).await?;
        let rows = self
            .db
            .query_all_raw(stmt(
                "SELECT g.id, g.user_id, u.email, c.name, g.scopes, g.created_at, g.last_used_at
             FROM oauth_grants g JOIN oauth_clients c ON c.id = g.client_id
             JOIN users u ON u.id = g.user_id
             WHERE g.org_id = ? AND g.revoked_at IS NULL AND (? OR g.user_id = ?)
               AND g.id < ? ORDER BY g.id DESC LIMIT ?",
                [
                    org.as_str().into(),
                    role.can_manage().into(),
                    user.0.into(),
                    before.unwrap_or(i64::MAX).into(),
                    i64::from(limit.clamp(1, 100)).into(),
                ],
            ))
            .await?;
        rows.into_iter()
            .map(|row| {
                Ok(GrantSummary {
                    id: row.try_get_by_index(0)?,
                    user_id: UserId(row.try_get_by_index(1)?),
                    email: row.try_get_by_index(2)?,
                    client_name: row.try_get_by_index(3)?,
                    scopes: parse_stored_scopes(&row.try_get_by_index::<String>(4)?)?,
                    created_at: row.try_get_by_index(5)?,
                    last_used_at: row.try_get_by_index(6)?,
                })
            })
            .collect()
    }

    pub async fn revoke_dashboard_grant(
        &self,
        user: UserId,
        org: &OrgId,
        grant: i64,
    ) -> Result<(), OAuthError> {
        let tx = self.begin().await?;
        let role = tx
            .query_one_raw(stmt(
                "SELECT role FROM memberships WHERE user_id = ? AND org_id = ?",
                [user.0.into(), org.as_str().into()],
            ))
            .await?
            .ok_or(OAuthError::AccessDenied)?;
        let role = parse_role(&role.try_get_by_index::<String>(0)?)?;
        let result = tx
            .execute_raw(stmt(
                "UPDATE oauth_grants SET revoked_at = COALESCE(revoked_at, ?)
             WHERE id = ? AND org_id = ? AND (? OR user_id = ?)",
                [
                    now_secs().into(),
                    grant.into(),
                    org.as_str().into(),
                    role.can_manage().into(),
                    user.0.into(),
                ],
            ))
            .await?;
        if result.rows_affected() != 1 {
            return Err(OAuthError::AccessDenied);
        }
        tx.commit().await?;
        Ok(())
    }

    async fn dashboard_role(&self, user: UserId, org: &OrgId) -> Result<Role, OAuthError> {
        let row = self
            .db
            .query_one_raw(stmt(
                "SELECT role FROM memberships WHERE user_id = ? AND org_id = ?",
                [user.0.into(), org.as_str().into()],
            ))
            .await?
            .ok_or(OAuthError::AccessDenied)?;
        parse_role(&row.try_get_by_index::<String>(0)?)
    }

    /// Deletes expired and dead OAuth rows, at most `batch` rows per statement.
    /// Each statement commits on its own. Returns the number of deleted rows.
    pub async fn sweep(&self, batch: i64) -> Result<u64, OAuthError> {
        let now = now_secs();
        let statements = [
            stmt(
                "DELETE FROM oauth_codes WHERE code_hash IN (
                    SELECT code_hash FROM oauth_codes WHERE expires_at <= ? LIMIT ?)",
                [now.into(), batch.into()],
            ),
            stmt(
                "DELETE FROM oauth_consents WHERE handle_hash IN (
                    SELECT handle_hash FROM oauth_consents WHERE expires_at <= ? LIMIT ?)",
                [now.into(), batch.into()],
            ),
            stmt(
                "DELETE FROM oauth_tokens WHERE token_hash IN (
                    SELECT token_hash FROM oauth_tokens WHERE expires_at <= ? LIMIT ?)",
                [now.into(), batch.into()],
            ),
            stmt(
                "DELETE FROM oauth_tokens WHERE token_hash IN (
                    SELECT t.token_hash FROM oauth_tokens t
                    JOIN oauth_grants g ON g.id = t.grant_id
                    WHERE g.revoked_at IS NOT NULL LIMIT ?)",
                [batch.into()],
            ),
            stmt(
                "DELETE FROM oauth_grants WHERE id IN (
                    SELECT g.id FROM oauth_grants g
                    WHERE NOT EXISTS (SELECT 1 FROM oauth_tokens t WHERE t.grant_id = g.id)
                    LIMIT ?)",
                [batch.into()],
            ),
            stmt(
                "DELETE FROM oauth_clients WHERE id IN (
                    SELECT c.id FROM oauth_clients c
                    WHERE c.created_at <= ?
                      AND NOT EXISTS (SELECT 1 FROM oauth_grants g WHERE g.client_id = c.id)
                      AND NOT EXISTS (SELECT 1 FROM oauth_codes k WHERE k.client_id = c.id)
                      AND NOT EXISTS (SELECT 1 FROM oauth_consents p WHERE p.client_id = c.id)
                    LIMIT ?)",
                [(now - self.config.unused_client_secs).into(), batch.into()],
            ),
        ];
        let mut deleted = 0;
        for statement in statements {
            deleted += self.db.execute_raw(statement).await?.rows_affected();
        }
        Ok(deleted)
    }

    async fn begin(&self) -> Result<DatabaseTransaction, DbErr> {
        self.db
            .begin_with_options(TransactionOptions {
                sqlite_transaction_mode: Some(SqliteTransactionMode::Immediate),
                ..TransactionOptions::default()
            })
            .await
    }

    async fn client_count(&self, tx: &DatabaseTransaction) -> Result<i64, OAuthError> {
        let row = tx
            .query_one_raw(stmt("SELECT COUNT(*) FROM oauth_clients", []))
            .await?
            .ok_or_else(|| OAuthError::Internal("count returned no row".into()))?;
        Ok(row.try_get_by_index(0)?)
    }

    async fn issue_tokens(
        &self,
        tx: &DatabaseTransaction,
        grant_id: i64,
        scopes: ScopeSet,
        now: i64,
    ) -> Result<TokenResponse, OAuthError> {
        let access = Secret::generate(SecretKind::Access);
        let refresh = Secret::generate(SecretKind::Refresh);
        tx.execute_raw(stmt(
            "INSERT INTO oauth_tokens (token_hash, grant_id, kind, expires_at)
             VALUES (?, ?, 'access', ?), (?, ?, 'refresh', ?)",
            [
                access.hash().into(),
                grant_id.into(),
                (now + self.config.access_ttl_secs).into(),
                refresh.hash().into(),
                grant_id.into(),
                (now + self.config.refresh_ttl_secs).into(),
            ],
        ))
        .await?;
        Ok(TokenResponse {
            access_token: access,
            refresh_token: refresh,
            expires_in: self.config.access_ttl_secs,
            scope: scopes,
        })
    }

    fn redirect(
        &self,
        redirect_uri: &str,
        params: &[(&str, &str)],
        state: Option<&str>,
    ) -> Result<String, OAuthError> {
        let mut url = Url::parse(redirect_uri)
            .map_err(|error| OAuthError::Internal(format!("stored redirect: {error}")))?;
        {
            let mut query = url.query_pairs_mut();
            query.extend_pairs(params);
            if let Some(state) = state {
                query.append_pair("state", state);
            }
            query.append_pair("iss", &self.config.issuer);
        }
        Ok(url.into())
    }
}

struct PendingConsent {
    client_id: String,
    redirect_uri: String,
    code_challenge: String,
    scopes: String,
    state: Option<String>,
    resource: String,
    expires_at: i64,
}

async fn take_consent(
    tx: &DatabaseTransaction,
    handle: &Secret,
    user: UserId,
) -> Result<PendingConsent, OAuthError> {
    let row = tx
        .query_one_raw(stmt(
            "DELETE FROM oauth_consents WHERE handle_hash = ? AND user_id = ?
             RETURNING client_id, redirect_uri, code_challenge, scopes, state, resource, expires_at",
            [handle.hash().into(), user.0.into()],
        ))
        .await?
        .ok_or(OAuthError::InvalidRequest)?;
    Ok(PendingConsent {
        client_id: row.try_get_by_index(0)?,
        redirect_uri: row.try_get_by_index(1)?,
        code_challenge: row.try_get_by_index(2)?,
        scopes: row.try_get_by_index(3)?,
        state: row.try_get_by_index(4)?,
        resource: row.try_get_by_index(5)?,
        expires_at: row.try_get_by_index(6)?,
    })
}

async fn has_membership(
    tx: &DatabaseTransaction,
    user: UserId,
    org: &OrgId,
) -> Result<bool, OAuthError> {
    Ok(tx
        .query_one_raw(stmt(
            "SELECT 1 FROM memberships WHERE org_id = ? AND user_id = ?",
            [org.as_str().into(), user.0.into()],
        ))
        .await?
        .is_some())
}

async fn revoke_grant(tx: &DatabaseTransaction, grant_id: i64, now: i64) -> Result<(), DbErr> {
    tx.execute_raw(stmt(
        "UPDATE oauth_grants SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL",
        [now.into(), grant_id.into()],
    ))
    .await?;
    Ok(())
}

fn stmt<const N: usize>(sql: &str, values: [Value; N]) -> Statement {
    Statement::from_sql_and_values(DbBackend::Sqlite, sql, values)
}

fn parse_org(value: &str) -> Result<OrgId, OAuthError> {
    value
        .parse()
        .map_err(|()| OAuthError::Internal("stored organization id is invalid".into()))
}

fn parse_role(value: &str) -> Result<Role, OAuthError> {
    Role::parse(value).ok_or_else(|| OAuthError::Internal("stored role is invalid".into()))
}

fn parse_stored_scopes(value: &str) -> Result<ScopeSet, OAuthError> {
    ScopeSet::parse(value).ok_or_else(|| OAuthError::Internal("stored scopes are invalid".into()))
}
