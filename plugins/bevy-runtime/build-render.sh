#!/usr/bin/env bash
# Build the headless renderer and put it where Bennu looks for it.
#
# The sibling of `build.sh`, which builds the wasm viewport. Two scripts and not one because
# they are two targets with nothing in common but the source: the viewport is wasm, stripped
# and wasm-opt'd because it travels over a network on install; this is a native binary that
# has to render as fast as it can and never leaves the machine.
#
# `bennu_shader_render` finds it at `<package>/bin/arbor-shader-render`, which is why it is
# copied out of `target/` rather than left there: a `target/` directory is a build artefact
# nobody should have to know the layout of, and the package is what gets installed.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# `cd`, not `--manifest-path`. The app is its own workspace inside another checkout, and
# pointing cargo at the manifest from outside it answers "Finished" without compiling — see
# the long note in `build.sh`, which this shares the scar with.
( cd "$here/app" && cargo build --release --features native-render --bin arbor-shader-render )

exe="arbor-shader-render"
[ "${OS:-}" = "Windows_NT" ] && exe="arbor-shader-render.exe"

mkdir -p "$here/bin"
cp "$here/app/target/release/$exe" "$here/bin/$exe"
chmod +x "$here/bin/$exe" 2>/dev/null || true

printf 'renderer: %s (%s)\n' "$here/bin/$exe" "$(du -h "$here/bin/$exe" | cut -f1)"

# Prove it runs at all before anything downstream trusts it. `--help` is not implemented on
# purpose — there is one caller and it passes real flags — so the check is that it refuses an
# empty invocation with the message it should, and not that it crashed on start.
# `grep -c`, not `grep -q`: a quiet grep exits at the first match, the producer takes SIGPIPE,
# and under `pipefail` the pipeline reports failure about the very run that passed. Counting
# reads the whole stream, so the answer is about the output and not about the plumbing.
hits=$("$here/bin/$exe" 2>&1 | grep -c -- '--shader is required' || true)
if [ "${hits:-0}" -eq 0 ]; then
  echo 'WARNING: the renderer did not start, or did not report its own usage' >&2
  exit 1
fi
echo 'renderer verified — starts and validates its arguments'
