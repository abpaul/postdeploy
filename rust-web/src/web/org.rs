use axum::{body::Bytes, extract::Path, http::StatusCode, response::IntoResponse};
use serde_json::{json, Value};

use crate::{
    account_settings::{self, TeamMember},
    agent_access::OAuthError,
    api_keys::{self, NewApiKey},
    domain::{Role, UserId},
    error::{ApiError, ApiResult},
    identity::{
        orgs,
        projects::{self, PageRequest},
    },
    ingest::policy as ingest_policy,
    notifications::{DestinationId, DestinationView, EmailSubscription, EventKind, WebhookInput},
    onboarding::{self, Agent, Onboarding, Setup, Step, StepState},
};

use super::{
    page::{
        form_error, initial, project_path, project_row, redirect, role_label, Fields, Flash, OrgCx,
        Page, Web, WebError, WebResult,
    },
    policy,
    project::open_issue_count,
};

const EVENTS: [EventKind; 3] = [
    EventKind::IssueNew,
    EventKind::IssueRegression,
    EventKind::ReportPublished,
];

fn outcome(web: &Web, target: &str, result: ApiResult<()>, done: &str) -> WebResult {
    match result {
        Ok(()) => Ok(web.redirect_flash(target, Flash::Info, done)),
        Err(error) => Ok(web.redirect_flash(target, Flash::Error, form_error(error)?.1)),
    }
}

fn checklist(cx: &OrgCx, onboarding: &Onboarding) -> Vec<Value> {
    let paths = match onboarding.setup {
        Setup::NoSource { project } => Some((project_path(&cx.org.id, project), None)),
        Setup::AwaitingFirstEvent { project, source } => {
            Some((project_path(&cx.org.id, project), Some(source)))
        }
        Setup::NoProject | Setup::Receiving => None,
    };
    onboarding
        .steps()
        .into_iter()
        .map(|(step, state)| {
            let (key, title, description, href) = match step {
                Step::Organization => ("organization", "Create an organization", "Your team's workspace.", String::new()),
                Step::Project => ("project", "Create a project", "A project groups the errors and logs of one application. You or your agent can create it.", "#onboarding-paths".to_owned()),
                Step::Source => ("source", "Create a source", "A source gives you the DSN that your Sentry SDK sends errors and logs to.", paths.as_ref().map_or(String::new(), |(project, _)| format!("{project}/sources"))),
                Step::FirstEvent => ("first-event", "Receive the first event", "Send a test event or deploy with the DSN.", match &paths {
                    Some((project, Some(source))) => format!("{project}/sources/{}", source.0),
                    _ => String::new(),
                }),
                Step::Agent => ("agent", "Connect an agent", "An agent investigates issues and logs, then publishes a report.", format!("{}/settings#org-agent-connection", cx.base)),
            };
            let state = match state {
                StepState::Done => "done",
                StepState::Current => "current",
                StepState::Todo => "todo",
            };
            json!({"key": key, "title": title, "description": description, "state": state, "href": href})
        })
        .collect()
}

async fn projects_page(web: &Web, cx: &OrgCx) -> WebResult<Page> {
    let mut page = web.org_page(cx, "Projects", "projects");
    let mut rows = Vec::new();
    for project in &cx.projects {
        let open = open_issue_count(&web.rt, &cx.access, project.id).await?;
        rows.push(project_row(&cx.org.id, project, Some(open)));
    }
    page.set("projects", rows)
        .set("form_action", format!("{}/projects", cx.base))
        .set("show_project_form", false);
    let onboarding = onboarding::load(&web.rt, &cx.access, &cx.projects).await?;
    if !onboarding.is_done() {
        let steps = checklist(cx, &onboarding);
        let done = steps.iter().filter(|step| step["state"] == "done").count();
        page.set("checklist", steps).set("checklist_done", done);
    }
    if onboarding.setup == Setup::NoProject {
        let url = &web.rt.settings.oauth.resource;
        page.set("mcp_url", url.as_str())
            .set("agent_commands", json!([
                {"id": "claude", "label": "Claude Code", "command": format!("claude mcp add --transport http postdeploy {url}")},
                {"id": "codex", "label": "Codex", "command": format!("codex mcp add postdeploy --url {url}")},
            ]))
            .set("agent_can_create", onboarding.agent == Agent::CanCreateProjects);
    }
    Ok(page)
}

