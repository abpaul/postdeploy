//! The free-text credential grammar. One forward pass over the bytes finds
//! labelled credentials and records the byte ranges to replace; the output is
//! built once from those ranges.
//!
//! Grammar, tried in this order at each position:
//!
//! - URL: `scheme://userinfo@host…`. Only the password (or a user-only
//!   userinfo, except for `ssh` and `git+ssh` login names) is replaced; host,
//!   port, path and query stay and are scanned as ordinary text, so query
//!   pairs follow the pair rule.
//! - Element: `<name>value</name>` or `<name attributes>value</name>` with a
//!   sensitive name.
//! - Quoted key: `"…"`, `'…'`, `` `…` `` or `\"…\"`, at most
//!   [`MAX_QUOTED_KEY`] bytes on one line, possibly several words.
//! - Word: a run of `A-Z a-z 0-9 _ - . $ % [ ] /`. A word is a key only after
//!   a delimiter (see [`Scan::key_position`]), and never when it is a source
//!   or config file name (`auth.ts`, `session.yml`) or an exception class
//!   name (`TokenExpiredError`, `SessionNotFound`). Before `:` a word with `/`
//!   is a path and not a key; before `=` its last segment is the key
//!   (`/cb/token=`). `key` is a key only in a URL query (`?key=`) or at the
//!   start of a text that is a whole raw query string (`key=…&page=2`). A word
//!   holding `%XX` is also decoded once and scanned again; a credential inside
//!   replaces the whole encoded token.
//!   `Bearer`, `Basic` and `Token` followed by a credential-shaped run, and
//!   Oracle `thin:user/password@`, are recognized after the word.
//!
//! A key, separator and value form a pair. Separators are `=`, `:`, `=>` and
//! `:=` with spaces or tabs around them; a quoted key's value may also start
//! on a later line. Values are a quoted string up to its unescaped closing
//! quote (or the end of the line when unterminated), a `[…]` or `{…}` group up
//! to its balancing bracket (or the end of the text), or a bare run up to
//! whitespace or one of ``, ; & ) } ] " ' ` < >``. An unquoted key with `:`
//! at the start of a line, and any `Authorization` or `Cookie` name, takes the
//! rest of the line; after `=` such a name's scheme word (`Bearer x`) takes
//! the credential after it. After `:` a number such as `5432`, `42:13` or
//! `0.93` that ends at whitespace, the end of the text or one of
//! ``, ; ) } ] " ' ` `` is a port, position or count and is kept, unless the
//! name is a password, secret or key name; after `=` it is a PIN and is
//! replaced. `true`, `false`, `null`, `nil`, `none` and `undefined` are kept.
//!
//! A range that already reads `[Filtered]` is not replaced again, and a word
//! that starts with `[Filtered]` is not a key, so redacting a redacted text
//! usually changes nothing. A second pass can only filter more: it reads the
//! first pass's output, which holds no removed text.
//!
//! Only a sensitive key's value is consumed. A harmless key moves the cursor
//! past the key alone, so its value is scanned like any other text. Every
//! look-ahead either becomes the next cursor position or is bounded by a
//! constant or by the next occurrence of the byte it searches for, so each
//! byte is examined a bounded number of times.

use std::borrow::Cow;

use super::{decode_component, Numbers, Redactor, FILTERED};

const MAX_QUOTED_KEY: usize = 64;
const MAX_ELEMENT_NAME: usize = 64;
const MAX_SCHEME: usize = 32;
const MAX_ATTRIBUTES: usize = 256;

const SOURCE_EXTENSIONS: &[&str] = &[
    "c", "cc", "cfg", "cjs", "clj", "cljs", "conf", "cpp", "cs", "cts", "dart", "erb", "erl", "ex",
    "exs", "go", "groovy", "h", "hpp", "hrl", "ini", "java", "js", "json", "jsx", "kt", "kts",
    "lua", "m", "mjs", "mm", "mts", "php", "pl", "pm", "py", "rb", "rs", "scala", "sh", "svelte",
    "swift", "toml", "ts", "tsx", "vue", "xml", "yaml", "yml",
];

/// Exception class name endings. `TokenExpiredError: …` and
/// `SessionNotFound: …` start a message, not a pair.
const CLASS_SUFFIXES: &[&str] = &["Error", "Exception", "NotFound"];

