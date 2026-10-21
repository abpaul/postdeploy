use std::{
    io::{Read, Write},
    net::TcpListener,
    process::Command,
    thread,
};

use loco_rs::app::Hooks;
use postdeploy::testing::{serve, TestApp, TestEnv};

fn healthcheck(addr: &str) -> Option<i32> {
    Command::new(env!("CARGO_BIN_EXE_postdeploy-cli"))
        .args(["healthcheck", addr])
        .output()
        .expect("run the healthcheck binary")
        .status
        .code()
}

fn serve_once(response: &'static str) -> (String, thread::JoinHandle<String>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let addr = listener.local_addr().expect("local addr").to_string();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accept");
        let mut request = [0u8; 1024];
        let read = stream.read(&mut request).expect("read request");
        stream
            .write_all(response.as_bytes())
            .expect("write response");
        String::from_utf8_lossy(&request[..read]).into_owned()
    });
    (addr, server)
}

#[test]
fn healthcheck_exits_zero_only_for_200_with_status_ok() {
    let cases = [
        (
            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n\r\n{\"status\":\"ok\",\"backups\":{}}",
            Some(0),
        ),
        (
            "HTTP/1.1 503 Service Unavailable\r\n\r\n{\"status\":\"draining\"}",
            Some(1),
        ),
        ("HTTP/1.1 200 OK\r\n\r\n{\"status\":\"draining\"}", Some(1)),
        ("HTTP/1.1 200 OK\r\n\r\nok", Some(1)),
    ];
    for (response, expected) in cases {
        let (addr, server) = serve_once(response);
        assert_eq!(healthcheck(&addr), expected, "response {response:?}");
        let request = server.join().expect("server thread");
        assert!(
            request.starts_with("GET /healthz HTTP/1.0\r\n"),
            "request {request:?}"
        );
    }
}

#[test]
fn healthcheck_fails_when_nothing_listens() {
    let addr = TcpListener::bind("127.0.0.1:0")
        .expect("bind")
        .local_addr()
        .expect("local addr")
        .to_string();
    assert_eq!(healthcheck(&addr), Some(1));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn healthcheck_passes_against_the_server_and_fails_once_it_drains() {
    let env = TestEnv::new("healthcheck");
    let boot = env.boot_memory(|_| {}).await.unwrap();
    let (base, _server) = serve(&boot).await;
    let addr = base.trim_start_matches("http://").to_owned();

    let probe = addr.clone();
    let healthy = tokio::task::spawn_blocking(move || healthcheck(&probe))
        .await
        .unwrap();
    assert_eq!(healthy, Some(0), "a running server is healthy");

    TestApp::on_shutdown(&boot.app_context).await;
    let drained = tokio::task::spawn_blocking(move || healthcheck(&addr))
        .await
        .unwrap();
    assert_eq!(drained, Some(1), "a draining server is unhealthy");
}
