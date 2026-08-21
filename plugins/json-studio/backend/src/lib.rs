//! JSON, as an Arbor Studio format backend.
//!
//! Implements `arbor:extensions/studio-format@1` — the interface Studio calls into when it
//! needs a tree, a query or an edit. See `wit/studio-format.wit` for the contract.
//!
//! ## The reference implementation
//!
//! JSON is the format the interface was shaped against, so this is where its decisions are
//! easiest to read: **subtrees rather than nodes** (one call renders a level instead of one
//! call per row), **batched edits** (a multi-site change is one round trip and one undo
//! entry), and a **resource handle** rather than a document id the caller has to remember to
//! close.
//!
//! ## What it can reach
//!
//! Nothing. No network, no credentials, no filesystem — the host reads the file, knows its
//! encoding, and will write it back. A format backend receives text and returns structure,
//! which makes it the simplest guest there is and the right one to read first.
//!
//! ## Order is preserved
//!
//! `serde_json`'s `preserve_order`, and it is load-bearing rather than a nicety: a config file
//! whose keys reshuffle every time somebody edits one value produces a diff nobody can review,
//! and Studio saves what it parsed.

wit_bindgen::generate!({
    path: "../../../wit",
    world: "studio-format-world",
});

use std::cell::RefCell;

use exports::arbor::extensions::studio_format::{
    Document as DocumentHandle, Guest, GuestDocument,
};
use arbor::extensions::studio_types::{
    EncodingInfo, Error, Hit, Node, NodeKind, Span, TextFlavour, Edit,
};

use serde_json::Value;

// ── Paths ───────────────────────────────────────────────────────────────────────

/// Walk to a node by path. Segments are object keys or decimal array indices; which one a
/// segment means is decided by what it lands on, not by its spelling — `"0"` is a key in an
/// object and an index in an array, and a document can legitimately have both.
fn at<'v>(root: &'v Value, path: &[String]) -> Option<&'v Value> {
    let mut cur = root;
    for seg in path {
        cur = match cur {
            Value::Object(m) => m.get(seg)?,
            Value::Array(a) => a.get(seg.parse::<usize>().ok()?)?,
            _ => return None,
        };
    }
    Some(cur)
}

fn at_mut<'v>(root: &'v mut Value, path: &[String]) -> Option<&'v mut Value> {
    let mut cur = root;
    for seg in path {
        cur = match cur {
            Value::Object(m) => m.get_mut(seg)?,
            Value::Array(a) => a.get_mut(seg.parse::<usize>().ok()?)?,
            _ => return None,
        };
    }
    Some(cur)
}

fn kind_of(v: &Value) -> NodeKind {
    match v {
        Value::Object(_) => NodeKind::Object,
        Value::Array(_) => NodeKind::Array,
        Value::String(_) => NodeKind::String,
        Value::Number(_) => NodeKind::Number,
        Value::Bool(_) => NodeKind::Boolean,
        Value::Null => NodeKind::Null,
    }
}

/// What the tree shows in the value column.
///
/// A container gets a summary of its size rather than its contents: the row is one line, and
/// a serialised object would push the columns off the panel while telling the reader less than
/// `{3}` does.
fn display_of(v: &Value) -> String {
    match v {
        Value::Object(m) => format!("{{{}}}", m.len()),
        Value::Array(a) => format!("[{}]", a.len()),
        Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}

fn has_children(v: &Value) -> bool {
    match v {
        Value::Object(m) => !m.is_empty(),
        Value::Array(a) => !a.is_empty(),
        _ => false,
    }
}

/// One level of children of `v`, as rows.
fn children<'v>(v: &'v Value, base: &[String]) -> Vec<(String, String, &'v Value)> {
    match v {
        Value::Object(m) => m
            .iter()
            .map(|(k, child)| {
                let mut p = base.to_vec();
                p.push(k.clone());
                (p.join("\u{1}"), k.clone(), child)
            })
            .collect(),
        Value::Array(a) => a
            .iter()
            .enumerate()
            .map(|(i, child)| {
                let mut p = base.to_vec();
                p.push(i.to_string());
                // No key: an array element is identified by position, and putting the index in
                // the key column would repeat what the row's order already says.
                (p.join("\u{1}"), String::new(), child)
            })
            .collect(),
        _ => Vec::new(),
    }
}

