mod release_support {

    use std::{path::PathBuf, sync::Arc, time::Duration};

    use postdeploy::{
        domain::{OrgId, ProjectId, Role, UserId},
        error_retention::TENANT_RUN_ON_START,
        identity::access::OrgAccess,
        runtime::sql,
        store::{Faults, ObjectStore},
    };
    use sea_orm::{ConnectionTrait, Database, DatabaseConnection};
    use tenant_sqlite_loco::{Config, Synchronous, TenantHandle, TenantId, TenantPools};

    /// Two organizations with one project each, real SQLite files under
    /// `<test run>/releases/<name>-<uuid>`, kept after the test.
    pub struct Env {
        pub dir: PathBuf,
        pub control: DatabaseConnection,
        pub tenants: TenantPools,
        pub store: ObjectStore,
        pub org: OrgId,
        pub other_org: OrgId,
        pub project: ProjectId,
        pub other_project: ProjectId,
    }

    pub const OWNER: UserId = UserId(1);
    pub const MEMBER: UserId = UserId(2);
    pub const OUTSIDER: UserId = UserId(3);

    impl Env {
        pub async fn new(name: &str) -> Self {
            let dir = postdeploy::testing::run_dir()
                .join("releases")
                .join(format!("{name}-{}", uuid::Uuid::now_v7().simple()));
            std::fs::create_dir_all(dir.join("tenants")).unwrap();
            let dir = dir.canonicalize().unwrap();
            let control = Database::connect(format!(
                "sqlite://{}?mode=rwc",
                dir.join("control.sqlite").display()
            ))
            .await
            .unwrap();
            loco_rs::db::migrate::<migration::ControlMigrator>(&control)
                .await
                .unwrap();
            let org = OrgId::generate();
            let other_org = OrgId::generate();
            control
            .execute_unprepared(&format!(
                "INSERT INTO users (id, email, password_hash, created_at) VALUES
                    (1, 'owner@example.invalid', 'x', 0), (2, 'member@example.invalid', 'x', 0),
                    (3, 'outsider@example.invalid', 'x', 0);
                 INSERT INTO organizations (id, name, created_by, created_at) VALUES
                    ('{org}', 'Acme', 1, 0), ('{other_org}', 'Other', 3, 0);
                 INSERT INTO memberships (org_id, user_id, role, created_at) VALUES
                    ('{org}', 1, 'owner', 0), ('{org}', 2, 'member', 0), ('{other_org}', 3, 'owner', 0);
                 INSERT INTO projects (id, org_id, name, created_at) VALUES
                    (10, '{org}', 'web', 0), (20, '{other_org}', 'web', 0);"
            ))
            .await
            .unwrap();
            let mut config = Config::new(dir.join("tenants"));
            config.synchronous = Synchronous::Full;
            config.run_on_start = Some(TENANT_RUN_ON_START.to_owned());
            let registry = tenant_sqlite_loco::Registry::new(config, |db| {
                Box::pin(async move {
                    postdeploy::error_retention::initialize_tenant(db).await?;
                    loco_rs::db::migrate::<migration::OrgMigrator>(db).await
                })
            })
            .unwrap();
            let tenants = TenantPools::from_registry(Arc::new(registry));
            for id in [&org, &other_org] {
                drop(tenants.registry().provision(&tenant_id(id)).await.unwrap());
            }
            let store = ObjectStore::memory(
                &format!("probe/{name}/"),
                Duration::from_secs(5),
                Arc::new(Faults::default()),
            )
            .unwrap();
            Self {
                dir,
                control,
                tenants,
                store,
                org,
                other_org,
                project: ProjectId(10),
                other_project: ProjectId(20),
            }
        }

        pub fn access(&self, user: UserId) -> OrgAccess {
            let (org, role) = match user {
                OWNER => (self.org.clone(), Role::Owner),
                MEMBER => (self.org.clone(), Role::Member),
                _ => (self.other_org.clone(), Role::Owner),
            };
            OrgAccess { user, org, role }
        }

        pub async fn tenant(&self, org: &OrgId) -> TenantHandle {
            self.tenants
                .registry()
                .open_existing(&tenant_id(org))
                .await
                .unwrap()
        }

        pub async fn leased(&self) -> usize {
            self.tenants.registry().stats().await.leased_pools
        }

        pub async fn count(&self, org: &OrgId, query: &str) -> i64 {
            let handle = self.tenant(org).await;
            let row = handle
                .query_one_raw(sql(query, vec![]))
                .await
                .unwrap()
                .unwrap();
            row.try_get_by_index::<i64>(0).unwrap()
        }

        pub async fn keys(&self, prefix: &str) -> Vec<String> {
            self.store
                .list_page(prefix, None, 10_000)
                .await
                .unwrap()
                .keys
        }

        /// Bytes of every file in the run directory, for leak scans.
        pub fn local_bytes(&self) -> Vec<(PathBuf, Vec<u8>)> {
            fn walk(dir: &std::path::Path, out: &mut Vec<(PathBuf, Vec<u8>)>) {
                for entry in std::fs::read_dir(dir).unwrap() {
                    let path = entry.unwrap().path();
                    if path.is_dir() {
                        walk(&path, out);
                    } else {
                        out.push((path.clone(), std::fs::read(&path).unwrap()));
                    }
                }
            }
            let mut out = Vec::new();
            walk(&self.dir, &mut out);
            out
        }
    }

    pub fn tenant_id(org: &OrgId) -> TenantId {
        TenantId::new(org.as_str()).unwrap()
    }

