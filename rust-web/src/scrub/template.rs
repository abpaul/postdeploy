//! Message templates whose parameters SDKs send apart from the text: `message`
//! with `params` in `logentry` or an object `message`, and the
//! `sentry.message.template` log attribute with `sentry.message.parameter.<slot>`
//! attributes. A parameter alone often looks harmless (`hunter2`), so it is
//! judged in its place in the template.
//!
//! Placeholders: printf `%s`, `%5.2f`, `%(name)s`, Ruby `%{name}`, and `{}`,
//! `{0}` and `{name}` with an optional `:spec` or `!conversion`. `%%`, `{{`
//! and a placeholder without a matching parameter are literal text.

use std::{borrow::Cow, collections::HashMap};

use serde_json::Value;

use super::{text, Redactor};

const MAX_NAME: usize = 64;
const MARKER: &str = "Pdtpl";
const MARKER_TAIL: &str = "Mark";
const NUMBER_MARKER: &str = "90909";
const MAX_PARAMETERS: usize = 26 * 26 * 26 * 26;

/// Where a parameter goes: a position, or a name for named placeholders.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Slot<'a> {
    Index(usize),
    Name(&'a str),
}

impl<'a> Slot<'a> {
    /// The slot named by a `sentry.message.parameter.<slot>` suffix.
    pub fn parse(suffix: &'a str) -> Self {
        suffix.parse().map_or(Self::Name(suffix), Self::Index)
    }
}

struct Hole<'t> {
    start: usize,
    end: usize,
    slot: Slot<'t>,
}

enum Field<'t> {
    Next,
    Slot(Slot<'t>),
}

fn holes(template: &str) -> Vec<Hole<'_>> {
    let s = template.as_bytes();
    let mut out = Vec::new();
    let mut next = 0;
    let mut i = 0;
    while i < s.len() {
        let found = match (s[i], s.get(i + 1)) {
            (b'%', Some(b'%')) | (b'{', Some(b'{')) => {
                i += 2;
                continue;
            }
            (b'%', _) => percent(template, i),
            (b'{', _) => brace(template, i),
            _ => None,
        };
        let Some((end, field)) = found else {
            i += 1;
            continue;
        };
        let slot = match field {
            Field::Slot(slot) => slot,
            Field::Next => {
                next += 1;
                Slot::Index(next - 1)
            }
        };
        out.push(Hole {
            start: i,
            end,
            slot,
        });
        i = end;
    }
    out
}

/// The end of a `name)` or `name}` that starts at `from`.
fn name_end(s: &[u8], from: usize, close: u8) -> Option<usize> {
    let limit = (from + MAX_NAME).min(s.len());
    let k = (from..limit).find(|&k| matches!(s[k], b'{' | b'}' | b'(' | b')'))?;
    (s[k] == close && k > from).then_some(k)
}

fn percent(t: &str, at: usize) -> Option<(usize, Field<'_>)> {
    let s = t.as_bytes();
    match s.get(at + 1)? {
        b'(' => {
            let close = name_end(s, at + 2, b')')?;
            let end = conversion_end(s, close + 1)?;
            Some((end, Field::Slot(Slot::Name(&t[at + 2..close]))))
        }
        b'{' => {
            let close = name_end(s, at + 2, b'}')?;
            let name = &t[at + 2..close];
            is_identifier(name).then_some((close + 1, Field::Slot(Slot::Name(name))))
        }
        _ => Some((conversion_end(s, at + 1)?, Field::Next)),
    }
}

/// The end of a printf conversion: flags, width, precision, length and type.
fn conversion_end(s: &[u8], from: usize) -> Option<usize> {
    let mut k = from;
    let skip = |k: usize, accept: fn(u8) -> bool| {
        k + s[k.min(s.len())..]
            .iter()
            .take_while(|&&b| accept(b))
            .count()
    };
    k = skip(k, |b| matches!(b, b'-' | b'+' | b'#' | b'0'));
    k = skip(k, |b| b.is_ascii_digit());
    if s.get(k) == Some(&b'.') {
        k = skip(k + 1, |b| b.is_ascii_digit());
    }
    k = skip(k, |b| {
        matches!(b, b'h' | b'l' | b'L' | b'q' | b'j' | b'z' | b't')
    });
    s.get(k)
        .filter(|b| b"diouxXeEfFgGcrsabjO".contains(b))
        .map(|_| k + 1)
}