pub async fn projects(web: Web, Path(org): Path<String>) -> WebResult {
    let cx = web.member(&org).await?;
    let page = projects_page(&web, &cx).await?;
    Ok(web.render(page, "projects/index.html"))
}

pub async fn create_project(web: Web, Path(org): Path<String>, body: Bytes) -> WebResult {
    let fields = Fields::parse(&body);
    let cx = web.member_form(&org, &fields).await?;
    match projects::create(&web.rt, &cx.access, fields.get("name")).await {
        Ok(project) => {
            let target = format!("{}/sources", project_path(&cx.org.id, project.id));
            Ok(web.redirect_flash(
                &target,
                Flash::Info,
                "Project created. Create a source to get its DSN.",
            ))
        }
        Err(error) => {
            let (field, message) = form_error(error)?;
            let mut page = projects_page(&web, &cx).await?;
            page.set("show_project_form", true).invalid(
                field,
                message,
                json!({"name": fields.get("name")}),
            );
            Ok(web.render(page, "projects/index.html"))
        }
    }
}

fn member_rows(cx: &OrgCx, members: &[TeamMember]) -> Vec<Value> {
    let manage = cx.access.role.can_manage();
    let owner = cx.access.role == Role::Owner;
    members
        .iter()
        .map(|member| {
            let you = member.user_id == cx.access.user;
            let path = format!("{}/team/{}", cx.base, member.user_id.0);
            let action = |allowed: bool, verb: &str| {
                if allowed {
                    format!("{path}/{verb}")
                } else {
                    String::new()
                }
            };
            let editable = manage && !you && member.role != Role::Owner;
            json!({
                "id": member.user_id.0,
                "name": member.name,
                "email": member.email,
                "initial": initial(member.name.as_deref().unwrap_or(&member.email)),
                "role": member.role.as_str(),
                "role_label": role_label(member.role),
                "you": you,
                "joined": policy::format_secs(member.joined_at),
                "role_action": action(editable, "role"),
                "remove_action": action(editable, "remove"),
                "transfer_action": action(owner && !you, "transfer"),
            })
        })
        .collect()
}

async fn team_page(web: &Web, cx: &OrgCx) -> WebResult<Page> {
    let mut page = web.org_page(cx, "Team", "team");
    let members = account_settings::team(&web.rt, &cx.access).await?;
    let invitations = if cx.access.role.can_manage() {
        account_settings::invitations(&web.rt, &cx.access).await?
    } else {
        Vec::new()
    };
    let invitation_rows: Vec<Value> = invitations
        .iter()
        .map(|invitation| {
            json!({
                "email": invitation.email,
                "role_label": role_label(invitation.role),
                "sent_at": policy::format_secs(invitation.created_at),
                "revoke_action": format!("{}/team/invitations/{}/revoke", cx.base, invitation.id),
            })
        })
        .collect();
    let mut stats = vec![json!({"label": "Members", "value": members.len()})];
    if cx.access.role.can_manage() {
        stats.push(json!({"label": "Pending invitations", "value": invitations.len()}));
    }
    page.set("members", member_rows(cx, &members))
        .set("invitations", invitation_rows)
        .set("team_stats", stats)
        .set("show_invite", false)
        .set("form_action", format!("{}/team", cx.base));
    Ok(page)
}

pub async fn team(web: Web, Path(org): Path<String>) -> WebResult {
    let cx = web.member(&org).await?;
    let page = team_page(&web, &cx).await?;
    Ok(web.render(page, "team/index.html"))
}