    pub fn fixture(path: &str) -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures/releases")
            .join(path)
    }

    /// The scrubbed SDK event JSON, mapped by the app's real envelope and event code.
    pub fn captured_event(name: &str) -> serde_json::Value {
        use postdeploy::{
            domain::Environment,
            ingest::{envelope, event},
        };
        let raw = std::fs::read(fixture(&format!("captures/{name}.envelope"))).unwrap();
        let limits = envelope::Limits {
            max_inflated_bytes: 4 << 20,
            max_items: 100,
            max_events: 10,
        };
        let parsed = envelope::parse(&bytes::Bytes::from(raw), &limits).unwrap();
        assert_eq!(parsed.events.len(), 1, "one SDK event item");
        let mapped = event::map(
            &parsed.events[0],
            parsed.event_id.as_deref(),
            ProjectId(10),
            &Environment::parse("production").unwrap(),
            0,
            1 << 20,
            &postdeploy::ingest::policy::IngestionPolicy::default(),
        )
        .unwrap();
        serde_json::from_slice(&mapped.payload).unwrap()
    }
}

use std::time::Duration;

use bytes::Bytes;
use credseal::SecretString;
use postdeploy::{
    credentials::R2Credentials,
    domain::ProjectId,
    error::ApiError,
    releases::{
        ArtifactQuery, FrameStatus, MatchedBy, ReleaseSettings, Releases, StackOrigin,
        Symbolicated, SymbolicatedFrame, UploadRequest,
    },
    store::ObjectStore,
};
use release_support::{captured_event, fixture, Env, MEMBER, OUTSIDER, OWNER};
use serde_json::{json, Value};

fn service(env: &Env, settings: ReleaseSettings) -> Releases {
    Releases::new(
        env.control.clone(),
        env.tenants.clone(),
        env.store.clone(),
        settings,
    )
}

fn map_body(build: &str) -> Bytes {
    Bytes::from(std::fs::read(fixture(&format!("dist/{build}/app.js.map"))).unwrap())
}

fn bundle_debug_id() -> String {
    let bundle = std::fs::read_to_string(fixture("dist/debugid/app.js")).unwrap();
    let start = bundle.find("sentry-dbid-").unwrap() + "sentry-dbid-".len();
    bundle[start..start + 36].to_owned()
}

fn release_upload(project: ProjectId) -> UploadRequest {
    UploadRequest {
        project,
        release: Some("checkout@1.4.0".into()),
        dist: Some("web".into()),
        name: "~/dist/release/app.js".into(),
        debug_id: None,
        body: map_body("release"),
    }
}

fn app_frames(result: &Symbolicated) -> Vec<&SymbolicatedFrame> {
    let stack = &result.stacks[0];
    assert_eq!(stack.origin, StackOrigin::Exception);
    stack
        .frames
        .iter()
        .filter(|f| {
            f.raw
                .file
                .as_deref()
                .is_some_and(|file| file.contains("dist/"))
        })
        .collect()
}

fn summary(frame: &SymbolicatedFrame) -> Value {
    let original = frame.original.as_ref();
    json!({
        "status": frame.status,
        "matched_by": frame.matched_by,
        "function": original.and_then(|o| o.function.clone()),
        "file": original.map(|o| o.file.clone()),
        "lineno": original.map(|o| o.lineno),
        "context_line": original.and_then(|o| o.context_line.clone()),
    })
}

fn evidence(name: &str, value: &impl serde::Serialize) {
    let dir = postdeploy::testing::run_dir().join("releases/evidence");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(
        dir.join(format!("{name}.json")),
        serde_json::to_vec_pretty(value).unwrap(),
    )
    .unwrap();
}

#[tokio::test]
async fn real_sdk_error_maps_to_original_typescript_frames_by_release_url() {
    let env = Env::new("release-url").await;
    let releases = service(&env, ReleaseSettings::default());
    let uploaded = releases
        .upload(&env.access(OWNER), release_upload(env.project))
        .await
        .unwrap();
    assert!(uploaded.created);
    assert_eq!(uploaded.artifact.name, "~/dist/release/app.js");

    let payload = captured_event("release");
    let result = releases
        .symbolicate(&env.access(MEMBER), env.project, &payload)
        .await
        .unwrap();
    evidence("release-url-symbolicated", &result);
    assert_eq!(result.release.as_deref(), Some("checkout@1.4.0"));
    assert_eq!(result.dist.as_deref(), Some("web"));

    let frames = &result.stacks[0].frames;
    assert_eq!(frames.len(), 6);
    for runtime in &frames[..3] {
        assert_eq!(runtime.status, FrameStatus::NotApplicable);
        assert!(runtime
            .raw
            .file
            .as_deref()
            .unwrap()
            .starts_with("node:internal/"));
    }
    let app = app_frames(&result);
    assert_eq!(
        app.iter().map(|f| summary(f)).collect::<Vec<_>>(),
        vec![
            json!({"status": "symbolicated", "matched_by": "url", "function": "?",
                "file": "../../src/main.ts", "lineno": 18,
                "context_line": "  processOrder({ items: [{ sku: \"kb-01\", price: 80 }, { sku: \"ms-02\", price: 45 }] });"}),
            json!({"status": "symbolicated", "matched_by": "url", "function": "processOrder",
                "file": "../../src/checkout.ts", "lineno": 21,
                "context_line": "  const charged = priceOf(cart) * 1.2;"}),
            json!({"status": "symbolicated", "matched_by": "url", "function": "priceOf",
                "file": "../../src/checkout.ts", "lineno": 15,
                "context_line": "    throw new TypeError(`cart total ${total} exceeds the card limit`);"}),
        ]
    );
    let throw = app[2].original.as_ref().unwrap();
    assert_eq!(
        throw.pre_context,
        vec![
            "const endpoint = \"https://payments.test/v1/charge?api_key=[Filtered]\";",
            "",
            "export function priceOf(cart: Cart): number {",
            "  const total = cart.items.reduce((sum, item) => sum + item.price, 0);",
            "  if (total > 100) {",
        ]
    );
    assert_eq!(
        throw.post_context,
        vec![
            "  }",
            "  return total;",
            "}",
            "",
            "export function processOrder(cart: Cart): number {"
        ]
    );
    assert!(throw.in_app);
    assert_eq!(app[2].raw.function.as_deref(), Some("c"));
    assert_eq!(app[2].raw.lineno, Some(1));
    assert_eq!(env.leased().await, 0);
}

