//! What a sync would actually do, worked out before anything is transferred.
//!
//! The decision — copy this, skip that, delete the other — is the whole of a sync; the
//! transfers are just doing it. Separating them buys two things that matter more than the
//! tidiness: the plan can be **shown to the user** before a thousand files move, and it can be
//! **tested**, which a loop that lists and copies in one pass cannot.
//!
//! ## Comparing without hashing
//!
//! Nothing here reads a file's contents. A remote object and a local file are "the same" when
//! the policy says so, out of the three facts both sides always have: size, modification time,
//! and (remotely) an etag. An etag is only comparable to a *previously recorded* one, never to
//! a local file, so it earns a policy of its own rather than being silently ignored.
//!
//! Times are compared with a **two-second slack**. Not superstition: FAT and several object
//! stores keep whole seconds, some keep two, and without slack a file copied a moment ago
//! compares as newer than itself and the next sync copies it again, forever.

use serde::{Deserialize, Serialize};

/// An object in the bucket.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RemoteEntry {
    pub key: String,
    #[serde(default)]
    pub size: u64,
    /// Unix seconds, when the store reports one.
    #[serde(default)]
    pub modified: Option<u64>,
    #[serde(default)]
    pub etag: Option<String>,
}

/// A file on this machine, named RELATIVE to the sync root — so the two sides can be compared
/// at all. Turning that back into a path is the caller's, and it is the one part of a sync
/// that is genuinely about this machine.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LocalEntry {
    pub key: String,
    #[serde(default)]
    pub size: u64,
    #[serde(default)]
    pub modified: Option<u64>,
    /// The etag recorded the last time this file was transferred, when the caller kept one.
    #[serde(default)]
    pub etag: Option<String>,
}

/// When an entry that exists on both sides should be transferred anyway.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Overwrite {
    /// Transfer every time. Correct and expensive; the honest choice when neither side keeps
    /// a usable timestamp.
    Always,
    /// Transfer when the source is newer than the destination (with slack).
    IfNewer,
    /// Transfer when the sizes differ. Cheap, and blind to an edit that kept the length.
    IfDifferentSize,
    /// Transfer when the recorded etag differs from the store's. The most accurate, and only
    /// available for entries the caller has an etag for.
    IfDifferentEtag,
    /// Never — additive sync: new files only.
    Never,
}

/// The rules for one sync.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct SyncPolicy {
    pub overwrite: Overwrite,
    /// Remove entries at the destination that the source no longer has. Off by default in
    /// every caller that has asked so far, because it is the setting that loses data when the
    /// source listing was partial.
    #[serde(default)]
    pub delete_extraneous: bool,
}

/// What to do with one entry.
///
/// `reason` is an owned `String` rather than the `&'static str` the literals would suggest:
/// a plan is meant to be serialised — shown to the user, sent across the extension boundary —
/// and a borrowed field makes `Deserialize` require the input to outlive `'static`, which
/// nothing does.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "kebab-case")]
pub enum SyncAction {
    /// Not at the destination: copy it.
    Create { key: String, size: u64 },
    /// At both, and the policy says to copy it again.
    Update { key: String, size: u64, reason: String },
    /// At both, and it is already current.
    Skip { key: String, reason: String },
    /// At the destination and not at the source.
    Delete { key: String },
}

/// The whole answer, ready to show or to execute.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct SyncPlan {
    pub actions: Vec<SyncAction>,
    /// Bytes the transfers would move — what a progress bar needs before it starts.
    pub bytes: u64,
}

/// Seconds of slack when comparing modification times. See the module doc: without it, a file
/// is copied again on every run, forever.
const SLACK: u64 = 2;

fn newer(source: Option<u64>, dest: Option<u64>) -> bool {
    match (source, dest) {
        (Some(s), Some(d)) => s > d.saturating_add(SLACK),
        // A source with no time cannot be shown to be newer, and a destination with no time
        // cannot be shown to be current. The second is the safe direction: copy.
        (Some(_), None) => true,
        (None, _) => false,
    }
}

/// Plan a download: bucket → disk. `remote` is the source, `local` the destination.
///
/// Both sides are keyed the same way (relative keys), which is what makes the comparison
/// possible at all — and is why `LocalEntry.key` is documented as relative rather than as a
/// path.
pub fn sync_plan(remote: &[RemoteEntry], local: &[LocalEntry], policy: SyncPolicy) -> SyncPlan {
    let mut plan = SyncPlan::default();

    for r in remote {
        let Some(l) = local.iter().find(|l| l.key == r.key) else {
            plan.actions.push(SyncAction::Create { key: r.key.clone(), size: r.size });
            plan.bytes += r.size;
            continue;
        };
        let (transfer, reason) = match policy.overwrite {
            Overwrite::Always => (true, "policy is always"),
            Overwrite::Never => (false, "policy is never"),
            Overwrite::IfNewer => (newer(r.modified, l.modified), "remote is newer"),
            Overwrite::IfDifferentSize => (r.size != l.size, "size differs"),
            Overwrite::IfDifferentEtag => match (&r.etag, &l.etag) {
                (Some(a), Some(b)) => (a != b, "etag differs"),
                // No recorded etag is not "unchanged": the file may never have been recorded.
                // Falling back to size keeps the answer defensible instead of silently
                // skipping everything the first time the policy is used.
                _ => (r.size != l.size, "no recorded etag, size differs"),
            },
        };
        if transfer {
            plan.actions.push(SyncAction::Update {
                key: r.key.clone(),
                size: r.size,
                reason: reason.to_string(),
            });
            plan.bytes += r.size;
        } else {
            plan.actions.push(SyncAction::Skip {
                key: r.key.clone(),
                reason: "up to date".to_string(),
            });
        }
    }

    if policy.delete_extraneous {
        for l in local {
            if !remote.iter().any(|r| r.key == l.key) {
                plan.actions.push(SyncAction::Delete { key: l.key.clone() });
            }
        }
    }

    plan
}