pub async fn invite(web: Web, Path(org): Path<String>, body: Bytes) -> WebResult {
    let fields = Fields::parse(&body);
    let cx = web.member_form(&org, &fields).await?;
    let role = match fields.get("role") {
        "admin" => Some(Role::Admin),
        "member" => Some(Role::Member),
        _ => None,
    };
    let result = match role {
        Some(role) => account_settings::invite(
            &web.rt,
            web.svc.account_mail.as_ref(),
            &cx.access,
            fields.get("email"),
            role,
        )
        .await
        .map(|_| ()),
        None => Err(ApiError::BadRequest("invalid_role")),
    };
    match result {
        Ok(()) => Ok(web.redirect_flash(
            &format!("{}/team", cx.base),
            Flash::Info,
            "Invitation sent.",
        )),
        Err(error) => {
            let (field, message) = form_error(error)?;
            let mut page = team_page(&web, &cx).await?;
            page.set("show_invite", true).invalid(
                field,
                message,
                json!({"email": fields.get("email"), "role": fields.get("role")}),
            );
            Ok(web.render(page, "team/index.html"))
        }
    }
}

pub async fn set_role(web: Web, Path((org, user)): Path<(String, i64)>, body: Bytes) -> WebResult {
    let fields = Fields::parse(&body);
    let cx = web.member_form(&org, &fields).await?;
    let result = match Role::parse(fields.get("role")) {
        Some(role) => {
            account_settings::set_member_role(&web.rt, &cx.access, UserId(user), role).await
        }
        None => Err(ApiError::BadRequest("invalid_role")),
    };
    outcome(&web, &format!("{}/team", cx.base), result, "Role saved.")
}

async fn confirmed_member(
    web: &Web,
    cx: &OrgCx,
    user: i64,
    fields: &Fields,
) -> WebResult<Result<TeamMember, ApiError>> {
    let member = account_settings::team(&web.rt, &cx.access)
        .await?
        .into_iter()
        .find(|m| m.user_id.0 == user)
        .ok_or(WebError::NotFound)?;
    let typed = fields.get("confirm_email").trim();
    Ok(if typed.eq_ignore_ascii_case(&member.email) {
        Ok(member)
    } else {
        Err(ApiError::BadRequest("confirm_email"))
    })
}

pub async fn remove_member(
    web: Web,
    Path((org, user)): Path<(String, i64)>,
    body: Bytes,
) -> WebResult {
    let fields = Fields::parse(&body);
    let cx = web.member_form(&org, &fields).await?;
    let result = match confirmed_member(&web, &cx, user, &fields).await? {
        Ok(member) => orgs::remove_member(&web.rt, &cx.access, member.user_id).await,
        Err(error) => Err(error),
    };
    outcome(
        &web,
        &format!("{}/team", cx.base),
        result,
        "Member removed.",
    )
}

pub async fn transfer(web: Web, Path((org, user)): Path<(String, i64)>, body: Bytes) -> WebResult {
    let fields = Fields::parse(&body);
    let cx = web.member_form(&org, &fields).await?;
    let result = match confirmed_member(&web, &cx, user, &fields).await? {
        Ok(member) => {
            account_settings::transfer_ownership(&web.rt, &cx.access, member.user_id).await
        }
        Err(error) => Err(error),
    };
    outcome(
        &web,
        &format!("{}/team", cx.base),
        result,
        "Ownership transferred. You are now an admin.",
    )
}

pub async fn revoke_invitation(
    web: Web,
    Path((org, id)): Path<(String, i64)>,
    body: Bytes,
) -> WebResult {
    let fields = Fields::parse(&body);
    let cx = web.member_form(&org, &fields).await?;
    let result = account_settings::revoke_invitation(&web.rt, &cx.access, id).await;
    outcome(
        &web,
        &format!("{}/team", cx.base),
        result,
        "Invitation revoked.",
    )
}

