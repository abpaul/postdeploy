//! Removes credentials and secrets from SDK payloads. Runs before any storage,
//! upload or live publication.

use std::borrow::Cow;

use serde_json::{Map, Value};

mod template;
mod text;

pub use template::Slot;

pub const FILTERED: &str = "[Filtered]";

#[derive(Clone, Copy)]
enum Scope {
    Anywhere,
    LastWord,
    LastWordEnd,
}

/// Whether a number after `:` is part of the value. Most credential names
/// also label counts and ports (`token_count: 5`, `session: 7`); a password,
/// secret or key name never does.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum Numbers {
    Kept,
    Secret,
}

/// Every built-in credential name, in compact form: lowercase ASCII letters
/// and digits only. Object keys, pair names and names found in text all go
/// through `Redactor::sensitivity`, which reads only this table and the
/// organization's extra names. `Anywhere` names match inside the compact key,
/// so `privateKey`, `private-key` and `PRIVATE_KEY` all match `privatekey`.
/// `LastWord` names are short and match the last word of a key, so `pass`
/// filters `db.pass` but not `pass_count`. A `LastWordEnd` name ends the last
/// word, so `auth` filters `X-Auth`, `basicAuth`, `oauth` and `XAuth` but not
/// `author` or `auth_provider`.
const SENSITIVE_NAMES: &[(&str, Scope, Numbers)] = &[
    ("password", Scope::Anywhere, Numbers::Secret),
    ("passwd", Scope::Anywhere, Numbers::Secret),
    ("passphrase", Scope::Anywhere, Numbers::Secret),
    ("pwd", Scope::Anywhere, Numbers::Secret),
    ("secret", Scope::Anywhere, Numbers::Secret),
    ("apikey", Scope::Anywhere, Numbers::Secret),
    ("privatekey", Scope::Anywhere, Numbers::Secret),
    ("credential", Scope::Anywhere, Numbers::Secret),
    ("token", Scope::Anywhere, Numbers::Kept),
    ("authorization", Scope::Anywhere, Numbers::Kept),
    ("cookie", Scope::Anywhere, Numbers::Kept),
    ("accesskey", Scope::Anywhere, Numbers::Kept),
    ("session", Scope::Anywhere, Numbers::Kept),
    ("csrf", Scope::Anywhere, Numbers::Kept),
    ("sentrykey", Scope::Anywhere, Numbers::Kept),
    ("authkey", Scope::Anywhere, Numbers::Kept),
    ("authcode", Scope::Anywhere, Numbers::Kept),
    ("authdata", Scope::Anywhere, Numbers::Kept),
    ("authheader", Scope::Anywhere, Numbers::Kept),
    ("authvalue", Scope::Anywhere, Numbers::Kept),
    ("codeverifier", Scope::Anywhere, Numbers::Kept),
    ("amzsignature", Scope::Anywhere, Numbers::Kept),
    ("pass", Scope::LastWord, Numbers::Kept),
    ("auth", Scope::LastWordEnd, Numbers::Kept),
];

const NAME_FIELDS: &[&str] = &["name", "key", "property"];

/// An additional sensitive field name: 3 to 64 characters of `a-z`, `0-9`,
/// `_` and `.`, stored in the normalized form used for matching.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, serde::Serialize)]
#[serde(transparent)]
pub struct FieldName(String);

impl FieldName {
    pub const MIN_LEN: usize = 3;
    pub const MAX_LEN: usize = 64;

