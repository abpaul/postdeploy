mod support;

use std::time::Duration;

use loco_rs::{app::Hooks, boot::BootResult};
use postdeploy::{
    app::App,
    logs::{
        object::{decode, encode_batch, BatchIdentity},
        record::LogRecord,
    },
    runtime::Runtime,
    testing::{serve, TestApp, TestEnv},
};
use reqwest::StatusCode;
use serde_json::{json, Value};
use support::*;

fn log_envelope(items: Vec<Value>) -> Vec<u8> {
    let payload = json!({"items": items}).to_string();
    format!(
        "{{}}\n{}\n{payload}\n",
        json!({"type":"log", "item_count":1,"length":payload.len()})
    )
    .into_bytes()
}

async fn tail(api: &Api, org: &str) -> reqwest::Response {
    tail_after(api, org, "c1.0.4294967295").await
}

async fn tail_after(api: &Api, org: &str, after: &str) -> reqwest::Response {
    api.http
        .get(format!(
            "{}/api/orgs/{org}/logs/tail?after={after}",
            api.base
        ))
        .header("cookie", api.cookie.clone().unwrap())
        .send()
        .await
        .unwrap()
}

async fn attribute_boundary(boot: &BootResult) {
    let (base, server) = serve(boot).await;
    let api = Api::signup(&base, "log-boundary@example.test").await;
    let (org, project, dsn) = api.setup_source("Attribute boundary").await;
    let items = vec![
        json!({"level":"info", "body":"bounded-record-proof", "attributes": {
            "unsupported":{"type":"object","value":{"password":"nested-isolated-secret"},"extra":"token=extra-isolated-secret"},
            "mismatched":{"type":"string","value":{"nested":"mismatched-isolated-secret"}},
            "mixed":{"type":"array","value":["mixed-isolated-secret",{}]},
            "integer":{"type":"integer","value":7,"extra":"extra-field-isolated-secret"},
            "message":{"type":"string","value":"token=direct-isolated-secret"},
            "list":{"type":"array","value":["first","token=array-isolated-secret"]},
            "password":{"type":"string","value":"sensitive-isolated-secret"},
            "token=key-isolated-secret":{"type":"string","value":"key-value-isolated-secret"},
            "oversized":{"type":"string","value":"x".repeat(4 << 20)}
        }}),
    ];
    use std::io::Write;
    let mut gzip = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
    gzip.write_all(&log_envelope(items)).unwrap();
    let (status, _) = post_envelope(
        &base,
        project,
        &dsn_key(&dsn),
        gzip.finish().unwrap(),
        Some("gzip"),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    wait_archived(&api, &org).await;
    let rt = Runtime::get(&boot.app_context);
    let keys = rt.store.list_page("logs/", None, 10).await.unwrap().keys;
    assert_eq!(keys.len(), 1);
    let stored = rt.store.get(&keys[0], 4 << 20).await.unwrap().unwrap();
    let records = stored_records(&stored);
    let serialized = serde_json::to_string(&records).unwrap();
    assert!(
        !serialized.contains("isolated-secret"),
        "secret reached the persisted object"
    );
    assert!(
        serialized.len() < 65_536,
        "accepted record exceeds its byte budget"
    );
    let attrs = records[0].attributes.as_map();
    assert_eq!(attrs["integer"], json!({"type":"integer","value":7}));
    assert_eq!(
        attrs["list"],
        json!({"type":"array","value":["first","token=[Filtered]"]})
    );
    assert!(
        !attrs.contains_key("unsupported")
            && !attrs.contains_key("mismatched")
            && !attrs.contains_key("mixed")
    );
    let (status, page) = api.get(&format!("/api/orgs/{org}/logs")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(page["rows"][0]["body"], "bounded-record-proof");
    assert!(!page.to_string().contains("isolated-secret"));
    let events = read_sse(tail(&api, &org).await, Duration::from_secs(3), |name, _| {
        name == "entries"
    })
    .await;
    assert!(
        events
            .iter()
            .any(|(name, data)| name == "entries"
                && data["rows"][0]["body"] == "bounded-record-proof")
    );
    assert!(!serde_json::to_string(&events)
        .unwrap()
        .contains("isolated-secret"));
    App::on_shutdown(&boot.app_context).await;
    server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn unsupported_attributes_and_secrets_never_reach_stored_search_or_tail_records() {
    let env = TestEnv::new("log-record-boundary");
    let boot = env
        .boot_memory(|s| {
            fast_archive(s);
            s["ingest"]["max_inflated_bytes"] = json!(8 << 20);
        })
        .await
        .unwrap();
    attribute_boundary(&boot).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "requires isolated R2 credentials"]
async fn real_r2_stored_search_and_tail_records_apply_the_attribute_boundary() {
    let path = std::env::var_os("POSTDEPLOY_CREDENTIALS_FILE").unwrap();
    let credentials =
        postdeploy::credentials::Credentials::load(std::path::Path::new(&path), "test").unwrap();
    assert_eq!(credentials.r2.bucket, "postdeploy-rust-local-test-20261015");
    let env = TestEnv::new("log-record-r2-boundary");
    let prefix = format!(
        "local-verification/record-security-{}/",
        uuid::Uuid::now_v7().simple()
    );
    let boot = env
        .boot_r2(&prefix, |s| {
            fast_archive(s);
            s["ingest"]["max_inflated_bytes"] = json!(8 << 20);
        })
        .await
        .unwrap();
    let store = Runtime::get(&boot.app_context).store.clone();
    attribute_boundary(&boot).await;
    let owned = store.list_page("", None, 100).await.unwrap().keys;
    for key in &owned {
        store.delete(key).await.unwrap();
    }
    assert!(store.list_page("", None, 10).await.unwrap().keys.is_empty());
    println!("record security prefix={prefix} removed={}", owned.len());
}

#[test]
fn record_byte_cost_includes_json_escaping_and_ndjson_separator() {
    let record: LogRecord = serde_json::from_value(
        json!({"ts":1,"rt":1,"level":"info","body":"\u{0001}".repeat(1_000),"attributes":{}}),
    )
    .unwrap();
    assert_eq!(
        record.approx_bytes(),
        serde_json::to_vec(&record).unwrap().len() + 1
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn legacy_oversized_entry_emits_an_advancing_gap_and_delivers_the_next_entry() {
    let env = TestEnv::new("legacy-log-record-boundary");
    let boot = env
        .boot_memory(|s| {
            fast_archive(s);
            s["logs"]["tail"]["replay_max_output_bytes"] = json!(4_000);
            s["logs"]["search"]["max_output_bytes"] = json!(4_000);
        })
        .await
        .unwrap();
    let (base, server) = serve(&boot).await;
    let api = Api::signup(&base, "legacy-record@example.test").await;
    let (org, project, dsn) = api.setup_source("Legacy boundary").await;
    assert_eq!(
        post_envelope(
            &base,
            project,
            &dsn_key(&dsn),
            envelope(None, &["legacy-first", "after-legacy-record"]),
            None
        )
        .await
        .0,
        StatusCode::OK
    );
    wait_archived(&api, &org).await;
    let rt = Runtime::get(&boot.app_context);
    let key = rt
        .store
        .list_page("logs/", None, 10)
        .await
        .unwrap()
        .keys
        .remove(0);
    let body = rt.store.get(&key, 4 << 20).await.unwrap().unwrap();
    let Ok((header, mut entries)) = decode(&body, 12 << 20) else {
        panic!("archived object is a batch");
    };
    let mut legacy = serde_json::to_value(&entries[0].record).unwrap();
    legacy["body"] = json!("x".repeat(5_000));
    entries[0].record = serde_json::from_value(legacy).unwrap();
    let mut legacy = serde_json::to_value(&entries[1].record).unwrap();
    legacy["attributes"] = json!({"bad":{"type":"object","value":{"password":"legacy-isolated-secret"}},"good":{"type":"string","value":"token=legacy-direct-isolated-secret","extra":"legacy-extra-isolated-secret"}});
    entries[1].record = serde_json::from_value(legacy).unwrap();
    let identity = BatchIdentity {
        org: header.org,
        object_id: header.object_id,
        key: header.key,
        usage_day: header.usage_day,
        opened_at: header.opened_at,
    };
    rt.store
        .put(&key, encode_batch(&identity, &entries).unwrap().body)
        .await
        .unwrap();
    let events = read_sse(
        tail(&api, &org).await,
        Duration::from_secs(3),
        |name, data| name == "entries" && data.to_string().contains("after-legacy-record"),
    )
    .await;
    let gap = events
        .iter()
        .find(|(name, data)| name == "gap" && data["reason"] == "record_too_large")
        .expect("oversized record has an explicit gap");
    assert_ne!(
        gap.1["resume"], "c1.0.4294967295",
        "gap advances beyond the oversized record"
    );
    assert!(events
        .iter()
        .any(|(name, data)| name == "entries" && data["rows"][0]["body"] == "after-legacy-record"));
    assert!(!serde_json::to_string(&events)
        .unwrap()
        .contains("isolated-secret"));
    let resumed = read_sse(
        tail_after(&api, &org, gap.1["resume"].as_str().unwrap()).await,
        Duration::from_secs(3),
        |name, _| name == "entries",
    )
    .await;
    assert!(!resumed
        .iter()
        .any(|(name, data)| name == "gap" && data["reason"] == "record_too_large"));
    assert!(resumed
        .iter()
        .any(|(name, data)| name == "entries" && data["rows"][0]["body"] == "after-legacy-record"));
    let (_, page) = api.get(&format!("/api/orgs/{org}/logs")).await;
    assert!(!page.to_string().contains("isolated-secret"));
    assert!(serde_json::to_vec(&page).unwrap().len() <= 4_000);
    assert_eq!(page["rows"].as_array().unwrap().len(), 1);
    assert_eq!(page["coverage"]["truncated_by"], "record_too_large");
    assert!(page["next"].is_null());
    TestApp::on_shutdown(&boot.app_context).await;
    server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn escaped_records_and_search_pages_respect_serialized_byte_limits() {
    let env = TestEnv::new("escaped-log-record-boundary");
    let boot = env
        .boot_memory(|s| {
            fast_archive(s);
            s["logs"]["max_record_bytes"] = json!(2_000);
            s["logs"]["search"]["max_output_bytes"] = json!(4_000);
            s["logs"]["tail"]["replay_max_output_bytes"] = json!(4_000);
        })
        .await
        .unwrap();
    let (base, server) = serve(&boot).await;
    let api = Api::signup(&base, "escaped-record@example.test").await;
    let (org, project, dsn) = api.setup_source("Escaped record").await;
    let bodies: Vec<String> = (0..6)
        .map(|i| format!("escaped-{i}-{}", "\u{0001}".repeat(200)))
        .collect();
    let mut refs: Vec<&str> = bodies.iter().map(String::as_str).collect();
    let rejected = "\u{0001}".repeat(1_000);
    refs.push(&rejected);
    let response = post_envelope(&base, project, &dsn_key(&dsn), envelope(None, &refs), None).await;
    assert_eq!(
        (response.0, response.1["receipt"]["log"].clone()),
        (
            StatusCode::OK,
            json!({"accepted": 6, "duplicate": 0, "filtered": 0, "sampled": 0, "unsupported": 0,
                "invalid": 1, "reasons": {"record_too_large": 1}})
        ),
        "the oversized record is refused and reported"
    );
    wait_archived(&api, &org).await;
    let rt = Runtime::get(&boot.app_context);
    let keys = rt.store.list_page("logs/", None, 10).await.unwrap().keys;
    let mut count = 0;
    for key in keys {
        let records = stored_records(&rt.store.get(&key, 4 << 20).await.unwrap().unwrap());
        for record in records {
            assert!(serde_json::to_vec(&record).unwrap().len() < 2_000);
            count += 1;
        }
    }
    assert_eq!(count, 6);
    let mut before = None;
    let mut seen = Vec::new();
    for _ in 0..8 {
        let suffix = before
            .as_ref()
            .map(|c| format!("?before={c}"))
            .unwrap_or_default();
        let (status, page) = api.get(&format!("/api/orgs/{org}/logs{suffix}")).await;
        assert_eq!(status, StatusCode::OK);
        assert!(serde_json::to_vec(&page).unwrap().len() <= 4_000);
        seen.extend(
            page["rows"]
                .as_array()
                .unwrap()
                .iter()
                .map(|row| row["body"].as_str().unwrap().to_owned()),
        );
        let Some(next) = page["next"].as_str() else {
            break;
        };
        assert_ne!(before.as_deref(), Some(next), "pagination must advance");
        before = Some(next.to_owned());
    }
    seen.sort();
    assert_eq!(seen, bodies);
    TestApp::on_shutdown(&boot.app_context).await;
    server.abort();
}