/// Connected agents of the organization. Members see their own grants;
/// owners and admins see all of them.
pub async fn grant_rows(web: &Web, cx: &OrgCx, revoke_base: &str) -> WebResult<Vec<Value>> {
    let grants = web
        .svc
        .oauth
        .grants(cx.access.user, &cx.access.org, None, 100)
        .await
        .map_err(oauth_error)?;
    Ok(grants
        .iter()
        .map(|grant| {
            json!({
                "id": grant.id,
                "client_name": grant.client_name.as_deref().unwrap_or("Unnamed agent"),
                "account": grant.email,
                "access": policy::scope_summary(&grant.scopes),
                "last_used_at": policy::format_last_used(grant.last_used_at),
                "connected_at": policy::format_secs(grant.created_at),
                "revoke_action": format!("{revoke_base}/{}/revoke", grant.id),
            })
        })
        .collect())
}

pub fn oauth_error(error: OAuthError) -> WebError {
    match error {
        OAuthError::AccessDenied => WebError::NotFound,
        OAuthError::TemporarilyUnavailable => WebError::Unavailable,
        other => ApiError::from(other).into(),
    }
}

pub fn agent_setup(web: &Web, page: &mut Page) {
    let endpoint = &web.rt.settings.oauth.resource;
    let setup = serde_json::to_string_pretty(
        &json!({"mcpServers": {"postdeploy": {"type": "http", "url": endpoint}}}),
    )
    .unwrap_or_default();
    page.set("mcp_endpoint", endpoint.as_str())
        .set("agent_setup", setup);
}

async fn settings_page(web: &Web, cx: &OrgCx) -> WebResult<Page> {
    let mut page = web.org_page(cx, "Settings", "settings");
    let members = account_settings::team(&web.rt, &cx.access).await?;
    let preview: Vec<Value> = member_rows(cx, &members).into_iter().take(5).collect();
    let grants = grant_rows(web, cx, &format!("{}/access/grants", cx.base)).await?;
    page.set("scope_role", role_label(cx.access.role))
        .set(
            "name_action",
            if cx.access.role.can_manage() {
                format!("{}/settings/name", cx.base)
            } else {
                String::new()
            },
        )
        .set("delete_action", if cx.access.role == Role::Owner { format!("{}/delete", cx.base) } else { String::new() })
        .set("organization", json!({"id": cx.org.id.as_str(), "name": cx.org.name, "initial": initial(&cx.org.name), "created_at": policy::format_secs(cx.org.created_at)}))
        .set("members", preview)
        .set("grants", grants)
        .set("api_key_action", format!("{}/settings/api-keys", cx.base))
        .set("api_key_scopes", policy::key_scope_rows(cx.access.role))
        .set("api_keys", api_key_rows(web, cx).await?);
    agent_setup(web, &mut page);
    Ok(page)
}

/// Unrevoked API keys: the member's own, or every key for a manager.
async fn api_key_rows(web: &Web, cx: &OrgCx) -> WebResult<Vec<Value>> {
    let (keys, _) =
        api_keys::list(&web.rt, &cx.access, &PageRequest::new(None, Some(100))?).await?;
    Ok(keys
        .iter()
        .map(|key| {
            json!({
                "id": key.id,
                "name": key.name,
                "hint": key.hint,
                "account": key.email,
                "access": policy::scope_summary(&key.scopes),
                "expires_at": policy::format_secs(key.expires_at),
                "last_used_at": policy::format_last_used(key.last_used_at),
                "revoke_action": format!("{}/settings/api-keys/{}/revoke", cx.base, key.id),
            })
        })
        .collect())
}

fn key_form_error(error: ApiError) -> Result<(&'static str, &'static str), WebError> {
    match error {
        ApiError::BadRequest("invalid_name") => Ok(("key_name", "Use 1 to 100 characters.")),
        ApiError::BadRequest("invalid_scope") => {
            Ok(("key_scopes", "Select at least one kind of access."))
        }
        ApiError::BadRequest("invalid_expiry") => Ok(("key_expiry", "Use 1 to 90 days.")),
        ApiError::Conflict("api_key_limit") => Ok((
            "key_name",
            "You have 50 active keys here. Revoke one to create another.",
        )),
        other => Err(other.into()),
    }
}

