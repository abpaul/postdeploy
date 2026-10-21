use std::{net::IpAddr, net::SocketAddr, sync::Arc, sync::OnceLock};

use axum::{
    extract::{ConnectInfo, FromRequestParts},
    http::{header, request::Parts, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
};
use loco_rs::{
    app::AppContext,
    controller::views::{engines::TeraView, ViewEngine, ViewRenderer},
};
use serde_json::{json, Map, Value};
use zeroize::Zeroize;

use crate::{
    account_settings::{self, Account},
    admission::QueryPermit,
    domain::{OrgId, ProjectId},
    error::ApiError,
    identity::{
        access::{authorize, cookie_value, resolve_session, OrgAccess, Session, SESSION_COOKIE},
        orgs::{self, OrgSummary},
        projects::{self, Project},
        random_token,
    },
    runtime::Runtime,
    services::Services,
};

use super::policy::{
    self, FLASH_COOKIE, PREAUTH_COOKIE, PREAUTH_MAX_AGE, RETURN_COOKIE, RETURN_MAX_AGE,
};

static VIEWS: OnceLock<TeraView> = OnceLock::new();

pub fn keep_views(views: TeraView) {
    let _ = VIEWS.set(views);
}

pub struct Web {
    pub rt: Arc<Runtime>,
    pub svc: Arc<Services>,
    pub peer: Option<IpAddr>,
    pub uri: String,
    views: TeraView,
    session_token: Option<String>,
    preauth: Option<String>,
    return_to: Option<String>,
    flash: Option<Value>,
    same_origin: bool,
}

impl FromRequestParts<AppContext> for Web {
    type Rejection = Response;

    async fn from_request_parts(parts: &mut Parts, ctx: &AppContext) -> Result<Self, Response> {
        let Some(ViewEngine(views)) = parts.extensions.get::<ViewEngine<TeraView>>().cloned()
        else {
            tracing::error!("view engine is not installed");
            return Err(static_error(StatusCode::INTERNAL_SERVER_ERROR));
        };
        let rt = Runtime::get(ctx);
        let header = |name: &str| parts.headers.get(name).and_then(|v| v.to_str().ok());
        let same_origin = policy::origin_allowed(header("origin"), &rt.settings.auth.origin)
            && policy::fetch_site_allowed(header("sec-fetch-site"));
        let cookie = |name: &str| {
            cookie_value(parts, name)
                .filter(|v| !v.is_empty())
                .map(str::to_owned)
        };
        Ok(Self {
            svc: Services::get(ctx),
            // Only the Cloudflare tunnel reaches the listener, and Cloudflare
            // sets this header on every request it forwards.
            peer: header("cf-connecting-ip")
                .and_then(|value| value.parse().ok())
                .or_else(|| {
                    parts
                        .extensions
                        .get::<ConnectInfo<SocketAddr>>()
                        .map(|ConnectInfo(addr)| addr.ip())
                }),
            uri: parts
                .uri
                .path_and_query()
                .map_or_else(|| parts.uri.path().to_owned(), |p| p.as_str().to_owned()),
            session_token: cookie(SESSION_COOKIE),
            preauth: cookie(PREAUTH_COOKIE),
            return_to: cookie(RETURN_COOKIE)
                .and_then(|v| decode(&v))
                .filter(|v| policy::return_path(v).is_some()),
            flash: cookie(FLASH_COOKIE).and_then(|v| read_flash(&v)),
            same_origin,
            views,
            rt,
        })
    }
}

/// Failures that end a dashboard request. Service errors that belong to a form
/// field are handled in the handler and never reach this type.
#[derive(Debug)]
pub enum WebError {
    NotFound,
    Forbidden,
    /// Signed out. Carries the page to return to after sign-in and whether
    /// cookies need the `Secure` attribute.
    SignIn {
        return_to: Option<String>,
        secure: bool,
    },
    Unavailable,
    Internal,
}

impl From<ApiError> for WebError {
    fn from(error: ApiError) -> Self {
        match error {
            ApiError::NotFound => Self::NotFound,
            ApiError::Forbidden => Self::Forbidden,
            ApiError::Unauthorized => Self::SignIn {
                return_to: None,
                secure: true,
            },
            ApiError::Unavailable(_) | ApiError::RateLimited { .. } => Self::Unavailable,
            ApiError::Internal(cause) => {
                tracing::error!(cause = %cause, "dashboard request failed");
                Self::Internal
            }
            other => {
                tracing::warn!(error = %other, "unexpected dashboard service error");
                Self::Internal
            }
        }
    }
}

impl IntoResponse for WebError {
    fn into_response(self) -> Response {
        let status = match self {
            Self::SignIn { return_to, secure } => {
                let mut response = redirect("/sign-in");
                if let Some(path) = return_to.as_deref().and_then(policy::return_path) {
                    add_cookie(
                        &mut response,
                        &policy::cookie(RETURN_COOKIE, &encode(path), RETURN_MAX_AGE, secure),
                    );
                }
                return response;
            }
            Self::NotFound => StatusCode::NOT_FOUND,
            Self::Forbidden => StatusCode::FORBIDDEN,
            Self::Unavailable => StatusCode::SERVICE_UNAVAILABLE,
            Self::Internal => StatusCode::INTERNAL_SERVER_ERROR,
        };
        error_page(status)
    }
}

pub type WebResult<T = Response> = Result<T, WebError>;

pub fn error_page(status: StatusCode) -> Response {
    let (template, title) = if status == StatusCode::NOT_FOUND {
        ("errors/404.html", "Page not found")
    } else {
        ("errors/500.html", "Something went wrong")
    };
    let data = json!({"title": title, "csrf_token": "", "user": null, "flash": null});
    match VIEWS.get().map(|views| views.render(template, &data)) {
        Some(Ok(body)) => html(status, body),
        Some(Err(_)) => {
            tracing::error!(template, "error page did not render");
            static_error(status)
        }
        None => static_error(status),
    }
}

pub async fn not_found() -> Response {
    error_page(StatusCode::NOT_FOUND)
}

fn static_error(status: StatusCode) -> Response {
    html(
        status,
        "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"robots\" content=\"noindex\"><title>PostDeploy</title></head><body><h1>PostDeploy could not finish this request.</h1><p><a href=\"/dashboard\">Go to dashboard</a> <a href=\"/sign-in\">Sign in</a></p></body></html>".to_owned(),
    )
}

fn html(status: StatusCode, body: String) -> Response {
    (
        status,
        [
            (header::CONTENT_TYPE, "text/html; charset=utf-8"),
            (header::CACHE_CONTROL, "no-store"),
        ],
        body,
    )
        .into_response()
}

pub fn redirect(location: &str) -> Response {
    let location = policy::relative_location(location).unwrap_or("/dashboard");
    let mut response = StatusCode::SEE_OTHER.into_response();
    let headers = response.headers_mut();
    headers.insert(
        header::LOCATION,
        HeaderValue::from_str(location).unwrap_or(HeaderValue::from_static("/dashboard")),
    );
    headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    response
}

pub fn add_cookie(response: &mut Response, cookie: &str) {
    if let Ok(value) = HeaderValue::from_str(cookie) {
        response.headers_mut().append(header::SET_COOKIE, value);
    }
}

fn encode(value: &str) -> String {
    url::form_urlencoded::byte_serialize(value.as_bytes()).collect()
}

fn decode(value: &str) -> Option<String> {
    url::form_urlencoded::parse(format!("v={value}").as_bytes())
        .next()
        .map(|(_, v)| v.into_owned())
}

fn read_flash(raw: &str) -> Option<Value> {
    let (kind, message) = raw.split_once('.')?;
    let message = decode(message)?;
    let kind = if kind == "e" { "error" } else { "info" };
    (!message.is_empty()).then(|| json!({"kind": kind, "message": message}))
}

#[derive(Clone, Copy)]
pub enum Flash {
    Info,
    Error,
}

/// URL-encoded form fields in order. Repeated names are kept. Values are wiped
/// when dropped because forms carry passwords and tokens.
pub struct Fields(Vec<(String, String)>);

impl Fields {
    pub fn parse(body: &[u8]) -> Self {
        Self(
            url::form_urlencoded::parse(body)
                .map(|(k, v)| (k.into_owned(), v.into_owned()))
                .collect(),
        )
    }

    pub fn get(&self, name: &str) -> &str {
        self.0
            .iter()
            .find(|(k, _)| k == name)
            .map_or("", |(_, v)| v.as_str())
    }

    pub fn all(&self, name: &str) -> Vec<&str> {
        self.0
            .iter()
            .filter(|(k, _)| k == name)
            .map(|(_, v)| v.as_str())
            .collect()
    }

    /// Builds a typed service input (token or secret) from one field.
    pub fn typed<T: serde::de::DeserializeOwned>(&self, name: &str) -> Option<T> {
        serde_json::from_value(Value::String(self.get(name).to_owned())).ok()
    }
}

impl Drop for Fields {
    fn drop(&mut self) {
        for (_, value) in &mut self.0 {
            value.zeroize();
        }
    }
}

pub struct Page {
    data: Map<String, Value>,
    status: StatusCode,
    retry_after: Option<u64>,
    cookies: Vec<String>,
}

/// An expensive read refused by query admission. The page renders without it
/// and shows `message` where its result would be.
pub struct QueryBusy {
    status: StatusCode,
    retry_secs: u64,
}

impl QueryBusy {
    pub fn message(&self) -> String {
        let wait = match self.retry_secs {
            1 => "1 second".to_owned(),
            secs => format!("{secs} seconds"),
        };
        if self.status == StatusCode::TOO_MANY_REQUESTS {
            format!("This organization's query budget is busy. Try again in {wait}.")
        } else {
            format!("The server is busy with other log queries. Try again in {wait}.")
        }
    }
}

impl Page {
    fn base(title: &str, csrf: &str, user: Value) -> Self {
        let Value::Object(data) = json!({
            "title": title,
            "csrf_token": csrf,
            "user": user,
            "organization": null,
            "project": null,
            "org_base": "",
            "project_base": "",
            "flash": null,
            "field_errors": {},
            "values": {},
            "form_action": "",
            "sign_out_action": "/sign-out",
            "project_switch_action": "",
            "environment_action": "",
            "page_heading": false,
            "active": "",
            "onboarding": false,
            "can_manage": false,
            "owner": false,
            "crumbs": [],
            "organizations": [],
            "projects": [],
            "windows": [],
            "environments": [],
            "agent_connected": false,
            "turnstile_site_key": "",
        }) else {
            unreachable!("object literal")
        };
        Self {
            data,
            status: StatusCode::OK,
            retry_after: None,
            cookies: Vec::new(),
        }
    }

    pub fn set(&mut self, key: &str, value: impl Into<Value>) -> &mut Self {
        self.data.insert(key.into(), value.into());
        self
    }

    pub fn status(&mut self, status: StatusCode) -> &mut Self {
        self.status = status;
        self
    }

    /// Answers with the admission status and `Retry-After`, as the API does.
    pub fn busy(&mut self, busy: &QueryBusy) -> &mut Self {
        self.status = busy.status;
        self.retry_after = Some(busy.retry_secs);
        self
    }

    /// A rejected form: the field message, the submitted values, and 422.
    pub fn invalid(&mut self, field: &str, message: &str, values: Value) -> &mut Self {
        self.data
            .entry("field_errors")
            .or_insert_with(|| json!({}))
            .as_object_mut()
            .expect("field_errors is an object")
            .insert(field.into(), json!(message));
        self.data.insert("values".into(), values);
        self.status = StatusCode::UNPROCESSABLE_ENTITY;
        self
    }

    /// Shows a message for this response only. Used for one-time secrets,
    /// which must not travel in the flash cookie.
    pub fn notice(&mut self, kind: Flash, message: &str) -> &mut Self {
        let kind = match kind {
            Flash::Info => "info",
            Flash::Error => "error",
        };
        self.set("flash", json!({"kind": kind, "message": message}))
    }

    fn crumbs(&mut self, crumbs: &[(&str, &str)]) {
        let crumbs: Vec<Value> = crumbs
            .iter()
            .map(|(label, href)| json!({"label": label, "href": href}))
            .collect();
        self.set("crumbs", crumbs);
    }
}

pub fn initial(value: &str) -> String {
    value
        .chars()
        .next()
        .map_or_else(|| "?".into(), |c| c.to_uppercase().to_string())
}

fn user_value(account: &Account) -> Value {
    json!({
        "id": account.id.0,
        "name": account.name,
        "email": account.email,
        "initial": initial(account.name.as_deref().unwrap_or(&account.email)),
        "confirmed": account.confirmed,
    })
}

pub fn org_path(org: &OrgId) -> String {
    format!("/dashboard/orgs/{org}")
}

pub fn project_path(org: &OrgId, project: ProjectId) -> String {
    format!("/dashboard/orgs/{org}/projects/{}", project.0)
}

pub struct OrgCx {
    pub session: Session,
    pub account: Account,
    pub access: OrgAccess,
    pub org: OrgSummary,
    pub orgs: Vec<OrgSummary>,
    pub projects: Vec<Project>,
    pub base: String,
}

impl OrgCx {
    pub fn project(&self, id: i64) -> WebResult<&Project> {
        self.projects
            .iter()
            .find(|p| p.id.0 == id)
            .ok_or(WebError::NotFound)
    }
}

impl Web {
    pub fn secure(&self) -> bool {
        self.rt.settings.auth.secure_cookies
    }

    pub async fn session(&self) -> Option<Session> {
        resolve_session(&self.rt, self.session_token.as_deref()?)
            .await
            .ok()
    }

    /// The signed-in session, or a redirect to sign-in that returns here.
    pub async fn signed(&self) -> WebResult<Session> {
        self.session().await.ok_or_else(|| WebError::SignIn {
            return_to: Some(self.uri.clone()),
            secure: self.secure(),
        })
    }

    /// Origin, fetch metadata, and the hidden CSRF field against the session.
    pub async fn signed_form(&self, fields: &Fields) -> WebResult<Session> {
        let session = self.session().await.ok_or(WebError::SignIn {
            return_to: None,
            secure: self.secure(),
        })?;
        self.check(fields, Some(&session.csrf_token))?;
        Ok(session)
    }

    /// Origin, fetch metadata, and the hidden CSRF field against the
    /// pre-authentication cookie.
    pub fn anonymous_form(&self, fields: &Fields) -> WebResult<()> {
        self.check(fields, self.preauth.as_deref())
    }

    fn check(&self, fields: &Fields, expected: Option<&str>) -> WebResult<()> {
        let ok = self.same_origin
            && expected.is_some_and(|e| policy::tokens_match(fields.get("_csrf_token"), e));
        ok.then_some(()).ok_or(WebError::Forbidden)
    }

    pub fn return_to(&self) -> Option<&str> {
        self.return_to.as_deref()
    }

    pub fn render(&self, mut page: Page, template: &str) -> Response {
        if !page.data.get("flash").is_some_and(|f| !f.is_null()) {
            page.data
                .insert("flash".into(), self.flash.clone().unwrap_or(Value::Null));
        }
        let mut response = match self.views.render(template, &page.data) {
            Ok(body) => html(page.status, body),
            Err(_) => {
                tracing::error!(template, "view render failed");
                return error_page(StatusCode::INTERNAL_SERVER_ERROR);
            }
        };
        if self.flash.is_some() {
            add_cookie(
                &mut response,
                &policy::cookie(FLASH_COOKIE, "", 0, self.secure()),
            );
        }
        for cookie in &page.cookies {
            add_cookie(&mut response, cookie);
        }
        if let Some(secs) = page.retry_after {
            response
                .headers_mut()
                .insert(header::RETRY_AFTER, HeaderValue::from(secs));
        }
        response
    }

    /// Admits one expensive read for `org`. A refusal is a [`QueryBusy`] for
    /// the page to show; any other failure ends the request.
    pub fn admit_query(&self, org: &OrgId) -> WebResult<Result<QueryPermit, QueryBusy>> {
        let error = match self.rt.admission.queries.expensive(org) {
            Ok(permit) => return Ok(Ok(permit)),
            Err(error) => error,
        };
        let Some(retry_secs) = error.retry_after_secs() else {
            return Err(error.into());
        };
        let status = if matches!(error, ApiError::RateLimited { .. }) {
            StatusCode::TOO_MANY_REQUESTS
        } else {
            StatusCode::SERVICE_UNAVAILABLE
        };
        Ok(Err(QueryBusy { status, retry_secs }))
    }

    pub fn redirect_flash(&self, location: &str, kind: Flash, message: &str) -> Response {
        let mut response = redirect(location);
        add_cookie(&mut response, &self.flash_cookie(kind, message));
        response
    }

    /// A message for the next page. Never put a secret in it.
    pub fn flash_cookie(&self, kind: Flash, message: &str) -> String {
        let kind = match kind {
            Flash::Info => "i",
            Flash::Error => "e",
        };
        policy::cookie(
            FLASH_COOKIE,
            &format!("{kind}.{}", encode(message)),
            60,
            self.secure(),
        )
    }

    /// Page for a signed-out visitor. The CSRF token is the pre-authentication
    /// cookie, created on first visit.
    pub fn anonymous_page(&self, title: &str, action: &str) -> Page {
        let (token, fresh) = match &self.preauth {
            Some(token) => (token.clone(), false),
            None => (random_token(), true),
        };
        let mut page = Page::base(title, &token, Value::Null);
        page.set("form_action", action);
        if fresh {
            page.cookies.push(policy::cookie(
                PREAUTH_COOKIE,
                &token,
                PREAUTH_MAX_AGE,
                self.secure(),
            ));
        }
        page
    }

    /// Page with no form and no account data. Sets no cookie.
    pub fn public_page(&self, title: &str) -> Page {
        Page::base(title, "", Value::Null)
    }

    pub async fn account_page(
        &self,
        session: &Session,
        title: &str,
        active: &str,
    ) -> WebResult<(Page, Account)> {
        let account = account_settings::account(&self.rt, session).await?;
        let orgs = orgs::list(&self.rt, session.user).await?;
        let mut page = Page::base(title, &session.csrf_token, user_value(&account));
        page.set("active", active);
        page.set("organizations", org_rows(&orgs));
        Ok((page, account))
    }

    pub async fn org(&self, session: Session, org: &str) -> WebResult<OrgCx> {
        let org: OrgId = org.parse().map_err(|()| WebError::NotFound)?;
        let access = authorize(&self.rt, session.user, &org).await?;
        let summary = orgs::get(&self.rt, &access).await?;
        let orgs = orgs::list(&self.rt, session.user).await?;
        let projects = projects::list(&self.rt, &access).await?;
        let account = account_settings::account(&self.rt, &session).await?;
        Ok(OrgCx {
            base: org_path(&org),
            session,
            account,
            access,
            org: summary,
            orgs,
            projects,
        })
    }

    pub async fn member(&self, org: &str) -> WebResult<OrgCx> {
        let session = self.signed().await?;
        self.org(session, org).await
    }

    pub async fn member_form(&self, org: &str, fields: &Fields) -> WebResult<OrgCx> {
        let session = self.signed_form(fields).await?;
        self.org(session, org).await
    }

    pub fn org_page(&self, cx: &OrgCx, title: &str, active: &str) -> Page {
        let mut page = Page::base(title, &cx.session.csrf_token, user_value(&cx.account));
        let role = cx.access.role;
        page.set("active", active)
            .set("organizations", org_rows(&cx.orgs))
            .set("organization", json!({"id": cx.org.id.as_str(), "name": cx.org.name, "initial": initial(&cx.org.name), "created_at": ""}))
            .set("org_base", cx.base.as_str())
            .set("can_manage", role.can_manage())
            .set("owner", role == crate::domain::Role::Owner)
            .set("projects", cx.projects.iter().map(|p| project_row(&cx.org.id, p, None)).collect::<Vec<_>>())
            .set("project_switch_action", format!("{}/open", cx.base))
            .set("onboarding", cx.projects.is_empty());
        page.crumbs(&[
            (&cx.org.name, &format!("{}/projects", cx.base)),
            (title, ""),
        ]);
        page
    }

    pub fn project_page(&self, cx: &OrgCx, project: &Project, title: &str, active: &str) -> Page {
        let mut page = self.org_page(cx, title, active);
        let base = project_path(&cx.org.id, project.id);
        page.set("project", json!({"id": project.id.0, "name": project.name}))
            .set("project_base", base.as_str())
            .set("onboarding", false);
        page.crumbs(&[
            (&cx.org.name, &format!("{}/projects", cx.base)),
            (&project.name, &base),
            (title, ""),
        ]);
        page
    }
}

pub fn org_rows(orgs: &[OrgSummary]) -> Vec<Value> {
    orgs.iter()
        .map(|org| {
            json!({
                "id": org.id.as_str(),
                "name": org.name,
                "href": format!("{}/projects", org_path(&org.id)),
                "role": role_label(org.role),
                "initial": initial(&org.name),
            })
        })
        .collect()
}

pub fn project_row(org: &OrgId, project: &Project, open_issues: Option<usize>) -> Value {
    let mut row =
        json!({"id": project.id.0, "name": project.name, "href": project_path(org, project.id)});
    if let Some(count) = open_issues {
        row["open_issues"] = json!(count);
    }
    row
}

pub fn role_label(role: crate::domain::Role) -> &'static str {
    match role {
        crate::domain::Role::Owner => "Owner",
        crate::domain::Role::Admin => "Admin",
        crate::domain::Role::Member => "Member",
    }
}

/// Field and message for a service error on a form, or the error itself.
pub fn form_error(error: ApiError) -> Result<(&'static str, &'static str), WebError> {
    let code = match &error {
        ApiError::BadRequest(code) | ApiError::Conflict(code) | ApiError::Unavailable(code) => {
            *code
        }
        _ => return Err(error.into()),
    };
    policy::field_message(code).ok_or_else(|| error.into())
}