/// Collect `depth` levels below `path`, breadth-first.
///
/// Breadth-first because that is the order the tree paints: a caller asking for two levels
/// wants the first level to arrive whole rather than interleaved with one branch's
/// grandchildren.
fn collect(root: &Value, path: &[String], depth: u32) -> Vec<Node> {
    let Some(start) = at(root, path) else { return Vec::new() };
    let mut out = Vec::new();
    let mut frontier: Vec<(Vec<String>, &Value)> = vec![(path.to_vec(), start)];
    for _ in 0..depth.max(1) {
        let mut next = Vec::new();
        for (base, v) in &frontier {
            for (joined, key, child) in children(v, base) {
                let p: Vec<String> =
                    joined.split('\u{1}').filter(|s| !s.is_empty()).map(str::to_string).collect();
                out.push(Node {
                    path: p.clone(),
                    key,
                    kind: kind_of(child),
                    display: display_of(child),
                    has_children: has_children(child),
                    // No spans: this backend parses through serde_json, which does not keep
                    // byte offsets. `none` is what the interface allows for exactly this, and
                    // it is more honest than a fabricated range the text view would scroll to.
                    span: None,
                });
                next.push((p, child));
            }
        }
        if next.is_empty() {
            break;
        }
        frontier = next;
    }
    out
}

// ── A very small path query ─────────────────────────────────────────────────────

/// Match a dotted/bracketed path expression against the document.
///
/// A **subset** of JSONPath, and named as one rather than sold as the whole thing:
/// `$.a.b`, `$.arr[0]`, `$.arr[*]` and `$..key`. Filters and slices are not here.
/// The host's own JSONPath engine is a crate this guest deliberately does not carry —
/// a component that pulled in a full query engine would be several times its own size for a
/// feature most documents never use.
fn query_paths(root: &Value, expr: &str) -> Vec<Vec<String>> {
    let expr = expr.trim().trim_start_matches('$');
    if let Some(name) = expr.strip_prefix("..") {
        // Descendant search: every key with this name, anywhere.
        let name = name.trim_start_matches('.');
        let mut out = Vec::new();
        descend(root, &[], name, &mut out);
        return out;
    }

    let mut frontier: Vec<Vec<String>> = vec![Vec::new()];
    for raw in expr.split('.') {
        if raw.is_empty() {
            continue;
        }
        let (name, index) = match raw.split_once('[') {
            Some((n, rest)) => (n, Some(rest.trim_end_matches(']'))),
            None => (raw, None),
        };
        if !name.is_empty() {
            frontier = frontier
                .into_iter()
                .filter_map(|mut p| {
                    p.push(name.to_string());
                    at(root, &p).map(|_| p)
                })
                .collect();
        }
        if let Some(idx) = index {
            frontier = frontier
                .into_iter()
                .flat_map(|p| -> Vec<Vec<String>> {
                    let Some(Value::Array(a)) = at(root, &p) else { return Vec::new() };
                    if idx == "*" {
                        (0..a.len())
                            .map(|i| {
                                let mut q = p.clone();
                                q.push(i.to_string());
                                q
                            })
                            .collect()
                    } else {
                        let mut q = p.clone();
                        q.push(idx.to_string());
                        at(root, &q).map(|_| vec![q]).unwrap_or_default()
                    }
                })
                .collect();
        }
    }
    frontier
}

fn descend(v: &Value, base: &[String], name: &str, out: &mut Vec<Vec<String>>) {
    if let Value::Object(m) = v {
        for (k, child) in m {
            let mut p = base.to_vec();
            p.push(k.clone());
            if k == name {
                out.push(p.clone());
            }
            descend(child, &p, name, out);
        }
    } else if let Value::Array(a) = v {
        for (i, child) in a.iter().enumerate() {
            let mut p = base.to_vec();
            p.push(i.to_string());
            descend(child, &p, name, out);
        }
    }
}

// ── Indent detection ────────────────────────────────────────────────────────────