pub async fn create_api_key(web: Web, Path(org): Path<String>, body: Bytes) -> WebResult {
    let fields = Fields::parse(&body);
    let cx = web.member_form(&org, &fields).await?;
    let expiry = fields.get("expires_in_days").trim();
    let result = match expiry {
        "" => Ok(None),
        days => days
            .parse::<i64>()
            .map(Some)
            .map_err(|_| ApiError::BadRequest("invalid_expiry")),
    };
    let result = match result {
        Ok(expires_in_days) => {
            let input = NewApiKey {
                name: fields.get("key_name").to_owned(),
                scopes: Some(
                    fields
                        .all("scopes")
                        .into_iter()
                        .map(str::to_owned)
                        .collect(),
                ),
                expires_in_days,
            };
            api_keys::create(&web.rt, &cx.access, input).await
        }
        Err(error) => Err(error),
    };
    let page = match result {
        Ok(created) => {
            let mut page = settings_page(&web, &cx).await?;
            page.set("new_api_key", created.secret.expose())
                .status(StatusCode::CREATED);
            page
        }
        Err(error) => {
            let (field, message) = key_form_error(error)?;
            let mut page = settings_page(&web, &cx).await?;
            page.invalid(
                field,
                message,
                json!({"key_name": fields.get("key_name"), "expires_in_days": expiry}),
            );
            page
        }
    };
    Ok(web.render(page, "settings/org.html"))
}

pub async fn revoke_api_key(
    web: Web,
    Path((org, key)): Path<(String, i64)>,
    body: Bytes,
) -> WebResult {
    let fields = Fields::parse(&body);
    let cx = web.member_form(&org, &fields).await?;
    api_keys::revoke(&web.rt, &cx.access, key).await?;
    Ok(web.redirect_flash(
        &format!("{}/settings", cx.base),
        Flash::Info,
        "API key revoked.",
    ))
}

pub async fn settings(web: Web, Path(org): Path<String>) -> WebResult {
    let cx = web.member(&org).await?;
    let page = settings_page(&web, &cx).await?;
    Ok(web.render(page, "settings/org.html"))
}

pub async fn delete(web: Web, Path(org): Path<String>, body: Bytes) -> WebResult {
    let fields = Fields::parse(&body);
    let cx = web.member_form(&org, &fields).await?;
    if cx.access.role != Role::Owner {
        return Err(WebError::Forbidden);
    }
    match web
        .rt
        .organization_lifecycle
        .request(
            &web.rt,
            &web.svc.billing,
            &cx.access,
            fields.get("confirmed_name"),
        )
        .await
    {
        Ok(()) => Ok(web.redirect_flash(
            "/dashboard",
            Flash::Info,
            "Organization deletion requested.",
        )),
        Err(ApiError::BadRequest("organization_name_confirmation")) => {
            let mut page = settings_page(&web, &cx).await?;
            page.invalid(
                "confirmed_name",
                "Enter the organization name exactly as shown.",
                json!({"confirmed_name": fields.get("confirmed_name")}),
            );
            Ok(web.render(page, "settings/org.html"))
        }
        Err(error @ (ApiError::Conflict(_) | ApiError::Unavailable(_))) => {
            Ok(error.into_response())
        }
        Err(error) => Err(error.into()),
    }
}

