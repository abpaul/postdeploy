use std::{sync::Arc, time::Duration};

use async_trait::async_trait;
use reqwest::Client;
use sha1::{Digest, Sha1};
use tokio::sync::Semaphore;
use unicode_segmentation::UnicodeSegmentation;
use zeroize::{Zeroize, Zeroizing};

use crate::error::{ApiError, ApiResult};

const RANGE_URL: &str = "https://api.pwnedpasswords.com/range/";
const RESPONSE_LIMIT: usize = 256 * 1024;
const WEAK_PASSWORDS: &[&str] = &[
    "password",
    "password123",
    "password1234",
    "12345678901",
    "123456789012",
    "qwertyuiop123",
    "qwertyuiop1234",
    "letmein12345",
    "admin12345678",
    "welcome12345",
    "iloveyou12345",
    "monkey1234567",
    "dragon12345678",
    "sunshine12345",
    "princess12345",
    "football12345",
    "baseball12345",
    "trustno112345",
    "changeme12345",
    "whatever12345",
    "superman12345",
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BreachUnavailable;

#[async_trait]
pub trait BreachChecker: Send + Sync {
    async fn pwned(&self, prefix: &str, suffix: &str) -> Result<bool, BreachUnavailable>;
}

pub struct PasswordPolicy {
    checker: Arc<dyn BreachChecker>,
}

impl PasswordPolicy {
    pub fn new() -> loco_rs::Result<Self> {
        Ok(Self::with_checker(Arc::new(Hibp::new()?)))
    }

    pub fn with_checker(checker: Arc<dyn BreachChecker>) -> Self {
        Self { checker }
    }

    pub async fn validate(&self, password: &str) -> ApiResult<()> {
        if password.chars().count() > 256 || password.graphemes(true).count() < 12 {
            return Err(ApiError::BadRequest("password_length"));
        }
        let weak = {
            let lowercase = Zeroizing::new(password.to_lowercase());
            WEAK_PASSWORDS.contains(&lowercase.as_str())
        };
        if weak {
            return Err(ApiError::BadRequest("password_common"));
        }
        let mut digest = Sha1::digest(password.as_bytes());
        let hash = Zeroizing::new(hex::encode_upper(digest));
        digest[..].zeroize();
        match self.checker.pwned(&hash[..5], &hash[5..]).await {
            Ok(false) => Ok(()),
            Ok(true) => Err(ApiError::BadRequest("password_breached")),
            Err(BreachUnavailable) => Err(ApiError::Unavailable("password_check_unavailable")),
        }
    }
}

struct Hibp {
    client: Client,
    requests: Semaphore,
}

impl Hibp {
    fn new() -> loco_rs::Result<Self> {
        let client = Client::builder()
            .connect_timeout(Duration::from_secs(1))
            .timeout(Duration::from_secs(3))
            .redirect(reqwest::redirect::Policy::none())
            .user_agent("PostDeploy/0.1")
            .build()
            .map_err(|_| {
                loco_rs::Error::string("password breach HTTP client could not be created")
            })?;
        Ok(Self {
            client,
            requests: Semaphore::new(8),
        })
    }
}

#[async_trait]
impl BreachChecker for Hibp {
    async fn pwned(&self, prefix: &str, suffix: &str) -> Result<bool, BreachUnavailable> {
        self.check_at(&format!("{RANGE_URL}{prefix}"), suffix).await
    }
}

impl Hibp {
    async fn check_at(&self, url: &str, suffix: &str) -> Result<bool, BreachUnavailable> {
        let _request = self.requests.try_acquire().map_err(|_| BreachUnavailable)?;
        let mut response = self
            .client
            .get(url)
            .header("Add-Padding", "true")
            .send()
            .await
            .map_err(|_| BreachUnavailable)?;
        if response.status() != reqwest::StatusCode::OK {
            return Err(BreachUnavailable);
        }
        let mut body = Zeroizing::new(Vec::new());
        loop {
            match response.chunk().await {
                Ok(Some(chunk)) if body.len() + chunk.len() <= RESPONSE_LIMIT => {
                    body.extend_from_slice(&chunk)
                }
                Ok(None) => break,
                _ => return Err(BreachUnavailable),
            }
        }
        let text = std::str::from_utf8(&body).map_err(|_| BreachUnavailable)?;
        let mut breached = false;
        let mut entries = 0;
        for line in text.lines().filter(|line| !line.is_empty()) {
            let (candidate, count) = line.split_once(':').ok_or(BreachUnavailable)?;
            if candidate.len() != 35 || !candidate.bytes().all(|byte| byte.is_ascii_hexdigit()) {
                return Err(BreachUnavailable);
            }
            let count = count.parse::<u64>().map_err(|_| BreachUnavailable)?;
            if candidate.eq_ignore_ascii_case(suffix) && count > 0 {
                breached = true;
            }
            entries += 1;
        }
        if entries == 0 {
            return Err(BreachUnavailable);
        }
        Ok(breached)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    const SUFFIX: &str = "00000000000000000000000000000000000";

    async fn reply(status: u16, body: &str) -> (String, tokio::task::JoinHandle<()>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/range/00000", listener.local_addr().unwrap());
        let response = format!(
            "HTTP/1.1 {status} Result\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut bytes = Zeroizing::new(Vec::new());
            loop {
                let mut chunk = [0; 1024];
                let len = stream.read(&mut chunk).await.unwrap();
                assert!(len > 0);
                bytes.extend_from_slice(&chunk[..len]);
                assert!(bytes.len() <= 4096);
                if bytes.windows(4).any(|part| part == b"\r\n\r\n") {
                    break;
                }
            }
            let request = std::str::from_utf8(&bytes).unwrap();
            assert!(request.starts_with("GET /range/00000 HTTP/1.1\r\n"));
            assert!(request.contains("add-padding: true\r\n"));
            assert!(request.contains("user-agent: PostDeploy/0.1\r\n"));
            assert!(!request.contains(SUFFIX));
            let _ = stream.write_all(response.as_bytes()).await;
        });
        (url, server)
    }

    #[tokio::test]
    async fn range_protocol_is_prefix_only_and_padded_and_rejects_bad_responses() {
        for (status, body, expected) in [
            (200, format!("{SUFFIX}:2\r\n"), Ok(true)),
            (200, format!("{SUFFIX}:0\r\n"), Ok(false)),
            (
                200,
                "11111111111111111111111111111111111:3\r\n".into(),
                Ok(false),
            ),
            (500, format!("{SUFFIX}:2\r\n"), Err(BreachUnavailable)),
            (302, format!("{SUFFIX}:2\r\n"), Err(BreachUnavailable)),
            (200, "".into(), Err(BreachUnavailable)),
            (
                200,
                "untrusted response body".into(),
                Err(BreachUnavailable),
            ),
            (200, format!("{SUFFIX}:invalid\r\n"), Err(BreachUnavailable)),
            (200, "x".repeat(RESPONSE_LIMIT + 1), Err(BreachUnavailable)),
        ] {
            let (url, server) = reply(status, &body).await;
            assert_eq!(Hibp::new().unwrap().check_at(&url, SUFFIX).await, expected);
            server.await.unwrap();
        }
    }

    #[tokio::test]
    async fn range_timeout_and_capacity_fail_closed() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/range/00000", listener.local_addr().unwrap());
        let hibp = Hibp::new().unwrap();
        let permits = hibp.requests.try_acquire_many(8).unwrap();
        assert_eq!(hibp.check_at(&url, SUFFIX).await, Err(BreachUnavailable));
        assert!(
            tokio::time::timeout(Duration::from_millis(50), listener.accept())
                .await
                .is_err()
        );
        drop(permits);
        let server = tokio::spawn(async move {
            let (_stream, _) = listener.accept().await.unwrap();
            tokio::time::sleep(Duration::from_secs(10)).await;
        });
        assert_eq!(
            tokio::time::timeout(Duration::from_millis(3500), hibp.check_at(&url, SUFFIX)).await,
            Ok(Err(BreachUnavailable))
        );
        server.abort();
    }

    #[tokio::test]
    #[ignore = "calls the official HIBP range API over HTTPS with its documented demonstration password"]
    async fn official_range_api_reports_the_documented_demonstration_password_as_breached() {
        let mut digest = Sha1::digest(b"password");
        let hash = Zeroizing::new(hex::encode_upper(digest));
        digest[..].zeroize();
        assert_eq!(
            Hibp::new().unwrap().pwned(&hash[..5], &hash[5..]).await,
            Ok(true)
        );
    }
}
