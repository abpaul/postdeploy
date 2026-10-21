use std::{collections::HashMap, net::IpAddr, sync::Mutex, time::Duration};

use serde_json::{json, Value};
use subtle::ConstantTimeEq;

use crate::{
    agent_access::{Scope, ScopeSet},
    domain::Role,
    ingest::interfaces,
};

pub const PREAUTH_COOKIE: &str = "pd_preauth";
pub const RETURN_COOKIE: &str = "pd_return";
pub const FLASH_COOKIE: &str = "pd_flash";
pub const PREAUTH_MAX_AGE: u64 = 3600;
pub const RETURN_MAX_AGE: u64 = 600;

const PER_IP_LIMIT: u32 = 10;
const UNKNOWN_PEER_LIMIT: u32 = 5;
const GLOBAL_LIMIT: u32 = 100;
const WINDOW: Duration = Duration::from_secs(60);
const MAX_FRAMES: usize = 64;
const MAX_BREADCRUMBS: usize = 50;
const MAX_TEXT: usize = 200;

pub fn tokens_match(supplied: &str, expected: &str) -> bool {
    !expected.is_empty()
        && supplied.len() == expected.len()
        && bool::from(supplied.as_bytes().ct_eq(expected.as_bytes()))
}

pub fn origin_allowed(supplied: Option<&str>, expected: &str) -> bool {
    !expected.is_empty() && supplied == Some(expected)
}

pub fn fetch_site_allowed(site: Option<&str>) -> bool {
    site.is_none_or(|site| site == "same-origin" || site == "none")
}

pub fn cookie(name: &str, value: &str, max_age: u64, secure: bool) -> String {
    let secure = if secure { "; Secure" } else { "" };
    format!("{name}={value}; Path=/; HttpOnly; SameSite=Lax; Max-Age={max_age}{secure}")
}

/// Pages a signed-out visitor may return to after sign-in.
pub fn return_path(path_and_query: &str) -> Option<&str> {
    let allowed = [
        "/dashboard",
        "/oauth/authorize",
        "/confirm",
        "/invitations/accept",
    ]
    .iter()
    .any(|prefix| path_and_query.starts_with(prefix));
    (allowed && path_and_query.len() <= 2048 && relative_location(path_and_query).is_some())
        .then_some(path_and_query)
}

/// An authorization request to resume after the user creates an
/// organization.
pub fn agent_return(path_and_query: &str) -> Option<&str> {
    return_path(path_and_query).filter(|path| path.starts_with("/oauth/authorize?"))
}

pub fn relative_location(path: &str) -> Option<&str> {
    let safe = path.starts_with('/')
        && !path.starts_with("//")
        && path
            .bytes()
            .all(|b| b.is_ascii_graphic() && b != b'\\' && b != b'"' && b != b';');
    safe.then_some(path)
}

/// Accepts only an http(s) URL returned by the OAuth service: https, or http
/// to a loopback host.
pub fn client_redirect_target(url: &str) -> Option<&str> {
    if url.len() > 2048
        || url
            .bytes()
            .any(|b| !b.is_ascii_graphic() || b == b'\\' || b == b'"')
    {
        return None;
    }
    let parsed = url::Url::parse(url).ok()?;
    if !parsed.username().is_empty() || parsed.password().is_some() || parsed.host().is_none() {
        return None;
    }
    let loopback = match parsed.host()? {
        url::Host::Domain(host) => host == "localhost",
        url::Host::Ipv4(ip) => ip.is_loopback(),
        url::Host::Ipv6(ip) => ip.is_loopback(),
    };
    match parsed.scheme() {
        "https" => Some(url),
        "http" if loopback => Some(url),
        _ => None,
    }
}

pub enum ConsentDecision {
    Allow(ScopeSet),
    Deny,
}

/// Uses only the checked scopes. An empty Allow is rejected so the full
/// requested set is never granted by default.
pub fn consent_decision(decision: &str, scopes: &[&str]) -> Result<ConsentDecision, &'static str> {
    match decision {
        "deny" => Ok(ConsentDecision::Deny),
        "allow" => selected_scopes(scopes).map(ConsentDecision::Allow),
        _ => Err("invalid_decision"),
    }
}

