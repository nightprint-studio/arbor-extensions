-- ui/modal.lua — Edit Configurations modal for Source Export.
--
-- Layout:
--   [tree_layout outer]
--     nav  = profile list + toolbar (+ − 📋)
--     body = tabs { Info | Regole | Cronologia } for the selected profile
--
-- The "Regole" tab is a 3-column row:
--   palette (searchable ops list)  |  stages+steps sequence  |  step detail form
--
-- Mutations happen via plugin actions; after each change we rebuild the form
-- payload and call arbor.ui.form.replace() to refresh without flicker.

local schema  = require("profile_schema")
local pcfg    = require("config.project")
local gcfg    = require("config.global")
local ops     = require("operations")
local compile = require("compile")

local M = {}

-- ─ format helpers ───────────────────────────────────────────────────────────

-- Coerce mlua's JSON-null userdata sentinel (and any non-number) to nil so
-- arithmetic and `or 0` fallbacks work. Required because pipeline runs come
-- back from Rust with `finished_at = null` while running, and serde maps
-- that to a userdata value (NOT Lua nil).
local function num_or_nil(v)
  if type(v) == "number" then return v end
  return nil
end

local function format_ts(ms)
  local n = num_or_nil(ms)
  if not n or n == 0 then return "—" end
  local secs = math.floor(n / 1000)
  return os.date("%Y-%m-%d %H:%M:%S", secs)
end

local function format_duration(started_at, finished_at)
  local s = num_or_nil(started_at)
  if not s or s == 0 then return "—" end
  local end_ms = num_or_nil(finished_at) or (os.time() * 1000)
  local ms = end_ms - s
  if ms < 0 then ms = 0 end
  if ms < 1000 then return tostring(ms) .. "ms" end
  local s = math.floor(ms / 1000)
  if s < 60 then return tostring(s) .. "s" end
  local m = math.floor(s / 60)
  return string.format("%dm %02ds", m, s % 60)
end

local function status_color(status)
  if status == "success" then return "accent" end
  if status == "running" then return "info"   end
  if status == "paused"  then return "warn"   end
  if status == "failed"  then return "danger" end
  return "neutral"
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Transient in-memory state (scoped to one open modal instance).
-- The form itself persists the profile list via pcfg/gcfg; these track the
-- user's current focus (which profile / stage / step is highlighted).
-- ─────────────────────────────────────────────────────────────────────────────

M.state = {
  selected_profile_id = "",
  selected_stage_id   = "",
  selected_step_id    = "",
  selected_branch_id  = "",        -- which if-block branch is the current
                                    -- "drop target" for new palette ops
  collapsed_branches  = {},         -- map<branch_id, true>: per-branch collapse state
  active_tab          = "info",    -- "info" | "rules" | "history"
  palette_query       = "",
}

local function reset_state()
  M.state = {
    selected_profile_id = "",
    selected_stage_id   = "",
    selected_step_id    = "",
    selected_branch_id  = "",
    collapsed_branches  = {},
    active_tab          = "info",
    palette_query       = "",
  }
end

-- Run history per profile, sourced from the pipeline registry. Each profile's
-- runs live under pipeline_id "profile:<profile_id>".
local function load_run_history(profile_id)
  if not profile_id or profile_id == "" then return {} end
  local ok, runs = pcall(function()
    return arbor.pipeline.list_runs({
      pipeline_id = compile.pipeline_id_for(profile_id),
    })
  end)
  if not ok or type(runs) ~= "table" then return {} end
  -- Newest first — list_runs returns insertion order (oldest first).
  table.sort(runs, function(a, b)
    return (num_or_nil(a.started_at) or 0) > (num_or_nil(b.started_at) or 0)
  end)
  return runs
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Small node helpers
-- ─────────────────────────────────────────────────────────────────────────────

local function label(text, variant)
  return { type = "paragraph", content = text, variant = variant or "muted" }
end

local function spacer_h(px)
  return { type = "container", style = "height:" .. tostring(px or 8) .. "px;", children = {} }
end

local function hline()
  return { type = "divider" }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Tab 1 — Info
-- ─────────────────────────────────────────────────────────────────────────────