/// The indent the document already uses, so a save does not reformat a file nobody edited.
fn sniff_indent(text: &str) -> String {
    for line in text.lines().skip(1) {
        let ws: String = line.chars().take_while(|c| *c == ' ' || *c == '\t').collect();
        if !ws.is_empty() && ws.len() < 16 {
            return ws;
        }
    }
    "  ".to_string()
}

fn to_text(v: &Value, indent: &str) -> String {
    if indent.is_empty() {
        return serde_json::to_string(v).unwrap_or_default();
    }
    let mut buf = Vec::new();
    let fmt = serde_json::ser::PrettyFormatter::with_indent(indent.as_bytes());
    let mut ser = serde_json::Serializer::with_formatter(&mut buf, fmt);
    match serde::Serialize::serialize(v, &mut ser) {
        Ok(()) => String::from_utf8(buf).unwrap_or_default(),
        Err(_) => serde_json::to_string_pretty(v).unwrap_or_default(),
    }
}

// ── The document ────────────────────────────────────────────────────────────────

struct Doc {
    inner: RefCell<Inner>,
}

struct Inner {
    original: String,
    value: Value,
    encoding: EncodingInfo,
    indent: String,
    dirty: bool,
}

fn parse_error(e: serde_json::Error, text: &str) -> Error {
    // Line/column back to a byte offset, so the text view can highlight where the parser
    // actually stopped rather than the top of the file.
    let mut offset = 0usize;
    for (i, line) in text.lines().enumerate() {
        if i + 1 == e.line() {
            offset += e.column().saturating_sub(1);
            break;
        }
        offset += line.len() + 1;
    }
    let start = offset.min(text.len()) as u32;
    Error::Parse((e.to_string(), Some(Span { start, end: start })))
}

impl GuestDocument for Doc {
    fn parse(
        text: String,
        _source_path: Option<String>,
        encoding: EncodingInfo,
    ) -> Result<DocumentHandle, Error> {
        let value: Value = serde_json::from_str(&text).map_err(|e| parse_error(e, &text))?;
        let indent = sniff_indent(&text);
        Ok(DocumentHandle::new(Doc {
            inner: RefCell::new(Inner { original: text, value, encoding, indent, dirty: false }),
        }))
    }

    fn set_text(&self, text: String) -> Result<(), Error> {
        let value: Value = serde_json::from_str(&text).map_err(|e| parse_error(e, &text))?;
        let mut i = self.inner.borrow_mut();
        i.value = value;
        i.dirty = text != i.original;
        Ok(())
    }

    fn text(&self, flavour: TextFlavour) -> Result<String, Error> {
        let i = self.inner.borrow();
        Ok(match flavour {
            TextFlavour::Original => i.original.clone(),
            TextFlavour::Current => to_text(&i.value, &i.indent),
            // "Formatted" and "current" coincide here: this backend holds a value tree, not a
            // token stream, so what it can emit is always canonical. Formats that keep their
            // original spacing have two different answers; JSON through serde_json has one.
            TextFlavour::Formatted => to_text(&i.value, &i.indent),
        })
    }

    fn encoding(&self) -> EncodingInfo {
        self.inner.borrow().encoding.clone()
    }

    fn indent(&self) -> String {
        self.inner.borrow().indent.clone()
    }

    fn set_indent(&self, indent: String) -> Result<(), Error> {
        self.inner.borrow_mut().indent = indent;
        Ok(())
    }

    fn subtree(&self, path: Vec<String>, depth: u32) -> Result<Vec<Node>, Error> {
        let i = self.inner.borrow();
        if at(&i.value, &path).is_none() {
            return Err(Error::NoSuchPath(path));
        }
        Ok(collect(&i.value, &path, depth))
    }

    fn value(&self, path: Vec<String>) -> Result<String, Error> {
        let i = self.inner.borrow();
        let v = at(&i.value, &path).ok_or_else(|| Error::NoSuchPath(path.clone()))?;
        Ok(match v {
            // The raw text a user edits: a string's contents, not its quoted form.
            Value::String(s) => s.clone(),
            other => other.to_string(),
        })
    }

    fn query(&self, expr: String) -> Result<Vec<Hit>, Error> {
        let i = self.inner.borrow();
        Ok(query_paths(&i.value, &expr)
            .into_iter()
            .filter_map(|p| {
                at(&i.value, &p).map(|v| Hit {
                    path: p,
                    display: display_of(v),
                    span: None,
                })
            })
            .collect())
    }