    pub fn parse(raw: &str) -> Option<Self> {
        let name = normalize_key(raw.trim());
        let valid = (Self::MIN_LEN..=Self::MAX_LEN).contains(&name.len())
            && name
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_' || b == b'.');
        valid.then_some(Self(name))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

fn normalize_key(key: &str) -> String {
    key.to_ascii_lowercase().replace('-', "_")
}

/// The credential filter for one ingestion request: the mandatory built-in
/// names plus the organization's additional field names. Additional names
/// match like `Anywhere` names: their letters and digits are a substring of
/// the field name's letters and digits, ignoring case, so `customer_ssn`
/// matches `customerSsn` and `X-Customer-SSN`. A number is a secret value
/// for an additional name.
#[derive(Clone, Copy, Debug)]
pub struct Redactor<'a> {
    extra: &'a [FieldName],
}

pub const BUILT_IN: Redactor<'static> = Redactor { extra: &[] };

impl<'a> Redactor<'a> {
    pub fn new(extra: &'a [FieldName]) -> Self {
        Self { extra }
    }

    pub fn is_sensitive_key(&self, key: &str) -> bool {
        self.sensitivity(key).is_some()
    }

    /// How a name labels a credential, or `None` for a harmless name. A name
    /// with a `%` is percent-decoded once first. Organization names always
    /// treat numbers as secret.
    pub(crate) fn sensitivity(&self, key: &str) -> Option<Numbers> {
        if key.contains('%') {
            return self.decoded_sensitivity(&decode_component(key));
        }
        self.decoded_sensitivity(key)
    }

    fn decoded_sensitivity(&self, key: &str) -> Option<Numbers> {
        let mut stack = [0u8; 96];
        let heap: Vec<u8>;
        let compact: &[u8] = if key.len() <= stack.len() {
            let len = compact_into(key.as_bytes(), &mut stack);
            &stack[..len]
        } else {
            heap = key
                .bytes()
                .filter(u8::is_ascii_alphanumeric)
                .map(|b| b.to_ascii_lowercase())
                .collect();
            &heap
        };
        let last = last_word(key).as_bytes();
        let extra = self.extra.iter().any(|name| {
            let mut buf = [0u8; FieldName::MAX_LEN];
            let len = compact_into(name.as_str().as_bytes(), &mut buf);
            len > 0 && contains(compact, &buf[..len])
        });
        let built_in = SENSITIVE_NAMES
            .iter()
            .filter(|(name, scope, _)| match scope {
                Scope::Anywhere => contains(compact, name.as_bytes()),
                Scope::LastWord => last.eq_ignore_ascii_case(name.as_bytes()),
                Scope::LastWordEnd => {
                    last.len() >= name.len()
                        && last[last.len() - name.len()..].eq_ignore_ascii_case(name.as_bytes())
                }
            })
            .map(|(_, _, numbers)| *numbers)
            .max();
        if extra {
            Some(Numbers::Secret)
        } else {
            built_in
        }
    }

    /// Whether a field set names its `value` field as a credential, as in
    /// `{"name": "Authorization", "value": …}`, `{"key": …}` or
    /// `{"property": "password", …}`. Field names match case-insensitively.
    pub fn names_secret<'v>(
        &self,
        fields: impl IntoIterator<Item = (&'v String, Option<&'v str>)>,
    ) -> bool {
        fields.into_iter().any(|(field, name)| {
            NAME_FIELDS
                .iter()
                .any(|known| field.eq_ignore_ascii_case(known))
                && name.is_some_and(|name| self.is_sensitive_key(name))
        })
    }

