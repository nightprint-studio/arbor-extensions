#!/usr/bin/env bash
# Build the runtime's wasm bundle into `web/`.
#
# The `wasm-opt` step is NOT optional, and that is the whole reason this file exists.
# `[profile.release] strip = "debuginfo"` does not remove a wasm module's DWARF, which lives
# in custom sections `-C strip` leaves alone — so `cargo build --release` produces a **55 MB**
# module, and shipping it means the app freezes while the webview compiles it. Stripping and
# optimising takes it to under 20 MB.
#
# Requires: rustup target wasm32-unknown-unknown · wasm-bindgen-cli · binaryen (wasm-opt).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="$here/web"

# `cd` rather than `--manifest-path`. The app is its OWN workspace inside another checkout,
# and pointing cargo at the manifest from outside it produced "Finished" without a single
# "Compiling" line — three rebuilds in a row silently reprocessed yesterday's artifact, and
# every fix landed in a bundle nobody was running. Building from inside the crate is the
# version that recompiles when the source changes.
( cd "$here/app" && cargo build --release --target wasm32-unknown-unknown )

artifact="$here/app/target/wasm32-unknown-unknown/release/arbor_bevy_runtime.wasm"

wasm-bindgen \
  --target web \
  --no-typescript \
  --out-dir "$out" \
  --out-name runtime \
  "$artifact"

# -Oz over -O3: this is a viewer, and the module travels over a network on install. Bevy's
# frame time is dominated by the GPU either way.
wasm-opt -Oz --strip-debug --strip-producers \
  -o "$out/runtime_bg.wasm.opt" "$out/runtime_bg.wasm"
mv "$out/runtime_bg.wasm.opt" "$out/runtime_bg.wasm"

printf 'bundle: %s\n' "$(du -h "$out/runtime_bg.wasm" | cut -f1)"

# Prove the bundle is the source you just built, not a stale one reprocessed. A size that
# looks right is exactly what a stale rebuild produces.
# Two checks, because a stale bundle is the failure that cost the most here: cargo answered
# "Finished" without compiling for three rebuilds in a row, and every one produced a file of
# exactly the right size from yesterday's artifact.

# 1. Is anything in the bundle newer than every source file? Catches the general case.
newest_src=$(find "$here/app/src" "$here/app/Cargo.toml" -type f -newer "$artifact" 2>/dev/null | head -1 || true)
if [ -n "$newest_src" ]; then
  echo "WARNING: $newest_src is newer than the compiled artifact — cargo did not rebuild" >&2
  exit 1
fi

# 2. Is a known string from the source actually in the bundle? Catches the case where the
# artifact is fresh but the pipeline downstream of it silently used another file.
#
# `grep -c`, not `grep -q`: under `pipefail` a quiet grep exits at the first match, `strings`
# takes SIGPIPE, and the pipeline reports failure on the very bundle that passed. Counting
# reads the whole stream, so the answer is about the file and not about the plumbing.
marker=$(strings "$out/runtime_bg.wasm" | grep -c 'runtime: received' || true)
if [ "${marker:-0}" -gt 0 ]; then
  echo 'bundle verified — newer than its sources, and carries their strings'
else
  echo 'WARNING: trace marker missing — the bundle is stale, do not ship it' >&2
  exit 1
fi