fn brace(t: &str, at: usize) -> Option<(usize, Field<'_>)> {
    let s = t.as_bytes();
    let close =
        name_end(s, at + 1, b'}').or_else(|| (s.get(at + 1) == Some(&b'}')).then_some(at + 1))?;
    let (head, spec) = t[at + 1..close]
        .split_once(':')
        .unwrap_or((&t[at + 1..close], ""));
    let (name, conversion) = head.split_once('!').unwrap_or((head, "s"));
    if !matches!(conversion, "r" | "s" | "a") || !is_format_spec(spec.as_bytes()) {
        return None;
    }
    let slot = if name.is_empty() {
        Field::Next
    } else if name.bytes().all(|b| b.is_ascii_digit()) {
        Field::Slot(Slot::Index(name.parse().ok()?))
    } else if is_identifier(name) {
        Field::Slot(Slot::Name(name))
    } else {
        return None;
    };
    Some((close + 1, slot))
}

/// A `str.format` spec such as `>8`, `+.2f` or `,d`.
fn is_format_spec(spec: &[u8]) -> bool {
    let align = |b: &u8| matches!(b, b'<' | b'>' | b'=' | b'^');
    let mut k = if spec.get(1).is_some_and(align) {
        2
    } else {
        usize::from(spec.first().is_some_and(align))
    };
    k = skip_one(spec, k, |b| matches!(b, b'+' | b'-' | b' '));
    k = skip_one(spec, k, |b| b == b'#');
    k = skip_one(spec, k, |b| b == b'0');
    k += count_digits(&spec[k..]);
    k = skip_one(spec, k, |b| matches!(b, b',' | b'_'));
    if spec.get(k) == Some(&b'.') {
        k += 1 + count_digits(&spec[k + 1..]);
    }
    k = skip_one(spec, k, |b| b.is_ascii_alphabetic() || b == b'%');
    k == spec.len()
}

fn skip_one(s: &[u8], k: usize, accept: fn(u8) -> bool) -> usize {
    k + usize::from(s.get(k).is_some_and(|&b| accept(b)))
}

fn count_digits(s: &[u8]) -> usize {
    s.iter().take_while(|b| b.is_ascii_digit()).count()
}

fn is_identifier(name: &str) -> bool {
    let mut bytes = name.bytes();
    bytes
        .next()
        .is_some_and(|b| b.is_ascii_alphabetic() || b == b'_')
        && bytes.all(|b| b.is_ascii_alphanumeric() || b == b'_')
}

/// The text a string or number parameter adds to the message. An array or
/// object adds only its marker: it is masked whole when the filled message
/// filters that marker, and its own fields are judged by the normal
/// recursion. `true`, `false` and `null` are never filtered.
fn rendered(value: &Value) -> Option<Cow<'_, str>> {
    match value {
        Value::String(text) => Some(Cow::Borrowed(text)),
        Value::Number(number) => Some(Cow::Owned(number.to_string())),
        _ => None,
    }
}

fn is_hidden(value: &Value) -> bool {
    matches!(value, Value::Null | Value::Bool(_))
}

/// A placeholder that shows a string parameter exactly as sent.
fn is_verbatim(placeholder: &str) -> bool {
    placeholder == "%s"
        || placeholder.starts_with("%(") && placeholder.ends_with(")s")
        || placeholder.starts_with("%{")
        || placeholder.starts_with('{') && !placeholder.contains([':', '!'])
}

