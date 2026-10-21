//! Sends the privacy corpus in `tests/fixtures/privacy/` through the real
//! envelope endpoint on every event and log surface and reads every surface
//! back: credentials in `leaks.txt` never come back, `harmless.txt` comes
//! back byte-identical, and `accepted-over-filter.txt` and
//! `residual-leaks.txt` come back exactly as listed.

mod support;

use std::{
    collections::BTreeMap,
    time::{Duration, Instant},
};

use postdeploy::{
    runtime::Runtime,
    testing::{serve, TestApp, TestEnv},
};
use reqwest::StatusCode;
use serde_json::{json, Map, Value};
use support::*;

const LEAKS: &str = include_str!("fixtures/privacy/leaks.txt");
const HARMLESS: &str = include_str!("fixtures/privacy/harmless.txt");
const OVER_FILTERED: &str = include_str!("fixtures/privacy/accepted-over-filter.txt");
const RESIDUAL: &str = include_str!("fixtures/privacy/residual-leaks.txt");
const BATCH: usize = 50;
const FILTERED: &str = "[Filtered]";

fn entries(corpus: &str) -> Vec<Value> {
    corpus
        .lines()
        .filter(|line| !line.trim().is_empty() && !line.starts_with('#'))
        .map(|line| serde_json::from_str(line).unwrap_or_else(|e| panic!("{line}: {e}")))
        .collect()
}

/// The marker of a leak line: `zqmark` plus three digits, or `4242` plus
/// three digits for a secret that is a number.
fn marker(line: &str) -> &str {
    let (at, len) = line
        .find("zqmark")
        .map(|at| (at, 9))
        .or_else(|| line.find("4242").map(|at| (at, 7)))
        .expect("every leak line holds a marker");
    &line[at..at + len]
}

/// One corpus line and the value each surface must return for it. `None`
/// means the line is a leak and only the marker's absence is checked.
struct Case {
    input: Value,
    expected: Option<Value>,
}

fn cases() -> Vec<Case> {
    let leaks = entries(LEAKS).into_iter().map(|input| Case {
        input,
        expected: None,
    });
    let harmless = entries(HARMLESS).into_iter().map(|input| Case {
        expected: Some(input.clone()),
        input,
    });
    let listed = entries(OVER_FILTERED)
        .into_iter()
        .chain(entries(RESIDUAL))
        .map(|entry| Case {
            input: entry[0].clone(),
            expected: Some(entry[1].clone()),
        });
    leaks.chain(harmless).chain(listed).collect()
}

fn event_id(k: usize) -> String {
    format!("{k:032x}")
}

fn second_event_id(k: usize) -> String {
    format!("f{k:031x}")
}

/// A message template and its parameters for one line. A leak string becomes
/// its own template with the marker as the parameter, as in
/// `logger.error("password=%s", secret)`. Other strings are the only
/// parameter of `%s`. An object's keys become named parameters.
fn template(case: &Case) -> (String, Value) {
    match (&case.input, &case.expected) {
        (Value::String(text), None) => {
            let marker = marker(text);
            let escaped = text.replace('%', "%%");
            match marker.parse::<i64>() {
                Ok(number) => (escaped.replacen(marker, "%d", 1), json!([number])),
                Err(_) => (escaped.replacen(marker, "%s", 1), json!([marker])),
            }
        }
        (Value::String(text), Some(_)) => ("%s".to_owned(), json!([text])),
        (Value::Object(map), _) => {
            let names: Vec<String> = map.keys().map(|key| format!("%({key})s")).collect();
            (names.join(" "), case.input.clone())
        }
        (other, _) => panic!("unsupported corpus value {other}"),
    }
}

