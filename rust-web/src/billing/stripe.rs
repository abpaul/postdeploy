use std::time::Duration;

use hmac::{Hmac, Mac};
use reqwest::{Client, Method, StatusCode};
use serde::{de::DeserializeOwned, Deserialize};
use sha2::Sha256;
use zeroize::Zeroizing;

use crate::credentials::StripeCredentials;

pub const API_VERSION: &str = "2026-09-30.endive";
pub const DEFAULT_API_BASE: &str = "https://api.stripe.com";
pub const SIGNATURE_TOLERANCE_SECS: i64 = 300;
const RESPONSE_LIMIT: usize = 1 << 20;
const INVOICE_PAGES: usize = 10;

#[derive(Debug, thiserror::Error)]
pub enum StripeError {
    #[error("Stripe request failed")]
    Unavailable,
    #[error("Stripe rejected the request with status {0}")]
    Rejected(u16),
    #[error("Stripe response was not understood")]
    Malformed,
}

pub struct Stripe {
    client: Client,
    base: String,
    secret_key: Zeroizing<String>,
    webhook_secret: Zeroizing<String>,
    pub price_id: String,
    pub live: bool,
}

#[derive(Debug, Deserialize)]
pub struct Recurring {
    pub interval: String,
    pub interval_count: u32,
}

#[derive(Debug, Deserialize)]
pub struct Price {
    pub id: String,
    pub active: bool,
    pub currency: String,
    pub unit_amount: Option<i64>,
    pub recurring: Option<Recurring>,
}

#[derive(Debug, Deserialize)]
pub struct CheckoutSession {
    pub id: String,
    pub url: Option<String>,
    pub status: Option<String>,
    pub mode: String,
    pub client_reference_id: Option<String>,
    pub customer: Option<String>,
    pub subscription: Option<String>,
    pub expires_at: i64,
}

#[derive(Debug, Deserialize)]
pub struct Subscription {
    pub id: String,
    pub customer: String,
    pub status: String,
    #[serde(default)]
    pub cancel_at_period_end: bool,
}

#[derive(Debug, Deserialize)]
pub struct List<T> {
    pub data: Vec<T>,
    pub has_more: bool,
}

#[derive(Debug, Deserialize)]
pub struct Period {
    pub start: i64,
    pub end: i64,
}

#[derive(Debug, Deserialize)]
pub struct PriceDetails {
    pub price: String,
}

#[derive(Debug, Deserialize)]
pub struct LinePricing {
    pub price_details: Option<PriceDetails>,
}

#[derive(Debug, Deserialize)]
pub struct InvoiceLine {
    pub amount: i64,
    pub currency: String,
    pub quantity: Option<u64>,
    pub period: Period,
    pub pricing: Option<LinePricing>,
}

#[derive(Debug, Deserialize)]
pub struct SubscriptionDetails {
    pub subscription: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct InvoiceParent {
    pub subscription_details: Option<SubscriptionDetails>,
}

#[derive(Debug, Deserialize)]
pub struct Invoice {
    pub id: String,
    pub customer: Option<String>,
    pub status: Option<String>,
    pub currency: String,
    pub total: i64,
    pub amount_remaining: i64,
    #[serde(default)]
    pub post_payment_credit_notes_amount: i64,
    pub parent: Option<InvoiceParent>,
    pub lines: List<InvoiceLine>,
}

impl Invoice {
    pub fn subscription(&self) -> Option<&str> {
        self.parent
            .as_ref()?
            .subscription_details
            .as_ref()?
            .subscription
            .as_deref()
    }
}

pub struct PaidInvoices {
    pub invoices: Vec<Invoice>,
    pub complete: bool,
}

#[derive(Debug, Deserialize)]
struct PortalSession {
    url: String,
}

/// Parameters of one Checkout Session. Identical retries reuse `attempt` as
/// the idempotency key so Stripe returns the session it already created.
pub struct CheckoutRequest<'a> {
    pub attempt: &'a str,
    pub org: &'a str,
    pub customer: Option<&'a str>,
    pub success_url: &'a str,
    pub cancel_url: &'a str,
}

