use axum::{body::Bytes, response::Response};
use credseal::SecretString;
use serde_json::json;

use crate::{
    account_settings::{self, AccountToken},
    error::ApiError,
    identity::{
        access::resolve_session,
        accounts::{self, SessionGrant},
    },
};

use super::{
    page::{
        add_cookie, form_error, org_path, redirect, Fields, Flash, Page, Web, WebError, WebResult,
    },
    policy::{self, PREAUTH_COOKIE, RETURN_COOKIE},
};

const INVALID_LINK: &str = "This link is not valid, has expired, or belongs to another account.";
const SECURITY_CHECK_FAILED: &str = "Security check failed. Please try again.";

fn auth_page(web: &Web, title: &str, action: &str) -> Page {
    let mut page = web.anonymous_page(title, action);
    if let Some(turnstile) = &web.svc.turnstile {
        page.set("turnstile_site_key", turnstile.site_key());
    }
    page
}

async fn security_check(web: &Web, fields: &Fields) -> bool {
    match &web.svc.turnstile {
        Some(turnstile) => {
            turnstile
                .verify(fields.get("cf-turnstile-response"), web.peer)
                .await
        }
        None => true,
    }
}

fn security_rejected(web: &Web, path: &str) -> Response {
    let mut response = redirect(path);
    add_cookie(
        &mut response,
        &web.flash_cookie(Flash::Error, SECURITY_CHECK_FAILED),
    );
    response
}

fn query(web: &Web) -> Fields {
    Fields::parse(web.uri.split_once('?').map_or("", |(_, q)| q).as_bytes())
}

fn start(web: &Web, grant: SessionGrant, fallback: &str) -> Response {
    let target = web.return_to().unwrap_or(fallback).to_owned();
    let mut response = redirect(&target);
    add_cookie(
        &mut response,
        &accounts::session_cookie(&web.rt, &grant.token, grant.max_age),
    );
    add_cookie(
        &mut response,
        &policy::cookie(PREAUTH_COOKIE, "", 0, web.secure()),
    );
    add_cookie(
        &mut response,
        &policy::cookie(RETURN_COOKIE, "", 0, web.secure()),
    );
    response
}

async fn already_signed_in(web: &Web) -> Option<Response> {
    web.session()
        .await
        .map(|_| redirect(web.return_to().unwrap_or("/dashboard")))
}

pub async fn sign_in_form(web: Web) -> Response {
    if let Some(response) = already_signed_in(&web).await {
        return response;
    }
    web.render(auth_page(&web, "Sign in", "/sign-in"), "auth/sign_in.html")
}

pub async fn sign_in(web: Web, body: Bytes) -> WebResult {
    let fields = Fields::parse(&body);
    web.anonymous_form(&fields)?;
    let missing_email = fields.get("email").trim().is_empty();
    let missing_password = fields.get("password").is_empty();
    if missing_email || missing_password {
        let mut page = auth_page(&web, "Sign in", "/sign-in");
        for (field, missing) in [("email", missing_email), ("password", missing_password)] {
            if missing {
                page.invalid(field, "is required", json!({"email": fields.get("email")}));
            }
        }
        return Ok(web.render(page, "auth/sign_in.html"));
    }
    if !security_check(&web, &fields).await {
        return Ok(security_rejected(&web, "/sign-in"));
    }
    match accounts::login(&web.rt, fields.get("email"), fields.get("password")).await {
        Ok(grant) => Ok(start(&web, grant, "/dashboard")),
        Err(ApiError::Unauthorized) => {
            let mut page = auth_page(&web, "Sign in", "/sign-in");
            let (field, message) =
                policy::field_message("invalid_credentials").expect("known code");
            page.invalid(field, message, json!({"email": fields.get("email")}));
            Ok(web.render(page, "auth/sign_in.html"))
        }
        Err(error) => Err(error.into()),
    }
}

pub async fn register_form(web: Web) -> Response {
    if let Some(response) = already_signed_in(&web).await {
        return response;
    }
    web.render(
        auth_page(&web, "Create an account", "/register"),
        "auth/register.html",
    )
}

