use axum::{
    body::Body,
    extract::{Path, State},
    http::{HeaderMap, Uri},
    response::Response,
    routing::post,
};
use loco_rs::{app::AppContext, controller::Routes};

use crate::runtime::Runtime;

async fn envelope(
    State(ctx): State<AppContext>,
    Path(project): Path<String>,
    uri: Uri,
    headers: HeaderMap,
    body: Body,
) -> Response {
    let rt = Runtime::get(&ctx);
    crate::ingest::envelope(&rt, &project, &headers, uri.query(), body).await
}

async fn native_errors(State(ctx): State<AppContext>, headers: HeaderMap, body: Body) -> Response {
    let rt = Runtime::get(&ctx);
    crate::ingest::native_errors(&rt, &headers, body).await
}

pub fn routes() -> Routes {
    Routes::new()
        .add("/api/{project}/envelope", post(envelope))
        .add("/e/errors", post(native_errors))
}

/// Sentry SDKs post to `/api/{project}/envelope/`. Loco removes trailing
/// slashes from its routes, so this path is added to the finished router.
pub fn with_trailing_slash(router: axum::Router, ctx: &AppContext) -> axum::Router {
    router.route(
        "/api/{project}/envelope/",
        post(envelope).with_state(ctx.clone()),
    )
}
