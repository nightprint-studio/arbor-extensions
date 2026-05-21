-- resolvers/gradle.lua

local parser = require("parsers.gradle_deps")
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

-- Pick the Gradle invocation: prefer the wrapper in the repo (consistent
-- versions across machines) and fall back to a plain `gradle` on PATH.
local function gradle_cmd(repo_path)
  if package.config:sub(1, 1) == "\\" then
    if arbor.fs.is_file(arbor.fs.join(repo_path, "gradlew.bat")) then
      return ".\\gradlew.bat"
    end
  else
    if arbor.fs.is_file(arbor.fs.join(repo_path, "gradlew")) then
      return "./gradlew"
    end
  end
  return "gradle"
end

local function resolve_java_home_async(callback)
  -- service.call may raise if compile-action isn't loaded (no svc registry);
  -- pcall guards that and feeds the callback an empty JAVA_HOME.
  local ok, err = pcall(function()
    arbor.service.call("compile-action.resolve_java_home", {})
      :ok(function(result)
        local jh = (type(result) == "table" and result.ok and result.java_home) or ""
        callback(jh)
      end)
      :err(function(_e) callback("") end)
  end)
  if not ok then
    arbor.log.warn("[deps-explorer/gradle] resolve_java_home failed: " .. tostring(err))
    callback("")
  end
end

local function build_env(java_home)
  local env = {}
  if java_home and java_home ~= "" then
    env.JAVA_HOME = java_home
    local sep   = package.config:sub(3, 3)
    local path  = os.getenv("PATH") or ""
    env.PATH    = arbor.fs.join(java_home, "bin") .. sep .. path
  end
  return env
end

local function tree_to_nodes(tree)
  if not tree then return {} end
  local function visit(node, key)
    local c = node.coord
    local children_nodes = {}
    for i, ch in ipairs(node.children) do
      children_nodes[#children_nodes + 1] = visit(ch, key .. "/" .. i)
    end
    local label
    if c.group == "(project)" then
      label = "project " .. c.artifact
    else
      label = c.artifact .. ":" .. (c.version ~= "" and c.version or "?")
      if c.requested and c.requested ~= "" and c.requested ~= c.version then
        label = label .. "  (req " .. c.requested .. ")"
      end
    end
    return {
      id    = "dep:" .. key,
      label = label,
      icon  = "Box",
      kind  = "dep",
      selectable = true,
      expanded   = (key == "0"),
      data = {
        group      = c.group or "",
        artifact   = c.artifact,
        version    = c.version or "",
        requested  = c.requested or "",
        scope      = "compile",
        latest_central = nil,
        is_outdated    = false,
        conflict_count = 0,
      },
      children = children_nodes,
    }
  end
  return { visit(tree, "0") }
end

local function postwalk(nodes)
  local versions = {}
  local pairs_set = {}
  local function visit(n)
    local d = n.data
    if d and d.group and d.artifact and d.group ~= "" and d.group ~= "(project)" then
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

  local out = {}
  for _, p in pairs(pairs_set) do out[#out + 1] = p end
  return out
end

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

function M.resolve(ctx)
  local request_id = ctx.request_id
  local sid        = ctx.sidebar_id
  local label      = ctx.label
  local module_dir = ctx.module_dir
  -- Fingerprint over every Gradle build script we can find. Any of these
  -- changing should invalidate the cached tree.
  local cache_key  = "gradle:" .. module_dir
  local cache_files = {
    arbor.fs.join(module_dir, "build.gradle"),
    arbor.fs.join(module_dir, "build.gradle.kts"),
    arbor.fs.join(module_dir, "settings.gradle"),
    arbor.fs.join(module_dir, "settings.gradle.kts"),
    arbor.fs.join(module_dir, "gradle.properties"),
  }

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

  resolve_java_home_async(function(java_home)
    local env      = build_env(java_home)
    local out_file = tmp_path("gradle-deps", request_id)
    local cmd      = gradle_cmd(module_dir)
        .. ' dependencies --configuration runtimeClasspath --console=plain'
    -- Capture stdout to file via shell redirect — gradle has no -DoutputFile.
    local full_cmd
    if package.config:sub(1, 1) == "\\" then
      full_cmd = string.format('%s > "%s" 2>nul', cmd, out_file)
    else
      full_cmd = string.format('%s > "%s" 2>/dev/null', cmd, out_file)
    end

    arbor.job.spawn({
      name     = "gradle dependencies — " .. label,
      command  = full_cmd,
      cwd      = module_dir,
      env      = env,
      category = "Deps Explorer",
      on_done  = function(jc)
        local body = arbor.fs.read(out_file)
        arbor.fs.delete(out_file)
        if not jc.success or not body then
          arbor.ui.tree.set(sid, {
            title = "Gradle dependencies — " .. label,
            nodes = {{
              id = "err",
              label = "gradle dependencies failed (exit " .. (jc.exit_code or -1)
                       .. "). Check the Jobs panel.",
              icon = "AlertCircle", kind = "deps:status",
              selectable = false, expanded = false,
              data = { status = "error" }, children = {},
            }},
          })
          return
        end

        local tree = parser.parse(body, "runtimeClasspath")
                  or parser.parse(body, "compileClasspath")
        if not tree then
          arbor.ui.tree.set(sid, {
            title = "Gradle dependencies — " .. label,
            nodes = {{
              id = "err",
              label = "Couldn't find runtimeClasspath / compileClasspath in the output.",
              icon = "AlertCircle", kind = "deps:status",
              selectable = false, expanded = false,
              data = { status = "error" }, children = {},
            }},
          })
          return
        end

        local nodes = tree_to_nodes(tree)
        local pairs_to_query = postwalk(nodes)
        local snapshot = {
          title = "Gradle dependencies — " .. label,
          nodes = nodes,
        }
        arbor.ui.tree.set(sid, snapshot)
        pcall(cache.put, cache_key, cache_files, snapshot)

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
