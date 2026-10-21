#[path = "support/mcp.rs"]
mod common;
mod support;

use std::sync::{atomic::Ordering, Arc};

use bytes::Bytes;
use loco_rs::app::Hooks;
use postdeploy::{
    domain::{now_micros, Environment, OrgId, ProjectId, SourceId},
    identity::access::authorize,
    ingest::event::ErrorEvent,
    issues::{self, EventSource},
    orphan_retention::{OrphanRetention, OrphanRetentionSettings},
    releases::UploadRequest,
    runtime::{sql, Gate},
    services::Services,
    testing::TestApp,
};
use reqwest::StatusCode;
use sea_orm::ConnectionTrait;
use serde_json::{json, Value};

fn ids(value: &Value) -> Vec<i64> {
    value["issues"]
        .as_array()
        .unwrap()
        .iter()
        .map(|issue| issue["id"].as_i64().unwrap())
        .collect()
}

async fn seed_issue(f: &common::Fixture, org: &OrgId, project: i64, id: i64, seen: i64) {
    let handle = f.rt.tenant(org).await.unwrap();
    handle.execute_raw(sql(
        "INSERT INTO issues (id, project_id, environment, fingerprint, title, level, status, first_seen, last_seen, event_count) VALUES (?, ?, 'production', ?, 'tied issue', 'error', 'open', ?, ?, 1)",
        vec![id.into(), project.into(), format!("fingerprint-{id}").into(), seen.into(), seen.into()],
    )).await.unwrap();
}