/// The primary event: every text field, the template as `logentry`, and a
/// harmless name that holds the line in tags, contexts, header pairs, the
/// query string and cookies.
fn event(k: usize, case: &Case) -> Value {
    let input = &case.input;
    let (message, params) = template(case);
    let mut event = json!({
        "event_id": event_id(k),
        "fingerprint": [format!("corpus-{k}")],
        "logentry": {"message": message, "params": params},
        "tags": {"note": input},
        "contexts": {"app": {"note": input}},
        "breadcrumbs": {"values": [{"message": "corpus", "data": {"note": input}}]},
    });
    let fields = event.as_object_mut().unwrap();
    match input {
        Value::String(text) => {
            fields.insert("message".into(), json!(text));
            fields["logentry"]["formatted"] = json!(text);
            fields.insert(
                "exception".into(),
                json!({"values": [{"type": "CorpusError", "value": text}]}),
            );
            fields["breadcrumbs"]["values"][0]["message"] = json!(text);
            fields.insert("extra".into(), json!({"line": text}));
            fields.insert(
                "request".into(),
                json!({"url": "https://h.example/p", "headers": [["X-Note", text]],
                    "query_string": text, "cookies": text}),
            );
        }
        data => {
            fields.insert(
                "exception".into(),
                json!({"values": [{"type": "CorpusError", "stacktrace": {"frames": [
                    {"function": "f", "abs_path": "/srv/app/f.rs", "in_app": true, "vars": data}]}}]}),
            );
            fields.insert(
                "request".into(),
                json!({"url": "https://h.example/p", "data": data, "headers": [["X-Note", data]],
                    "query_string": [["note", data]], "cookies": data}),
            );
            fields.insert("extra".into(), json!({"data": data}));
        }
    }
    event
}

/// The second event of the same issue: the other shapes of the same
/// surfaces. Header and cookie maps, tag and query pairs, an object
/// `message` with the template, and the line as the only `logentry`
/// parameter.
fn second_event(k: usize, case: &Case) -> Value {
    let input = &case.input;
    let (message, params) = template(case);
    let mut message = json!({"message": message, "params": params});
    if let Value::String(text) = input {
        message["formatted"] = json!(text);
    }
    json!({
        "event_id": second_event_id(k),
        "fingerprint": [format!("corpus-{k}")],
        "message": message,
        "logentry": {"message": "%s", "params": [input]},
        "tags": [["note", input]],
        "request": {"url": "https://h.example/p", "headers": {"X-Note": input},
            "query_string": [["note", input]], "cookies": {"note": input}},
    })
}

/// A typed log attribute. Attributes hold only primitives.
fn attribute(value: &Value) -> Option<Value> {
    let kind = match value {
        Value::Number(n) if n.is_i64() => "integer",
        Value::Number(_) => "double",
        Value::Bool(_) => "boolean",
        Value::String(_) => "string",
        _ => return None,
    };
    Some(json!({"type": kind, "value": value}))
}

