-- compile-action / main.lua — thin wiring (build-only)
-- The run side lives in the separate `run-action` plugin which depends on
-- this one and orchestrates builds via:
--   · arbor.service.call("compile-action.spawn_build", ...)
--   · arbor.events.on("compile-action:build-done", ...)

local state     = require("state")
local detect    = require("detect")
local defs      = require("defaults")
local gcfg      = require("config.global")
local pcfg      = require("config.project")
local jdk       = require("config.jdk")
local combo     = require("ui.combo")
local sidebar   = require("ui.sidebar")
local templates = require("config.templates")

-- ── Lifecycle ─────────────────────────────────────────────────────────────────

-- ── Profile helpers ───────────────────────────────────────────────────────────

local PROFILES = {
  { value = "dev",  label = "dev",  color = "dev"  },
  { value = "prod", label = "prod", color = "prod" },
  { value = "test", label = "test", color = "test" },
  { value = "none", label = "none", color = "none" },
}

local function load_profile()
  local ok, v = pcall(function() return arbor.settings.project.get("active_profile") end)
  return (ok and v and v ~= "") and v or "dev"
end

local function save_profile(p)
  pcall(function() arbor.settings.project.set("active_profile", p or "dev") end)
end

-- ── Lifecycle ─────────────────────────────────────────────────────────────────

arbor.events.on("on_plugin_load", function(ctx)
  combo.register()

  -- New: register the IntelliJ-style "Build & Run" tree sidebar + declare
  -- the contribution points consumed by run-action and the maven update-deps
  -- plugin. The combo button + F9 keybinding are kept untouched — they're
  -- complementary entry points that work alongside the sidebar.
  sidebar.register()

  -- Register the settings panel up-front so the gear icon in the Plugin
  -- Manager appears immediately (the manager derives `has settings` from
  -- the contributions to `arbor:settings:panel`). The panel's `on_load`
  -- fires every time the modal opens — we use it to refresh the JDK / Node
  -- / Rust section contributions with the current toolchain state, so the
  -- modal always shows what's on disk right now.
  arbor.ui.settings.panel({
    id           = "main",
    title        = "Compile · Build & Toolchains",
    icon         = "Settings",
    width        = "880px",
    submit_label = "Close",
    on_load      = "compile:settings_refresh",
  })
  -- Declare the contribution points external plugins can extend.
  -- Documentation-only — the registry never validates payloads.
  arbor.ui.contribution_point({
    name = "compile-action:settings:category",
    description = "Sidebar entry in compile-action's settings panel. "
              .. "Payload: { label, icon?, priority?, description? }.",
  })
  arbor.ui.contribution_point({
    name = "compile-action:settings:section",
    description = "Content card inside a category. Payload: "
              .. "{ category, label?, icon?, count?, add_action?, "
              .. "nodes (FormNode[]), on_load?, on_save?, priority? }. "
              .. "Sections without `category` go to a synthetic 'general' entry.",
  })
  arbor.ui.contribution_point({
    name = "compile-action:settings:on_open",
    description = "Pre-open hook contribution. Payload: { action }. "
              .. "Each contributed action is fired SYNCHRONOUSLY by the "
              .. "orchestrator before the modal opens, giving the contributor "
              .. "a chance to re-contribute its categories/sections with "
              .. "fresh state.",
  })

  -- Profile pill in RepoActions: picks the active build environment.
  arbor.ui.add_graph_combo({
    id            = "active-profile",
    run_action    = "compile:set_profile",
    select_action = "compile:set_profile",
    target        = "repo_actions",
    variant       = "profile",
    tooltip       = "Active build profile",
    options       = PROFILES,
  })

  arbor.keybinding.register({
    key         = "F9",
    ctrl        = true,
    action      = "compile:run",
    description = "Build selected configuration",
  })

  arbor.log.info("ready (api_version=" .. ctx.api_version .. ")")
end)

-- ── Shared logic: detect project type, populate build combo ──────────────────