#[tokio::test]
async fn tied_issue_pages_are_complete_over_http_mcp_and_dashboard() {
    let f = common::fixture("review-tied-issues").await;
    let email = "review-tied@example.invalid";
    let org = f.org(email, "Tied issues").await;
    let token = f.token(org.owner, &org.id, Some(common::FULL)).await;
    let (project, _, _) = f.source(&token, "web").await;
    let seen = now_micros();
    for id in 1..=5 {
        seed_issue(&f, &org.id, project, id, seen).await;
    }
    let mut api = support::Api::new(&f.base);
    assert_eq!(
        api.auth("login", email, common::PASSWORD).await.0,
        StatusCode::OK
    );
    let path = format!("/api/orgs/{}/issues?limit=3", org.id);
    let (status, first) = api.get(&path).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(ids(&first), [5, 4, 3]);
    let cursor = first["next"].as_str().unwrap();
    let (status, second) = api.get(&format!("{path}&before={cursor}")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(ids(&second), [2, 1]);
    assert_eq!(second["next"], Value::Null);
    assert_eq!(
        api.get(&format!("{path}&before={seen}")).await.0,
        StatusCode::BAD_REQUEST
    );

    let mcp = f.call(&token, "list_issues", json!({"limit":3})).await;
    assert_eq!(ids(&mcp["structuredContent"]), [5, 4, 3]);
    let mcp_next = mcp["structuredContent"]["next"].as_str().unwrap();
    let mcp = f
        .call(&token, "list_issues", json!({"limit":3,"before":mcp_next}))
        .await;
    assert_eq!(ids(&mcp["structuredContent"]), [2, 1]);
    let invalid = f.call(&token, "list_issues", json!({"before":seen})).await;
    assert_eq!(invalid["isError"], true);

    for id in 6..=60 {
        seed_issue(&f, &org.id, project, id, seen).await;
    }
    let observe = format!("/dashboard/orgs/{}/projects/{project}/observe", org.id);
    let response = api
        .http
        .get(format!("{}{observe}", f.base))
        .header("cookie", api.cookie.as_ref().unwrap())
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let html = response.text().await.unwrap();
    let web_cursor = format!("i1.{seen}.11");
    assert!(
        html.contains(&format!("before={web_cursor}")),
        "dashboard emits tied-row cursor"
    );
    let response = api
        .http
        .get(format!("{}{observe}?before={web_cursor}", f.base))
        .header("cookie", api.cookie.as_ref().unwrap())
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let html = response.text().await.unwrap();
    assert!(
        html.contains("/observe/issues/1\""),
        "dashboard can reach oldest tied row"
    );
    TestApp::on_shutdown(&f.boot.app_context).await;
}

fn event() -> ErrorEvent {
    ErrorEvent {
        event_id: "0123456789abcdef0123456789abcdef".into(),
        level: "error",
        title: "failure test".into(),
        culprit: None,
        fingerprint: "cleanup-error".into(),
        release: None,
        trace_id: None,
        request_id: None,
        service: None,
        occurred_us: now_micros(),
        payload: br#"{"message":"review-private-payload-marker"}"#.to_vec(),
    }
}

#[tokio::test]
async fn failed_metadata_writes_delete_uploaded_error_report_and_map_objects() {
    let f = common::fixture("review-upload-cleanup").await;
    let org = f.org("review-cleanup@example.invalid", "Cleanup").await;
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
    let handle = f.rt.tenant(&org.id).await.unwrap();
    handle.execute_unprepared("CREATE TRIGGER reject_event BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT, 'injected event metadata failure'); END;").await.unwrap();
    drop(handle);
    assert!(issues::commit(&f.rt, &at, event(), now_micros())
        .await
        .is_err());
    assert!(f
        .rt
        .store
        .list_page(&format!("errors/v1/{}/", org.id), None, 10)
        .await
        .unwrap()
        .keys
        .is_empty());
    f.rt.store
        .faults()
        .unwrap()
        .fail_deletes
        .store(1, Ordering::SeqCst);
    assert!(issues::commit(&f.rt, &at, event(), now_micros())
        .await
        .is_err());
    assert_eq!(
        f.rt.store
            .list_page(&format!("errors/v1/{}/", org.id), None, 10)
            .await
            .unwrap()
            .keys
            .len(),
        1
    );
    let sweep = OrphanRetention::new(
        f.rt.control.clone(),
        f.rt.tenants.clone(),
        f.rt.store.clone(),
        Default::default(),
    );
    assert_eq!(
        sweep
            .sweep_org(&org.id, now_micros() + 7_200_000_000)
            .await
            .unwrap()
            .deleted,
        1
    );
    assert!(f
        .rt
        .store
        .list_page(&format!("errors/v1/{}/", org.id), None, 10)
        .await
        .unwrap()
        .keys
        .is_empty());
    let handle = f.rt.tenant(&org.id).await.unwrap();
    handle
        .execute_unprepared("DROP TRIGGER reject_event;")
        .await
        .unwrap();
    drop(handle);
    let issue = match issues::commit(&f.rt, &at, event(), now_micros())
        .await
        .unwrap()
    {
        issues::Committed::New { issue, .. } => issue,
        _ => panic!("fresh event expected"),
    };
    assert_eq!(
        f.rt.store
            .list_page(&format!("errors/v1/{}/", org.id), None, 10)
            .await
            .unwrap()
            .keys
            .len(),
        1
    );

    let handle = f.rt.tenant(&org.id).await.unwrap();
    handle.execute_unprepared("CREATE TRIGGER reject_report BEFORE INSERT ON reports BEGIN SELECT RAISE(ABORT, 'injected report metadata failure'); END;
        CREATE TRIGGER reject_map BEFORE INSERT ON release_artifacts BEGIN SELECT RAISE(ABORT, 'injected source map metadata failure'); END;").await.unwrap();
    drop(handle);
    let report = serde_json::from_value(json!({"project_id":project,"title":"Review","summary":"review-private-payload-marker","findings":[{"title":"Evidence","severity":"high","detail":"review-private-payload-marker","evidence":[{"kind":"issue","issue_id":issue}]}]})).unwrap();
    assert!(Services::get(&f.boot.app_context)
        .reports
        .publish(&access, report)
        .await
        .is_err());
    assert!(f
        .rt
        .store
        .list_page(&format!("reports/v1/{}/", org.id), None, 10)
        .await
        .unwrap()
        .keys
        .is_empty());
    let map = UploadRequest { project: ProjectId(project), release: Some("test@1".into()), dist: None, name: "~/app.js".into(), debug_id: None,
        body: Bytes::from_static(br#"{"version":3,"sources":["original.js"],"sourcesContent":["review-private-payload-marker"],"names":[],"mappings":"AAAA"}"#) };
    assert!(f.rt.releases.upload(&access, map).await.is_err());
    assert!(f
        .rt
        .store
        .list_page(&format!("releases/v1/{}/", org.id), None, 10)
        .await
        .unwrap()
        .keys
        .is_empty());
    assert_eq!(f.rt.tenants.registry().stats().await.leased_pools, 0);
    let root = f.rt.settings.tenants.root.parent().unwrap();
    assert_no_payload(root);
    TestApp::on_shutdown(&f.boot.app_context).await;
}

fn assert_no_payload(path: &std::path::Path) {
    for entry in std::fs::read_dir(path).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            assert_no_payload(&path);
        } else {
            let bytes = std::fs::read(&path).unwrap();
            let marker = b"review-private-payload-marker";
            assert!(
                !bytes.windows(marker.len()).any(|window| window == marker),
                "raw payload must not be stored locally"
            );
        }
    }
}

fn old_id(micros: i64, serial: u128) -> uuid::Uuid {
    uuid::Uuid::from_u128(((micros as u128 / 1_000) << 80) | (7 << 76) | (2 << 62) | serial)
}

fn keys(org: &OrgId, project: i64, micros: i64, serial: u128) -> [String; 3] {
    let id = old_id(micros, serial).simple();
    [
        format!("errors/v1/{org}/{project}/1/20261015/event-{id}.json.zst"),
        format!("releases/v1/{org}/{project}/a{id}.map.zst"),
        format!("reports/v1/{org}/20261015/r{id}.json"),
    ]
}

#[tokio::test]
async fn orphan_sweep_survives_a_full_gate_and_an_invalid_organization_id() {
    let f = common::fixture("review-orphan-gate").await;
    let org = f
        .org("review-orphan-gate@example.invalid", "Orphan gate")
        .await;
    f.rt.control
        .execute_raw(sql(
            "INSERT INTO organizations (id, name, created_by, created_at) VALUES ('a-invalid', 'Invalid', ?, 0)",
            vec![org.owner.0.into()],
        ))
        .await
        .unwrap();
    let orphan = keys(&org.id, 1, now_micros() - 7_200_000_000, 1)[2].clone();
    f.rt.store
        .put(&orphan, Bytes::from_static(b"orphan"))
        .await
        .unwrap();
    let gate = Arc::new(Gate::new(1));
    let busy = gate.enter().unwrap();
    let cancel = tokio_util::sync::CancellationToken::new();
    let sweeper = OrphanRetention::new(
        f.rt.control.clone(),
        f.rt.tenants.clone(),
        f.rt.store.clone(),
        OrphanRetentionSettings {
            interval_secs: 1,
            ..Default::default()
        },
    );
    let task = tokio::spawn({
        let (cancel, gate) = (cancel.clone(), gate.clone());
        async move { sweeper.run(cancel, gate).await }
    });
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
    drop(busy);
    let mut removed = false;
    for _ in 0..30 {
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        if f.rt.store.get(&orphan, 100).await.unwrap().is_none() {
            removed = true;
            break;
        }
    }
    assert!(removed, "orphan removed on the tick after the gate frees");
    assert!(!task.is_finished(), "sweeper still running");
    cancel.cancel();
    task.await.unwrap();
    TestApp::on_shutdown(&f.boot.app_context).await;
}

#[tokio::test]
async fn orphan_sweep_resumes_after_restart_and_retries_deletes_without_touching_live_payloads() {
    let f = common::fixture("review-orphan-recovery").await;
    let org = f.org("review-orphans@example.invalid", "Orphans").await;
    let token = f.token(org.owner, &org.id, Some(common::FULL)).await;
    let (project, _, _) = f.source(&token, "web").await;
    let now = now_micros();
    let old = now - 7_200_000_000;
    seed_issue(&f, &org.id, project, 1, now).await;
    let accepted = keys(&org.id, project, old, 1);
    let pending = keys(&org.id, project, old, 2);
    let young = keys(&org.id, project, now, 3);
    let foreign = keys(&OrgId::generate(), project, old, 9);
    let invalid: Vec<String> = accepted
        .iter()
        .map(|key| format!("{}/zzz-invalid", key.rsplit_once('/').unwrap().0))
        .collect();
    let mut guards = Vec::new();
    for key in &pending {
        guards.push(f.rt.store.pending(key));
    }
    let mut orphaned = Vec::new();
    for serial in 3..=8 {
        orphaned.extend(keys(&org.id, project, old, serial));
    }
    for key in accepted
        .iter()
        .chain(&pending)
        .chain(&young)
        .chain(&foreign)
        .chain(&invalid)
        .chain(&orphaned)
    {
        f.rt.store
            .put(key, Bytes::from_static(b"review-private-payload-marker"))
            .await
            .unwrap();
    }
    let handle = f.rt.tenant(&org.id).await.unwrap();
    handle.execute_raw(sql("INSERT INTO events (issue_id, project_id, source_id, event_id, level, occurred_at, received_at, payload_key, payload_bytes) VALUES (1, ?, 1, 'indexed', 'error', ?, ?, ?, 1)", vec![project.into(), old.into(), old.into(), accepted[0].clone().into()])).await.unwrap();
    handle.execute_raw(sql("INSERT INTO release_artifacts (id, project_id, release, dist, name, sha256, object_key, raw_bytes, stored_bytes, uploaded_by, created_at) VALUES (?, ?, 'test', '', '~/app.js', 'test', ?, 1, 1, ?, ?)", vec![format!("a{}", old_id(old, 1).simple()).into(), project.into(), accepted[1].clone().into(), org.owner.0.into(), old.into()])).await.unwrap();
    handle.execute_raw(sql("INSERT INTO reports (id, project_id, author_id, created_at, object_key, body_bytes, finding_count, evidence_count) VALUES (?, ?, ?, ?, ?, 1, 0, 0)", vec![format!("r{}", old_id(old, 1).simple()).into(), project.into(), org.owner.0.into(), old.into(), accepted[2].clone().into()])).await.unwrap();
    drop(handle);
    let make = || {
        OrphanRetention::new(
            f.rt.control.clone(),
            f.rt.tenants.clone(),
            f.rt.store.clone(),
            OrphanRetentionSettings {
                page_size: 2,
                max_pages: 1,
                ..Default::default()
            },
        )
    };
    let first = make().sweep_org(&org.id, now).await.unwrap();
    assert_eq!(first.listed, 6);
    assert_eq!(first.protected, 6);
    assert_eq!(first.deleted, 0);
    f.rt.store
        .faults()
        .unwrap()
        .fail_deletes
        .store(1, Ordering::SeqCst);
    let next = make().sweep_org(&org.id, now).await.unwrap();
    assert_eq!(next.listed, 6);
    assert_eq!(next.deleted, 5);
    assert_eq!(next.delete_failures, 1);
    let mut invalid_seen = 0;
    for _ in 0..12 {
        let report = make().sweep_org(&org.id, now).await.unwrap();
        assert!(report.listed <= 6, "every resumed sweep is bounded");
        invalid_seen += report.invalid;
    }
    assert!(invalid_seen >= 3);
    for key in &orphaned {
        assert!(
            f.rt.store.get(key, 100).await.unwrap().is_none(),
            "orphan removed"
        );
    }
    for key in accepted
        .iter()
        .chain(&pending)
        .chain(&young)
        .chain(&foreign)
        .chain(&invalid)
    {
        assert!(
            f.rt.store.get(key, 100).await.unwrap().is_some(),
            "indexed, pending, young, and foreign payloads remain"
        );
    }
    drop(guards);
    for _ in 0..8 {
        make().sweep_org(&org.id, now).await.unwrap();
    }
    for key in &pending {
        assert!(
            f.rt.store.get(key, 100).await.unwrap().is_none(),
            "abandoned writer recovered"
        );
    }
    assert_eq!(f.rt.tenants.registry().stats().await.leased_pools, 0);
    TestApp::on_shutdown(&f.boot.app_context).await;
}

#[tokio::test]
#[ignore = "uses real R2: needs CREDSEAL_KEY_FILE and POSTDEPLOY_CREDENTIALS_FILE"]
async fn real_r2_orphan_sweep_pages_and_removes_only_old_unreferenced_payloads() {
    let f = common::fixture("review-real-r2-orphans").await;
    let org = f
        .org("review-r2-orphans@example.invalid", "R2 Orphans")
        .await;
    let credentials = postdeploy::credentials::Credentials::load(
        std::path::Path::new(&std::env::var("POSTDEPLOY_CREDENTIALS_FILE").unwrap()),
        "test",
    )
    .unwrap();
    let prefix = format!(
        "local-verification/orphan-{}/",
        uuid::Uuid::now_v7().simple()
    );
    let store = postdeploy::store::ObjectStore::r2(
        &credentials.r2,
        &prefix,
        std::time::Duration::from_secs(30),
    )
    .unwrap();
    let now = now_micros();
    let old = keys(&org.id, 1, now - 7_200_000_000, 1);
    let young = keys(&org.id, 1, now, 2);
    for key in old.iter().chain(&young) {
        store
            .put(
                key,
                Bytes::from_static(b"owned orphan retention verification"),
            )
            .await
            .unwrap();
    }
    let sweep = OrphanRetention::new(
        f.rt.control.clone(),
        f.rt.tenants.clone(),
        store.clone(),
        OrphanRetentionSettings {
            page_size: 1,
            max_pages: 1,
            ..Default::default()
        },
    );
    let report = sweep.sweep_org(&org.id, now).await.unwrap();
    assert_eq!(report.listed, 3);
    assert_eq!(report.deleted, 3);
    let resumed = OrphanRetention::new(
        f.rt.control.clone(),
        f.rt.tenants.clone(),
        store.clone(),
        OrphanRetentionSettings {
            page_size: 1,
            max_pages: 1,
            ..Default::default()
        },
    );
    let report = resumed.sweep_org(&org.id, now).await.unwrap();
    assert_eq!(report.listed, 3);
    assert_eq!(report.protected, 3);
    assert_eq!(report.deleted, 0);
    for key in &old {
        assert!(store.get(key, 100).await.unwrap().is_none());
    }
    for key in &young {
        assert_eq!(
            store.get(key, 100).await.unwrap().unwrap().as_ref(),
            b"owned orphan retention verification"
        );
    }
    for key in &young {
        store.delete(key).await.unwrap();
    }
    assert!(store.list_page("", None, 10).await.unwrap().keys.is_empty());
    assert_eq!(f.rt.tenants.registry().stats().await.leased_pools, 0);
    TestApp::on_shutdown(&f.boot.app_context).await;
}
