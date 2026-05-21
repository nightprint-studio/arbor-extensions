-- deps-explorer / main.lua
--
-- Adds an "Analyze dependencies…" entry on every module node of the
-- compile-action Build & Run sidebar (Maven, Gradle, Cargo, npm). Clicking
-- it opens the IntelliJ-style DepsExplorerModal in the frontend.
--
-- Plugin → modal protocol (piggy-backs on `arbor.ui.tree.set`):
--
--   1. We generate `request_id` and immediately push a "loading" snapshot
--      under the sidebar id `deps:<request_id>` so the frontend modal opens
--      right away (depsExplorerStore filters the unified
--      `arbor://contributions-changed` event for `point="arbor:tree-state"`
--      and recognises sidebar ids prefixed with `deps:`).
--   2. We spawn the resolver job in the background (mvn/gradle/cargo/npm).
--      On done, we parse the output, build the transitive tree (with all
--      metadata in node.data), and push the final snapshot under the same
--      sidebar id — the modal updates reactively.
--   3. For Maven only: we also fan out `curl` jobs to Maven Central in
--      parallel and patch the snapshot when the latest-version info arrives.
--
-- Each node's `data` carries:
--   { group, artifact, version, scope?, classifier?, type?, optional?,
--     conflict?, latest_central?, is_outdated?, omitted_for? }
-- The modal derives the flat list, group-by views, conflict map and the
-- reverse-usages map from the tree on the frontend.

local maven  = require("resolvers.maven")
local cargo  = require("resolvers.cargo")
local npm    = require("resolvers.npm")
local gradle = require("resolvers.gradle")
local mc     = require("maven_central")
local nr     = require("npm_registry")
local cr     = require("crates_io")
local dcache = require("deps_cache")

local COMPILE_NS = "compile-action:compile"

-- Per-request resolver context. The Refresh action posted from the modal
-- (`deps-explorer:refresh` with `{ request_id }`) needs the original ctx so
-- it can re-dispatch with `force = true`. Keyed by request_id; entries are
-- never removed (a few hundred bytes each — fine for a session).
local _active_requests = {}

-- Forward declaration — defined further down the file but referenced from the
-- PLUGIN_LOAD callback registered just below.
local contribute_maintenance_section

-- ── Lifecycle ────────────────────────────────────────────────────────────────

arbor.events.on("on_plugin_load", function(_ctx)
  -- One context-menu entry per supported toolchain. We could collapse them
  -- into a single entry with template-aware dispatch, but per-toolchain
  -- entries make the `when` clauses self-documenting and the priority easy
  -- to tune individually.
  local TOOLCHAINS = {
    { id = "deps-analyze-maven",  template = "maven"  },
    { id = "deps-analyze-cargo",  template = "cargo"  },
    { id = "deps-analyze-npm",    template = "npm"    },
    { id = "deps-analyze-gradle", template = "gradle" },
  }
  for _, t in ipairs(TOOLCHAINS) do
    arbor.ui.contribute(COMPILE_NS .. ":context_menu", {
      id       = t.id,
      priority = 60,
      when     = { kind = "module", data_field = { key = "template_id", value = t.template } },
      payload  = {
        label  = "Analyze dependencies…",
        action = "deps-explorer:analyze",
      },
    })
  end

  -- Hover-revealed icon on module rows (one-click affordance — context menu
  -- stays as the discoverable label fallback).
  for _, t in ipairs(TOOLCHAINS) do
    arbor.ui.contribute(COMPILE_NS .. ":node_action", {
      id       = t.id .. "-icon",
      priority = 40,
      when     = { kind = "module", data_field = { key = "template_id", value = t.template } },
      payload  = {
        icon    = "Network",
        tooltip = "Analyze dependencies",
        action  = "deps-explorer:analyze",
      },
    })
  end

  -- Contribute cache-management section to compile-action's "Maintenance"
  -- settings category. Re-contributed on every settings open via the
  -- `compile-action:settings:on_open` hook so the displayed counts stay
  -- fresh.
  pcall(contribute_maintenance_section)
  arbor.ui.contribute("compile-action:settings:on_open", {
    id      = "deps-explorer-cache-refresh",
    payload = { action = "deps-explorer:settings_refresh" },
  })

  arbor.log.info("ready — Analyze dependencies wired into compile sidebar")
end)

