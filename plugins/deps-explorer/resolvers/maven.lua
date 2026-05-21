-- resolvers/maven.lua
--
-- Pipeline:
--   1. Ask compile-action for the JAVA_HOME of the active build (so the user
--      runs mvn under the same JDK they see in the compile combo). Falls
--      back to the active JDK toolchain when the active build isn't a JVM
--      template; falls back further to the OS PATH when no JDK is registered.
--   2. Spawn `mvn -B -f <pom> dependency:tree -DoutputFile=<tmp>` and read
--      the output file in on_done.
--   3. Parse the tree, build the snapshot in deps-explorer's tree-node shape,
--      detect version conflicts, and push it via arbor.ui.tree.set.
--   4. Fan out Maven Central lookups for every unique (group, artifact);
--      patch the snapshot when results land.

local parser = require("parsers.maven_tree")
local mc     = require("maven_central")
local cache  = require("deps_cache")

local M = {}

local function tmp_dir()
  return os.getenv("TEMP") or os.getenv("TMP") or os.getenv("TMPDIR") or "/tmp"
end

local function tmp_path(prefix, request_id)
  return arbor.fs.join(tmp_dir(),
    "arbor-" .. prefix .. "-" .. request_id:gsub("[^%w%-]", "_") .. ".txt")
end