fn selected_scopes(scopes: &[&str]) -> Result<ScopeSet, &'static str> {
    if scopes.is_empty() {
        return Err("empty_scope");
    }
    if scopes
        .iter()
        .any(|scope| scope.is_empty() || scope.contains(' '))
    {
        return Err("invalid_scope");
    }
    ScopeSet::parse(&scopes.join(" ")).ok_or("invalid_scope")
}

/// Consent and key creation preselect read access only.
pub fn scope_row(scope: Scope) -> Value {
    json!({
        "id": scope.as_str(),
        "label": scope_label(scope),
        "description": scope_description(scope),
        "checked": !scope.is_write(),
    })
}

/// Consent rows for every offered scope. Requested read scopes start
/// checked. With `create_projects`, `projects:write` starts checked too and is
/// worded as the client's ability to set up projects.
pub fn consent_rows(
    offered: &ScopeSet,
    requested: &ScopeSet,
    client: &str,
    create_projects: bool,
) -> Vec<Value> {
    Scope::ALL
        .into_iter()
        .filter(|scope| offered.contains(*scope))
        .map(|scope| {
            let mut row = scope_row(scope);
            let preselected = requested.contains(scope) && !scope.is_write();
            row["checked"] =
                json!(preselected || (create_projects && scope == Scope::ProjectsWrite));
            if scope == Scope::ProjectsWrite {
                row["label"] = json!(format!("Let {client} create projects and sources"));
            }
            row
        })
        .collect()
}

/// The scopes a member with `role` may put on an API key.
pub fn key_scope_rows(role: Role) -> Vec<Value> {
    Scope::ALL
        .into_iter()
        .filter(|scope| role.can_manage() || !scope.needs_manager())
        .map(scope_row)
        .collect()
}

pub fn scope_summary(scopes: &ScopeSet) -> String {
    Scope::ALL
        .into_iter()
        .filter(|scope| scopes.contains(*scope))
        .map(scope_label)
        .collect::<Vec<_>>()
        .join(", ")
}

fn scope_label(scope: Scope) -> &'static str {
    match scope {
        Scope::IssuesRead => "Read issues",
        Scope::IssuesTriage => "Triage issues",
        Scope::LogsRead => "Read logs",
        Scope::ProjectsRead => "Read projects",
        Scope::ProjectsWrite => "Change projects and sources",
        Scope::ReportsWrite => "Publish reports",
        Scope::DeploymentsWrite => "Record deployments",
    }
}

fn scope_description(scope: Scope) -> &'static str {
    match scope {
        Scope::IssuesRead => "View the issue inbox, event details, and stack traces.",
        Scope::IssuesTriage => "Resolve, ignore, and reopen issues.",
        Scope::LogsRead => "Search logs and follow a live tail.",
        Scope::ProjectsRead => "View projects and sources.",
        Scope::ProjectsWrite => "Create projects, sources, and ingestion keys.",
        Scope::ReportsWrite => "Publish an investigation report.",
        Scope::DeploymentsWrite => "Record a deployment of a project, for example from CI.",
    }
}

