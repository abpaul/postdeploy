use std::{path::PathBuf, time::Duration};

use bytes::Bytes;
use postdeploy::{
    credentials::Credentials,
    store::{Created, ObjectStore, StoreError},
};

/// Exercises the production object store against the isolated R2 test bucket.
#[tokio::test]
#[ignore = "uses real R2: needs CREDSEAL_KEY_FILE and POSTDEPLOY_CREDENTIALS_FILE"]
async fn r2_store_bounds_reads_and_pages_listings() {
    let path = PathBuf::from(std::env::var("POSTDEPLOY_CREDENTIALS_FILE").unwrap());
    let credentials = Credentials::load(&path, "test").unwrap();
    let run = chrono::Utc::now().format("%Y%m%dt%H%M%S").to_string();
    let prefix = format!("local-verification/store-{run}/");
    let store = ObjectStore::r2(&credentials.r2, &prefix, Duration::from_secs(30)).unwrap();

    store
        .put("probe/big", Bytes::from(vec![7u8; 64 * 1024]))
        .await
        .unwrap();
    let refused = store.get("probe/big", 64 * 1024 - 1).await;
    assert!(
        matches!(refused, Err(StoreError::TooLarge(_))),
        "{refused:?}"
    );
    assert_eq!(
        store
            .get("probe/big", 64 * 1024)
            .await
            .unwrap()
            .unwrap()
            .len(),
        64 * 1024
    );
    assert!(store.get("probe/missing", 10).await.unwrap().is_none());

    for i in 0..5 {
        store
            .put(&format!("probe/list/{i}"), Bytes::from_static(b"x"))
            .await
            .unwrap();
    }
    let mut seen = Vec::new();
    let mut after: Option<String> = None;
    loop {
        let page = store
            .list_page("probe/list/", after.as_deref(), 2)
            .await
            .unwrap();
        seen.extend(page.keys);
        match page.next {
            Some(next) => after = Some(next),
            None => break,
        }
    }
    assert_eq!(
        seen,
        (0..5)
            .map(|i| format!("probe/list/{i}"))
            .collect::<Vec<_>>()
    );
    for key in seen.iter().chain(["probe/big".to_owned()].iter()) {
        store.delete(key).await.unwrap();
    }
    assert!(store
        .list_page("probe/", None, 10)
        .await
        .unwrap()
        .keys
        .is_empty());
    println!("r2 store probe prefix={prefix} ok");
}

/// Proves the OpenDAL S3 mapping of a competing conditional write against
/// actual R2: the second body is refused and the first body stays readable.
#[tokio::test]
#[ignore = "uses real R2: needs CREDSEAL_KEY_FILE and POSTDEPLOY_CREDENTIALS_FILE"]
async fn r2_conditional_create_refuses_a_second_body_at_the_same_key() {
    let path = PathBuf::from(std::env::var("POSTDEPLOY_CREDENTIALS_FILE").unwrap());
    let credentials = Credentials::load(&path, "test").unwrap();
    assert_eq!(credentials.r2.bucket, "postdeploy-rust-local-test-20261015");
    let prefix = format!(
        "local-verification/conditional-{}/",
        uuid::Uuid::now_v7().simple()
    );
    let store = ObjectStore::r2(&credentials.r2, &prefix, Duration::from_secs(30)).unwrap();
    let key = "logs/v1/o00000000000000000000000000000000/v2/2026101600/probe.ndjson.zst";
    let first = store
        .put_if_absent(key, Bytes::from_static(b"body-a"))
        .await
        .unwrap();
    let second = store
        .put_if_absent(key, Bytes::from_static(b"body-b"))
        .await
        .unwrap();
    let stored = store.get(key, 64).await.unwrap().unwrap();
    store.delete(key).await.unwrap();
    let remaining = store.list_page("", None, 10).await.unwrap().keys;
    println!(
        "r2 conditional prefix={prefix} first={first:?} second={second:?} stored={} remaining={}",
        String::from_utf8_lossy(&stored),
        remaining.len()
    );
    assert_eq!(first, Created::New);
    assert_eq!(second, Created::Exists);
    assert_eq!(stored, Bytes::from_static(b"body-a"));
    assert!(remaining.is_empty(), "owned probe object cleaned up");
}