impl Stripe {
    pub fn new(
        credentials: &StripeCredentials,
        base: &str,
        timeout: Duration,
    ) -> Result<Self, String> {
        let client = Client::builder()
            .connect_timeout(Duration::from_secs(2).min(timeout))
            .timeout(timeout)
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|_| "Stripe HTTP client could not be created".to_owned())?;
        Ok(Self {
            client,
            base: base.trim_end_matches('/').to_owned(),
            secret_key: Zeroizing::new(credentials.secret_key.expose_secret().to_owned()),
            webhook_secret: Zeroizing::new(credentials.webhook_secret.expose_secret().to_owned()),
            price_id: credentials.price_id.clone(),
            live: credentials.is_live(),
        })
    }

    pub fn verify_webhook(&self, header: &str, body: &[u8], now: i64) -> bool {
        verify_signature(self.webhook_secret.as_bytes(), header, body, now)
    }

    pub async fn price(&self) -> Result<Price, StripeError> {
        let path = format!("/v1/prices/{}", segment(&self.price_id)?);
        self.request(Method::GET, &path, &[], None).await
    }

    pub async fn create_checkout(
        &self,
        request: &CheckoutRequest<'_>,
    ) -> Result<CheckoutSession, StripeError> {
        let mut form = vec![
            ("mode", "subscription".to_owned()),
            ("line_items[0][price]", self.price_id.clone()),
            ("line_items[0][quantity]", "1".to_owned()),
            ("client_reference_id", request.org.to_owned()),
            ("metadata[org_id]", request.org.to_owned()),
            (
                "subscription_data[metadata][org_id]",
                request.org.to_owned(),
            ),
            ("success_url", request.success_url.to_owned()),
            ("cancel_url", request.cancel_url.to_owned()),
        ];
        if let Some(customer) = request.customer {
            form.push(("customer", customer.to_owned()));
        }
        self.request(
            Method::POST,
            "/v1/checkout/sessions",
            &form,
            Some(&format!("checkout-{}", request.attempt)),
        )
        .await
    }

    pub async fn checkout(&self, id: &str) -> Result<CheckoutSession, StripeError> {
        let path = format!("/v1/checkout/sessions/{}", segment(id)?);
        self.request(Method::GET, &path, &[], None).await
    }

    pub async fn portal(&self, customer: &str, return_url: &str) -> Result<String, StripeError> {
        let form = [
            ("customer", customer.to_owned()),
            ("return_url", return_url.to_owned()),
        ];
        let session: PortalSession = self
            .request(Method::POST, "/v1/billing_portal/sessions", &form, None)
            .await?;
        Ok(session.url)
    }

    pub async fn subscription(&self, id: &str) -> Result<Subscription, StripeError> {
        let path = format!("/v1/subscriptions/{}", segment(id)?);
        self.request(Method::GET, &path, &[], None).await
    }

    pub async fn invoice(&self, id: &str) -> Result<Invoice, StripeError> {
        let path = format!("/v1/invoices/{}", segment(id)?);
        self.request(Method::GET, &path, &[], None).await
    }

    /// Paid invoices of one subscription, newest first, up to
    /// `INVOICE_PAGES` pages. `complete` is false when Stripe has more.
    pub async fn paid_invoices(&self, subscription: &str) -> Result<PaidInvoices, StripeError> {
        let subscription = segment(subscription)?;
        let mut invoices: Vec<Invoice> = Vec::new();
        for _ in 0..INVOICE_PAGES {
            let mut path =
                format!("/v1/invoices?subscription={subscription}&status=paid&limit=100");
            if let Some(last) = invoices.last() {
                path.push_str(&format!("&starting_after={}", segment(&last.id)?));
            }
            let page: List<Invoice> = self.request(Method::GET, &path, &[], None).await?;
            let more = page.has_more && !page.data.is_empty();
            invoices.extend(page.data);
            if !more {
                return Ok(PaidInvoices {
                    invoices,
                    complete: true,
                });
            }
        }
        Ok(PaidInvoices {
            invoices,
            complete: false,
        })
    }

    async fn request<T: DeserializeOwned>(
        &self,
        method: Method,
        path: &str,
        form: &[(&str, String)],
        idempotency_key: Option<&str>,
    ) -> Result<T, StripeError> {
        let mut request = self
            .client
            .request(method.clone(), format!("{}{path}", self.base))
            .bearer_auth(self.secret_key.as_str())
            .header("Stripe-Version", API_VERSION);
        if method == Method::POST {
            request = request.form(form);
        }
        if let Some(key) = idempotency_key {
            request = request.header("Idempotency-Key", key);
        }
        let mut response = request.send().await.map_err(|_| StripeError::Unavailable)?;
        let status = response.status();
        let mut body = Vec::new();
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|_| StripeError::Unavailable)?
        {
            if body.len() + chunk.len() > RESPONSE_LIMIT {
                return Err(StripeError::Malformed);
            }
            body.extend_from_slice(&chunk);
        }
        if status.is_server_error() || status == StatusCode::TOO_MANY_REQUESTS {
            return Err(StripeError::Unavailable);
        }
        if !status.is_success() {
            return Err(StripeError::Rejected(status.as_u16()));
        }
        serde_json::from_slice(&body).map_err(|_| StripeError::Malformed)
    }
}