local function on_repo_activated(path)
  if path == "" then return end

  state.set_repo(path)

  local proj_type   = detect.detect(path)
  local stored_type = arbor.settings.project.get("detected_type") or ""
  local type_changed = proj_type and proj_type ~= stored_type

  if #pcfg.load() == 0 or type_changed then
    if proj_type then
      pcfg.save(defs.for_type(proj_type, path))
      arbor.settings.project.set("detected_type", proj_type)
      arbor.log.info("detected " .. proj_type ..
        ", created " .. #pcfg.load() .. " default build configurations")
    end
  end

  local sel_build  = pcfg.load_selected()
  local all_build  = pcfg.load()
  local found_build = false
  for _, c in ipairs(all_build) do if c.id == sel_build then found_build = true; break end end

  if not found_build then
    local default_id = proj_type and gcfg.load_default_profile(proj_type) or ""
    if default_id ~= "" and gcfg.find(default_id) then
      sel_build = default_id
    elseif #all_build > 0 then
      sel_build = all_build[1].id
    end
    if sel_build ~= "" then pcfg.save_selected(sel_build) end
  end

  combo.refresh(sel_build ~= "" and sel_build or nil)
  sidebar.refresh(path)

  -- Restore persisted profile selection for this repo.
  local prof = load_profile()
  arbor.ui.set_combo_options{ id = "active-profile", options = PROFILES, selected = prof }
end

arbor.events.on("on_repo_open", function(ctx)
  on_repo_activated(ctx.path or ctx.repo or "")
end)

arbor.events.on("on_tab_switch", function(ctx)
  on_repo_activated(ctx.path or "")
end)

-- ── Build resolver ────────────────────────────────────────────────────────────
-- Given an optional build_id, returns the build config to use or nil.

local function resolve_build_cfg(build_id)
  local preferred = build_id or ""
  if preferred ~= "" then
    local cfg = pcfg.find(preferred) or gcfg.find(preferred)
    if cfg then return cfg end
  end

  local sel_id = pcfg.load_selected() or ""
  if sel_id ~= "" then
    local cfg = pcfg.find(sel_id) or gcfg.find(sel_id)
    if cfg then return cfg end
  end

  local all_p = pcfg.load()
  if #all_p > 0 then return all_p[1] end
  local all_g = gcfg.load()
  if #all_g > 0 then return all_g[1] end

  return nil
end

-- ── Build spawn ───────────────────────────────────────────────────────────────
-- Spawns a build for the given repo. Returns the spawned job id AND the
-- effective JAVA_HOME used (so callers, like run-action, can pass it to the
-- run job). Emits `compile-action:build-started` / `compile-action:build-done`
-- on the bus when the build starts / completes.

-- Resolve the env for a build. Layered (each later layer wins on conflicts):
--   1. cfg.env                 (explicit user kv_list — base)
--   2. template-derived env    (MAVEN_OPTS / GRADLE_OPTS / RUSTFLAGS / NODE_OPTIONS)
--   3. profile_env[<active>]   (per-profile overrides)
--   4. toolchain env           (JAVA_HOME / PATH — only fills missing keys, so
--                                explicit user values still win)
-- The first three layers are computed by templates.resolve_effective_env;
-- toolchain layering happens here so the global active-toolchain fallback
-- stays close to the spawn site.
local TEMPLATE_KIND = { maven = "jdk", gradle = "jdk", cargo = "rust", npm = "node", make = nil }

local function resolve_build_env(build_cfg)
  local env = templates.resolve_effective_env(build_cfg, load_profile())

  local kind = TEMPLATE_KIND[build_cfg.template_id or ""] or nil
  local tc_id = build_cfg.toolchain_id or ""

  if kind and tc_id ~= "" then
    -- Use the specific toolchain the config pinned. Toolchain only fills
    -- missing keys so user / profile values always win.
    local tc_env = arbor.toolchain.env{ kind = kind, id = tc_id } or {}
    for k, v in pairs(tc_env) do if env[k] == nil then env[k] = v end end
  elseif kind == "jdk" then
    -- Java template without a pinned JDK → fall back to active (legacy path).
    env = jdk.get_java_env(env)
  elseif kind and tc_id == "" then
    -- Node/Rust without pinned toolchain → use active.
    local active = arbor.toolchain.active(kind)
    if active then
      local tc_env = arbor.toolchain.env{ kind = kind, id = active.id } or {}
      for k, v in pairs(tc_env) do if env[k] == nil then env[k] = v end end
    end
  end
  return env
end

-- silent: when true, skips the build-lifecycle notifications (succeeded /
-- failed / cancelled / failed-to-start). Used by run-action so its run
-- flow only emits its own consolidated "started" toast + "result" bell
-- entry — without compile-action layering its own three notifications on
-- top. Direct sidebar Build clicks always pass silent=false.
-- The per-cfg `notify_on_completion` toggle adds a second mute switch on
-- top: even when silent=false, a config can opt out of completion toasts
-- (failure-to-start is always reported because the user just clicked Build
-- and needs feedback that it didn't even spawn).
local function spawn_build(build_cfg, repo_path, silent)
  local repo_folder = repo_path:match("[/\\]([^/\\]+)[/\\]?$") or repo_path
  local job_label   = build_cfg.label or build_cfg.name or "Build"
  local cwd         = (build_cfg.cwd and build_cfg.cwd ~= "") and build_cfg.cwd or repo_path
  local env         = resolve_build_env(build_cfg)
  local java_home   = env["JAVA_HOME"] or ""

  local notify_done = build_cfg.notify_on_completion
  if notify_done == nil then notify_done = true end
  local emit_done_notif = (not silent) and notify_done

  local job, spawn_err = arbor.job.spawn({
    name     = repo_folder .. " (build)",
    command  = build_cfg.command,
    cwd      = cwd,
    env      = env,
    category = "Builds",
    on_done  = function(job_ctx)
      arbor.log.info("[compile:spawn_build/on_done] ENTER"
        .. "  job_id=" .. tostring(job_ctx.job_id)
        .. "  success=" .. tostring(job_ctx.success)
        .. "  cancelled=" .. tostring(job_ctx.cancelled)
        .. "  repo_path=" .. repo_path)

      state.untrack_build(repo_path)
      pcall(sidebar.refresh, repo_path)

      if emit_done_notif then
        if job_ctx.success then
          arbor.notify{ title = "Build succeeded", message = "[" .. repo_folder .. "] " .. job_label .. " completed ✓", level = "success" }
        elseif job_ctx.cancelled then
          arbor.notify{ title = "Build cancelled", message = "[" .. repo_folder .. "] " .. job_label .. " was stopped.", level = "warning" }
        else
          arbor.notify{ title = "Build failed", message = "[" .. repo_folder .. "] " .. job_label .. " — exit code " .. job_ctx.exit_code, level = "error" }
        end
      end

      -- Broadcast on the bus so other plugins (notably run-action) can react.
      arbor.events.emit("build-done", {
        repo_path = repo_path,
        success   = job_ctx.success and true or false,
        cancelled = job_ctx.cancelled and true or false,
        exit_code = job_ctx.exit_code or -1,
        build_cfg = build_cfg,
        job_id    = job_ctx.job_id,
        java_home = java_home,
      })
    end,
  })

  if not job then
    if not silent then
      arbor.notify{ title = "Build failed to start", message = tostring(spawn_err), level = "error" }
    end
    return nil, java_home
  end

  local build_id = job.id
  state.track_build(repo_path, build_id)
  pcall(sidebar.refresh, repo_path)

  arbor.events.emit("build-started", {
    repo_path = repo_path,
    build_cfg = build_cfg,
    job_id    = build_id,
  })

  arbor.log.info("[compile:spawn_build] spawned: job_id=" .. build_id
    .. "  repo_path=" .. repo_path
    .. "  command=" .. build_cfg.command)
  return build_id, java_home
end

-- ── Before-launch chain ──────────────────────────────────────────────────────
-- Pre-tasks run sequentially in their own jobs (so each shows up in the Jobs
-- UI with its own output), and the chain stops on the first failure. Pre-task
-- env mirrors the parent build's env (toolchain + profile + derived) so
-- helpers like `mvn …` work without re-pinning the JDK in every shell row.

-- Spawn a single pre-task. Returns a JobHandle (Promise) on success, or
-- (nil, err) when the task is misconfigured.
local function spawn_pre_task(task, parent_cfg, repo_path)
  local repo_folder = repo_path:match("[/\\]([^/\\]+)[/\\]?$") or repo_path
  local kind        = task.step_type or ""
  if kind == "build" then
    local pre_cfg = pcfg.find(task.target) or gcfg.find(task.target)
    if not pre_cfg then
      return nil, "build target '" .. tostring(task.target) .. "' not found"
    end
    local env = resolve_build_env(pre_cfg)
    local cwd = (pre_cfg.cwd and pre_cfg.cwd ~= "") and pre_cfg.cwd or repo_path
    return arbor.job.spawn({
      name     = repo_folder .. " (pre: " .. (pre_cfg.name or pre_cfg.id) .. ")",
      command  = pre_cfg.command,
      cwd      = cwd,
      env      = env,
      category = "Builds",
    })
  elseif kind == "shell" then
    local cmd = task.target or ""
    if cmd == "" then return nil, "shell command is empty" end
    local env = resolve_build_env(parent_cfg)
    local cwd = (task.cwd and task.cwd ~= "") and task.cwd or repo_path
    return arbor.job.spawn({
      name     = repo_folder .. " (pre: shell)",
      command  = cmd,
      cwd      = cwd,
      env      = env,
      category = "Builds",
    })
  end
  return nil, "unknown pre-task type '" .. tostring(kind) .. "'"
end

-- Public entry: run before_launch tasks (if any) then spawn the main build.
-- When the cfg has no pre-tasks this is just a thin pass-through to
-- spawn_build (preserving synchronous semantics for the existing call sites
-- that need the build_id back). With pre-tasks, the work runs inside
-- arbor.async.run and the function returns nil — the actual build_id is
-- emitted via the `compile-action:build-started` event when it spawns.
local function start_build(build_cfg, repo_path, silent)
  local pre = build_cfg.before_launch or {}
  if #pre == 0 then
    return spawn_build(build_cfg, repo_path, silent)
  end

  local repo_folder = repo_path:match("[/\\]([^/\\]+)[/\\]?$") or repo_path
  arbor.async.run(function()
    for i, task in ipairs(pre) do
      local label = "Pre-task " .. i .. "/" .. #pre
                  .. " — " .. (task.step_type or "?")
      local handle, spawn_err = spawn_pre_task(task, build_cfg, repo_path)
      if not handle then
        arbor.notify{ title = "Pre-task failed to start",
                      message = "[" .. repo_folder .. "] " .. label
                             .. ": " .. tostring(spawn_err),
                      level = "error" }
        return
      end

      -- Track the pre-task as the active build so the "Build already in
      -- progress" guard and the toolbar Stop button work throughout the
      -- chain — Stop cancels the running pre-task, and the await below
      -- catches the cancellation and aborts the chain.
      state.track_build(repo_path, handle.id)
      pcall(sidebar.refresh, repo_path)
      local result, err = arbor.async.await(handle)
      state.untrack_build(repo_path)

      if err then
        local cancelled = err.cancelled and true or false
        local exit_code = err.exit_code or -1
        arbor.notify{
          title = cancelled and "Pre-task cancelled" or "Pre-task failed",
          message = "[" .. repo_folder .. "] " .. label
                 .. " — chain aborted (exit " .. exit_code .. ").",
          level = cancelled and "warning" or "error",
        }
        return
      end
    end
    -- All pre-tasks ok → spawn the main build.
    spawn_build(build_cfg, repo_path, silent)
  end)
  return nil, ""
end

-- ── compile:run action ────────────────────────────────────────────────────────

arbor.events.on("compile:run", function(ctx)
  local value     = ctx.value or ""
  local repo_path = state.current_repo

  if value == "__project_settings__" then
    pcfg.open_project_settings_form(repo_path)
    return
  end

  if state.get_build(repo_path) then
    local repo_folder = repo_path:match("[/\\]([^/\\]+)[/\\]?$") or repo_path
    arbor.notify{ title = "Build already in progress", message = repo_folder .. " is already building. Wait for it to finish.", level = "warning" }
    return
  end

  if value == "" then value = pcfg.load_selected() or "" end
  local cfg = resolve_build_cfg(value)
  if not cfg then
    arbor.notify{ title = "No build configuration", message = "Create a configuration first", level = "warning" }
    return
  end

  pcfg.save_selected(cfg.id)
  start_build(cfg, repo_path, false)
end)

arbor.events.on("compile:select", function(ctx)
  local value = ctx.value or ""
  if value ~= "" and value ~= "__project_settings__" then
    pcfg.save_selected(value)
  end
end)

-- ── Service exports (consumed by run-action) ─────────────────────────────────
-- Arguments and results travel as JSON, so everything must be plain data.
-- Errors are returned as { ok = false, error = <message> } rather than raised
-- so callers can react without catching typed errors.

arbor.service.export("spawn_build", function(args)
  args = args or {}
  local repo_path = args.repo_path or state.current_repo or ""
  local build_id  = args.build_id  or ""
  -- Callers (run-action) can ask compile-action to NOT emit its own
  -- build-lifecycle notifications when they're going to emit their own
  -- consolidated ones. Default false → standalone callers keep getting
  -- the full notification set.
  local silent    = args.silent and true or false

  if repo_path == "" then
    return { ok = false, error = "no active repository" }
  end

  -- If a build is already running for this repo, treat it as a success so
  -- callers can enqueue their dependent run without starting a second build.
  if state.get_build(repo_path) then
    -- We don't have the running build's cfg snapshot stored, so return the
    -- resolved one based on the current selection. This is close enough for
    -- the Tomcat WAR-dir resolution the caller needs.
    local fallback = resolve_build_cfg(build_id)
    return {
      ok              = true,
      already_running = true,
      build_cfg       = fallback,
      job_id          = state.get_build(repo_path),
    }
  end

  local cfg = resolve_build_cfg(build_id)
  if not cfg then
    return { ok = false, error = "no build configuration available" }
  end

  pcfg.save_selected(cfg.id)
  local job_id, java_home = spawn_build(cfg, repo_path, silent)
  return {
    ok        = true,
    build_cfg = cfg,
    job_id    = job_id,
    java_home = java_home,
  }
end)

arbor.service.export("get_build_config", function(args)
  local id = (args and args.id) or ""
  if id == "" then return nil end
  return pcfg.find(id) or gcfg.find(id)
end)

-- Resolve a build into the data a CALLER needs to run it themselves
-- (e.g. as a stage of their own pipeline) — without spawning anything.
-- Returns the cfg, the resolved env (incl. JAVA_HOME / PATH from the
-- pinned toolchain), the cwd, and the command. Used by run-action's
-- Tomcat pipeline so the Build stage runs in-pipeline instead of as a
-- separate Job.
arbor.service.export("resolve_build", function(args)
  args = args or {}
  local repo_path = args.repo_path or state.current_repo or ""
  if repo_path == "" then
    return { ok = false, error = "no active repository" }
  end
  local cfg = resolve_build_cfg(args.build_id or "")
  if not cfg then
    return { ok = false, error = "no build configuration available" }
  end
  local env  = resolve_build_env(cfg)
  local cwd  = (cfg.cwd and cfg.cwd ~= "") and cfg.cwd or repo_path
  local label = cfg.label or cfg.name or cfg.id or "Build"
  return {
    ok        = true,
    build_cfg = cfg,
    env       = env,
    command   = cfg.command,
    cwd       = cwd,
    label     = label,
    java_home = env["JAVA_HOME"] or "",
  }
end)

arbor.service.export("list_build_configs", function(_args)
  local project = {}
  pcall(function() project = pcfg.load() end)
  return { project = project, global = gcfg.load() }
end)

arbor.service.export("get_active_profile", function(_args)
  local profile = ""
  pcall(function() profile = load_profile() end)
  return { profile = profile ~= "" and profile or "dev" }
end)

arbor.service.export("get_selected_build_id", function(_args)
  local sel = ""
  pcall(function() sel = pcfg.load_selected() end)
  return { id = sel or "" }
end)

arbor.service.export("is_building", function(args)
  local repo_path = (args and args.repo_path) or state.current_repo or ""
  local job_id = state.get_build(repo_path)
  return { building = job_id ~= nil, job_id = job_id }
end)

-- Resolved JAVA_HOME for a given build_id (or the active build when omitted).
-- Mirrors `resolve_build_env` so external plugins (deps-explorer, etc.) can
-- spawn JVM tools — `mvn`, `gradle` — under the SAME JDK the user sees in the
-- compile combo, without re-implementing the toolchain resolution rules.
arbor.service.export("resolve_java_home", function(args)
  args = args or {}
  local cfg = resolve_build_cfg(args.build_id or "")
  if not cfg then return { ok = false, error = "no build configuration available" } end
  local kind = TEMPLATE_KIND[cfg.template_id or ""] or nil
  if kind ~= "jdk" then
    return { ok = false, error = "active build is not a JVM template (" .. tostring(cfg.template_id) .. ")" }
  end
  local env = resolve_build_env(cfg)
  return { ok = true, java_home = env["JAVA_HOME"] or "", build_id = cfg.id, template_id = cfg.template_id }
end)

-- ── Profile actions ──────────────────────────────────────────────────────────

arbor.events.on("compile:set_profile", function(ctx)
  local value = ctx.value or "dev"
  save_profile(value)
end)

-- ── Settings actions ──────────────────────────────────────────────────────────

arbor.events.on("compile:open_settings",      function(_ctx) gcfg.open_settings_form() end)
arbor.events.on("compile:settings_noop",      function(_ctx) end)

-- Fired by the settings orchestrator before it opens the modal. We use it
-- to re-contribute the JDK / Node / Rust sections with current toolchain
-- data so the form always reflects what's on disk. External contributors
-- (run-action and future add-ons) refresh themselves through the
-- `compile-action:settings:on_open` contribution point — see the
-- orchestrator. We don't need to broadcast anything from here.
arbor.events.on("compile:settings_refresh",   function(_ctx)
  pcall(function() gcfg.contribute_sections() end)
end)
arbor.events.on("compile:global_add_config",  function(ctx)  gcfg.handle_add(ctx);          combo.refresh() end)
arbor.events.on("compile:global_set_default", function(ctx)  gcfg.handle_set_default(ctx) end)
arbor.events.on("compile:global_delete",      function(ctx)  gcfg.handle_delete(ctx);       combo.refresh() end)
arbor.events.on("compile:global_edit",        function(ctx)  gcfg.handle_edit(ctx) end)
arbor.events.on("compile:global_edit_save",   function(ctx)  gcfg.handle_edit_save(ctx);    combo.refresh() end)

-- ── Project build configurations (IntelliJ-style tree modal) ─────────────────

arbor.events.on("compile:cfg_save_all",   function(ctx) pcfg.handle_save_all(ctx)        end)
arbor.events.on("compile:cfg_cancel",     function(ctx) pcfg.handle_cancel(ctx)           end)
arbor.events.on("compile:cfg_new",        function(ctx) pcfg.handle_cfg_new(ctx)          end)
arbor.events.on("compile:cfg_remove",     function(ctx) pcfg.handle_cfg_remove(ctx)       end)
arbor.events.on("compile:cfg_duplicate",  function(ctx) pcfg.handle_cfg_duplicate(ctx)    end)
arbor.events.on("compile:cfg_export",       function(ctx) pcfg.handle_cfg_export(ctx)        end)
arbor.events.on("compile:cfg_import_open",  function(ctx) pcfg.handle_cfg_import_open(ctx)   end)
arbor.events.on("compile:cfg_import_save",  function(ctx) pcfg.handle_cfg_import_save(ctx)   end)
arbor.events.on("compile:cfg_import_cancel",function(ctx) pcfg.handle_cfg_import_cancel(ctx) end)
arbor.events.on("compile:project_settings_noop",   function(_ctx) end)

arbor.events.on("compile:jdk_add",         function(ctx)  jdk.handle_add(ctx)         end)
arbor.events.on("compile:jdk_delete",      function(ctx)  jdk.handle_delete(ctx)      end)
arbor.events.on("compile:jdk_set_default", function(ctx)  jdk.handle_set_default(ctx) end)
arbor.events.on("compile:jdk_edit",        function(ctx)  jdk.handle_edit(ctx)        end)
arbor.events.on("compile:jdk_edit_save",   function(ctx)  jdk.handle_edit_save(ctx)   end)

arbor.events.on("compile:jdk_detect", function(_ctx)
  local candidates = arbor.toolchain.detect("jdk") or {}
  local added = 0
  for _, c in ipairs(candidates) do
    if not jdk.find_jdk(c.id) then
      arbor.toolchain.add("jdk", { id = c.id, label = c.label, path = c.path })
      added = added + 1
    end
  end
  if added > 0 then
    arbor.notify{ message = added .. " JDK(s) detected and added", level = "success" }
  else
    arbor.notify{ message = "No new JDKs found", level = "info" }
  end
  gcfg.open_settings_form()
end)

arbor.events.on("compile:toolchain_set_active", function(ctx)
  local kind = ctx.kind or ""
  local id   = ctx.id   or ""
  if kind == "" or id == "" then
    arbor.notify{ message = "Missing toolchain kind or id", level = "warning" }
    return
  end
  arbor.toolchain.set_active(kind, id)
  arbor.notify{ message = "Active " .. kind .. " toolchain updated", level = "success" }
  gcfg.open_settings_form()
end)

-- Generic detect+add for Node / Rust (JDK has its own handlers above).
local function toolchain_find(kind, id)
  for _, t in ipairs(arbor.toolchain.list(kind) or {}) do
    if t.id == id then return t end
  end
  return nil
end

local function do_toolchain_detect(kind, label)
  local candidates = arbor.toolchain.detect(kind) or {}
  local added = 0
  for _, c in ipairs(candidates) do
    if not toolchain_find(kind, c.id) then
      arbor.toolchain.add(kind, { id = c.id, label = c.label, path = c.path })
      added = added + 1
    end
  end
  if added > 0 then
    arbor.notify{ message = added .. " " .. label .. " installation(s) detected and added", level = "success" }
  else
    arbor.notify{ message = "No new " .. label .. " installations found", level = "info" }
  end
  gcfg.open_settings_form()
end

local function do_toolchain_add(kind, label, ctx)
  local id    = ctx["new_" .. kind .. "_id"]    or ""
  local lbl   = ctx["new_" .. kind .. "_label"] or ""
  local path  = ctx["new_" .. kind .. "_path"]  or ""
  if id == "" or path == "" then
    arbor.notify{ message = "ID and Path are required", level = "warning" }
    gcfg.open_settings_form(); return
  end
  if toolchain_find(kind, id) then
    arbor.notify{ message = label .. " id '" .. id .. "' already exists", level = "warning" }
    gcfg.open_settings_form(); return
  end
  arbor.toolchain.add(kind, {
    id    = id,
    label = lbl ~= "" and lbl or id,
    path  = path,
  })
  arbor.notify{ message = label .. " '" .. (lbl ~= "" and lbl or id) .. "' added", level = "success" }
  gcfg.open_settings_form()
end

arbor.events.on("compile:node_detect", function(_ctx) do_toolchain_detect("node", "Node.js") end)
arbor.events.on("compile:rust_detect", function(_ctx) do_toolchain_detect("rust", "Rust")    end)
arbor.events.on("compile:node_add",    function(ctx)  do_toolchain_add("node", "Node.js", ctx) end)
arbor.events.on("compile:rust_add",    function(ctx)  do_toolchain_add("rust", "Rust",    ctx) end)

-- ── Tree sidebar action handlers ──────────────────────────────────────────────
-- These power the Build & Run tree's contribution-driven UI: toolbar buttons,
-- per-node default actions (lifecycle phases / scripts / runnables), and the
-- placeholder dependency providers the modal calls into.

-- Map (template_id, phase) → command. Kept in main.lua so the build templates
-- module isn't loaded just for this — a one-call lookup.
local PHASE_COMMAND = {
  maven  = function(phase) return "mvn -B " .. phase end,
  gradle = function(phase) return "gradle " .. phase end,
  cargo  = function(phase) return "cargo " .. phase end,
  rust   = function(phase) return "cargo " .. phase end,
  npm    = function(phase, pm) return (pm or "npm") .. " run " .. phase end,
  make   = function(phase) return "make " .. phase end,
}

arbor.events.on("compile:run_phase", function(ctx)
  -- ctx = { node_id, data = { template_id, phase, repo_path, [pm] } }
  local d = ctx.data or {}
  local builder = PHASE_COMMAND[d.template_id or ""]
  if not builder then
    arbor.notify{ title = "No runner", message = "Phase runner missing for template '" .. tostring(d.template_id) .. "'", level = "warning" }
    return
  end
  local repo_path = d.repo_path or state.current_repo or ""
  if repo_path == "" then return end
  local repo_folder = repo_path:match("[/\\]([^/\\]+)[/\\]?$") or repo_path
  local cmd = builder(d.phase or "", d.pm)

  arbor.job.spawn({
    name     = repo_folder .. " (" .. (d.phase or "") .. ")",
    command  = cmd,
    cwd      = repo_path,
    category = "Builds",
    on_done  = function(jc)
      pcall(sidebar.refresh, repo_path)
      if jc.success then
        arbor.notify{ title = "Phase done", message = cmd .. " ✓", level = "success" }
      elseif not jc.cancelled then
        arbor.notify{ title = "Phase failed", message = cmd .. " — exit " .. (jc.exit_code or -1), level = "error" }
      end
    end,
  })
end)

arbor.events.on("compile:stop", function(_ctx)
  -- "Stop" should cancel everything: our build AND any long-running run
  -- service. We use a synchronous service call to run-action so we can sum
  -- the totals and tell the user when there was *nothing* to stop —
  -- without that feedback the click felt like a no-op. If run-action isn't
  -- loaded the call simply errors and we count zero services.
  local rp = state.current_repo or ""
  if rp == "" then
    arbor.notify{ title = "No active repository", message = "Open a repo tab first.", level = "warning" }
    return
  end

  local stopped_build = 0
  local jid = state.get_build(rp)
  if jid then
    pcall(function() arbor.job.cancel(jid) end)
    stopped_build = 1
  end

  -- run-action.stop_services may not be loaded → on rejection we still want
  -- to count zero services and surface the "nothing to stop" message.
  local function finalize(stopped_services)
    local total = stopped_build + stopped_services
    if total == 0 then
      arbor.notify{ title = "Nothing to stop", message = "No build or service is running in this repo.", level = "info" }
    end
    -- Build cancellation already surfaces its own toast via the job
    -- system; service cancellations notify from inside run-action's
    -- service handler. We only own the empty case.
  end
  arbor.service.call("run-action.stop_services", { repo_path = rp })
    :ok(function(result)
      local stopped_services = (type(result) == "table" and tonumber(result.stopped)) or 0
      finalize(stopped_services)
    end)
    :err(function(_e) finalize(0) end)
end)

arbor.events.on("compile:refresh_tree", function(_ctx)
  pcall(sidebar.refresh, state.current_repo or "")
end)

arbor.events.on("compile:new_runconfig", function(_ctx)
  -- Reuse the existing project-settings tree modal — same surface used by
  -- the combo button's "Project settings…" entry.
  pcfg.open_project_settings_form(state.current_repo)
end)

-- ── Manual modules (sidebar) ─────────────────────────────────────────────────
-- Lets the user add sub-projects the auto-detection misses (nested poms,
-- Cargo crates outside the workspace, etc.). Stored per-repo as a JSON
-- array under the `manual_modules` project setting.

local MANUAL_TEMPLATES = {
  { value = "maven",  label = "Maven (pom.xml)"            },
  { value = "gradle", label = "Gradle (build.gradle[.kts])" },
  { value = "cargo",  label = "Cargo (Cargo.toml)"          },
  { value = "npm",    label = "npm / pnpm / yarn"           },
  { value = "make",   label = "Makefile / generic"          },
}

arbor.events.on("compile:manual_add_open", function(_ctx)
  local repo_path = state.current_repo or ""
  if repo_path == "" then
    arbor.notify{ title = "Add manual project", message = "Open a repository first.", level = "warning" }
    return
  end
  arbor.ui.form({
    title         = "Add Manual Project",
    description   = "Register a sub-project the auto-detection didn't pick up. "
                 .. "Path may be absolute or relative to the repository root.",
    submit_label  = "Add",
    submit_action = "compile:manual_add_save",
    cancel_label  = "Cancel",
    cancel_action = "compile:project_settings_noop",
    width         = "520px",
    nodes = {
      { type = "text",   name = "manual_name",  label = "Display Name *",
        placeholder = "e.g. Core module" },
      { type = "select", name = "manual_template", label = "Project Type *",
        default = "maven", options = MANUAL_TEMPLATES },
      { type = "text",   name = "manual_dir", label = "Directory *",
        placeholder = "subdir/core  (or absolute path)",
        hint = "Relative to the repo root, or an absolute path." },
    },
  })
end)

arbor.events.on("compile:manual_add_save", function(ctx)
  local repo_path = state.current_repo or ""
  if repo_path == "" then return end

  local name = (ctx.manual_name or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local dir  = (ctx.manual_dir  or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local tpl  = ctx.manual_template or "maven"
  if name == "" or dir == "" then
    arbor.notify{ message = "Display Name and Directory are required", level = "warning" }
    return
  end

  local entries = sidebar.load_manual()
  -- Dedup on (template, dir) so re-adding the same module just refreshes
  -- the display name instead of stacking duplicate rows.
  for _, e in ipairs(entries) do
    if (e.template_id or "") == tpl and (e.dir or "") == dir then
      e.name = name
      sidebar.save_manual(entries)
      pcall(sidebar.refresh, repo_path)
      arbor.notify{ message = "Manual project updated", level = "success" }
      return
    end
  end

  local id = "m_" .. tostring(math.floor((os.time() % 1000000) * 1000))
              .. "_" .. tostring(math.random(1000, 9999))
  entries[#entries + 1] = {
    id          = id,
    name        = name,
    dir         = dir,
    template_id = tpl,
  }
  sidebar.save_manual(entries)
  pcall(sidebar.refresh, repo_path)
  arbor.notify{ message = "Manual project added", level = "success" }
end)

-- ── Maintenance actions (Settings > Maintenance) ────────────────────────────

arbor.events.on("compile:reset_detection", function(_ctx)
  local repo_path = state.current_repo or ""
  if repo_path == "" then
    arbor.notify{ title = "Reset detection", message = "Open a repository first.", level = "warning" }
    return
  end
  arbor.settings.project.set("detected_type", "")
  arbor.notify{ title = "Detection reset", message = "Project type cache cleared. It will be re-detected on next repo open / tab switch.", level = "success" }
  -- Re-run detection right now so the user gets the effect without a restart.
  on_repo_activated(repo_path)
  pcall(gcfg.open_settings_form)
end)

arbor.events.on("compile:reset_configs", function(_ctx)
  local repo_path = state.current_repo or ""
  if repo_path == "" then
    arbor.notify{ title = "Reset configurations", message = "Open a repository first.", level = "warning" }
    return
  end
  arbor.settings.project.set("project_configs", "[]")
  arbor.settings.project.set("selected", "")
  -- Force re-detection too so the defaults are recomputed for the current type.
  arbor.settings.project.set("detected_type", "")
  arbor.notify{ title = "Configurations reset", message = "Build configurations cleared and recreated from defaults.", level = "success" }
  on_repo_activated(repo_path)
  pcall(gcfg.open_settings_form)
end)

arbor.events.on("compile:reset_manual", function(_ctx)
  local repo_path = state.current_repo or ""
  if repo_path == "" then return end
  arbor.settings.project.set("manual_modules", "[]")
  pcall(sidebar.refresh, repo_path)
  arbor.notify{ title = "Manual projects cleared", message = "All manually-added projects removed from the sidebar for this repo.", level = "info" }
  pcall(gcfg.open_settings_form)
end)

arbor.events.on("compile:manual_remove", function(ctx)
  local repo_path = state.current_repo or ""
  local d = ctx.data or {}
  local target = d.manual_id or ""
  if target == "" then return end

  local entries = sidebar.load_manual()
  local out, removed = {}, false
  for _, e in ipairs(entries) do
    if e.id == target then removed = true
    else out[#out + 1] = e end
  end
  if not removed then return end
  sidebar.save_manual(out)
  pcall(sidebar.refresh, repo_path)
  arbor.notify{ message = "Manual project removed", level = "info" }
end)
