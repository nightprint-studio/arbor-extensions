//! The one timestamp format every object store answers in.
//!
//! Hand-rolled rather than pulled from a date crate: a guest module travels over the network
//! on install, and a calendar library is a surprising share of a small component's size for a
//! shape that is fixed — `2026-08-20T14:03:11.123Z`, always UTC, always this layout.

/// RFC 3339 (UTC) → unix seconds. `None` for anything that is not that shape.
///
/// `None` rather than a guess, because the interface allows a missing timestamp: a column left
/// empty is honest, and a fabricated date is what makes a sync copy the wrong files.
pub fn rfc3339_secs(s: &str) -> Option<u64> {
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_store_timestamp_becomes_unix_seconds() {
        // Checked against known values rather than a round trip, so a wrong-but-self-consistent
        // implementation cannot pass.
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
        assert_eq!(rfc3339_secs(""), None);
        assert_eq!(rfc3339_secs("yesterday"), None);
        assert_eq!(rfc3339_secs("2026/08/20 14:03:11"), None);
    }
}