#[tokio::test]
async fn real_sdk_debug_id_selects_the_map_without_a_release_upload() {
    let env = Env::new("debug-id").await;
    let releases = service(&env, ReleaseSettings::default());
    let id = bundle_debug_id();
    let uploaded = releases
        .upload(
            &env.access(OWNER),
            UploadRequest {
                project: env.project,
                release: None,
                dist: None,
                name: "~/dist/debugid/app.js".into(),
                debug_id: Some(id.to_uppercase()),
                body: map_body("debugid"),
            },
        )
        .await
        .unwrap();
    assert_eq!(uploaded.artifact.debug_id.as_deref(), Some(id.as_str()));
    assert_eq!(uploaded.artifact.release, None);

    let payload = captured_event("debugid");
    assert_eq!(payload["debug_meta"]["images"][0]["debug_id"], json!(id));
    let result = releases
        .symbolicate(&env.access(OWNER), env.project, &payload)
        .await
        .unwrap();
    evidence("debug-id-symbolicated", &result);
    let app = app_frames(&result);
    assert_eq!(
        app.iter()
            .map(|f| (
                f.status,
                f.matched_by,
                f.original.as_ref().map(|o| (o.function.clone(), o.lineno))
            ))
            .collect::<Vec<_>>(),
        vec![
            (
                FrameStatus::Symbolicated,
                Some(MatchedBy::DebugId),
                Some((Some("?".into()), 18))
            ),
            (
                FrameStatus::Symbolicated,
                Some(MatchedBy::DebugId),
                Some((Some("processOrder".into()), 21))
            ),
            (
                FrameStatus::Symbolicated,
                Some(MatchedBy::DebugId),
                Some((Some("priceOf".into()), 15))
            ),
        ]
    );
}

#[tokio::test]
async fn missing_artifacts_keep_raw_frames_with_an_explicit_status() {
    let env = Env::new("missing").await;
    let releases = service(&env, ReleaseSettings::default());
    let payload = captured_event("release");
    let result = releases
        .symbolicate(&env.access(OWNER), env.project, &payload)
        .await
        .unwrap();
    let app = app_frames(&result);
    assert_eq!(app.len(), 3);
    for frame in &app {
        assert_eq!(frame.status, FrameStatus::MissingArtifact);
        assert!(frame.original.is_none() && frame.artifact_id.is_none());
        assert_eq!(
            frame.raw.file.as_deref(),
            Some("app:///dist/release/app.js")
        );
        assert_eq!(frame.raw.lineno, Some(1));
    }
    assert_eq!(
        app.iter()
            .map(|f| f.raw.function.clone().unwrap())
            .collect::<Vec<_>>(),
        vec!["?", "n", "c"]
    );
}

/// One frame at the captured SDK throw position, under another file URL.
fn synthetic(file: &str, release: &str) -> Value {
    let captured = captured_event("release");
    let frames = captured["exception"]["values"][0]["stacktrace"]["frames"]
        .as_array()
        .unwrap();
    let colno = frames.last().unwrap()["colno"].clone();
    json!({
        "release": release,
        "exception": {"values": [{"type": "TypeError", "value": "boom", "stacktrace": {"frames": [
            {"function": "c", "abs_path": file, "lineno": 1, "colno": colno}
        ]}}]}
    })
}

#[tokio::test]
async fn basename_matches_only_when_unique_in_the_release() {
    let env = Env::new("basename").await;
    let releases = service(&env, ReleaseSettings::default());
    let mut upload = release_upload(env.project);
    upload.dist = None;
    upload.name = "https://cdn.example.com/assets/app.js?v=9".into();
    let first = releases
        .upload(&env.access(OWNER), upload.clone())
        .await
        .unwrap();
    assert_eq!(first.artifact.name, "~/assets/app.js");

    let payload = synthetic("https://shop.example.com/static/app.js", "checkout@1.4.0");
    let result = releases
        .symbolicate(&env.access(OWNER), env.project, &payload)
        .await
        .unwrap();
    let frame = &result.stacks[0].frames[0];
    assert_eq!(
        (frame.status, frame.matched_by),
        (FrameStatus::Symbolicated, Some(MatchedBy::Basename))
    );
    assert_eq!(frame.original.as_ref().unwrap().lineno, 15);

    let exact = synthetic("https://shop.example.com/assets/app.js", "checkout@1.4.0");
    let result = releases
        .symbolicate(&env.access(OWNER), env.project, &exact)
        .await
        .unwrap();
    assert_eq!(result.stacks[0].frames[0].matched_by, Some(MatchedBy::Url));

    upload.name = "~/other/app.js".into();
    releases.upload(&env.access(OWNER), upload).await.unwrap();
    let result = releases
        .symbolicate(&env.access(OWNER), env.project, &payload)
        .await
        .unwrap();
    assert_eq!(
        result.stacks[0].frames[0].status,
        FrameStatus::MissingArtifact
    );

    let other_release = synthetic("https://shop.example.com/assets/app.js", "checkout@9.9.9");
    let result = releases
        .symbolicate(&env.access(OWNER), env.project, &other_release)
        .await
        .unwrap();
    assert_eq!(
        result.stacks[0].frames[0].status,
        FrameStatus::MissingArtifact
    );
}