/// Field and message for a fixed service error code.
pub fn field_message(code: &str) -> Option<(&'static str, &'static str)> {
    Some(match code {
        "invalid_email" => ("email", "Enter a valid email address."),
        "email_taken" => ("email", "An account with that email already exists."),
        "email_unchanged" => ("email", "That is already your email address."),
        "email_recently_sent" => (
            "email",
            "A link was sent less than a minute ago. Wait, then try again.",
        ),
        "email_not_configured" => ("email", "Email is not available on this server."),
        "email_unavailable" => ("email", "The email could not be sent. Try again later."),
        "email_rejected" => ("email", "The mail server did not accept that address."),
        "already_member" => ("email", "That person is already on the team."),
        "too_many_invitations" => (
            "email",
            "This organization has 50 pending invitations. Revoke one first.",
        ),
        "email_not_confirmed" => ("email", "Confirm your email address first."),
        "invitation_email_mismatch" => (
            "invitation_token",
            "This invitation is for another email address.",
        ),
        "password_length" => ("password", "Use 12 to 256 characters."),
        "password_common" => (
            "password",
            "This password is too common. Choose a different password.",
        ),
        "password_breached" => (
            "password",
            "This password has appeared in a data breach. Choose a different password.",
        ),
        "password_mismatch" => ("password_confirmation", "Enter the same password twice."),
        "invalid_credentials" => ("password", "Email or password is wrong."),
        "invalid_name" => ("name", "Use 1 to 100 characters."),
        "organization_limit" => (
            "name",
            "You have created the maximum number of organizations.",
        ),
        "invalid_environment" => (
            "environment",
            "Use up to 32 lowercase letters, numbers, hyphens, or underscores.",
        ),
        "invalid_role" => ("role", "Choose member or admin."),
        "confirm_email" => ("confirm_email", "Type that member's email to confirm."),
        "use_transfer" => ("role", "Use Make owner to change ownership."),
        "last_owner" => ("role", "An organization needs at least one owner."),
        "self_transfer" => ("confirm_email", "You already own this organization."),
        "invalid_webhook_url" => ("url", "Enter an https URL."),
        "unsafe_webhook_url" => (
            "url",
            "That address is private or local. Use a public https endpoint.",
        ),
        "too_many_webhooks" => (
            "url",
            "This organization has the maximum number of webhooks.",
        ),
        "account_email_only" => (
            "email",
            "Email notifications go to your sign-in address. Change it on the Account page.",
        ),
        "empty_scope" => ("scopes", "Select at least one kind of access."),
        "invalid_scope" => ("scopes", "One of the selected access values is not valid."),
        "invalid_token" => (
            "token",
            "This link is not valid, has expired, or belongs to another account.",
        ),
        _ => return None,
    })
}

#[derive(Clone, Copy)]
struct Window {
    start_ms: u64,
    count: u32,
}

impl Window {
    const EMPTY: Self = Self {
        start_ms: 0,
        count: 0,
    };

    fn hit(self, now_ms: u64, limit: u32) -> (Window, bool) {
        let fresh = now_ms.saturating_sub(self.start_ms) >= WINDOW.as_millis() as u64;
        let window = if fresh {
            Window {
                start_ms: now_ms,
                count: 0,
            }
        } else {
            self
        };
        if window.count >= limit {
            (window, false)
        } else {
            (
                Window {
                    count: window.count + 1,
                    ..window
                },
                true,
            )
        }
    }
}

struct GateState {
    per_ip: HashMap<IpAddr, Window>,
    unknown: Window,
    global: Window,
}

/// Fixed-window limit for dynamic client registration: global and per client
/// address (`Web::peer`).
pub struct RegistrationGate {
    inner: Mutex<GateState>,
}

impl Default for RegistrationGate {
    fn default() -> Self {
        Self {
            inner: Mutex::new(GateState {
                per_ip: HashMap::new(),
                unknown: Window::EMPTY,
                global: Window::EMPTY,
            }),
        }
    }
}

impl RegistrationGate {
    /// `Ok` or the number of seconds to wait.
    pub fn allow(&self, now_ms: u64, peer: Option<IpAddr>) -> Result<(), u64> {
        let mut state = self.inner.lock().expect("registration limit lock");
        let local_ok = match peer {
            Some(ip) => {
                let current = state.per_ip.get(&ip).copied().unwrap_or(Window::EMPTY);
                let (window, ok) = current.hit(now_ms, PER_IP_LIMIT);
                state.per_ip.insert(ip, window);
                if state.per_ip.len() > 10_000 {
                    let horizon = WINDOW.as_millis() as u64;
                    state
                        .per_ip
                        .retain(|_, w| now_ms.saturating_sub(w.start_ms) < horizon);
                }
                ok
            }
            None => {
                let (window, ok) = state.unknown.hit(now_ms, UNKNOWN_PEER_LIMIT);
                state.unknown = window;
                ok
            }
        };
        if !local_ok {
            return Err(WINDOW.as_secs());
        }
        let (global, global_ok) = state.global.hit(now_ms, GLOBAL_LIMIT);
        state.global = global;
        if global_ok {
            Ok(())
        } else {
            Err(WINDOW.as_secs())
        }
    }
}

