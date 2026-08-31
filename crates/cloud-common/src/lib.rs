//! What every object store needs and none of them provides.
//!
//! A provider talks to one service; this is everything around that which is the same whichever
//! service it is — splitting keys, matching a glob, deciding which parts of a large object to
//! ask for, working out what a sync would actually do. Written once here because it was
//! otherwise written twice: once inside each provider, once inside the orchestrating plugin,
//! and the two disagreeing is what "sync did nothing" looks like from outside.
//!
//! ## Two ways to reach it
//!
//! · **Linked**, by a provider in this repo (`cloud-gcs` and its siblings) — an ordinary crate
//!   dependency, no boundary in the way.
//! · **Called**, by a plugin in Lua, through the `cloud-toolkit` package: a component that
//!   exports these functions so `arbor.ext.call` can reach them. A guest cannot call another
//!   guest, so a provider takes the first road and the panel takes the second — and both run
//!   the same code.
//!
//! ## Everything here is pure
//!
//! No I/O, no clock, no randomness — [`jwt`] included, which takes the time as a parameter
//! rather than reading a clock. That is what makes it testable at all, and it is why the
//! component that wraps it needs no capabilities: a package that only computes cannot be asked
//! to leak anything.
//!
//! [`jwt`] is the one module the toolkit package does NOT export to Lua. Signing is done with
//! a private key, and a key that crosses into Lua is a key in a place nobody can reason
//! about — the providers link it, and it stays there.

pub mod chunks;
pub mod glob;
pub mod jwt;
pub mod keys;
pub mod plan;
pub mod sync;
pub mod time;

pub mod prelude {
    //! Canonical entry point — the workspace convention, and the import a provider writes.
    pub use crate::chunks::{order_chunks, ChunkOrder};
    pub use crate::glob::glob_match;
    pub use crate::jwt::{assertion, assertion_form, ServiceAccount};
    pub use crate::keys::{encode_segment, join_key, name_of, parent_prefix, split_key};
    pub use crate::plan::{plan_ranges, ByteRange};
    pub use crate::sync::{sync_plan, LocalEntry, RemoteEntry, SyncAction, SyncPlan, SyncPolicy, Overwrite};
    pub use crate::time::rfc3339_secs;
}