    fn apply(&self, edits: Vec<Edit>) -> Result<(), Error> {
        let mut i = self.inner.borrow_mut();
        // Applied to a CLONE, swapped in only if every edit succeeded. Atomicity is the
        // interface's promise, and a half-applied batch leaves a document the user cannot
        // reason about with one entry on the undo stack.
        let mut draft = i.value.clone();
        for edit in edits {
            apply_one(&mut draft, edit)?;
        }
        i.value = draft;
        i.dirty = true;
        Ok(())
    }

    fn dirty(&self) -> bool {
        self.inner.borrow().dirty
    }
}

fn apply_one(root: &mut Value, edit: Edit) -> Result<(), Error> {
    match edit {
        Edit::SetValue((path, raw)) => {
            // Parsed as JSON first so a user typing `42` or `true` gets a number or a boolean;
            // anything that does not parse is taken as the string they typed, which is what
            // they meant when they typed `hello`.
            let parsed = serde_json::from_str::<Value>(&raw).unwrap_or(Value::String(raw));
            let slot = at_mut(root, &path).ok_or_else(|| Error::NoSuchPath(path.clone()))?;
            *slot = parsed;
            Ok(())
        }
        Edit::RenameKey((path, new_key)) => {
            let (parent, old) = split_parent(&path)?;
            let p = at_mut(root, parent).ok_or_else(|| Error::NoSuchPath(path.clone()))?;
            let Value::Object(m) = p else {
                return Err(Error::InvalidEdit("only an object's keys can be renamed".into()));
            };
            // Rebuilt in order rather than remove-then-insert: with `preserve_order` the
            // latter moves the entry to the end, and a key that jumps to the bottom of a
            // config file on rename is a diff nobody asked for.
            let mut rebuilt = serde_json::Map::with_capacity(m.len());
            let mut found = false;
            for (k, v) in m.iter() {
                if k == old {
                    rebuilt.insert(new_key.clone(), v.clone());
                    found = true;
                } else {
                    rebuilt.insert(k.clone(), v.clone());
                }
            }
            if !found {
                return Err(Error::NoSuchPath(path));
            }
            *m = rebuilt;
            Ok(())
        }
        Edit::Remove(path) => {
            let (parent, last) = split_parent(&path)?;
            let p = at_mut(root, parent).ok_or_else(|| Error::NoSuchPath(path.clone()))?;
            match p {
                Value::Object(m) => {
                    m.shift_remove(last).ok_or_else(|| Error::NoSuchPath(path.clone()))?;
                }
                Value::Array(a) => {
                    let i: usize = last
                        .parse()
                        .map_err(|_| Error::InvalidEdit(format!("'{last}' is not an index")))?;
                    if i >= a.len() {
                        return Err(Error::NoSuchPath(path.clone()));
                    }
                    a.remove(i);
                }
                _ => return Err(Error::InvalidEdit("that has no children to remove".into())),
            }
            Ok(())
        }
        Edit::Insert((container, key, raw)) => {
            let parsed = serde_json::from_str::<Value>(&raw).unwrap_or(Value::String(raw));
            let c = at_mut(root, &container).ok_or_else(|| Error::NoSuchPath(container.clone()))?;
            match c {
                Value::Object(m) => {
                    if key.is_empty() {
                        return Err(Error::InvalidEdit("an object member needs a key".into()));
                    }
                    m.insert(key, parsed);
                }
                // An array appends and the key is ignored — that is what the interface says,
                // and inventing a position from a key would be inventing an ordering.
                Value::Array(a) => a.push(parsed),
                _ => return Err(Error::InvalidEdit("that cannot hold children".into())),
            }
            Ok(())
        }
    }
}

fn split_parent(path: &[String]) -> Result<(&[String], &str), Error> {
    match path.split_last() {
        Some((last, parent)) => Ok((parent, last.as_str())),
        None => Err(Error::InvalidEdit("the document root cannot be edited in place".into())),
    }
}

struct Backend;

impl Guest for Backend {
    type Document = Doc;
}

export!(Backend);