/// Maps a scrubbed SDK payload to the issue detail fields. Only an allowlist of
/// request headers is shown.
pub fn map_event(payload: &Value) -> Value {
    let frames = frames(payload);
    let raw_stack = frames
        .iter()
        .map(|frame| {
            let line = frame
                .get("lineno")
                .and_then(Value::as_i64)
                .map(|n| format!(":{n}"))
                .unwrap_or_default();
            format!(
                "{} {}{line}",
                frame["function"].as_str().unwrap_or(""),
                frame["filename"].as_str().unwrap_or("")
            )
        })
        .collect::<Vec<_>>()
        .join("\n");
    let exceptions = interfaces::values(payload, "exception");
    let stack_summary = exceptions
        .last()
        .map(|exception| {
            let kind = exception.get("type").and_then(Value::as_str).unwrap_or("");
            let value = exception.get("value").and_then(Value::as_str).unwrap_or("");
            clip(
                &[kind, value]
                    .iter()
                    .filter(|s| !s.is_empty())
                    .copied()
                    .collect::<Vec<_>>()
                    .join(": "),
            )
        })
        .filter(|summary| !summary.is_empty());
    let unhandled = exceptions
        .iter()
        .any(|e| e.pointer("/mechanism/handled").and_then(Value::as_bool) == Some(false));
    json!({
        "frames": frames,
        "event_breadcrumbs": breadcrumbs(payload),
        "release": payload.get("release").and_then(Value::as_str).map(clip),
        "trace_id": trace_id(payload),
        "request": request(payload),
        "stack_summary": stack_summary,
        "raw_stack": (!raw_stack.is_empty()).then_some(raw_stack),
        "unhandled": unhandled,
    })
}

fn trace_id(payload: &Value) -> Option<String> {
    payload
        .pointer("/contexts/trace/trace_id")
        .and_then(Value::as_str)
        .filter(|t| t.len() == 32 && t.bytes().all(|b| b.is_ascii_hexdigit()))
        .map(str::to_ascii_lowercase)
}

fn frames(payload: &Value) -> Vec<Value> {
    interfaces::primary_frames(payload)
        .iter()
        .rev()
        .take(MAX_FRAMES)
        .map(|frame| {
            let text = |key: &str| frame.get(key).and_then(Value::as_str).map(clip);
            let mut out = json!({
                "function": text("function").unwrap_or_default(),
                "filename": text("filename").or_else(|| text("module")).unwrap_or_default(),
                "in_app": frame.get("in_app").and_then(Value::as_bool).unwrap_or(false),
                "context": text("context_line").map(|line| line.trim().to_owned()),
            });
            if let Some(line) = frame.get("lineno").and_then(Value::as_i64) {
                out["lineno"] = json!(line);
            }
            out
        })
        .collect()
}

fn breadcrumbs(payload: &Value) -> Vec<Value> {
    interfaces::values(payload, "breadcrumbs")
        .iter()
        .rev()
        .take(MAX_BREADCRUMBS)
        .map(|crumb| {
            let at = match crumb.get("timestamp") {
                Some(Value::Number(n)) => n
                    .as_f64()
                    .and_then(|secs| chrono::DateTime::from_timestamp_micros((secs * 1e6) as i64))
                    .map(|t| t.format("%H:%M:%S").to_string())
                    .unwrap_or_default(),
                Some(Value::String(s)) => clip(s),
                _ => String::new(),
            };
            let text = |key: &str| {
                crumb
                    .get(key)
                    .and_then(Value::as_str)
                    .map(clip)
                    .unwrap_or_default()
            };
            json!({"at": at, "category": text("category"), "message": text("message")})
        })
        .collect()
}