/// Bare values that are never a credential.
const LITERALS: &[&str] = &["true", "false", "null", "nil", "none", "undefined"];

/// Schemes whose user name without a password is a login name, never a token.
const LOGIN_SCHEMES: &[&str] = &["git+ssh", "ssh"];

/// Schemes whose authority never carries a port-only `host:digits` before a
/// raw `/`, so `user:123/abc@host` is a password.
const DATABASE_SCHEMES: &[&str] = &[
    "amqp",
    "amqps",
    "mariadb",
    "mongodb",
    "mongodb+srv",
    "mssql",
    "mysql",
    "postgres",
    "postgresql",
    "redis",
    "rediss",
    "sqlserver",
];

#[derive(Clone, Copy, PartialEq, Eq)]
enum Separator {
    Colon,
    Assign,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Quote {
    None,
    Double,
    Single,
    Backtick,
    Escaped,
}

impl Quote {
    fn at(s: &[u8], i: usize) -> Option<Self> {
        match (s[i], s.get(i + 1)) {
            (b'"', _) => Some(Self::Double),
            (b'\'', _) => Some(Self::Single),
            (b'`', _) => Some(Self::Backtick),
            (b'\\', Some(b'"')) => Some(Self::Escaped),
            _ => None,
        }
    }

    fn text(self) -> &'static str {
        match self {
            Self::None => "",
            Self::Double => "\"",
            Self::Single => "'",
            Self::Backtick => "`",
            Self::Escaped => "\\\"",
        }
    }

    fn len(self) -> usize {
        self.text().len()
    }
}

struct Edit {
    start: usize,
    end: usize,
    open: &'static str,
    close: &'static str,
}

/// How a sensitive key's value is read.
#[derive(Clone, Copy)]
struct Pair {
    separator: Separator,
    quote: Quote,
    /// After `:`, the value is the rest of the line.
    rest_of_line: bool,
    /// An `Authorization` or `Cookie` name: after `=`, a scheme word such as
    /// `Bearer` takes the credential after it.
    authorization: bool,
    numbers: Numbers,
}

/// The first byte matching a predicate at or after a position, for positions
/// that only grow. A later query inside the cached span reuses the answer, so
/// all queries together read each byte once.
struct Next {
    from: usize,
    at: usize,
}

impl Next {
    const fn new() -> Self {
        Self {
            from: usize::MAX,
            at: 0,
        }
    }

    fn find(&mut self, s: &[u8], from: usize, matches: impl Fn(u8) -> bool) -> usize {
        if self.from <= from && from <= self.at {
            return self.at;
        }
        self.from = from;
        self.at = s[from..]
            .iter()
            .position(|&b| matches(b))
            .map_or(s.len(), |k| from + k);
        self.at
    }
}

/// The byte ranges that [`redact`] replaces, in order and without overlap.
pub(super) fn ranges(redactor: &Redactor<'_>, text: &str) -> Vec<(usize, usize)> {
    Scan::new(redactor, text, true)
        .run()
        .into_iter()
        .map(|edit| (edit.start, edit.end))
        .collect()
}

pub(super) fn redact<'s>(redactor: &Redactor<'_>, text: &'s str) -> Cow<'s, str> {
    let edits = Scan::new(redactor, text, true).run();
    if edits.is_empty() {
        return Cow::Borrowed(text);
    }
    let mut out = String::with_capacity(text.len());
    let mut copied = 0;
    for edit in edits {
        out.push_str(&text[copied..edit.start]);
        out.push_str(edit.open);
        out.push_str(FILTERED);
        out.push_str(edit.close);
        copied = edit.end;
    }
    out.push_str(&text[copied..]);
    Cow::Owned(out)
}

struct Scan<'r, 's> {
    redactor: &'r Redactor<'r>,
    text: &'s str,
    s: &'s [u8],
    decode: bool,
    encoded_until: usize,
    url_end: Next,
    authority_end: Next,
    at_sign: Next,
    edits: Vec<Edit>,
}

impl<'r, 's> Scan<'r, 's> {
    fn new(redactor: &'r Redactor<'r>, text: &'s str, decode: bool) -> Self {
        Self {
            redactor,
            text,
            s: text.as_bytes(),
            decode,
            encoded_until: 0,
            url_end: Next::new(),
            authority_end: Next::new(),
            at_sign: Next::new(),
            edits: Vec::new(),
        }
    }

