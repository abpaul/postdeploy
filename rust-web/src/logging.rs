use loco_rs::{app::AppContext, Result};
use tracing_subscriber::EnvFilter;

fn filter() -> EnvFilter {
    EnvFilter::new("off,postdeploy=info,loco_rs=info,sea_orm_migration=warn")
}

pub fn install(ctx: &AppContext) -> Result<bool> {
    if ctx.config.logger.enable {
        tracing_subscriber::fmt()
            .with_env_filter(filter())
            .with_ansi(false)
            .with_target(true)
            .compact()
            .try_init()
            .map_err(|_| loco_rs::Error::string("operational logger could not be installed"))?;
    }
    Ok(true)
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};

    #[derive(Clone, Default)]
    struct Output(Arc<Mutex<Vec<u8>>>);

    impl std::io::Write for Output {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(bytes);
            Ok(bytes.len())
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn dependency_responses_and_debug_payloads_never_reach_operational_output() {
        let output = Output::default();
        let writer = output.clone();
        let subscriber = tracing_subscriber::fmt()
            .with_env_filter(super::filter())
            .with_ansi(false)
            .with_writer(move || writer.clone())
            .finish();
        tracing::subscriber::with_default(subscriber, || {
            tracing::trace!(target: "rmcp::transport", body = "isolated-payload-marker", "response");
            tracing::error!(target: "opendal::http", body = "isolated-payload-marker", "response");
            tracing::debug!(target: "postdeploy::ingest", body = "isolated-payload-marker", "payload");
            tracing::info!(target: "postdeploy::app", status = 200, "request-complete");
        });
        let bytes = output.0.lock().unwrap();
        let text = String::from_utf8_lossy(&bytes);
        assert!(text.contains("request-complete"));
        assert!(!text.contains("isolated-payload-marker"));
    }
}