/// Whether `formatted` reads as `rebuilt` with any text in place of each
/// `wild` range.
fn renders(rebuilt: &str, wild: &[(usize, usize)], formatted: &str) -> bool {
    let mut fixed = Vec::with_capacity(wild.len() + 1);
    let mut from = 0;
    for &(start, end) in wild {
        fixed.push(&rebuilt[from..start]);
        from = end;
    }
    fixed.push(&rebuilt[from..]);
    let Some((first, rest)) = fixed.split_first() else {
        return false;
    };
    let Some(tail) = formatted.strip_prefix(first) else {
        return false;
    };
    let Some((last, middle)) = rest.split_last() else {
        return tail.is_empty();
    };
    let Some(mut between) = tail.strip_suffix(last) else {
        return false;
    };
    middle.iter().all(|piece| match between.find(piece) {
        Some(at) => {
            between = &between[at + piece.len()..];
            true
        }
        None => false,
    })
}

fn is_number(text: &str) -> bool {
    let digits = text.strip_prefix('-').unwrap_or(text);
    let mut parts = digits.splitn(2, '.');
    parts.all(|part| !part.is_empty() && part.bytes().all(|b| b.is_ascii_digit()))
}

/// Template text as the formatted message shows it: `%%`, `{{` and `}}`
/// stand for one character.
fn push_literal(out: &mut String, text: &str) {
    let mut rest = text;
    while let Some(at) = rest.find(['%', '{', '}']) {
        let doubled = rest[at + 1..].starts_with(&rest[at..=at]);
        out.push_str(&rest[..=at]);
        rest = &rest[at + 1 + usize::from(doubled)..];
    }
    out.push_str(rest);
}

/// A marker shaped like the parameter: digits for a number, letters for
/// anything else, so a port or a count keeps the number rules.
fn push_marker(out: &mut String, n: usize, number: bool) {
    if number {
        out.push_str(&format!("{NUMBER_MARKER}{n:06}9"));
    } else {
        out.push_str(MARKER);
        let mut rest = n;
        for _ in 0..4 {
            out.push(char::from(b'A' + (rest % 26) as u8));
            rest /= 26;
        }
        out.push_str(MARKER_TAIL);
    }
}

/// How often each marker survives in `text`.
fn surviving_markers(text: &str, count: usize) -> Vec<usize> {
    let mut seen = vec![0; count];
    for (at, _) in text.match_indices(MARKER) {
        let code = &text.as_bytes()[at + MARKER.len()..];
        if code.len() >= 4 + MARKER_TAIL.len()
            && code[..4].iter().all(u8::is_ascii_uppercase)
            && code[4..].starts_with(MARKER_TAIL.as_bytes())
        {
            let n = code[..4]
                .iter()
                .rev()
                .fold(0, |n, b| n * 26 + usize::from(b - b'A'));
            if let Some(seen) = seen.get_mut(n) {
                *seen += 1;
            }
        }
    }
    for (at, _) in text.match_indices(NUMBER_MARKER) {
        let code = &text.as_bytes()[at + NUMBER_MARKER.len()..];
        if code.len() >= 7 && code[..6].iter().all(u8::is_ascii_digit) && code[6] == b'9' {
            let n: usize = text[at + NUMBER_MARKER.len()..at + NUMBER_MARKER.len() + 6]
                .parse()
                .unwrap_or(usize::MAX);
            if let Some(seen) = seen.get_mut(n) {
                *seen += 1;
            }
        }
    }
    seen
}

