use axum::{extract::State, http::StatusCode, response::IntoResponse, routing::get, Json};
use loco_rs::{app::AppContext, controller::Routes};
use serde_json::json;

use crate::{runtime::Runtime, services::Services};

async fn health(State(ctx): State<AppContext>) -> impl IntoResponse {
    let rt = Runtime::get(&ctx);
    if rt.gate.is_open() {
        let backups = Services::get(&ctx).backups.health(&rt).await;
        (
            StatusCode::OK,
            Json(json!({"status": "ok", "backups": backups})),
        )
    } else {
        (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({"status": "draining"})),
        )
    }
}

pub fn routes() -> Routes {
    Routes::new().add("/healthz", get(health))
}
