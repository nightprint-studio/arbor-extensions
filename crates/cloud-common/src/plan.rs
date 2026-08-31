//! Cutting a large object into calls.
//!
//! A provider answers with bytes, so a transfer is the caller asking repeatedly for slices it
//! can hold. This decides the slices. It is three lines of arithmetic and it is here because
//! the three lines were about to be written in Lua, in the provider, and in the panel — and
//! an off-by-one in any of them corrupts a file rather than failing.

use serde::{Deserialize, Serialize};

/// A half-open byte range: `start` included, `end` excluded — the same convention the WIT
/// interface uses, so a range crosses without a conversion nobody remembers to make.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct ByteRange {
    pub start: u64,
    pub end: u64,
}

impl ByteRange {
    pub fn len(&self) -> u64 {
        self.end.saturating_sub(self.start)
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

/// Split `size` bytes into consecutive ranges of at most `chunk`.
///
/// The last range is short rather than padded, an empty object plans nothing at all, and a
/// `chunk` of zero is treated as "one whole range" instead of dividing by zero — a caller that
/// forgot to set it gets a working single-shot transfer, not a panic in a background job.
pub fn plan_ranges(size: u64, chunk: u64) -> Vec<ByteRange> {
    if size == 0 {
        return Vec::new();
    }
    let step = if chunk == 0 { size } else { chunk };
    let mut out = Vec::new();
    let mut at = 0u64;
    while at < size {
        let end = at.saturating_add(step).min(size);
        out.push(ByteRange { start: at, end });
        at = end;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_exact_multiple_has_no_short_tail() {
        let r = plan_ranges(300, 100);
        assert_eq!(r.len(), 3);
        assert_eq!(r[2], ByteRange { start: 200, end: 300 });
    }

    #[test]
    fn the_last_range_is_short_rather_than_past_the_end() {
        // Reading past the end is the bug that shows up as a 416 from the store, or as a file
        // with trailing garbage if the store is lenient.
        let r = plan_ranges(250, 100);
        assert_eq!(r.last().copied(), Some(ByteRange { start: 200, end: 250 }));
        assert_eq!(r.iter().map(|x| x.len()).sum::<u64>(), 250);
    }

    #[test]
    fn ranges_are_contiguous_and_cover_everything() {
        let r = plan_ranges(1000, 128);
        assert_eq!(r[0].start, 0);
        assert_eq!(r.last().unwrap().end, 1000);
        for pair in r.windows(2) {
            assert_eq!(pair[0].end, pair[1].start);
        }
    }

    #[test]
    fn an_empty_object_plans_nothing() {
        // Not one empty range: a caller looping over this would otherwise make a pointless
        // request and append zero bytes, which reads as a stall on a file of size zero.
        assert!(plan_ranges(0, 100).is_empty());
    }

    #[test]
    fn a_missing_chunk_size_means_one_whole_range() {
        assert_eq!(plan_ranges(500, 0), vec![ByteRange { start: 0, end: 500 }]);
    }

    #[test]
    fn a_chunk_bigger_than_the_object_is_one_range() {
        assert_eq!(plan_ranges(10, 1024), vec![ByteRange { start: 0, end: 10 }]);
    }
}
