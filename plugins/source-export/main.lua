-- source-export / main.lua — entry point, action wiring, lifecycle.
--
-- Responsibilities of this file:
--   · register the ActivityBar combo and refresh it on repo/tab changes
--   · fan out plugin actions ("source-export:*") to the right helper module
--   · handle profile mutation actions from the Edit Configurations modal
--   · kick off pipeline runs (Phase 2 will compile stages into arbor.pipeline)
--
-- Source of truth for the various sub-systems:
--   · profile CRUD (per-repo) → config/project.lua
--   · plugin-global settings / templates → config/global.lua
--   · operation catalog (palette + step forms) → operations.lua
--   · profile shape helpers → profile_schema.lua
--   · Edit Configurations modal → ui/modal.lua
--   · Settings modal → ui/settings.lua
--   · JSON import/export → import_export.lua

local schema        = require("profile_schema")
local pcfg          = require("config.project")
local gcfg          = require("config.global")
local ops           = require("operations")
local combo         = require("ui.combo")
local modal         = require("ui.modal")
local settings_ui   = require("ui.settings")
local io_ex         = require("import_export")
local compile       = require("compile")
-- ── Sequences (cross-repo meta-exports) ─────────────────────────────────────
local seq_schema        = require("sequence_schema")
local seq_store         = require("config.sequences")
local seq_runner        = require("sequence_runner")
local seq_sidebar       = require("ui.sequence_sidebar")
local seq_modal         = require("ui.sequence_modal")
local seq_history_modal = require("ui.sequence_history_modal")

local state = { current_repo = "" }

-- Snapshot of every profile we've ever registered as a stub, keyed by
-- def id (e.g. "profile:cfg_xyz"). Populated by `register_profile_stubs`
-- on every repo activation, READ by `on_pipeline_run_request` so the
-- handler can recover the source repo + profile data even when the user
-- has switched tabs after registration.
--
-- Each entry: { repo = <repo_path>, profile = <profile_table_snapshot> }.
-- The snapshot is treated as a fallback — when the active repo matches
-- `entry.repo` we still re-load the latest profile via `pcfg.find` to
-- pick up edits made since registration.
local stub_index = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- Lifecycle
-- ─────────────────────────────────────────────────────────────────────────────