local function build_info_tab(profile)
  -- Variables table uses kv_list. The form DSL stores kv_list as
  -- `Record<string,string>`, NOT an array of `{key,value}` pairs — using an
  -- array produces "[object Object]" rows because the frontend iterates via
  -- `Object.entries`. The on-disk format (profile.variables) stays an array
  -- for ordered ipairs compat; conversion happens at the UI boundary.
  local vars_default = {}
  for _, v in ipairs(profile.variables or {}) do
    if v.key and v.key ~= "" then
      vars_default[v.key] = v.value or ""
    end
  end

  -- Same Record<string,string> shape as Variables. Keys flatten to a single
  -- string per name (kv_list dedupe semantics) — fine for env vars.
  local env_default = {}
  for _, e in ipairs(profile.env or {}) do
    if e.key and e.key ~= "" then
      env_default[e.key] = e.value or ""
    end
  end

  -- Gather branches + tags of the active repo so the source picker has a
  -- real list. Best-effort: any failure (e.g. no repo open) falls back to a
  -- free-text entry.
  local src_options = {}
  local ok_b, branches = pcall(arbor.repo.branches)
  if ok_b and type(branches) == "table" then
    for _, b in ipairs(branches) do
      if b and b.name then
        src_options[#src_options+1] = {
          value = b.name,
          label = b.is_remote and ("⇡ " .. b.name) or b.name,
        }
      end
    end
  end
  local ok_t, tags = pcall(arbor.repo.tags)
  if ok_t and type(tags) == "table" then
    for _, t in ipairs(tags) do
      if t and t.name then
        src_options[#src_options+1] = { value = t.name, label = "⚑ " .. t.name }
      end
    end
  end

  return {
    { type = "section", title = "Profile", card = true, children = {
      { type = "text",     name = "info_name",        label = "Name",
        default = profile.name or "", placeholder = "BancaRoma Core" },
      { type = "textarea", name = "info_description", label = "Description",
        default = profile.description or "", rows = 2 },
    }},

    { type = "section", title = "Source / Target", card = true, children = {
      -- Autocomplete with repo branches + tags. `free_form = true` keeps it
      -- usable when the active repo is offline or the name isn't in the list.
      { type = "autocomplete",
        id           = "branch_src_picker",
        name         = "info_branch_src",
        label        = "Source branch / tag (vuoto = HEAD corrente)",
        default      = profile.branch_src or "",
        placeholder  = "main / v1.2.3 / origin/develop",
        options      = src_options,
        free_form    = true },
      { type = "checkbox", name = "info_auto_clone",
        label   = "Clone automatico del sorgente in $OUTPUT_PATH prima del primo step (consigliato)",
        default = (profile.auto_clone ~= false) },
      { type = "text", name = "info_branch_dest", label = "Destination branch (opzionale)",
        default = profile.branch_dest or "", placeholder = "client/bancaroma-main" },
      { type = "text", name = "info_remote_url",  label = "Destination remote URL (opzionale)",
        default = profile.remote_url or "",
        placeholder = "git@clientgit.com:bancaroma/core.git" },
      label("Destination fields are placeholders for Git Push steps. Leaving them empty means the export stops at the local filesystem."),
    }},

    { type = "section", title = "Logging", card = true, children = {
      { type = "select", name = "info_log_level", label = "Log level",
        default = profile.log_level or "info",
        options = {
          { value = "debug", label = "Debug (verbose)" },
          { value = "info",  label = "Info (default)"  },
          { value = "warn",  label = "Warning"         },
          { value = "error", label = "Error only"      },
        } },
      label("The pipeline runtime auto-logs start/end of pipeline, stages and steps, plus parameter resolution at DEBUG level."),
    }},

    { type = "section", title = "Variables", card = true, children = {
      { type = "kv_list", name = "info_variables",
        key_label = "Name", value_label = "Value",
        key_placeholder = "DB_HOST", value_placeholder = "prod",
        default = vars_default },
      label("Usable anywhere as $NAME or ${NAME}. Built-ins ($SOURCE_PATH, $OUTPUT_PATH, $PROFILE, $BRANCH_SRC, …) are always available and override these on name collision."),
    }},

    { type = "section", title = "Environment", card = true, children = {
      { type = "kv_list", name = "info_env",
        key_label = "Variable", value_label = "Value",
        key_placeholder = "JAVA_HOME", value_placeholder = "${env:JAVA_HOME_11}",
        default = env_default },
      label("Process env overrides applied to every shell_command step (auto-clone is excluded). Values support $NAME (profile vars) and ${env:NAME} (system env). Use them to pin JAVA_HOME, prepend to PATH, inject GH_TOKEN, etc."),
    }},
  }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Tab 2 — Regole export (delegates to the dedicated Svelte component)
-- ─────────────────────────────────────────────────────────────────────────────
--
-- We now emit a single `pipeline_editor` node and let
-- `PluginPipelineEditor.svelte` own the layout/interaction. The lua side is
-- responsible only for:
--   · grouping the op catalog into palette-ready categories
--   · computing the detail-form for the currently selected step (using the
--     existing `op.form(step)` schema from operations.lua)
--   · wiring plugin actions

-- Stage settings, rendered in the detail panel when a stage is selected but
-- no step is. Replaces the old modal-inside-modal flow that was closing the
-- main Configurations modal on open.
local function build_stage_detail_form(profile, selected_stage_id)
  if not selected_stage_id or selected_stage_id == "" then return nil end
  local stage = schema.find_stage(profile, selected_stage_id)
  if not stage then return nil end

  return {
    { type = "section", card = true, title = "Gruppo  ·  " .. (stage.name or stage.id),
      children = {
        { type = "text", name = "stage_name_" .. stage.id, label = "Nome gruppo",
          default = stage.name or "" },
        { type = "select", name = "stage_mode_" .. stage.id, label = "Modalità esecuzione",
          default = stage.mode or "sequential",
          options = {
            { value = "sequential", label = "Sequential — step uno dopo l'altro" },
            { value = "parallel",   label = "Parallel — step concorrenti" },
          } },
        { type = "number", name = "stage_max_parallel_" .. stage.id,
          label = "Max parallel (0 = unlimited, solo se mode = parallel)",
          default = stage.max_parallel or 0, min = 0, max = 32 },
      } },
    { type = "section", card = true, title = "Azioni",
      children = {
        { type = "paragraph", variant = "muted",
          content = "Tip: clic su uno step per editarne i parametri." },
      } },
  }
end

local function build_step_detail_form(profile, selected_stage_id, selected_step_id)
  if not selected_step_id or selected_step_id == "" then return nil end
  local step, _, stage = schema.find_step(profile, selected_stage_id, selected_step_id)
  if not step then return nil end
  local op = ops.get(step.kind) or {}
  local form_fields = op.form and op.form(step) or {
    label("Op kind '" .. step.kind .. "' non registrata.", "muted")
  }
  -- Prefix each param field name with the step id so we can parse them back
  -- on save (and so switching selection doesn't leak values).
  for _, f in ipairs(form_fields) do
    if f.name then f.name = "param_" .. step.id .. "_" .. f.name end
  end

  -- Break the form into the standard "card" sections used across Arbor:
  --   · General → step name + allow_failure
  --   · Parametri → the op's own form fields
  local params_children = {}
  if op.summary and op.summary ~= "" then
    params_children[#params_children+1] = {
      type = "paragraph", variant = "muted", content = op.summary,
    }
  end
  for _, f in ipairs(form_fields) do params_children[#params_children+1] = f end

  return {
    { type = "section", card = true,
      title = (op.label or step.kind) .. "  ·  " .. (stage.name or stage.id),
      children = {
        { type = "text", name = "step_name_" .. step.id, label = "Nome step",
          default = step.name or "" },
        { type = "checkbox", name = "step_allow_fail_" .. step.id,
          label = "Allow failure (continue stage on non-zero exit)",
          default = step.allow_failure and true or false },
      } },
    { type = "section", card = true, title = "Parametri",
      children = params_children },
  }
end

local function build_operations_catalog(query)
  -- The editor does its own client-side filtering, so we ship the full catalog
  -- grouped by display-order category on every refresh.
  local cats = {}
  for _, cat in ipairs(ops.categories) do
    local bucket = { id = cat.id, label = cat.label, ops = {} }
    local sorted_names = {}
    for kind, _ in pairs(ops.ops) do sorted_names[#sorted_names+1] = kind end
    table.sort(sorted_names)
    for _, kind in ipairs(sorted_names) do
      local op = ops.ops[kind]
      if op.category == cat.id then
        bucket.ops[#bucket.ops+1] = {
          kind     = kind,
          label    = op.label,
          icon     = op.icon,
          summary  = op.summary,
          category = op.category,   -- drives the subtle icon colour in the editor
        }
      end
    end
    if #bucket.ops > 0 then cats[#cats+1] = bucket end
  end
  return cats
end

-- Recursively rewrite an `if_block` step into the editor-friendly shape with
-- `branches` / `else_branch` synthesized from `params.branches` /
-- `params.else_steps`. Other step kinds are passed through. The shape we
-- emit matches `Step` / `Branch` types in PluginPipelineEditor.svelte.
local function enrich_step(step, state)
  local out = {
    id            = step.id,
    name          = step.name,
    kind          = step.kind,
    allow_failure = step.allow_failure,
  }
  if step.kind == "if_block" then
    out.has_body = true
    -- One-line summary on the parent row: count how many rami so the user
    -- doesn't have to expand to see the shape.
    local b_count = step.params and #(step.params.branches or {}) or 0
    local has_else = step.params and step.params.else_steps and #step.params.else_steps > 0
    out.summary = "(" .. b_count .. " " .. (b_count == 1 and "ramo" or "rami")
                  .. (has_else and " + else" or "") .. ")"

    out.branches = {}
    for i, br in ipairs(step.params and step.params.branches or {}) do
      local branch_id = step.id .. "/" .. tostring(i - 1)
      local sub = {
        id         = branch_id,
        label      = (i == 1) and "if" or ("elif #" .. tostring(i - 1)),
        expression = br.expression or "",
        collapsed  = state.collapsed_branches[branch_id] or false,
        steps      = {},
      }
      for _, child in ipairs(br.steps or {}) do
        sub.steps[#sub.steps + 1] = enrich_step(child, state)
      end
      out.branches[#out.branches + 1] = sub
    end

    if has_else then
      local branch_id = step.id .. "/else"
      local sub = {
        id        = branch_id,
        label     = "else",
        collapsed = state.collapsed_branches[branch_id] or false,
        steps     = {},
      }
      for _, child in ipairs(step.params.else_steps or {}) do
        sub.steps[#sub.steps + 1] = enrich_step(child, state)
      end
      out.else_branch = sub
    end
  end
  return out
end

local function enrich_stages(stages, state)
  local out = {}
  for _, stage in ipairs(stages or {}) do
    local s = {
      id           = stage.id,
      name         = stage.name,
      mode         = stage.mode,
      max_parallel = stage.max_parallel,
      steps        = {},
    }
    for _, step in ipairs(stage.steps or {}) do
      s.steps[#s.steps + 1] = enrich_step(step, state)
    end
    out[#out + 1] = s
  end
  return out
end

local function build_rules_tab(profile, query, selected_stage_id, selected_step_id)
  return {
    { id     = "se_pipeline_editor",
      type   = "pipeline_editor",
      stages = enrich_stages(profile.stages or {}, M.state),
      operations         = build_operations_catalog(query),
      search_query       = query or "",
      selected_step_id   = selected_step_id   or "",
      selected_stage_id  = selected_stage_id  or "",
      selected_branch_id = M.state.selected_branch_id or "",
      step_detail_form = build_step_detail_form(profile, selected_stage_id, selected_step_id)
                         or build_stage_detail_form(profile, selected_stage_id),
      empty_label      = "Seleziona un gruppo o uno step per modificarne i parametri.",
      -- Stretch vertically: the tabpanel gives us all the available height,
      -- the editor and its three columns handle scroll internally.
      style  = "flex: 1 1 auto; min-height: 0;",
      actions = {
        add_stage       = "source-export:add_stage",
        add_step        = "source-export:add_step",
        select_step     = "source-export:select_step",
        select_stage    = "source-export:select_stage",
        remove_step     = "source-export:remove_step",
        duplicate_step  = "source-export:duplicate_step",
        move_step_up    = "source-export:move_step_up",
        move_step_down  = "source-export:move_step_down",
        remove_stage    = "source-export:remove_stage",
        move_stage_up   = "source-export:move_stage_up",
        move_stage_down = "source-export:move_stage_down",
        edit_stage      = "source-export:edit_stage",
        export_stage    = "source-export:export_stage",
        import_stage    = "source-export:import_stage",
        search_changed  = "source-export:palette_search",
        -- if-block branch actions (new, 2026-05-09)
        select_branch            = "source-export:select_branch",
        toggle_branch            = "source-export:toggle_branch",
        add_elif_branch          = "source-export:add_elif_branch",
        add_else_branch          = "source-export:add_else_branch",
        remove_branch            = "source-export:remove_branch",
        update_branch_expression = "source-export:update_branch_expression",
      },
    },
  }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Tab 3 — Cronologia
-- ─────────────────────────────────────────────────────────────────────────────

local function build_history_tab(profile)
  local runs = load_run_history(profile.id)
  if #runs == 0 then
    return {
      { type = "section", title = "Cronologia", card = true, children = {
        label("Nessuna run registrata per questo profilo.", "muted"),
        spacer_h(8),
        label("Le run compariranno qui automaticamente dopo il primo Esegui. Ogni run è persistita su disco in ~/.config/arbor/pipeline_runs/ e sopravvive ai restart."),
      }},
    }
  end

  local rows = {}
  for _, r in ipairs(runs) do
    local resumable = (r.status == "failed" or r.status == "paused")
    rows[#rows+1] = {
      type  = "card_row",
      label = format_ts(r.started_at),
      description = (r.status or "?"):upper()
        .. "  ·  " .. format_duration(r.started_at, r.finished_at)
        .. "  ·  " .. (r.id or "—"),
      children = {
        { type = "paragraph", variant = "muted",
          content = r.log_level and ("log: " .. r.log_level) or "" },
        { type = "button", variant = "default", label = "Open log",
          icon = "Eye",
          action = "source-export:open_run_log",
          extra  = { run_id = r.id } },
        { type = "button", variant = "primary", label = "Resume",
          icon = "Play",
          action  = "source-export:resume_run",
          extra   = { run_id = r.id },
          disabled = (not resumable) },
        { type = "button", variant = "danger", label = "Discard",
          icon = "Trash2",
          action = "source-export:discard_run",
          extra  = { run_id = r.id } },
      }}
  end
  return {
    { type = "section", title = "Cronologia (" .. #runs .. ")", card = true,
      count = #runs, children = rows },
  }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Outer modal
-- ─────────────────────────────────────────────────────────────────────────────

local function build_profile_tree(profiles, selected_id)
  local nodes = {}
  for _, p in ipairs(profiles) do
    nodes[#nodes+1] = {
      value = p.id, label = p.name or p.id, icon = "Share2",
    }
  end
  if #nodes == 0 then
    nodes[#nodes+1] = { value = "__none__", label = "(no profile yet)", icon = "CircleSlash" }
  end
  return {
    { value = "grp_profiles", label = "Profiles", group = true, children = nodes }
  }
end

local function build_body(profile_list, state)
  local sel_id = state.selected_profile_id
  local selected_profile

  if sel_id ~= "" then
    for _, p in ipairs(profile_list) do
      if p.id == sel_id then selected_profile = p; break end
    end
  end
  if not selected_profile then
    selected_profile = profile_list[1]
    if selected_profile then state.selected_profile_id = selected_profile.id end
  end

  local nav_toolbar = { type = "row", gap = 4, align = "center", children = {
    { type = "menu_button", icon = "Plus", icon_only = true, tooltip = "Nuovo profilo",
      variant = "ghost",
      options = {
        { heading = true, label = "Nuovo profilo" },
        { label = "Profilo vuoto", icon = "FilePlus2",
          action = "source-export:new_profile", extra = { template = "" } },
        { separator = true },
        { heading = true, label = "Da template" },
        -- Dynamic template list is appended below.
      } },
    { type = "button", icon = "Copy", icon_only = true, variant = "ghost",
      tooltip = "Duplica profilo",
      action = "source-export:duplicate_profile",
      extra  = { profile_id = sel_id } },
    { type = "button", icon = "Upload", icon_only = true, variant = "ghost",
      tooltip = "Import profile (JSON)",
      action = "source-export:import_profile" },
    { type = "button", icon = "Download", icon_only = true, variant = "ghost",
      tooltip = "Export profile (JSON)",
      action = "source-export:export_profile",
      extra  = { profile_id = sel_id } },
    { type = "button", icon = "Minus", icon_only = true, variant = "ghost",
      tooltip = "Elimina profilo",
      action = "source-export:delete_profile",
      extra  = { profile_id = sel_id } },
  }}

  -- Extend the "+ menu" with one entry per template.
  local tpl_list = gcfg.load_templates()
  for _, tpl in ipairs(tpl_list) do
    nav_toolbar.children[1].options[#nav_toolbar.children[1].options+1] = {
      label = tpl.name or tpl.id, icon = "FileText",
      action = "source-export:new_profile",
      extra  = { template = tpl.id },
    }
  end

  local nav_children = {
    nav_toolbar,
    { type = "tree", name = "sel_profile", default = state.selected_profile_id,
      expanded = true,
      -- Master/detail: selecting a different profile in the tree fires this
      -- action so the content column can rebuild with the new profile's data.
      -- Without it, the form just updates `sel_profile` internally and the
      -- Info/Regole/Cronologia tabs stay pinned on the previous profile.
      change_action = "source-export:select_profile",
      nodes = build_profile_tree(profile_list, state.selected_profile_id) },
  }

  local content_children
  if selected_profile then
    local active = state.active_tab or "info"
    -- Stable id required: without it `form.replace` assigns a fresh
    -- auto-id on each rebuild and the active-tab preservation (which is keyed
    -- by node.id) no longer matches → the tabs reset to the default on every
    -- mutation. The id must be identical across rebuilds.
    content_children = {
      { id = "se_tabs", type = "tabs", default_tab = active, tabs = {
        { id = "info", label = "Info", icon = "Info",
          children = build_info_tab(selected_profile) },
        { id = "rules", label = "Regole export", icon = "ListChecks",
          flush = true,    -- pipeline editor owns its own spacing edge-to-edge
          children = build_rules_tab(selected_profile,
            state.palette_query, state.selected_stage_id, state.selected_step_id) },
        { id = "history", label = "Cronologia", icon = "History",
          children = build_history_tab(selected_profile) },
      }},
    }
  else
    content_children = {
      { type = "alert", variant = "info",
        text = "Nessun profilo definito. Creane uno con il tasto + in alto a sinistra." }
    }
  end

  return {
    nodes = {
      { id = "se_root", type = "tree_layout",
        nav_width             = "240px",
        nav_collapsible       = true,
        nav_collapsed_default = false,
        nav_children          = nav_children,
        content_children      = content_children,
      }
    },
    state = {
      -- Track open ids so action handlers can diff against current form values.
      selected_profile_id = state.selected_profile_id,
      selected_stage_id   = state.selected_stage_id,
      selected_step_id    = state.selected_step_id,
      active_tab          = state.active_tab,
      palette_query       = state.palette_query or "",
    },
  }
end

local function refresh()
  local profiles = pcfg.load()
  local body = build_body(profiles, M.state)

  -- `form.replace` preserves existing field values whose `name` didn't change.
  -- That's the right default when only ONE profile is being edited, but when
  -- the user selects a DIFFERENT profile in the tree the Info tab fields
  -- (info_name, info_description, …) would otherwise keep showing the old
  -- profile's values because the names are the same. Explicitly push the
  -- selected profile's current values via set_values so the form matches.
  local sel_id = M.state.selected_profile_id
  local selected
  for _, p in ipairs(profiles) do
    if p.id == sel_id then selected = p; break end
  end

  local set = {
    sel_profile    = sel_id,
    palette_query  = M.state.palette_query or "",
  }
  if selected then
    set.info_name        = selected.name        or ""
    set.info_description = selected.description or ""
    set.info_branch_src  = selected.branch_src  or ""
    set.info_branch_dest = selected.branch_dest or ""
    set.info_remote_url  = selected.remote_url  or ""
    set.info_log_level   = selected.log_level   or "info"
    set.info_auto_clone  = (selected.auto_clone ~= false)
    -- Record<string,string> shape — see note in build_info_tab().
    local vars = {}
    for _, v in ipairs(selected.variables or {}) do
      if v.key and v.key ~= "" then vars[v.key] = v.value or "" end
    end
    set.info_variables = vars
    local env = {}
    for _, e in ipairs(selected.env or {}) do
      if e.key and e.key ~= "" then env[e.key] = e.value or "" end
    end
    set.info_env = env
  end

  arbor.ui.form.replace({
    nodes = body.nodes, state = body.state,
    set_values = set,
  })
end
M.refresh = refresh

function M.open(initial_profile_id)
  reset_state()
  local profiles = pcfg.load()
  if initial_profile_id and initial_profile_id ~= "" then
    M.state.selected_profile_id = initial_profile_id
  else
    M.state.selected_profile_id = profiles[1] and profiles[1].id or ""
  end
  local body = build_body(profiles, M.state)
  arbor.ui.form({
    title         = "Gestione profili di export",
    width         = "1280px",
    height        = "820px",
    submit_label  = "Save",
    submit_action = "source-export:save_all",
    cancel_label  = "Close",
    cancel_action = "source-export:cancel",
    state         = body.state,
    nodes         = body.nodes,
  })
end

return M