fn segment(id: &str) -> Result<&str, StripeError> {
    let valid = !id.is_empty()
        && id.len() <= 255
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_');
    valid.then_some(id).ok_or(StripeError::Malformed)
}

/// Verifies a `Stripe-Signature` header: `t=<unix>,v1=<hex>[,v1=<hex>...]`.
/// The signed payload is `"<t>." + raw body`, signed with HMAC-SHA256 under the
/// endpoint secret. The timestamp must be within the tolerance of `now`.
pub fn verify_signature(secret: &[u8], header: &str, body: &[u8], now: i64) -> bool {
    let mut timestamp = None;
    let mut signatures = Vec::new();
    for part in header.split(',') {
        match part.trim().split_once('=') {
            Some(("t", value)) => timestamp = value.parse::<i64>().ok(),
            Some(("v1", value)) => {
                if let Ok(bytes) = hex::decode(value) {
                    signatures.push(bytes);
                }
            }
            _ => {}
        }
    }
    let Some(timestamp) = timestamp else {
        return false;
    };
    if (now - timestamp).abs() > SIGNATURE_TOLERANCE_SECS || signatures.is_empty() {
        return false;
    }
    signatures.iter().any(|signature| {
        let Ok(mut mac) = Hmac::<Sha256>::new_from_slice(secret) else {
            return false;
        };
        mac.update(timestamp.to_string().as_bytes());
        mac.update(b".");
        mac.update(body);
        mac.verify_slice(signature).is_ok()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sign(secret: &str, t: i64, body: &str) -> String {
        let mut mac = Hmac::<Sha256>::new_from_slice(secret.as_bytes()).unwrap();
        mac.update(format!("{t}.{body}").as_bytes());
        hex::encode(mac.finalize().into_bytes())
    }

    #[test]
    fn signature_accepts_exact_body_within_tolerance_only() {
        let secret = "whsec_unit";
        let body = r#"{"id":"evt_1"}"#;
        let t = 1_800_000_000;
        let header = format!("t={t},v1={}", sign(secret, t, body));
        assert!(verify_signature(
            secret.as_bytes(),
            &header,
            body.as_bytes(),
            t + 300
        ));
        assert!(verify_signature(
            secret.as_bytes(),
            &header,
            body.as_bytes(),
            t - 300
        ));
        assert!(!verify_signature(
            secret.as_bytes(),
            &header,
            body.as_bytes(),
            t + 301
        ));
        assert!(!verify_signature(
            secret.as_bytes(),
            &header,
            br#"{"id":"evt_2"}"#,
            t
        ));
        assert!(!verify_signature(
            b"whsec_other",
            &header,
            body.as_bytes(),
            t
        ));
        let rotated = format!("t={t},v1=00ff,v1={},v0=abc", sign(secret, t, body));
        assert!(verify_signature(
            secret.as_bytes(),
            &rotated,
            body.as_bytes(),
            t
        ));
        assert!(!verify_signature(
            secret.as_bytes(),
            &format!("v1={}", sign(secret, t, body)),
            body.as_bytes(),
            t
        ));
    }

    #[test]
    fn object_ids_outside_the_token_alphabet_never_form_a_path() {
        assert_eq!(segment("sub_1Abc").unwrap(), "sub_1Abc");
        assert!(segment("sub_1/../prices").is_err());
        assert!(segment("sub_1?x=1").is_err());
        assert!(segment("").is_err());
    }
}
