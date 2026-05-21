-- run-action / main.lua — thin wiring
-- Orchestrates application runs:
--   · resolves run configs
--   · calls compile-action.spawn_build (async) to build before running
--   · subscribes to compile-action:build-done on the bus to dequeue runs
--   · handles the run job lifecycle (including Tomcat WAR deploy)
--
-- Build logic lives entirely in compile-action. This plugin only orchestrates.

local state     = require("state")
local detect    = require("detect")
local run_defs  = require("run_defaults")
local rgcfg     = require("config.run_global")
local rpcfg     = require("config.run_project")
local rtpl      = require("config.run_templates")
local run_combo = require("ui.run_combo")

-- The "hide Services jobs" runtime flag lives in `state` so tomcat_pipeline
-- (and any other module that spawns Services) can read it synchronously.
-- The export handlers below mutate it; sibling plugins call them via
-- `arbor.service.call("run-action.set_hide_services", ...)`.
local services_hidden = state.services_hidden

-- Toolchain kinds per template.
local TEMPLATE_KIND = {
  simple_java = "jdk", spring = "jdk", tomcat = "jdk",
  cargo = "rust", npm = "node",
}

-- Default debug port per template, used when the user hits Debug on a
-- config that has no debug_port set. JDWP defaults to 5005 (IntelliJ's),
-- Node --inspect defaults to 9229.
local DEFAULT_DEBUG_PORT = {
  simple_java = "5005", spring = "5005", tomcat = "5005",
  npm = "9229",
}

-- Return a shallow-copied run-config with debug_port overridden to honour
-- the requested launch mode, plus a regenerated `command` field. The
-- original cfg is never mutated — callers always pass the returned value
-- on to do_run / state.enqueue_run.
--
--   mode == "debug" → use cfg.debug_port if present, else the template
--                     default (5005 / 9229). Cargo + Make have no JDWP
--                     story so they pass through unchanged.
--   mode == "run"   → debug_port = "" (turn off the agent).
--   mode == nil     → no override (legacy behaviour).
local function apply_run_mode(cfg, mode)
  if not cfg or not mode then return cfg end
  local out = {}
  for k, v in pairs(cfg) do out[k] = v end

  if mode == "debug" then
    local port = (cfg.debug_port or "")
    if port == "" then port = DEFAULT_DEBUG_PORT[cfg.template_id or ""] or "" end
    out.debug_port = port
  elseif mode == "run" then
    out.debug_port = ""
  end
  -- Marker so do_run / Tomcat skip-build paths know the debug state is an
  -- explicit user choice and don't second-guess it via project-level
  -- fallback (rpcfg.load_debug_port()).
  out._debug_explicit = true

  local tpl = rtpl.run_get(out.template_id or "")
  if tpl and tpl.build_command then
    out.command = tpl.build_command(out)
  end
  return out
end

-- The active build profile (`dev` / `prod` / `test`) is owned by
-- compile-action and persisted in its PROJECT settings (per repo). Reading
-- cross-plugin requires `settings_read_others = true` in plugin.toml; if
-- the lookup fails (compile-action absent / disabled / no value yet) we
-- silently fall back to "dev" so the run is never blocked on it.
local function active_profile()
  local ok, value = pcall(function()
    return arbor.settings.read_project("compile-action", "active_profile")
  end)
  if ok and type(value) == "string" and value ~= "" then return value end
  return "dev"
end

-- Resolve the env for a run config. Layered (each later layer wins):
--   1. cfg.env                       (explicit user kv_list — base)
--   2. template-derived env          (vm_args, JPDA_*, NODE_OPTIONS, RUSTFLAGS)
--   3. profile_env[<active>]         (per-profile overrides)
--   4. toolchain env / build_java_home (only fills missing keys)
-- The first three are computed by run_templates.resolve_effective_env;
-- toolchain layering happens here next to the active-toolchain fallback.
local function resolve_run_env(run_cfg, build_java_home)
  local env = rtpl.resolve_effective_env(run_cfg, active_profile())

  local kind  = TEMPLATE_KIND[run_cfg.template_id or ""] or nil
  local tc_id = run_cfg.toolchain_id or ""
  if kind and tc_id ~= "" then
    local tc_env = arbor.toolchain.env{ kind = kind, id = tc_id } or {}
    for k, v in pairs(tc_env) do if env[k] == nil then env[k] = v end end
  elseif kind == "jdk" and build_java_home and build_java_home ~= "" then
    if env.JAVA_HOME == nil then env.JAVA_HOME = build_java_home end
  elseif kind then
    local active = arbor.toolchain.active(kind)
    if active then
      local tc_env = arbor.toolchain.env{ kind = kind, id = active.id } or {}
      for k, v in pairs(tc_env) do if env[k] == nil then env[k] = v end end
    end
  end
  return env
end

-- Forward declarations so the PLUGIN_LOAD hook can reference handlers
-- defined later in this file.
local on_build_done
local do_run

-- ── Lifecycle ─────────────────────────────────────────────────────────────────

arbor.events.on("on_plugin_load", function(ctx)
  run_combo.register()

  -- Register the built-in ops we actually use for the Tomcat deploy
  -- pipeline: delete_file / copy_file (plugin-local) +
  -- assert_file_exists (arbor.core.assert). The other categories aren't
  -- needed here so we skip them — no closures we won't call.
  require("pipeline_ops.file").register()
  require("arbor.core.assert").register()

  arbor.keybinding.register({
    key         = "F10",
    shift       = true,
    action      = "run:run",
    description = "Run selected application configuration",
  })

  -- IntelliJ-style Debug shortcut. Forces the debug agent ON for jar /
  -- spring / tomcat / npm regardless of the cfg's debug_port — when the cfg
  -- has none configured we fall back to a sensible default port so the user
  -- can attach immediately.
  arbor.keybinding.register({
    key         = "F9",
    shift       = true,
    action      = "run:debug",
    description = "Debug selected application configuration",
  })

  -- Skip-build shortcuts for Tomcat: launch catalina against the existing
  -- WAR (no build, no deploy). Two chords mirroring the regular Run/Debug
  -- pair so the user knows exactly which mode they're getting:
  --   · Ctrl+Shift+F10 — forced RUN  (debug agent OFF, regardless of cfg)
  --   · Ctrl+Shift+F9  — forced DEBUG (debug agent ON; falls back to
  --                                    template default port if cfg has none)
  arbor.keybinding.register({
    key         = "F10",
    ctrl        = true,
    shift       = true,
    action      = "run:tomcat_no_build_run",
    description = "Start Tomcat without building (no debug)",
  })

  arbor.keybinding.register({
    key         = "F9",
    ctrl        = true,
    shift       = true,
    action      = "run:tomcat_no_build_debug",
    description = "Debug Tomcat without building (catalina + JPDA)",
  })

  -- Contribute to the compile-action sidebar — the "Build & Run" tree.
  -- Convention: contribution points are owned by compile-action and named
  -- `<owner>:<sidebar_id>:<slot>`. See compile-action/ui/sidebar.lua for
  -- the full slot list.
  local COMPILE_NS = "compile-action:compile"

  -- Toolbar: "Run application" — the primary action of the Build & Run
  -- sidebar. Lowest priority so it lands at the LEFT of the toolbar (the
  -- conventional "primary action" slot in IDE toolbars). Uses the green
  -- Play glyph because that's what users instinctively click to launch.
  arbor.ui.contribute(COMPILE_NS .. ":toolbar", {
    id       = "run-app",
    priority = 5,
    payload  = {
      icon    = "Play",
      tooltip = "Run application (Shift+F10)",
      action  = "run:run",
      success = true,    -- green — primary positive action
    },
  })

  -- Toolbar: "Debug application" — companion to Run. Sits next to it so
  -- users can switch between regular launch and JDWP-attached launch with
  -- one click; matches the IntelliJ "green play / green bug" pairing.
  arbor.ui.contribute(COMPILE_NS .. ":toolbar", {
    id       = "debug-app",
    priority = 6,
    payload  = {
      icon    = "Bug",
      tooltip = "Debug application (Shift+F9)",
      action  = "run:debug",
    },
  })

  -- Per-row hover button on RUN config rows only — restarts the
  -- application matching the config. Filtered by `kind = "run_config"` so
  -- we never appear on build_config or module rows.
  arbor.ui.contribute(COMPILE_NS .. ":node_action", {
    id       = "restart-runnable",
    priority = 10,
    when     = { kind = "run_config" },
    payload  = {
      icon    = "RotateCw",
      tooltip = "Restart application",
      action  = "run:restart_with_id",
    },
  })

  -- Per-row hover button visible only on Tomcat run configs — runs JUST
  -- catalina against the previously deployed WAR, skipping both build and
  -- deploy. Useful when iterating on Tomcat config / debugger attach
  -- without redoing the full build cycle.
  arbor.ui.contribute(COMPILE_NS .. ":node_action", {
    id       = "tomcat-run-no-build",
    priority = 15,
    when     = { kind = "run_config", data_field = { key = "config_type", value = "tomcat" } },
    payload  = {
      icon    = "SkipForward",
      tooltip = "Start Tomcat without building (catalina only)",
      action  = "run:start_tomcat_no_build",
    },
  })

  -- Per-row hover button visible only on Tomcat run configs — opens the
  -- Tomcat home folder in the OS file explorer for quick access to
  -- conf/, logs/, webapps/.
  arbor.ui.contribute(COMPILE_NS .. ":node_action", {
    id       = "open-tomcat-root",
    priority = 20,
    when     = { kind = "run_config", data_field = { key = "config_type", value = "tomcat" } },
    payload  = {
      icon    = "FolderOpen",
      tooltip = "Open Tomcat root in file explorer",
      action  = "run:open_tomcat_root",
    },
  })

  -- Right-click on a RUN config: "Run with arguments…" opens the run
  -- config editor pre-filtered so the user can tweak before launching.
  arbor.ui.contribute(COMPILE_NS .. ":context_menu", {
    id       = "run-with-args",
    priority = 10,
    when     = { kind = "run_config" },
    payload  = {
      label  = "Run with arguments…",
      action = "run:run_with_args",
    },
  })

  -- Listen to compile-action's build-done events. When a build finishes for a
  -- repo that has a pending run, trigger the run using the pre-captured snapshots.
  arbor.events.on("compile-action:build-done", function(evt)
    on_build_done(evt)
  end)

  -- Service exposed to compile-action's toolbar Stop button. Cancels every
  -- running service for the given repo (Tomcat catalina, Spring boot, plain
  -- JARs, …) and returns how many were stopped so the caller can decide
  -- whether to surface a "nothing to stop" notification.
  --
  -- Two cancellation paths because Lua state and the Rust JobRegistry can
  -- drift out of sync (most commonly: the user reloads plugins while a
  -- service is running — the OS process keeps going but state.active_runs
  -- is wiped, so list_running() returns empty even though the service is
  -- alive in the JobRegistry).
  --   1. Cancel everything still tracked in our Lua state (fast path).
  --   2. Scan arbor.job.list() for orphaned services owned by this plugin
  --      whose name starts with the repo folder — recovers from reloads.
  arbor.service.export("stop_services", function(args)
    local repo = (args and args.repo_path) or ""
    if repo == "" then return { stopped = 0 } end
    local repo_folder = repo:match("[/\\]([^/\\]+)[/\\]?$") or repo

    local stopped = 0
    local cancelled_ids = {}
    for cfg_id, job_id in pairs(state.list_running(repo) or {}) do
      if job_id then
        pcall(function() arbor.job.cancel(job_id) end)
        state.untrack_run(repo, cfg_id)
        cancelled_ids[job_id] = true
        stopped = stopped + 1
      end
    end

    -- Orphan scan: any "Services" job spawned by us, whose name starts with
    -- the repo folder, and that is still Running but not already cancelled
    -- via the state path above.
    local all_jobs = nil
    pcall(function() all_jobs = arbor.job.list() end)
    if type(all_jobs) == "table" then
      for _, j in ipairs(all_jobs) do
        local jid = j and j.id or nil
        if jid and not cancelled_ids[jid]
           and (j.plugin_name == "run-action")
           and (j.category == "Services")
           and type(j.name) == "string"
           and j.name:find(repo_folder, 1, true) == 1
           and type(j.status) == "table" and j.status.type == "running"
        then
          pcall(function() arbor.job.cancel(jid) end)
          cancelled_ids[jid] = true
          stopped = stopped + 1
        end
      end
    end

    if stopped > 0 then
      run_combo.refresh()
      arbor.notify{ title = "Services stopped", message = "[" .. repo_folder .. "] " .. stopped .. " running service(s) cancelled.", level = "info" }
    end
    return { stopped = stopped }
  end)

  -- Cross-plugin runtime flag: when a sibling plugin (e.g. run-monitor) takes
  -- ownership of presenting Services, it flips this to true so our service
  -- jobs spawn with `hidden = true` and disappear from the global Jobs
  -- overlay + status-bar badge. There is no UI for this in run-action
  -- settings — the only valid setter is another plugin via service.call.
  -- Args: { value = boolean }. Returns: { hidden = boolean }.
  arbor.service.export("set_hide_services", function(args)
    state.set_hide_services(args and args.value)
    arbor.log.info("hide_services -> " .. tostring(state.hide_services))
    return { hidden = state.hide_services }
  end)

  arbor.service.export("get_hide_services", function()
    return { hidden = state.hide_services }
  end)

  -- Contribute our "Run" sidebar category + its sections to compile-action's
  -- settings panel up-front so the entry exists from the first gear click.
  pcall(function() rgcfg.contribute_sections() end)

  -- Register a pre-open hook so the orchestrator re-runs our section
  -- builder right before opening the modal — keeps run-config lists in
  -- sync with disk even when the user mutates them outside our flow.
  -- The `:settings:on_open` contribution point is fired SYNCHRONOUSLY by
  -- the orchestrator (await firePluginAction) before reading sections, so
  -- our re-contributes land in time.
  arbor.ui.contribute("compile-action:settings:on_open", {
    id      = "run-action-refresh",
    payload = { action = "run:settings_refresh" },
  })

  arbor.log.info("ready (api_version=" .. ctx.api_version .. ")")
end)

-- Tomcat deploy pipeline bookkeeping: route PIPELINE_DONE events for runs
-- we started through the deploy module (it spawns catalina on success or
-- raises a notification on failure).
arbor.events.on("on_pipeline_done", function(ctx)
  if ctx.plugin ~= "run-action" then return end
  require("tomcat_pipeline").on_pipeline_done(ctx)
end)

-- ── Pipeline stubs ────────────────────────────────────────────────────────────
-- Make every Tomcat run-config show up in the host's Pipelines panel even
-- before the user has run it for the first time. Pipeline defs live only
-- in memory, so without these stubs the panel is empty until a deploy
-- actually runs (which re-defines the def with full stages via
-- `tomcat_pipeline.deploy`). After the first deploy the stub is replaced
-- with the compiled version and Play replays it directly without touching
-- this plugin again.
--
-- Only Tomcat configs go here. Other config types (spring, custom, rust,
-- node, …) launch through `arbor.job.spawn` rather than the pipeline
-- runtime, so they don't belong in the Pipelines panel at all.
-- Lua gotcha: "" is truthy, so plain `c.name or c.label or c.id` keeps the
-- empty string when `name` was never set by the user. Two such configs
-- would then collapse to the same `"Deploy "` label in the SplitButton.
local function nonempty(s) return (type(s) == "string" and s ~= "") and s or nil end

local function register_run_stubs(repo_path)
  local cfgs = {}
  pcall(function()
    for _, c in ipairs(rpcfg.load() or {}) do cfgs[#cfgs+1] = c end
  end)
  pcall(function()
    for _, c in ipairs(rgcfg.load() or {}) do cfgs[#cfgs+1] = c end
  end)
  local repo_folder = (repo_path or ""):match("[/\\]([^/\\]+)[/\\]?$")
  for _, c in ipairs(cfgs) do
    if (c.config_type or "") == "tomcat" and nonempty(c.id) then
      local label = nonempty(repo_folder) or nonempty(c.name) or nonempty(c.label) or c.id
      pcall(function()
        arbor.pipeline.define({
          id          = "tomcat-deploy:" .. c.id,
          name        = "Deploy " .. label,
          description = c.description or "",
          icon        = "Server",
          -- Same lock key tomcat_pipeline.deploy uses, so a stub-launched
          -- run and a combo-launched run can't race on the same Tomcat.
          lock_key    = "tomcat-deploy:" .. (repo_path or ""),
          log_level   = "info",
          stages      = {},   -- stub; tomcat_pipeline.deploy fills these.
        })
      end)
    end
  end
end

-- ── Shared logic: detect project type, populate run combo ────────────────────

local function on_repo_activated(path)
  if path == "" then return end
  state.set_repo(path)

  local proj_type   = detect.detect(path)
  local stored_type = arbor.settings.project.get("detected_type") or ""
  local type_changed = proj_type and proj_type ~= stored_type

  -- Seed default run configs if empty or if detection changed.
  if #rpcfg.load() == 0 or type_changed then
    if proj_type then
      arbor.settings.project.set("detected_type", proj_type)
      local run_list = run_defs.for_type(proj_type, path)
      if #run_list > 0 then
        rpcfg.save(run_list)
        arbor.log.info("created " .. #run_list .. " default run configurations")
      end
    end
  end

  local sel_run   = rpcfg.load_selected()
  local all_run   = rpcfg.load()
  local found_run = false
  for _, c in ipairs(all_run) do if c.id == sel_run then found_run = true; break end end

  if not found_run then
    local default_run_id = proj_type and rgcfg.load_default_profile(proj_type) or ""
    if default_run_id ~= "" and rgcfg.find(default_run_id) then
      sel_run = default_run_id
    elseif #all_run > 0 then
      sel_run = all_run[1].id
    end
    if sel_run ~= "" then rpcfg.save_selected(sel_run) end
  end

  run_combo.refresh(sel_run ~= "" and sel_run or nil)
  contribute_runconfigs_section(path, sel_run)
  -- Make Tomcat configs visible in the host's Pipelines panel split-button
  -- before any deploy has actually been launched.
  register_run_stubs(path)
end

-- ── Tree-section contribution into compile-action's sidebar ───────────────────
-- Builds a "Run configurations" TreeNode and pushes it into the
-- `compile-action:compile:tree.section` slot. Re-fired on every repo open /
-- tab switch so the section always reflects the active repo's configs.
function contribute_runconfigs_section(repo_path, selected_id)
  local COMPILE_NS = "compile-action:compile"
  local TREE_SECTION_POINT = COMPILE_NS .. ":tree.section"

  if not repo_path or repo_path == "" then
    -- Drop the section when no repo is active so we don't show stale rows.
    pcall(function()
      arbor.ui.unregister_contribution(TREE_SECTION_POINT, "run-configs")
    end)
    return
  end

  -- Pull project + global configs (project takes precedence; merged for
  -- display so the user sees everything available in this repo at a glance).
  local cfgs = {}
  local ok_p, project = pcall(rpcfg.load); if ok_p and type(project) == "table" then
    for _, c in ipairs(project) do cfgs[#cfgs+1] = c end
  end
  local ok_g, global  = pcall(rgcfg.load); if ok_g and type(global)  == "table" then
    -- Avoid id collisions (project shadows global).
    local seen = {}
    for _, c in ipairs(cfgs) do seen[c.id or ""] = true end
    for _, c in ipairs(global) do
      if not seen[c.id or ""] then cfgs[#cfgs+1] = c end
    end
  end

  -- Group by config_type so visually-similar configs cluster together.
  local TYPE_LABEL = {
    spring = "Spring Boot", tomcat = "Tomcat", custom = "Java (JAR)",
    rust   = "Rust",        node   = "Node.js",
  }
  local TYPE_ORDER = { "spring", "tomcat", "custom", "rust", "node" }

  local by_type = {}
  for _, c in ipairs(cfgs) do
    local t = c.config_type or "custom"
    by_type[t] = by_type[t] or {}
    table.insert(by_type[t], c)
  end

  local section_children = {}
  local total = 0

  -- Count distinct types so we can skip the per-type group header when only
  -- one type is present (the common case — e.g. a Tomcat-only project gains
  -- no clarity from a "Tomcat" sub-header above its configs).
  local present_types = {}
  for t, _ in pairs(by_type) do present_types[#present_types+1] = t end
  local single_group = (#present_types == 1)

  local function build_run_node(c)
    local tpl = rtpl.run_get(c.template_id or "")
    local icon = (tpl and tpl.icon) or "Play"
    return {
      id             = "runcfg:" .. (c.id or "?"),
      label          = c.name or c.label or c.id or "(unnamed)",
      icon           = icon,
      kind           = "run_config",
      selectable     = true,
      default_action = "run:run_with_id",
      badge          = (c.id == selected_id) and "default" or nil,
      badge_kind     = (c.id == selected_id) and "accent" or nil,
      data = {
        cfg_id      = c.id or "",
        template_id = c.template_id or "",
        config_type = c.config_type or "custom",
        tomcat_home = c.tomcat_home or "",
        repo_path   = repo_path,
      },
      children = {},
    }
  end

  local function emit_group(t)
    local list = by_type[t]
    if not list or #list == 0 then return end
    table.sort(list, function(a, b) return (a.name or a.id or "") < (b.name or b.id or "") end)

    if single_group then
      -- Inline the configs directly under "Run configurations" — no inner
      -- per-type header.
      for _, c in ipairs(list) do
        section_children[#section_children+1] = build_run_node(c)
        total = total + 1
      end
      return
    end

    local group_children = {}
    for _, c in ipairs(list) do
      group_children[#group_children+1] = build_run_node(c)
      total = total + 1
    end
    section_children[#section_children+1] = {
      id        = "section:runconfigs:" .. t,
      label     = TYPE_LABEL[t] or t,
      icon      = (rtpl.run_get((list[1] or {}).template_id or "") or {}).icon or "Folder",
      kind      = "section",
      expanded  = true,
      selectable = false,
      data      = {},
      children  = group_children,
    }
  end

  -- Emit known types in the documented order, then any custom types.
  local emitted = {}
  for _, t in ipairs(TYPE_ORDER) do emit_group(t); emitted[t] = true end
  for t, _ in pairs(by_type) do
    if not emitted[t] then emit_group(t) end
  end

  if total == 0 then
    -- No run configs in this repo — drop the section entirely so the
    -- sidebar doesn't show an empty header taking up space.
    pcall(function()
      arbor.ui.unregister_contribution(TREE_SECTION_POINT, "run-configs")
    end)
    return
  end

  arbor.ui.contribute(TREE_SECTION_POINT, {
    id       = "run-configs",
    priority = 50,    -- after compile's own build_configs section (priority ~10)
    payload  = {
      section = {
        id        = "section:runconfigs",
        label     = "Run configurations",
        icon      = "Rocket",
        kind      = "section",
        expanded  = true,
        selectable = false,
        data      = {},
        children  = section_children,
      },
    },
  })
end

arbor.events.on("on_repo_open", function(ctx)
  on_repo_activated(ctx.path or ctx.repo or "")
end)

arbor.events.on("on_tab_switch", function(ctx)
  on_repo_activated(ctx.path or "")
end)

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function resolve_auto_stop()
  local override = rpcfg.load_auto_stop_override()
  if override == "true"  then return true  end
  if override == "false" then return false end
  return rgcfg.load_auto_stop()
end

local function stop_all_services(repo_path)
  -- Only stop services that belong to the given repo — cancelling jobs from
  -- other repos would break concurrent runs across tabs.
  for cfg_id, job_id in pairs(state.list_running(repo_path)) do
    if job_id then
      arbor.log.info("stopping service " .. cfg_id .. " (job=" .. job_id
        .. ") in repo=" .. tostring(repo_path))
      arbor.job.cancel(job_id)
      state.untrack_run(repo_path, cfg_id)
    end
  end
end

-- ── Core run logic ────────────────────────────────────────────────────────────
-- Called either directly (skip_build runs) or by on_build_done after a
-- successful build. All inputs are snapshots — no settings reads here.
--
-- run_cfg         : full run-config table captured while the correct tab was active.
-- repo_path       : repo path captured at call time.
-- build_cfg       : build-config snapshot (for Tomcat — used to resolve WAR dir).
-- build_java_home : resolved JAVA_HOME from the build step (for Tomcat env).

-- Resolve everything the Tomcat pipeline needs (catalina path, JPDA env,
-- service command, target_dir, build snapshot) and kick off the unified
-- Build → Preflight → Clean → Deploy pipeline. Notifications: a single
-- transient toast at the start (no bell entry — that's the START phase
-- the user already sees in the pipelines panel); success/failure ends
-- up in the bell only via on_pipeline_done.
local function start_tomcat_pipeline(run_cfg, repo_path, build_cfg, build_env, build_command, build_cwd, build_label)
  local cfg_id      = run_cfg.id
  local repo_folder = repo_path:match("[/\\]([^/\\]+)[/\\]?$") or cfg_id
  local tomcat_pipeline = require("tomcat_pipeline")

  local tomcat_home = run_cfg.tomcat_home
  if not tomcat_home or tomcat_home == "" then tomcat_home = rpcfg.load_tomcat_home() end
  local debug_port  = run_cfg.debug_port or ""
  -- Honour explicit Run/Debug-mode overrides. Without this guard a "Run"
  -- (mode = run, debug_port forced to "") on a Tomcat config that has no
  -- per-cfg port would silently re-enable the agent via the project
  -- fallback below.
  if debug_port == "" and not run_cfg._debug_explicit then
    debug_port = rpcfg.load_debug_port()
  end

  if not arbor.fs.is_dir(tomcat_home) then
    arbor.notify{ title = "Tomcat not configured", message = "Set Tomcat Home in Run Settings before launching.", level = "warning" }
    return
  end

  local build_java_home = (build_env and build_env["JAVA_HOME"]) or ""
  local jpda = debug_port ~= ""
  -- Start from the merged template/env/toolchain env, then overlay the
  -- Tomcat-specific JPDA + CATALINA_* env.
  local svc_env = resolve_run_env(run_cfg, build_java_home)
  if jpda then
    svc_env["JPDA_ADDRESS"]   = "*:" .. debug_port
    svc_env["JPDA_TRANSPORT"] = "dt_socket"
  end
  svc_env["CATALINA_HOME"] = tomcat_home
  if build_java_home ~= "" then
    svc_env["JAVA_HOME"] = build_java_home
    svc_env["JRE_HOME"]  = build_java_home
  end

  local is_win   = arbor.meta.os() == "windows"
  local script   = is_win and "catalina.bat" or "catalina.sh"
  local catalina = arbor.fs.join(tomcat_home, "bin", script)
  local svc_command = '"' .. catalina .. '" ' .. (jpda and "jpda run" or "run")

  -- target_dir resolution: explicit war_relative_path wins; otherwise look
  -- in the build cwd's `target/` (Maven default). Falls back to repo_path
  -- when no build cfg is available (skip-build path).
  local war_dir  = run_cfg.war_relative_path or run_cfg.war_dir or ""
  local cwd_for_target = build_cwd or ((build_cfg and build_cfg.cwd ~= "" and build_cfg.cwd) or repo_path)
  local target_dir
  if war_dir ~= "" then
    local is_abs = war_dir:match("^[A-Za-z]:") or war_dir:match("^[/\\]")
    target_dir = is_abs and war_dir or arbor.fs.join(cwd_for_target, war_dir)
  else
    target_dir = arbor.fs.join(cwd_for_target, "target")
  end

  local _, err = tomcat_pipeline.deploy({
    repo_path     = repo_path,
    repo_folder   = repo_folder,
    cfg_id        = cfg_id,
    cfg_name      = run_cfg.name,
    cfg_label     = run_cfg.label,
    tomcat_home   = tomcat_home,
    svc_env       = svc_env,
    svc_command   = svc_command,
    target_dir    = target_dir,
    build_command = build_command,
    build_env     = build_env,
    build_cwd     = build_cwd,
    build_label   = build_label,
    stop_existing = function() stop_all_services(repo_path) end,
  })
  if err then
    arbor.notify{
      title   = "Run failed to start",
      message = "[" .. repo_folder .. "] " .. err,
      level   = "error",
      toast   = false,
    }
    return
  end
end

do_run = function(run_cfg, repo_path, build_cfg, build_java_home, start_silent)
  if not run_cfg then
    arbor.notify{ message = "Run configuration not found", level = "error" }
    return
  end
  local cfg_id      = run_cfg.id
  local cfg_type    = run_cfg.config_type or ""
  local run_label   = run_cfg.name or run_cfg.label or cfg_id
  local repo_folder = repo_path:match("[/\\]([^/\\]+)[/\\]?$") or run_label

  arbor.log.info("[do_run] ENTER"
    .. "  repo_path=" .. repo_path
    .. "  cfg_id=" .. cfg_id
    .. "  cfg_type=" .. cfg_type
    .. "  build_cfg=" .. (build_cfg and build_cfg.id or "(nil)"))

  -- Tomcat path is special: Build is part of the deploy pipeline (not a
  -- separate Job). The cfg_type guard is unreachable on the run-dispatch
  -- code path (Tomcat is intercepted earlier), but kept for the legacy
  -- on_build_done callback path that may still feed Tomcat configs here.
  if cfg_type == "tomcat" then
    if not build_cfg then
      arbor.notify{ title = "No build configuration", message = "Tomcat requires a build configuration to produce the WAR.", level = "warning", toast = false }
      return
    end
    local build_cwd = (build_cfg.cwd and build_cfg.cwd ~= "") and build_cfg.cwd or repo_path
    local build_env = (build_java_home and build_java_home ~= "")
                    and { JAVA_HOME = build_java_home }
                    or  {}
    start_tomcat_pipeline(run_cfg, repo_path, build_cfg, build_env, build_cfg.command, build_cwd, build_cfg.label)
    return
  end

  -- ── Normal service: stop existing instance if auto_stop, then spawn ───────

  if resolve_auto_stop() then
    local existing = state.get_running(repo_path, cfg_id)
    if existing then
      arbor.job.cancel(existing)
      state.untrack_run(repo_path, cfg_id)
    end
  end

  local cwd = (run_cfg.cwd and run_cfg.cwd ~= "") and run_cfg.cwd or repo_path
  local env = resolve_run_env(run_cfg, build_java_home)

  -- notify_on_completion defaults to true on missing — old configs keep
  -- their previous behaviour.
  local notify_done = run_cfg.notify_on_completion
  if notify_done == nil then notify_done = true end

  local job, spawn_err = arbor.job.spawn({
    name     = repo_folder,
    command  = run_cfg.command,
    cwd      = cwd,
    env      = env,
    category = "Services",
    hidden   = services_hidden(),
    on_done  = function(svc_ctx)
      state.untrack_run(repo_path, cfg_id)
      run_combo.refresh()
      if notify_done then
        local lvl = svc_ctx.success and "info" or "warning"
        local msg = svc_ctx.success
          and run_label .. " exited cleanly"
          or  run_label .. " exited with code " .. (svc_ctx.exit_code or -1)
        arbor.notify{ title = "Application stopped", message = msg, level = lvl, toast = false }
      end
    end,
  })
  if not job then
    arbor.notify{ title = "Run failed to start", message = tostring(spawn_err), level = "error", toast = false }
    return
  end

  state.track_run(repo_path, cfg_id, job.id)
  run_combo.refresh()
  -- Single start toast (mirror of Tomcat path) so direct runs aren't
  -- silent at kick-off. Suppressed when run_dispatch already showed one
  -- (the post-build path sets start_silent so we don't double-toast).
  if not start_silent then
    arbor.notify{
      title   = "Run started",
      message = "[" .. repo_folder .. "] " .. run_label,
      level   = "info",
      persist = false,
    }
  end
end

-- ── Build-done bus handler ────────────────────────────────────────────────────
-- Listens on "compile-action:build-done". If we have a queued run for that
-- repo, dequeue and execute it.

on_build_done = function(evt)
  local repo_path = evt and evt.repo_path or ""
  if repo_path == "" then return end

  local pending = state.dequeue_run(repo_path)
  if not pending then return end

  if not evt.success then
    local repo_folder = repo_path:match("[/\\]([^/\\]+)[/\\]?$") or repo_path
    if evt.cancelled then
      arbor.notify{ title = "Run aborted", message = "[" .. repo_folder .. "] build was cancelled — queued run dropped.", level = "warning", toast = false }
    else
      arbor.notify{ title = "Run aborted", message = "[" .. repo_folder .. "] build failed — queued run dropped.", level = "error", toast = false }
    end
    return
  end

  arbor.log.info("[on_build_done] dequeue + do_run: run=" .. pending.run_cfg.id
    .. "  repo=" .. repo_path)
  -- run_dispatch already showed the start toast when the build kicked off;
  -- suppress the second one in do_run.
  do_run(pending.run_cfg, repo_path, pending.build_cfg, evt.java_home, true)
end

-- ── Run handler ───────────────────────────────────────────────────────────────

-- "Run with args" jumps into the project run-settings form so the user can
-- tweak before running. Wired from the compile sidebar context-menu
-- contribution registered in PLUGIN_LOAD above.
arbor.events.on("run:run_with_args", function(_ctx)
  rpcfg.open_project_run_settings_form(state.current_repo)
end)

-- ── Before-launch chain ──────────────────────────────────────────────────────
-- Pre-tasks run sequentially in their own jobs (so each shows up in the Jobs
-- UI with its own output) before the build/run kicks off. The chain stops
-- on the first failure. Used by every launch path — skip-build, Tomcat
-- pipeline, and the regular non-Tomcat build → run.

-- Spawn a single pre-task. Returns a JobHandle (Promise) on success, or
-- (nil, err) when the task is misconfigured. Must be called from inside
-- `arbor.async.run` because build-type pre-tasks await
-- compile-action.resolve_build via service.call.
local function spawn_run_pre_task(task, parent_cfg, repo_path)
  local repo_folder = repo_path:match("[/\\]([^/\\]+)[/\\]?$") or repo_path
  local kind        = task.step_type or ""
  if kind == "build" then
    -- Resolve the build via compile-action so the env (toolchain + profile +
    -- derived) and cwd are computed in one place. resolve_build doesn't
    -- spawn anything — just returns the snapshot we need to launch ourselves.
    local result, err = arbor.async.await(
      arbor.service.call("compile-action.resolve_build", {
        repo_path = repo_path, build_id = task.target,
      })
    )
    if err or not result or result.ok == false then
      local detail = (result and result.error)
                  or (type(err) == "table" and err.message)
                  or "unresolved"
      return nil, "build target '" .. tostring(task.target) .. "' (" .. detail .. ")"
    end
    return arbor.job.spawn({
      name     = repo_folder .. " (pre: " .. (result.label or task.target) .. ")",
      command  = result.command,
      cwd      = result.cwd,
      env      = result.env,
      category = "Builds",
    })
  elseif kind == "shell" then
    local cmd = task.target or ""
    if cmd == "" then return nil, "shell command is empty" end
    -- Shell pre-tasks inherit the parent run config's env so users can rely
    -- on JAVA_HOME / NODE_OPTIONS being set when running ad-hoc helpers.
    local env = resolve_run_env(parent_cfg, nil)
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

-- Run the pre-launch chain inside an async coroutine. Calls `cb()` only on
-- full success — failures emit a toast and the run is silently dropped (the
-- caller has already done all its setup so there's nothing else to undo).
local function with_pre_chain(run_cfg, repo_path, repo_folder, cb)
  local pre = run_cfg.before_launch or {}
  if #pre == 0 then cb(); return end

  arbor.async.run(function()
    for i, task in ipairs(pre) do
      local label = "Pre-task " .. i .. "/" .. #pre
                  .. " — " .. (task.step_type or "?")
      local handle, spawn_err = spawn_run_pre_task(task, run_cfg, repo_path)
      if not handle then
        arbor.notify{ title = "Pre-task failed to start",
                      message = "[" .. repo_folder .. "] " .. label
                             .. ": " .. tostring(spawn_err),
                      level = "error" }
        return
      end
      local _, err = arbor.async.await(handle)
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
    cb()
  end)
end

local run_dispatch = function(ctx)
  local value     = ctx.value or ""
  local mode      = ctx.mode  or "run"
  local repo_path = state.current_repo

  if value == "__run_project_settings__" then
    rpcfg.open_project_run_settings_form(repo_path)
    return
  end

  if value == "" then value = rpcfg.load_selected() or "" end
  if value == "" then
    local all_p = rpcfg.load()
    if #all_p > 0 then value = all_p[1].id
    else
      local all_g = rgcfg.load()
      if #all_g > 0 then value = all_g[1].id end
    end
  end
  if value == "" then
    arbor.notify{ title = "No run configuration", message = "Create a run configuration first", level = "warning" }
    return
  end

  local run_cfg = rpcfg.find(value) or rgcfg.find(value)
  if not run_cfg then
    arbor.notify{ title = "Run configuration not found", message = value, level = "error" }
    return
  end

  -- Honour the launch mode by overriding debug_port + regenerating the
  -- command. The base config on disk is left untouched.
  run_cfg = apply_run_mode(run_cfg, mode)

  rpcfg.save_selected(value)

  local repo_folder = repo_path:match("[/\\]([^/\\]+)[/\\]?$") or repo_path
  local build_id    = run_cfg.build_id or ""
  local cfg_type    = run_cfg.config_type or ""

  -- The actual launch logic, gated behind the optional Before Launch chain.
  -- All three paths (skip / Tomcat / non-Tomcat build) share the same
  -- pre-chain wrapper above, so a config can mix `Build before run` AND
  -- additional pre-launch tasks freely.
  local function proceed()
    -- ── Case 1: explicit skip → run without building ─────────────────────────
    if build_id == "__skip__" then
      do_run(run_cfg, repo_path, nil, nil)
      return
    end

    -- ── Tomcat: build runs INSIDE the deploy pipeline as the first stage ────
    -- We fetch the build snapshot synchronously via resolve_build (no spawn,
    -- just a config + env resolution) and hand the whole thing to the
    -- pipeline.
    if cfg_type == "tomcat" then
      arbor.service.call("compile-action.resolve_build", { repo_path = repo_path, build_id = build_id })
        :ok(function(result)
          if not result or result.ok == false then
            local err = (result and result.error) or "unknown error"
            arbor.notify{
              title   = "Run aborted",
              message = "[" .. repo_folder .. "] " .. err,
              level   = "error",
              toast   = false,
            }
            return
          end
          start_tomcat_pipeline(
            run_cfg, repo_path,
            result.build_cfg, result.env, result.command, result.cwd, result.label
          )
        end)
        :err(function(e)
          local kind = (type(e) == "table" and e.kind)    or "error"
          local msg  = (type(e) == "table" and e.message) or tostring(e)
          arbor.notify{
            title   = "Run aborted",
            message = "[" .. repo_folder .. "] cannot resolve build (" .. kind .. "): " .. msg,
            level   = "error",
            toast   = false,
          }
        end)
      return
    end

    -- ── Non-Tomcat: ask compile-action to build, then we receive build-done ─
    state.enqueue_run(run_cfg, nil, repo_path)
    arbor.service.call("compile-action.spawn_build", { repo_path = repo_path, build_id = build_id, silent = true })
      :ok(function(result)
        if not result or result.ok == false then
          state.drop_run(repo_path)
          local err = (result and result.error) or "unknown error"
          arbor.notify{ title = "Run aborted", message = "[" .. repo_folder .. "] " .. err, level = "error", toast = false }
          return
        end
        local pending = state.pending_runs[repo_path]
        if pending then pending.build_cfg = result.build_cfg end
        arbor.notify{
          title   = "Run started",
          message = "[" .. repo_folder .. "] " .. (run_cfg.name or run_cfg.label or value),
          level   = "info",
          persist = false,
        }
      end)
      :err(function(e)
        state.drop_run(repo_path)
        local kind = (type(e) == "table" and e.kind)    or "error"
        local msg  = (type(e) == "table" and e.message) or tostring(e)
        arbor.notify{ title = "Run aborted", message = "[" .. repo_folder .. "] build could not start (" .. kind .. "): " .. msg, level = "error", toast = false }
      end)
  end

  with_pre_chain(run_cfg, repo_path, repo_folder, proceed)
end

arbor.events.on("run:run",     run_dispatch)
arbor.events.on("run:debug",   function(ctx) run_dispatch({ value = (ctx and ctx.value) or "", mode = "debug" }) end)
-- "Restart" wired from the compile sidebar's per-row hover button. Same
-- entry point as a plain run, with no value override → reuses the saved
-- selection (or the first available config).
arbor.events.on("run:restart", function(_ctx) run_dispatch({ value = "" }) end)

-- Default-action target for run_config tree rows: pull cfg_id from the
-- node's data and run that specific config. Used when the user
-- double-clicks / activates a row in the compile sidebar.
local function ctx_cfg_id(ctx)
  local d = ctx and ctx.data
  if type(d) == "table" then return d.cfg_id or "" end
  return ""
end

arbor.events.on("run:run_with_id", function(ctx)
  run_dispatch({ value = ctx_cfg_id(ctx) })
end)

arbor.events.on("run:debug_with_id", function(ctx)
  run_dispatch({ value = ctx_cfg_id(ctx), mode = "debug" })
end)

arbor.events.on("run:restart_with_id", function(ctx)
  -- Same as run with id — the runtime kills the previous run for this repo
  -- before launching the new one (auto-stop semantics).
  run_dispatch({ value = ctx_cfg_id(ctx) })
end)

-- Routed launch from the host's Pipelines panel (Play button).
--
-- `tomcat_pipeline.deploy` registers its def lazily right before running it,
-- with the id `tomcat-deploy:<cfg_id>`. Calling `arbor.pipeline.run` directly
-- on that id from the panel works only as long as the def stays in the
-- registry — and it carries no build resolution / no JDK env. Routing
-- through `run_dispatch` re-runs the full Build + Deploy chain (resolves the
-- attached build cfg via compile-action.resolve_build, releases libgit2
-- handles, etc.) so the panel's Play behaves identically to clicking the
-- combo button.
arbor.events.on("on_pipeline_run_request", function(ctx)
  local def_id = ctx.pipeline_id or ""
  if def_id:sub(1, 14) ~= "tomcat-deploy:" then return end
  local cfg_id = def_id:sub(15)
  run_dispatch({ value = cfg_id })
end)

arbor.events.on("run:open_tomcat_root", function(ctx)
  -- The tomcat_home is captured in the row's `data` when the section is
  -- contributed; we never recompute it here so we don't need to re-read the
  -- run-config storage on every click.
  local d = ctx and ctx.data
  local home = (type(d) == "table") and d.tomcat_home or ""
  if home == "" then
    arbor.notify{ title = "Tomcat root", message = "This run config has no Tomcat home set.", level = "warning" }
    return
  end
  pcall(function() arbor.ui.open_path(home) end)
end)

-- Start catalina against the already-deployed WAR — skip both build and
-- deploy stages. Mirrors the catalina-spawn block in do_run + the success
-- branch of tomcat_pipeline.on_pipeline_done, just without the surrounding
-- pipeline. Useful for fast iteration when the WAR is already in webapps/.
--
-- Fires from three places:
--   · per-row hover button (ctx.data.cfg_id present, no mode → respects cfg)
--   · run:tomcat_no_build_run   (ctx.mode = "run"   → forced no-debug)
--   · run:tomcat_no_build_debug (ctx.mode = "debug" → forced JPDA on)
-- The `mode` field, when present, is honoured exactly the way Run/Debug do
-- on the regular launch path: apply_run_mode overrides debug_port and
-- stamps `_debug_explicit` so the project-level debug fallback below is
-- skipped — otherwise a "Run" on a cfg without debug_port would silently
-- pick up the project default and start the agent anyway.
local function start_tomcat_no_build(ctx)
  local mode   = ctx and ctx.mode or nil
  local cfg_id = ctx_cfg_id(ctx)
  -- Keybinding path: no node clicked → fall back to the saved selection,
  -- or to the first Tomcat config in this repo if nothing is selected.
  if cfg_id == "" then
    cfg_id = rpcfg.load_selected() or ""
    if cfg_id == "" or not (rpcfg.find(cfg_id) or rgcfg.find(cfg_id)) then
      cfg_id = ""
      for _, c in ipairs(rpcfg.load() or {}) do
        if (c.config_type or "") == "tomcat" then cfg_id = c.id; break end
      end
    end
    if cfg_id == "" then
      for _, c in ipairs(rgcfg.load() or {}) do
        if (c.config_type or "") == "tomcat" then cfg_id = c.id; break end
      end
    end
  end
  if cfg_id == "" then
    arbor.notify{ title = "No Tomcat run config", message = "Create or select a Tomcat run configuration first.", level = "warning" }
    return
  end

  local run_cfg = rpcfg.find(cfg_id) or rgcfg.find(cfg_id)
  if not run_cfg then
    arbor.notify{ title = "Run config not found", message = cfg_id, level = "error" }
    return
  end
  if (run_cfg.config_type or "") ~= "tomcat" then
    arbor.notify{ title = "Not a Tomcat config", message = "Skip-build is only available for Tomcat run configurations.", level = "warning" }
    return
  end

  -- Honour the launch mode (when the caller specified one). Same shape as
  -- the regular Run/Debug path: returns a shallow copy with debug_port
  -- forced on/off and `_debug_explicit = true` set.
  run_cfg = apply_run_mode(run_cfg, mode)

  -- Trust ctx.data.repo_path first (set when the row was contributed) and
  -- fall back to state.current_repo for the keybinding path.
  local repo_path = ""
  local d = ctx and ctx.data
  if type(d) == "table" then repo_path = d.repo_path or "" end
  if repo_path == "" then repo_path = state.current_repo or "" end
  if repo_path == "" then
    arbor.notify{ title = "No active repository", message = "Open a repo tab before starting Tomcat.", level = "warning" }
    return
  end
  local repo_folder = repo_path:match("[/\\]([^/\\]+)[/\\]?$") or repo_path

  local tomcat_home = run_cfg.tomcat_home
  if not tomcat_home or tomcat_home == "" then
    pcall(function() tomcat_home = rpcfg.load_tomcat_home() end)
  end
  if not tomcat_home or tomcat_home == "" or not arbor.fs.is_dir(tomcat_home) then
    arbor.notify{ title = "Tomcat home invalid", message = "Set a valid Tomcat Home on '" .. (run_cfg.name or cfg_id) .. "' first.", level = "warning" }
    return
  end
  local debug_port = run_cfg.debug_port or ""
  -- Skip the project-level fallback when the caller already made an
  -- explicit choice via `mode` — otherwise "Run" on a cfg without
  -- debug_port would silently re-enable the agent through the project
  -- default. (Same guard as start_tomcat_pipeline.)
  if debug_port == "" and not run_cfg._debug_explicit then
    pcall(function() debug_port = rpcfg.load_debug_port() or "" end)
  end

  -- Stop any previous run for this repo+cfg so the catalina port is free.
  if resolve_auto_stop() then
    local existing = state.get_running(repo_path, cfg_id)
    if existing then
      arbor.job.cancel(existing)
      state.untrack_run(repo_path, cfg_id)
    end
  end

  -- Pre-existing JDK fallback chain — same as resolve_run_env.
  local svc_env = resolve_run_env(run_cfg, nil)
  local jpda = debug_port ~= ""
  if jpda then
    svc_env["JPDA_ADDRESS"]   = "*:" .. debug_port
    svc_env["JPDA_TRANSPORT"] = "dt_socket"
  end
  svc_env["CATALINA_HOME"] = tomcat_home

  local is_win   = arbor.meta.os() == "windows"
  local script   = is_win and "catalina.bat" or "catalina.sh"
  local catalina = arbor.fs.join(tomcat_home, "bin", script)
  if not arbor.fs.is_file(catalina) then
    arbor.notify{ title = "catalina not found", message = catalina, level = "error" }
    return
  end
  local svc_command = '"' .. catalina .. '" ' .. (jpda and "jpda run" or "run")

  local nb_notify_done = run_cfg.notify_on_completion
  if nb_notify_done == nil then nb_notify_done = true end

  local job, spawn_err = arbor.job.spawn({
    name     = repo_folder .. " (catalina)",
    command  = svc_command,
    cwd      = tomcat_home,
    env      = svc_env,
    category = "Services",
    hidden   = services_hidden(),
    on_done  = function(svc_ctx)
      state.untrack_run(repo_path, cfg_id)
      run_combo.refresh()
      if not nb_notify_done then return end
      if svc_ctx.success then
        arbor.notify{ title = "Tomcat stopped", message = "[" .. repo_folder .. "] exited cleanly", level = "info" }
      else
        arbor.notify{ title = "Tomcat stopped", message = "[" .. repo_folder .. "] exited with code " .. (svc_ctx.exit_code or -1), level = "warning" }
      end
    end,
  })
  if not job then
    arbor.notify{ title = "Tomcat failed to start", message = tostring(spawn_err), level = "error" }
    return
  end
  state.track_run(repo_path, cfg_id, job.id)
  run_combo.refresh()
  arbor.notify{
    title   = jpda and "Tomcat started (debug, no build)" or "Tomcat started (no build)",
    message = "[" .. repo_folder .. "] catalina launched against existing WAR"
            .. (jpda and (" — JPDA on :" .. debug_port) or "") .. ".",
    level   = "success",
  }
end

arbor.events.on("run:start_tomcat_no_build", start_tomcat_no_build)

-- Forced-mode entry points used by the Ctrl+Shift+F10 / F9 keybindings.
-- Plain delegates so the heavy lifting stays in one place; they exist
-- because keybinding payloads can't carry a `mode` field — the only way
-- to distinguish "Run no-build" from "Debug no-build" is by action name.
-- We can't `arbor.events.emit("run:start_tomcat_no_build", …)` here because
-- emit enforces that the prefix matches the plugin name (it's `run-action`,
-- not `run`). Direct call is correct anyway: same plugin, same VM.
local function with_mode(forced)
  return function(ctx)
    local merged = { mode = forced }
    if type(ctx) == "table" then
      for k, v in pairs(ctx) do if merged[k] == nil then merged[k] = v end end
    end
    start_tomcat_no_build(merged)
  end
end
arbor.events.on("run:tomcat_no_build_run",   with_mode("run"))
arbor.events.on("run:tomcat_no_build_debug", with_mode("debug"))

-- ── Selection persistence ─────────────────────────────────────────────────────

arbor.events.on("run:select", function(ctx)
  local value = ctx.value or ""
  if value ~= "" and value ~= "__run_project_settings__" then
    rpcfg.save_selected(value)
  end
end)

-- ── Settings form + delegated handlers ────────────────────────────────────────

arbor.events.on("run:open_settings", function(_ctx)
  rpcfg.open_project_run_settings_form(state.current_repo)
end)

-- Pre-open hook for the compile-action settings panel. Fired synchronously
-- by the orchestrator before reading contributions; we just re-publish
-- our sections so any run-config mutation outside our own flow is picked
-- up on the next open.
arbor.events.on("run:settings_refresh", function(_ctx)
  rgcfg.contribute_sections()
end)

arbor.events.on("run:global_settings_noop", function(_ctx) end)
arbor.events.on("run:global_set_auto_stop", function(ctx)  rgcfg.handle_set_auto_stop(ctx)              end)
arbor.events.on("run:global_add_config",    function(ctx)  rgcfg.handle_add(ctx);    run_combo.refresh() end)
arbor.events.on("run:global_set_default",   function(ctx)  rgcfg.handle_set_default(ctx)               end)
arbor.events.on("run:global_delete",        function(ctx)  rgcfg.handle_delete(ctx); run_combo.refresh() end)
arbor.events.on("run:global_edit",          function(ctx)  rgcfg.handle_edit(ctx)                       end)
arbor.events.on("run:global_edit_save",     function(ctx)  rgcfg.handle_edit_save(ctx); run_combo.refresh() end)

arbor.events.on("run:project_settings_noop", function(_ctx) end)
arbor.events.on("run:project_set_auto_stop", function(ctx)  rpcfg.handle_set_auto_stop(ctx) end)

-- ── New IntelliJ-style run-config tree modal ─────────────────────────────────
arbor.events.on("run:cfg_save_all",   function(ctx) rpcfg.handle_save_all(ctx)        end)
arbor.events.on("run:cfg_cancel",     function(ctx) rpcfg.handle_cancel(ctx)          end)
arbor.events.on("run:cfg_new",        function(ctx) rpcfg.handle_cfg_new(ctx)         end)
arbor.events.on("run:cfg_remove",     function(ctx) rpcfg.handle_cfg_remove(ctx)      end)
arbor.events.on("run:cfg_duplicate",  function(ctx) rpcfg.handle_cfg_duplicate(ctx)   end)
arbor.events.on("run:cfg_export",       function(ctx) rpcfg.handle_cfg_export(ctx)        end)
arbor.events.on("run:cfg_import_open",  function(ctx) rpcfg.handle_cfg_import_open(ctx)   end)
arbor.events.on("run:cfg_import_save",  function(ctx) rpcfg.handle_cfg_import_save(ctx)   end)
arbor.events.on("run:cfg_import_cancel",function(ctx) rpcfg.handle_cfg_import_cancel(ctx) end)
