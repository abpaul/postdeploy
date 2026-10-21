use axum::{body::Bytes, extract::Path, response::Response};
use serde_json::{json, Value};

use crate::{
    account_settings,
    error::ApiError,
    identity::{access::authorize, orgs, projects},
};

use super::{
    page::{form_error, org_path, project_path, redirect, Fields, Flash, Page, Web, WebResult},
    policy,
};

pub async fn index(web: Web) -> WebResult {
    let session = web.signed().await?;
    let (mut page, _) = web.account_page(&session, "Dashboard", "dashboard").await?;
    let mut rows = Vec::new();
    let mut total = 0;
    for org in orgs::list(&web.rt, session.user).await? {
        let access = authorize(&web.rt, session.user, &org.id).await?;
        let count = projects::list(&web.rt, &access).await?.len();
        total += count;
        let mut row = super::page::org_rows(std::slice::from_ref(&org)).remove(0);
        row["project_count"] = json!(count);
        rows.push(row);
    }
    page.set("organizations", rows)
        .set("project_total", total)
        .set("page_heading", true)
        .set("crumbs", json!([{"label": "Dashboard", "href": ""}]));
    Ok(web.render(page, "dashboard/index.html"))
}

async fn account_page(
    web: &Web,
    session: &crate::identity::access::Session,
) -> WebResult<(Page, String)> {
    let (mut page, account) = web.account_page(session, "Account", "account").await?;
    let name = account.name.unwrap_or_default();
    page.set("values", json!({"name": name}))
        .set("name_action", "/dashboard/account/name")
        .set("email_action", "/dashboard/account/email")
        .set(
            "confirmation_action",
            if account.confirmed {
                ""
            } else {
                "/dashboard/account/confirmation"
            },
        )
        .set(
            "pending_email",
            account.pending_email.map_or(Value::Null, Value::String),
        );
    Ok((page, name))
}

pub async fn account(web: Web) -> WebResult {
    let session = web.signed().await?;
    let (page, _) = account_page(&web, &session).await?;
    Ok(web.render(page, "dashboard/account.html"))
}

pub async fn account_name(web: Web, body: Bytes) -> WebResult {
    let fields = Fields::parse(&body);
    let session = web.signed_form(&fields).await?;
    match account_settings::update_name(&web.rt, &session, fields.get("name")).await {
        Ok(_) => Ok(web.redirect_flash("/dashboard/account", Flash::Info, "Name saved.")),
        Err(error) => {
            let (field, message) = form_error(error)?;
            let (mut page, _) = account_page(&web, &session).await?;
            page.invalid(field, message, json!({"name": fields.get("name")}));
            Ok(web.render(page, "dashboard/account.html"))
        }
    }
}

pub async fn account_email(web: Web, body: Bytes) -> WebResult {
    let fields = Fields::parse(&body);
    let session = web.signed_form(&fields).await?;
    let mail = web.svc.account_mail.as_ref();
    match account_settings::request_email_change(&web.rt, mail, &session, fields.get("email")).await {
        Ok(()) => Ok(web.redirect_flash(
            "/dashboard/account",
            Flash::Info,
            "Confirmation link sent to the new address. Your current address works until you open it.",
        )),
        Err(error) => {
            let (field, message) = form_error(error)?;
            let (mut page, name) = account_page(&web, &session).await?;
            page.invalid(field, message, json!({"name": name, "email": fields.get("email")}));
            Ok(web.render(page, "dashboard/account.html"))
        }
    }
}

pub async fn account_confirmation(web: Web, body: Bytes) -> WebResult {
    let fields = Fields::parse(&body);
    let session = web.signed_form(&fields).await?;
    let mail = web.svc.account_mail.as_ref();
    let (kind, message) =
        match account_settings::send_account_confirmation(&web.rt, mail, &session).await {
            Ok(()) => (Flash::Info, "Confirmation link sent. Check your inbox."),
            Err(ApiError::Conflict("already_confirmed")) => {
                (Flash::Info, "Your email address is already confirmed.")
            }
            Err(error) => (Flash::Error, form_error(error)?.1),
        };
    Ok(web.redirect_flash("/dashboard/account", kind, message))
}

/// The authorization request a new organization resumes, and the line that
/// names the waiting agent.
async fn agent_waiting(web: &Web, return_to: &str) -> WebResult<Option<(String, String)>> {
    let Some(path) = policy::agent_return(return_to) else {
        return Ok(None);
    };
    let query = Fields::parse(path.split_once('?').map_or("", |(_, q)| q).as_bytes());
    let name = web
        .svc
        .oauth
        .client_name(query.get("client_id"))
        .await
        .map_err(super::org::oauth_error)?;
    let line = format!(
        "Create an organization to finish connecting {}.",
        name.as_deref().unwrap_or("your agent")
    );
    Ok(Some((path.to_owned(), line)))
}

async fn new_org_page(
    web: &Web,
    session: &crate::identity::access::Session,
    return_to: &str,
) -> WebResult<Page> {
    let (mut page, _) = web
        .account_page(session, "Create your organization", "dashboard")
        .await?;
    page.set("form_action", "/dashboard/orgs/new")
        .set("create_allowed", true);
    if let Some((path, line)) = agent_waiting(web, return_to).await? {
        page.set("return_to", path).set("agent_waiting", line);
    }
    Ok(page)
}

pub async fn new_org_form(web: Web) -> WebResult {
    let session = web.signed().await?;
    let query = Fields::parse(web.uri.split_once('?').map_or("", |(_, q)| q).as_bytes());
    let page = new_org_page(&web, &session, query.get("return_to")).await?;
    Ok(web.render(page, "orgs/new.html"))
}

pub async fn new_org(web: Web, body: Bytes) -> WebResult {
    let fields = Fields::parse(&body);
    let session = web.signed_form(&fields).await?;
    match orgs::create(&web.rt, session.user, fields.get("name")).await {
        Ok(org) => Ok(redirect(
            policy::agent_return(fields.get("return_to"))
                .unwrap_or(&format!("{}/projects", org_path(&org.id))),
        )),
        Err(error) => {
            let (field, message) = form_error(error)?;
            let mut page = new_org_page(&web, &session, fields.get("return_to")).await?;
            page.invalid(field, message, json!({"name": fields.get("name")}));
            Ok(web.render(page, "orgs/new.html"))
        }
    }
}

pub async fn org_home(web: Web, Path(org): Path<String>) -> WebResult {
    let cx = web.member(&org).await?;
    Ok(redirect(&format!("{}/projects", cx.base)))
}

pub async fn open_project(web: Web, Path(org): Path<String>) -> WebResult<Response> {
    let cx = web.member(&org).await?;
    let query = Fields::parse(web.uri.split_once('?').map_or("", |(_, q)| q).as_bytes());
    let project = query
        .get("project_id")
        .parse::<i64>()
        .ok()
        .and_then(|id| cx.project(id).ok());
    Ok(match project {
        Some(project) => redirect(&project_path(&cx.org.id, project.id)),
        None => redirect(&format!("{}/projects", cx.base)),
    })
}