    fn run(mut self) -> Vec<Edit> {
        let s = self.s;
        let mut i = 0;
        let mut line_start = true;
        while i < s.len() {
            let b = s[i];
            if b == b'\n' || b == b'\r' {
                line_start = true;
                i += 1;
                continue;
            }
            if b == b' ' || b == b'\t' {
                i += 1;
                continue;
            }
            if b == b'\\' && matches!(s.get(i + 1), Some(b'n' | b'r' | b't')) {
                line_start |= s[i + 1] != b't';
                i += 2;
                continue;
            }
            let at_line_start = std::mem::replace(&mut line_start, false);
            i = if s[i..].starts_with(b"://") {
                self.url(i + 3)
            } else if b == b'<' {
                self.element(i).unwrap_or(i + 1)
            } else if let Some(quote) = Quote::at(s, i) {
                self.quoted_key(i, quote).unwrap_or(i + 1)
            } else if is_word(b) {
                self.word(i, at_line_start)
            } else {
                i + 1
            };
        }
        self.edits
    }

    /// Records a replacement unless the range already reads as its own
    /// replacement, so a second pass does not filter it again.
    fn edit(&mut self, start: usize, end: usize, open: &'static str, close: &'static str) {
        if start >= end {
            return;
        }
        let done = self.text[start..end]
            .strip_prefix(open)
            .and_then(|rest| rest.strip_suffix(close))
            == Some(FILTERED);
        if !done {
            self.edits.push(Edit {
                start,
                end,
                open,
                close,
            });
        }
    }

    /// How a key labels its value. `key` is a credential name only as a URL
    /// query key, where it holds API keys (`?key=…`), including the first key
    /// of a raw query string as SDKs send it without `?`.
    fn sensitivity(&self, name: &str, start: usize, separator: Separator) -> Option<Numbers> {
        let query = if start == 0 {
            is_query(self.s)
        } else {
            matches!(self.s[start - 1], b'?' | b'&')
        };
        if query && separator == Separator::Assign && name.eq_ignore_ascii_case("key") {
            return Some(Numbers::Kept);
        }
        self.redactor.sensitivity(name)
    }

    fn word(&mut self, start: usize, line_start: bool) -> usize {
        let s = self.s;
        let end = s[start..]
            .iter()
            .position(|&b| !is_word(b))
            .map_or(s.len(), |k| start + k);
        let text = self.text;
        let word = &text[start..end];
        if self.decode && start >= self.encoded_until && has_escape(word.as_bytes()) {
            if let Some(next) = self.encoded(start) {
                return next;
            }
        }
        if self.key_position(start) && !word.starts_with(FILTERED) {
            if let Some((value, separator)) = self.separator(end) {
                let Some(key) = key_name(word, separator) else {
                    return end;
                };
                let Some(numbers) = self.sensitivity(key, end - key.len(), separator) else {
                    return end;
                };
                let authorization = whole_line_name(key);
                let pair = Pair {
                    separator,
                    quote: Quote::None,
                    rest_of_line: line_start || authorization,
                    authorization,
                    numbers,
                };
                return self.value(value, pair);
            }
        }
        if let Some(next) = self.scheme_credential(word, end) {
            return next;
        }
        if let Some(next) = self.oracle(word, start, end) {
            return next;
        }
        end
    }

    /// A key starts the text or a line, or follows whitespace, an opening
    /// bracket, a list or query delimiter, a quote, `@`, an escaped line
    /// break, or a `:` that itself follows such a delimiter (`{:api_key=>`).
    fn key_position(&self, start: usize) -> bool {
        let s = self.s;
        let opens = |b: u8| b" \t\r\n{[(,;&?#|<>\"'`@".contains(&b);
        match start.checked_sub(1).map(|p| s[p]) {
            None => true,
            Some(b':') => start < 2 || opens(s[start - 2]) && s[start - 2] != b'@',
            Some(b'n' | b'r' | b't') => start >= 2 && s[start - 2] == b'\\',
            Some(b) => opens(b),
        }
    }