pub async fn register(web: Web, body: Bytes) -> WebResult {
    let fields = Fields::parse(&body);
    web.anonymous_form(&fields)?;
    if !security_check(&web, &fields).await {
        return Ok(security_rejected(&web, "/register"));
    }
    let rejected = |code| -> WebResult {
        let (field, message) = match code {
            Ok(code) => policy::field_message(code).expect("known code"),
            Err(error) => form_error(error)?,
        };
        let mut page = auth_page(&web, "Create an account", "/register");
        page.invalid(field, message, json!({"email": fields.get("email")}));
        Ok(web.render(page, "auth/register.html"))
    };
    if fields.get("password") != fields.get("password_confirmation") {
        return rejected(Ok("password_mismatch"));
    }
    let grant = match accounts::signup(&web.rt, fields.get("email"), fields.get("password")).await {
        Ok(grant) => grant,
        Err(error) => return rejected(Err(error)),
    };
    let session = resolve_session(&web.rt, &grant.token).await?;
    let sent = account_settings::send_account_confirmation(
        &web.rt,
        web.svc.account_mail.as_ref(),
        &session,
    )
    .await;
    let mut response = start(&web, grant, "/dashboard/orgs/new");
    let (kind, message) = match sent {
        Ok(()) => (Flash::Info, "Account created. Check your inbox for a confirmation link."),
        Err(_) => (Flash::Error, "Account created. The confirmation email could not be sent. Request a new link from your account page."),
    };
    add_cookie(&mut response, &web.flash_cookie(kind, message));
    Ok(response)
}

pub async fn sign_out(web: Web, body: Bytes) -> WebResult {
    let fields = Fields::parse(&body);
    let session = web.signed_form(&fields).await?;
    accounts::logout(&web.rt, &session).await?;
    let mut response = redirect("/sign-in");
    add_cookie(&mut response, &accounts::session_cookie(&web.rt, "", 0));
    Ok(response)
}

fn reset_page(web: &Web, sent: bool) -> Page {
    let mut page = auth_page(web, "Reset your password", "/reset");
    page.set("reset_sent", sent);
    page
}

pub async fn reset_form(web: Web) -> Response {
    let sent = query(&web).get("sent") == "1";
    web.render(reset_page(&web, sent), "auth/reset.html")
}

pub async fn reset(web: Web, body: Bytes) -> WebResult {
    let fields = Fields::parse(&body);
    web.anonymous_form(&fields)?;
    if !security_check(&web, &fields).await {
        return Ok(security_rejected(&web, "/reset"));
    }
    match account_settings::request_password_reset(
        &web.rt,
        web.svc.account_mail.as_ref(),
        fields.get("email"),
    )
    .await
    {
        Ok(()) => Ok(redirect("/reset?sent=1")),
        Err(error) => {
            let (field, message) = form_error(error)?;
            let mut page = reset_page(&web, false);
            page.invalid(field, message, json!({"email": fields.get("email")}));
            Ok(web.render(page, "auth/reset.html"))
        }
    }
}

fn reset_complete_page(web: &Web, token: &str) -> Page {
    let mut page = web.anonymous_page("Choose a new password", "/reset/complete");
    page.set("reset_token", token);
    page
}

pub async fn reset_complete_form(web: Web) -> Response {
    let query = query(&web);
    web.render(
        reset_complete_page(&web, query.get("token")),
        "auth/reset_complete.html",
    )
}

pub async fn reset_complete(web: Web, body: Bytes) -> WebResult {
    let fields = Fields::parse(&body);
    web.anonymous_form(&fields)?;
    let rejected = |field: &str, message: &str| {
        let mut page = reset_complete_page(&web, fields.get("reset_token"));
        page.invalid(field, message, json!({}));
        Ok(web.render(page, "auth/reset_complete.html"))
    };
    if fields.get("password") != fields.get("password_confirmation") {
        let (field, message) = policy::field_message("password_mismatch").expect("known code");
        return rejected(field, message);
    }
    let (Some(token), Some(password)) = (
        fields.typed::<AccountToken>("reset_token"),
        fields.typed::<SecretString>("password"),
    ) else {
        return rejected("reset_token", INVALID_LINK);
    };
    match account_settings::reset_password(&web.rt, &token, &password).await {
        Ok(()) => {
            let mut response = web.redirect_flash(
                "/sign-in",
                Flash::Info,
                "Password changed. Sign in with your new password.",
            );
            add_cookie(&mut response, &accounts::session_cookie(&web.rt, "", 0));
            Ok(response)
        }
        Err(ApiError::NotFound) => rejected("reset_token", INVALID_LINK),
        Err(error) => {
            let (field, message) = form_error(error)?;
            rejected(field, message)
        }
    }
}