#[tokio::test]
async fn stored_map_is_scrubbed_compressed_and_keeps_mappings_and_names() {
    let env = Env::new("scrub").await;
    let releases = service(&env, ReleaseSettings::default());
    let uploaded = releases
        .upload(&env.access(OWNER), release_upload(env.project))
        .await
        .unwrap();
    let keys = env.keys("releases/").await;
    assert_eq!(
        keys,
        vec![format!(
            "releases/v1/{}/10/{}.map.zst",
            env.org, uploaded.artifact.id
        )]
    );
    let stored = env.store.get(&keys[0], 1 << 20).await.unwrap().unwrap();
    assert_eq!(stored.len() as i64, uploaded.artifact.stored_bytes);
    let json: Value =
        serde_json::from_slice(&zstd::stream::decode_all(&stored[..]).unwrap()).unwrap();
    let original: Value = serde_json::from_slice(&map_body("release")).unwrap();
    assert_eq!(json["mappings"], original["mappings"]);
    assert_eq!(json["names"], original["names"]);
    assert_eq!(json["sources"], original["sources"]);
    assert_eq!(json["version"], json!(3));
    let content = json["sourcesContent"][1].as_str().unwrap();
    let before = original["sourcesContent"][1].as_str().unwrap();
    assert!(before.contains("api_key=pd_fixture_secret_0042"));
    assert!(content.contains("api_key=[Filtered]"));
    assert!(!content.contains("pd_fixture_secret_0042"));
    assert_eq!(content.lines().count(), before.lines().count());

    for (path, bytes) in env.local_bytes() {
        for marker in [
            "pd_fixture_secret_0042",
            "exceeds the card limit",
            "processOrder",
        ] {
            assert!(
                !bytes.windows(marker.len()).any(|w| w == marker.as_bytes()),
                "{marker} found in {}",
                path.display()
            );
        }
    }
    let row = env
        .count(&env.org, "SELECT raw_bytes FROM release_artifacts")
        .await;
    assert_eq!(row, uploaded.artifact.size);
}

#[tokio::test]
async fn uploads_need_a_manager_and_every_read_is_scoped_to_the_organization() {
    let env = Env::new("isolation").await;
    let releases = service(&env, ReleaseSettings::default());
    assert!(matches!(
        releases
            .upload(&env.access(MEMBER), release_upload(env.project))
            .await,
        Err(ApiError::Forbidden)
    ));
    assert!(matches!(
        releases
            .upload(&env.access(OWNER), release_upload(env.other_project))
            .await,
        Err(ApiError::NotFound)
    ));
    assert!(env.keys("releases/").await.is_empty());
    assert_eq!(
        env.count(&env.other_org, "SELECT COUNT(*) FROM release_artifacts")
            .await,
        0
    );

    let uploaded = releases
        .upload(&env.access(OWNER), release_upload(env.project))
        .await
        .unwrap();
    let id = uploaded.artifact.id.clone();
    let outsider = env.access(OUTSIDER);
    assert!(matches!(
        releases.get(&outsider, &id).await,
        Err(ApiError::NotFound)
    ));
    assert!(matches!(
        releases
            .list(&outsider, env.project, ArtifactQuery::default())
            .await,
        Err(ApiError::NotFound)
    ));
    assert!(matches!(
        releases.releases(&outsider, env.project, None).await,
        Err(ApiError::NotFound)
    ));
    assert!(matches!(
        releases
            .symbolicate(&outsider, env.project, &captured_event("release"))
            .await,
        Err(ApiError::NotFound)
    ));
    let own = releases
        .list(&outsider, env.other_project, ArtifactQuery::default())
        .await
        .unwrap();
    assert!(own.artifacts.is_empty());
    let result = releases
        .symbolicate(&outsider, env.other_project, &captured_event("release"))
        .await
        .unwrap();
    assert!(app_frames(&result)
        .iter()
        .all(|f| f.status == FrameStatus::MissingArtifact));

    let member = env.access(MEMBER);
    assert_eq!(releases.get(&member, &id).await.unwrap(), uploaded.artifact);
    let page = releases
        .list(&member, env.project, ArtifactQuery::default())
        .await
        .unwrap();
    assert_eq!(page.artifacts, vec![uploaded.artifact.clone()]);
    let summary = releases.releases(&member, env.project, None).await.unwrap();
    assert_eq!(
        serde_json::to_value(&summary).unwrap(),
        json!([{"release": "checkout@1.4.0", "dist": "web", "artifact_count": 1,
            "last_uploaded": uploaded.artifact.created_at}])
    );
}

#[tokio::test]
async fn retries_are_idempotent_and_different_content_never_overwrites() {
    let env = Env::new("immutable").await;
    let releases = service(&env, ReleaseSettings::default());
    let owner = env.access(OWNER);
    let first = releases
        .upload(&owner, release_upload(env.project))
        .await
        .unwrap();
    let again = releases
        .upload(&owner, release_upload(env.project))
        .await
        .unwrap();
    assert!(first.created && !again.created);
    assert_eq!(first.artifact, again.artifact);

    let mut changed = release_upload(env.project);
    changed.body = map_body("debugid");
    assert!(matches!(
        releases.upload(&owner, changed).await,
        Err(ApiError::Conflict("artifact_exists"))
    ));
    assert_eq!(env.keys("releases/").await.len(), 1);

    let (a, b) = tokio::join!(
        releases.upload(
            &owner,
            UploadRequest {
                name: "~/race/app.js".into(),
                ..release_upload(env.project)
            }
        ),
        releases.upload(
            &owner,
            UploadRequest {
                name: "~/race/app.js".into(),
                ..release_upload(env.project)
            }
        ),
    );
    let (a, b) = (a.unwrap(), b.unwrap());
    assert_eq!(a.artifact.id, b.artifact.id);
    assert_eq!([a.created, b.created].iter().filter(|c| **c).count(), 1);
    assert_eq!(env.keys("releases/").await.len(), 2);
    assert_eq!(
        env.count(&env.org, "SELECT COUNT(*) FROM release_artifacts")
            .await,
        2
    );
}

