//! Google Cloud Storage, as an Arbor extension.
//!
//! Implements `arbor:cloud/provider@1` — the interface Arbor calls into when the cloud panel
//! needs a listing, an object, or a write. See `wit/cloud-provider.wit` for the contract and
//! `wit/README.md` for why it is a WIT world rather than a Rust trait.
//!
//! ## What this component cannot do
//!
//! It has no filesystem, no sockets, and no TLS. Every request goes out through
//! `arbor:host/http`, which checks the URL against the `network` allowlist in `plugin.toml`
//! before it sends anything, and the access token comes from `arbor:host/secrets` under a key
//! this package declared — the token never lands here as a config value, and this package
//! cannot name a credential belonging to anything else.
//!
//! That is not defence in depth for its own sake. It is what lets the *user's* consent —
//! "this package may reach googleapis.com and store one Google token" — be a thing the host
//! enforces rather than a thing this code promises.
//!
//! ## Why the JSON API and not the XML one
//!
//! The JSON API returns the metadata a file browser needs (size, updated, contentType,
//! generation) in the listing itself. The XML API needs a HEAD per object to fill the same
//! columns, which for a thousand-entry prefix is a thousand extra round trips through a host
//! function.

wit_bindgen::generate!({
    path: "../../../wit",
    world: "cloud-provider-world",
});

use exports::arbor::extensions::cloud_provider::{
    Connection as ConnectionHandle, Guest, GuestConnection,
};
use arbor::extensions::cloud_types::{Error, Listing, Object, Range};
use arbor::extensions::http::{Header, Request};
use arbor::extensions::log::Level;

const API: &str = "https://storage.googleapis.com/storage/v1";
const UPLOAD: &str = "https://storage.googleapis.com/upload/storage/v1";
/// The key this package declared in `[[credentials]]`. Asking for any other name is refused
/// by the host, so this constant is the whole of what this component can reach.
const TOKEN_KEY: &str = "oauth";

// ── Small helpers ───────────────────────────────────────────────────────────────

/// Percent-encode a path segment.
///
/// Object keys contain `/` as an ordinary character — `a/b.txt` is one key, not two segments
/// — so a key going into a URL path must have its slashes encoded too. Getting this wrong
/// turns `stat("a/b.txt")` into a request for an object called `b.txt` inside something that
/// does not exist, and the 404 blames the wrong thing.
fn enc(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 8);
    for b in s.as_bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// Encode a query-string value. Same rules; kept separate because a future change to one
/// (space as `+`, say) must not silently apply to the other.
fn enc_query(s: &str) -> String {
    enc(s)
}

fn header(name: &str, value: String) -> Header {
    Header { name: name.to_string(), value }
}

/// Map an HTTP status onto the interface's error variants.
///
/// The distinction that matters is `not-found` versus `denied`: one is a typo in a key and
/// the other is an expired token or a missing IAM role, and a caller that cannot tell them
/// apart shows the user the wrong next step.
fn status_error(status: u16, body: &[u8]) -> Error {
    let message = String::from_utf8_lossy(body).chars().take(400).collect::<String>();
    match status {
        401 | 403 => Error::Denied(message),
        404 => Error::NotFound(message),
        _ => Error::Remote((Some(status), message)),
    }
}

/// Perform a request through the host, with the bearer token attached.
fn call(
    method: &str,
    url: String,
    token: &str,
    extra: Vec<Header>,
    body: Option<Vec<u8>>,
) -> Result<Vec<u8>, Error> {
    let mut headers = vec![header("authorization", format!("Bearer {token}"))];
    headers.extend(extra);
    let req = Request {
        method: method.to_string(),
        url,
        headers,
        body,
        timeout_secs: Some(60),
    };
    let res = arbor::extensions::http::send(&req).map_err(|e| match e {
        arbor::extensions::http::Error::NotAllowed(h) => Error::Transport(format!(
            "'{h}' is not in this package's network allowlist — it should not have been \
             reached at all, which means a URL was built wrong"
        )),
        arbor::extensions::http::Error::Transport(m) => Error::Transport(m),
        arbor::extensions::http::Error::Invalid(m) => Error::Config(m),
    })?;
    if res.status >= 400 {
        return Err(status_error(res.status, &res.body));
    }
    Ok(res.body)
}