    fn separator(&self, from: usize) -> Option<(usize, Separator)> {
        let s = self.s;
        let at = skip_blank(s, from);
        let rest = &s[at..];
        if rest.starts_with(b"=>") || rest.starts_with(b":=") {
            Some((at + 2, Separator::Assign))
        } else if rest.starts_with(b"::") || rest.starts_with(b"://") || rest.starts_with(b"==") {
            None
        } else if rest.starts_with(b":") {
            Some((at + 1, Separator::Colon))
        } else if rest.starts_with(b"=") {
            Some((at + 1, Separator::Assign))
        } else {
            None
        }
    }

    /// Replaces the value that starts at or after `from` and returns the
    /// position after it, or after the separator when there is no value.
    fn value(&mut self, from: usize, pair: Pair) -> usize {
        let s = self.s;
        let mut at = skip_blank(s, from);
        if at >= s.len() || s[at] == b'\n' || s[at] == b'\r' {
            if pair.quote == Quote::None {
                return at;
            }
            at = s[at..]
                .iter()
                .position(|b| !b.is_ascii_whitespace())
                .map_or(s.len(), |k| at + k);
            if at >= s.len() {
                return at;
            }
        }
        if let Some(quote) = Quote::at(s, at) {
            return self.quoted_value(at, quote);
        }
        if s[at] == b'[' || s[at] == b'{' {
            let end = group_end(s, at, pair.quote == Quote::Escaped);
            if &s[at..end] != FILTERED.as_bytes() {
                self.edit(at, end, pair.quote.text(), pair.quote.text());
            }
            return end;
        }
        let colon = pair.separator == Separator::Colon;
        if colon && pair.numbers == Numbers::Kept && is_number(s, at) {
            return at;
        }
        let bare_end = |from: usize| {
            s[from..]
                .iter()
                .position(|&b| ends_bare(b))
                .map_or(s.len(), |k| from + k)
        };
        let mut end = if colon && pair.quote == Quote::None && pair.rest_of_line {
            line_end(s, at)
        } else {
            bare_end(at)
        };
        if LITERALS
            .iter()
            .any(|literal| s[at..end].eq_ignore_ascii_case(literal.as_bytes()))
        {
            return end;
        }
        if !colon && pair.authorization && is_scheme(&s[at..end]) {
            let credential = skip_blank(s, end);
            if credential > end && credential < s.len() && !ends_bare(s[credential]) {
                end = bare_end(credential);
            }
        }
        self.edit(at, end, "", "");
        end.max(at)
    }

    fn quoted_value(&mut self, at: usize, quote: Quote) -> usize {
        let s = self.s;
        let mut k = at + quote.len();
        while k < s.len() {
            match (quote, s[k]) {
                (_, b'\n' | b'\r') => break,
                (Quote::Escaped, b'\\') if s.get(k + 1) == Some(&b'"') => {
                    self.edit(at, k + 2, quote.text(), quote.text());
                    return k + 2;
                }
                (Quote::Double | Quote::Single | Quote::Escaped, b'\\') => k += 2,
                (Quote::Double, b'"') | (Quote::Single, b'\'') | (Quote::Backtick, b'`') => {
                    self.edit(at, k + 1, quote.text(), quote.text());
                    return k + 1;
                }
                _ => k += 1,
            }
        }
        let end = line_end(s, at).max(at + quote.len());
        self.edit(at, end, quote.text(), "");
        end
    }

    fn quoted_key(&mut self, at: usize, quote: Quote) -> Option<usize> {
        let s = self.s;
        let start = at + quote.len();
        let limit = (start + MAX_QUOTED_KEY).min(s.len());
        let close = (start..limit).find(|&k| {
            matches!(
                (quote, s[k]),
                (_, b'"' | b'\\' | b'\n' | b'\r')
                    | (Quote::Single, b'\'')
                    | (Quote::Backtick, b'`')
            )
        })?;
        let closes = match quote {
            Quote::Escaped => s[close] == b'\\' && s.get(close + 1) == Some(&b'"'),
            Quote::Double => s[close] == b'"',
            Quote::Single => s[close] == b'\'',
            Quote::Backtick => s[close] == b'`',
            Quote::None => false,
        };
        if !closes || close == start {
            return None;
        }
        let after = close + quote.len();
        let (value, separator) = self.separator(after)?;
        let text = self.text;
        let Some(numbers) = self.redactor.sensitivity(&text[start..close]) else {
            return Some(after);
        };
        let pair = Pair {
            separator,
            quote,
            rest_of_line: false,
            authorization: false,
            numbers,
        };
        Some(self.value(value, pair))
    }

