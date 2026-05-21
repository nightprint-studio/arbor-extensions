-- resolvers/npm.lua — Run `npm ls / pnpm list / yarn list` and parse JSON.

local parser = require("parsers.npm_ls")
local cache  = require("deps_cache")
local nr     = require("npm_registry")

local M = {}

-- Collect every unique package name in the snapshot, then patch each node's
-- data with the latest version on the npm registry. Mirrors maven_central's
-- two-pass design — the modal renders the resolved tree first, the latest-
-- version badges land a second or two later.
local function postwalk_collect_names(nodes)
  local seen = {}
  local out  = {}
  local function visit(n)
    local d = n.data
    -- Only fetch latest for artifacts that have an installed version: with
    -- no installed version we can't compute "outdated" anyway, and querying
    -- the registry for ghost optional deps just wastes HTTP round-trips.
    if d and d.artifact and d.artifact ~= ""
       and d.version and d.version ~= ""
       and not seen[d.artifact] then
      seen[d.artifact] = true
      out[#out + 1] = d.artifact
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
        d.latest_central = latest                       -- field name shared with the maven path so the modal renders it uniformly
        d.is_outdated    = nr.is_outdated(d.version, latest)
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
    "arbor-" .. prefix .. "-" .. request_id:gsub("[^%w%-]", "_") .. ".json")
end

-- Build the right "list deps as JSON" command per package manager. Yarn
-- classic emits NDJSON which we don't parse yet — fall back to npm there.
local function pm_command(pm, out_file)
  if pm == "pnpm" then
    return string.format('pnpm list --depth=Infinity --json > "%s"', out_file)
  end
  -- npm + yarn classic + unknown all use npm ls — yarn keeps a node_modules
  -- compatible enough for `npm ls` to walk it most of the time.
  -- `--silent` keeps lockfile-warnings out of the JSON; `|| true` lets us
  -- still consume partial output when npm exits non-zero on missing peers
  -- (very common in real codebases).
  return string.format(
    'npm ls --all --json --silent > "%s" 2>nul || cmd /c exit 0',
    out_file)
end

-- POSIX equivalent of the trailing `cmd /c exit 0` chunk above. We pick the
-- right tail at runtime so the command works on both Windows cmd and Unix sh.
local function pm_command_posix(pm, out_file)
  if pm == "pnpm" then
    return string.format('pnpm list --depth=Infinity --json > "%s"', out_file)
  end
  return string.format(
    'npm ls --all --json --silent > "%s" 2>/dev/null; true',
    out_file)
end

local function build_command(pm, out_file)
  if package.config:sub(1, 1) == "\\" then
    return pm_command(pm, out_file)
  else
    return pm_command_posix(pm, out_file)
  end
end

local function tree_to_nodes(tree)
  if not tree then return {} end
  local function visit(node, key, scope)
    local c = node.coord
    local children_nodes = {}
    for i, ch in ipairs(node.children or {}) do
      children_nodes[#children_nodes + 1] = visit(ch, key .. "/" .. i, c.scope or scope)
    end
    local label = c.artifact .. (c.version ~= "" and (" v" .. c.version) or "")
    if c.missing then label = label .. "  (missing)" end
    if c.extraneous then label = label .. "  (extraneous)" end
    return {
      id    = "dep:" .. key,
      label = label,
      icon  = "Package",
      kind  = "dep",
      selectable = true,
      expanded   = (key == "0"),
      data = {
        group      = "",
        artifact   = c.artifact,
        version    = c.version or "",
        scope      = c.scope or scope or "prod",
        source     = c.source,
        missing    = c.missing or false,
        extraneous = c.extraneous or false,
        peer       = c.peer or false,
        latest_central = nil,
        is_outdated    = false,
        conflict_count = 0,
      },
      children = children_nodes,
    }
  end
  return { visit(tree, "0", "root") }
end

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

function M.resolve(ctx)
  local request_id = ctx.request_id
  local sid        = ctx.sidebar_id
  local label      = ctx.label
  local module_dir = ctx.module_dir
  local pm         = ctx.pm or "npm"
  local pkg_path   = arbor.fs.join(module_dir, "package.json")
  -- Lockfiles pin resolved versions; we fingerprint whichever ones exist so
  -- e.g. a `pnpm-lock.yaml` change invalidates the cached tree.
  local cache_key  = "npm:" .. pm .. ":" .. module_dir
  local cache_files = {
    pkg_path,
    arbor.fs.join(module_dir, "package-lock.json"),
    arbor.fs.join(module_dir, "pnpm-lock.yaml"),
    arbor.fs.join(module_dir, "yarn.lock"),
  }

  if not ctx.force then
    local cached = cache.lookup(cache_key, cache_files)
    if cached and cached.nodes then
      arbor.ui.tree.set(sid, cached)
      -- Run the npm-registry pass on top of the cached tree (its own cache
      -- usually serves it in milliseconds).
      local names = postwalk_collect_names(cached.nodes)
      if #names > 0 then
        nr.fetch_many(names, function(results)
          apply_latest(cached.nodes, results)
          arbor.ui.tree.set(sid, cached)
        end)
      end
      return
    end
  end

  if not arbor.fs.is_file(pkg_path) then
    arbor.ui.tree.set(sid, {
      title = "npm dependencies — " .. label,
      nodes = {{
        id = "err", label = "package.json not found at " .. pkg_path,
        icon = "AlertCircle", kind = "deps:status", selectable = false,
        expanded = false, data = { status = "error" }, children = {},
      }},
    })
    return
  end

  local out_file = tmp_path(pm .. "-ls", request_id)
  local cmd = build_command(pm, out_file)

  -- Resolve the node toolchain env so `npm/pnpm/yarn ls` runs against the
  -- node version the user pinned in compile-action's settings (active node
  -- toolchain). Without this we'd pick up whatever node lands on PATH.
  local function resolve_node_env()
    local active = arbor.toolchain.active("node")
    if not active then return {} end
    return arbor.toolchain.env{ kind = "node", id = active.id } or {}
  end

  arbor.job.spawn({
    name     = pm .. " ls — " .. label,
    command  = cmd,
    cwd      = module_dir,
    env      = resolve_node_env(),
    category = "Deps Explorer",
    on_done  = function(jc)
      local body = arbor.fs.read(out_file) or ""
      arbor.fs.delete(out_file)

      local tree = parser.parse(body)
      if not tree then
        arbor.ui.tree.set(sid, {
          title = "npm dependencies — " .. label,
          nodes = {{
            id = "err",
            label = "Couldn't parse `" .. pm .. "` output (exit " .. (jc.exit_code or -1)
                     .. "). Try `" .. pm .. " install` first.",
            icon = "AlertCircle", kind = "deps:status",
            selectable = false, expanded = false,
            data = { status = "error" }, children = {},
          }},
        })
        return
      end

      local nodes = tree_to_nodes(tree)
      mark_conflicts(nodes)
      local snapshot = {
        title = "npm dependencies — " .. label,
        nodes = nodes,
      }
      arbor.ui.tree.set(sid, snapshot)
      pcall(cache.put, cache_key, cache_files, snapshot)

      -- 2nd push (async): patch with latest versions from the npm registry.
      local names = postwalk_collect_names(nodes)
      if #names > 0 then
        nr.fetch_many(names, function(results)
          apply_latest(nodes, results)
          arbor.ui.tree.set(sid, snapshot)
        end)
      end
    end,
  })
end

return M