#[tokio::test]
async fn malformed_oversize_and_invalid_targets_store_nothing() {
    let env = Env::new("malformed").await;
    let releases = service(
        &env,
        ReleaseSettings {
            max_artifact_bytes: 1024,
            ..ReleaseSettings::default()
        },
    );
    let owner = env.access(OWNER);
    let with = |body: &[u8]| UploadRequest {
        body: Bytes::copy_from_slice(body),
        ..release_upload(env.project)
    };
    let cases: Vec<(UploadRequest, &str)> = vec![
        (with(b"{not json"), "invalid_source_map"),
        (with(br#"{"version":3,"sections":[{"offset":{"line":0,"column":0},"url":"https://evil.test/x.map"}]}"#), "unsupported_source_map"),
        (with(br#"{"version":2,"sources":[],"mappings":""}"#), "invalid_source_map"),
        (with(br#"{"version":3,"sources":["a.js"],"mappings":"%%%"}"#), "invalid_source_map"),
        (with(br#"{"version":3,"sources":[],"mappings":"","debugId":"not-a-uuid"}"#), "invalid_source_map"),
        (UploadRequest { name: "~/assets/../../etc/passwd".into(), ..with(b"{}") }, "invalid_name"),
        (UploadRequest { release: Some("a/b".into()), ..with(b"{}") }, "invalid_release"),
        (UploadRequest { dist: Some("x\ny".into()), ..with(b"{}") }, "invalid_dist"),
        (UploadRequest { debug_id: Some("zz".into()), ..with(b"{}") }, "invalid_debug_id"),
        (UploadRequest { release: None, ..with(br#"{"version":3,"sources":[],"mappings":""}"#) }, "release_or_debug_id_required"),
        (
            UploadRequest {
                debug_id: Some("6f2b3c1e-0000-4000-8000-000000000001".into()),
                ..with(br#"{"version":3,"sources":[],"mappings":"","debugId":"6f2b3c1e-0000-4000-8000-000000000002"}"#)
            },
            "debug_id_mismatch",
        ),
    ];
    for (request, code) in cases {
        match releases.upload(&owner, request).await {
            Err(ApiError::BadRequest(got)) => assert_eq!(got, code),
            other => panic!("{code}: {other:?}"),
        }
    }
    assert!(matches!(
        releases.upload(&owner, release_upload(env.project)).await,
        Err(ApiError::TooLarge)
    ));
    assert!(env.keys("releases/").await.is_empty());
    assert_eq!(
        env.count(&env.org, "SELECT COUNT(*) FROM release_artifacts")
            .await,
        0
    );
}

#[tokio::test]
async fn storage_failures_and_limits_leave_no_unreferenced_objects() {
    let env = Env::new("failures").await;
    let releases = service(
        &env,
        ReleaseSettings {
            max_artifacts_per_project: 1,
            ..ReleaseSettings::default()
        },
    );
    let owner = env.access(OWNER);
    env.store
        .faults()
        .unwrap()
        .fail_puts
        .store(1, std::sync::atomic::Ordering::SeqCst);
    assert!(matches!(
        releases.upload(&owner, release_upload(env.project)).await,
        Err(ApiError::Unavailable("store_unavailable"))
    ));
    assert_eq!(
        env.count(&env.org, "SELECT COUNT(*) FROM release_artifacts")
            .await,
        0
    );

    releases
        .upload(&owner, release_upload(env.project))
        .await
        .unwrap();
    let second = UploadRequest {
        name: "~/dist/other.js".into(),
        ..release_upload(env.project)
    };
    assert!(matches!(
        releases.upload(&owner, second).await,
        Err(ApiError::Conflict("artifact_limit"))
    ));
    assert_eq!(env.keys("releases/").await.len(), 1);
    assert_eq!(env.leased().await, 0);
}

fn unreachable_store() -> ObjectStore {
    ObjectStore::r2(
        &R2Credentials {
            endpoint: "http://127.0.0.1:9".into(),
            bucket: "probe".into(),
            access_key_id: serde_json::from_value::<SecretString>(json!("probe")).unwrap(),
            secret_access_key: serde_json::from_value::<SecretString>(json!("probe")).unwrap(),
        },
        "probe/",
        Duration::from_secs(2),
    )
    .unwrap()
}

#[tokio::test]
async fn unreadable_maps_deadlines_and_budgets_report_status_per_frame() {
    let env = Env::new("unreadable").await;
    let releases = service(&env, ReleaseSettings::default());
    releases
        .upload(&env.access(OWNER), release_upload(env.project))
        .await
        .unwrap();
    let payload = captured_event("release");
    let statuses = |result: &Symbolicated| {
        app_frames(result)
            .iter()
            .map(|f| f.status)
            .collect::<Vec<_>>()
    };

    let offline = Releases::new(
        env.control.clone(),
        env.tenants.clone(),
        unreachable_store(),
        ReleaseSettings::default(),
    );
    let result = offline
        .symbolicate(&env.access(OWNER), env.project, &payload)
        .await
        .unwrap();
    assert_eq!(statuses(&result), vec![FrameStatus::ArtifactUnavailable; 3]);
    assert!(app_frames(&result)
        .iter()
        .all(|f| f.raw.function.is_some() && f.original.is_none()));
    assert_eq!(env.leased().await, 0);

    let expired = service(
        &env,
        ReleaseSettings {
            symbolicate_deadline_ms: 0,
            ..ReleaseSettings::default()
        },
    );
    let result = expired
        .symbolicate(&env.access(OWNER), env.project, &payload)
        .await
        .unwrap();
    assert_eq!(statuses(&result), vec![FrameStatus::DeadlineExceeded; 3]);

    let no_maps = service(
        &env,
        ReleaseSettings {
            max_maps_per_event: 0,
            ..ReleaseSettings::default()
        },
    );
    let result = no_maps
        .symbolicate(&env.access(OWNER), env.project, &payload)
        .await
        .unwrap();
    assert_eq!(statuses(&result), vec![FrameStatus::Skipped; 3]);

    let two = service(
        &env,
        ReleaseSettings {
            max_frames: 2,
            ..ReleaseSettings::default()
        },
    );
    let result = two
        .symbolicate(&env.access(OWNER), env.project, &payload)
        .await
        .unwrap();
    assert!(result.frames_truncated);
    assert_eq!(
        result.stacks[0]
            .frames
            .iter()
            .map(|f| f.raw.function.clone().unwrap())
            .collect::<Vec<_>>(),
        vec!["n", "c"]
    );

    let key = env.keys("releases/").await.remove(0);
    env.store
        .put(&key, Bytes::from_static(b"not zstd"))
        .await
        .unwrap();
    let fresh = service(&env, ReleaseSettings::default());
    let result = fresh
        .symbolicate(&env.access(OWNER), env.project, &payload)
        .await
        .unwrap();
    assert_eq!(statuses(&result), vec![FrameStatus::MalformedArtifact; 3]);

    env.store.delete(&key).await.unwrap();
    let fresh = service(&env, ReleaseSettings::default());
    let result = fresh
        .symbolicate(&env.access(OWNER), env.project, &payload)
        .await
        .unwrap();
    assert_eq!(statuses(&result), vec![FrameStatus::ArtifactUnavailable; 3]);
}

#[tokio::test]
async fn deletion_requires_manager_removes_r2_and_invalidates_cached_mapping() {
    let env = Env::new("delete").await;
    let releases = service(&env, ReleaseSettings::default());
    let artifact = releases
        .upload(&env.access(OWNER), release_upload(env.project))
        .await
        .unwrap()
        .artifact;
    let payload = captured_event("release");
    let mapped = releases
        .symbolicate(&env.access(OWNER), env.project, &payload)
        .await
        .unwrap();
    assert_eq!(app_frames(&mapped)[2].status, FrameStatus::Symbolicated);
    assert!(matches!(
        releases.delete(&env.access(MEMBER), &artifact.id).await,
        Err(ApiError::Forbidden)
    ));
    assert!(matches!(
        releases.delete(&env.access(OUTSIDER), &artifact.id).await,
        Err(ApiError::NotFound)
    ));
    releases
        .delete(&env.access(OWNER), &artifact.id)
        .await
        .unwrap();
    assert!(env.keys("releases/").await.is_empty());
    assert!(matches!(
        releases.get(&env.access(OWNER), &artifact.id).await,
        Err(ApiError::NotFound)
    ));
    let result = releases
        .symbolicate(&env.access(OWNER), env.project, &payload)
        .await
        .unwrap();
    assert!(app_frames(&result)
        .iter()
        .all(|frame| frame.status == FrameStatus::MissingArtifact));
    assert_eq!(env.leased().await, 0);
}

async fn seed_retention(env: &Env, now: i64, count: i64) {
    use postdeploy::runtime::sql;
    use sea_orm::ConnectionTrait;
    let handle = env.tenant(&env.org).await;
    handle.execute_unprepared("INSERT INTO issues (id,project_id,environment,fingerprint,title,level,status,first_seen,last_seen,event_count) VALUES (1,10,'production','retention','fixture','error','open',0,0,3)").await.unwrap();
    drop(handle);
    for n in 0..count {
        let key = format!("errors/v1/{}/10/1/fixture-{n}.json.zst", env.org);
        env.store
            .put(&key, Bytes::from_static(b"isolated-retention-fixture"))
            .await
            .unwrap();
        let handle = env.tenant(&env.org).await;
        handle.execute_raw(sql("INSERT INTO events (issue_id,project_id,source_id,event_id,level,occurred_at,received_at,payload_key,payload_bytes) VALUES(1,10,1,?,'error',?,?,?,26)", vec![format!("{n:032x}").into(), now.into(), now.into(), key.into()])).await.unwrap();
    }
}

#[tokio::test]
async fn retention_deletes_r2_before_metadata_in_indexed_bounded_batches() {
    use postdeploy::{
        error_retention::{ErrorRetention, ErrorRetentionSettings},
        runtime::sql,
    };
    use sea_orm::ConnectionTrait;
    let env = Env::new("retention").await;
    let now = postdeploy::domain::now_micros();
    seed_retention(&env, now - 3 * 86_400_000_000, 3).await;
    let settings = ErrorRetentionSettings {
        event_days: 1,
        batch: 1,
        max_batches: 1,
        ..Default::default()
    };
    let retention = ErrorRetention::new(
        env.control.clone(),
        env.tenants.clone(),
        env.store.clone(),
        settings,
    );
    let first = retention.sweep_org(&env.org, now).await.unwrap();
    assert_eq!(first.events_deleted, 1);
    assert_eq!(first.payload_failures, 0);
    assert!(!first.complete);
    assert_eq!(first.issues_deleted, 0);
    assert_eq!(env.keys("errors/").await.len(), 2);
    assert_eq!(env.count(&env.org, "SELECT COUNT(*) FROM events").await, 2);
    let handle = env.tenant(&env.org).await;
    let plans = handle.query_all_raw(sql("EXPLAIN QUERY PLAN SELECT id,payload_key FROM events WHERE received_at < ? ORDER BY received_at LIMIT 1", vec![now.into()])).await.unwrap();
    assert!(plans.iter().any(|row| row
        .try_get::<String>("", "detail")
        .unwrap()
        .contains("events_received")));
    drop(handle);
    retention.sweep_org(&env.org, now).await.unwrap();
    let last = retention.sweep_org(&env.org, now).await.unwrap();
    assert_eq!(last.issues_deleted, 1);
    assert_eq!(env.count(&env.org, "SELECT COUNT(*) FROM issues").await, 0);
    assert!(env.keys("errors/").await.is_empty());
    assert!(retention.sweep_org(&env.org, now).await.unwrap().complete);
    assert_eq!(env.leased().await, 0);
}

#[tokio::test]
async fn retention_keeps_rows_when_r2_delete_fails_and_reclaims_incremental_pages() {
    use postdeploy::{
        error_retention::{ErrorRetention, ErrorRetentionSettings},
        runtime::sql,
    };
    use sea_orm::ConnectionTrait;
    let env = Env::new("retention-failure").await;
    let now = postdeploy::domain::now_micros();
    seed_retention(&env, 0, 1).await;
    let failing = ErrorRetention::new(
        env.control.clone(),
        env.tenants.clone(),
        unreachable_store(),
        ErrorRetentionSettings::default(),
    );
    let failed = failing.sweep_org(&env.org, now).await.unwrap();
    assert_eq!(failed.payload_failures, 1);
    assert_eq!(failed.events_deleted, 0);
    assert_eq!(failed.issues_deleted, 0);
    assert!(!failed.complete);
    assert_eq!(env.count(&env.org, "SELECT COUNT(*) FROM events").await, 1);
    let handle = env.tenant(&env.org).await;
    let mode = handle
        .query_one_raw(sql("PRAGMA auto_vacuum", vec![]))
        .await
        .unwrap()
        .unwrap()
        .try_get_by_index::<i64>(0)
        .unwrap();
    assert_eq!(mode, 2);
    handle.execute_unprepared("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<1500) INSERT INTO usage_daily(day,category,accepted,bytes) SELECT '2000-01-01', printf('%08d-%0250d',i,i),1,1 FROM n").await.unwrap();
    drop(handle);
    let before = env.count(&env.org, "PRAGMA page_count").await;
    let working = ErrorRetention::new(
        env.control.clone(),
        env.tenants.clone(),
        env.store.clone(),
        ErrorRetentionSettings {
            batch: 1000,
            vacuum_pages: 4096,
            ..Default::default()
        },
    );
    working.sweep_org(&env.org, now).await.unwrap();
    let mut pages = 0;
    for _ in 0..5 {
        pages += working
            .sweep_org(&env.org, now)
            .await
            .unwrap()
            .pages_reclaimed;
    }
    assert!(pages > 0);
    assert!(env.count(&env.org, "PRAGMA page_count").await < before);
    assert_eq!(
        env.count(&env.org, "SELECT COUNT(*) FROM usage_daily")
            .await,
        0
    );
    assert_eq!(env.leased().await, 0);
}

#[tokio::test]
#[ignore = "requires isolated R2 test credentials"]
async fn real_r2_maps_sdk_frame_then_deletes_only_its_owned_artifact() {
    use postdeploy::credentials::Credentials;
    let env = Env::new("real-r2").await;
    let path = std::path::PathBuf::from(std::env::var("POSTDEPLOY_CREDENTIALS_FILE").unwrap());
    let credentials = Credentials::load(&path, "test").unwrap();
    let prefix = format!(
        "local-verification/releases-{}/",
        uuid::Uuid::now_v7().simple()
    );
    let store = ObjectStore::r2(&credentials.r2, &prefix, Duration::from_secs(30)).unwrap();
    let releases = Releases::new(
        env.control.clone(),
        env.tenants.clone(),
        store.clone(),
        ReleaseSettings::default(),
    );
    let artifact = releases
        .upload(&env.access(OWNER), release_upload(env.project))
        .await
        .unwrap()
        .artifact;
    let page = store.list_page("releases/", None, 10).await.unwrap();
    assert_eq!(page.keys.len(), 1);
    let stored = store.get(&page.keys[0], 1 << 20).await.unwrap().unwrap();
    let map = zstd::stream::decode_all(&stored[..]).unwrap();
    let document: Value = serde_json::from_slice(&map).unwrap();
    assert!(document["sourcesContent"][0]
        .as_str()
        .unwrap()
        .contains("processOrder"));
    let result = releases
        .symbolicate(&env.access(OWNER), env.project, &captured_event("release"))
        .await
        .unwrap();
    let thrown = app_frames(&result)[2].original.as_ref().unwrap();
    assert_eq!(thrown.lineno, 15);
    assert_eq!(thrown.function.as_deref(), Some("priceOf"));
    assert_eq!(
        thrown.context_line.as_deref(),
        Some("    throw new TypeError(`cart total ${total} exceeds the card limit`);")
    );
    evidence("real-r2-symbolicated", &result);
    releases
        .delete(&env.access(OWNER), &artifact.id)
        .await
        .unwrap();
    assert!(store
        .list_page("releases/", None, 10)
        .await
        .unwrap()
        .keys
        .is_empty());
    assert!(releases
        .list(&env.access(OWNER), env.project, ArtifactQuery::default())
        .await
        .unwrap()
        .artifacts
        .is_empty());
    println!("real R2 source-map upload, read, symbolication, deletion passed in {prefix}");
}

#[path = "support/mod.rs"]
mod api_support;

#[tokio::test]
async fn loco_api_uploads_map_and_returns_original_sdk_frame_without_dsn_read_access() {
    use loco_rs::app::Hooks;
    use postdeploy::{
        runtime::Runtime,
        testing::{serve, TestApp, TestEnv},
    };
    use reqwest::StatusCode;
    let env = TestEnv::new("release-http");
    let boot = env.boot_memory(|_| {}).await.unwrap();
    let (base, server) = serve(&boot).await;
    let owner = api_support::Api::signup(&base, "release-owner@example.invalid").await;
    let (org, project, dsn) = owner.setup_source("release-http").await;
    let artifact_path = format!("/api/orgs/{org}/projects/{project}/artifacts");
    let upload = || {
        owner
            .http
            .post(format!("{base}{artifact_path}"))
            .header("cookie", owner.cookie.as_ref().unwrap())
            .header("x-csrf-token", owner.csrf.as_ref().unwrap())
            .query(&[
                ("release", "checkout@1.4.0"),
                ("dist", "web"),
                ("name", "~/dist/release/app.js"),
            ])
            .header("content-type", "application/json")
            .body(map_body("release"))
    };
    let rt = Runtime::get(&boot.app_context);
    let first_slot = rt.releases.upload_slot().unwrap();
    let second_slot = rt.releases.upload_slot().unwrap();
    assert_eq!(
        upload().send().await.unwrap().status(),
        StatusCode::SERVICE_UNAVAILABLE
    );
    drop((first_slot, second_slot));
    let uploaded = upload().send().await.unwrap();
    assert_eq!(uploaded.status(), StatusCode::CREATED);
    let artifact: Value = uploaded.json().await.unwrap();
    let id = artifact["artifact"]["id"].as_str().unwrap();
    assert_eq!(upload().send().await.unwrap().status(), StatusCode::OK);
    let key = api_support::dsn_key(&dsn);
    let denied = reqwest::Client::new()
        .post(format!("{base}{artifact_path}"))
        .header(
            "x-sentry-auth",
            format!("Sentry sentry_version=7, sentry_key={key}"),
        )
        .query(&[
            ("release", "checkout@1.4.0"),
            ("name", "~/dist/release/app.js"),
        ])
        .body(map_body("release"))
        .send()
        .await
        .unwrap();
    assert_eq!(denied.status(), StatusCode::UNAUTHORIZED);
    let denied = reqwest::Client::new()
        .get(format!("{base}{artifact_path}"))
        .header("authorization", format!("Bearer {key}"))
        .send()
        .await
        .unwrap();
    assert_eq!(denied.status(), StatusCode::UNAUTHORIZED);
    let outsider = api_support::Api::signup(&base, "release-outsider@example.invalid").await;
    assert_eq!(outsider.get(&artifact_path).await.0, StatusCode::NOT_FOUND);
    let raw = std::fs::read(fixture("captures/release.envelope")).unwrap();
    assert_eq!(
        api_support::post_envelope(&base, project, &key, raw, None)
            .await
            .0,
        StatusCode::OK
    );
    let (status, inbox) = owner.get(&format!("/api/orgs/{org}/issues")).await;
    assert_eq!(status, StatusCode::OK);
    let issue = inbox["issues"][0]["id"].as_i64().unwrap();
    let (_, detail) = owner.get(&format!("/api/orgs/{org}/issues/{issue}")).await;
    let event = detail["latest_event"]["event_id"].as_str().unwrap();
    let (status, body) = owner
        .get(&format!("/api/orgs/{org}/issues/{issue}/events/{event}"))
        .await;
    assert_eq!(status, StatusCode::OK);
    let frames = body["payload"]["postdeploy_symbolicated"]["stacks"][0]["frames"]
        .as_array()
        .unwrap();
    let frame = frames.last().unwrap();
    assert_eq!(frame["status"], "symbolicated");
    assert_eq!(frame["original"]["file"], "../../src/checkout.ts");
    assert_eq!(frame["original"]["lineno"], 15);
    assert_eq!(frame["original"]["function"], "priceOf");
    assert_eq!(
        frame["original"]["context_line"],
        "    throw new TypeError(`cart total ${total} exceeds the card limit`);"
    );
    assert_eq!(
        owner
            .send(
                reqwest::Method::DELETE,
                &format!("/api/orgs/{org}/artifacts/{id}"),
                None
            )
            .await
            .0,
        StatusCode::NO_CONTENT
    );
    assert!(env
        .store
        .list_page("releases/", None, 10)
        .await
        .unwrap()
        .keys
        .is_empty());
    assert_eq!(
        Runtime::get(&boot.app_context)
            .tenants
            .registry()
            .stats()
            .await
            .leased_pools,
        0
    );
    server.abort();
    let _ = server.await;
    TestApp::on_shutdown(&boot.app_context).await;
}

#[tokio::test]
async fn existing_nonincremental_tenant_requires_offline_migration_without_rewrite() {
    use sea_orm::{ConnectionTrait, Database};
    let env = Env::new("existing-vacuum-mode").await;
    let db = Database::connect(format!(
        "sqlite://{}?mode=rwc",
        env.dir.join("existing.sqlite").display()
    ))
    .await
    .unwrap();
    db.execute_unprepared("CREATE TABLE evidence(value INTEGER); INSERT INTO evidence VALUES(42);")
        .await
        .unwrap();
    let error = postdeploy::error_retention::initialize_tenant(&db)
        .await
        .unwrap_err();
    assert!(error
        .to_string()
        .contains("offline incremental vacuum migration"));
    let row = db
        .query_one_raw(postdeploy::runtime::sql(
            "SELECT value FROM evidence",
            vec![],
        ))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(row.try_get_by_index::<i64>(0).unwrap(), 42);
    db.close().await.unwrap();
}