    fn element(&mut self, at: usize) -> Option<usize> {
        let s = self.s;
        let start = at + 1;
        let limit = (start + MAX_ELEMENT_NAME).min(s.len());
        let close = (start..limit).find(|&k| !is_element_name(s[k]))?;
        if close == start || !matches!(s[close], b'>' | b' ' | b'\t' | b'\n' | b'\r') {
            return None;
        }
        let text = self.text;
        let name = &text[start..close];
        if !self.redactor.is_sensitive_key(name) {
            return None;
        }
        let open_end = (close..(close + MAX_ATTRIBUTES).min(s.len()))
            .find(|&k| matches!(s[k], b'>' | b'<'))
            .filter(|&k| s[k] == b'>' && s[k - 1] != b'/')?;
        let content = open_end + 1;
        let end = s[content..]
            .iter()
            .position(|&b| b == b'<')
            .map(|k| content + k)?;
        let closing = &s[end..];
        let matched = closing.starts_with(b"</")
            && closing[2..].starts_with(name.as_bytes())
            && closing.get(2 + name.len()) == Some(&b'>');
        if !matched || end == content {
            return None;
        }
        self.edit(content, end, "", "");
        Some(end)
    }

    /// `from` is the position after `://`.
    fn url(&mut self, from: usize) -> usize {
        let s = self.s;
        let end = self.url_end.find(s, from, |b| {
            b.is_ascii_whitespace() || matches!(b, b'"' | b'\'' | b'`' | b'<' | b'>')
        });
        let authority = self
            .authority_end
            .find(s, from, |b| matches!(b, b'/' | b'?' | b'#'))
            .min(end);
        let at = s[from..authority]
            .iter()
            .rposition(|&b| b == b'@')
            .map(|k| from + k)
            .or_else(|| self.raw_password_end(from, authority, end));
        let Some(at) = at.filter(|&at| at > from) else {
            return from;
        };
        match s[from..at].iter().position(|&b| b == b':') {
            Some(colon) => self.edit(from + colon + 1, at, "", ""),
            None if LOGIN_SCHEMES
                .iter()
                .any(|login| self.scheme(from - 3).eq_ignore_ascii_case(login)) => {}
            None => self.edit(from, at, "", ""),
        }
        at + 1
    }

    /// The `@` that ends a password holding a raw `/`, `?`, `#` or quote. The
    /// text after `user:` must not read as a port, except for database
    /// schemes, and an IPv6 host never has a password.
    fn raw_password_end(&mut self, from: usize, authority: usize, end: usize) -> Option<usize> {
        let s = self.s;
        if s.get(from) == Some(&b'[') {
            return None;
        }
        let colon = from + s[from..authority].iter().position(|&b| b == b':')?;
        let after = &s[colon + 1..authority];
        if authority < end {
            let port = after.iter().all(u8::is_ascii_digit);
            if after.is_empty() || port && !self.database_scheme(from - 3) {
                return None;
            }
            let at = self.at_sign.find(s, authority, |b| b == b'@');
            return (at < end).then(|| self.last_at(at));
        }
        if end < s.len() && matches!(s[end], b'"' | b'\'') && !after.is_empty() {
            let stop = s[end + 1..]
                .iter()
                .position(|&b| !is_password(b))
                .map_or(s.len(), |k| end + 1 + k);
            return (stop < s.len() && s[stop] == b'@' && stop > end + 1)
                .then(|| self.last_at(stop));
        }
        None
    }

    /// The last `@` before the URL part that holds the `@` at `at` ends. A
    /// password found past a raw `/` or a quote then ends where it ends once
    /// the redacted URL is read again.
    fn last_at(&self, at: usize) -> usize {
        let s = self.s;
        let stop = s[at..]
            .iter()
            .position(|&b| {
                b.is_ascii_whitespace()
                    || matches!(b, b'/' | b'?' | b'#' | b'"' | b'\'' | b'`' | b'<' | b'>')
            })
            .map_or(s.len(), |k| at + k);
        at + s[at..stop].iter().rposition(|&b| b == b'@').unwrap_or(0)
    }