    /// Filters labelled credentials embedded in text with the grammar in
    /// [`text`]: URL user information, header lines, `name=value`,
    /// `name: value` and `name => value` pairs (quoted or not) whose name is
    /// sensitive, and authorization schemes. A percent-encoded token is
    /// decoded once and checked with the same rules; a secret encoded twice is
    /// not detected.
    pub fn text<'s>(&self, value: &'s str) -> Cow<'s, str> {
        text::redact(self, value)
    }

    /// Scrubs a JSON tree in place. A sensitive object key or pair name loses
    /// its value whatever the value text is; every string and key is checked
    /// for embedded credentials; an object with a `message` template and
    /// `params` loses the parameters the template puts in a credential
    /// position.
    pub fn value(&self, value: &mut Value) {
        match value {
            Value::String(s) => {
                if let Cow::Owned(clean) = self.text(s) {
                    *s = clean;
                }
            }
            Value::Array(items) => {
                for item in items {
                    match pair(item) {
                        Some((name, entry, rest)) => {
                            self.entry(name, entry);
                            rest.iter_mut().for_each(|item| self.value(item));
                            if let Cow::Owned(clean) = self.text(name) {
                                *name = clean;
                            }
                        }
                        None => self.value(item),
                    }
                }
            }
            Value::Object(map) => {
                self.template_params(map);
                let named = self.names_secret(map.iter().map(|(key, item)| (key, item.as_str())));
                let scrubbed = std::mem::take(map)
                    .into_iter()
                    .map(|(key, mut item)| {
                        if named && key.eq_ignore_ascii_case("value") {
                            mask(&mut item);
                        } else {
                            self.entry(&key, &mut item);
                        }
                        (self.text(&key).into_owned(), item)
                    })
                    .collect::<Map<_, _>>();
                *map = scrubbed;
            }
            _ => {}
        }
    }

    /// Masks the `params` that a `message` template puts in a credential
    /// position, as in `logentry` and an object `message`, checked against
    /// the SDK's `formatted` message when it is present.
    fn template_params(&self, map: &mut Map<String, Value>) {
        let exposed = match (map.get("message"), map.get("params")) {
            (Some(Value::String(template)), Some(params)) => {
                let slots: Vec<(Slot<'_>, &Value)> = match params {
                    Value::Array(items) => items
                        .iter()
                        .enumerate()
                        .map(|(n, item)| (Slot::Index(n), item))
                        .collect(),
                    Value::Object(named) => named
                        .iter()
                        .map(|(name, item)| (Slot::Name(name), item))
                        .collect(),
                    other => vec![(Slot::Index(0), other)],
                };
                let formatted = map.get("formatted").and_then(Value::as_str);
                self.exposed_parameters(template, &slots, formatted)
            }
            _ => return,
        };
        match map.get_mut("params") {
            Some(Value::Array(items)) => items.iter_mut().zip(exposed).for_each(masked),
            Some(Value::Object(named)) => named.values_mut().zip(exposed).for_each(masked),
            Some(other) if exposed.first() == Some(&true) => mask(other),
            _ => {}
        }
    }

    fn entry(&self, name: &str, value: &mut Value) {
        if self.is_sensitive_key(name) {
            mask(value);
        } else {
            self.value(value);
        }
    }
}

fn masked((value, exposed): (&mut Value, bool)) {
    if exposed {
        mask(value);
    }
}

fn mask(value: &mut Value) {
    if !matches!(value, Value::Null | Value::Bool(_)) {
        *value = Value::String(FILTERED.to_owned());
    }
}

fn compact_into(raw: &[u8], out: &mut [u8]) -> usize {
    let mut len = 0;
    for &b in raw.iter().filter(|b| b.is_ascii_alphanumeric()) {
        out[len] = b.to_ascii_lowercase();
        len += 1;
    }
    len
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack
        .windows(needle.len())
        .any(|window| window == needle)
}

/// The last word of a name. Words split at characters other than ASCII
/// letters and digits, and before an uppercase letter that follows a
/// lowercase letter or digit.
fn last_word(name: &str) -> &str {
    let mut word = (0, 0);
    let mut start = None;
    let mut lower = false;
    for (at, b) in name.bytes().enumerate() {
        if b.is_ascii_alphanumeric() {
            if start.is_none() || lower && b.is_ascii_uppercase() {
                start = Some(at);
            }
            word = (start.unwrap_or(at), at + 1);
            lower = b.is_ascii_lowercase() || b.is_ascii_digit();
        } else {
            start = None;
            lower = false;
        }
    }
    &name[word.0..word.1]
}

fn decode_component(raw: &str) -> String {
    url::form_urlencoded::parse(raw.as_bytes())
        .next()
        .map(|(name, _)| name.into_owned())
        .unwrap_or_default()
}

