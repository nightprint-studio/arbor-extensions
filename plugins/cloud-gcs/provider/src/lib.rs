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

use exports::arbor::extensions::cloud_provider::Guest;
use arbor::extensions::cloud_types::{Error, Listing, Object, Range, Target, Token};
use arbor::extensions::http::{Header, Request};
use arbor::extensions::log::Level;

// The shared half, linked rather than copied. `encode_segment` is the one that bites: a key
// with a raw `/` turns `stat("a/b.txt")` into a request for something that does not exist,
// and the store's 404 blames the object instead of the URL. Tested once, in `cloud-common`,
// and used by every provider and by the toolkit the panel calls.
use cloud_common::prelude::{
    assertion, assertion_form, encode_segment as enc, rfc3339_secs, ServiceAccount,
};

const API: &str = "https://storage.googleapis.com/storage/v1";
const UPLOAD: &str = "https://storage.googleapis.com/upload/storage/v1";
/// The key this package declared in `[[credentials]]`. Asking for any other name is refused
/// by the host, so this constant is the whole of what this component can reach.
const TOKEN_KEY: &str = "oauth";
/// What a minted token is asked to cover. The same scope the interactive sign-in requests, so
/// a connection behaves identically whichever way it authenticated.
const SCOPE: &str = "https://www.googleapis.com/auth/devstorage.read_write";

// ── Small helpers ───────────────────────────────────────────────────────────────

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

// ── The exported interface ──────────────────────────────────────────────────────
//
// Whole calls: each one carries the target it acts on. There is no connection to open, which
// is what makes this callable from Lua through `arbor.ext.call` — see the interface's own doc
// for why a resource made this package reachable only by Arbor.

/// Validate the target and hand back the bucket to build URLs from.
///
/// The config is this provider's own JSON, and GCS needs nothing from it beyond the bucket
/// today. Parsed anyway so a malformed one fails as a config error naming itself, rather than
/// as a listing that returns nothing for a reason the user cannot see.
fn target(at: &Target) -> Result<&str, Error> {
    let bucket = at.bucket.trim();
    if bucket.is_empty() {
        return Err(Error::Config("no bucket name".into()));
    }
    if !at.config.trim().is_empty() {
        serde_json::from_str::<serde_json::Value>(&at.config)
            .map_err(|e| Error::Config(format!("connection config is not JSON: {e}")))?;
    }
    Ok(bucket)
}

struct Provider;

impl Guest for Provider {
    /// A zero-length listing: cheap, side-effect free, and it exercises exactly the two things
    /// that go wrong — the token and the bucket's existence.
    fn test(at: Target) -> Result<(), Error> {
        let bucket = target(&at)?;
        let t = token()?;
        call("GET", format!("{API}/b/{}/o?maxResults=0", enc(bucket)), &t, vec![], None)?;
        arbor::extensions::log::write(Level::Info, &format!("gcs: '{bucket}' answered"));
        Ok(())
    }