    /// The URL scheme that ends at the `:` of `://`.
    fn scheme(&self, colon: usize) -> &'s str {
        let s = self.s;
        let start = (colon.saturating_sub(MAX_SCHEME)..colon)
            .rev()
            .take_while(|&k| s[k].is_ascii_alphanumeric() || matches!(s[k], b'+' | b'.' | b'-'))
            .last()
            .unwrap_or(colon);
        &self.text[start..colon]
    }

    fn database_scheme(&self, colon: usize) -> bool {
        let scheme = self.scheme(colon);
        DATABASE_SCHEMES
            .iter()
            .any(|known| scheme.eq_ignore_ascii_case(known))
    }

    fn scheme_credential(&mut self, word: &str, end: usize) -> Option<usize> {
        let s = self.s;
        let needs_digit = word.eq_ignore_ascii_case("token");
        if !(needs_digit
            || word.eq_ignore_ascii_case("bearer")
            || word.eq_ignore_ascii_case("basic"))
        {
            return None;
        }
        let start = skip_blank(s, end);
        if start == end {
            return None;
        }
        let stop = s[start..]
            .iter()
            .position(|&b| !is_credential(b))
            .map_or(s.len(), |k| start + k);
        let run = &s[start..stop];
        if run.len() < 8 || needs_digit && !run.iter().any(u8::is_ascii_digit) {
            return None;
        }
        self.edit(start, stop, "", "");
        Some(stop)
    }

    /// `jdbc:oracle:thin:user/password@host`.
    fn oracle(&mut self, word: &str, start: usize, end: usize) -> Option<usize> {
        let s = self.s;
        let prefixed = start >= 7 && s[start - 7..start].eq_ignore_ascii_case(b"oracle:");
        if !word.eq_ignore_ascii_case("thin") || !prefixed || s.get(end) != Some(&b':') {
            return None;
        }
        let user = end + 1;
        let slash = user
            + s[user..]
                .iter()
                .position(|&b| !(b.is_ascii_alphanumeric() || matches!(b, b'_' | b'$' | b'#')))?;
        if slash == user || s[slash] != b'/' {
            return None;
        }
        let at = slash + 1 + s[slash + 1..].iter().position(|&b| !is_password(b))?;
        if s[at] != b'@' || at == slash + 1 {
            return None;
        }
        self.edit(slash + 1, at, "", "");
        Some(at + 1)
    }

    /// Decodes the percent-encoded token at `start` once and replaces the
    /// whole token when the decoded text holds a credential.
    fn encoded(&mut self, start: usize) -> Option<usize> {
        let s = self.s;
        let end = s[start..]
            .iter()
            .position(|&b| {
                b.is_ascii_whitespace()
                    || matches!(
                        b,
                        b'&' | b',' | b';' | b'=' | b'?' | b'#' | b'"' | b'\'' | b'<' | b'>'
                    )
            })
            .map_or(s.len(), |k| start + k);
        self.encoded_until = end;
        let text = self.text;
        let decoded = decode_component(&text[start..end]);
        if Scan::new(self.redactor, &decoded, false).run().is_empty() {
            return None;
        }
        self.edit(start, end, "", "");
        Some(end)
    }
}

/// A whole text shaped like a raw query string: `name=value` pairs joined by
/// `&`, without whitespace.
fn is_query(s: &[u8]) -> bool {
    !s.iter().any(u8::is_ascii_whitespace)
        && s.split(|&b| b == b'&')
            .all(|pair| pair.first() != Some(&b'=') && pair.contains(&b'='))
}

fn is_word(b: u8) -> bool {
    b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-' | b'.' | b'$' | b'%' | b'[' | b']' | b'/')
}

fn is_element_name(b: u8) -> bool {
    b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-' | b'.' | b':')
}

fn is_password(b: u8) -> bool {
    b.is_ascii_graphic()
        && !matches!(
            b,
            b'"' | b'\''
                | b'`'
                | b','
                | b':'
                | b';'
                | b'{'
                | b'}'
                | b'/'
                | b'<'
                | b'>'
                | b'\\'
                | b'@'
        )
}

fn is_credential(b: u8) -> bool {
    b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'~' | b'+' | b'/' | b'=' | b'-')
}

fn ends_bare(b: u8) -> bool {
    b.is_ascii_whitespace()
        || matches!(
            b,
            b',' | b';' | b'&' | b')' | b'}' | b']' | b'"' | b'\'' | b'`' | b'<' | b'>'
        )
}