/// The body an SDK sends for an object line's template: each named
/// parameter in its place, and a placeholder without a parameter attribute
/// as written. A leak line keeps a neutral body instead, because a body that
/// shows a parameter's value without its name has nothing to filter by.
fn rendered_named(map: &Map<String, Value>) -> String {
    map.iter()
        .map(|(key, value)| match value {
            Value::String(text) => text.clone(),
            other if attribute(other).is_some() => other.to_string(),
            _ => format!("%({key})s"),
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn log(k: usize, case: &Case) -> Value {
    let mut attributes = Map::new();
    attributes.insert(
        "case".into(),
        json!({"type": "string", "value": format!("c{k}")}),
    );
    let (template, params) = template(case);
    attributes.insert(
        "sentry.message.template".into(),
        json!({"type": "string", "value": template}),
    );
    let slots: Vec<(String, &Value)> = match &params {
        Value::Array(items) => items
            .iter()
            .enumerate()
            .map(|(n, item)| (n.to_string(), item))
            .collect(),
        Value::Object(map) => map.iter().map(|(key, item)| (key.clone(), item)).collect(),
        _ => Vec::new(),
    };
    for (slot, item) in slots {
        if let Some(item) = attribute(item) {
            attributes.insert(format!("sentry.message.parameter.{slot}"), item);
        }
    }
    let body = match &case.input {
        Value::String(text) => {
            attributes.insert("line".into(), json!({"type": "string", "value": text}));
            text.clone()
        }
        Value::Object(map) => {
            for (key, value) in map {
                if let Value::String(value) = value {
                    attributes.insert(key.clone(), json!({"type": "string", "value": value}));
                }
            }
            match case.expected {
                Some(_) => rendered_named(map),
                None => format!("structured case {k}"),
            }
        }
        other => panic!("unsupported corpus value {other}"),
    };
    json!({"level": "info", "body": body, "attributes": attributes})
}

fn batch_envelope(batch: &[(usize, &Case)]) -> Vec<u8> {
    let mut out = format!("{}\n", json!({}));
    for (k, case) in batch {
        for event in [event(*k, case), second_event(*k, case)] {
            out.push_str(&format!("{}\n{event}\n", json!({"type": "event"})));
        }
    }
    let logs: Vec<Value> = batch.iter().map(|(k, case)| log(*k, case)).collect();
    out.push_str(&format!(
        "{}\n{}\n",
        json!({"type": "log"}),
        json!({"items": logs})
    ));
    out.into_bytes()
}

async fn stored_objects(rt: &Runtime) -> (String, Vec<postdeploy::logs::record::LogRecord>) {
    let keys = rt.store.list_page("", None, 10_000).await.unwrap().keys;
    let mut text = String::new();
    let mut records = Vec::new();
    for key in keys {
        let body = rt.store.get(&key, 64 << 20).await.unwrap().unwrap();
        if key.starts_with("logs/") {
            records.extend(stored_records(&body));
        }
        let raw = zstd::stream::decode_all(&body[..]).unwrap_or_else(|_| body.to_vec());
        text.push_str(&String::from_utf8_lossy(&raw));
        text.push('\n');
    }
    (text, records)
}

async fn all_issues(api: &Api, org: &str) -> Vec<Value> {
    let mut issues = Vec::new();
    let mut before = String::new();
    loop {
        let (status, page) = api
            .get(&format!("/api/orgs/{org}/issues?limit=200{before}"))
            .await;
        assert_eq!(status, StatusCode::OK);
        issues.extend(page["issues"].as_array().unwrap().iter().cloned());
        match page["next"].as_str() {
            Some(next) => before = format!("&before={next}"),
            None => return issues,
        }
    }
}

async fn all_logs(api: &Api, org: &str, project: i64) -> Vec<Value> {
    let mut rows = Vec::new();
    let mut before = String::new();
    loop {
        let (status, page) = api
            .get(&format!(
                "/api/orgs/{org}/logs?project={project}&limit=200{before}"
            ))
            .await;
        assert_eq!(status, StatusCode::OK);
        rows.extend(page["rows"].as_array().unwrap().iter().cloned());
        match page["next"].as_str() {
            Some(next) => before = format!("&before={next}"),
            None => return rows,
        }
    }
}

/// Every surface that must return a corpus line, with the value it returned.
/// Cookies are a sensitive name, so they always return `[Filtered]`.
fn observed<'a>(
    case: &Case,
    expected: &Value,
    first: &'a Value,
    second: &'a Value,
    row: &'a Value,
) -> Vec<(String, &'a Value, Value)> {
    let attrs = &row["attributes"];
    let same = |name: &str, value: &'a Value| (name.to_owned(), value, expected.clone());
    let (first_params, second_params) = match &case.input {
        Value::String(_) => (
            &first["logentry"]["params"][0],
            &second["message"]["params"][0],
        ),
        _ => (&first["logentry"]["params"], &second["message"]["params"]),
    };
    let mut out = vec![
        same("logentry params", first_params),
        same("message params", second_params),
        same("tags", &first["tags"]["note"]),
        same("contexts", &first["contexts"]["app"]["note"]),
        same(
            "breadcrumb data",
            &first["breadcrumbs"]["values"][0]["data"]["note"],
        ),
        same("header pair", &first["request"]["headers"][0][1]),
        (
            "cookies".into(),
            &first["request"]["cookies"],
            json!(FILTERED),
        ),
        same("header map", &second["request"]["headers"]["X-Note"]),
        same("tag pair", &second["tags"][0][1]),
        same("query pair", &second["request"]["query_string"][0][1]),
        (
            "cookie map".into(),
            &second["request"]["cookies"],
            json!(FILTERED),
        ),
        same("logentry only parameter", &second["logentry"]["params"][0]),
    ];
    match &case.input {
        Value::String(_) => {
            out.extend([
                same("message", &first["message"]),
                same("exception", &first["exception"]["values"][0]["value"]),
                same("breadcrumb", &first["breadcrumbs"]["values"][0]["message"]),
                same("extra", &first["extra"]["line"]),
                same("logentry formatted", &first["logentry"]["formatted"]),
                same("query string", &first["request"]["query_string"]),
                same("message formatted", &second["message"]["formatted"]),
                same("log body", &row["body"]),
                same("log attribute", &attrs["line"]["value"]),
                same(
                    "log parameter",
                    &attrs["sentry.message.parameter.0"]["value"],
                ),
                (
                    "logentry template".into(),
                    &first["logentry"]["message"],
                    json!("%s"),
                ),
                (
                    "log template".into(),
                    &attrs["sentry.message.template"]["value"],
                    json!("%s"),
                ),
            ]);
        }
        Value::Object(_) => {
            out.extend([
                same("extra", &first["extra"]["data"]),
                same("request data", &first["request"]["data"]),
                same(
                    "frame vars",
                    &first["exception"]["values"][0]["stacktrace"]["frames"][0]["vars"],
                ),
                same("query pair", &first["request"]["query_string"][0][1]),
            ]);
            for (key, value) in expected.as_object().unwrap() {
                let input = &case.input[key];
                if input.is_string() {
                    out.push((
                        format!("log attribute {key}"),
                        &attrs[key]["value"],
                        value.clone(),
                    ));
                }
                if attribute(input).is_some() {
                    out.push((
                        format!("log parameter {key}"),
                        &attrs[format!("sentry.message.parameter.{key}")]["value"],
                        value.clone(),
                    ));
                }
            }
        }
        _ => {}
    }
    out
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_privacy_corpus_keeps_credentials_out_and_harmless_text_intact() {
    let env = TestEnv::new("privacy-corpus");
    let boot = env.boot_memory(fast_archive).await.unwrap();
    let (base, _server) = serve(&boot).await;
    let api = Api::signup(&base, "privacy-corpus@example.test").await;
    let (org, project, dsn) = api.setup_source("Corpus").await;
    let key = dsn_key(&dsn);
    let cases = cases();
    let indexed: Vec<(usize, &Case)> = cases.iter().enumerate().collect();
    for batch in indexed.chunks(BATCH) {
        let (status, receipt) =
            post_envelope(&base, project, &key, batch_envelope(batch), None).await;
        assert_eq!(status, StatusCode::OK, "{receipt}");
        assert_eq!(
            receipt["receipt"]["error"]["accepted"],
            json!(2 * batch.len()),
            "{receipt}"
        );
        assert_eq!(
            receipt["receipt"]["log"]["accepted"],
            json!(batch.len()),
            "{receipt}"
        );
    }

    let issues = all_issues(&api, &org).await;
    assert_eq!(issues.len(), cases.len());
    let mut events = BTreeMap::new();
    for issue in &issues {
        let id = issue["id"].as_i64().unwrap();
        let (status, list) = api
            .get(&format!("/api/orgs/{org}/issues/{id}/events"))
            .await;
        assert_eq!(status, StatusCode::OK);
        for summary in list["events"].as_array().unwrap() {
            let event_id = summary["event_id"].as_str().unwrap().to_owned();
            let (status, event) = api
                .get(&format!("/api/orgs/{org}/issues/{id}/events/{event_id}"))
                .await;
            assert_eq!(status, StatusCode::OK);
            events.insert(event_id, event["payload"].clone());
        }
    }
    assert_eq!(events.len(), 2 * cases.len());
    wait_archived(&api, &org).await;
    let rows = all_logs(&api, &org, project).await;
    assert_eq!(rows.len(), cases.len());
    let case_of = |attributes: &Value| attributes["case"]["value"].as_str().unwrap().to_owned();
    let logs: BTreeMap<String, Value> = rows
        .iter()
        .map(|row| (case_of(&row["attributes"]), row.clone()))
        .collect();
    let rt = Runtime::get(&boot.app_context);
    let (objects, records) = stored_objects(&rt).await;
    assert!(
        objects.contains("CorpusError"),
        "the error objects were read"
    );
    assert_eq!(records.len(), cases.len(), "the log objects were read");
    <TestApp as loco_rs::app::Hooks>::on_shutdown(&boot.app_context).await;

    let mut reread = Vec::new();
    for record in &records {
        let attributes = serde_json::to_value(&record.attributes).unwrap();
        let row = &logs[&case_of(&attributes)];
        if row["body"] != record.body.as_str() || row["attributes"] != attributes {
            reread.push(format!(
                "stored {} {attributes}\nlogs API {} {}",
                record.body.as_str(),
                row["body"],
                row["attributes"]
            ));
        }
    }

    let surfaces = [
        ("issues", serde_json::to_string(&issues).unwrap()),
        ("events", serde_json::to_string(&events).unwrap()),
        ("logs", serde_json::to_string(&rows).unwrap()),
        ("objects", objects),
    ];
    let mut survivors = Vec::new();
    let mut leak_count = 0;
    for case in cases.iter().filter(|c| c.expected.is_none()) {
        leak_count += 1;
        let line = case.input.to_string();
        let marker = marker(&line);
        let mut at: Vec<String> = surfaces
            .iter()
            .filter(|(_, text)| text.contains(marker))
            .map(|(name, _)| (*name).to_owned())
            .collect();
        let files = file_contains(&env.dir, marker.as_bytes());
        if !files.is_empty() {
            at.push(format!("files:{}", files.len()));
        }
        if !at.is_empty() {
            survivors.push(format!("{marker} -> {} :: {line}", at.join(",")));
        }
    }

    let mut diffs = Vec::new();
    let mut checked = 0;
    for (k, case) in cases.iter().enumerate() {
        let Some(expected) = &case.expected else {
            continue;
        };
        checked += 1;
        let first = &events[&event_id(k)];
        let second = &events[&second_event_id(k)];
        let row = &logs[&format!("c{k}")];
        for (surface, value, want) in observed(case, expected, first, second, row) {
            if *value != want {
                diffs.push(format!("{surface}: {} -> {value}", case.input));
            }
        }
    }
    println!(
        "SURVIVORS {} of {leak_count}\n{}\nHARMLESS DIFFS {} over {checked} cases\n{}\nREREAD DIFFS {}\n{}",
        survivors.len(),
        survivors.join("\n"),
        diffs.len(),
        diffs.join("\n"),
        reread.len(),
        reread.join("\n")
    );
    assert_eq!(survivors, Vec::<String>::new());
    assert_eq!(diffs, Vec::<String>::new());
    assert_eq!(reread, Vec::<String>::new());
}

fn gzip(body: &[u8]) -> Vec<u8> {
    use std::io::Write;
    let mut encoder = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
    encoder.write_all(body).unwrap();
    encoder.finish().unwrap()
}

fn log_envelope(body: &str, entries: usize) -> Vec<u8> {
    let items: Vec<Value> = (0..entries)
        .map(|_| json!({"level": "info", "body": body}))
        .collect();
    format!(
        "{}\n{}\n{}\n",
        json!({}),
        json!({"type": "log"}),
        json!({"items": items})
    )
    .into_bytes()
}

fn error_envelope(text: &str, events: usize) -> Vec<u8> {
    let mut out = format!("{}\n", json!({}));
    for _ in 0..events {
        let event = json!({"message": text, "extra": {"a": text}});
        out.push_str(&format!("{}\n{event}\n", json!({"type": "event"})));
    }
    out.into_bytes()
}

/// Chains of pair, URL and quote starts that a backtracking grammar handles in
/// quadratic time, filling an envelope to just under the 4 MiB inflated limit. Gzip brings each under 64 KiB on the wire.
fn adversarial() -> Vec<(&'static str, Vec<u8>)> {
    let unit = |unit: &str, bytes: usize| unit.repeat(bytes / unit.len());
    let envelopes = vec![
        ("logs a=", log_envelope(&unit("a=", 1200 << 10), 3)),
        ("logs a://", log_envelope(&unit("a://", 1200 << 10), 3)),
        ("errors a=", error_envelope(&unit("a=", 440 << 10), 4)),
        (
            "errors a://u:p/",
            error_envelope(&unit("a://u:p/", 440 << 10), 4),
        ),
        ("errors 'a':", error_envelope(&unit("'a':", 440 << 10), 4)),
    ];
    envelopes
        .into_iter()
        .map(|(label, body)| {
            assert!(body.len() < 4 << 20, "{label}: {}", body.len());
            (label, gzip(&body))
        })
        .collect()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn adversarial_posts_finish_quickly_and_never_stall_other_requests() {
    let env = TestEnv::new("privacy-corpus-cost");
    let boot = env.boot_memory(fast_archive).await.unwrap();
    let (base, _server) = serve(&boot).await;
    let api = Api::signup(&base, "privacy-cost@example.test").await;
    let (org, project, dsn) = api.setup_source("Cost").await;
    let key = dsn_key(&dsn);
    for (label, body) in adversarial() {
        let start = Instant::now();
        let posted = tokio::time::timeout(
            Duration::from_secs(10),
            post_envelope(&base, project, &key, body, Some("gzip")),
        )
        .await;
        let took = start.elapsed();
        println!(
            "SINGLE {label}: {:?} in {took:?}",
            posted.as_ref().map(|r| r.0)
        );
        assert_eq!(posted.map(|r| r.0).ok(), Some(StatusCode::OK), "{label}");
    }

    let bodies: Vec<Vec<u8>> = adversarial().into_iter().map(|(_, body)| body).collect();
    let start = Instant::now();
    let posts: Vec<_> = (0..8)
        .map(|n| {
            let (base, key, body) = (base.clone(), key.clone(), bodies[n % bodies.len()].clone());
            tokio::spawn(async move {
                tokio::time::timeout(
                    Duration::from_secs(30),
                    post_envelope(&base, project, &key, body, Some("gzip")),
                )
                .await
                .map(|(status, _)| status)
            })
        })
        .collect();
    let mut slowest = Duration::ZERO;
    for _ in 0..10 {
        tokio::time::sleep(Duration::from_millis(50)).await;
        let probe = Instant::now();
        let (status, _) = api.get(&format!("/api/orgs/{org}/usage")).await;
        assert_eq!(status, StatusCode::OK);
        slowest = slowest.max(probe.elapsed());
    }
    let mut statuses = Vec::new();
    for post in posts {
        statuses.push(post.await.unwrap());
    }
    println!(
        "CONCURRENT 8 posts {statuses:?} in {:?}; slowest unrelated GET {slowest:?}",
        start.elapsed()
    );
    assert!(statuses.iter().all(Result::is_ok), "{statuses:?}");
    assert!(slowest < Duration::from_millis(500), "{slowest:?}");
    <TestApp as loco_rs::app::Hooks>::on_shutdown(&boot.app_context).await;
}
