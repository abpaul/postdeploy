#[path = "support/mcp.rs"]
mod common;
mod support;

use common::{error_of, fixture, Fixture, FULL};
use postdeploy::{
    domain::ProjectId,
    identity::{access::authorize, projects},
};
use reqwest::StatusCode;
use serde_json::{json, Value};

async fn get(f: &Fixture, token: &str, path: &str) -> (StatusCode, Value) {
    let response = f
        .http
        .get(format!("{}{path}", f.base))
        .bearer_auth(token)
        .send()
        .await
        .unwrap();
    let status = response.status();
    (status, response.json().await.unwrap_or(Value::Null))
}

fn ids(items: &Value) -> Vec<i64> {
    items
        .as_array()
        .unwrap()
        .iter()
        .map(|item| item["id"].as_i64().unwrap())
        .collect()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn project_lists_page_with_a_bounded_stable_cursor() {
    let f = fixture("project-pages").await;
    let org = f.org("owner@project-pages.test", "Pages").await;
    let access = authorize(&f.rt, org.owner, &org.id).await.unwrap();
    let mut created = Vec::new();
    for n in 0..101 {
        created.push(
            projects::create(&f.rt, &access, &format!("p{n:03}"))
                .await
                .unwrap()
                .id
                .0,
        );
    }
    let token = f.token(org.owner, &org.id, None).await;
    let base = format!("/api/orgs/{}/projects", org.id);

    let (status, first) = get(&f, &token, &base).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(ids(&first["projects"]), created[..25]);
    assert_eq!(first["next"], created[24]);
    let (_, widest) = get(&f, &token, &format!("{base}?limit=100")).await;
    assert_eq!(ids(&widest["projects"]), created[..100]);
    assert_eq!(widest["next"], created[99]);

    let (_, page) = get(&f, &token, &format!("{base}?limit=40")).await;
    let mut seen = ids(&page["projects"]);
    let mut next = page["next"].clone();
    let late = projects::create(&f.rt, &access, "late").await.unwrap().id.0;
    while !next.is_null() {
        let (_, page) = get(&f, &token, &format!("{base}?limit=40&after={next}")).await;
        seen.extend(ids(&page["projects"]));
        next = page["next"].clone();
    }
    let mut expected = created.clone();
    expected.push(late);
    assert_eq!(seen, expected, "every project once, in order, across pages");

    let listed = f.call(&token, "list_projects", json!({"limit": 2})).await;
    assert_eq!(ids(&listed["structuredContent"]["projects"]), created[..2]);
    assert_eq!(listed["structuredContent"]["next"], created[1]);
    let listed = f
        .call(
            &token,
            "list_projects",
            json!({"limit": 2, "after": created[1]}),
        )
        .await;
    assert_eq!(ids(&listed["structuredContent"]["projects"]), created[2..4]);
    let listed = f.call(&token, "list_projects", json!({})).await;
    assert_eq!(ids(&listed["structuredContent"]["projects"]).len(), 25);
    assert_eq!(
        error_of(&f.call(&token, "list_projects", json!({"limit": 101})).await),
        json!({"error": "invalid_arguments"})
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn source_lists_page_and_existing_names_still_converge() {
    let f = fixture("source-pages").await;
    let org = f.org("owner@source-pages.test", "Sources").await;
    let writer = f.token(org.owner, &org.id, Some(FULL)).await;
    let (project, first, _) = f.source(&writer, "web").await;
    let access = authorize(&f.rt, org.owner, &org.id).await.unwrap();
    let mut sources = vec![first["id"].as_i64().unwrap()];
    for environment in ["staging", "development"] {
        let (source, _) =
            projects::create_source(&f.rt, &access, ProjectId(project), "api", environment)
                .await
                .unwrap();
        sources.push(source.id.0);
    }
    let token = f.token(org.owner, &org.id, None).await;
    let base = format!("/api/orgs/{}/projects/{project}/sources", org.id);
    let (status, page) = get(&f, &token, &format!("{base}?limit=2")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(ids(&page["sources"]), sources[..2]);
    assert_eq!(page["sources"][1]["environment"], "staging");
    let (_, rest) = get(
        &f,
        &token,
        &format!("{base}?limit=2&after={}", page["next"]),
    )
    .await;
    assert_eq!(ids(&rest["sources"]), sources[2..]);
    assert_eq!(rest["next"], Value::Null);

    let listed = f
        .call(
            &token,
            "list_sources",
            json!({"project_id": project, "limit": 1, "after": sources[0]}),
        )
        .await;
    assert_eq!(ids(&listed["structuredContent"]["sources"]), sources[1..2]);
    assert_eq!(listed["structuredContent"]["next"], sources[1]);

    let again = f
        .call(
            &writer,
            "create_source",
            json!({"project_id": project, "name": "api", "environment": "development"}),
        )
        .await;
    assert_eq!(again["structuredContent"]["created"], false);
    assert_eq!(again["structuredContent"]["source"]["id"], sources[2]);
    let again = f
        .call(&writer, "create_project", json!({"name": "web"}))
        .await;
    assert_eq!(
        again["structuredContent"],
        json!({"project": {"id": project, "name": "web"}, "created": false})
    );
}

async fn raw(
    f: &Fixture,
    token: Option<&str>,
    cookie: Option<&str>,
    path: &str,
) -> (StatusCode, String, Value) {
    let mut request = f.http.get(format!("{}{path}", f.base));
    if let Some(token) = token {
        request = request.bearer_auth(token);
    }
    if let Some(cookie) = cookie {
        request = request.header("cookie", cookie);
    }
    let response = request.send().await.unwrap();
    let status = response.status();
    let kind = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .map(|value| value.to_str().unwrap().to_owned())
        .unwrap_or_default();
    (status, kind, response.json().await.unwrap_or(Value::Null))
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn out_of_range_page_inputs_are_json_errors_on_http_and_mcp() {
    let f = fixture("page-inputs").await;
    let org = f.org("owner@page-inputs.test", "Inputs").await;
    let writer = f.token(org.owner, &org.id, Some(FULL)).await;
    let (project, source, _) = f.source(&writer, "web").await;
    let mut api = support::Api::new(&f.base);
    assert_eq!(
        api.auth("login", "owner@page-inputs.test", common::PASSWORD)
            .await
            .0,
        StatusCode::OK
    );
    let cookie = api.cookie.clone().unwrap();
    let invalid = (
        StatusCode::BAD_REQUEST,
        "application/json".to_owned(),
        json!({"error": "invalid_pagination"}),
    );
    let projects = format!("/api/orgs/{}/projects", org.id);
    let sources = format!("/api/orgs/{}/projects/{project}/sources", org.id);
    let keys = format!("/api/orgs/{}/api-keys", org.id);
    for query in [
        "limit=0",
        "limit=101",
        "limit=-1",
        "limit=abc",
        "limit=99999999999999999999",
        "after=0",
        "after=-5",
        "after=abc",
        "before=1",
        "foo=1",
    ] {
        assert_eq!(
            raw(&f, Some(&writer), None, &format!("{projects}?{query}")).await,
            invalid,
            "projects?{query}"
        );
        assert_eq!(
            raw(&f, Some(&writer), None, &format!("{sources}?{query}")).await,
            invalid,
            "sources?{query}"
        );
    }
    for query in ["limit=0", "limit=101", "before=0", "before=abc", "after=1"] {
        assert_eq!(
            raw(&f, None, Some(&cookie), &format!("{keys}?{query}")).await,
            invalid,
            "api-keys?{query}"
        );
    }
    let (status, _, page) = raw(&f, Some(&writer), None, &format!("{sources}?limit=100")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(ids(&page["sources"]), vec![source["id"].as_i64().unwrap()]);
    let (status, _, page) = raw(&f, None, Some(&cookie), &format!("{keys}?limit=100")).await;
    assert_eq!(
        (status, page),
        (StatusCode::OK, json!({"keys": [], "next": null}))
    );
    for args in [
        json!({"limit": 0}),
        json!({"limit": 101}),
        json!({"after": 0}),
    ] {
        assert_eq!(
            error_of(&f.call(&writer, "list_projects", args.clone()).await),
            json!({"error": "invalid_arguments"}),
            "list_projects {args}"
        );
    }
}
