#!/usr/bin/env bash
#
# Print the `index.json` entry for a released package, with a sha256 for every asset.
#
# ## Why this exists
#
# A `.wasm` cannot be read in a pull request, so what a reviewer approves is a **digest**.
# That only works if the digest is easy to produce: asking somebody to hash four files by
# hand and paste them correctly is asking for the step to be skipped, and a skipped
# integrity check is worse than none because it looks like one.
#
# Run by the release workflow into the job summary, so the block is sitting there when you
# open the registry PR. Also runnable locally against a directory of built assets.
#
# Usage: registry-entry.sh <package-name> <package-dir> <tag> <assets-dir>

set -euo pipefail

name="${1:?package name}"
dir="${2:?package dir}"
tag="${3:?tag}"
assets="${4:?assets dir}"

# `plugins/foo` → the subpath the registry points at. Leading `./` stripped so the entry
# reads the way the existing ones do.
subpath="${dir#./}"

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    # macOS
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# A Lua-only package carries no digests: it installs from the source archive of its ref, and
# git already content-addresses that. Saying so is more useful than printing an empty block
# somebody then wonders about.
shopt -s nullglob
wasm=( "$assets"/*.wasm )
shopt -u nullglob

echo '## Registry entry'
echo
echo 'Paste into `index.json` in `arbor-extensions`, then open a PR — that PR is the review.'
echo
echo '```json'
if [ ${#wasm[@]} -eq 0 ]; then
  # No artifacts key at all. An entry that records digests must pin an exact ref; one that
  # records none may ride a branch, which is what every Lua plugin here does today.
  printf '{ "subpath": "%s" }\n' "$subpath"
else
  printf '{\n'
  printf '  "subpath": "%s",\n' "$subpath"
  printf '  "ref": "%s",\n' "$tag"
  printf '  "artifacts": {\n'
  first=1
  for f in "$assets"/*; do
    [ -f "$f" ] || continue
    [ $first -eq 1 ] || printf ',\n'
    first=0
    printf '    "%s": "sha256:%s"' "$(basename "$f")" "$(sha256_of "$f")"
  done
  printf '\n  }\n}\n'
fi
echo '```'

if [ ${#wasm[@]} -eq 0 ]; then
  echo
  echo "_No \`[[provides]]\` in \`$name\` — this package installs from the source archive, so"
  echo "it needs no digests and no \`ref\`. The zip above is published for convenience only._"
fi