#[derive(Clone, Copy, PartialEq)]
pub enum Confirm {
    Account,
    EmailChange,
}

impl Confirm {
    fn path(self) -> &'static str {
        match self {
            Self::Account => account_settings::CONFIRM_ACCOUNT_PATH,
            Self::EmailChange => account_settings::CONFIRM_EMAIL_PATH,
        }
    }
}

async fn confirm_page(web: &Web, kind: Confirm, token: &str) -> WebResult<Page> {
    let session = web.signed().await?;
    let (mut page, account) = web
        .account_page(&session, "Confirm your email", "account")
        .await?;
    page.set("form_action", kind.path())
        .set(
            "confirm_kind",
            if kind == Confirm::Account {
                "account"
            } else {
                "email_change"
            },
        )
        .set("confirm_token", token)
        .set("confirmed", kind == Confirm::Account && account.confirmed);
    Ok(page)
}

pub async fn confirm_form(web: Web, kind: Confirm) -> WebResult {
    let page = confirm_page(&web, kind, query(&web).get("token")).await?;
    Ok(web.render(page, "auth/confirm.html"))
}

pub async fn confirm(web: Web, kind: Confirm, body: Bytes) -> WebResult {
    let fields = Fields::parse(&body);
    let session = web.signed_form(&fields).await?;
    let token = fields
        .typed::<AccountToken>("confirm_token")
        .ok_or(WebError::NotFound)?;
    let result = match kind {
        Confirm::Account => account_settings::confirm_account(&web.rt, &session, &token).await,
        Confirm::EmailChange => {
            account_settings::confirm_email_change(&web.rt, &session, &token).await
        }
    };
    let message = match result {
        Ok(_) if kind == Confirm::Account => {
            return Ok(web.redirect_flash("/dashboard", Flash::Info, "Email address confirmed."))
        }
        Ok(_) => {
            return Ok(web.redirect_flash(
                "/dashboard/account",
                Flash::Info,
                "Email address changed and confirmed.",
            ))
        }
        Err(ApiError::NotFound) => INVALID_LINK,
        Err(ApiError::Conflict("email_taken")) => "That address now belongs to another account.",
        Err(error) => return Err(error.into()),
    };
    let mut page = confirm_page(&web, kind, fields.get("confirm_token")).await?;
    page.invalid("confirm_token", message, json!({}));
    Ok(web.render(page, "auth/confirm.html"))
}

async fn invitation_page(web: &Web, token: &str) -> WebResult<Page> {
    let session = web.signed().await?;
    let (mut page, _) = web
        .account_page(&session, "Join an organization", "dashboard")
        .await?;
    page.set("form_action", account_settings::ACCEPT_INVITATION_PATH)
        .set("invitation_token", token);
    Ok(page)
}

pub async fn invitation_form(web: Web) -> WebResult {
    let page = invitation_page(&web, query(&web).get("token")).await?;
    Ok(web.render(page, "auth/invitation.html"))
}

pub async fn accept_invitation(web: Web, body: Bytes) -> WebResult {
    let fields = Fields::parse(&body);
    let session = web.signed_form(&fields).await?;
    let token = fields
        .typed::<AccountToken>("invitation_token")
        .ok_or(WebError::NotFound)?;
    let message = match account_settings::accept_invitation(&web.rt, &session, &token).await {
        Ok(org) => {
            let target = format!("{}/projects", org_path(&org.id));
            return Ok(web.redirect_flash(&target, Flash::Info, "You joined the organization."));
        }
        Err(ApiError::NotFound) => INVALID_LINK,
        Err(ApiError::Conflict("email_not_confirmed")) => {
            "Confirm your email address first, then open this link again."
        }
        Err(ApiError::Conflict("invitation_email_mismatch")) => {
            "This invitation is for another email address. Sign in with that address to accept it."
        }
        Err(error) => return Err(error.into()),
    };
    let mut page = invitation_page(&web, fields.get("invitation_token")).await?;
    page.invalid("invitation_token", message, json!({}));
    Ok(web.render(page, "auth/invitation.html"))
}