fn has_escape(word: &[u8]) -> bool {
    word.windows(3)
        .any(|w| w[0] == b'%' && w[1].is_ascii_hexdigit() && w[2].is_ascii_hexdigit())
}

fn skip_blank(s: &[u8], from: usize) -> usize {
    s[from..]
        .iter()
        .position(|&b| b != b' ' && b != b'\t')
        .map_or(s.len(), |k| from + k)
}

/// The end of the line that contains `from`, before trailing blanks. An
/// escaped `\n` or `\r` also ends it.
fn line_end(s: &[u8], from: usize) -> usize {
    let mut end = (from..s.len())
        .find(|&k| {
            matches!(s[k], b'\n' | b'\r')
                || s[k] == b'\\' && matches!(s.get(k + 1), Some(b'n' | b'r'))
        })
        .unwrap_or(s.len());
    while end > from && matches!(s[end - 1], b' ' | b'\t') {
        end -= 1;
    }
    end
}

/// The end of the `[…]` or `{…}` group at `from`, or the end of the text when
/// it does not balance. Brackets inside strings do not count.
fn group_end(s: &[u8], from: usize, escaped: bool) -> usize {
    let mut depth = 0usize;
    let mut k = from;
    while k < s.len() {
        match s[k] {
            b'[' | b'{' => depth += 1,
            b']' | b'}' => {
                depth -= 1;
                if depth == 0 {
                    return k + 1;
                }
            }
            b'\\' if escaped && s.get(k + 1) == Some(&b'"') => {
                k += 2;
                while k < s.len() && !(s[k] == b'\\' && s.get(k + 1) == Some(&b'"')) {
                    k += 1;
                }
                k += 1;
            }
            b'"' if !escaped => {
                k += 1;
                while k < s.len() && s[k] != b'"' {
                    k += if s[k] == b'\\' { 2 } else { 1 };
                }
            }
            _ => {}
        }
        k += 1;
    }
    s.len()
}

/// A number, `42:13` or `0.93`, that ends the text or is followed by
/// whitespace or one of ``, ; ) } ] " ' ` ``.
fn is_number(s: &[u8], from: usize) -> bool {
    let mut k = from + usize::from(s[from] == b'-');
    let digits = |k: usize| s[k..].iter().take_while(|b| b.is_ascii_digit()).count();
    let first = digits(k);
    if first == 0 {
        return false;
    }
    k += first;
    while k + 1 < s.len() && matches!(s[k], b'.' | b':') && s[k + 1].is_ascii_digit() {
        k += 1 + digits(k + 1);
    }
    s.get(k).is_none_or(|&b| {
        b.is_ascii_whitespace()
            || matches!(b, b',' | b';' | b')' | b'}' | b']' | b'"' | b'\'' | b'`')
    })
}

/// An authorization scheme word such as `Bearer`, `Basic`, `Digest` or
/// `AWS4-HMAC-SHA256`.
fn is_scheme(word: &[u8]) -> bool {
    word.first().is_some_and(u8::is_ascii_alphabetic)
        && word.iter().all(|&b| b.is_ascii_alphanumeric() || b == b'-')
}

fn whole_line_name(word: &str) -> bool {
    let compact: String = word
        .bytes()
        .filter(u8::is_ascii_alphanumeric)
        .map(|b| char::from(b.to_ascii_lowercase()))
        .collect();
    compact.contains("authorization") || compact.contains("cookie")
}

/// The name a word labels before `separator`. Before `:`, a path, a source
/// file such as `auth.ts` or an exception class such as `TokenExpiredError`
/// starts a stack frame or a message, not a pair. Before `=`, a path labels
/// its last segment, as in `/cb/token=…`.
fn key_name(word: &str, separator: Separator) -> Option<&str> {
    if separator == Separator::Colon && word.contains('/') {
        return None;
    }
    let name = word.rsplit('/').next().unwrap_or(word);
    let file = name
        .rsplit_once('.')
        .is_some_and(|(stem, ext)| !stem.is_empty() && SOURCE_EXTENSIONS.contains(&ext));
    let class = CLASS_SUFFIXES.iter().any(|suffix| name.ends_with(suffix));
    (!name.is_empty() && !file && !class).then_some(name)
}