/// A `[name, value]` or `[name, value, x]` element of a key/value pair list, as
/// SDKs and HTTP archives send headers, cookies, query strings and tags.
fn pair(item: &mut Value) -> Option<(&mut String, &mut Value, &mut [Value])> {
    match item.as_array_mut()?.as_mut_slice() {
        [Value::String(name), value, rest @ ..] if rest.len() <= 1 => Some((name, value, rest)),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn removes_credentials_from_keys_pairs_urls_and_text() {
        let mut payload = json!({
            "request": {
                "headers": [["Authorization", "opaque-value-1"], ["Accept", "*/*"]],
                "url": "https://x.test/cb?%74oken=s3cr3t&page=2&session_id=s4"
            },
            "extra": {
                "db_password": "hunter2",
                "note": "login with password=hunter2 ok",
                "dsn": "postgres://app:opaque@value-2@db.test/app",
                "text": "retry db_password=opaque-value-4 now\nsession_id=opaque-value-5 page=2",
                "prefs": "theme=dark; sessionid=opaque-value-7",
                "pairs": [["password=opaque-value-6", "v"]],
                "ssn_note": "plain",
                "list": ["Authorization", "opaque-value-3"]
            },
            "message": "Bearer abcdefghijklmnop failed",
        });
        let extra = [FieldName::parse("SSN").unwrap()];
        Redactor::new(&extra).value(&mut payload);
        assert_eq!(
            payload,
            json!({
                "request": {
                    "headers": [["Authorization", "[Filtered]"], ["Accept", "*/*"]],
                    "url": "https://x.test/cb?%74oken=[Filtered]&page=2&session_id=[Filtered]"
                },
                "extra": {
                    "db_password": "[Filtered]",
                    "note": "login with password=[Filtered] ok",
                    "dsn": "postgres://app:[Filtered]@db.test/app",
                    "text": "retry db_password=[Filtered] now\nsession_id=[Filtered] page=2",
                    "prefs": "theme=dark; sessionid=[Filtered]",
                    "pairs": [["password=[Filtered]", "[Filtered]"]],
                    "ssn_note": "[Filtered]",
                    "list": ["Authorization", "opaque-value-3"]
                },
                "message": "Bearer [Filtered] failed",
            })
        );
    }

    #[test]
    fn field_names_are_normalized_and_bounded() {
        assert_eq!(
            FieldName::parse(" Customer-SSN ").map(|name| name.0),
            Some("customer_ssn".to_owned())
        );
        assert_eq!(FieldName::parse("ab"), None);
        assert_eq!(FieldName::parse("has space"), None);
        assert_eq!(FieldName::parse(&"a".repeat(65)), None);
    }

    fn corpus(text: &str) -> Vec<Value> {
        text.lines()
            .filter(|line| !line.trim().is_empty() && !line.starts_with('#'))
            .map(|line| serde_json::from_str(line).unwrap())
            .collect()
    }

    /// `zqmark` plus three digits, or `4242` plus three digits for a secret
    /// that is a number.
    fn marker(line: &str) -> &str {
        let (at, len) = line
            .find("zqmark")
            .map(|at| (at, 9))
            .or_else(|| line.find("4242").map(|at| (at, 7)))
            .expect("every leak line holds a marker");
        &line[at..at + len]
    }

    const LEAKS: &str = include_str!("../tests/fixtures/privacy/leaks.txt");
    const HARMLESS: &str = include_str!("../tests/fixtures/privacy/harmless.txt");
    const LISTED: [&str; 2] = [
        include_str!("../tests/fixtures/privacy/accepted-over-filter.txt"),
        include_str!("../tests/fixtures/privacy/residual-leaks.txt"),
    ];

    fn redacted(value: &Value) -> Value {
        let mut value = value.clone();
        BUILT_IN.value(&mut value);
        value
    }

    #[test]
    fn the_privacy_corpus_holds_for_text_and_structures() {
        let mut failures = Vec::new();
        for leak in corpus(LEAKS) {
            let out = redacted(&leak).to_string();
            if out.contains(marker(&leak.to_string())) {
                failures.push(format!("leak {leak} -> {out}"));
            }
        }
        for harmless in corpus(HARMLESS) {
            let out = redacted(&harmless);
            if out != harmless {
                failures.push(format!("harmless {harmless} -> {out}"));
            }
        }
        for entry in LISTED.into_iter().flat_map(corpus) {
            let out = redacted(&entry[0]);
            if out != entry[1] {
                failures.push(format!(
                    "listed {} -> {out}, expected {}",
                    entry[0], entry[1]
                ));
            }
            if !entry[2].as_str().is_some_and(|reason| !reason.is_empty())
                || entry[3] != Value::Null
            {
                failures.push(format!("listed {} needs exactly one reason", entry[0]));
            }
        }
        assert_eq!(failures, Vec::<String>::new());
    }

    /// Strings of credential-shaped tokens from a fixed seed, so a failure
    /// reproduces.
    fn fuzz_inputs(count: usize) -> Vec<String> {
        const TOKENS: &[&str] = &[
            "password",
            "pass",
            "token",
            "Authorization",
            "Cookie",
            "session",
            "auth",
            "Bearer ",
            "Basic ",
            "Token ",
            "=",
            ":",
            "::",
            "=>",
            ":=",
            " ",
            "\t",
            "\n",
            "\r",
            "\\n",
            "\\r",
            "\\",
            "\"",
            "'",
            "`",
            "\\\"",
            "{",
            "}",
            "[",
            "]",
            "(",
            ")",
            ",",
            ";",
            "&",
            "?",
            "#",
            "@",
            "%",
            "://",
            "https://",
            "postgres://",
            "u:p",
            "[::1]",
            "%41",
            "%3D",
            "%2",
            "<password>",
            "</password>",
            "<",
            ">",
            "42",
            "0.5",
            "1",
            "a",
            "x.ts",
            "Error",
            "oracle:thin:",
            "_",
            "-",
            ".",
            "/",
            "$",
            "+",
            "true",
            "é",
            "€",
            "😀",
            "ß",
            "\u{a0}",
            "\u{2028}",
            "\u{301}",
            "[Filtered]",
        ];
        let mut state = 0x9e37_79b9_7f4a_7c15_u64;
        let mut next = move || {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            state
        };
        (0..count)
            .map(|_| {
                let len = 1 + next() % 24;
                (0..len)
                    .map(|_| TOKENS[(next() % TOKENS.len() as u64) as usize])
                    .collect()
            })
            .collect()
    }

    #[test]
    fn redaction_is_stable_when_applied_twice() {
        let mut unstable = Vec::new();
        let mut leaked = Vec::new();
        let leaks = corpus(LEAKS);
        let inputs = leaks
            .iter()
            .cloned()
            .chain(corpus(HARMLESS))
            .chain(
                LISTED
                    .into_iter()
                    .flat_map(corpus)
                    .map(|entry| entry[0].clone()),
            )
            .chain(fuzz_inputs(100_000).into_iter().map(Value::String));
        for input in inputs {
            let once = redacted(&input);
            let twice = redacted(&once);
            if twice != once {
                unstable.push(format!("{input}\n  1: {once}\n  2: {twice}"));
            }
        }
        for leak in &leaks {
            let out = redacted(leak).to_string();
            if out.contains(marker(&leak.to_string())) {
                leaked.push(out);
            }
        }
        assert_eq!((leaked, unstable), (Vec::new(), Vec::new()));
    }

    #[test]
    fn the_grammar_replaces_exactly_the_value() {
        let cases = [
            ("password=hunter2 ok", "password=[Filtered] ok"),
            ("pin_password=123456", "pin_password=[Filtered]"),
            ("{\"password\": 1234}", "{\"password\": [Filtered]}"),
            ("password: 2024-Summer!x", "password: [Filtered]"),
            ("  db_password: 5432!x", "  db_password: [Filtered]"),
            ("secret: 0.5#x", "secret: [Filtered]"),
            (
                "{\"token_count\": 5, \"port\": 5432}",
                "{\"token_count\": 5, \"port\": 5432}",
            ),
            ("session: 7 users", "session: 7 users"),
            ("secret: true", "secret: true"),
            ("{\"password\": hunter2}", "{\"password\": [Filtered]}"),
            (
                "Authorization=Bearer abcdefgh1&next=/home",
                "Authorization=[Filtered]&next=/home",
            ),
            (
                "<wsse:Password Type=\"PasswordText\">x</wsse:Password>",
                "<wsse:Password Type=\"PasswordText\">[Filtered]</wsse:Password>",
            ),
            (
                "got oauth: x and XAuth: y",
                "got oauth: [Filtered] and XAuth: [Filtered]",
            ),
            ("author: Ada", "author: Ada"),
            (
                "GET /maps?key=AIzaSyA1&q=x and key=v",
                "GET /maps?key=[Filtered]&q=x and key=v",
            ),
            ("ssh://git@h/org/r.git", "ssh://git@h/org/r.git"),
            ("https://git@h/org/r.git", "https://[Filtered]@h/org/r.git"),
            (
                "{\"password\"=>\"x\", \"user\"=>\"ada\"}",
                "{\"password\"=>\"[Filtered]\", \"user\"=>\"ada\"}",
            ),
            (
                "{\"tokens\": [\"a\", \"b\"], \"n\": 1}",
                "{\"tokens\": \"[Filtered]\", \"n\": 1}",
            ),
            (
                "{\\\"tokens\\\":[\\\"a\\\"]}",
                "{\\\"tokens\\\":\\\"[Filtered]\\\"}",
            ),
            (
                "{\"credentials\": {\"key\": \"a\"}} ok",
                "{\"credentials\": \"[Filtered]\"} ok",
            ),
            (
                "{\n  \"password\":\n    \"x\"\n}",
                "{\n  \"password\":\n    \"[Filtered]\"\n}",
            ),
            (
                "sent Cookie: a=b; sid=x\nnext",
                "sent Cookie: [Filtered]\nnext",
            ),
            (
                "Authorization: Bot x\\r\\nAccept: */*",
                "Authorization: [Filtered]\\r\\nAccept: */*",
            ),
            (
                "at verify (/srv/app/src/auth.ts:42:13)",
                "at verify (/srv/app/src/auth.ts:42:13)",
            ),
            (
                "GET https://u:p@auth.example.com:8443/login?token=t&next=/home",
                "GET https://u:[Filtered]@auth.example.com:8443/login?token=[Filtered]&next=/home",
            ),
            (
                "postgres://u:123/x@db/app",
                "postgres://u:[Filtered]@db/app",
            ),
            ("http://localhost:3000/@me", "http://localhost:3000/@me"),
            (
                "jdbc:oracle:thin:scott/tiger@db:1521/svc",
                "jdbc:oracle:thin:scott/[Filtered]@db:1521/svc",
            ),
            ("<password>x</password>", "<password>[Filtered]</password>"),
            (
                "Token abcdefgh1 and token provided",
                "Token [Filtered] and token provided",
            ),
        ];
        let failures: Vec<String> = cases
            .iter()
            .filter(|(input, expected)| BUILT_IN.text(input) != *expected)
            .map(|(input, _)| format!("{input} -> {}", BUILT_IN.text(input)))
            .collect();
        assert_eq!(failures, Vec::<String>::new());
    }

    #[test]
    fn template_parameters_in_credential_positions_are_filtered() {
        let cases = [
            (
                "db login failed password=%s",
                json!(["hunter2"]),
                json!(["[Filtered]"]),
            ),
            ("token={}", json!(["abc"]), json!(["[Filtered]"])),
            (
                "%s=%s",
                json!(["password", "hunter2"]),
                json!(["password", "[Filtered]"]),
            ),
            (
                "%s: %s",
                json!(["api_key", "abc"]),
                json!(["api_key", "[Filtered]"]),
            ),
            ("password: %d", json!([1234]), json!(["[Filtered]"])),
            ("https://u:%s@db/app", json!(["pw"]), json!(["[Filtered]"])),
            (
                "Authorization: Bearer %s",
                json!(["abc"]),
                json!(["[Filtered]"]),
            ),
            (
                "user %(user)s password=%(pw)s",
                json!({"user": "ada", "pw": "x"}),
                json!({"user": "ada", "pw": "[Filtered]"}),
            ),
            (
                "login %{user} with token=%{t}",
                json!({"user": "ada", "t": "x"}),
                json!({"user": "ada", "t": "[Filtered]"}),
            ),
            (
                "user {0} failed with {1}",
                json!(["ada", "password=x"]),
                json!(["ada", "password=[Filtered]"]),
            ),
            ("Invalid token %s", json!(["provided"]), json!(["provided"])),
            (
                "token_count: %s, port %d",
                json!(["5", 5432]),
                json!(["5", 5432]),
            ),
            ("prompt_tokens: %d", json!([12]), json!([12])),
            (
                "%s",
                json!(["password=x ok"]),
                json!(["password=[Filtered] ok"]),
            ),
            ("retry %s of %s", json!([2, 3]), json!([2, 3])),
            ("100%% done for %s", json!(["ada"]), json!(["ada"])),
            ("no placeholder", json!(["x"]), json!(["[Filtered]"])),
            ("secret: %s", json!([true]), json!([true])),
        ];
        let mut failures = Vec::new();
        for (template, params, expected) in cases {
            let mut event = json!({"logentry": {"message": template, "params": params}});
            BUILT_IN.value(&mut event);
            if event["logentry"]["params"] != expected {
                failures.push(format!("{template} -> {}", event["logentry"]["params"]));
            }
        }
        assert_eq!(failures, Vec::<String>::new());
    }

    #[test]
    fn parameters_are_masked_when_the_template_does_not_render_the_formatted_message() {
        let cases = [
            (
                "auth failed for {:?}: token={} retry={}",
                json!(["Request { id: 7 }", "abc", "3"]),
                "auth failed for Request { id: 7 }: token=abc retry=3",
                json!(["[Filtered]", "[Filtered]", "[Filtered]"]),
            ),
            (
                "db %v login failed password=%s user=%s",
                json!(["primary", "hunter2", "app"]),
                "db primary login failed password=hunter2 user=app",
                json!(["[Filtered]", "[Filtered]", "[Filtered]"]),
            ),
            (
                "attempt % d password=%s user=%s",
                json!([3, "hunter2", "app"]),
                "attempt  3 password=hunter2 user=app",
                json!(["[Filtered]", "[Filtered]", "[Filtered]"]),
            ),
            (
                "GET /cb?next=%2Fhome failed, password: {}",
                json!(["hunter2"]),
                "GET /cb?next=%2Fhome failed, password: hunter2",
                json!(["[Filtered]"]),
            ),
            (
                "payload {} rejected for password=%s",
                json!(["hunter2"]),
                "payload {} rejected for password=hunter2",
                json!(["[Filtered]"]),
            ),
            (
                "user %s from %s retried %d times in %.2f s",
                json!(["ada", "10.0.0.1", 3, 1.5]),
                "user ada from 10.0.0.1 retried 3 times in 1.50 s",
                json!(["ada", "10.0.0.1", 3, 1.5]),
            ),
            (
                "{name} {{literal}} took {ms:>6}ms",
                json!({"name": "ada", "ms": 12}),
                "ada {literal} took     12ms",
                json!({"name": "ada", "ms": 12}),
            ),
        ];
        let mut failures = Vec::new();
        for (template, params, formatted, expected) in cases {
            let mut event = json!({"logentry":
                {"message": template, "params": params, "formatted": formatted}});
            BUILT_IN.value(&mut event);
            if event["logentry"]["params"] != expected {
                failures.push(format!("{template} -> {}", event["logentry"]["params"]));
            }
        }
        assert_eq!(failures, Vec::<String>::new());
    }

    #[test]
    fn nested_templates_judge_each_level_in_its_own_template() {
        let mut event = json!({"extra": {"t": {"message": "user %s with %s", "params": [
            {"message": "login %s password=%s", "params": ["ada", "hunter2"]},
            {"password": "x", "note": "ok"}
        ]}}});
        BUILT_IN.value(&mut event);
        assert_eq!(
            event,
            json!({"extra": {"t": {"message": "user %s with %s", "params": [
                {"message": "login %s password=[Filtered]", "params": ["ada", "[Filtered]"]},
                {"password": "[Filtered]", "note": "ok"}
            ]}}})
        );
    }

    #[test]
    fn structured_name_value_shapes_and_split_names_are_filtered() {
        let mut payload = json!({
            "postman": {"key": "Authorization", "value": "a"},
            "dotnet": {"Name": "Authorization", "Value": "b"},
            "validator": {"property": "password", "value": "c", "constraints": {"min": "x"}},
            "privateKey": "d",
            "passphrase": "e",
            "auth_provider": "github",
            "header": {"name": "Accept", "value": "*/*"}
        });
        BUILT_IN.value(&mut payload);
        assert_eq!(
            payload,
            json!({
                "postman": {"key": "Authorization", "value": "[Filtered]"},
                "dotnet": {"Name": "Authorization", "Value": "[Filtered]"},
                "validator": {"property": "password", "value": "[Filtered]", "constraints": {"min": "x"}},
                "privateKey": "[Filtered]",
                "passphrase": "[Filtered]",
                "auth_provider": "github",
                "header": {"name": "Accept", "value": "*/*"}
            })
        );
    }

    fn fastest(input: &str) -> std::time::Duration {
        (0..3)
            .map(|_| {
                let start = std::time::Instant::now();
                std::hint::black_box(BUILT_IN.text(input));
                start.elapsed()
            })
            .min()
            .unwrap()
    }

    /// Eight times the input must cost about eight times the time, never the
    /// sixty-four times of a quadratic pass, and 1 MiB stays well under a
    /// second unoptimized.
    #[test]
    fn adversarial_text_redacts_in_linear_time() {
        let units = [
            "a=",
            "a:",
            "a://",
            "a://u:p/",
            "a=\"",
            "\"a\":",
            "a=>",
            "{\"a\":\"b\"}",
            "%41",
            "a: b\n",
            "    at f (/srv/app/b.js:10:20)\n",
            "a=b;",
            "a= ",
            "[",
            "{",
            "\"",
            "'",
            "\\\"",
            "<a>",
            "password=[",
            "\"password\":",
            "password: x ",
            "token=%41",
            "<password>",
            "Bearer ",
            "u:p@",
            "'a",
            "a/b=",
            "x://u:p\"",
        ];
        let mut report = Vec::new();
        for unit in units {
            let small = fastest(&unit.repeat((128 << 10) / unit.len()));
            let large = fastest(&unit.repeat((1 << 20) / unit.len()));
            let ratio = large.as_secs_f64() / small.as_secs_f64().max(1e-4);
            report.push(format!(
                "{unit:?}: 128 KiB {small:?}, 1 MiB {large:?}, ratio {ratio:.1}"
            ));
            assert!(
                ratio < 20.0 && large < std::time::Duration::from_secs(1),
                "{report:#?}"
            );
        }
        println!("{}", report.join("\n"));
    }
}
