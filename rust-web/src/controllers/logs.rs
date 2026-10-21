use std::{convert::Infallible, time::Duration};

use axum::{
    extract::{Query, State},
    http::HeaderMap,
    response::{
        sse::{Event, KeepAlive, Sse},
        IntoResponse, Response,
    },
    routing::get,
    Json,
};
use futures::StreamExt;
use loco_rs::{app::AppContext, controller::Routes};
use serde_json::json;

use crate::{
    error::ApiResult,
    identity::access::OrgAccess,
    logs::read::{self, LogQuery, TailEvent, TailRequest},
    runtime::Runtime,
};

async fn search(
    State(ctx): State<AppContext>,
    access: OrgAccess,
    Query(query): Query<LogQuery>,
) -> ApiResult<Response> {
    let rt = Runtime::get(&ctx);
    let admitted = rt.admission.queries.expensive(&access.org)?;
    let page = read::search(&rt, &access, &admitted, query).await?;
    Ok(Json(page).into_response())
}

/// Archive progress of the organization's logs.
async fn storage(State(ctx): State<AppContext>, access: OrgAccess) -> ApiResult<Response> {
    let status = crate::logs::storage::status(&Runtime::get(&ctx), &access.org).await?;
    Ok(Json(status).into_response())
}

fn sse_event(event: TailEvent) -> Event {
    let (name, id, data) = match event {
        TailEvent::Entries { rows, cursor } => (
            "entries",
            cursor,
            json!({ "rows": rows, "cursor": cursor.to_string() }),
        ),
        TailEvent::Gap { reason, resume } => (
            "gap",
            resume,
            json!({ "reason": reason, "resume": resume.to_string() }),
        ),
        TailEvent::Closing { resume } => {
            ("closing", resume, json!({ "resume": resume.to_string() }))
        }
    };
    Event::default()
        .event(name)
        .id(id.to_string())
        .json_data(data)
        .unwrap_or_else(|_| Event::default().event("closing"))
}

async fn tail(
    State(ctx): State<AppContext>,
    access: OrgAccess,
    headers: HeaderMap,
    Query(mut request): Query<TailRequest>,
) -> ApiResult<Response> {
    let rt = Runtime::get(&ctx);
    if request.after.is_none() {
        request.after = headers
            .get("last-event-id")
            .and_then(|v| v.to_str().ok())
            .map(str::to_owned);
    }
    let keep_alive = Duration::from_secs(rt.settings.logs.tail.keep_alive_secs.max(1));
    let stream = read::tail(rt, access, request).await?;
    let events = stream.map(|event| Ok::<_, Infallible>(sse_event(event)));
    Ok(Sse::new(events)
        .keep_alive(KeepAlive::new().interval(keep_alive))
        .into_response())
}

pub fn routes() -> Routes {
    Routes::new()
        .prefix("/api/orgs/{org}/logs")
        .add("/", get(search))
        .add("/tail", get(tail))
        .add("/storage", get(storage))
}
