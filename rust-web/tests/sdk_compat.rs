#[path = "support/mcp.rs"]
mod common;
mod support;

use loco_rs::app::Hooks;
use postdeploy::{
    domain::{now_micros, Environment, OrgId, ProjectId, SourceId},
    identity::access::authorize,
    ingest::event::ErrorEvent,
    issues::{self, Committed, EventSource},
    runtime::sql,
    testing::TestApp,
};
use reqwest::StatusCode;
use sea_orm::ConnectionTrait;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use support::{accepted, dsn_key, post_envelope, Api};

fn fixture(sdk: &str) -> Value {
    let path = format!(
        "{}/tests/fixtures/sdk/{sdk}-error.json",
        env!("CARGO_MANIFEST_DIR")
    );
    serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
}

fn sentry_envelope(event: &Value) -> Vec<u8> {
    format!(
        "{}\n{}\n{}\n",
        json!({"event_id": event["event_id"]}),
        json!({"type": "event"}),
        event
    )
    .into_bytes()
}

async fn html(api: &Api, path: &str) -> String {
    let response = api
        .http
        .get(format!("{}{path}", api.base))
        .header("cookie", api.cookie.as_deref().unwrap())
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK, "{path}");
    response.text().await.unwrap()
}

async fn issue_ids(api: &Api, org: &str) -> Vec<(String, i64)> {
    let (status, body) = api.get(&format!("/api/orgs/{org}/issues")).await;
    assert_eq!(status, StatusCode::OK);
    body["issues"]
        .as_array()
        .unwrap()
        .iter()
        .map(|i| {
            (
                i["title"].as_str().unwrap().to_owned(),
                i["id"].as_i64().unwrap(),
            )
        })
        .collect()
}

