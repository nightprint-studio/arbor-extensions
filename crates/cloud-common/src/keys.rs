//! Object keys: they look like paths and are not.
//!
//! `a/b/c.txt` is ONE key with slashes in it, not three path segments. Every function here
//! exists because treating it as a path breaks something specific, and the breakage is always
//! at the far end where nobody can see the cause.

/// Percent-encode one URL path segment, slashes included.
///
/// The bug this prevents: a key with a `/` left raw turns `stat("a/b.txt")` into a request for
/// `b.txt` inside something that does not exist, and the store answers 404 — blaming the
/// object rather than the URL that was built wrong.
pub fn encode_segment(s: &str) -> String {
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

/// Split a key into its prefix (with trailing `/`) and its final component.
///
/// The prefix keeps its slash because that is what a store's `prefix=` parameter wants — the
/// version without it lists the sibling `foo-2/` as well, which is a listing that quietly
/// contains the wrong bucket contents.
pub fn split_key(key: &str) -> (String, String) {
    match key.rfind('/') {
        Some(i) => (key[..=i].to_string(), key[i + 1..].to_string()),
        None => (String::new(), key.to_string()),
    }
}

/// The final component of a key — what a file browser shows in the name column.
pub fn name_of(key: &str) -> String {
    split_key(key).1
}

/// The prefix one level up, for a breadcrumb's parent link.
///
/// A trailing slash is ignored first, so the parent of `a/b/` is `a/` and not `a/b/` again —
/// which is the difference between a breadcrumb that walks up and one that does nothing.
pub fn parent_prefix(prefix: &str) -> String {
    let trimmed = prefix.strip_suffix('/').unwrap_or(prefix);
    match trimmed.rfind('/') {
        Some(i) => trimmed[..=i].to_string(),
        None => String::new(),
    }
}

/// Join a prefix and a name into a key, without doubling or dropping the separator.
pub fn join_key(prefix: &str, name: &str) -> String {
    if prefix.is_empty() {
        return name.trim_start_matches('/').to_string();
    }
    let left = prefix.trim_end_matches('/');
    let right = name.trim_start_matches('/');
    if right.is_empty() {
        return format!("{left}/");
    }
    format!("{left}/{right}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_key_with_slashes_is_encoded_whole() {
        assert_eq!(encode_segment("a/b.txt"), "a%2Fb.txt");
        assert_eq!(encode_segment("plain.txt"), "plain.txt");
        assert_eq!(encode_segment("with space"), "with%20space");
        assert_eq!(encode_segment("uni\u{00e0}"), "uni%C3%A0");
    }

    #[test]
    fn unreserved_characters_survive_untouched() {
        assert_eq!(encode_segment("a-b_c.d~e09"), "a-b_c.d~e09");
    }

    #[test]
    fn a_key_splits_into_a_prefix_that_still_ends_in_a_slash() {
        // Without the trailing slash, `prefix=logs` also lists `logs-archive/`.
        assert_eq!(split_key("logs/2026/app.log"), ("logs/2026/".into(), "app.log".into()));
        assert_eq!(split_key("top.txt"), ("".into(), "top.txt".into()));
    }

    #[test]
    fn the_parent_of_a_folder_is_one_level_up_and_not_itself() {
        assert_eq!(parent_prefix("a/b/"), "a/");
        assert_eq!(parent_prefix("a/b"), "a/");
        assert_eq!(parent_prefix("a/"), "");
        assert_eq!(parent_prefix(""), "");
    }

    #[test]
    fn joining_never_doubles_or_drops_the_separator() {
        assert_eq!(join_key("a/b/", "c.txt"), "a/b/c.txt");
        assert_eq!(join_key("a/b", "c.txt"), "a/b/c.txt");
        assert_eq!(join_key("a/b/", "/c.txt"), "a/b/c.txt");
        assert_eq!(join_key("", "c.txt"), "c.txt");
        assert_eq!(join_key("a/b", ""), "a/b/");
    }
}
