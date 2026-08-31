//! Wildcard matching over keys.
//!
//! The panel's remote search takes a pattern and the store takes a prefix, so the filtering is
//! the caller's either way. Three wildcards, and the third is the one that matters:
//!
//! · `?`  — one character, never the separator.
//! · `*`  — any run of characters, never the separator: `logs/*.txt` stays in `logs/`.
//! · `**` — any run at all, separators included: `logs/**/*.txt` reaches every depth.
//!
//! Keeping `*` out of the separator is what makes the two distinguishable, and it is the
//! behaviour every shell and every editor's file filter already has — a search that quietly
//! descended would return a thousand rows from folders the user was not looking at.

/// Whether `key` matches `pattern`.
///
/// Iterative with one backtrack point, rather than recursive: a key is arbitrary user input
/// and a pattern like `**a**b**c` on a long key is where a naive recursion goes exponential.
pub fn glob_match(pattern: &str, key: &str) -> bool {
    let p: Vec<char> = pattern.chars().collect();
    let k: Vec<char> = key.chars().collect();

    let (mut pi, mut ki) = (0usize, 0usize);
    // The last `*`/`**` seen, and where in the key it had matched up to. Backtracking means
    // "let that star eat one more character and try again".
    let mut star: Option<(usize, usize, bool)> = None; // (pattern index after star, key index, crosses_separator)

    while ki < k.len() {
        if pi < p.len() && p[pi] == '*' {
            let double = pi + 1 < p.len() && p[pi + 1] == '*';
            pi += if double { 2 } else { 1 };
            star = Some((pi, ki, double));
            continue;
        }
        if pi < p.len() && (p[pi] == '?' && k[ki] != '/') {
            pi += 1;
            ki += 1;
            continue;
        }
        if pi < p.len() && p[pi] == k[ki] {
            pi += 1;
            ki += 1;
            continue;
        }
        match star {
            // A single star may not consume the separator; a double one may. Without this the
            // two wildcards are the same wildcard.
            Some((after, at, double)) if double || k[at] != '/' => {
                pi = after;
                ki = at + 1;
                star = Some((after, at + 1, double));
            }
            _ => return false,
        }
    }

    // Trailing stars match the empty remainder.
    while pi < p.len() && p[pi] == '*' {
        pi += 1;
    }
    pi == p.len()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_star_stays_inside_one_level() {
        assert!(glob_match("logs/*.txt", "logs/app.txt"));
        // The one this exists for: a search in `logs/` must not return the contents of every
        // folder under it, which is what a star crossing the separator would do.
        assert!(!glob_match("logs/*.txt", "logs/2026/app.txt"));
    }

    #[test]
    fn a_double_star_crosses_levels() {
        assert!(glob_match("logs/**/*.txt", "logs/2026/08/app.txt"));
        assert!(glob_match("**/*.txt", "a/b/c/d.txt"));
        assert!(glob_match("**", "anything/at/all"));
    }

    #[test]
    fn a_question_mark_is_one_character_and_not_the_separator() {
        assert!(glob_match("app-?.log", "app-1.log"));
        assert!(!glob_match("app-?.log", "app-10.log"));
        assert!(!glob_match("a?b", "a/b"));
    }

    #[test]
    fn a_pattern_with_no_wildcards_is_an_equality_test() {
        assert!(glob_match("logs/app.txt", "logs/app.txt"));
        assert!(!glob_match("logs/app.txt", "logs/app.txt.bak"));
    }

    #[test]
    fn backtracking_finds_the_match_that_a_greedy_star_would_miss() {
        // The classic: the first star must give a character back for `.txt` to land.
        assert!(glob_match("*.txt", "a.b.txt"));
        assert!(glob_match("a*c*e", "abcde"));
        assert!(!glob_match("a*c*x", "abcde"));
    }

    #[test]
    fn a_pathological_pattern_still_returns() {
        // Not a correctness claim — a timing one. A recursive matcher takes exponential time
        // on this shape, and the input is a key from a bucket nobody controls.
        let key = "a".repeat(64);
        assert!(!glob_match("**a**b**c**d", &key));
    }
}