fn stack_functions(page: &str) -> Vec<String> {
    let Some(start) = page.find(r#"id="observe-issue-stacktrace""#) else {
        return Vec::new();
    };
    let stack = &page[start
        ..page[start..]
            .find("</ol>")
            .map_or(page.len(), |end| start + end)];
    stack
        .split(r#"<p class="break-words font-mono text-data text-text-primary">"#)
        .skip(1)
        .map(|part| part.split("</p>").next().unwrap().to_owned())
        .collect()
}

#[tokio::test]
async fn actual_python_ruby_and_elixir_sdk_errors_render_their_stacks() {
    let f = common::fixture("sdk-stacks").await;
    let api = Api::signup(&f.base, "sdk-stacks@example.invalid").await;
    let (org, project, dsn) = api.setup_source("SDK stacks").await;
    let key = dsn_key(&dsn);
    for sdk in ["python", "ruby", "elixir"] {
        let (status, body) =
            post_envelope(&f.base, project, &key, sentry_envelope(&fixture(sdk)), None).await;
        assert_eq!(status, StatusCode::OK, "{sdk}");
        assert_eq!(body["id"], fixture(sdk)["event_id"], "{sdk}");
    }
    let issues = issue_ids(&api, &org).await;
    let issue = |title: &str| issues.iter().find(|(t, _)| t == title).unwrap().1;
    let page = |id: i64| format!("/dashboard/orgs/{org}/projects/{project}/observe/issues/{id}");

    let elixir = html(
        &api,
        &page(issue("RuntimeError: postdeploy-elixir-078d5f2eab4e249d")),
    )
    .await;
    assert_eq!(
        stack_functions(&elixir),
        [
            ":elixir_compiler_2.__FILE__/1",
            ":elixir_compiler.dispatch/4",
            ":elixir_compiler.compile/4",
            ":elixir_compiler.optimize_defmodule/2",
            ":elixir_lexical.run/3",
            ":elixir_compiler.quoted/3",
            "Module.ParallelChecker.verify/1",
            "Code.require_file/2",
        ]
    );
    assert!(elixir.contains("Elixir error fixture"), "elixir breadcrumb");
    assert!(
        !elixir.contains(r#"aria-label="Request""#),
        "empty request hidden"
    );

    let python = html(
        &api,
        &page(issue("RuntimeError: postdeploy-python-facb73b760c60fd1")),
    )
    .await;
    assert_eq!(stack_functions(&python), ["&lt;module&gt;"]);
    assert!(python.contains("Python error fixture"));

    let ruby = html(
        &api,
        &page(issue(
            "RuntimeError: postdeploy-ruby-6afe3d3c3a483de8 (RuntimeError)",
        )),
    )
    .await;
    assert_eq!(stack_functions(&ruby), ["&lt;main&gt;"]);
    assert!(ruby.contains("Ruby error fixture"));
    TestApp::on_shutdown(&f.boot.app_context).await;
}

fn native_envelope(id: &str, key: Option<&str>) -> Value {
    json!({
        "header": {"key": key, "sdk": {"name": "postdeploy-elixir", "version": "0.4.0", "platform": "elixir"}, "sent_at": null},
        "items": [{
            "id": id, "type": "exception", "timestamp": "2026-10-16T08:00:00.000000Z",
            "level": "error", "release": "shop@2", "environment": null, "message": null, "mechanism": "plug",
            "exception": {"type": "Shop.PaymentError", "value": "card declined", "cause": null,
                "stacktrace": {"frames": [
                    {"function": "Shop.Pay.charge/2", "file": "lib/shop/pay.ex", "lineno": 12, "in_app": true},
                    {"function": "ShopWeb.CheckoutController.create/2", "file": "lib/shop_web/checkout_controller.ex", "lineno": 30, "in_app": true}
                ]}},
            "fingerprint": null, "breadcrumbs": [{"category": "plug", "message": "POST /checkout", "timestamp": "2026-10-16T07:59:59Z"}],
            "contexts": {"request": {"headers": {"x-request-id": "req-native-1"}}},
            "tags": null, "user": null
        }]
    })
}

async fn native_post(base: &str, key: &str, body: &Value) -> (StatusCode, Value) {
    let response = reqwest::Client::new()
        .post(format!("{base}/e/errors"))
        .header("authorization", format!("Bearer {key}"))
        .json(body)
        .send()
        .await
        .unwrap();
    let status = response.status();
    (status, response.json().await.unwrap_or(Value::Null))
}

#[tokio::test]
async fn legacy_keys_and_native_errors_use_the_sentry_pipeline() {
    let f = common::fixture("sdk-native").await;
    let api = Api::signup(&f.base, "sdk-native@example.invalid").await;
    let (org, first_project, _) = api.setup_source("Native").await;
    let (status, created) = api
        .post(
            &format!("/api/orgs/{org}/projects"),
            json!({"name": "shop"}),
        )
        .await;
    assert_eq!(status, StatusCode::CREATED);
    let project = created["id"].as_i64().unwrap();
    assert_eq!((first_project, project), (1, 2));
    let (status, created) = api
        .post(
            &format!("/api/orgs/{org}/projects/{project}/sources"),
            json!({"name": "shop", "environment": "production"}),
        )
        .await;
    assert_eq!(status, StatusCode::CREATED);
    let key = dsn_key(created["dsn"].as_str().unwrap());
    let source =
        f.rt.control
            .query_one_raw(sql(
                "SELECT id FROM sources WHERE project_id = ?",
                vec![project.into()],
            ))
            .await
            .unwrap()
            .unwrap()
            .try_get::<i64>("", "id")
            .unwrap();
    let legacy = "obs_Ab-_0123456789abcdefghijklmnopqrstuvwxyzABC";
    assert_eq!(legacy.len(), 47);
    f.rt.control
        .execute_raw(sql(
            "INSERT INTO ingest_keys (org_id, project_id, source_id, key_hash, key_hint, created_at)
             VALUES (?, ?, ?, ?, 'obs_Ab-_', 0)",
            vec![org.clone().into(), project.into(), source.into(), Sha256::digest(legacy.as_bytes()).to_vec().into()],
        ))
        .await
        .unwrap();

    let (status, body) = native_post(
        &f.base,
        legacy,
        &native_envelope("err_01920000-0000-7000-8000-000000000001", Some(legacy)),
    )
    .await;
    assert_eq!(status, StatusCode::ACCEPTED);
    assert_eq!(
        body,
        json!({"accepted": 1, "dropped": 0, "event_ids": ["01920000000070008000000000000001"],
            "receipt": accepted(None, 1, 0)["receipt"]})
    );
    let (status, body) = native_post(
        &f.base,
        legacy,
        &native_envelope("err_01920000-0000-7000-8000-000000000002", Some(&key)),
    )
    .await;
    assert_eq!(
        (status, body["error"].clone()),
        (StatusCode::BAD_REQUEST, json!("key_mismatch"))
    );
    let (status, _) = native_post(
        &f.base,
        "obs_unknown_unknown_unknown_unknown_unknown_x",
        &native_envelope("err_01920000-0000-7000-8000-000000000003", None),
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);

    let issues = issue_ids(&api, &org).await;
    assert_eq!(issues.len(), 1);
    assert_eq!(issues[0].0, "Shop.PaymentError: card declined");
    let (status, event) = api
        .get(&format!(
            "/api/orgs/{org}/issues/{}/events/01920000000070008000000000000001",
            issues[0].1
        ))
        .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(event["event"]["request_id"], "req-native-1");
    assert_eq!(event["event"]["occurred_at"], 1_792_137_600_000_000_i64);
    assert_eq!(
        event["payload"]["exception"]["values"][0]["stacktrace"]["frames"][1]["function"],
        "Shop.Pay.charge/2"
    );
    let page = html(
        &api,
        &format!(
            "/dashboard/orgs/{org}/projects/{project}/observe/issues/{}",
            issues[0].1
        ),
    )
    .await;
    assert_eq!(
        stack_functions(&page),
        ["Shop.Pay.charge/2", "ShopWeb.CheckoutController.create/2"]
    );

    let python = sentry_envelope(&fixture("python"));
    let (status, _) = post_envelope(&f.base, 1, legacy, python.clone(), None).await;
    assert_eq!(status, StatusCode::OK, "legacy DSN path /1");
    let (status, _) = post_envelope(&f.base, 1, &key, python, None).await;
    assert_eq!(
        status,
        StatusCode::FORBIDDEN,
        "current keys keep the project path"
    );
    assert_eq!(issue_ids(&api, &org).await.len(), 2);
    TestApp::on_shutdown(&f.boot.app_context).await;
}

#[tokio::test]
async fn an_event_id_sent_by_two_sources_needs_its_source() {
    let f = common::fixture("sdk-ambiguous").await;
    let api = Api::signup(&f.base, "sdk-ambiguous@example.invalid").await;
    let (org, project, dsn_a) = api.setup_source("Ambiguous").await;
    let (status, worker) = api
        .post(
            &format!("/api/orgs/{org}/projects/{project}/sources"),
            json!({"name": "worker", "environment": "production"}),
        )
        .await;
    assert_eq!(status, StatusCode::CREATED);
    let dsn_b = worker["dsn"].as_str().unwrap();
    let source_b = worker["source"]["id"].as_i64().unwrap();
    let event_id = "5f3c0a7e9b1d4e2fa8c6b0d1e2f3a4b5";
    for (dsn, marker) in [(dsn_a.as_str(), "from-api"), (dsn_b, "from-worker")] {
        let event = json!({"event_id": event_id, "level": "error", "extra": {"marker": marker},
            "exception": {"values": [{"type": "Boom", "value": "same id"}]}});
        let (status, _) = post_envelope(
            &f.base,
            project,
            &dsn_key(dsn),
            sentry_envelope(&event),
            None,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
    }
    let issue = issue_ids(&api, &org).await[0].1;
    let path = format!("/api/orgs/{org}/issues/{issue}/events/{event_id}");
    let (status, body) = api.get(&path).await;
    assert_eq!(
        (status, body),
        (StatusCode::CONFLICT, json!({"error": "ambiguous_event"}))
    );
    let (status, body) = api.get(&format!("{path}?source={source_b}")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["event"]["source_id"], source_b);
    assert_eq!(body["payload"]["extra"]["marker"], "from-worker");

    let dashboard = format!("/dashboard/orgs/{org}/projects/{project}/observe/issues/{issue}");
    let page = html(&api, &format!("{dashboard}?event={event_id}")).await;
    assert!(page.contains("Two sources sent an event with this ID."));
    let page = html(
        &api,
        &format!("{dashboard}?event={event_id}&source={source_b}"),
    )
    .await;
    assert!(page.contains(&format!("?event={event_id}&amp;source={source_b}")));
    TestApp::on_shutdown(&f.boot.app_context).await;
}

fn event(id: &str, title: &str, release: &str, occurred: i64) -> ErrorEvent {
    ErrorEvent {
        event_id: id.into(),
        level: "error",
        title: title.into(),
        culprit: None,
        fingerprint: "sha256:ordering".into(),
        release: Some(release.into()),
        trace_id: None,
        request_id: None,
        service: None,
        occurred_us: occurred,
        payload: br#"{"message":"ordering"}"#.to_vec(),
    }
}

#[tokio::test]
async fn issue_times_ignore_commit_order_and_late_events_do_not_reopen() {
    let f = common::fixture("sdk-ordering").await;
    let org = f.org("sdk-ordering@example.invalid", "Ordering").await;
    let token = f.token(org.owner, &org.id, Some(common::FULL)).await;
    let (project, source, _) = f.source(&token, "web").await;
    let access = authorize(&f.rt, org.owner, &org.id).await.unwrap();
    let environment = Environment::parse("production").unwrap();
    let at = EventSource {
        org: &org.id,
        project: ProjectId(project),
        source: SourceId(source["id"].as_i64().unwrap()),
        environment: &environment,
    };
    let now = now_micros();
    let newer = now - 100_000_000;
    let older = now - 200_000_000;
    let Committed::New { issue, .. } = issues::commit(
        &f.rt,
        &at,
        event(
            "00000000000000000000000000000001",
            "newest title",
            "web@2",
            newer,
        ),
        newer,
    )
    .await
    .unwrap() else {
        panic!("first event stored");
    };
    issues::commit(
        &f.rt,
        &at,
        event(
            "00000000000000000000000000000002",
            "older title",
            "web@1",
            older,
        ),
        older,
    )
    .await
    .unwrap();
    let (stored, _) = issues::get(&f.rt, &access, issue).await.unwrap();
    assert_eq!(
        (
            stored.first_seen,
            stored.last_seen,
            stored.title.as_str(),
            stored.last_release.as_deref()
        ),
        (older, newer, "newest title", Some("web@2"))
    );

    let resolved = issues::set_status(&f.rt, &access, issue, "resolved")
        .await
        .unwrap();
    let fixed = resolved.resolved_at.unwrap();
    assert!(fixed >= now);
    let late = issues::commit(
        &f.rt,
        &at,
        event(
            "00000000000000000000000000000003",
            "late",
            "web@2",
            fixed - 60_000_000,
        ),
        now_micros(),
    )
    .await
    .unwrap();
    assert_eq!(
        late,
        Committed::New {
            issue,
            regression: false
        }
    );
    let (stored, _) = issues::get(&f.rt, &access, issue).await.unwrap();
    assert_eq!(
        (stored.status.as_str(), stored.regressed_at),
        ("resolved", None)
    );

    let after_fix = fixed + 1_000_000;
    let regressed = issues::commit(
        &f.rt,
        &at,
        event(
            "00000000000000000000000000000004",
            "after fix",
            "web@3",
            after_fix,
        ),
        now_micros(),
    )
    .await
    .unwrap();
    assert_eq!(
        regressed,
        Committed::New {
            issue,
            regression: true
        }
    );
    let reopened = issues::set_status(&f.rt, &access, issue, "open")
        .await
        .unwrap();
    assert_eq!(
        (reopened.status.as_str(), reopened.resolved_at),
        ("open", Some(fixed))
    );
    let events = issues::events(&f.rt, &access, issue, Some(10))
        .await
        .unwrap();
    let flags: Vec<(String, Option<bool>)> = events
        .iter()
        .map(|e| (e.event_id.clone(), e.regression))
        .collect();
    assert_eq!(
        flags,
        [
            ("00000000000000000000000000000004".to_owned(), Some(true)),
            ("00000000000000000000000000000003".to_owned(), Some(false)),
            ("00000000000000000000000000000001".to_owned(), Some(false)),
            ("00000000000000000000000000000002".to_owned(), Some(false)),
        ]
    );
    let org_id: &OrgId = &org.id;
    let handle = f.rt.tenant(org_id).await.unwrap();
    let row = handle
        .query_one_raw(sql(
            "SELECT status FROM issues WHERE id = ?",
            vec![issue.into()],
        ))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(row.try_get::<String>("", "status").unwrap(), "open");
    drop(handle);
    TestApp::on_shutdown(&f.boot.app_context).await;
}
