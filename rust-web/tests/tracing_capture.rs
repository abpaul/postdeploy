//! Operational output must not contain tool results even when the environment
//! asks for trace logging. The parent test runs `capture_child` in a child
//! process whose logger is installed the way Loco's CLI does it
//! (`App::init_logger`), and reads the child's real stdout and stderr.

#[path = "support/mcp.rs"]
mod common;

use std::{collections::BTreeSet, process::Command};

use common::*;
use loco_rs::app::Hooks;
use postdeploy::app::App;
use reqwest::StatusCode;
use serde_json::{json, Value};

/// Prefixes the child's one stdout line that carries the hex-encoded tool
/// secrets. The hex form cannot match a raw secret, and the line is excluded
/// from the search.
const SECRETS_LINE: &str = "MCP_CAPTURE_SECRETS ";

/// Runs `capture_child` in a child process and returns the targets of output
/// lines that contain a tool secret, plus the whole output. Output stays in
/// memory.
fn capture(logger: &str) -> (BTreeSet<String>, String) {
    let output = Command::new(std::env::current_exe().unwrap())
        .args([
            "--ignored",
            "--exact",
            "capture_child",
            "--nocapture",
            "--test-threads=1",
        ])
        .env("RUST_LOG", "trace")
        .env("POSTDEPLOY_LOG", "true")
        .env("MCP_CAPTURE_LOGGER", logger)
        .output()
        .unwrap();
    assert!(output.status.success(), "{logger} capture child failed");
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let encoded = text
        .lines()
        .find_map(|line| line.strip_prefix(SECRETS_LINE))
        .expect("capture child reported its secrets");
    let secrets: Vec<String> = serde_json::from_slice(&hex::decode(encoded).unwrap()).unwrap();
    let leaks = text
        .lines()
        .filter(|line| !line.starts_with(SECRETS_LINE))
        .filter(|line| secrets.iter().any(|secret| line.contains(secret.as_str())))
        .map(|line| {
            line.split_whitespace()
                .find(|word| word.ends_with(':') && word.contains("::"))
                .unwrap_or("<no target>")
                .trim_end_matches(':')
                .to_owned()
        })
        .collect();
    println!(
        "{logger} capture: {} bytes, targets with tool data: {leaks:?}",
        text.len()
    );
    (leaks, text)
}

#[test]
fn trace_environment_cannot_put_tool_results_in_operational_output() {
    let (leaks, text) = capture("app");
    assert!(
        text.contains("postdeploy::app"),
        "operational output had no application events"
    );
    assert_eq!(leaks, BTreeSet::new());
}

/// Control for the observation method: the same flow under a plain `trace`
/// subscriber must expose the tool data that the application logger filters.
#[test]
fn unfiltered_trace_subscriber_exposes_tool_results() {
    let (leaks, _) = capture("unfiltered");
    assert!(
        leaks.iter().any(|target| target.starts_with("rmcp::")),
        "{leaks:?}"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "run as a child process by trace_environment_cannot_put_tool_results_in_operational_output"]
async fn capture_child() {
    let f = fixture_with("trace-capture", |config| config.logger.enable = true).await;
    if std::env::var("MCP_CAPTURE_LOGGER").as_deref() == Ok("unfiltered") {
        tracing_subscriber::fmt()
            .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
            .with_ansi(false)
            .with_target(true)
            .compact()
            .init();
    } else {
        assert!(
            App::init_logger(&f.boot.app_context).unwrap(),
            "App::init_logger declined"
        );
    }

    let marker = format!("mcp-capture-{}", uuid::Uuid::now_v7().simple());
    let org = f.org("owner@capture.test", "Capture").await;
    let token = f.token(org.owner, &org.id, Some(FULL)).await;
    let (_, _, dsn) = f.source(&token, "web").await;
    let dsn_key = dsn
        .split_once("://")
        .unwrap()
        .1
        .split_once('@')
        .unwrap()
        .0
        .to_owned();
    let logs = [("error", marker.as_str(), TRACE)];
    let event = envelope(
        "ffffffffffffffffffffffffffffff09",
        &format!("{marker} issue"),
        &logs,
    );
    assert_eq!(f.ingest(&dsn, event).await, StatusCode::OK);
    let rows = f
        .call(&token, "search_logs", json!({ "query": marker }))
        .await;
    assert!(
        rows["structuredContent"]["rows"][0]["body"] == marker.as_str(),
        "log evidence must round trip"
    );
    let payload = f
        .call(
            &token,
            "get_issue_event",
            json!({ "issue_id": 1, "event_id": "ffffffffffffffffffffffffffffff09" }),
        )
        .await;
    assert!(
        payload["structuredContent"]["payload"]["exception"]["values"][0]["value"]
            == Value::String(format!("{marker} issue")),
        "event evidence must round trip"
    );
    let rotated = f
        .call(&token, "create_source_key", json!({ "source_id": 1 }))
        .await;
    let rotated_key = rotated["structuredContent"]["dsn"]
        .as_str()
        .unwrap()
        .split_once("://")
        .unwrap()
        .1
        .split_once('@')
        .unwrap()
        .0
        .to_owned();
    let login = f
        .http
        .post(format!("{}/api/auth/login", f.base))
        .json(&json!({"email": "owner@capture.test", "password": PASSWORD}))
        .send()
        .await
        .unwrap();
    let cookie = login.headers()["set-cookie"]
        .to_str()
        .unwrap()
        .split(';')
        .next()
        .unwrap()
        .to_owned();
    let csrf = login.json::<Value>().await.unwrap()["csrf_token"]
        .as_str()
        .unwrap()
        .to_owned();
    let created: Value = f
        .http
        .post(format!("{}/api/orgs/{}/api-keys", f.base, org.id))
        .header("cookie", &cookie)
        .header("x-csrf-token", &csrf)
        .json(&json!({"name": "capture"}))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let api_key = created["secret"].as_str().unwrap().to_owned();
    let listed = f
        .http
        .get(format!("{}/api/orgs/{}/issues", f.base, org.id))
        .bearer_auth(&api_key)
        .send()
        .await
        .unwrap();
    assert_eq!(listed.status(), StatusCode::OK, "API key reads issues");
    let mcp = f.call(&api_key, "list_issues", json!({})).await;
    assert!(
        mcp["structuredContent"]["issues"][0]["id"] == 1,
        "API key reads issues through MCP"
    );
    let secrets = json!([marker, dsn_key, rotated_key, token, api_key]).to_string();
    println!("{SECRETS_LINE}{}", hex::encode(secrets));
}
