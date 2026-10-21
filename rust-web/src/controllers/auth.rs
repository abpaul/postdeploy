use axum::{
    extract::State,
    http::{header, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json,
};
use loco_rs::{app::AppContext, controller::Routes};
use serde::Deserialize;
use serde_json::json;

use crate::{
    error::{ApiError, ApiResult},
    identity::{access::Session, accounts},
    runtime::Runtime,
    services::Services,
};

#[derive(Deserialize)]
struct Credentials {
    email: String,
    password: credseal::SecretString,
    #[serde(default)]
    cf_turnstile_response: Option<credseal::SecretString>,
}

async fn security_check(ctx: &AppContext, body: &Credentials) -> ApiResult<()> {
    if let Some(turnstile) = &Services::get(ctx).turnstile {
        let token = body
            .cf_turnstile_response
            .as_ref()
            .map_or("", |token| token.expose_secret());
        if !turnstile.verify(token, None).await {
            return Err(ApiError::BadRequest("security_check_failed"));
        }
    }
    Ok(())
}

fn granted(rt: &Runtime, status: StatusCode, grant: accounts::SessionGrant) -> Response {
    let cookie = accounts::session_cookie(rt, &grant.token, grant.max_age);
    (
        status,
        [(header::SET_COOKIE, cookie)],
        Json(json!({ "user": grant.user, "csrf_token": grant.csrf_token })),
    )
        .into_response()
}

async fn signup(
    State(ctx): State<AppContext>,
    Json(body): Json<Credentials>,
) -> ApiResult<Response> {
    security_check(&ctx, &body).await?;
    let rt = Runtime::get(&ctx);
    let grant = accounts::signup(&rt, &body.email, body.password.expose_secret()).await?;
    Ok(granted(&rt, StatusCode::CREATED, grant))
}

async fn login(
    State(ctx): State<AppContext>,
    Json(body): Json<Credentials>,
) -> ApiResult<Response> {
    security_check(&ctx, &body).await?;
    let rt = Runtime::get(&ctx);
    let grant = accounts::login(&rt, &body.email, body.password.expose_secret()).await?;
    Ok(granted(&rt, StatusCode::OK, grant))
}

async fn logout(State(ctx): State<AppContext>, session: Session) -> ApiResult<Response> {
    let rt = Runtime::get(&ctx);
    accounts::logout(&rt, &session).await?;
    let cookie = accounts::session_cookie(&rt, "", 0);
    Ok((StatusCode::NO_CONTENT, [(header::SET_COOKIE, cookie)]).into_response())
}

async fn current(session: Session) -> Json<serde_json::Value> {
    Json(json!({
        "user": {"id": session.user, "email": session.email},
        "csrf_token": session.csrf_token,
    }))
}

pub fn routes() -> Routes {
    Routes::new()
        .prefix("/api/auth")
        .add("/signup", post(signup))
        .add("/login", post(login))
        .add("/logout", post(logout))
        .add("/session", get(current))
}