-- ── on_repo_deregistered: prune per-repo tree-cache entries ─────────────────
-- The host fires this when a repo is permanently removed from Arbor (full
-- registry delete, removed from its last workspace, or last tab closed while
-- already orphaned). The registry caches (Maven Central / npm / crates.io)
-- are keyed by package name so they aren't repo-specific and stay put — we
-- only flush the dependency-tree snapshots whose module dir lived inside
-- the removed repo path.
arbor.events.on("on_repo_deregistered", function(ctx)
  local path = ctx and ctx.path or ""
  if path == "" then return end
  local removed = 0
  pcall(function() removed = dcache.invalidate_path(path) end)
  if removed > 0 then
    arbor.log.info("[deps-explorer] dropped " .. removed
      .. " tree-cache entr" .. (removed == 1 and "y" or "ies")
      .. " for deregistered repo: " .. path)
  end
end)

-- ── Cache statistics + clearing ─────────────────────────────────────────────
-- Each cache module exposes `clear_cache()` and `invalidate_misses()`. We
-- read counts via a thin module-private helper so the maintenance card can
-- show "Maven Central — 142 entries" instead of just a Clear button.

local function settings_count(key)
  local ok, val = pcall(arbor.settings.global.get, key)
  if not ok or type(val) ~= "table" then return 0 end
  local n = 0
  for _ in pairs(val) do n = n + 1 end
  return n
end

local function plural(n, sing, plur)
  return tostring(n) .. " " .. (n == 1 and sing or plur)
end

contribute_maintenance_section = function()  -- assigns to local declared above
  local mc_count = settings_count("mvn_central_cache")
  local nr_count = settings_count("npm_registry_cache")
  local cr_count = settings_count("crates_io_cache")

  local nodes = {
    { type = "paragraph", variant = "muted",
      content = "Latest-version lookups (Maven Central, npm registry, crates.io) "
             .. "and the resolved dependency tree per module are cached so "
             .. "re-opening the modal is instant. Clear a cache below to force "
             .. "fresh lookups on the next analysis." },
    { type = "card_row",
      label = "Maven Central — latest versions",
      description = plural(mc_count, "entry", "entries") .. " cached",
      children = {
        { type = "button", label = "Clear", action = "deps-explorer:clear_maven_central",
          variant = "default", disabled = mc_count == 0 },
      },
    },
    { type = "card_row",
      label = "npm registry — latest versions",
      description = plural(nr_count, "entry", "entries") .. " cached",
      children = {
        { type = "button", label = "Clear", action = "deps-explorer:clear_npm_registry",
          variant = "default", disabled = nr_count == 0 },
      },
    },
    { type = "card_row",
      label = "crates.io — latest versions",
      description = plural(cr_count, "entry", "entries") .. " cached",
      children = {
        { type = "button", label = "Clear", action = "deps-explorer:clear_crates_io",
          variant = "default", disabled = cr_count == 0 },
      },
    },
    { type = "card_row",
      label = "Resolved dependency trees",
      description = "Per-module snapshot cache (mvn / gradle / cargo / npm output).",
      children = {
        { type = "button", label = "Clear",
          action = "deps-explorer:clear_tree_cache", variant = "default" },
      },
    },
    { type = "card_row",
      label = "All deps-explorer caches",
      description = "One-click reset of every cache above. The modal still shows resolver progress on the next analysis.",
      children = {
        { type = "button", label = "Clear all",
          action = "deps-explorer:clear_all", variant = "danger" },
      },
    },
  }

  arbor.ui.contribute("compile-action:settings:section", {
    id       = "deps-explorer-caches",
    priority = 20,
    payload  = {
      category = "maintenance",
      label    = "Dependency caches (deps-explorer)",
      nodes    = nodes,
    },
  })
end

arbor.events.on("deps-explorer:settings_refresh", function(_ctx)
  pcall(contribute_maintenance_section)
end)

-- Reopens the compile-action settings panel after a cache mutation so the
-- user sees the freshly-counted entries without manually closing + reopening.
local function reopen_settings_panel()
  pcall(contribute_maintenance_section)
  pcall(arbor.ui.settings.open, "compile-action", "main")