pub async fn rename(web: Web, Path(org): Path<String>, body: Bytes) -> WebResult {
    let fields = Fields::parse(&body);
    let cx = web.member_form(&org, &fields).await?;
    match account_settings::rename_org(&web.rt, &cx.access, fields.get("name")).await {
        Ok(_) => Ok(web.redirect_flash(
            &format!("{}/settings", cx.base),
            Flash::Info,
            "Organization name saved.",
        )),
        Err(error) => {
            let (field, message) = form_error(error)?;
            let mut page = settings_page(&web, &cx).await?;
            page.invalid(field, message, json!({"name": fields.get("name")}));
            Ok(web.render(page, "settings/org.html"))
        }
    }
}

pub async fn revoke_grant(
    web: Web,
    Path((org, grant)): Path<(String, i64)>,
    body: Bytes,
) -> WebResult {
    let fields = Fields::parse(&body);
    let cx = web.member_form(&org, &fields).await?;
    revoke_grant_for(&web, &cx, grant, &format!("{}/settings", cx.base)).await
}

pub async fn revoke_grant_for(web: &Web, cx: &OrgCx, grant: i64, target: &str) -> WebResult {
    web.svc
        .oauth
        .revoke_dashboard_grant(cx.access.user, &cx.access.org, grant)
        .await
        .map_err(oauth_error)?;
    Ok(web.redirect_flash(target, Flash::Info, "Agent access revoked."))
}

fn channel_rows(
    cx: &OrgCx,
    destinations: &[DestinationView],
    members: &[TeamMember],
) -> Vec<Value> {
    let mut channels = Vec::new();
    for destination in destinations {
        let (name, kind_label, target) = if destination.kind == "email" {
            let email = destination
                .user_id
                .and_then(|id| members.iter().find(|m| m.user_id.0 == id))
                .map(|m| m.email.as_str());
            let name = email.map_or_else(
                || "Email to a former member".to_owned(),
                |e| format!("Email to {e}"),
            );
            (
                name,
                "Email",
                email.map(policy::mask_email).unwrap_or_default(),
            )
        } else {
            (
                "Signed webhook".to_owned(),
                "Signed webhook",
                destination.url_hint.clone().unwrap_or_default(),
            )
        };
        channels.push(json!({
            "id": destination.id.as_str(),
            "name": name,
            "kind_label": kind_label,
            "destination": target,
            "is_default": false,
            "default_action": "",
            "delete_action": format!("{}/settings/notifications/{}/delete", cx.base, destination.id.as_str()),
        }));
    }
    channels
}

async fn notifications_page(web: &Web, cx: &OrgCx) -> WebResult<Page> {
    let mut page = web.org_page(cx, "Notifications", "notifications");
    let destinations = web.svc.notifications.destinations(&cx.access).await?;
    let members = account_settings::team(&web.rt, &cx.access).await?;
    let channels = channel_rows(cx, &destinations, &members);
    let base = format!("{}/settings/notifications", cx.base);
    page.set("channels", channels)
        .set("channel_email_action", format!("{base}/email"))
        .set("channel_webhook_action", format!("{base}/webhook"));
    Ok(page)
}

pub async fn notifications(web: Web, Path(org): Path<String>) -> WebResult {
    let cx = web.member(&org).await?;
    let page = notifications_page(&web, &cx).await?;
    Ok(web.render(page, "settings/notifications.html"))
}

fn all_events() -> Value {
    serde_json::to_value(EVENTS).expect("event kinds serialize")
}

pub async fn add_email(web: Web, Path(org): Path<String>, body: Bytes) -> WebResult {
    let fields = Fields::parse(&body);
    let cx = web.member_form(&org, &fields).await?;
    let result = if fields
        .get("email")
        .trim()
        .eq_ignore_ascii_case(&cx.account.email)
    {
        let input: EmailSubscription =
            serde_json::from_value(json!({"events": all_events(), "project_id": null}))
                .expect("subscription input");
        web.svc
            .notifications
            .subscribe_email(&cx.access, input)
            .await
            .map(|_| ())
    } else {
        Err(ApiError::BadRequest("account_email_only"))
    };
    match result {
        Ok(()) => Ok(web.redirect_flash(
            &format!("{}/settings/notifications", cx.base),
            Flash::Info,
            "Email notifications are on for new issues, regressions, and reports.",
        )),
        Err(error) => {
            let (field, message) = form_error(error)?;
            let mut page = notifications_page(&web, &cx).await?;
            page.invalid(
                field,
                message,
                json!({"name": fields.get("name"), "email": fields.get("email")}),
            );
            Ok(web.render(page, "settings/notifications.html"))
        }
    }
}

