# `wit/` — vendored copy

**These files are a copy.** The originals live in Arbor's own repo under `wit/`, and that is
where they are edited. This copy exists because a guest has to compile against the interface
and this is a different repository.

Vendoring rather than publishing an SDK crate is the state of things today, not the
destination: the moment a third party outside this organisation wants to implement one of
these, the contract has to be fetchable — an `arbor-extension-sdk` crate carrying the WIT and
the generated bindings. Until then, a copy with its origin written down beats a copy without.

**Keeping it in step**: the interface version in `[[provides]]` is what actually matters. A
package declaring `cloud-provider@1` compiles against `cloud-provider@1`, and a host running a
different major refuses to instantiate it rather than calling into a mismatched ABI. So a
stale copy fails loudly at load, not subtly at runtime — which is the failure mode worth
having while a copy is how this works.

---

These are **contracts, not code**. Each one describes an interface Arbor defines and a guest
implements: the host calls in, the guest answers. That direction is what separates an
*extension* from a *plugin* — a Lua plugin calls Arbor's API, an extension implements Arbor's
interface — and it is why an extension needs none of the `arbor.*` surface.

| file | who implements it | needs |
|---|---|---|
| `host.wit` | **Arbor** — what a guest may ask for | — |
| `studio-format.wit` | a format backend (json, toml, yaml, ron, properties, …) | logging only |
| `cloud-provider.wit` | a bucket provider (gcs, s3, azblob, …) | secrets, http |

## Why WIT and not a Rust trait behind a macro

Because a `.wit` file is an interface anybody can implement, and a proc-macro is an interface
only Rust can. If `studio-format@1` is meant to be public — if somebody outside this project
should be able to add `.ini` support — then the contract cannot be "depend on our crate and
use our macro".

It is also a better specification even if the ABI beneath it ever changes: the types, the
errors and the shapes are here in one readable file rather than spread across a trait, its
serde derives and the code that marshals them.

## Versioning

An interface versions **itself**. `studio-format@1` moves when the format contract changes;
that is not the same event as a package release (`version` in `plugin.toml`) or a change to
the Lua API (`arbor_api`), and collapsing any two of the three makes one of them unable to
move without invalidating things that did not change.

A package declares which it implements:

```toml
[[provides]]
interface = "studio-format"
version   = 1
id        = "json"
module    = "studio_json.wasm"
```

## Two rules that shaped these files

**Guests are synchronous.** Every function here returns a value, not a future. A guest runs on
a blocking worker and the host drives the async work while that worker waits — which is how
the rest of Arbor already reaches a backend, and which sidesteps the least-settled corner of
the component model entirely.

**Capabilities are narrow and named.** A provider that needs to reach a bucket asks the host to
perform a request; the host holds the credential, checks the URL against the
`[permissions] network` list the user consented to, and speaks TLS. A guest that held the token
would turn an enforced rule back into a promise.

**WASI is linked, and granted nothing.** This is a correction to what this file first claimed.
`wasm32-wasip2` links the WASI standard library into every guest whether it uses it or not, so
a component built for that target imports `wasi:io/poll` before running a line of its own code
— refusing to link WASI does not produce a guest without it, it produces a guest that will not
instantiate. So it is linked with an **empty context**: no preopened directories, no sockets,
no inherited environment, no stdio. A guest still cannot open a file or a connection. The
guarantee moved from what the linker omits to what the context contains, which is the same
guarantee and a more honest description of it.