/// The access token, from the host's credential store.
///
/// Read on every call rather than cached in the component. A token is refreshed by the UI
/// half — which is where the OAuth flow lives — and a component holding a stale copy would
/// keep failing with 401 long after the user fixed it. The read is a host call, not a
/// network round trip.
fn token() -> Result<String, Error> {
    match arbor::extensions::secrets::get(TOKEN_KEY) {
        Ok(Some(t)) if !t.is_empty() => Ok(t),
        Ok(_) => Err(Error::Auth(
            "no Google access token stored. Connect an account from the cloud panel's \
             connection settings."
                .into(),
        )),
        Err(e) => Err(Error::Auth(format!("{e:?}"))),
    }
}

// ── GCS JSON shapes ─────────────────────────────────────────────────────────────

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct GcsObject {
    name: String,
    #[serde(default)]
    size: Option<String>,
    #[serde(default)]
    updated: Option<String>,
    #[serde(default)]
    etag: Option<String>,
    #[serde(default)]
    content_type: Option<String>,
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct GcsListing {
    #[serde(default)]
    items: Vec<GcsObject>,
    #[serde(default)]
    prefixes: Vec<String>,
    #[serde(default)]
    next_page_token: Option<String>,
}

/// RFC 3339 → unix seconds.
///
/// Hand-rolled because a date crate is a surprising amount of a small module's compiled size,
/// and the shape is fixed: GCS emits `2026-08-20T14:03:11.123Z`, always UTC, always this
/// layout. Anything else yields `None`, which the interface already allows.
fn rfc3339_secs(s: &str) -> Option<u64> {
    let b = s.as_bytes();
    if b.len() < 19 || b[4] != b'-' || b[7] != b'-' || b[10] != b'T' {
        return None;
    }
    let n = |from: usize, to: usize| s[from..to].parse::<i64>().ok();
    let (y, mo, d) = (n(0, 4)?, n(5, 7)?, n(8, 10)?);
    let (h, mi, sec) = (n(11, 13)?, n(14, 16)?, n(17, 19)?);
    // Days since the epoch, by the civil-from-days algorithm (Howard Hinnant's). Correct for
    // every proleptic Gregorian date, which is more than enough for an object's mtime.
    let y_adj = if mo <= 2 { y - 1 } else { y };
    let era = if y_adj >= 0 { y_adj } else { y_adj - 399 } / 400;
    let yoe = y_adj - era * 400;
    let mp = (mo + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    let total = days * 86_400 + h * 3_600 + mi * 60 + sec;
    u64::try_from(total).ok()
}

fn to_object(o: GcsObject) -> Object {
    Object {
        key: o.name,
        prefix: false,
        size: o.size.and_then(|s| s.parse().ok()).unwrap_or(0),
        modified: o.updated.as_deref().and_then(rfc3339_secs),
        etag: o.etag,
        content_type: o.content_type,
    }
}

/// A synthesised folder row.
///
/// Object stores have no directories. GCS reports `prefixes` when a delimiter is set, and
/// those are the rows the explorer draws as folders — they have no size and no mtime, and
/// pretending otherwise would put a fabricated date in a column the user reads.
fn to_prefix(p: String) -> Object {
    Object {
        key: p,
        prefix: true,
        size: 0,
        modified: None,
        etag: None,
        content_type: None,
    }
}

// ── The exported resource ───────────────────────────────────────────────────────

struct Connection {
    bucket: String,
}

impl GuestConnection for Connection {
    fn open(bucket: String, config: String) -> Result<ConnectionHandle, Error> {
        if bucket.trim().is_empty() {
            return Err(Error::Config("no bucket name".into()));
        }
        // The config is this provider's own JSON, and GCS needs nothing from it beyond the
        // bucket today. Parsed anyway so a malformed one fails at connect time rather than at
        // the first listing, when the user has stopped associating it with what they typed.
        if !config.trim().is_empty() {
            serde_json::from_str::<serde_json::Value>(&config)
                .map_err(|e| Error::Config(format!("connection config is not JSON: {e}")))?;
        }
        arbor::extensions::log::write(Level::Info, &format!("gcs: opened bucket '{bucket}'"));
        Ok(ConnectionHandle::new(Connection { bucket }))
    }

    /// A zero-length listing: cheap, side-effect free, and it exercises exactly the two things
    /// that go wrong — the token and the bucket's existence.
    fn test(&self) -> Result<(), Error> {
        let t = token()?;
        call(
            "GET",
            format!("{API}/b/{}/o?maxResults=0", enc(&self.bucket)),
            &t,
            vec![],
            None,
        )?;
        Ok(())
    }

    fn list(
        &self,
        prefix: String,
        delimiter: Option<String>,
        cursor: Option<String>,
        limit: Option<u32>,
    ) -> Result<Listing, Error> {
        let t = token()?;
        let mut url = format!("{API}/b/{}/o?", enc(&self.bucket));
        if !prefix.is_empty() {
            url.push_str(&format!("prefix={}&", enc_query(&prefix)));
        }
        if let Some(d) = &delimiter {
            url.push_str(&format!("delimiter={}&", enc_query(d)));
        }
        if let Some(c) = &cursor {
            url.push_str(&format!("pageToken={}&", enc_query(c)));
        }
        url.push_str(&format!("maxResults={}", limit.unwrap_or(1000).min(1000)));

        let body = call("GET", url, &t, vec![], None)?;
        let parsed: GcsListing = serde_json::from_slice(&body)
            .map_err(|e| Error::Remote((None, format!("listing is not the expected JSON: {e}"))))?;

        // Prefixes first: a file browser puts folders above files, and doing it here means
        // every caller gets the same order without sorting a thousand rows again.
        let mut entries: Vec<Object> = parsed.prefixes.into_iter().map(to_prefix).collect();
        entries.extend(parsed.items.into_iter().map(to_object));

        Ok(Listing { entries, cursor: parsed.next_page_token })
    }

    fn stat(&self, key: String) -> Result<Object, Error> {
        let t = token()?;
        let body = call(
            "GET",
            format!("{API}/b/{}/o/{}", enc(&self.bucket), enc(&key)),
            &t,
            vec![],
            None,
        )?;
        let o: GcsObject = serde_json::from_slice(&body)
            .map_err(|e| Error::Remote((None, format!("object metadata is not JSON: {e}"))))?;
        Ok(to_object(o))
    }

    fn read(&self, key: String, part: Option<Range>) -> Result<Vec<u8>, Error> {
        let t = token()?;
        let mut extra = Vec::new();
        if let Some(r) = part {
            // HTTP ranges are inclusive on both ends; the interface's `end` is exclusive, so
            // the conversion is a subtraction — and an empty range would ask for byte -1.
            let value = match r.end {
                Some(end) if end > r.start => format!("bytes={}-{}", r.start, end - 1),
                Some(_) => return Ok(Vec::new()),
                None => format!("bytes={}-", r.start),
            };
            extra.push(header("range", value));
        }
        match call(
            "GET",
            format!("{API}/b/{}/o/{}?alt=media", enc(&self.bucket), enc(&key)),
            &t,
            extra,
            None,
        ) {
            Ok(bytes) => Ok(bytes),
            // A range that starts past the end of the object is zero bytes, and saying so is
            // the only reading consistent with "may return fewer at the end". The host chunks
            // a download by asking for successive ranges, and a store whose reported size was
            // stale would otherwise end a finished transfer with a 416 instead of an EOF.
            Err(Error::Remote((Some(416), _))) => Ok(Vec::new()),
            Err(e) => Err(e),
        }
    }

    fn write(
        &self,
        key: String,
        body: Vec<u8>,
        content_type: Option<String>,
    ) -> Result<(), Error> {
        let t = token()?;
        let ct = content_type.unwrap_or_else(|| "application/octet-stream".to_string());
        call(
            "POST",
            format!(
                "{UPLOAD}/b/{}/o?uploadType=media&name={}",
                enc(&self.bucket),
                enc_query(&key)
            ),
            &t,
            vec![header("content-type", ct)],
            Some(body),
        )?;
        Ok(())
    }

    fn delete(&self, key: String) -> Result<(), Error> {
        let t = token()?;
        match call(
            "DELETE",
            format!("{API}/b/{}/o/{}", enc(&self.bucket), enc(&key)),
            &t,
            vec![],
            None,
        ) {
            Ok(_) => Ok(()),
            // The interface says removing something absent succeeds: the caller asked for it
            // to be gone, and it is.
            Err(Error::NotFound(_)) => Ok(()),
            Err(e) => Err(e),
        }
    }

    fn copy(&self, source: String, destination: String) -> Result<(), Error> {
        let t = token()?;
        // Server-side, so the bytes never travel through this machine — which for a
        // multi-gigabyte object is the difference between instant and a download plus an
        // upload.
        call(
            "POST",
            format!(
                "{API}/b/{b}/o/{f}/copyTo/b/{b}/o/{t2}",
                b = enc(&self.bucket),
                f = enc(&source),
                t2 = enc(&destination)
            ),
            &t,
            vec![header("content-length", "0".into())],
            None,
        )?;
        Ok(())
    }
}

struct Provider;

impl Guest for Provider {
    type Connection = Connection;
}

export!(Provider);

#[cfg(test)]
mod tests {
    use super::{enc, rfc3339_secs};

    #[test]
    fn a_key_with_slashes_is_encoded_whole() {
        // The bug this prevents: `a/b.txt` is ONE key, and leaving the slash raw turns a stat
        // into a request for `b.txt` inside a bucket path that does not exist — so the 404
        // blames the object instead of the URL.
        assert_eq!(enc("a/b.txt"), "a%2Fb.txt");
        assert_eq!(enc("plain.txt"), "plain.txt");
        assert_eq!(enc("with space"), "with%20space");
        assert_eq!(enc("uni\u{00e0}"), "uni%C3%A0");
    }

    #[test]
    fn unreserved_characters_survive_untouched() {
        assert_eq!(enc("a-b_c.d~e09"), "a-b_c.d~e09");
    }

    #[test]
    fn a_gcs_timestamp_becomes_unix_seconds() {
        // 2026-08-20T14:03:11Z. Checked against a known value rather than a round trip, so a
        // wrong-but-self-consistent implementation cannot pass.
        assert_eq!(rfc3339_secs("2026-08-20T14:03:11.123Z"), Some(1_787_234_591));
        assert_eq!(rfc3339_secs("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(rfc3339_secs("2000-03-01T00:00:00Z"), Some(951_868_800));
    }

    #[test]
    fn a_leap_day_is_not_off_by_one() {
        // The civil-from-days algorithm shifts the year in January and February; getting that
        // wrong is invisible for ten months of the year.
        assert_eq!(rfc3339_secs("2024-02-29T00:00:00Z"), Some(1_709_164_800));
        assert_eq!(rfc3339_secs("2024-03-01T00:00:00Z"), Some(1_709_251_200));
    }

    #[test]
    fn anything_that_is_not_that_shape_yields_nothing() {
        // The interface allows `none`, so a surprise format is a missing column and not a
        // fabricated date.
        assert_eq!(rfc3339_secs(""), None);
        assert_eq!(rfc3339_secs("yesterday"), None);
        assert_eq!(rfc3339_secs("2026/08/20 14:03:11"), None);
    }
}