arbor.events.on("on_plugin_load", function(ctx)
  combo.register()
  -- Register the plugin-settings panel up-front so the gear icon in the
  -- Plugin Manager appears for source-export. The panel is the ONLY entry
  -- point for plugin-wide settings — the toolbar combo deals exclusively
  -- with per-repo profiles. `on_load` fires every time the modal opens,
  -- giving us a chance to re-contribute sections with fresh state
  -- (templates list in particular).
  arbor.ui.settings.panel({
    id           = "main",
    title        = "Source Export — Settings",
    icon         = "Settings",
    width        = "720px",
    height       = "560px",
    submit_label = "Save",
    cancel_label = "Close",
    on_load      = "source-export:settings_refresh",
  })
  -- Pipeline op catalog: every kind referenced by a profile step maps to a
  -- Lua handler registered here. File / content ops are plugin-local
  -- (pipeline_ops/*.lua); structured-edit / assert come from arbor.core.*.
  require("pipeline_ops.file").register()
  require("pipeline_ops.content").register()
  require("arbor.core.edit").register()
  require("arbor.core.assert").register()
  seq_sidebar.register()  -- right-side "Export Sequences" panel
  -- Orphan recovery: any SequenceRun still tagged "running" was interrupted
  -- by a crash / restart — mark it failed so the History view is accurate.
  seq_runner.sweep_on_load()
  arbor.keybinding.register({
    key         = "E",
    ctrl        = true,
    shift       = true,
    action      = "source-export:open_edit",
    description = "Source Export: edit configurations",
  })
  arbor.log.info("source-export ready (api_version=" .. tostring(ctx.api_version) .. ")")
end)

-- Panel content: Arbor fires `panel:open:<id>` every time the sidebar icon
-- is clicked. We re-push on each open so the list reflects whatever was
-- added / deleted / run since last time — no reactive polling needed.
arbor.events.on("panel:open:sequences", function(_ctx)
  seq_sidebar.push()
end)

-- Make every profile of the active repo show up in the Pipelines panel,
-- even before the user runs it for the first time. Without this, the panel
-- is empty on a fresh app start: pipeline defs live in memory only, and we
-- otherwise populate them lazily from `compile.run`.
--
-- The stub registered here has no stages — `compile.run` replaces it with
-- the fully compiled version just before starting the orchestrator.
local function register_profile_stubs()
  local profiles = {}
  pcall(function() profiles = pcfg.load() end)
  if type(profiles) ~= "table" then return end
  local repo = arbor.repo.current() or state.current_repo or ""
  for _, p in ipairs(profiles) do
    local def_id = "profile:" .. p.id
    pcall(function()
      arbor.pipeline.define({
        id          = def_id,
        name        = p.name or p.id,
        description = p.description or "",
        icon        = "Share2",
        lock_key    = "source-export:" .. p.id,
        log_level   = p.log_level or "info",
        stages      = {},   -- stub; real stages are provided by compile.run
      })
    end)
    -- Remember which repo this def belongs to + a snapshot of the profile.
    -- Used by `on_pipeline_run_request` so a Play click works even if the
    -- user has switched to a different tab since registration.
    stub_index[def_id] = { repo = repo, profile = p }
  end
end

local function on_repo_activated(path)
  if path == "" then return end
  state.current_repo = path
  combo.refresh(pcfg.load_selected())
  register_profile_stubs()
end

arbor.events.on("on_repo_open", function(ctx)
  on_repo_activated(ctx.path or ctx.repo or "")
end)

arbor.events.on("on_tab_switch", function(ctx)
  on_repo_activated(ctx.path or "")
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Combo actions
-- ─────────────────────────────────────────────────────────────────────────────

arbor.events.on("source-export:run", function(ctx)
  local value = ctx.value or ""

  if value == combo.NEW_PROFILE then
    local p = schema.new_profile("New Profile")
    pcfg.upsert(p)
    pcfg.save_selected(p.id)
    combo.refresh(p.id)
    modal.open(p.id)
    return
  end
  if value == combo.EDIT_CONFIGS then
    modal.open(pcfg.load_selected())
    return
  end

  if value == "" then value = pcfg.load_selected() end
  local p = pcfg.find(value)
  if not p then
    arbor.notify{ message = "Select a profile first", level = "warning" }
    return
  end

  -- Compile the profile into a pipeline definition and start a run.
  -- `compile.run` validates ops, resolves variables, acquires the lock, and
  -- delegates to arbor.pipeline.run which spawns the orchestrator thread.
  local ok, run_id_or_err = compile.run(p)
  if not ok then
    arbor.notify{ title = "Export failed to start", message = run_id_or_err, level = "error" }
    return
  end
end)

-- Routed launch from the host's Pipelines panel (Play button).
--
-- The panel's `request_pipeline_run` command only fires this hook when the
-- def is a *stub* (empty `stages`) — defs already compiled by a previous
-- `compile.run` call (combo button, sequence runner, …) carry their full
-- stages and are replayed directly by the host without involving us. This
-- means we only land here on the very first Play after a fresh repo open,
-- before any other path has compiled the profile.
--
-- Our job: turn the def id `profile:<p.id>` back into a profile object and
-- delegate to `compile.run` — same materialise-stages-then-run path the
-- combo button takes. Profiles are repo-scoped and the panel shows defs
-- from every repo opened since app start, so we keep an in-memory
-- `stub_index` snapshot to handle "Play on a def whose origin tab the user
-- is no longer viewing".
arbor.events.on("on_pipeline_run_request", function(ctx)
  local def_id = ctx.pipeline_id or ""
  if def_id:sub(1, 8) ~= "profile:" then return end
  local profile_id = def_id:sub(9)
  local entry      = stub_index[def_id]
  local active     = arbor.repo.current() or ""

  -- Path 1 — same repo as registration: re-load from settings so any edits
  -- the user made since stub registration (rename, new stage, …) take
  -- effect on this run.
  local p
  if entry and entry.repo ~= "" and entry.repo == active then
    p = pcfg.find(profile_id)
  end

  -- Path 2 — different (or unknown) repo: use the cached snapshot so the
  -- run still works without forcing the user to switch tabs first. The
  -- profile won't reflect post-registration edits — flag that softly.
  if not p and entry and entry.profile then
    p = entry.profile
    if entry.repo ~= active then
      arbor.notify{
        title   = "Running cross-repo profile",
        message = "Using the snapshot captured when '" .. (entry.repo or "?") .. "' was active. Switch tabs to edit it.",
        level   = "info",
      }
    end
  end

  -- Path 3 — last-resort try in the active repo (e.g. plugin reload wiped
  -- `stub_index` but the profile still lives on disk under the active tab).
  if not p then p = pcfg.find(profile_id) end

  if not p then
    arbor.notify{
      title   = "Profile not found",
      message = "Source export profile '" .. profile_id .. "' is no longer registered in any open repo.",
      level   = "warning",
    }
    return
  end

  -- Pin source_path to the def's origin repo when we're running across
  -- tabs — otherwise `vars.build_ctx` would default to the active tab's
  -- path and steps would resolve files / cwd against the wrong repo.
  local run_opts = nil
  if entry and entry.repo and entry.repo ~= "" and entry.repo ~= active then
    run_opts = { source_path = entry.repo }
  end

  local ok, run_id_or_err = compile.run(p, run_opts)
  if not ok then
    arbor.notify{ title = "Export failed to start", message = tostring(run_id_or_err), level = "error" }
    return
  end
end)

arbor.events.on("source-export:select", function(ctx)
  local value = ctx.value or ""
  if value == "" then return end
  if value == combo.NEW_PROFILE or value == combo.EDIT_CONFIGS then
    return -- magic values: only meaningful as primary action
  end
  pcfg.save_selected(value)
end)

arbor.events.on("source-export:open_edit", function(_ctx)
  modal.open(pcfg.load_selected())
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Modal — apply pending edits before mutating
-- ─────────────────────────────────────────────────────────────────────────────
--
-- The modal is rebuilt on every mutation via `form.replace`. Each rebuild
-- preserves the user's in-progress field edits by pulling them out of `ctx`
-- (the current form values) and applying them to the currently-selected
-- profile BEFORE we do the requested mutation.

local function apply_pending_edits(ctx)
  local profiles = pcfg.load()
  local sel_id   = modal.state.selected_profile_id
  if sel_id == "" then return profiles end

  local profile
  for _, p in ipairs(profiles) do if p.id == sel_id then profile = p; break end end
  if not profile then return profiles end

  -- ── Info tab ───────────────────────────────────────────────────────────
  if ctx.info_name         then profile.name        = ctx.info_name end
  if ctx.info_description  then profile.description = ctx.info_description end
  if ctx.info_branch_src   ~= nil then profile.branch_src  = ctx.info_branch_src end
  if ctx.info_branch_dest  then profile.branch_dest = ctx.info_branch_dest end
  if ctx.info_remote_url   then profile.remote_url  = ctx.info_remote_url end
  if ctx.info_log_level    then profile.log_level   = ctx.info_log_level end
  if ctx.info_auto_clone   ~= nil then
    profile.auto_clone = ctx.info_auto_clone and true or false
  end
  if ctx.info_variables and type(ctx.info_variables) == "table" then
    -- kv_list payload is a `Record<string,string>` (the form DSL's canonical
    -- shape) — iterate via `pairs`, not `ipairs`. The `has_real_entries`
    -- guard stays: kv_list echoes an empty `{}` in several edge cases
    -- (right after `set_values`, or before the user types anything) and we
    -- don't want a spurious echo to wipe imported variables.
    --
    -- Historical note: ipairs-based code here produced the "[object Object]"
    -- display + silently-dropped saves — fixed by going through pairs and
    -- matching the DSL's Record format.
    local has_real_entries = false
    for k, _ in pairs(ctx.info_variables) do
      local kk = tostring(k or ""):gsub("^%s+", ""):gsub("%s+$", "")
      if kk ~= "" then has_real_entries = true; break end
    end
    if has_real_entries then
      local vars = {}
      for k, v in pairs(ctx.info_variables) do
        local kk = tostring(k or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if kk ~= "" then vars[#vars+1] = { key = kk, value = tostring(v or "") } end
      end
      profile.variables = vars
    end
  end
  if ctx.info_env and type(ctx.info_env) == "table" then
    -- Same Record<string,string>-with-spurious-empty-echo guard as Variables.
    -- An empty echo would otherwise wipe an env list the user just configured
    -- in another tab.
    local has_real_entries = false
    for k, _ in pairs(ctx.info_env) do
      local kk = tostring(k or ""):gsub("^%s+", ""):gsub("%s+$", "")
      if kk ~= "" then has_real_entries = true; break end
    end
    if has_real_entries then
      local env = {}
      for k, v in pairs(ctx.info_env) do
        local kk = tostring(k or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if kk ~= "" then env[#env+1] = { key = kk, value = tostring(v or "") } end
      end
      profile.env = env
    end
  end

  -- ── Rules tab — stage settings (inline in the detail column) ───────────
  for _, stage in ipairs(profile.stages or {}) do
    local snkey = "stage_name_" .. stage.id
    if ctx[snkey] ~= nil and ctx[snkey] ~= "" then stage.name = ctx[snkey] end
    local smkey = "stage_mode_" .. stage.id
    if ctx[smkey] ~= nil and ctx[smkey] ~= "" then stage.mode = ctx[smkey] end
    local spkey = "stage_max_parallel_" .. stage.id
    if ctx[spkey] ~= nil then
      local n = tonumber(ctx[spkey]) or 0
      stage.max_parallel = (n > 0) and n or nil
    end
  end

  -- ── Rules tab — step name / allow_failure / params ─────────────────────
  for _, stage in ipairs(profile.stages or {}) do
    for _, step in ipairs(stage.steps or {}) do
      local nkey = "step_name_" .. step.id
      if ctx[nkey] ~= nil then step.name = ctx[nkey] end
      local afkey = "step_allow_fail_" .. step.id
      if ctx[afkey] ~= nil then step.allow_failure = ctx[afkey] and true or false end

      -- Parameter fields are prefixed "param_<step_id>_"
      local prefix = "param_" .. step.id .. "_"
      local prefix_len = #prefix
      local new_params = step.params or {}
      local touched = false
      for k, v in pairs(ctx) do
        if type(k) == "string" and k:sub(1, prefix_len) == prefix then
          local pname = k:sub(prefix_len + 1)
          new_params[pname] = v
          touched = true
        end
      end
      if touched then step.params = new_params end
    end
  end

  -- Persist whichever piece of modal state came back with the action, so the
  -- next rebuild stays on the same tab / row.
  if ctx.active_tab          then modal.state.active_tab          = ctx.active_tab end
  if ctx.sel_profile         then modal.state.selected_profile_id = ctx.sel_profile end
  if ctx.palette_query ~= nil then modal.state.palette_query      = ctx.palette_query end

  pcfg.upsert(profile)
  return pcfg.load()
end

-- Shortcut: apply edits, then rebuild the modal.
local function apply_and_refresh(ctx)
  apply_pending_edits(ctx or {})
  modal.refresh()
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Profile-level modal actions
-- ─────────────────────────────────────────────────────────────────────────────

arbor.events.on("source-export:save_all", function(ctx)
  apply_pending_edits(ctx)
  arbor.notify{ message = "Source Export profiles saved ✓", level = "success" }
  combo.refresh(modal.state.selected_profile_id)
  register_profile_stubs()
end)

arbor.events.on("source-export:cancel", function(_ctx) end)

arbor.events.on("source-export:new_profile", function(ctx)
  apply_pending_edits(ctx)
  local tpl_id = ctx.template or ""
  local new_p
  if tpl_id ~= "" then
    new_p = gcfg.instantiate_template(tpl_id, nil)
  end
  if not new_p then new_p = schema.new_profile("New Profile") end
  pcfg.upsert(new_p)
  modal.state.selected_profile_id = new_p.id
  modal.state.active_tab          = "info"
  modal.state.selected_stage_id   = ""
  modal.state.selected_step_id    = ""
  combo.refresh(new_p.id)
  modal.refresh()
  register_profile_stubs()
end)

arbor.events.on("source-export:duplicate_profile", function(ctx)
  apply_pending_edits(ctx)
  local pid = ctx.profile_id or modal.state.selected_profile_id
  local copy = pcfg.duplicate(pid)
  if copy then
    modal.state.selected_profile_id = copy.id
    combo.refresh(copy.id)
    modal.refresh()
    register_profile_stubs()
    arbor.notify{ message = "Profile duplicated", level = "success" }
  end
end)

-- Fires when the user clicks a different profile in the left tree.
-- apply_pending_edits saves the CURRENT profile's in-progress edits to disk
-- first (it reads `modal.state.selected_profile_id` at entry, so the save
-- targets the PREVIOUS profile), then updates selected_profile_id to the new
-- value from ctx.sel_profile, then refresh() rebuilds the content column with
-- the new profile's data (pushed via set_values so the Info tab actually
-- reflects the switch — form.replace alone would keep the old values).
arbor.events.on("source-export:select_profile", function(ctx)
  apply_pending_edits(ctx)
  -- Always reset step/stage selection and land on Info so the detail column
  -- is predictable after a profile switch (otherwise stale stage/step ids
  -- would still point at the old profile's rows).
  modal.state.selected_stage_id = ""
  modal.state.selected_step_id  = ""
  modal.state.active_tab        = "info"
  modal.refresh()
end)

arbor.events.on("source-export:delete_profile", function(ctx)
  apply_pending_edits(ctx)
  local pid = ctx.profile_id or modal.state.selected_profile_id
  if pid == "" then return end
  pcfg.remove(pid)
  local rest = pcfg.load()
  modal.state.selected_profile_id = rest[1] and rest[1].id or ""
  combo.refresh(modal.state.selected_profile_id)
  modal.refresh()
  arbor.notify{ message = "Profile deleted", level = "info" }
end)

arbor.events.on("source-export:export_profile", function(ctx)
  local pid = ctx.profile_id or modal.state.selected_profile_id
  if pid == "" then return end
  io_ex.export_profile(pid)
end)

-- Opens the native file picker and routes the chosen path to
-- `source-export:do_import_profile` (empty path on cancel).
arbor.events.on("source-export:import_profile", function(_ctx)
  arbor.ui.pick_file({
    mode        = "file",
    title       = "Importa profilo Source Export",
    extensions  = { "json" },
    action      = "source-export:do_import_profile",
  })
end)

arbor.events.on("source-export:do_import_profile", function(ctx)
  local path = ctx.path or ""
  if path == "" then return end                              -- user cancelled
  local imported = io_ex.import_profile(path)
  if imported then
    modal.state.selected_profile_id = imported.id
    combo.refresh(imported.id)
    modal.refresh()
  end
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Stage actions
-- ─────────────────────────────────────────────────────────────────────────────

arbor.events.on("source-export:add_stage", function(ctx)
  apply_pending_edits(ctx)
  local profile = pcfg.find(modal.state.selected_profile_id)
  if not profile then return end
  local stage = schema.new_stage("Nuovo gruppo")
  schema.add_stage(profile, stage)
  pcfg.upsert(profile)
  modal.state.selected_stage_id = stage.id
  modal.state.active_tab        = "rules"
  modal.refresh()
end)

arbor.events.on("source-export:select_stage", function(ctx)
  apply_pending_edits(ctx)
  modal.state.selected_stage_id = ctx.stage_id or ""
  -- Clear step selection so the detail column swaps to stage settings.
  modal.state.selected_step_id  = ""
  modal.refresh()
end)

arbor.events.on("source-export:remove_stage", function(ctx)
  apply_pending_edits(ctx)
  local profile = pcfg.find(modal.state.selected_profile_id)
  if profile then
    schema.remove_stage(profile, ctx.stage_id)
    pcfg.upsert(profile)
  end
  if modal.state.selected_stage_id == ctx.stage_id then
    modal.state.selected_stage_id = ""
    modal.state.selected_step_id  = ""
  end
  modal.refresh()
end)

arbor.events.on("source-export:move_stage_up", function(ctx)
  apply_pending_edits(ctx)
  local profile = pcfg.find(modal.state.selected_profile_id)
  if profile then schema.move_stage(profile, ctx.stage_id, -1); pcfg.upsert(profile) end
  modal.refresh()
end)

arbor.events.on("source-export:move_stage_down", function(ctx)
  apply_pending_edits(ctx)
  local profile = pcfg.find(modal.state.selected_profile_id)
  if profile then schema.move_stage(profile, ctx.stage_id, 1); pcfg.upsert(profile) end
  modal.refresh()
end)

-- Stage settings are now rendered inline in the detail column whenever a
-- stage is selected (click on the stage header). The dedicated gear icon in
-- the stage header emits `edit_stage`, which we alias to a straight
-- `select_stage` so both paths lead to the same inline editor.
arbor.events.on("source-export:edit_stage", function(ctx)
  apply_pending_edits(ctx)
  modal.state.selected_stage_id = ctx.stage_id or modal.state.selected_stage_id
  modal.state.selected_step_id  = ""   -- clear step selection so stage form shows
  modal.refresh()
end)

arbor.events.on("source-export:export_stage", function(ctx)
  apply_pending_edits(ctx)
  local sid = ctx.stage_id or modal.state.selected_stage_id
  if not sid or sid == "" then
    arbor.notify{ message = "Nessun gruppo selezionato", level = "warning" }
    return
  end
  io_ex.export_stage(modal.state.selected_profile_id, sid)
end)

arbor.events.on("source-export:import_stage", function(ctx)
  apply_pending_edits(ctx)
  if modal.state.selected_profile_id == "" then return end
  arbor.ui.pick_file({
    mode        = "file",
    title       = "Importa gruppo nel profilo '" .. (pcfg.find(modal.state.selected_profile_id) and pcfg.find(modal.state.selected_profile_id).name or "?") .. "'",
    extensions  = { "json" },
    action      = "source-export:do_import_stage",
    extra       = { profile_id = modal.state.selected_profile_id },
  })
end)

arbor.events.on("source-export:do_import_stage", function(ctx)
  local path = ctx.path or ""
  local pid  = ctx.profile_id or modal.state.selected_profile_id
  if path == "" or pid == "" then return end                 -- user cancelled
  local imported = io_ex.import_stage(pid, path)
  if imported then
    modal.state.selected_stage_id = imported.id
    modal.state.selected_step_id  = ""
    modal.state.active_tab        = "rules"
    modal.refresh()
  end
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Step actions
-- ─────────────────────────────────────────────────────────────────────────────

-- Helper: move step within ITS PARENT array (works for top-level + nested
-- steps under an if_block branch). Replaces the old top-level-only
-- schema.move_step call which choked on nested children once if_block
-- subgroups landed.
local function move_step_in_place(profile, step_id, delta)
  local _step, parent_arr, idx = schema.find_step_anywhere(profile, step_id)
  if not parent_arr or not idx then return end
  local j = math.max(1, math.min(#parent_arr, idx + (delta or 0)))
  if j == idx then return end
  local s = table.remove(parent_arr, idx)
  table.insert(parent_arr, j, s)
  profile.updated_at = schema.now_ms()
end

arbor.events.on("source-export:add_step", function(ctx)
  apply_pending_edits(ctx)
  local profile = pcfg.find(modal.state.selected_profile_id)
  if not profile then return end

  local op   = ops.get(ctx.kind)
  local step = schema.new_step(ctx.kind, op and op.label or ctx.kind)

  -- ── Route 1 — palette click while a branch is selected: append into
  -- that branch's `steps` (replaces the legacy "always-add-to-stage"
  -- path so the user can populate if/elif/else bodies via the palette).
  local target_arr
  if modal.state.selected_branch_id and modal.state.selected_branch_id ~= "" then
    target_arr = schema.find_branch_steps(profile, modal.state.selected_branch_id)
  end
  if target_arr then
    target_arr[#target_arr + 1] = step
    profile.updated_at = schema.now_ms()
    pcfg.upsert(profile)
    modal.state.selected_step_id = step.id
    modal.state.active_tab       = "rules"
    modal.refresh()
    return
  end

  -- ── Route 2 — legacy path: append to the selected stage (or last stage
  -- as a sensible fallback; create a stage if the profile is empty).
  local stage_id = ctx.stage_id or modal.state.selected_stage_id or ""
  if stage_id == "" or not schema.find_stage(profile, stage_id) then
    if not profile.stages or #profile.stages == 0 then
      local first = schema.new_stage("Gruppo 1")
      schema.add_stage(profile, first)
      stage_id = first.id
    else
      stage_id = profile.stages[#profile.stages].id
    end
  end
  schema.add_step(profile, stage_id, step)
  pcfg.upsert(profile)

  modal.state.selected_stage_id = stage_id
  modal.state.selected_step_id  = step.id
  modal.state.active_tab        = "rules"
  modal.refresh()
end)

arbor.events.on("source-export:select_step", function(ctx)
  apply_pending_edits(ctx)
  modal.state.selected_stage_id = ctx.stage_id or modal.state.selected_stage_id
  modal.state.selected_step_id  = ctx.step_id  or ""
  -- A direct step selection clears the branch target so the next palette
  -- click goes back to the stage. The user re-picks a branch by clicking
  -- its header.
  modal.state.selected_branch_id = ""
  modal.refresh()
end)

arbor.events.on("source-export:remove_step", function(ctx)
  apply_pending_edits(ctx)
  local profile = pcfg.find(modal.state.selected_profile_id)
  if profile then
    local _step, parent_arr, idx = schema.find_step_anywhere(profile, ctx.step_id or "")
    if parent_arr and idx then
      table.remove(parent_arr, idx)
      profile.updated_at = schema.now_ms()
      pcfg.upsert(profile)
    end
  end
  if modal.state.selected_step_id == ctx.step_id then
    modal.state.selected_step_id = ""
  end
  modal.refresh()
end)

arbor.events.on("source-export:duplicate_step", function(ctx)
  apply_pending_edits(ctx)
  local profile = pcfg.find(modal.state.selected_profile_id)
  if not profile then return end
  local src, parent_arr, idx = schema.find_step_anywhere(profile, ctx.step_id or "")
  if not src or not parent_arr then return end
  local copy = schema.clone(src)
  if not copy then return end
  copy.id   = schema.new_id("stp")
  copy.name = (copy.name or "step") .. " (copy)"
  table.insert(parent_arr, idx + 1, copy)
  profile.updated_at = schema.now_ms()
  pcfg.upsert(profile)
  modal.state.selected_step_id = copy.id
  modal.refresh()
end)

arbor.events.on("source-export:move_step_up", function(ctx)
  apply_pending_edits(ctx)
  local profile = pcfg.find(modal.state.selected_profile_id)
  if profile then
    move_step_in_place(profile, ctx.step_id or "", -1)
    pcfg.upsert(profile)
  end
  modal.refresh()
end)

arbor.events.on("source-export:move_step_down", function(ctx)
  apply_pending_edits(ctx)
  local profile = pcfg.find(modal.state.selected_profile_id)
  if profile then
    move_step_in_place(profile, ctx.step_id or "", 1)
    pcfg.upsert(profile)
  end
  modal.refresh()
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- If-block branch actions (visual editor — added 2026-05-09)
-- ─────────────────────────────────────────────────────────────────────────────

arbor.events.on("source-export:select_branch", function(ctx)
  apply_pending_edits(ctx)
  modal.state.selected_branch_id = ctx.branch_id or ""
  -- Clear the step selection so the detail panel doesn't render a stale step
  -- form while the user is targeting a branch for new ops.
  modal.state.selected_step_id   = ""
  modal.refresh()
end)

arbor.events.on("source-export:toggle_branch", function(ctx)
  local id = ctx.branch_id or ""
  if id == "" then return end
  modal.state.collapsed_branches = modal.state.collapsed_branches or {}
  modal.state.collapsed_branches[id] = not modal.state.collapsed_branches[id] and true or nil
  modal.refresh()
end)

arbor.events.on("source-export:add_elif_branch", function(ctx)
  apply_pending_edits(ctx)
  local profile = pcfg.find(modal.state.selected_profile_id)
  if not profile then return end
  local new_id = schema.add_branch(profile, ctx.step_id or "", false)
  if new_id then
    pcfg.upsert(profile)
    modal.state.selected_branch_id = new_id
    modal.state.selected_step_id   = ""
  end
  modal.refresh()
end)

arbor.events.on("source-export:add_else_branch", function(ctx)
  apply_pending_edits(ctx)
  local profile = pcfg.find(modal.state.selected_profile_id)
  if not profile then return end
  local new_id = schema.add_branch(profile, ctx.step_id or "", true)
  if new_id then
    pcfg.upsert(profile)
    modal.state.selected_branch_id = new_id
    modal.state.selected_step_id   = ""
  end
  modal.refresh()
end)

arbor.events.on("source-export:remove_branch", function(ctx)
  apply_pending_edits(ctx)
  local profile = pcfg.find(modal.state.selected_profile_id)
  if not profile then return end
  schema.remove_branch(profile, ctx.branch_id or "")
  pcfg.upsert(profile)
  if modal.state.selected_branch_id == ctx.branch_id then
    modal.state.selected_branch_id = ""
  end
  modal.refresh()
end)

arbor.events.on("source-export:update_branch_expression", function(ctx)
  apply_pending_edits(ctx)
  local profile = pcfg.find(modal.state.selected_profile_id)
  if not profile then return end
  schema.update_branch_expression(profile, ctx.branch_id or "", ctx.expr or "")
  pcfg.upsert(profile)
  -- No refresh needed — the expression buffer in the editor already echoes
  -- the new value. A full refresh while typing causes input focus loss; let
  -- the user trigger one via another action when needed.
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Palette actions
-- ─────────────────────────────────────────────────────────────────────────────

arbor.events.on("source-export:palette_clear", function(_ctx)
  modal.state.palette_query = ""
  modal.refresh()
end)

-- Emitted by PluginPipelineEditor on search input blur/enter. Value may be
-- empty; we store the query so the plugin can re-emit the editor with the
-- same filter without the component having to persist it itself.
arbor.events.on("source-export:palette_search", function(ctx)
  modal.state.palette_query = ctx.value or ""
  -- No need to rebuild the full modal for search-only changes: the editor
  -- filters client-side. We still save the query so an unrelated action
  -- (e.g. add_step) triggers a rebuild with the same filter preserved.
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Sequences — run / manage actions (sidebar is the entry point)
-- ─────────────────────────────────────────────────────────────────────────────

-- Open the run-history as a proper modal — the sidebar is for definitions,
-- the modal is for logs / runs. Keeping them separate lets the sidebar stay
-- compact and the history get proper breathing room.
arbor.events.on("source-export:seq_history_open", function(_ctx)
  seq_history_modal.open()
end)

-- Sidebar invokes actions with ctx.id (sequence id). Modal invokes with
-- ctx.sequence_id or uses its state.selected_sequence_id.
local function resolve_seq_id(ctx)
  local id = (ctx and (ctx.id or ctx.sequence_id)) or ""
  if id == "" then id = seq_modal.state.selected_sequence_id or "" end
  return id
end

arbor.events.on("source-export:seq_run", function(ctx)
  local id  = resolve_seq_id(ctx)
  local seq = seq_store.find(id)
  if not seq then
    arbor.notify{ message = "Select a sequence first", level = "warning" }
    return
  end
  local ok, err_or_sr_id = seq_runner.start(seq)
  if not ok then
    arbor.notify{ title = "Sequence failed to start", message = err_or_sr_id, level = "error" }
    return
  end
  -- Open the history modal so the user can watch progress live. The sidebar
  -- is still the entry point; the modal is the dashboard for ONE active run.
  seq_history_modal.open()
end)

arbor.events.on("source-export:seq_edit", function(ctx)
  local id = (ctx and ctx.id) or ""
  arbor.log.info("seq_edit fired (id='" .. id .. "')")
  -- pcall so a build_body error surfaces in the plugin console instead of
  -- silently failing inside the hook dispatcher (which only logs to the
  -- Rust tracing layer the user never sees).
  local ok, err = pcall(function() seq_modal.open(id) end)
  if not ok then
    arbor.log.error("seq_modal.open failed: " .. tostring(err))
  end
end)

arbor.events.on("source-export:seq_new", function(_ctx)
  local s = seq_schema.new_sequence("New Sequence")
  seq_store.upsert(s)
  seq_sidebar.refresh()
  seq_modal.open(s.id)
end)

arbor.events.on("source-export:seq_duplicate", function(ctx)
  local id = (ctx and ctx.id) or ""
  local copy = seq_store.duplicate(id)
  if copy then
    seq_sidebar.refresh()
    arbor.notify{ message = "Sequence duplicated", level = "success" }
  end
end)

arbor.events.on("source-export:seq_delete", function(ctx)
  local id = (ctx and ctx.id) or ""
  if id == "" then return end
  seq_store.remove(id)
  seq_sidebar.refresh()
  arbor.notify{ message = "Sequence deleted", level = "info" }
end)

-- ── History actions (fired from the sidebar) ────────────────────────────────

arbor.events.on("source-export:seq_run_cancel", function(ctx)
  local sr_id = (ctx and ctx.id) or ""
  if sr_id == "" then return end
  seq_runner.cancel(sr_id)
  seq_sidebar.refresh()
  -- Best-effort: if the history modal is open, repaint it. Silent when
  -- closed — form.replace just emits an event the frontend ignores.
  pcall(function() seq_history_modal.refresh() end)
end)

arbor.events.on("source-export:seq_run_discard", function(ctx)
  local sr_id = (ctx and ctx.id) or ""
  if sr_id == "" then return end
  seq_store.remove_run(sr_id)
  seq_sidebar.refresh()
  pcall(function() seq_history_modal.refresh() end)
end)

arbor.events.on("source-export:seq_history_clear", function(_ctx)
  seq_store.clear_runs()
  seq_sidebar.refresh()
  pcall(function() seq_history_modal.refresh() end)
end)

-- ── History navigation / output folder helpers ──────────────────────────────
--
-- Three tiny routers over arbor.ui.* convenience APIs. The history modal
-- renders one button per affordance; a dedicated action keeps all the "open
-- something in the OS" logic on the plugin side and lets us swap the
-- underlying API without touching the modal layout.

arbor.events.on("source-export:seq_nav_run", function(ctx)
  local rid = (ctx and ctx.run_id) or ""
  if rid == "" then
    arbor.notify{ message = "No pipeline run for this item yet", level = "warning" }
    return
  end
  pcall(function() arbor.ui.show_pipeline_run(rid) end)
end)

arbor.events.on("source-export:seq_open_output", function(ctx)
  local path = (ctx and ctx.path) or ""
  if path == "" then return end
  local ok, err = pcall(function() arbor.ui.open_path(path) end)
  if not ok then
    arbor.notify{ title = "Open failed", message = tostring(err), level = "error" }
  end
end)

-- Note: copy-to-clipboard for the output path lives on the form-DSL side
-- now via the `copy_link` widget (native clipboard call, no plugin hop).

-- ─────────────────────────────────────────────────────────────────────────────
-- Sequence modal — apply pending edits before mutating
-- ─────────────────────────────────────────────────────────────────────────────

local function apply_pending_seq_edits(ctx)
  local sel_id = seq_modal.state.selected_sequence_id
  if sel_id == "" then return end
  local sequence = seq_store.find(sel_id)
  if not sequence then return end

  if ctx.seq_name ~= nil           then sequence.name        = ctx.seq_name end
  if ctx.seq_description ~= nil    then sequence.description = ctx.seq_description end
  if ctx.seq_fail_fast ~= nil      then sequence.fail_fast   = ctx.seq_fail_fast and true or false end
  if ctx.seq_output_root ~= nil    then sequence.output_root = ctx.seq_output_root end

  -- kv_list on the wire is Record<string,string> (the form DSL canonical
  -- shape) — iterate via `pairs`, not `ipairs`. Guard kept: the field echoes
  -- empty `{}` in several edge cases (right after a set_values push, before
  -- the user types anything) and we don't want a spurious echo to wipe the
  -- matrix. On-disk stays an ordered array (ipairs compat in variables.lua).
  local function kv_from_ctx_record(obj)
    if type(obj) ~= "table" then return nil end
    local has_real, out = false, {}
    for k, v in pairs(obj) do
      local kk = tostring(k or ""):gsub("^%s+", ""):gsub("%s+$", "")
      if kk ~= "" then
        has_real = true
        out[#out+1] = { key = kk, value = tostring(v or "") }
      end
    end
    if not has_real then return nil end
    return out
  end

  local sv = kv_from_ctx_record(ctx.seq_vars)
  if sv then sequence.variables = sv end

  -- Per-item fields: item_enabled_<id>, item_allow_fail_<id>, item_vars_<id>
  for _, it in ipairs(sequence.items or {}) do
    local ekey = "item_enabled_" .. it.id
    if ctx[ekey] ~= nil then it.enabled = ctx[ekey] and true or false end
    local akey = "item_allow_fail_" .. it.id
    if ctx[akey] ~= nil then it.allow_failure = ctx[akey] and true or false end
    local vkey = "item_vars_" .. it.id
    local iv = kv_from_ctx_record(ctx[vkey])
    if iv then it.variables = iv end
  end

  if ctx.sel_sequence and ctx.sel_sequence ~= "" then
    seq_modal.state.selected_sequence_id = ctx.sel_sequence
  end
  if ctx.sel_item then
    -- Allow empty string to clear selection (e.g. on switching sequence).
    seq_modal.state.selected_item_id = ctx.sel_item
  end
  if ctx.active_tab and ctx.active_tab ~= "" then
    seq_modal.state.active_tab = ctx.active_tab
  end

  seq_store.upsert(sequence)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Sequence modal actions
-- ─────────────────────────────────────────────────────────────────────────────

arbor.events.on("source-export:seq_save_all", function(ctx)
  apply_pending_seq_edits(ctx)
  seq_sidebar.refresh()
  arbor.notify{ message = "Sequences saved ✓", level = "success" }
end)

arbor.events.on("source-export:seq_cancel", function(_ctx) end)
arbor.events.on("source-export:seq_noop",   function(_ctx) end)

arbor.events.on("source-export:seq_select", function(ctx)
  apply_pending_seq_edits(ctx)
  seq_modal.state.selected_sequence_id = ctx.sel_sequence or ""
  seq_modal.state.selected_item_id     = ""
  seq_modal.refresh()
end)

arbor.events.on("source-export:seq_new_in_modal", function(ctx)
  apply_pending_seq_edits(ctx)
  local s = seq_schema.new_sequence("New Sequence")
  seq_store.upsert(s)
  seq_modal.state.selected_sequence_id = s.id
  seq_sidebar.refresh()
  seq_modal.refresh()
end)

arbor.events.on("source-export:seq_duplicate_in_modal", function(ctx)
  apply_pending_seq_edits(ctx)
  local id = ctx.sequence_id or seq_modal.state.selected_sequence_id
  local copy = seq_store.duplicate(id)
  if copy then
    seq_modal.state.selected_sequence_id = copy.id
    seq_sidebar.refresh()
    seq_modal.refresh()
    arbor.notify{ message = "Sequence duplicated", level = "success" }
  end
end)

arbor.events.on("source-export:seq_delete_in_modal", function(ctx)
  apply_pending_seq_edits(ctx)
  local id = ctx.sequence_id or seq_modal.state.selected_sequence_id
  if id == "" then return end
  seq_store.remove(id)
  local list = seq_store.load()
  seq_modal.state.selected_sequence_id = list[1] and list[1].id or ""
  seq_sidebar.refresh()
  seq_modal.refresh()
  arbor.notify{ message = "Sequence deleted", level = "info" }
end)

-- ── Item-level mutations ───────────────────────────────────────────────────

-- Append an item to the currently-selected sequence. Fired from the palette
-- column: every profile button carries `extra = {repo_id, profile_id, repo_path}`
-- so the handler doesn't need a separate UI state channel.
--
-- Steps:
--   1. apply_pending_seq_edits — don't lose the user's in-flight edits to
--      the current sequence / selected item when we rebuild.
--   2. resolve repo metadata (falling back to the embedded path if the
--      workspace registry dropped the repo between modal open and click).
--   3. load the target profile ON-DISK so the cached name is fresh.
--   4. append + refresh + auto-select the newly-added item.
arbor.events.on("source-export:seq_palette_add", function(ctx)
  apply_pending_seq_edits(ctx)

  local repo_id    = ctx.repo_id    or ""
  local profile_id = ctx.profile_id or ""
  local repo_path  = ctx.repo_path  or ""
  if repo_id == "" or profile_id == "" or repo_path == "" then return end

  local repos = arbor.workspace.list_repos() or {}
  local repo_entry
  for _, r in ipairs(repos) do
    if r.id == repo_id then repo_entry = r; break end
  end
  if not repo_entry then
    repo_entry = { id = repo_id, path = repo_path, display_name = repo_path }
  end

  local profile
  local remote = require("remote_profiles")
  for _, p in ipairs(remote.load_profiles(repo_entry.path)) do
    if p.id == profile_id then profile = p; break end
  end
  if not profile then
    arbor.notify{ message = "Profile no longer exists in target repo", level = "warning" }
    return
  end

  local target_seq_id = seq_modal.state.selected_sequence_id
  local sequence = seq_store.find(target_seq_id)
  if not sequence then
    arbor.notify{ message = "Select a sequence first", level = "warning" }
    return
  end

  local item = seq_schema.new_item(repo_entry, profile)
  seq_schema.add_item(sequence, item)
  seq_store.upsert(sequence)

  -- Auto-focus the new row so the detail column lights up immediately —
  -- the user's flow is "add → edit" and a blank detail panel after add
  -- would be a dead-end.
  seq_modal.state.selected_item_id = item.id

  seq_modal.refresh()
  seq_sidebar.refresh()
end)

-- Tree node click in the Items tab middle column.
arbor.events.on("source-export:seq_item_select", function(ctx)
  apply_pending_seq_edits(ctx)
  local v = ctx.value or ""
  if v == "__none__" then v = "" end
  seq_modal.state.selected_item_id = v
  seq_modal.refresh()
end)

arbor.events.on("source-export:seq_item_remove", function(ctx)
  apply_pending_seq_edits(ctx)
  local item_id = ctx.item_id or ""
  if item_id == "" then return end
  local sequence = seq_store.find(seq_modal.state.selected_sequence_id)
  if not sequence then return end
  seq_schema.remove_item(sequence, item_id)
  seq_store.upsert(sequence)
  -- Clear the detail-column selection if it pointed at the removed row,
  -- otherwise the detail panel would render stale metadata until the user
  -- clicks elsewhere.
  if seq_modal.state.selected_item_id == item_id then
    seq_modal.state.selected_item_id = ""
  end
  seq_modal.refresh()
  seq_sidebar.refresh()
end)

arbor.events.on("source-export:seq_item_move_up", function(ctx)
  apply_pending_seq_edits(ctx)
  local sequence = seq_store.find(seq_modal.state.selected_sequence_id)
  if not sequence then return end
  seq_schema.move_item(sequence, ctx.item_id, -1)
  seq_store.upsert(sequence)
  seq_modal.refresh()
end)

arbor.events.on("source-export:seq_item_move_down", function(ctx)
  apply_pending_seq_edits(ctx)
  local sequence = seq_store.find(seq_modal.state.selected_sequence_id)
  if not sequence then return end
  seq_schema.move_item(sequence, ctx.item_id, 1)
  seq_store.upsert(sequence)
  seq_modal.refresh()
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Settings modal (global)
-- ─────────────────────────────────────────────────────────────────────────────

-- Panel on_load — fires every time the settings modal opens. Re-contributes
-- categories + sections with fresh state (templates list especially).
arbor.events.on("source-export:settings_refresh",          function(_ctx) settings_ui.refresh() end)
arbor.events.on("source-export:settings_save",             function(ctx) settings_ui.handle_save(ctx) end)
arbor.events.on("source-export:settings_cancel",           function(_ctx) end)
arbor.events.on("source-export:settings_noop",             function(_ctx) end)
arbor.events.on("source-export:settings_delete_template",  function(ctx) settings_ui.handle_delete_template(ctx) end)
arbor.events.on("source-export:settings_rename_template",  function(ctx) settings_ui.handle_rename_template(ctx) end)
arbor.events.on("source-export:settings_rename_template_save",
  function(ctx) settings_ui.handle_rename_template_save(ctx) end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Run history (stubs — Phase 2 wires these to arbor.pipeline)
-- ─────────────────────────────────────────────────────────────────────────────

arbor.events.on("source-export:open_run_log", function(_ctx)
  arbor.notify{ message = "Run log viewer arriverà in Fase 2", level = "info" }
end)

arbor.events.on("source-export:resume_run", function(ctx)
  local rid = ctx.run_id or ""
  if rid == "" then return end
  local ok, err = pcall(function() arbor.pipeline.resume(rid) end)
  if not ok then
    arbor.notify{ title = "Resume failed", message = tostring(err), level = "error" }
  end
end)

arbor.events.on("source-export:discard_run", function(ctx)
  local rid = ctx.run_id or ""
  if rid == "" then return end
  local ok, err = pcall(function() arbor.pipeline.discard(rid) end)
  if not ok then
    arbor.notify{ title = "Discard failed", message = tostring(err), level = "error" }
  end
end)

arbor.events.on("source-export:expand_all", function(_ctx)
  arbor.notify{ message = "(placeholder) Expand-all non ancora implementato", level = "info" }
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Pipeline hooks — refresh the open modal's Cronologia tab after every run
-- completes, and enforce the keep_last_n_runs cleanup policy.
-- ─────────────────────────────────────────────────────────────────────────────

local function is_our_plugin(ctx)
  return (ctx.plugin or "") == "source-export"
end

local function profile_id_from_pipeline_id(pid)
  -- see compile.lua: pipeline id is "profile:<profile_id>"
  return (pid or ""):match("^profile:(.+)$")
end

local function enforce_keep_last_n(pipeline_id)
  local keep = gcfg.get_keep_last_n()
  if keep <= 0 then return end   -- 0 = unlimited
  local ok, runs = pcall(function()
    return arbor.pipeline.list_runs({ pipeline_id = pipeline_id })
  end)
  if not ok or type(runs) ~= "table" then return end

  -- Separate terminal vs active (Running/Paused/Pending are not discardable).
  local terminal = {}
  for _, r in ipairs(runs) do
    if r.status == "success" or r.status == "failed" or r.status == "cancelled" then
      terminal[#terminal+1] = r
    end
  end
  -- Newest first by finished_at (fall back to started_at / 0).
  table.sort(terminal, function(a, b)
    return (a.finished_at or a.started_at or 0) > (b.finished_at or b.started_at or 0)
  end)
  for i = keep + 1, #terminal do
    pcall(function() arbor.pipeline.discard(terminal[i].id) end)
  end
end

arbor.events.on("on_pipeline_done", function(ctx)
  if not is_our_plugin(ctx) then return end
  enforce_keep_last_n(ctx.pipeline_id)
  -- Release libgit2 handles once more at the end: the UI may have touched
  -- them while the pipeline was running (status refresh, branch list, …),
  -- re-opening packfiles that would now keep OUTPUT_PATH files locked on
  -- Windows. Drop them so the user can move/delete the output folder
  -- freely from Explorer right after the run finishes.
  pcall(function() arbor.repo.release_handles() end)
  -- If the Edit Configurations modal is open on the profile that just ran,
  -- refresh it so the Cronologia tab picks up the new run.
  local pid = profile_id_from_pipeline_id(ctx.pipeline_id)
  if pid and modal.state.selected_profile_id == pid then
    modal.refresh()
  end
  -- Forward to the sequence runner: if this pipeline run is owned by a
  -- SequenceRun, the runner updates item status and advances to the next
  -- item. No-op when the run is a standalone profile execution.
  pcall(function()
    seq_runner.on_pipeline_done(ctx.run_id, ctx.status)
    seq_sidebar.refresh()
    seq_history_modal.refresh()
  end)
end)

arbor.events.on("on_pipeline_started", function(ctx)
  if not is_our_plugin(ctx) then return end
  local pid = profile_id_from_pipeline_id(ctx.pipeline_id)
  if pid and modal.state.selected_profile_id == pid then
    modal.refresh()
  end
  -- Mirror PIPELINE_DONE: if the started run is part of a sequence, its
  -- "running" state is already persisted by the runner (which set it before
  -- calling compile.run). We refresh the sidebar so the user sees the badge
  -- update as soon as the pipeline actually spawns.
  pcall(function()
    seq_sidebar.refresh()
    seq_history_modal.refresh()
  end)
end)
