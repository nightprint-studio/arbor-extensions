# arbor-extensions

The community plugin and theme registry for [Arbor](https://github.com/nightprint-studio/arbor).

Arbor ships an empty plugin runtime — no plugins are bundled in the binary. This repo is the catalog Arbor reads when you open the Marketplace from the Plugin Manager: a small list of pointers that lets the host fetch each plugin's `plugin.toml` (and its icon, screenshots, docs) directly from the author's source repository.

## How the registry works

The Arbor Marketplace pulls a tiny `index.json` from this repo, then resolves each entry by hitting the linked source repo. The advantages of this two-step model:

- Authors update **one** file — their own `plugin.toml`. They never edit the registry to publish a new version.
- The registry stays a small, PR-reviewable list of pointers.
- Icons, docs, screenshots come straight from the plugin repo, always in sync with the code.

The same model is used for themes.

## Maturity buckets

Each plugin entry declares its maturity. The buckets match Arbor's own status taxonomy:

- **Stable** — used day-to-day, broad coverage, considered reliable.
- **Functional** — wired into real workflows but with less mileage than the stable set. Expect occasional rough edges.
- **Experimental** — recent additions. Functional but not broadly tested; APIs may change.

The maturity tag travels with the plugin (it's declared in `plugin.toml`), so it always reflects what the author considers the current state of that release.

## Published plugins

### Workflow and integration

| Plugin | What it does | Maturity |
|---|---|---|
| **compile-action** | Auto-detects Maven/Gradle/npm/Rust/Go/Make and runs, watches, or stops builds from the activity bar | Stable |
| **run-action** | Generic command launcher with per-repo configurations | Stable |
| **run-monitor** | Dashboard for long-running services started by `run-action` | Stable |
| **deps-explorer** | Surfaces project dependencies and flags outdated or vulnerable ones | Stable |
| **cloud-storage** | Browse and upload/download to cloud object stores. Tested with Google Cloud Storage | Stable |
| **chunk-merger-bin** | Helper for `cloud-storage`: reassembles chunked downloads | Stable |
| **source-export** | Workflow engine for exporting code to external repos | Functional |
| **release-notes** | Generates release notes from commits between two refs | Functional |
| **commit-validator** | Vetoable pre-commit message validation hooks | Experimental |
| **gitignore-suggester** | Suggests `.gitignore` entries when ignorable files appear in the workdir | Experimental |
| **repo-bookmarks** | Pin files, lines, or commits across a repository | Experimental |

### Format studios

| Plugin | What it does | Maturity |
|---|---|---|
| **ron-studio** | RON viewer/editor with diff and cross-crate schema derived from Rust sources | Stable |
| **json-studio** | JSON viewer/editor with diff and JSON Schema validation | Functional |
| **toml-studio** | TOML viewer/editor with diff | Functional |
| **yaml-studio** | YAML viewer/editor with diff | Functional |
| **properties-studio** | `.properties` viewer/editor with lossless line view and JSON Schema validation | Functional |

### Why would you need it?

Plugins that have no business living inside a Git client but exist anyway. Once you have a plugin runtime, this is the kind of thing that happens.

| Plugin | What it does |
|---|---|
| **cipher-studio** | Encode / decode text with classical ciphers and old-school encodings — ROT13, Vigenère, Base64, Morse, and friends |
| **number-studio** | Convert integers between numeral systems: bases (binary, hex, base-36, sexagesimal), historical scripts (Roman, Greek, Egyptian, Babylonian, Mayan, Hebrew), non-Latin digits (Arabic-Indic, Devanagari, Chinese, Thai) |

## Installing a plugin

From inside Arbor:

1. Open the **Plugin Manager** and click **Browse**.
2. Pick a row in the catalog to open its detail pane.
3. Review the requested permissions.
4. Hit **Install**. A confirmation modal lists the same permissions in human-readable form — read carefully and confirm.
5. Arbor downloads the GitHub zipball, extracts it to `~/.config/arbor/marketplace_plugins/<name>/`, and reloads the plugin host. The plugin lands **disabled by default**.
6. Toggle **Enabled** in the detail pane when you're ready to use it.

When a newer version is available the row shows an **Update** pill. Updates re-run the install path and ask you to confirm the permission set again, in case the new version requests more.

## Custom sources

You don't have to use this registry. From the Marketplace footer in Arbor, click **Add custom source** and point Arbor at any GitHub repo. The resolver auto-detects the layout:

1. If you supply a `subpath` → fetches `<subpath>/plugin.toml` (subpath mode).
2. Else, looks for `plugin.toml` at the repo root → single plugin (root mode).
3. Else, looks for an `index.json` at the root → multi-plugin registry (mirror mode).

This means anyone can host their own mirror with the same structure as this repo.

## Publishing a plugin

> *(Authoring guide draft — fill in repo conventions as they settle.)*

1. Put your plugin in a public GitHub repo, with `plugin.toml` and `main.lua` at the root (or under a subpath).
2. Open a pull request on this repo adding a pointer entry to `index.json` with the plugin name, repo URL, and (optionally) the subpath.
3. After the PR is merged the plugin appears in every Arbor instance's Marketplace catalog on the next refresh.

The full plugin development reference — manifest schema, hooks, the Lua API surface — lives inside Arbor's in-app **Docs** panel.

## Reporting issues

- **Plugin bugs** → open an issue on the plugin's own repository.
- **Registry issues** (wrong pointer, dead link, plugin missing from catalog) → open an issue here.
- **Arbor core bugs** → open an issue on the [main Arbor repo](https://github.com/nightprint-studio/arbor/issues).

## License

Each plugin in this registry carries its own license, declared in its source repository. The registry data (`index.json` and supporting files in this repo) is released under the same license as Arbor: [GPL-3.0](https://github.com/nightprint-studio/arbor/blob/main/LICENSE).
