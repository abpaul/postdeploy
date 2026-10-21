use std::{net::IpAddr, time::Duration};

use loco_rs::{Error, Result};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use tokio::sync::Semaphore;
use zeroize::Zeroizing;

use crate::credentials::TurnstileCredentials;

const VERIFY_URL: &str = "https://challenges.cloudflare.com/turnstile/v0/siteverify";
const RESPONSE_LIMIT: usize = 16 * 1024;

pub struct Turnstile {
    client: Client,
    site_key: String,
    secret_key: Zeroizing<String>,
    requests: Semaphore,
}

#[derive(Serialize)]
struct Verification<'a> {
    secret: &'a str,
    response: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    remoteip: Option<IpAddr>,
}

#[derive(Deserialize)]
struct Verified {
    success: bool,
}

impl Turnstile {
    pub fn new(credentials: &TurnstileCredentials) -> Result<Self> {
        let client = Client::builder()
            .connect_timeout(Duration::from_secs(1))
            .timeout(Duration::from_secs(3))
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|_| Error::string("Turnstile HTTP client could not be created"))?;
        Ok(Self {
            client,
            site_key: credentials.site_key.clone(),
            secret_key: Zeroizing::new(credentials.secret_key.expose_secret().to_owned()),
            requests: Semaphore::new(8),
        })
    }

    pub fn site_key(&self) -> &str {
        &self.site_key
    }

    pub async fn verify(&self, token: &str, peer: Option<IpAddr>) -> bool {
        self.verify_at(VERIFY_URL, token, peer).await
    }

    async fn verify_at(&self, url: &str, token: &str, peer: Option<IpAddr>) -> bool {
        if token.is_empty() || token.len() > 2048 {
            return false;
        }
        let Ok(_request) = self.requests.try_acquire() else {
            return false;
        };
        let Ok(mut response) = self
            .client
            .post(url)
            .form(&Verification {
                secret: &self.secret_key,
                response: token,
                remoteip: peer,
            })
            .send()
            .await
        else {
            return false;
        };
        if response.status() != reqwest::StatusCode::OK {
            return false;
        }
        let mut body = Vec::new();
        loop {
            match response.chunk().await {
                Ok(Some(chunk)) if body.len() + chunk.len() <= RESPONSE_LIMIT => {
                    body.extend_from_slice(&chunk)
                }
                Ok(None) => break,
                _ => return false,
            }
        }
        serde_json::from_slice::<Verified>(&body).is_ok_and(|result| result.success)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    fn verifier() -> Turnstile {
        let credentials: TurnstileCredentials = serde_json::from_value(serde_json::json!({
            "site_key": "fixture-site-key",
            "secret_key": "fixture-secret-key"
        }))
        .unwrap();
        Turnstile::new(&credentials).unwrap()
    }

    async fn reply(response: String) -> (String, tokio::task::JoinHandle<()>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut buffer = [0; 4096];
            assert!(stream.read(&mut buffer).await.unwrap() > 0);
            let _ = stream.write_all(response.as_bytes()).await;
        });
        (format!("http://{address}"), server)
    }

    #[tokio::test]
    async fn accepts_only_bounded_successful_verification_responses() {
        for (status, body, expected) in [
            (200, r#"{"success":true}"#.to_owned(), true),
            (200, r#"{"success":false}"#.to_owned(), false),
            (200, r#"{"success":"true"}"#.to_owned(), false),
            (200, "untrusted-response".to_owned(), false),
            (500, r#"{"success":true}"#.to_owned(), false),
            (302, r#"{"success":true}"#.to_owned(), false),
            (200, "x".repeat(RESPONSE_LIMIT + 1), false),
        ] {
            let response = format!(
                "HTTP/1.1 {status} Result\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            let (url, server) = reply(response).await;
            assert_eq!(
                verifier().verify_at(&url, "fixture-token", None).await,
                expected
            );
            server.await.unwrap();
        }
    }

    #[tokio::test]
    async fn rejects_missing_oversized_and_over_capacity_requests_without_network() {
        let verifier = verifier();
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        assert!(!verifier.verify_at(&url, "", None).await);
        assert!(!verifier.verify_at(&url, &"x".repeat(2049), None).await);
        let _permits = verifier.requests.try_acquire_many(8).unwrap();
        assert!(!verifier.verify_at(&url, "fixture-token", None).await);
        assert!(
            tokio::time::timeout(Duration::from_millis(50), listener.accept())
                .await
                .is_err()
        );
    }

    #[tokio::test]
    async fn unreachable_or_stalled_verification_fails_closed() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let server = tokio::spawn(async move {
            let (_stream, _) = listener.accept().await.unwrap();
            tokio::time::sleep(Duration::from_secs(10)).await;
        });
        assert_eq!(
            tokio::time::timeout(
                Duration::from_millis(3500),
                verifier().verify_at(&url, "fixture-token", None)
            )
            .await,
            Ok(false)
        );
        server.abort();
        assert!(
            !verifier()
                .verify_at("http://127.0.0.1:1", "fixture-token", None)
                .await
        );
    }
}
