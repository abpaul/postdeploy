use std::sync::Arc;

use axum::{
    body::Bytes,
    extract::Extension,
    http::{header, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use serde::Serialize;
use serde_json::{json, Value};

use crate::{
    agent_access::{
        AuthorizeRequest, ClientRegistration, Consent, ConsentPrompt, OAuthError, RevokeForm,
        TokenForm,
    },
    domain::OrgId,
    error::ApiError,
    identity::{
        access::{authorize as org_access, Session},
        projects,
    },
    onboarding::{self, Setup},
};

use super::{
    page::{redirect, Fields, Web, WebError, WebResult},
    policy::{self, ConsentDecision, RegistrationGate},
};

const MAX_OAUTH_BODY: usize = 16 << 10;

fn no_store(mut response: Response) -> Response {
    let headers = response.headers_mut();
    headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    headers.insert(header::PRAGMA, HeaderValue::from_static("no-cache"));
    response
}

fn oauth_failure(error: OAuthError) -> Response {
    no_store(ApiError::from(error).into_response())
}

fn json_ok<T: Serialize>(status: StatusCode, value: T) -> Response {
    no_store((status, Json(value)).into_response())
}

pub async fn authorization_server(web: Web) -> Response {
    Json(web.svc.oauth.authorization_server_metadata()).into_response()
}

pub async fn protected_resource(web: Web) -> Response {
    Json(web.svc.oauth.protected_resource_metadata()).into_response()
}

pub async fn register(
    web: Web,
    Extension(gate): Extension<Arc<RegistrationGate>>,
    body: Bytes,
) -> Response {
    let now_ms = u64::try_from(chrono::Utc::now().timestamp_millis()).unwrap_or(0);
    if let Err(wait) = gate.allow(now_ms, web.peer) {
        let mut response = json_ok(
            StatusCode::TOO_MANY_REQUESTS,
            json!({"error": "temporarily_unavailable"}),
        );
        response
            .headers_mut()
            .insert(header::RETRY_AFTER, HeaderValue::from(wait));
        return response;
    }
    if body.len() > MAX_OAUTH_BODY {
        return oauth_failure(OAuthError::InvalidClientMetadata);
    }
    let Ok(request) = serde_json::from_slice::<ClientRegistration>(&body) else {
        return oauth_failure(OAuthError::InvalidClientMetadata);
    };
    match web.svc.oauth.register_client(request).await {
        Ok(client) => json_ok(StatusCode::CREATED, client),
        Err(error) => oauth_failure(error),
    }
}

fn form_object(fields: &Fields, names: &[&str]) -> Value {
    let map = names
        .iter()
        .filter(|name| !fields.get(name).is_empty())
        .map(|name| {
            (
                (*name).to_owned(),
                Value::String(fields.get(name).to_owned()),
            )
        })
        .collect();
    Value::Object(map)
}

pub async fn token(web: Web, body: Bytes) -> Response {
    if body.len() > MAX_OAUTH_BODY {
        return oauth_failure(OAuthError::InvalidRequest);
    }
    let fields = Fields::parse(&body);
    let names = [
        "grant_type",
        "client_id",
        "code",
        "redirect_uri",
        "code_verifier",
        "refresh_token",
        "resource",
    ];
    let Ok(form) = serde_json::from_value::<TokenForm>(form_object(&fields, &names)) else {
        return oauth_failure(OAuthError::InvalidRequest);
    };
    match web.svc.oauth.token(form).await {
        Ok(tokens) => json_ok(StatusCode::OK, tokens),
        Err(error) => oauth_failure(error),
    }
}

pub async fn revoke(web: Web, body: Bytes) -> Response {
    if body.len() > MAX_OAUTH_BODY {
        return oauth_failure(OAuthError::InvalidRequest);
    }
    let fields = Fields::parse(&body);
    let Ok(form) = serde_json::from_value::<RevokeForm>(form_object(
        &fields,
        &["token", "token_type_hint", "client_id"],
    )) else {
        return oauth_failure(OAuthError::InvalidRequest);
    };
    match web.svc.oauth.revoke(form).await {
        Ok(()) => no_store(StatusCode::OK.into_response()),
        Err(error) => oauth_failure(error),
    }
}

fn error_message(error: &OAuthError) -> Option<&'static str> {
    Some(match error {
        OAuthError::InvalidClient => "This agent is not registered here. Start the connection again from your agent.",
        OAuthError::AccessDenied => "You are not a member of that organization. Start the connection again from your agent.",
        OAuthError::InvalidScope => "The agent asked for access that is not available. Start the connection again from your agent.",
        OAuthError::TemporarilyUnavailable | OAuthError::Internal(_) => return None,
        _ => "This connection request is not valid or has expired. Start the connection again from your agent.",
    })
}

async fn consent_error(web: &Web, session: &Session, error: OAuthError) -> WebResult {
    let Some(message) = error_message(&error) else {
        return Err(match error {
            OAuthError::TemporarilyUnavailable => WebError::Unavailable,
            other => ApiError::from(other).into(),
        });
    };
    consent_message(web, session, message).await
}

async fn consent_message(web: &Web, session: &Session, message: &str) -> WebResult {
    let (mut page, _) = web.account_page(session, "Connect an agent", "").await?;
    page.set("client_name", "Connect an agent")
        .set("permission_error", message)
        .status(StatusCode::BAD_REQUEST);
    Ok(web.render(page, "oauth/consent.html"))
}

/// Projects-and-sources access starts checked only when it is the one thing
/// the agent can do next: an empty organization the user manages.
async fn offers_project_setup(
    web: &Web,
    session: &Session,
    prompt: &ConsentPrompt,
) -> WebResult<bool> {
    let [org] = prompt.organizations.as_slice() else {
        return Ok(false);
    };
    if !org.role.can_manage() {
        return Ok(false);
    }
    let access = org_access(&web.rt, session.user, &org.id).await?;
    let projects = projects::list(&web.rt, &access).await?;
    let onboarding = onboarding::load(&web.rt, &access, &projects).await?;
    Ok(onboarding.setup == Setup::NoProject)
}

pub async fn authorize_form(web: Web) -> WebResult {
    let session = web.signed().await?;
    let query = Fields::parse(web.uri.split_once('?').map_or("", |(_, q)| q).as_bytes());
    let text = |name: &str| {
        Some(query.get(name))
            .filter(|v| !v.is_empty())
            .map(str::to_owned)
    };
    let request = AuthorizeRequest {
        response_type: text("response_type"),
        client_id: text("client_id"),
        redirect_uri: text("redirect_uri"),
        code_challenge: text("code_challenge"),
        code_challenge_method: text("code_challenge_method"),
        scope: text("scope"),
        state: text("state"),
        resource: text("resource"),
    };
    let prompt = match web.svc.oauth.begin_consent(session.user, request).await {
        Ok(Consent::Ready(prompt)) => prompt,
        Ok(Consent::NoOrganization) => {
            let Some(path) = policy::agent_return(&web.uri) else {
                return consent_message(
                    &web,
                    &session,
                    "Create an organization, then start the connection again from your agent.",
                )
                .await;
            };
            let encoded: String = url::form_urlencoded::byte_serialize(path.as_bytes()).collect();
            return Ok(redirect(&format!(
                "/dashboard/orgs/new?return_to={encoded}"
            )));
        }
        Err(error) => return consent_error(&web, &session, error).await,
    };
    let create_projects = offers_project_setup(&web, &session, &prompt).await?;
    let (mut page, _) = web.account_page(&session, "Connect an agent", "").await?;
    let host = url::Url::parse(&prompt.redirect_uri)
        .ok()
        .and_then(|u| u.host_str().map(str::to_owned))
        .unwrap_or_default();
    let mut fields = vec![json!({"name": "consent", "value": prompt.handle.expose()})];
    let single = (prompt.organizations.len() == 1).then(|| &prompt.organizations[0]);
    if let Some(org) = single {
        fields.push(json!({"name": "org_id", "value": org.id.as_str()}));
        page.set(
            "organization",
            json!({"id": org.id.as_str(), "name": org.name}),
        );
    }
    let choices: Vec<Value> = prompt
        .organizations
        .iter()
        .map(|org| json!({"organization": {"id": org.id.as_str(), "name": org.name}, "projects": []}))
        .collect();
    let client = prompt.client_name.as_deref();
    page.set("client_name", client.unwrap_or("An agent"))
        .set("client_host", host)
        .set("organization_mode", single.is_some())
        .set("oauth_choices", choices)
        .set("oauth_fields", fields)
        .set(
            "scopes",
            policy::consent_rows(
                &prompt.offered,
                &prompt.requested,
                client.unwrap_or("the agent"),
                create_projects,
            ),
        )
        .set("form_action", "/oauth/authorize");
    Ok(web.render(page, "oauth/consent.html"))
}

pub async fn authorize(web: Web, body: Bytes) -> WebResult {
    let fields = Fields::parse(&body);
    let session = web.signed_form(&fields).await?;
    let handle = fields.get("consent");
    let oauth = &web.svc.oauth;
    let result = match policy::consent_decision(fields.get("decision"), &fields.all("scopes")) {
        Err(code) => {
            let message = policy::field_message(code).map_or("Choose Allow or Deny.", |(_, m)| m);
            return consent_message(
                &web,
                &session,
                &format!("{message} Start the connection again from your agent."),
            )
            .await;
        }
        Ok(ConsentDecision::Deny) => oauth.deny_consent(session.user, handle).await,
        Ok(ConsentDecision::Allow(scopes)) => match fields.get("org_id").parse::<OrgId>() {
            Ok(org) => {
                oauth
                    .approve_consent(session.user, handle, &org, scopes)
                    .await
            }
            Err(()) => Err(OAuthError::AccessDenied),
        },
    };
    let url = match result {
        Ok(url) => url,
        Err(error) => return consent_error(&web, &session, error).await,
    };
    let Some(target) =
        policy::client_redirect_target(&url).and_then(|u| HeaderValue::from_str(u).ok())
    else {
        tracing::warn!("OAuth service returned a redirect the dashboard refused");
        return Err(WebError::Internal);
    };
    let mut response = StatusCode::SEE_OTHER.into_response();
    response.headers_mut().insert(header::LOCATION, target);
    Ok(no_store(response))
}