/// The signing secret is generated by the server and shown in this response
/// only. It never goes into a redirect, cookie, or log.
pub async fn add_webhook(web: Web, Path(org): Path<String>, body: Bytes) -> WebResult {
    let fields = Fields::parse(&body);
    let cx = web.member_form(&org, &fields).await?;
    let input: WebhookInput = serde_json::from_value(
        json!({"url": fields.get("url"), "events": all_events(), "project_id": null}),
    )
    .expect("webhook input");
    match web
        .svc
        .notifications
        .create_webhook(&cx.access, input)
        .await
    {
        Ok(created) => {
            let mut page = notifications_page(&web, &cx).await?;
            let secret = created.signing_secret.expose_secret();
            page.set("webhook_secret", secret).notice(
                Flash::Info,
                &format!(
                    "Webhook created. Verify deliveries with this signing secret: {secret} . PostDeploy generated it, and it is shown only once. Copy it now."
                ),
            );
            page.status(StatusCode::CREATED);
            Ok(web.render(page, "settings/notifications.html"))
        }
        Err(error) => {
            let (field, message) = form_error(error)?;
            let mut page = notifications_page(&web, &cx).await?;
            page.invalid(
                field,
                message,
                json!({"webhook_name": fields.get("webhook_name"), "url": fields.get("url")}),
            );
            Ok(web.render(page, "settings/notifications.html"))
        }
    }
}

pub async fn delete_destination(
    web: Web,
    Path((org, destination)): Path<(String, String)>,
    body: Bytes,
) -> WebResult {
    let fields = Fields::parse(&body);
    let cx = web.member_form(&org, &fields).await?;
    let id: DestinationId = destination.parse().map_err(|()| WebError::NotFound)?;
    web.svc
        .notifications
        .delete_destination(&cx.access, &id)
        .await?;
    Ok(redirect(&format!("{}/settings/notifications", cx.base)))
}

const LEVEL_LABELS: [(&str, &str); 6] = [
    ("trace", "Trace"),
    ("debug", "Debug"),
    ("info", "Info"),
    ("warn", "Warning"),
    ("error", "Error"),
    ("fatal", "Fatal"),
];