impl Redactor<'_> {
    /// Which parameters a template puts in a credential position. Each
    /// parameter is exposed when its marker does not survive redaction of
    /// the template filled with one marker per parameter, or when the
    /// template filled with the real string and number values gets edits in
    /// that parameter other than the ones the parameter gets alone
    /// (`"%s=%s"` with `password` and `hunter2`). A parameter without a
    /// placeholder is exposed, because its place is unknown. When the SDK's
    /// `formatted` message is not the template with the parameters in their
    /// places, the parser read the placeholders differently from the SDK
    /// (`{:?}`, `%v`, `%2F` in a `{}` template), so every parameter is
    /// exposed.
    pub fn exposed_parameters(
        &self,
        template: &str,
        params: &[(Slot<'_>, &Value)],
        formatted: Option<&str>,
    ) -> Vec<bool> {
        let texts: Vec<Option<Cow<'_, str>>> = params.iter().map(|(_, v)| rendered(v)).collect();
        let all = || params.iter().map(|(_, v)| !is_hidden(v)).collect();
        if params.len() > MAX_PARAMETERS
            || template.contains(MARKER)
            || template.contains(NUMBER_MARKER)
        {
            return all();
        }
        let index: HashMap<Slot<'_>, usize> = params
            .iter()
            .enumerate()
            .map(|(n, (slot, _))| (*slot, n))
            .collect();
        let budget =
            16 * template.len() + 2 * texts.iter().flatten().map(|t| t.len()).sum::<usize>() + 1024;
        let mut marked = String::with_capacity(template.len());
        let mut real = String::with_capacity(template.len());
        let mut spans = Vec::new();
        let mut wild = Vec::new();
        let mut uses = vec![0; params.len()];
        let mut copied = 0;
        for hole in holes(template) {
            let Some(&n) = index.get(&hole.slot) else {
                continue;
            };
            let placeholder = &template[hole.start..hole.end];
            push_literal(&mut marked, &template[copied..hole.start]);
            push_literal(&mut real, &template[copied..hole.start]);
            copied = hole.end;
            let start = real.len();
            let value = params[n].1;
            if is_hidden(value) {
                marked.push_str(placeholder);
                real.push_str(placeholder);
            } else {
                uses[n] += 1;
                let marker = marked.len();
                push_marker(&mut marked, n, texts[n].as_deref().is_some_and(is_number));
                match &texts[n] {
                    Some(text) => {
                        real.push_str(text);
                        spans.push((start, real.len(), n));
                    }
                    None => {
                        real.push_str(&marked[marker..]);
                        spans.push((start, real.len(), n));
                    }
                }
            }
            if !(value.is_string() && is_verbatim(placeholder)) {
                wild.push((start, real.len()));
            }
            if real.len() > budget {
                return all();
            }
        }
        push_literal(&mut marked, &template[copied..]);
        push_literal(&mut real, &template[copied..]);
        if formatted.is_some_and(|formatted| !renders(&real, &wild, formatted)) {
            return all();
        }

        let seen = surviving_markers(&self.text(&marked), params.len());
        let mut exposed: Vec<bool> = params
            .iter()
            .zip(seen.iter().zip(&uses))
            .map(|((_, value), (seen, uses))| !is_hidden(value) && (seen != uses || *uses == 0))
            .collect();

        let edits = text::ranges(self, &real);
        let mut alone: Vec<Option<Vec<(usize, usize)>>> = vec![None; params.len()];
        let mut first = 0;
        for (start, end, n) in spans {
            while first < edits.len() && edits[first].1 <= start {
                first += 1;
            }
            let inside: Vec<(usize, usize)> = edits[first..]
                .iter()
                .take_while(|edit| edit.0 < end)
                .copied()
                .collect();
            if inside.is_empty() || exposed[n] {
                continue;
            }
            let own = alone[n]
                .get_or_insert_with(|| text::ranges(self, texts[n].as_deref().unwrap_or_default()));
            let shifted = inside
                .iter()
                .map(|&(a, b)| (a.wrapping_sub(start), b.wrapping_sub(start)));
            let contained = inside.iter().all(|&(a, b)| a >= start && b <= end);
            exposed[n] = !contained || !shifted.eq(own.iter().copied());
        }
        exposed
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn placeholders_resolve_to_slots() {
        let found: Vec<(&str, Slot<'_>)> =
            ["a %s b %5.2f %% %(user)s %{id} {} {0} {name:>4} {{x}} {not a field} %q"]
                .iter()
                .flat_map(|t| {
                    holes(t)
                        .into_iter()
                        .map(move |h| (&t[h.start..h.end], h.slot))
                })
                .collect();
        assert_eq!(
            found,
            [
                ("%s", Slot::Index(0)),
                ("%5.2f", Slot::Index(1)),
                ("%(user)s", Slot::Name("user")),
                ("%{id}", Slot::Name("id")),
                ("{}", Slot::Index(2)),
                ("{0}", Slot::Index(0)),
                ("{name:>4}", Slot::Name("name")),
            ]
        );
    }
}