end

arbor.events.on("deps-explorer:clear_maven_central", function(_ctx)
  pcall(mc.clear_cache)
  arbor.notify{ title = "Maven Central cache cleared", message = "Latest-version lookups will refetch on next analysis.", level = "success" }
  reopen_settings_panel()
end)

arbor.events.on("deps-explorer:clear_npm_registry", function(_ctx)
  pcall(nr.clear_cache)
  arbor.notify{ title = "npm registry cache cleared", message = "Latest-version lookups will refetch on next analysis.", level = "success" }
  reopen_settings_panel()
end)

arbor.events.on("deps-explorer:clear_crates_io", function(_ctx)
  pcall(cr.clear_cache)
  arbor.notify{ title = "crates.io cache cleared", message = "Latest-version lookups will refetch on next analysis.", level = "success" }
  reopen_settings_panel()
end)

arbor.events.on("deps-explorer:clear_tree_cache", function(_ctx)
  pcall(dcache.invalidate_all)
  arbor.notify{ title = "Tree cache cleared", message = "Resolvers will re-run on the next analysis.", level = "success" }
  reopen_settings_panel()
end)

arbor.events.on("deps-explorer:clear_all", function(_ctx)
  pcall(mc.clear_cache)
  pcall(nr.clear_cache)
  pcall(cr.clear_cache)
  pcall(dcache.invalidate_all)
  arbor.notify{ title = "All deps-explorer caches cleared", message = "Everything will refetch on the next analysis.", level = "success" }
  reopen_settings_panel()
end)

-- ── Helpers ──────────────────────────────────────────────────────────────────

local function repo_name(path)
  if not path or path == "" then return "(repo)" end
  return path:match("[/\\]([^/\\]+)[/\\]?$") or path
end

local function new_request_id()
  -- UTC-ish ms + small random suffix; uniqueness across concurrent modals
  -- is the only requirement (no need to be cryptographically strong).
  local ms = math.floor((os.time() % 100000) * 1000) + math.random(0, 999)
  return string.format("%x-%x", ms, math.random(0, 0xffffff))
end

local function loading_snapshot(label, request_id, meta)
  return {
    title = "Analyze dependencies — " .. label,
    nodes = {
      {
        id    = "deps:loading",
        label = "Resolving dependency graph…",
        icon  = "Loader",
        kind  = "deps:status",
        selectable = false,
        expanded   = false,
        data       = {
          status     = "loading",
          request_id = request_id,
          meta       = meta or {},
        },
        children = {},
      },
    },
  }
end

local function error_snapshot(label, request_id, message, meta)
  return {
    title = "Analyze dependencies — " .. label,
    nodes = {
      {
        id    = "deps:error",
        label = message,
        icon  = "AlertCircle",
        kind  = "deps:status",
        selectable = false,
        expanded   = false,
        data       = {
          status     = "error",
          request_id = request_id,
          message    = message,
          meta       = meta or {},
        },
        children = {},
      },
    },
  }
end

-- The frontend keys snapshots by `<plugin>::<sidebar_id>` and the plugin name
-- is implicit (us). Sidebar id format: `deps:<request_id>` so the frontend
-- store can spot a deps-explorer request from a generic tree update with a
-- single prefix check.
local function sidebar_id(request_id)
  return "deps:" .. request_id
end

-- ── Action handler ───────────────────────────────────────────────────────────
-- ctx = { node_id, data = { template_id, repo_path, module_dir?, pom_path?, cargo_path? } }

local function dispatch_resolver(resolver_ctx)
  local template = resolver_ctx.template
  local sid      = resolver_ctx.sidebar_id
  local label    = resolver_ctx.label

  local ok, err
  if template == "maven" then
    ok, err = pcall(maven.resolve, resolver_ctx)
  elseif template == "cargo" then
    ok, err = pcall(cargo.resolve, resolver_ctx)
  elseif template == "npm" then
    ok, err = pcall(npm.resolve, resolver_ctx)
  elseif template == "gradle" then
    ok, err = pcall(gradle.resolve, resolver_ctx)
  else
    ok, err = false, "Unsupported template: " .. tostring(template)
  end

  if not ok then
    arbor.log.error("[deps-explorer] resolver crash: " .. tostring(err))
    arbor.ui.tree.set(sid, error_snapshot(label, resolver_ctx.request_id,
      "Resolver crashed: " .. tostring(err), { template = template }))
  end
