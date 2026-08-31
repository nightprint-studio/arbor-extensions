//! Putting split files back in the order they were split in.
//!
//! A large upload arrives as `backup.tar.part1 … part10`, or as a set of timestamped exports.
//! Concatenating them in the order the store listed them produces a corrupt file — stores list
//! lexicographically, and lexicographically `part10` comes before `part2`.
//!
//! So there are two orders worth having, and neither is the store's:
//!
//! · **Natural** — digits inside a name compare as numbers. `part2` before `part10`.
//! · **By date** — the store's `modified`, for exports whose names carry no sequence.

use serde::{Deserialize, Serialize};

/// One candidate part, as little of it as the ordering needs.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Chunk {
    pub key: String,
    /// Unix seconds, when the store reported one.
    #[serde(default)]
    pub modified: Option<u64>,
}

/// Which order to put them in.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ChunkOrder {
    /// Digits compare as numbers — what a `partN` sequence needs.
    Natural,
    /// Oldest first, by the store's `modified`. Parts with no date keep their relative
    /// position at the end rather than being dropped or sorted as epoch zero.
    Date,
}

/// Order the parts. Stable: equal keys keep the order they arrived in, so a caller that
/// pre-sorted for its own reasons is not undone.
pub fn order_chunks(mut chunks: Vec<Chunk>, order: ChunkOrder) -> Vec<Chunk> {
    match order {
        ChunkOrder::Natural => chunks.sort_by(|a, b| natural_cmp(&a.key, &b.key)),
        ChunkOrder::Date => chunks.sort_by(|a, b| match (a.modified, b.modified) {
            (Some(x), Some(y)) => x.cmp(&y),
            // A part with no date sorts after every dated one, and the dateless keep their own
            // arrival order. Treating "unknown" as 1970 would silently put it first, which for
            // a concatenation is the one position where being wrong destroys the output.
            (Some(_), None) => std::cmp::Ordering::Less,
            (None, Some(_)) => std::cmp::Ordering::Greater,
            (None, None) => std::cmp::Ordering::Equal,
        }),
    }
    chunks
}

/// Compare two names with digit runs read as numbers.
fn natural_cmp(a: &str, b: &str) -> std::cmp::Ordering {
    let (ab, bb) = (a.as_bytes(), b.as_bytes());
    let (mut i, mut j) = (0usize, 0usize);
    while i < ab.len() && j < bb.len() {
        if ab[i].is_ascii_digit() && bb[j].is_ascii_digit() {
            let (na, ni) = number_at(ab, i);
            let (nb, nj) = number_at(bb, j);
            if na != nb {
                return na.cmp(&nb);
            }
            i = ni;
            j = nj;
            continue;
        }
        if ab[i] != bb[j] {
            return ab[i].cmp(&bb[j]);
        }
        i += 1;
        j += 1;
    }
    (ab.len() - i).cmp(&(bb.len() - j))
}

/// The number starting at `from`, and where it ends. Saturating, because a run of sixty digits
/// is a filename somebody built, not an integer anybody meant.
fn number_at(s: &[u8], from: usize) -> (u128, usize) {
    let mut n: u128 = 0;
    let mut i = from;
    while i < s.len() && s[i].is_ascii_digit() {
        n = n.saturating_mul(10).saturating_add((s[i] - b'0') as u128);
        i += 1;
    }
    (n, i)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn c(key: &str, modified: Option<u64>) -> Chunk {
        Chunk { key: key.to_string(), modified }
    }

    #[test]
    fn part_ten_comes_after_part_two() {
        // The whole reason this module exists: the store's own order concatenates the file
        // wrong, and the result is a corrupt archive rather than an error.
        let out = order_chunks(
            vec![c("b.part10", None), c("b.part2", None), c("b.part1", None)],
            ChunkOrder::Natural,
        );
        let keys: Vec<_> = out.iter().map(|x| x.key.as_str()).collect();
        assert_eq!(keys, ["b.part1", "b.part2", "b.part10"]);
    }

    #[test]
    fn leading_zeros_do_not_change_the_number() {
        let out = order_chunks(
            vec![c("x-007", None), c("x-8", None), c("x-06", None)],
            ChunkOrder::Natural,
        );
        let keys: Vec<_> = out.iter().map(|x| x.key.as_str()).collect();
        assert_eq!(keys, ["x-06", "x-007", "x-8"]);
    }

    #[test]
    fn a_very_long_digit_run_does_not_wrap() {
        // Saturating rather than overflowing: a sixty-digit "number" in a filename must not
        // compare as whatever it wrapped to.
        let long = format!("f{}", "9".repeat(60));
        let out = order_chunks(vec![c(&long, None), c("f1", None)], ChunkOrder::Natural);
        assert_eq!(out[0].key, "f1");
    }

    #[test]
    fn by_date_is_oldest_first() {
        let out = order_chunks(
            vec![c("c", Some(300)), c("a", Some(100)), c("b", Some(200))],
            ChunkOrder::Date,
        );
        let keys: Vec<_> = out.iter().map(|x| x.key.as_str()).collect();
        assert_eq!(keys, ["a", "b", "c"]);
    }

    #[test]
    fn a_part_with_no_date_goes_last_rather_than_first() {
        // Sorting "unknown" as epoch zero would put it at the front of a concatenation, which
        // is the one place where a wrong guess produces a broken file instead of a wrong list.
        let out = order_chunks(
            vec![c("nodate", None), c("dated", Some(100))],
            ChunkOrder::Date,
        );
        assert_eq!(out[0].key, "dated");
        assert_eq!(out[1].key, "nodate");
    }
}