#[cfg(test)]
mod tests {
    use super::*;

    fn r(key: &str, size: u64, modified: Option<u64>) -> RemoteEntry {
        RemoteEntry { key: key.into(), size, modified, etag: None }
    }
    fn l(key: &str, size: u64, modified: Option<u64>) -> LocalEntry {
        LocalEntry { key: key.into(), size, modified, etag: None }
    }
    fn policy(overwrite: Overwrite) -> SyncPolicy {
        SyncPolicy { overwrite, delete_extraneous: false }
    }

    #[test]
    fn what_is_missing_is_created_and_counted() {
        let plan = sync_plan(&[r("a", 10, None)], &[], policy(Overwrite::IfNewer));
        assert_eq!(plan.actions, vec![SyncAction::Create { key: "a".into(), size: 10 }]);
        assert_eq!(plan.bytes, 10);
    }

    #[test]
    fn a_file_copied_a_moment_ago_is_not_copied_again() {
        // The regression this pins: without slack, a one-second timestamp difference between
        // the store and the filesystem makes every sync re-copy everything, forever.
        let plan = sync_plan(
            &[r("a", 10, Some(1001))],
            &[l("a", 10, Some(1000))],
            policy(Overwrite::IfNewer),
        );
        assert!(matches!(plan.actions[0], SyncAction::Skip { .. }));
        assert_eq!(plan.bytes, 0);
    }

    #[test]
    fn a_genuinely_newer_remote_is_updated() {
        let plan = sync_plan(
            &[r("a", 10, Some(2000))],
            &[l("a", 10, Some(1000))],
            policy(Overwrite::IfNewer),
        );
        assert!(matches!(plan.actions[0], SyncAction::Update { .. }));
        assert_eq!(plan.bytes, 10);
    }

    #[test]
    fn a_destination_with_no_timestamp_is_copied_rather_than_assumed_current() {
        let plan = sync_plan(
            &[r("a", 10, Some(2000))],
            &[l("a", 10, None)],
            policy(Overwrite::IfNewer),
        );
        assert!(matches!(plan.actions[0], SyncAction::Update { .. }));
    }

    #[test]
    fn never_makes_the_sync_additive() {
        let plan = sync_plan(
            &[r("a", 99, Some(9999)), r("b", 1, None)],
            &[l("a", 10, Some(1))],
            policy(Overwrite::Never),
        );
        assert!(matches!(plan.actions[0], SyncAction::Skip { .. }));
        assert!(matches!(plan.actions[1], SyncAction::Create { .. }));
        assert_eq!(plan.bytes, 1);
    }

    #[test]
    fn an_etag_policy_without_a_recorded_etag_falls_back_to_size() {
        // Skipping everything would be the "safe" reading and is the wrong one: nothing has an
        // etag the first time, so the sync would do nothing at all and look broken.
        let plan = sync_plan(
            &[RemoteEntry { key: "a".into(), size: 20, modified: None, etag: Some("x".into()) }],
            &[l("a", 10, None)],
            policy(Overwrite::IfDifferentEtag),
        );
        assert!(matches!(plan.actions[0], SyncAction::Update { .. }));
    }

    #[test]
    fn extraneous_files_are_deleted_only_when_asked() {
        let remote = [r("a", 1, None)];
        let local = [l("a", 1, None), l("gone", 1, None)];

        let quiet = sync_plan(&remote, &local, policy(Overwrite::Never));
        assert!(!quiet.actions.iter().any(|a| matches!(a, SyncAction::Delete { .. })));

        let loud = sync_plan(
            &remote,
            &local,
            SyncPolicy { overwrite: Overwrite::Never, delete_extraneous: true },
        );
        assert!(loud.actions.contains(&SyncAction::Delete { key: "gone".into() }));
    }

    #[test]
    fn the_byte_count_covers_only_what_moves() {
        // What a progress bar is built on: skipped entries must not inflate the total, or the
        // bar finishes at 40% and stops.
        let plan = sync_plan(
            &[r("a", 100, Some(1)), r("b", 50, None)],
            &[l("a", 100, Some(9999))],
            policy(Overwrite::IfNewer),
        );
        assert_eq!(plan.bytes, 50);
    }
}