fn request(payload: &Value) -> Value {
    let Some(request) = payload.get("request") else {
        return Value::Null;
    };
    let headers: Vec<Value> = request
        .get("headers")
        .and_then(Value::as_object)
        .map(|headers| {
            headers
                .iter()
                .filter(|(name, _)| {
                    matches!(
                        name.to_ascii_lowercase().as_str(),
                        "accept" | "accept-language" | "content-type" | "user-agent"
                    )
                })
                .filter_map(|(name, value)| {
                    value
                        .as_str()
                        .map(|v| json!({"name": name.to_ascii_lowercase(), "value": clip(v)}))
                })
                .collect()
        })
        .unwrap_or_default();
    let url = request
        .get("url")
        .and_then(Value::as_str)
        .map(|url| clip(url.split(['?', '#']).next().unwrap_or("")));
    let method = request
        .get("method")
        .and_then(Value::as_str)
        .map(clip)
        .unwrap_or_default();
    let url = url.unwrap_or_default();
    if method.is_empty() && url.is_empty() && headers.is_empty() {
        return Value::Null;
    }
    json!({ "method": method, "url": url, "headers": headers })
}

fn clip(value: &str) -> String {
    value.chars().take(MAX_TEXT).collect()
}

/// `YYYY-MM-DD`, `YYYY-MM-DD HH:MM`, or `YYYY-MM-DD HH:MM:SS` in UTC to
/// microseconds. A date or minute names its whole span when `end` is set.
pub fn parse_form_time(value: &str, end: bool) -> Option<i64> {
    let value = value.trim().replace('T', " ");
    let (text, span_us) = match value.len() {
        10 => (format!("{value} 00:00:00"), 86_400_000_000 - 1),
        16 => (format!("{value}:00"), 60_000_000 - 1),
        19 => (value, 1_000_000 - 1),
        _ => return None,
    };
    let parsed = chrono::NaiveDateTime::parse_from_str(&text, "%Y-%m-%d %H:%M:%S").ok()?;
    let start = parsed.and_utc().timestamp_micros();
    Some(if end { start + span_us } else { start })
}

pub fn format_micros(micros: i64) -> String {
    chrono::DateTime::from_timestamp_micros(micros)
        .map(|time| time.format("%Y-%m-%d %H:%M:%S UTC").to_string())
        .unwrap_or_default()
}

pub fn format_micros_iso(micros: i64) -> String {
    chrono::DateTime::from_timestamp_micros(micros)
        .map(|time| time.to_rfc3339_opts(chrono::SecondsFormat::Micros, true))
        .unwrap_or_default()
}

pub fn relative_micros(micros: i64) -> String {
    relative_micros_at(micros, crate::domain::now_micros())
}

fn relative_micros_at(micros: i64, now: i64) -> String {
    let seconds = now.saturating_sub(micros) / 1_000_000;
    match seconds {
        ..60 => "just now".into(),
        60..3_600 => ago(seconds / 60, "minute"),
        3_600..86_400 => ago(seconds / 3_600, "hour"),
        86_400..2_592_000 => ago(seconds / 86_400, "day"),
        _ => ago(seconds / 2_592_000, "month"),
    }
}

fn ago(count: i64, unit: &str) -> String {
    if count == 1 {
        format!("1 {unit} ago")
    } else {
        format!("{count} {unit}s ago")
    }
}

pub fn format_secs(secs: i64) -> String {
    chrono::DateTime::from_timestamp(secs, 0)
        .map(|time| time.format("%Y-%m-%d").to_string())
        .unwrap_or_default()
}

/// Minute resolution in UTC. `None` is a credential that has never authenticated.
pub fn format_last_used(secs: Option<i64>) -> String {
    match secs {
        None => "Never".into(),
        Some(secs) => chrono::DateTime::from_timestamp(secs, 0)
            .map(|time| time.format("%Y-%m-%d %H:%M UTC").to_string())
            .unwrap_or_default(),
    }
}

