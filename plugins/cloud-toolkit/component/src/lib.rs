//! `cloud-toolkit` — the shared object-storage logic, exported as an extension.
//!
//! Every function here is two lines: translate the WIT shape into `cloud-common`'s, call it,
//! translate back. That is deliberate and it is the whole file — the logic lives in the crate,
//! which is also what the providers link, so there is one implementation and no chance of the
//! Lua caller and the provider disagreeing about what "part10" sorts after.
//!
//! ## No capabilities
//!
//! The manifest declares no permissions at all: no network, no filesystem, no credential
//! slots. Nothing here does I/O, so there is nothing to grant — and a package that cannot
//! reach anything cannot be talked into reaching something.

wit_bindgen::generate!({
    path: "../wit",
    world: "toolkit",
});

use exports::arbor::cloud_toolkit::util::{
    ByteRange, Chunk, ChunkOrder, Guest, LocalEntry, Overwrite, RemoteEntry, SyncAction,
    SyncPlanResult, SyncPolicy,
};

use cloud_common::prelude as cc;

struct Toolkit;

impl Guest for Toolkit {
    fn plan_ranges(size: u64, chunk: u64) -> Vec<ByteRange> {
        cc::plan_ranges(size, chunk)
            .into_iter()
            .map(|r| ByteRange { start: r.start, end: r.end })
            .collect()
    }

    fn glob_match(pattern: String, key: String) -> bool {
        cc::glob_match(&pattern, &key)
    }

    fn order_chunks(chunks: Vec<Chunk>, order: ChunkOrder) -> Vec<Chunk> {
        let input = chunks
            .into_iter()
            .map(|c| cloud_common::chunks::Chunk { key: c.key, modified: c.modified })
            .collect();
        let out = cc::order_chunks(
            input,
            match order {
                ChunkOrder::Natural => cc::ChunkOrder::Natural,
                ChunkOrder::Date => cc::ChunkOrder::Date,
            },
        );
        out.into_iter()
            .map(|c| Chunk { key: c.key, modified: c.modified })
            .collect()
    }

    fn sync_plan(
        remote: Vec<RemoteEntry>,
        local: Vec<LocalEntry>,
        policy: SyncPolicy,
    ) -> SyncPlanResult {
        let remote: Vec<cc::RemoteEntry> = remote
            .into_iter()
            .map(|r| cc::RemoteEntry {
                key: r.key,
                size: r.size,
                modified: r.modified,
                etag: r.etag,
            })
            .collect();
        let local: Vec<cc::LocalEntry> = local
            .into_iter()
            .map(|l| cc::LocalEntry {
                key: l.key,
                size: l.size,
                modified: l.modified,
                etag: l.etag,
            })
            .collect();
        let plan = cc::sync_plan(
            &remote,
            &local,
            cc::SyncPolicy {
                overwrite: match policy.overwrite {
                    Overwrite::Always => cc::Overwrite::Always,
                    Overwrite::IfNewer => cc::Overwrite::IfNewer,
                    Overwrite::IfDifferentSize => cc::Overwrite::IfDifferentSize,
                    Overwrite::IfDifferentEtag => cc::Overwrite::IfDifferentEtag,
                    Overwrite::Never => cc::Overwrite::Never,
                },
                delete_extraneous: policy.delete_extraneous,
            },
        );
        SyncPlanResult {
            actions: plan
                .actions
                .into_iter()
                .map(|a| match a {
                    cc::SyncAction::Create { key, size } => SyncAction::Create((key, size)),
                    cc::SyncAction::Update { key, size, reason } => {
                        SyncAction::Update((key, size, reason))
                    }
                    cc::SyncAction::Skip { key, reason } => {
                        SyncAction::Skip((key, reason))
                    }
                    cc::SyncAction::Delete { key } => SyncAction::Delete(key),
                })
                .collect(),
            bytes: plan.bytes,
        }
    }

    fn split_key(key: String) -> (String, String) {
        cc::split_key(&key)
    }

    fn join_key(prefix: String, name: String) -> String {
        cc::join_key(&prefix, &name)
    }

    fn parent_prefix(prefix: String) -> String {
        cc::parent_prefix(&prefix)
    }

    fn encode_segment(s: String) -> String {
        cc::encode_segment(&s)
    }

    fn rfc3339_secs(s: String) -> Option<u64> {
        cc::rfc3339_secs(&s)
    }
}

export!(Toolkit);