fn ingestion_page(
    web: &Web,
    cx: &OrgCx,
    stored: &ingest_policy::StoredPolicy,
    submitted: Option<&Fields>,
) -> Page {
    let mut page = web.org_page(cx, "Data controls", "settings");
    let default = ingest_policy::IngestionPolicy::default();
    let policy = match &stored.policy {
        ingest_policy::PolicyState::Valid(policy) => policy,
        ingest_policy::PolicyState::Invalid => {
            page.set(
                "policy_invalid",
                "The saved data controls are not valid. Every project in this organization refuses new events and logs until valid data controls are saved.",
            );
            &default
        }
    };
    let lines = |items: Vec<&str>| items.join("\n");
    let enabled = policy.log_levels.names();
    let checked = |id: &str| match submitted {
        Some(fields) => fields.all("log_levels").contains(&id),
        None => enabled.contains(&id),
    };
    let levels: Vec<Value> = LEVEL_LABELS
        .iter()
        .map(|(id, label)| json!({"id": id, "label": label, "checked": checked(id)}))
        .collect();
    let values = match submitted {
        Some(fields) => json!({
            "sensitive_fields": fields.get("sensitive_fields"),
            "excluded_exception_types": fields.get("excluded_exception_types"),
            "error_sample_percent": fields.get("error_sample_percent"),
            "log_sample_percent": fields.get("log_sample_percent"),
        }),
        None => json!({
            "sensitive_fields": lines(policy.sensitive_fields.iter().map(|f| f.as_str()).collect()),
            "excluded_exception_types": lines(policy.excluded_exception_types.iter().map(|t| t.as_str()).collect()),
            "error_sample_percent": policy.error_sample_percent.value().to_string(),
            "log_sample_percent": policy.log_sample_percent.value().to_string(),
        }),
    };
    page.set("values", values)
        .set("levels", levels)
        .set(
            "sensitive_field_list",
            policy
                .sensitive_fields
                .iter()
                .map(|f| f.as_str())
                .collect::<Vec<_>>(),
        )
        .set(
            "excluded_type_list",
            policy
                .excluded_exception_types
                .iter()
                .map(|t| t.as_str())
                .collect::<Vec<_>>(),
        )
        .set("enabled_levels", enabled.join(", "))
        .set("error_sample_percent", policy.error_sample_percent.value())
        .set("log_sample_percent", policy.log_sample_percent.value())
        .set("max_sensitive_fields", ingest_policy::MAX_SENSITIVE_FIELDS)
        .set("max_excluded_types", ingest_policy::MAX_EXCLUDED_TYPES)
        .set(
            "ingestion_action",
            format!("{}/settings/ingestion", cx.base),
        );
    page
}

pub async fn ingestion(web: Web, Path(org): Path<String>) -> WebResult {
    let cx = web.member(&org).await?;
    let stored = ingest_policy::load(&web.rt, &cx.access).await?;
    let page = ingestion_page(&web, &cx, &stored, None);
    Ok(web.render(page, "settings/ingestion.html"))
}

fn policy_input(fields: &Fields) -> Value {
    let lines = |name: &str| -> Vec<String> {
        fields
            .get(name)
            .lines()
            .map(str::trim)
            .filter(|line| !line.is_empty())
            .map(str::to_owned)
            .collect()
    };
    let percent = |name: &str| -> Value {
        fields
            .get(name)
            .trim()
            .parse::<i64>()
            .map_or(Value::Null, Value::from)
    };
    json!({
        "sensitive_fields": lines("sensitive_fields"),
        "log_levels": fields.all("log_levels"),
        "excluded_exception_types": lines("excluded_exception_types"),
        "error_sample_percent": percent("error_sample_percent"),
        "log_sample_percent": percent("log_sample_percent"),
    })
}

pub async fn save_ingestion(web: Web, Path(org): Path<String>, body: Bytes) -> WebResult {
    let fields = Fields::parse(&body);
    let cx = web.member_form(&org, &fields).await?;
    if !cx.access.role.can_manage() {
        return Err(WebError::Forbidden);
    }
    match ingest_policy::save(&web.rt, &cx.access, policy_input(&fields)).await {
        Ok(_) => Ok(web.redirect_flash(
            &format!("{}/settings/ingestion", cx.base),
            Flash::Info,
            "Data controls saved.",
        )),
        Err(ApiError::BadRequest("invalid_ingestion_policy")) => {
            let stored = ingest_policy::load(&web.rt, &cx.access).await?;
            let mut page = ingestion_page(&web, &cx, &stored, Some(&fields));
            page.status(StatusCode::UNPROCESSABLE_ENTITY).set(
                "policy_error",
                format!(
                    "Check the values. Field names use 3 to 64 letters, digits, dots, dashes or underscores, at most {}. A field name cannot be all or part of a name PostDeploy needs to group and store events and logs, such as message, type, value, trace, level or service. Exception types use at most 128 characters, at most {}. Percentages are whole numbers from 0 to 100.",
                    ingest_policy::MAX_SENSITIVE_FIELDS,
                    ingest_policy::MAX_EXCLUDED_TYPES
                ),
            );
            Ok(web.render(page, "settings/ingestion.html"))
        }
        Err(error) => Err(error.into()),
    }
}
