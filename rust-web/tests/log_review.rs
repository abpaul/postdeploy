mod support;

use std::{sync::atomic::Ordering, time::Duration};

use loco_rs::app::Hooks;
use postdeploy::{
    runtime::Runtime,
    testing::{serve, TestApp, TestEnv},
};
use reqwest::StatusCode;
use serde_json::json;
use support::*;

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_empty_search_page_keeps_the_first_unscanned_object_on_timeout() {
    let env = TestEnv::new("search-timeout-frontier");
    let boot = env
        .boot_memory(|settings| {
            settings["logs"]["batch_max_age_ms"] = json!(50);
            settings["logs"]["archive_tick_ms"] = json!(20);
            settings["logs"]["search"]["timeout_ms"] = json!(50);
            settings["logs"]["search"]["concurrency"] = json!(1);
        })
        .await
        .unwrap();
    let (base, _server) = serve(&boot).await;
    let api = Api::signup(&base, "timeout-review@example.test").await;
    let (org, project, dsn) = api.setup_source("Timeout review").await;
    let key = dsn_key(&dsn);
    for (archived, body) in [(1, "reviewolderneedle"), (2, "reviewnewerunrelated")] {
        assert_eq!(
            post_envelope(&base, project, &key, envelope(None, &[body]), None)
                .await
                .0,
            StatusCode::OK
        );
        eventually(Duration::from_secs(10), || {
            let api = api.clone();
            let org = org.clone();
            async move {
                let (_, status) = api.get(&format!("/api/orgs/{org}/logs/storage")).await;
                status["archived_objects"] == archived && status["pending_entries"] == 0
            }
        })
        .await;
    }
    let rt = Runtime::get(&boot.app_context);
    rt.cancel.cancel();
    tokio::time::sleep(Duration::from_millis(100)).await;
    let gets = rt.store.counters().gets.load(Ordering::Relaxed);
    env.faults
        .delay_get_after
        .store(gets + 2, Ordering::Relaxed);
    env.faults.delay_get_ms.store(500, Ordering::Relaxed);
    let (status, page) = api
        .get(&format!("/api/orgs/{org}/logs?q=reviewolderneedle"))
        .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(page["rows"], json!([]));
    assert_eq!(page["coverage"]["objects"], json!(1));
    assert_eq!(page["coverage"]["truncated_by"], json!("timeout"));
    assert_eq!(page["next"], json!("c1.1.4294967295"));
    env.faults.delay_get_ms.store(0, Ordering::Relaxed);
    let cursor = page["next"].as_str().unwrap();
    let (status, resumed) = api
        .get(&format!(
            "/api/orgs/{org}/logs?q=reviewolderneedle&before={cursor}"
        ))
        .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(resumed["rows"].as_array().unwrap().len(), 1);
    assert_eq!(resumed["rows"][0]["body"], json!("reviewolderneedle"));
    assert_eq!(resumed["coverage"]["truncated_by"], serde_json::Value::Null);
    TestApp::on_shutdown(&boot.app_context).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn transport_http_counters_record_methods_and_cancelled_attempt_lifetimes() {
    use axum::{
        body::Body,
        http::{Method, Request, StatusCode as HttpStatus},
        response::{IntoResponse, Response},
        Router,
    };
    use postdeploy::{
        credentials::R2Credentials,
        store::{ObjectStore, StoreError},
    };

    async fn object(request: Request<Body>) -> Response {
        if request.uri().path().ends_with("/failed") {
            return HttpStatus::SERVICE_UNAVAILABLE.into_response();
        }
        if request.uri().path().ends_with("/slow") {
            tokio::time::sleep(Duration::from_secs(1)).await;
        }
        match *request.method() {
            Method::HEAD => (HttpStatus::OK, [("content-length", "12")], "").into_response(),
            Method::GET => (HttpStatus::OK, "physicaldata").into_response(),
            Method::DELETE => HttpStatus::NO_CONTENT.into_response(),
            _ => HttpStatus::OK.into_response(),
        }
    }
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        axum::serve(listener, Router::new().fallback(object))
            .await
            .unwrap();
    });
    let credentials: R2Credentials = serde_json::from_value(json!({"endpoint":format!("http://{address}"),"bucket":"isolated-counter-fixture","access_key_id":"isolated-counter-fixture","secret_access_key":"isolated-counter-fixture"})).unwrap();
    let store = ObjectStore::r2(&credentials, "local/", Duration::from_millis(100)).unwrap();
    store
        .put("record", bytes::Bytes::from_static(b"physicaldata"))
        .await
        .unwrap();
    assert_eq!(
        store.get("record", 12).await.unwrap().unwrap().as_ref(),
        b"physicaldata"
    );
    store.delete("record").await.unwrap();
    let counters = store.counters();
    assert_eq!(
        (
            counters.http_requests.load(Ordering::Relaxed),
            counters.http_head.load(Ordering::Relaxed),
            counters.http_get.load(Ordering::Relaxed),
            counters.http_put.load(Ordering::Relaxed),
            counters.http_delete.load(Ordering::Relaxed)
        ),
        (4, 1, 1, 1, 1)
    );
    assert_eq!(
        (
            counters.http_completed.load(Ordering::Relaxed),
            counters.http_failed.load(Ordering::Relaxed),
            counters.http_cancelled.load(Ordering::Relaxed)
        ),
        (4, 0, 0)
    );
    assert_eq!(
        (
            counters.http_inflight.load(Ordering::Relaxed),
            counters.http_put_inflight.load(Ordering::Relaxed),
            counters.http_inflight_peak.load(Ordering::Relaxed),
            counters.http_put_inflight_peak.load(Ordering::Relaxed)
        ),
        (0, 0, 1, 1)
    );
    assert!(counters.http_head_duration_us.load(Ordering::Relaxed) > 0);
    assert!(counters.http_get_duration_us.load(Ordering::Relaxed) > 0);
    assert!(counters.http_put_duration_us.load(Ordering::Relaxed) > 0);
    assert!(counters.http_delete_duration_us.load(Ordering::Relaxed) > 0);

    assert!(store
        .put("failed", bytes::Bytes::from_static(b"failed"))
        .await
        .is_err());
    assert_eq!(counters.http_failed.load(Ordering::Relaxed), 1);
    assert!(matches!(
        store
            .put("slow", bytes::Bytes::from_static(b"cancelled"))
            .await,
        Err(StoreError::Timeout)
    ));
    assert_eq!(
        (
            counters.http_requests.load(Ordering::Relaxed),
            counters.http_put.load(Ordering::Relaxed),
            counters.http_completed.load(Ordering::Relaxed),
            counters.http_cancelled.load(Ordering::Relaxed)
        ),
        (6, 3, 5, 1)
    );
    assert_eq!(
        (
            counters.http_inflight.load(Ordering::Relaxed),
            counters.http_put_inflight.load(Ordering::Relaxed)
        ),
        (0, 0)
    );
    assert!(
        counters.http_put_max_duration_us.load(Ordering::Relaxed) >= 50_000,
        "the cancelled attempt contributes its observed lifetime"
    );
    server.abort();
}
