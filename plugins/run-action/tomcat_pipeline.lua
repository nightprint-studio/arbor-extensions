-- tomcat_pipeline.lua — the run-action Tomcat deploy, expressed as a
-- resumable / observable arbor.pipeline.
--
-- The pipeline now owns the WHOLE compile + deploy arc:
--   1. Build      — runs the project's mvn/gradle/make command
--   2. Preflight  — verifies the catalina script is in place
--   3. Clean      — removes the previous WAR + exploded dir from webapps/
--   4. Deploy     — copies the freshly built WAR into webapps/
--
-- Putting the build INSIDE the pipeline (instead of running it as a
-- separate Job before kicking off the deploy) gives the user one unified
-- progress timeline and lets resume/cancel work across both phases.
-- Catalina itself is NOT a pipeline stage — it's a never-ending service
-- spawned via arbor.job.spawn from on_pipeline_done, which would fight
-- the orchestrator's "every step must terminate" contract.

local state = require("state")

local M = {}

-- run_id → launch context. Populated by M.deploy(), consumed by the
-- PIPELINE_DONE hook so we know which run is ours and with what settings
-- to launch catalina once the deploy steps succeed.
local pending = {}

-- Build the pipeline def. The Build stage is included only when the caller
-- resolved a build cfg + command (i.e. user did not pick "skip build"); the
-- Clean + Deploy stages defer WAR-name resolution to runtime ops because on
-- a first-ever deploy the .war does not exist when the pipeline def is
-- built — it is produced by the Build stage.
local function build_def(args)
  local stages = {}

  if args.build_command and args.build_command ~= "" then
    stages[#stages+1] = {
      id = "build", name = "Build",
      steps = {
        {
          id      = "compile",
          name    = args.build_label or "Compile",
          command = args.build_command,
          cwd     = args.build_cwd,
          env     = args.build_env or {},
        },
      },
    }
  end

  stages[#stages+1] = {
    id = "preflight", name = "Preflight",
    steps = {
      {
        id     = "catalina-present",
        name   = "Catalina script present",
        lua_op = { op = "assert_file_exists", params = { path = args.catalina } },
      },
    },
  }

  stages[#stages+1] = {
    id = "clean", name = "Clean webapps",
    steps = {
      {
        id     = "rm",
        name   = "Remove old WAR + exploded dir",
        lua_op = { op = "tomcat_clean_old",
                   params = { target_dir = args.target_dir, webapps = args.webapps } },
      },
    },
  }

  stages[#stages+1] = {
    id = "deploy", name = "Deploy",
    steps = {
      {
        id     = "copy",
        name   = "Copy WAR → webapps/",
        lua_op = { op = "tomcat_deploy_war",
                   params = { target_dir = args.target_dir, webapps = args.webapps } },
      },
    },
  }

  -- Reuse the display name from the existing pipeline def in the registry
  -- whenever one is there — `register_run_stubs` (and any previous compile)
  -- has already resolved it from the run config. This keeps the panel
  -- label stable across stub → compile → replay without us re-doing the
  -- run-config lookup ourselves.
  local def_id = "tomcat-deploy:" .. args.cfg_id
  local existing
  pcall(function() existing = arbor.pipeline.get(def_id) end)
  local existing_name
  if type(existing) == "table"
     and type(existing.name) == "string"
     and existing.name ~= ""
  then
    existing_name = existing.name
  end

  -- Fallback chain — only hit when no def is registered yet (first-ever
  -- deploy AND register_run_stubs hasn't fired for this cfg). In Lua "" is
  -- truthy so we explicitly skip empty strings instead of an `or` chain.
  local function nonempty(s) return (type(s) == "string" and s ~= "") and s or nil end
  local fallback = nonempty(args.repo_folder)
                or nonempty(args.cfg_name)
                or nonempty(args.cfg_label)
                or args.cfg_id

  return {
    id          = def_id,
    name        = existing_name or ("Deploy " .. fallback),
    description = "Build · clean webapps · deploy WAR · launch Tomcat.",
    icon        = "Server",
    lock_key    = "tomcat-deploy:" .. args.repo_path,
    log_level   = "info",
    stages      = stages,
  }
end

-- Resolve + kick off the deploy. `args` is a flat table with everything
-- main.lua already computed in the tomcat branch:
--   run_cfg, repo_path, repo_folder, cfg_id, tomcat_home, svc_env, svc_command,
--   target_dir, stop_existing,
--   build_command (optional), build_env (optional), build_cwd (optional),
--   build_label (optional)
-- Returns the started run_id, or false + err string when preconditions fail.
function M.deploy(args)
  local repo_path     = args.repo_path
  local repo_folder   = args.repo_folder
  local cfg_id        = args.cfg_id
  local tomcat_home   = args.tomcat_home
  local target_dir    = args.target_dir
  local stop_existing = args.stop_existing or function() end

  local is_win   = arbor.meta.os() == "windows"
  local script   = is_win and "catalina.bat" or "catalina.sh"
  local catalina = arbor.fs.join(tomcat_home, "bin", script)
  local webapps  = arbor.fs.join(tomcat_home, "webapps")

  -- Stop any previous instance BEFORE the pipeline runs so Tomcat's file
  -- locks are released by the time the Clean stage tries to remove the
  -- exploded dir. If Tomcat hangs on shutdown the pipeline fails loud on
  -- the delete — exactly the signal we want.
  stop_existing()

  local def = build_def({
    cfg_id        = cfg_id,
    cfg_name      = args.cfg_name,
    cfg_label     = args.cfg_label,
    repo_path     = repo_path,
    repo_folder   = repo_folder,
    catalina      = catalina,
    webapps       = webapps,
    target_dir    = target_dir,
    build_command = args.build_command,
    build_env     = args.build_env,
    build_cwd     = args.build_cwd,
    build_label   = args.build_label,
  })
  arbor.pipeline.define(def)

  local run_id, run_err = arbor.pipeline.run{ pipeline_id = def.id, cwd = tomcat_home }
  if not run_id then
    return false, tostring(run_err)
  end

  pending[run_id] = {
    repo_path   = repo_path,
    repo_folder = repo_folder,
    cfg_id      = cfg_id,
    tomcat_home = tomcat_home,
    svc_env     = args.svc_env,
    svc_command = args.svc_command,
  }

  return run_id
end

-- Hooked to "on_pipeline_done" by main.lua. Ignores every run that wasn't
-- started by this module. On success → spawn catalina; on failure → leave
-- the run resumable from the Pipelines panel. The host already emits the
-- pipeline started/succeeded/failed notifications, so we only surface
-- service-level events (catalina spawn failure, service exit).
function M.on_pipeline_done(ctx)
  local pend = pending[ctx.run_id]
  if not pend then return end
  pending[ctx.run_id] = nil

  if ctx.status ~= "success" then
    return
  end

  -- Deploy stages all green → start catalina as a long-running service.
  local run_combo = require("ui.run_combo")
  local job, spawn_err = arbor.job.spawn({
    name     = pend.repo_folder,
    command  = pend.svc_command,
    cwd      = pend.tomcat_home,
    env      = pend.svc_env,
    category = "Services",
    hidden   = state.services_hidden(),
    on_done  = function(svc_ctx)
      state.untrack_run(pend.repo_path, pend.cfg_id)
      run_combo.refresh()
      -- Service-stop is a meaningful event for the user (the app they were
      -- running is gone) — keep it as a notification, but silent (no toast).
      local lvl = svc_ctx.success and "info" or "warning"
      local msg = svc_ctx.success
        and "[" .. pend.repo_folder .. "] exited cleanly"
        or  "[" .. pend.repo_folder .. "] exited with code " .. (svc_ctx.exit_code or -1)
      arbor.notify{ title = "Tomcat stopped", message = msg, level = lvl, toast = false }
    end,
  })
  if not job then
    arbor.notify{
      title   = "Tomcat failed to start",
      message = tostring(spawn_err),
      level   = "error",
      toast   = false,
    }
    return
  end
  state.track_run(pend.repo_path, pend.cfg_id, job.id)
  run_combo.refresh()
end

return M