-- Async resolver: feeds the callback with a JAVA_HOME string (empty when
-- compile-action isn't loaded, the call rejects, or no toolchain is active).
local function resolve_java_home_sync(callback)
  local ok, err = pcall(function()
    arbor.service.call("compile-action.resolve_java_home", {})
      :ok(function(result)
        local jh = (type(result) == "table" and result.ok and result.java_home) or ""
        callback(jh)
      end)
      :err(function(_e) callback("") end)
  end)
  if not ok then
    arbor.log.warn("[deps-explorer/maven] resolve_java_home call failed: " .. tostring(err))
    callback("")
  end
end

-- Build the env map: JAVA_HOME (if any) + PATH adjusted so that
-- "<JAVA_HOME>/bin" is first. Without that, plugins on Windows tend to pick
-- up whatever `java` lands on PATH (often a system JRE).
local function build_env(java_home)
  local env = {}
  if java_home and java_home ~= "" then
    env.JAVA_HOME = java_home
    local sep    = package.config:sub(3, 3) -- ';' on Win, ':' on Unix
    local path   = os.getenv("PATH") or ""
    env.PATH     = arbor.fs.join(java_home, "bin") .. sep .. path
  end
  return env
end

-- Walk the parsed tree (returned by the maven_tree parser) into the TreeNode
-- shape consumed by the modal. We tag each node with a deterministic id so
-- the Tree widget's expand-state map doesn't collide across siblings sharing
-- a coordinate (legal in Maven via classifiers).
local function tree_to_nodes(tree, path)
  if not tree then return {} end
  local function visit(node, key)
    local c = node.coord
    local children_nodes = {}
    for i, ch in ipairs(node.children) do
      children_nodes[#children_nodes + 1] = visit(ch, key .. "/" .. i)
    end
    local label = c.artifact .. ":" .. (c.version or "?")
    if c.classifier and c.classifier ~= "" then
      label = label .. " [" .. c.classifier .. "]"
    end
    local omitted = c.omitted
    return {
      id    = "dep:" .. key,
      label = label,
      icon  = "Box",
      kind  = "dep",
      selectable = true,
      expanded   = (key == "0"),  -- root expanded; rest collapsed
      data = {
        group      = c.group,
        artifact   = c.artifact,
        version    = c.version or "",
        scope      = c.scope or "compile",
        packaging  = c.packaging,
        classifier = c.classifier,
        omitted    = omitted,
        -- Filled in by the Maven Central pass:
        latest_central = nil,
        is_outdated    = false,
        -- Filled by the post-walk:
        conflict_count = 0,
      },
      children = children_nodes,
    }
  end
  return { visit(tree, "0") }
end

-- Walk the snapshot to compute conflicts (same group:artifact at different
-- versions across the tree) and collect the unique (group, artifact) pairs
-- we should query Maven Central for.
local function postwalk(nodes)
  local versions = {}     -- "g:a" → set of versions seen
  local pairs_set = {}    -- "g:a" → { group, artifact }

  local function visit(n)
    local d = n.data
    if d and d.group and d.artifact then
      local key = d.group .. ":" .. d.artifact
      versions[key] = versions[key] or {}
      if d.version and d.version ~= "" then versions[key][d.version] = true end
      if not pairs_set[key] then
        pairs_set[key] = { group = d.group, artifact = d.artifact }
      end
    end
    for _, c in ipairs(n.children or {}) do visit(c) end
  end
  for _, n in ipairs(nodes) do visit(n) end

  -- Mark conflicts.
  local function mark(n)
    local d = n.data
    if d and d.group and d.artifact then
      local key = d.group .. ":" .. d.artifact
      local count = 0
      for _ in pairs(versions[key] or {}) do count = count + 1 end
      if count > 1 then d.conflict_count = count end
    end
    for _, c in ipairs(n.children or {}) do mark(c) end
  end
  for _, n in ipairs(nodes) do mark(n) end

  -- Flatten unique pair list.
  local out = {}
  for _, p in pairs(pairs_set) do out[#out + 1] = p end
  return out
end

-- Patch the tree in place with maven-central results.
local function apply_central(nodes, results)
  local function visit(n)
    local d = n.data
    if d and d.group and d.artifact then
      local key = d.group .. ":" .. d.artifact
      local latest = results[key]
      if latest then
        d.latest_central = latest
        d.is_outdated    = mc.is_outdated(d.version, latest)
      end
    end
    for _, c in ipairs(n.children or {}) do visit(c) end
  end
  for _, n in ipairs(nodes) do visit(n) end
end

-- ── Public ───────────────────────────────────────────────────────────────────

function M.resolve(ctx)
  local request_id = ctx.request_id
  local sid        = ctx.sidebar_id
  local label      = ctx.label
  local module_dir = ctx.module_dir
  local pom_path   = ctx.pom_path or arbor.fs.join(module_dir, "pom.xml")
  local cache_key  = "maven:" .. module_dir
  local cache_files = { pom_path }

  if not arbor.fs.is_file(pom_path) then
    arbor.ui.tree.set(sid, {
      title = "Maven dependencies — " .. label,
      nodes = {{
        id = "err", label = "pom.xml not found at " .. pom_path,
        icon = "AlertCircle", kind = "deps:status", selectable = false,
        expanded = false, data = { status = "error" }, children = {},
      }},
    })
    return
  end

  -- Cache hit shortcut: serve the bare tree instantly, then run the Maven
  -- Central pass on top (which is itself cached in maven_central.lua, so
  -- it usually completes in milliseconds too).
  if not ctx.force then
    local cached = cache.lookup(cache_key, cache_files)
    if cached and cached.nodes then
      arbor.ui.tree.set(sid, cached)
      local pairs_to_query = postwalk(cached.nodes)
      if #pairs_to_query > 0 then
        mc.fetch_many(pairs_to_query, function(results)
          apply_central(cached.nodes, results)
          arbor.ui.tree.set(sid, cached)
        end)
      end
      return
    end
  end

  resolve_java_home_sync(function(java_home)
    local env = build_env(java_home)
    local out_file = tmp_path("mvn-tree", request_id)
    local cmd = string.format(
      'mvn -B -f "%s" dependency:tree -DoutputType=text -DoutputFile="%s"',
      pom_path, out_file)

    arbor.job.spawn({
      name     = "Maven dependency:tree — " .. label,
      command  = cmd,
      cwd      = module_dir,
      env      = env,
      category = "Deps Explorer",
      on_done  = function(jc)
        if not jc.success then
          arbor.ui.tree.set(sid, {
            title = "Maven dependencies — " .. label,
            nodes = {{
              id    = "err",
              label = "mvn dependency:tree failed (exit " .. (jc.exit_code or -1)
                       .. "). Check the Jobs panel for details.",
              icon  = "AlertCircle",
              kind  = "deps:status",
              selectable = false, expanded = false,
              data = { status = "error", java_home = java_home }, children = {},
            }},
          })
          arbor.fs.delete(out_file)
          return
        end

        local body = arbor.fs.read(out_file)
        arbor.fs.delete(out_file)
        local tree = parser.parse(body or "")
        if not tree then
          -- Surface the first lines of whatever Maven actually wrote to the
          -- output file so the user can spot mvn warnings, an unexpected
          -- format, or an empty file (mvn succeeded but produced nothing).
          local snippet = "(empty)"
          if body and body ~= "" then
            snippet = body:sub(1, 400):gsub("\r", "")
            if #body > 400 then snippet = snippet .. " …" end
          end
          arbor.log.warn("[deps-explorer/maven] parse failed; output head: " .. snippet)
          arbor.ui.tree.set(sid, {
            title = "Maven dependencies — " .. label,
            nodes = {{
              id = "err",
              label = "Couldn't parse dependency:tree output. First lines: "
                       .. snippet,
              icon = "AlertCircle", kind = "deps:status",
              selectable = false, expanded = false,
              data = { status = "error", raw_output = snippet }, children = {},
            }},
          })
          return
        end

        local nodes = tree_to_nodes(tree)
        local pairs_to_query = postwalk(nodes)

        -- 1st push: tree without Maven Central data (modal renders deps now).
        local snapshot = {
          title = "Maven dependencies — " .. label,
          nodes = nodes,
        }
        arbor.ui.tree.set(sid, snapshot)

        -- Persist the bare tree so re-opening this module is instant. We
        -- cache BEFORE the Central pass because central data is itself
        -- cached separately and re-applied on every lookup.
        pcall(cache.put, cache_key, cache_files, snapshot)

        -- 2nd push (async): patch with maven-central results.
        if #pairs_to_query > 0 then
          mc.fetch_many(pairs_to_query, function(results)
            apply_central(nodes, results)
            arbor.ui.tree.set(sid, snapshot)
          end)
        end
      end,
    })
  end)
end

return M
