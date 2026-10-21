use std::{
    io::{Read, Write},
    net::{SocketAddr, TcpStream},
    process::ExitCode,
    time::Duration,
};

use loco_rs::cli;
use migration::ControlMigrator;
use postdeploy::app::App;

const HEALTHCHECK_ADDR: &str = "127.0.0.1:80";
const HEALTHCHECK_TIMEOUT: Duration = Duration::from_secs(2);
const HEALTHCHECK_MAX_RESPONSE: u64 = 64 * 1024;

fn main() -> loco_rs::Result<ExitCode> {
    let mut args = std::env::args().skip(1);
    if args.next().as_deref() == Some("healthcheck") {
        return Ok(healthcheck(
            args.next().as_deref().unwrap_or(HEALTHCHECK_ADDR),
        ));
    }
    #[cfg(target_os = "linux")]
    disable_core_dumps()?;
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .map_err(|_| loco_rs::Error::string("could not start application runtime"))?;
    runtime.block_on(cli::main::<App, ControlMigrator>())?;
    Ok(ExitCode::SUCCESS)
}

/// Probes `/healthz` with plain std I/O. It must not boot Loco: a boot takes
/// the data locks and would hang or fail exactly when the server is wedged.
fn healthcheck(addr: &str) -> ExitCode {
    match probe(addr) {
        Ok(()) => ExitCode::SUCCESS,
        Err(reason) => {
            eprintln!("healthcheck failed: {reason}");
            ExitCode::FAILURE
        }
    }
}

fn probe(addr: &str) -> Result<(), String> {
    let addr: SocketAddr = addr
        .parse()
        .map_err(|_| format!("{addr:?} is not an IP:port address"))?;
    let mut stream = TcpStream::connect_timeout(&addr, HEALTHCHECK_TIMEOUT)
        .map_err(|error| format!("connect {addr}: {error}"))?;
    stream
        .set_read_timeout(Some(HEALTHCHECK_TIMEOUT))
        .and_then(|()| stream.set_write_timeout(Some(HEALTHCHECK_TIMEOUT)))
        .and_then(|()| {
            stream
                .write_all(b"GET /healthz HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        })
        .map_err(|error| format!("send request: {error}"))?;
    let mut response = Vec::new();
    stream
        .take(HEALTHCHECK_MAX_RESPONSE)
        .read_to_end(&mut response)
        .map_err(|error| format!("read response: {error}"))?;
    let response = String::from_utf8_lossy(&response);
    let (head, body) = response
        .split_once("\r\n\r\n")
        .ok_or("response has no header terminator")?;
    let status = head.lines().next().unwrap_or_default();
    if status.split(' ').nth(1) != Some("200") {
        return Err(format!("status line {status:?}"));
    }
    let body: serde_json::Value =
        serde_json::from_str(body).map_err(|_| "body is not JSON".to_owned())?;
    if body["status"] != "ok" {
        return Err(format!("status field {}", body["status"]));
    }
    Ok(())
}

#[cfg(target_os = "linux")]
fn disable_core_dumps() -> loco_rs::Result<()> {
    use rustix::process::{dumpable_behavior, set_dumpable_behavior, DumpableBehavior};

    set_dumpable_behavior(DumpableBehavior::NotDumpable)
        .map_err(|_| loco_rs::Error::string("could not disable process core dumps"))?;
    let actual = dumpable_behavior()
        .map_err(|_| loco_rs::Error::string("could not verify process core dump protection"))?;
    if actual != DumpableBehavior::NotDumpable {
        return Err(loco_rs::Error::string("process core dumps remain enabled"));
    }
    Ok(())
}