end

arbor.events.on("deps-explorer:analyze", function(ctx)
  local d = ctx.data or {}
  local template = d.template_id or ""
  local repo_path = d.repo_path or ""
  local module_dir = d.module_dir or repo_path
  if repo_path == "" then
    arbor.notify{ title = "Analyze dependencies", message = "No active repository.", level = "warning" }
    return
  end

  local request_id = new_request_id()
  local sid        = sidebar_id(request_id)
  local label      = repo_name(module_dir)

  -- 1. Open the modal immediately with a loading snapshot. The frontend
  --    store sees the new `deps:*` sidebar id and pops the modal up.
  arbor.ui.tree.set(sid, loading_snapshot(label, request_id, {
    template   = template,
    repo_path  = repo_path,
    module_dir = module_dir,
  }))

  -- 2. Dispatch to the per-toolchain resolver. Each resolver is responsible
  --    for spawning its job(s) and pushing the final snapshot via
  --    `arbor.ui.tree.set(sid, ...)`. We pass a context table so they don't
  --    need to know about the modal protocol.
  local resolver_ctx = {
    request_id = request_id,
    sidebar_id = sid,
    repo_path  = repo_path,
    module_dir = module_dir,
    template   = template,
    label      = label,
    pom_path   = d.pom_path,
    cargo_path = d.cargo_path,
    pm         = d.pm,
    force      = false,
  }
  _active_requests[request_id] = resolver_ctx
  dispatch_resolver(resolver_ctx)
end)

-- Refresh: posted by the modal's split Refresh button. Three modes mirror the
-- dropdown options the user sees:
--
--   · "all"    — invalidate registry "miss" entries + force-rerun the resolver.
--                Default behaviour; matches what the plain Refresh did before
--                the split button existed.
--   · "tree"   — force-rerun the resolver only. Keeps registry caches intact,
--                so already-fetched latest versions are reused.
--   · "latest" — keep the resolved tree (or whatever is cached), but FULLY
--                wipe the registry caches so the latest-version pass re-fetches
--                everything from Maven Central / npm / crates.io.
arbor.events.on("deps-explorer:refresh", function(ctx)
  local request_id = ctx.request_id or ""
  local mode = ctx.mode or "all"
  local original = _active_requests[request_id]
  if not original then
    arbor.notify{ title = "Refresh dependencies", message = "Request id is no longer tracked. Re-open the modal.", level = "warning" }
    return
  end

  if mode == "all" then
    pcall(mc.invalidate_misses)
    pcall(nr.invalidate_misses)
    pcall(cr.invalidate_misses)
  elseif mode == "latest" then
    pcall(mc.clear_cache)
    pcall(nr.clear_cache)
    pcall(cr.clear_cache)
  end

  local sid   = original.sidebar_id
  local label = original.label
  arbor.ui.tree.set(sid, loading_snapshot(label, request_id, {
    template   = original.template,
    repo_path  = original.repo_path,
    module_dir = original.module_dir,
    refreshed  = true,
    mode       = mode,
  }))
  local refreshed_ctx = {}
  for k, v in pairs(original) do refreshed_ctx[k] = v end
  -- "latest" reuses the cached tree → force = false so the resolver hits
  -- the on-disk snapshot before doing the registry pass. The other modes
  -- bypass the cache to actually re-run the toolchain command.
  refreshed_ctx.force = (mode ~= "latest")
  _active_requests[request_id] = refreshed_ctx
  dispatch_resolver(refreshed_ctx)
  -- Refresh the maintenance section's counts since some caches were just
  -- mutated. No-op if the settings panel isn't open.
  pcall(contribute_maintenance_section)
end)

-- Helpers exposed to resolver modules (so they can update the snapshot
-- mid-flight, e.g. when Maven Central responses arrive piecemeal).
return {
  loading_snapshot = loading_snapshot,
  error_snapshot   = error_snapshot,
  sidebar_id       = sidebar_id,
}