/// `a***@example.com`. Shows enough to recognise an address in a list.
pub fn mask_email(email: &str) -> String {
    match email.split_once('@') {
        Some((local, domain)) => {
            let first: String = local.chars().take(1).collect();
            format!("{first}***@{domain}")
        }
        None => "***".into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn relative_time_uses_the_largest_complete_unit() {
        let now = 3_000_000_000_000;
        assert_eq!(relative_micros_at(now - 59_000_000, now), "just now");
        assert_eq!(relative_micros_at(now - 60_000_000, now), "1 minute ago");
        assert_eq!(relative_micros_at(now - 7_200_000_000, now), "2 hours ago");
        assert_eq!(
            relative_micros_at(now - 2_592_000_000_000, now),
            "1 month ago"
        );
    }

    #[test]
    fn hidden_csrf_matches_only_the_same_token() {
        assert!(tokens_match("pd-token", "pd-token"));
        assert!(!tokens_match("pd-tokem", "pd-token"));
        assert!(!tokens_match("pd-token-extra", "pd-token"));
        assert!(!tokens_match("", "pd-token"));
        assert!(!tokens_match("", ""));
    }

    #[test]
    fn origin_must_equal_the_configured_origin() {
        assert!(origin_allowed(
            Some("https://postdeploy.dev"),
            "https://postdeploy.dev"
        ));
        assert!(!origin_allowed(None, "https://postdeploy.dev"));
        assert!(!origin_allowed(
            Some("https://evil.example"),
            "https://postdeploy.dev"
        ));
        assert!(!origin_allowed(
            Some("https://postdeploy.dev/"),
            "https://postdeploy.dev"
        ));
        assert!(fetch_site_allowed(None));
        assert!(fetch_site_allowed(Some("same-origin")));
        assert!(!fetch_site_allowed(Some("cross-site")));
        assert!(!fetch_site_allowed(Some("same-site")));
    }

    #[test]
    fn registration_limit_is_per_socket_and_global() {
        let gate = RegistrationGate::default();
        let ip: IpAddr = "203.0.113.9".parse().unwrap();
        let other: IpAddr = "203.0.113.10".parse().unwrap();
        for _ in 0..10 {
            assert_eq!(gate.allow(1_000, Some(ip)), Ok(()));
        }
        assert_eq!(gate.allow(1_000, Some(ip)), Err(60));
        assert_eq!(gate.allow(1_000, Some(other)), Ok(()));
        assert_eq!(gate.allow(61_000, Some(ip)), Ok(()));
        for _ in 0..5 {
            assert_eq!(gate.allow(61_000, None), Ok(()));
        }
        assert_eq!(gate.allow(61_000, None), Err(60));

        let global = RegistrationGate::default();
        for n in 0..100u32 {
            let peer = IpAddr::from([198, 51, (n / 200) as u8, (n % 200) as u8]);
            assert_eq!(global.allow(1_000, Some(peer)), Ok(()));
        }
        assert_eq!(
            global.allow(1_000, Some("192.0.2.1".parse().unwrap())),
            Err(60)
        );
    }

    #[test]
    fn allow_uses_only_the_checked_scopes() {
        let ConsentDecision::Allow(scopes) =
            consent_decision("allow", &["issues:read", "logs:read"]).unwrap()
        else {
            panic!("allow");
        };
        assert_eq!(scopes.to_string(), "issues:read logs:read");
        assert!(matches!(consent_decision("allow", &[]), Err("empty_scope")));
        assert!(matches!(
            consent_decision("allow", &["issues:read issues:triage"]),
            Err("invalid_scope")
        ));
        assert!(matches!(
            consent_decision("allow", &["admin"]),
            Err("invalid_scope")
        ));
        assert!(matches!(
            consent_decision("deny", &[]),
            Ok(ConsentDecision::Deny)
        ));
        assert!(matches!(
            consent_decision("maybe", &[]),
            Err("invalid_decision")
        ));
    }

    #[test]
    fn client_redirect_rejects_untrusted_targets() {
        assert!(client_redirect_target("https://client.example/callback?code=1").is_some());
        assert!(client_redirect_target("http://127.0.0.1:4317/callback").is_some());
        assert!(client_redirect_target("http://localhost/callback").is_some());
        assert!(client_redirect_target("http://[::1]:9/cb").is_some());
        assert!(client_redirect_target("javascript:alert(1)").is_none());
        assert!(client_redirect_target("https://user:pass@client.example/callback").is_none());
        assert!(client_redirect_target("http://evil.example/callback").is_none());
        assert!(client_redirect_target("http://127.0.0.1.evil.example/cb").is_none());
    }

    #[test]
    fn return_paths_stay_on_this_site() {
        assert_eq!(
            return_path("/oauth/authorize?client_id=pdi_1"),
            Some("/oauth/authorize?client_id=pdi_1")
        );
        assert_eq!(
            return_path("/confirm?token=abc"),
            Some("/confirm?token=abc")
        );
        assert_eq!(return_path("https://evil.example/oauth/authorize"), None);
        assert_eq!(return_path("//evil.example/dashboard"), None);
        assert_eq!(return_path("/sign-out"), None);
        assert_eq!(return_path("/dashboard\r\nSet-Cookie:x"), None);
        assert_eq!(
            agent_return("/oauth/authorize?client_id=pdi_1&state=x"),
            Some("/oauth/authorize?client_id=pdi_1&state=x")
        );
        assert_eq!(agent_return("/dashboard"), None);
        assert_eq!(agent_return("/oauth/authorize"), None);
        assert_eq!(agent_return("/oauth/authorizeX?client_id=1"), None);
        assert_eq!(
            agent_return("https://evil.example/oauth/authorize?a=1"),
            None
        );
        assert_eq!(agent_return("//evil.example/oauth/authorize?a=1"), None);
        assert_eq!(agent_return("/oauth/authorize?a=1\r\nSet-Cookie:x"), None);
        assert_eq!(relative_location("/dashboard"), Some("/dashboard"));
        assert_eq!(relative_location("//evil.example"), None);
    }

    #[test]
    fn event_view_uses_the_payload_and_drops_secret_headers() {
        let payload = json!({
            "release": "app@1",
            "contexts": {"trace": {"trace_id": "0123456789ABCDEF0123456789abcdef"}},
            "exception": {"values": [{
                "type": "TypeError",
                "value": "card declined",
                "mechanism": {"handled": false},
                "stacktrace": {"frames": [
                    {"function": "main", "filename": "src/main.rs", "lineno": 10, "in_app": true},
                    {"function": "charge", "filename": "src/pay.rs", "in_app": true, "context_line": "  charge()"}
                ]}
            }]},
            "breadcrumbs": {"values": [{"timestamp": "12:00", "category": "log", "message": "started"}]},
            "request": {"method": "POST", "url": "https://app.example/hook?token=secret", "headers": {
                "User-Agent": "test",
                "authorization": "secret",
                "cookie": "session"
            }}
        });
        let view = map_event(&payload);
        assert_eq!(view["frames"][0]["function"], "charge");
        assert!(view["frames"][0].get("lineno").is_none());
        assert_eq!(view["frames"][0]["context"], "charge()");
        assert_eq!(view["frames"][1]["lineno"], 10);
        assert_eq!(view["event_breadcrumbs"][0]["message"], "started");
        assert_eq!(view["release"], "app@1");
        assert_eq!(view["trace_id"], "0123456789abcdef0123456789abcdef");
        assert_eq!(view["stack_summary"], "TypeError: card declined");
        assert_eq!(view["unhandled"], true);
        assert_eq!(view["raw_stack"], "charge src/pay.rs\nmain src/main.rs:10");
        assert_eq!(view["request"]["url"], "https://app.example/hook");
        assert_eq!(
            view["request"]["headers"],
            json!([{"name": "user-agent", "value": "test"}])
        );
    }

    #[test]
    fn form_times_cover_their_whole_span() {
        assert_eq!(
            parse_form_time("2026-10-16", false),
            Some(1_792_108_800_000_000)
        );
        assert_eq!(
            parse_form_time("2026-10-16", true),
            Some(1_792_195_199_999_999)
        );
        assert_eq!(
            parse_form_time("2026-10-16 01:02", true),
            Some(1_792_112_579_999_999)
        );
        assert_eq!(parse_form_time("yesterday", false), None);
        assert_eq!(
            format_micros(1_792_108_800_000_000),
            "2026-10-16 00:00:00 UTC"
        );
        assert_eq!(mask_email("ana@example.com"), "a***@example.com");
    }
}
