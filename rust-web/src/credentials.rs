use std::{fs::File, io::Read, path::Path};

use base64::Engine as _;
use credseal::{Context, CredentialsFile, MasterKey, SecretString};
use loco_rs::{Error, Result};
use serde::Deserialize;
use zeroize::Zeroizing;

pub const APPLICATION: &str = "postdeploy";

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Credentials {
    pub r2: R2Credentials,
    pub security: Security,
    pub smtp: Option<crate::notifications::SmtpConfig>,
    pub turnstile: Option<TurnstileCredentials>,
    pub stripe: Option<StripeCredentials>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StripeCredentials {
    pub secret_key: SecretString,
    pub webhook_secret: SecretString,
    /// The single annual plan price. Billing checks it against Stripe before use.
    pub price_id: String,
}

impl StripeCredentials {
    pub fn is_live(&self) -> bool {
        let key = self.secret_key.expose_secret();
        key.starts_with("sk_live_") || key.starts_with("rk_live_")
    }

    fn validate(&self) -> Result<()> {
        let key = self.secret_key.expose_secret();
        let valid = (key.starts_with("sk_") || key.starts_with("rk_"))
            && key.len() > 12
            && self.webhook_secret.expose_secret().starts_with("whsec_")
            && self.webhook_secret.expose_secret().len() > 12
            && self.price_id.starts_with("price_")
            && self.price_id.len() <= 255
            && self.price_id[6..]
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'_')
            && self.price_id.len() > 6;
        if valid {
            Ok(())
        } else {
            Err(Error::string(
                "credentials.stripe requires a secret key, a webhook signing secret and a price ID",
            ))
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TurnstileCredentials {
    pub site_key: String,
    pub secret_key: SecretString,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct R2Credentials {
    pub endpoint: String,
    pub bucket: String,
    pub access_key_id: SecretString,
    pub secret_access_key: SecretString,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Security {
    /// Base64 of a 32-byte AES-256 key for encrypted backups.
    pub data_key: SecretString,
}

impl Credentials {
    pub fn load(path: &Path, environment: &str) -> Result<Self> {
        let context = Context::new(APPLICATION, environment)
            .map_err(|error| Error::string(&format!("credential context: {error}")))?;
        let key = master_key(environment)?;
        let credentials: Self = CredentialsFile::new(path, context)
            .load(&key)
            .map_err(|error| Error::string(&format!("credentials for {environment}: {error}")))?;
        credentials.check(environment)?;
        Ok(credentials)
    }

    fn check(&self, environment: &str) -> Result<()> {
        self.validate()?;
        if environment != "production" {
            return Ok(());
        }
        if self.stripe.as_ref().is_some_and(|stripe| !stripe.is_live()) {
            return Err(Error::string(
                "production credentials require a live-mode Stripe key",
            ));
        }
        let turnstile = self
            .turnstile
            .as_ref()
            .ok_or_else(|| Error::string("production credentials require Cloudflare Turnstile"))?;
        if [
            turnstile.site_key.as_str(),
            turnstile.secret_key.expose_secret(),
        ]
        .into_iter()
        .any(is_turnstile_testing_key)
        {
            return Err(Error::string(
                "production credentials require live Cloudflare Turnstile keys",
            ));
        }
        let mail = self.smtp.as_ref().is_some_and(|smtp| {
            !smtp.host.trim().is_empty()
                && !smtp.username.is_empty()
                && !smtp.password.expose_secret().is_empty()
                && smtp.from.parse::<lettre::message::Mailbox>().is_ok()
        });
        if !mail {
            return Err(Error::string("production credentials require SMTP"));
        }
        Ok(())
    }

    fn validate(&self) -> Result<()> {
        if let Some(stripe) = &self.stripe {
            stripe.validate()?;
        }
        if self.turnstile.as_ref().is_some_and(|credentials| {
            credentials.site_key.trim().is_empty()
                || credentials.secret_key.expose_secret().trim().is_empty()
        }) {
            return Err(Error::string(
                "credentials.turnstile requires a site key and secret key",
            ));
        }
        if !is_r2_endpoint(&self.r2.endpoint) || self.r2.bucket.trim().is_empty() {
            return Err(Error::string(
                "credentials.r2 requires a Cloudflare R2 endpoint (https://<account>.r2.cloudflarestorage.com) and a bucket",
            ));
        }
        if self.r2.access_key_id.expose_secret().is_empty()
            || self.r2.secret_access_key.expose_secret().is_empty()
        {
            return Err(Error::string("credentials.r2 requires an access key pair"));
        }
        let key = base64::engine::general_purpose::STANDARD
            .decode(self.security.data_key.expose_secret())
            .map_err(|_| Error::string("credentials.security.data_key must be Base64"))?;
        if key.len() != 32 {
            return Err(Error::string(
                "credentials.security.data_key must decode to 32 bytes",
            ));
        }
        Ok(())
    }
}

fn master_key(environment: &str) -> Result<MasterKey> {
    let file = std::env::var_os("CREDSEAL_KEY_FILE");
    if environment == "production" {
        if std::env::var_os("CREDSEAL_MASTER_KEY").is_some() {
            return Err(Error::string("production refuses CREDSEAL_MASTER_KEY"));
        }
        if file.is_none() {
            return Err(Error::string("production requires CREDSEAL_KEY_FILE"));
        }
    }
    match file {
        Some(path) => key_from_file(Path::new(&path)),
        None => MasterKey::from_env().map_err(|_| Error::string("credential key is invalid")),
    }
}

fn key_from_file(path: &Path) -> Result<MasterKey> {
    let invalid = || Error::string("credential key file is invalid");
    let expected = std::fs::symlink_metadata(path).map_err(|_| invalid())?;
    if !expected.is_file() || expected.len() > 128 {
        return Err(invalid());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if !matches!(expected.permissions().mode() & 0o7777, 0o400 | 0o600) {
            return Err(invalid());
        }
    }
    let file = File::open(path).map_err(|_| invalid())?;
    let actual = file.metadata().map_err(|_| invalid())?;
    if !actual.is_file() || actual.len() > 128 {
        return Err(invalid());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        if expected.dev() != actual.dev()
            || expected.ino() != actual.ino()
            || !matches!(actual.permissions().mode() & 0o7777, 0o400 | 0o600)
        {
            return Err(invalid());
        }
    }
    let mut encoded = Zeroizing::new(String::with_capacity(actual.len() as usize + 1));
    file.take(129)
        .read_to_string(&mut encoded)
        .map_err(|_| invalid())?;
    if encoded.len() > 128 {
        return Err(invalid());
    }
    MasterKey::from_base64(&encoded).map_err(|_| invalid())
}

fn is_turnstile_testing_key(key: &str) -> bool {
    matches!(key.as_bytes().first(), Some(b'1' | b'2' | b'3'))
        && key.get(1..2) == Some("x")
        && key.len() >= 12
        && key
            .get(2..key.len() - 2)
            .is_some_and(|part| part.bytes().all(|byte| byte == b'0'))
        && key.as_bytes()[key.len() - 2..]
            .iter()
            .all(u8::is_ascii_uppercase)
}

/// `https://<32 hex account id>[.<jurisdiction>].r2.cloudflarestorage.com`
pub fn is_r2_endpoint(endpoint: &str) -> bool {
    let Some(host) = endpoint.strip_prefix("https://") else {
        return false;
    };
    let host = host.strip_suffix('/').unwrap_or(host);
    let Some(rest) = host.strip_suffix(".r2.cloudflarestorage.com") else {
        return false;
    };
    let (account, jurisdiction) = rest
        .split_once('.')
        .map_or((rest, None), |(a, j)| (a, Some(j)));
    account.len() == 32
        && account.bytes().all(|b| b.is_ascii_hexdigit())
        && jurisdiction.is_none_or(|j| matches!(j, "eu" | "fedramp"))
}

#[cfg(test)]
mod tests {
    use serde_json::{json, Value};

    fn production(smtp: Option<Value>) -> super::Credentials {
        let mut credentials = json!({
            "r2": {
                "endpoint": "https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com",
                "bucket": "postdeploy",
                "access_key_id": "fixture-access-key",
                "secret_access_key": "fixture-secret-key"
            },
            "security": {"data_key": "BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc="},
            "turnstile": {"site_key": "0x4AAAAAAAfixture", "secret_key": "0x4AAAAAAAfixture-secret"},
            "stripe": {
                "secret_key": "sk_live_fixturefixture",
                "webhook_secret": "whsec_fixturefixture",
                "price_id": "price_fixture"
            }
        });
        if let Some(smtp) = smtp {
            credentials["smtp"] = smtp;
        }
        serde_json::from_value(credentials).unwrap()
    }

    fn smtp(change: impl FnOnce(&mut Value)) -> Option<Value> {
        let mut smtp = json!({
            "host": "smtp.mx.cloudflare.net",
            "port": 465,
            "tls": "implicit",
            "username": "api_token",
            "password": "fixture-api-token",
            "from": "PostDeploy <alerts@postdeploy.test>"
        });
        change(&mut smtp);
        Some(smtp)
    }

    #[test]
    fn production_credentials_require_a_valid_smtp_configuration() {
        let refused = |credentials: super::Credentials| {
            credentials
                .check("production")
                .map_err(|error| error.to_string())
        };
        let required = Err("production credentials require SMTP".to_owned());
        assert_eq!(refused(production(None)), required);
        assert_eq!(
            refused(production(smtp(|s| s["from"] = json!("not a mailbox")))),
            required
        );
        assert_eq!(
            refused(production(smtp(|s| s["host"] = json!(" ")))),
            required
        );
        assert_eq!(
            refused(production(smtp(|s| s["username"] = json!("")))),
            required
        );
        assert_eq!(
            refused(production(smtp(|s| s["password"] = json!("")))),
            required
        );
        assert_eq!(refused(production(smtp(|_| {}))), Ok(()));
        assert!(production(None).check("test").is_ok());
    }

    #[test]
    fn accepts_only_cloudflare_r2_endpoints() {
        let account = "0123456789abcdef0123456789abcdef";
        assert!(super::is_r2_endpoint(&format!(
            "https://{account}.r2.cloudflarestorage.com"
        )));
        assert!(super::is_r2_endpoint(&format!(
            "https://{account}.eu.r2.cloudflarestorage.com/"
        )));
        assert!(!super::is_r2_endpoint(&format!(
            "http://{account}.r2.cloudflarestorage.com"
        )));
        assert!(!super::is_r2_endpoint("https://s3.amazonaws.com"));
        assert!(!super::is_r2_endpoint(&format!(
            "https://{account}.r2.cloudflarestorage.com.evil.test"
        )));
    }
}

#[cfg(all(test, unix))]
mod key_file_tests {
    use std::{
        fs::{self, OpenOptions},
        io::Write,
        os::unix::fs::{symlink, OpenOptionsExt, PermissionsExt},
        path::{Path, PathBuf},
        process::Command,
    };

    use base64::Engine as _;

    struct Fixture {
        root: PathBuf,
        key: String,
    }

    impl Fixture {
        fn new() -> Self {
            let root = Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../.audit/postdeploy-rust/key-file-tests")
                .join(uuid::Uuid::now_v7().simple().to_string());
            fs::create_dir_all(&root).unwrap();
            fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
            Self {
                root,
                key: base64::engine::general_purpose::STANDARD.encode([23u8; 32]),
            }
        }

        fn file(&self, name: &str, bytes: &[u8], mode: u32) -> PathBuf {
            let path = self.root.join(name);
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(mode)
                .open(&path)
                .unwrap();
            file.write_all(bytes).unwrap();
            fs::set_permissions(&path, fs::Permissions::from_mode(mode)).unwrap();
            path
        }

        fn run(
            &self,
            label: &str,
            environment: &str,
            path: Option<&Path>,
            env_key: Option<&str>,
            expected: &str,
        ) {
            let mut command = Command::new(std::env::current_exe().unwrap());
            command
                .args([
                    "--exact",
                    "credentials::key_file_tests::key_source_child",
                    "--ignored",
                    "--nocapture",
                ])
                .env_remove("CREDSEAL_MASTER_KEY")
                .env_remove("CREDSEAL_KEY_FILE")
                .env("POSTDEPLOY_KEY_CHILD", environment)
                .env("POSTDEPLOY_KEY_EXPECT", expected);
            if let Some(path) = path {
                command.env("CREDSEAL_KEY_FILE", path);
            }
            if let Some(key) = env_key {
                command.env("CREDSEAL_MASTER_KEY", key);
            }
            let output = command.output().unwrap();
            let log = self.root.join(format!("{label}.log"));
            fs::write(&log, [output.stdout, output.stderr].concat()).unwrap();
            assert!(
                output.status.success(),
                "key-source child failed; evidence {}",
                log.display()
            );
        }
    }

    #[test]
    #[ignore = "isolated child of credential key-file tests"]
    fn key_source_child() {
        let Ok(environment) = std::env::var("POSTDEPLOY_KEY_CHILD") else {
            return;
        };
        let expected = std::env::var("POSTDEPLOY_KEY_EXPECT").unwrap();
        let result = super::master_key(&environment);
        if let Some(error) = expected.strip_prefix("error:") {
            assert_eq!(result.expect_err("key source must fail").to_string(), error);
        } else {
            assert_eq!(result.unwrap().to_base64().as_str(), expected);
        }
    }

    #[test]
    fn production_reads_only_private_bounded_key_files() {
        let fixture = Fixture::new();
        for mode in [0o400, 0o600] {
            let padded = format!("{}{}", fixture.key, " ".repeat(128 - fixture.key.len()));
            let path = fixture.file(&format!("private-{mode:o}"), padded.as_bytes(), mode);
            fixture.run(
                &format!("private-{mode:o}"),
                "production",
                Some(&path),
                None,
                &fixture.key,
            );
        }
    }

    #[test]
    fn production_refuses_master_environment_even_when_empty_and_requires_a_file() {
        let fixture = Fixture::new();
        let path = fixture.file("private", fixture.key.as_bytes(), 0o600);
        for (label, key) in [("empty", ""), ("present", fixture.key.as_str())] {
            fixture.run(
                label,
                "production",
                Some(&path),
                Some(key),
                "error:production refuses CREDSEAL_MASTER_KEY",
            );
        }
        fixture.run(
            "missing",
            "production",
            None,
            None,
            "error:production requires CREDSEAL_KEY_FILE",
        );
    }

    #[test]
    fn key_file_errors_are_fixed_and_reject_unsafe_or_malformed_inputs() {
        let fixture = Fixture::new();
        let invalid = "error:credential key file is invalid";
        for mode in [0o000, 0o200, 0o644, 0o700, 0o4600] {
            let path = fixture.file(&format!("mode-{mode:o}"), fixture.key.as_bytes(), mode);
            fixture.run(
                &format!("mode-{mode:o}"),
                "production",
                Some(&path),
                None,
                invalid,
            );
        }
        for (label, bytes) in [
            ("oversized", vec![b' '; 129]),
            ("malformed", b"sensitive-key-fixture-canary".to_vec()),
            ("utf8", vec![0xff; 44]),
        ] {
            let path = fixture.file(label, &bytes, 0o600);
            fixture.run(label, "production", Some(&path), None, invalid);
        }
        let path = fixture.file("target", fixture.key.as_bytes(), 0o600);
        let link = fixture.root.join("symlink");
        symlink(&path, &link).unwrap();
        fixture.run("symlink", "production", Some(&link), None, invalid);
        fixture.run(
            "directory",
            "production",
            Some(&fixture.root),
            None,
            invalid,
        );
        fixture.run(
            "absent",
            "production",
            Some(&fixture.root.join("sensitive-key-path-canary")),
            None,
            invalid,
        );
    }

    #[test]
    fn development_and_test_prefer_files_and_keep_the_environment_fallback() {
        let fixture = Fixture::new();
        let path = fixture.file("private", fixture.key.as_bytes(), 0o600);
        let other = base64::engine::general_purpose::STANDARD.encode([42u8; 32]);
        for environment in ["development", "test"] {
            fixture.run(
                &format!("{environment}-file"),
                environment,
                Some(&path),
                Some(&other),
                &fixture.key,
            );
            fixture.run(
                &format!("{environment}-env"),
                environment,
                None,
                Some(&other),
                &other,
            );
            fixture.run(
                &format!("{environment}-invalid-file"),
                environment,
                Some(&fixture.root.join("absent")),
                Some(&other),
                "error:credential key file is invalid",
            );
            fixture.run(
                &format!("{environment}-missing"),
                environment,
                None,
                None,
                "error:credential key is invalid",
            );
        }
    }
}