    fn list(
        at: Target,
        prefix: String,
        delimiter: Option<String>,
        cursor: Option<String>,
        limit: Option<u32>,
    ) -> Result<Listing, Error> {
        let bucket = target(&at)?;
        let t = token()?;
        let mut url = format!("{API}/b/{}/o?", enc(bucket));
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

    fn stat(at: Target, key: String) -> Result<Object, Error> {
        let bucket = target(&at)?;
        let t = token()?;
        let body = call(
            "GET",
            format!("{API}/b/{}/o/{}", enc(bucket), enc(&key)),
            &t,
            vec![],
            None,
        )?;
        let o: GcsObject = serde_json::from_slice(&body)
            .map_err(|e| Error::Remote((None, format!("object metadata is not JSON: {e}"))))?;
        Ok(to_object(o))
    }

    fn read(at: Target, key: String, part: Option<Range>) -> Result<Vec<u8>, Error> {
        let bucket = target(&at)?;
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
            format!("{API}/b/{}/o/{}?alt=media", enc(bucket), enc(&key)),
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
        at: Target,
        key: String,
        body: Vec<u8>,
        content_type: Option<String>,
    ) -> Result<(), Error> {
        let bucket = target(&at)?;
        let t = token()?;
        let ct = content_type.unwrap_or_else(|| "application/octet-stream".to_string());
        call(
            "POST",
            format!(
                "{UPLOAD}/b/{}/o?uploadType=media&name={}",
                enc(bucket),
                enc_query(&key)
            ),
            &t,
            vec![header("content-type", ct)],
            Some(body),
        )?;
        Ok(())
    }

    fn delete(at: Target, key: String) -> Result<(), Error> {
        let bucket = target(&at)?;
        let t = token()?;
        match call(
            "DELETE",
            format!("{API}/b/{}/o/{}", enc(bucket), enc(&key)),
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

    /// A service-account key in, an access token out.
    ///
    /// Two steps and no state: sign an assertion with the key, post it to the token endpoint.
    /// The caller stores what comes back — this guest is instantiated per call and could not
    /// keep it if it wanted to.
    fn mint_token(credential: String, scope: String, now_secs: u64) -> Result<Token, Error> {
        let sa: ServiceAccount = serde_json::from_str(&credential).map_err(|e| {
            Error::Config(format!("this is not a Google service-account key file: {e}"))
        })?;

        arbor::extensions::log::write(Level::Debug, "gcs: minting an access token");

        // The time comes from the caller: a guest has no clock, and this is the one field that
        // needs one.
        let jwt = assertion(&sa, if scope.is_empty() { SCOPE } else { &scope }, now_secs)
            .map_err(Error::Auth)?;

        let req = Request {
            method: "POST".to_string(),
            url: sa.token_uri.clone(),
            headers: vec![header("content-type", "application/x-www-form-urlencoded".into())],
            body: Some(assertion_form(&jwt).into_bytes()),
            timeout_secs: Some(30),
        };
        let res = arbor::extensions::http::send(&req).map_err(|e| match e {
            arbor::extensions::http::Error::NotAllowed(h) => Error::Transport(format!(
                "'{h}' is not in this package's network allowlist"
            )),
            arbor::extensions::http::Error::Transport(m) => Error::Transport(m),
            arbor::extensions::http::Error::Invalid(m) => Error::Config(m),
        })?;
        if res.status >= 400 {
            // The endpoint's own words: an unauthorized_client here means the key is real and
            // the account is not entitled, which is a different fix from a malformed key.
            return Err(Error::Auth(format!(
                "the token endpoint refused the assertion ({}): {}",
                res.status,
                String::from_utf8_lossy(&res.body).chars().take(300).collect::<String>()
            )));
        }

        #[derive(serde::Deserialize)]
        struct TokenResponse {
            access_token: String,
            #[serde(default)]
            expires_in: Option<u64>,
        }
        let parsed: TokenResponse = serde_json::from_slice(&res.body).map_err(|e| {
            Error::Remote((None, format!("the token response is not the expected JSON: {e}")))
        })?;

        Ok(Token {
            access_token: parsed.access_token,
            // An hour is what Google issues and what every other endpoint of theirs assumes;
            // a response without the field is not a token that lasts forever.
            expires_in: parsed.expires_in.unwrap_or(3600),
        })
    }

    fn copy(at: Target, source: String, destination: String) -> Result<(), Error> {
        let bucket = target(&at)?;
        let t = token()?;
        // Server-side, so the bytes never travel through this machine — which for a
        // multi-gigabyte object is the difference between instant and a download plus an
        // upload.
        call(
            "POST",
            format!(
                "{API}/b/{b}/o/{f}/copyTo/b/{b}/o/{t2}",
                b = enc(bucket),
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

export!(Provider);

#[cfg(test)]
mod tests {
    // The key encoder and the timestamp parser are tested where they live now
    // (`cloud-common`), which is also where every other provider gets them. What is left here
    // is this provider's own translation of the GCS JSON shapes, and it needs a listing
    // fixture rather than a unit test — see the package's doc for the manual check.
}
