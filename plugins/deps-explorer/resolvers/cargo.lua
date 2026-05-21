-- resolvers/cargo.lua — `cargo tree --charset ascii --color never` parser path.

local parser = require("parsers.cargo_tree")
local cache  = require("deps_cache")
local cr     = require("crates_io")

local M = {}

-- Walk the snapshot once to collect every unique crate name (excluding the
-- synthetic workspace-root container, path deps, and proc-macro shims that
-- aren't on crates.io).
local function postwalk_collect_names(nodes)
  local seen = {}
  local out  = {}
  local function visit(n)
    local d = n.data
    if d and d.artifact and d.artifact ~= "" and n.kind == "dep" and not seen[d.artifact] then
      -- Path / proc-macro / alt-registry deps aren't published on crates.io —
      -- their `source` field is non-empty and not the wildcard duplicate marker.
      local src = d.source or ""
      local skip = false
      if src ~= "" and src ~= "*" then
        if src:find("^/") or src:find("^[A-Za-z]:[/\\]") or src:find("proc%-macro") then
          skip = true
        end
      end
      if not skip then
        seen[d.artifact] = true
        out[#out + 1] = d.artifact
      end
    end
    for _, c in ipairs(n.children or {}) do visit(c) end
  end
  for _, n in ipairs(nodes) do visit(n) end
  return out
end

local function apply_latest(nodes, results)
  local function visit(n)
    local d = n.data
    if d and d.artifact then
      local latest = results[d.artifact]
      if latest then
        d.latest_central = latest                       -- shared field name with the maven/npm paths
        d.is_outdated    = cr.is_outdated(d.version, latest)
      end
    end
    for _, c in ipairs(n.children or {}) do visit(c) end
  end
  for _, n in ipairs(nodes) do visit(n) end
end

local function tmp_dir()
  return os.getenv("TEMP") or os.getenv("TMP") or os.getenv("TMPDIR") or "/tmp"
end

local function tmp_path(prefix, request_id)
  return arbor.fs.join(tmp_dir(),
    "arbor-" .. prefix .. "-" .. request_id:gsub("[^%w%-]", "_") .. ".txt")
end

local function build_node(tree, key, expanded)
  local c = tree.coord
  local children_nodes = {}
  for i, ch in ipairs(tree.children) do
    children_nodes[#children_nodes + 1] = build_node(ch, key .. "/" .. i, false)
  end
  local label = c.artifact .. " v" .. (c.version or "?")
  if c.source ~= "" and c.source ~= "*" then
    label = label .. "  " .. c.source
  end
  return {
    id    = "dep:" .. key,
    label = label,
    icon  = "Box",
    kind  = "dep",
    selectable = true,
    expanded   = expanded,
    data = {
      group      = c.group or "",
      artifact   = c.artifact,
      version    = c.version or "",
      scope      = c.scope or "normal",
      source     = c.source,
      duplicate  = c.duplicate or false,
      latest_central = nil,
      is_outdated    = false,
      conflict_count = 0,
    },
    children = children_nodes,
  }
end

-- `trees` is an array (parser returns one element per workspace member).
-- For a single tree we return it as the lone root; for multiple, we wrap
-- them under a synthetic "<workspace> (N crates)" container so the modal
-- has a single conceptual root and the user sees each crate as a
-- top-level expandable.
local function trees_to_nodes(trees, workspace_label)
  if not trees or #trees == 0 then return {} end
  if #trees == 1 then
    return { build_node(trees[1], "0", true) }
  end
  local children = {}
  for i, tr in ipairs(trees) do
    children[#children + 1] = build_node(tr, tostring(i - 1), false)
  end
  return {{
    id    = "ws-root",
    label = workspace_label .. "  (" .. tostring(#trees) .. " crates)",
    icon  = "Boxes",
    kind  = "section",
    selectable = false,
    expanded   = true,
    data = { group = "", artifact = workspace_label, version = "", scope = "" },
    children = children,
  }}
end

-- Cargo's tree de-duplicates paths under a `(*)` marker, but the same
-- crate may still appear at two versions across the project. Mark conflicts.
local function mark_conflicts(nodes)
  local versions = {}
  local function visit(n)
    local d = n.data
    if d and d.artifact and d.artifact ~= "" then
      versions[d.artifact] = versions[d.artifact] or {}
      if d.version and d.version ~= "" then versions[d.artifact][d.version] = true end
    end
    for _, c in ipairs(n.children or {}) do visit(c) end
  end
  for _, n in ipairs(nodes) do visit(n) end

  local function mark(n)
    local d = n.data
    if d and d.artifact then
      local count = 0
      for _ in pairs(versions[d.artifact] or {}) do count = count + 1 end
      if count > 1 then d.conflict_count = count end
    end
    for _, c in ipairs(n.children or {}) do mark(c) end
  end
  for _, n in ipairs(nodes) do mark(n) end
end

-- Detect whether the manifest declares a `[workspace]` block. We use this
-- only for the cache-key suffix and the title — for the actual cargo
-- invocation we ALWAYS pass --workspace (cargo treats single-crate
-- manifests as a workspace-of-one, so it's safe everywhere). Earlier we
-- tried to gate the flag, which silently mis-fired on some manifest
-- shapes and produced trees with only the root crate.
local function is_workspace_manifest(cargo_path)
  local body = arbor.fs.read(cargo_path)
  if not body or body == "" then return false end
  -- Lenient match: leading whitespace allowed, comment after the header
  -- allowed. Lines like `[workspace.package]` or `[workspace.dependencies]`
  -- must NOT match — we anchor the closing bracket immediately after the
  -- word `workspace`.
  for line in body:gmatch("[^\r\n]+") do
    local trimmed = line:gsub("^%s+", ""):gsub("#.*$", ""):gsub("%s+$", "")
    if trimmed == "[workspace]" then return true end
  end
  return false
end

local function workspace_label(cargo_path, module_dir)
  -- Try to surface the workspace name (resolver.workspace.package.name or
  -- the parent directory name). Cheap heuristic — falls back to the
  -- folder when nothing is parseable.
  local body = arbor.fs.read(cargo_path) or ""
  local pkg = body:match("\n%[workspace%.package%][^%[]*") or ""
  local name = pkg:match("name%s*=%s*\"([^\"]+)\"")
  if name and name ~= "" then return name end
  return module_dir:match("[/\\]([^/\\]+)[/\\]?$") or module_dir
end

function M.resolve(ctx)
  local request_id = ctx.request_id
  local sid        = ctx.sidebar_id
  local label      = ctx.label
  local module_dir = ctx.module_dir
  local cargo_path = ctx.cargo_path or arbor.fs.join(module_dir, "Cargo.toml")
  local cargo_lock = arbor.fs.join(module_dir, "Cargo.lock")
  local is_ws      = is_workspace_manifest(cargo_path)
  -- Different cache key per workspace/non-workspace mode so toggling the
  -- manifest type doesn't serve a stale "single crate" snapshot.
  local cache_key  = (is_ws and "cargo-ws:" or "cargo:") .. module_dir
  -- Cargo.lock pins the exact resolved versions, so any lockfile change
  -- invalidates the cached tree even when Cargo.toml is unchanged.
  local cache_files = { cargo_path, cargo_lock }

  if not ctx.force then
    local cached = cache.lookup(cache_key, cache_files)
    if cached and cached.nodes then
      arbor.ui.tree.set(sid, cached)
      local names = postwalk_collect_names(cached.nodes)
      if #names > 0 then
        cr.fetch_many(names, function(results)
          apply_latest(cached.nodes, results)
          arbor.ui.tree.set(sid, cached)
        end)
      end
      return
    end
  end

  if not arbor.fs.is_file(cargo_path) then
    arbor.ui.tree.set(sid, {
      title = "Cargo dependencies — " .. label,
      nodes = {{
        id = "err", label = "Cargo.toml not found at " .. cargo_path,
        icon = "AlertCircle", kind = "deps:status", selectable = false,
        expanded = false, data = { status = "error" }, children = {},
      }},
    })
    return
  end

  local out_file = tmp_path("cargo-tree", request_id)
  -- Speed knobs:
  --   --offline / --frozen   skip network refresh; relies on the local
  --                          registry cache + Cargo.lock. Falls back to a
  --                          plain run if cargo errors out (e.g. uncached
  --                          deps on first analysis after a clean checkout).
  --   --workspace            only when the manifest declares one — emits
  --                          one tree per member, our parser folds them
  --                          into separate roots.
  local fast_flags = " --offline --frozen"
  if not arbor.fs.is_file(cargo_lock) then
    -- Without Cargo.lock --frozen would fail; let cargo resolve normally.
    fast_flags = ""
  end
  local ws_flag = is_ws and " --workspace" or ""
  local base = string.format(
    'cargo tree --charset ascii --color never%s%s --manifest-path "%s"',
    ws_flag, fast_flags, cargo_path)
  local cmd = string.format('%s > "%s"', base, out_file)

  -- If the offline run fails (typical first-analysis path on a fresh
  -- checkout: registry cache empty), retry once without `--offline/--frozen`
  -- so the user gets a result instead of a hard error. The chained shell
  -- `||` keeps both attempts inside a single job so we don't pollute the
  -- Jobs panel with a transient failure.
  local cmd_with_fallback = cmd
  if fast_flags ~= "" then
    local fallback = string.format(
      'cargo tree --charset ascii --color never%s --manifest-path "%s" > "%s"',
      ws_flag, cargo_path, out_file)
    if package.config:sub(1, 1) == "\\" then
      cmd_with_fallback = string.format('%s || %s', cmd, fallback)
    else
      cmd_with_fallback = string.format('%s || %s', cmd, fallback)
    end
  end

  -- Resolve the rust toolchain env so `cargo tree` runs against the same
  -- toolchain the user pinned in compile-action's settings (active rust
  -- toolchain). Without this we'd pick up whatever cargo lands on PATH,
  -- which on Windows is often a stale system install.
  local function resolve_rust_env()
    local active = arbor.toolchain.active("rust")
    if not active then return {} end
    return arbor.toolchain.env{ kind = "rust", id = active.id } or {}
  end

  arbor.job.spawn({
    name     = "cargo tree — " .. label,
    command  = cmd_with_fallback,
    cwd      = module_dir,
    env      = resolve_rust_env(),
    category = "Deps Explorer",
    on_done  = function(jc)
      if not jc.success then
        arbor.ui.tree.set(sid, {
          title = "Cargo dependencies — " .. label,
          nodes = {{
            id = "err",
            label = "cargo tree failed (exit " .. (jc.exit_code or -1)
                     .. "). Check the Jobs panel.",
            icon = "AlertCircle", kind = "deps:status",
            selectable = false, expanded = false,
            data = { status = "error" }, children = {},
          }},
        })
        arbor.fs.delete(out_file)
        return
      end

      local body = arbor.fs.read(out_file)
      arbor.fs.delete(out_file)
      local trees = parser.parse(body)
      if not trees then
        arbor.ui.tree.set(sid, {
          title = "Cargo dependencies — " .. label,
          nodes = {{
            id = "err", label = "Couldn't parse cargo tree output.",
            icon = "AlertCircle", kind = "deps:status",
            selectable = false, expanded = false,
            data = { status = "error" }, children = {},
          }},
        })
        return
      end

      local nodes = trees_to_nodes(trees, workspace_label(cargo_path, module_dir))
      mark_conflicts(nodes)
      local snapshot = {
        title = "Cargo dependencies — " .. label,
        nodes = nodes,
      }
      arbor.ui.tree.set(sid, snapshot)
      pcall(cache.put, cache_key, cache_files, snapshot)

      -- 2nd push (async): patch with latest versions from crates.io.
      local names = postwalk_collect_names(nodes)
      if #names > 0 then
        cr.fetch_many(names, function(results)
          apply_latest(nodes, results)
          arbor.ui.tree.set(sid, snapshot)
        end)
      end
    end,
  })
end

return M
