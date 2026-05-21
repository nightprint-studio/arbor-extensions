-- config/run_global.lua — global run-config CRUD and settings form
-- Global run configs are shared across all repos.
-- Also owns the global "auto_stop_on_run" preference.

local M = {}

local RUN_LANGUAGES = {
  { value="maven",  label="Maven / Spring Boot" },
  { value="gradle", label="Gradle / Spring Boot" },
  { value="rust",   label="Rust (Cargo)"         },
  { value="npm",    label="npm / Yarn / pnpm"    },
  { value="tauri",  label="Tauri"                },
  { value="tomcat", label="Tomcat"               },
}

local function lang_label(lang)
  for _, l in ipairs(RUN_LANGUAGES) do
    if l.value == lang then return l.label end
  end
  return lang
end

-- ── Storage ───────────────────────────────────────────────────────────────────

function M.load()
  local raw = arbor.json.decode(arbor.settings.global.get("global_run_configs") or "[]")
  local cfgs = (raw and type(raw) == "table") and raw or {}

  -- One-shot migration: default `build_id = ""` to "__skip__" for every
  -- non-tomcat config (mirrors run_project.lua). Only Tomcat needs a
  -- separate build step.
  if arbor.settings.global.get("run_skip_build_migrated") ~= "1" then
    local changed = false
    for _, c in ipairs(cfgs) do
      local ct = c.config_type or ""
      if ct ~= "tomcat" and (c.build_id == nil or c.build_id == "") then
        c.build_id = "__skip__"
        changed = true
      end
    end
    arbor.settings.global.set("run_skip_build_migrated", "1")
    if changed then M.save(cfgs) end
  end

  return cfgs
end

function M.save(cfgs)
  local s = arbor.json.encode(cfgs)
  if s then arbor.settings.global.set("global_run_configs", s) end
end

function M.load_for_lang(lang)
  local all, out = M.load(), {}
  for _, c in ipairs(all) do
    if (c.lang or "") == lang then out[#out+1] = c end
  end
  return out
end

function M.find(id)
  for _, c in ipairs(M.load()) do
    if c.id == id then return c end
  end
  return nil
end

function M.load_default_profile(lang)
  return arbor.settings.global.get("run_default_profile:" .. lang) or ""
end

function M.save_default_profile(lang, id)
  arbor.settings.global.set("run_default_profile:" .. lang, id)
end

-- ── auto_stop_on_run  (global default, per-project can override) ───────────────

function M.load_auto_stop()
  local v = arbor.settings.global.get("run_auto_stop_on_run")
  return v ~= "false"
end

function M.save_auto_stop(enabled)
  arbor.settings.global.set("run_auto_stop_on_run", enabled and "true" or "false")
end

-- ── Settings form ─────────────────────────────────────────────────────────────

local function reopen()
  M.open_settings_form()
end

local function detected_to_run_lang(detected)
  if detected == "maven"  then return "maven"  end
  if detected == "gradle" then return "gradle" end
  if detected == "rust"   then return "rust"   end
  if detected == "npm"    then return "npm"    end
  if detected == "tauri"  then return "tauri"  end
  return ""
end

-- Re-contribute the "run" category + its sections with the current state.
-- Split out from `open_settings_form` so the same code runs at PLUGIN_LOAD
-- (to pre-populate the sidebar entry from the start) and on every open
-- (to refresh after run-config / auto-stop mutations).
function M.contribute_sections()
  -- run-action writes its own "detected_type" on repo open (same algorithm as
  -- compile-action) so this read is plugin-local and always matches the active repo.
  local detected = arbor.settings.project.get("detected_type") or ""
  local saved    = arbor.settings.global.get("ui:run_settings_lang") or ""

  local default_lang = saved
  if default_lang == "" then default_lang = detected_to_run_lang(detected) end
  if default_lang == "" then default_lang = "maven" end

  local highlighted = detected_to_run_lang(detected)

  local lang_opts = {}
  for _, l in ipairs(RUN_LANGUAGES) do
    local lbl = l.label
    if l.value == highlighted then lbl = lbl .. "  •  detected" end
    lang_opts[#lang_opts+1] = { value = l.value, label = lbl }
  end

  local auto_stop = M.load_auto_stop()
  local auto_stop_opts = {
    { value = "true",  label = "Yes — stop the running instance before launching a new one (recommended)" },
    { value = "false", label = "No  — allow multiple instances of the same configuration" },
  }

  -- Behaviour card — auto_stop default for run targets.
  local behaviour_nodes = {
    { type = "paragraph",
      content = "Global default applied to every repository. "
             .. "Each repository can override this in its Run Settings.",
      variant = "muted" },
    { type = "select",
      name    = "auto_stop_global",
      label   = "Stop existing instance on run",
      default = auto_stop and "true" or "false",
      options = auto_stop_opts },
    { type = "row", gap = 8, children = {
      { type = "button", label = "Apply", action = "run:global_set_auto_stop", variant = "primary" },
    }},
  }

  -- Configurations card — platform picker + per-platform CRUD.
  local run_children = {
    { type = "paragraph",
      content = "Run configurations shared across every repository — they appear below "
             .. "the project-specific ones in the combo. The • marker flags the platform "
             .. "that matches the active repo.",
      variant = "muted" },
    { type = "select", name = "run_lang", label = "Platform",
      default = default_lang, options = lang_opts },
  }

  for _, lang_entry in ipairs(RUN_LANGUAGES) do
    local lv         = lang_entry.value
    local default_id = M.load_default_profile(lv)
    local cfgs       = M.load_for_lang(lv)
    local show_lang  = { field = "run_lang", eq = lv }

    if #cfgs == 0 then
      run_children[#run_children+1] = {
        type    = "paragraph",
        content = "No global run configurations for " .. lang_entry.label .. " yet. Use the form below to add one.",
        variant = "muted",
        show_if = show_lang,
      }
    else
      local radio_opts = {}
      for _, c in ipairs(cfgs) do
        local lbl = c.label or c.id
        if c.id == default_id then lbl = lbl .. "  ✦  default" end
        radio_opts[#radio_opts+1] = { value = c.id, label = lbl }
      end
      local sel_name = "run_sel_" .. lv

      run_children[#run_children+1] = {
        type    = "radio", name = sel_name,
        label   = "Configurations",
        options = radio_opts,
        show_if = show_lang,
      }

      local row_visible = { ["and"] = { show_lang, { field = sel_name, neq = "" } } }
      run_children[#run_children+1] = {
        type = "row", gap = 8, align = "center", show_if = row_visible,
        children = {
          { type = "button", label = "Edit",           action = "run:global_edit",        variant = "default" },
          { type = "button", label = "Set as Default", action = "run:global_set_default", variant = "default" },
          { type = "button", label = "Delete",         action = "run:global_delete",      variant = "danger"  },
        },
      }
    end

    local placeholder_cmd = lv == "maven"  and "mvn spring-boot:run -Dspring-boot.run.profiles=dev"
                         or lv == "gradle" and "gradlew bootRun --args='--spring.profiles.active=dev'"
                         or lv == "rust"   and "cargo run --release"
                         or lv == "npm"    and "npm run dev"
                         or lv == "tauri"  and "cargo tauri dev"
                         or lv == "tomcat" and "/opt/tomcat/bin/catalina.sh run"
                         or "command"
    local hint_cmd = (lv == "rust") and "Features: --features f1,f2  |  --all-features  |  --no-default-features" or nil

    run_children[#run_children+1] = {
      type = "section",
      title = "New " .. lang_entry.label .. " run configuration",
      collapsible = true, collapsed = true,
      show_if = show_lang,
      children = {
        { type = "container", columns = 2, gap = 12, children = {
          { type = "text", name = "run_new_" .. lv .. "_id",    label = "Config ID *",    placeholder = lv .. "_run" },
          { type = "text", name = "run_new_" .. lv .. "_label", label = "Dropdown Label", placeholder = lang_label(lv) .. " · run" },
        }},
        { type = "textarea", name = "run_new_" .. lv .. "_cmd", label = "Command *",
          placeholder = placeholder_cmd, hint = hint_cmd, rows = 2 },
        { type = "text",     name = "run_new_" .. lv .. "_cwd", label = "Working Directory",
          hint = "Leave empty to use the active repo root at run time" },
        { type = "kv_list",  name = "run_new_" .. lv .. "_env", label = "Environment Variables",
          key_placeholder = "KEY", value_placeholder = "value" },
        { type = "row", gap = 8, children = {
          { type = "button", label = "Add Run Configuration", action = "run:global_add_config", variant = "primary" },
        }},
      },
    }
  end

  -- run-action contributes a "run" CATEGORY (sidebar entry) and two
  -- SECTIONS (cards) under it. Re-contributed each time so toolchain /
  -- config mutations are visible on the next open. We share the
  -- compile-action panel — the user sees Java / Node.js / Rust / Run as a
  -- single integrated settings surface.
  arbor.ui.contribute("compile-action:settings:category", {
    id       = "run",
    priority = 40,    -- right after Java/Node/Rust (10/20/30)
    payload  = {
      label       = "Run",
      icon        = "Play",
      priority    = 40,
      description = "Run-action global preferences and shared run configurations.",
    },
  })

  arbor.ui.contribute("compile-action:settings:section", {
    id       = "run-behaviour",
    priority = 10,
    payload  = {
      category = "run",
      label    = "Behaviour",
      nodes    = behaviour_nodes,
    },
  })

  arbor.ui.contribute("compile-action:settings:section", {
    id       = "run-configurations",
    priority = 20,
    payload  = {
      category = "run",
      label    = "Global Run Configurations",
      nodes    = run_children,
    },
  })
end

-- Open the panel — contribute fresh sections, then ask the orchestrator to
-- show the modal. Called by every "reopen()" path after a mutation.
function M.open_settings_form()
  M.contribute_sections()
  arbor.ui.settings.open("compile-action", "main")
end

-- ── Action handlers ───────────────────────────────────────────────────────────

function M.handle_set_auto_stop(ctx)
  local val = ctx.auto_stop_global or "true"
  M.save_auto_stop(val == "true")
  arbor.notify{ message = "Auto-stop default: " .. (val == "true" and "enabled" or "disabled"), level = "success" }
  reopen()
end

function M.handle_add(ctx)
  local lang = ctx.run_lang or "maven"
  local id   = ctx["run_new_" .. lang .. "_id"]  or ""
  local cmd  = ctx["run_new_" .. lang .. "_cmd"] or ""

  if id == "" or cmd == "" then
    arbor.notify{ message = "Config ID and Command are required", level = "warning" }
    reopen(); return
  end

  local lbl = ctx["run_new_" .. lang .. "_label"] or ""
  local cwd = ctx["run_new_" .. lang .. "_cwd"]   or ""
  local env = ctx["run_new_" .. lang .. "_env"]   or {}

  local cfgs = M.load()
  for _, c in ipairs(cfgs) do
    if c.id == id then
      arbor.notify{ message = "Config ID '" .. id .. "' already exists", level = "warning" }
      reopen(); return
    end
  end

  cfgs[#cfgs+1] = {
    id      = id,
    label   = lbl ~= "" and lbl or id,
    command = cmd,
    cwd     = cwd,
    env     = env,
    lang    = lang,
  }
  M.save(cfgs)
  arbor.notify{ message = "Global run config '" .. id .. "' added", level = "success" }
  reopen()
end

function M.handle_set_default(ctx)
  local lang   = ctx.run_lang or "maven"
  local cfg_id = ctx["run_sel_" .. lang] or ""
  if cfg_id == "" then
    arbor.notify{ message = "Select a configuration first", level = "warning" }
    reopen(); return
  end
  M.save_default_profile(lang, cfg_id)
  arbor.notify{ message = "Default run profile for " .. lang_label(lang) .. " set", level = "success" }
  reopen()
end

function M.handle_delete(ctx)
  local lang   = ctx.run_lang or "maven"
  local cfg_id = ctx["run_sel_" .. lang] or ""
  if cfg_id == "" then
    arbor.notify{ message = "Select a configuration first", level = "warning" }
    reopen(); return
  end
  local cfgs, new_cfgs, found = M.load(), {}, false
  for _, c in ipairs(cfgs) do
    if c.id == cfg_id then found = true
    else new_cfgs[#new_cfgs+1] = c end
  end
  if not found then
    arbor.notify{ message = "Configuration not found", level = "error" }
    reopen(); return
  end
  M.save(new_cfgs)
  if M.load_default_profile(lang) == cfg_id then
    M.save_default_profile(lang, "")
  end
  arbor.notify{ message = "Run configuration deleted", level = "success" }
  reopen()
end

function M.handle_edit(ctx)
  local lang   = ctx.run_lang or "maven"
  local cfg_id = ctx["run_sel_" .. lang] or ""
  if cfg_id == "" then
    arbor.notify{ message = "Select a configuration first", level = "warning" }
    reopen(); return
  end
  local cfg = M.find(cfg_id)
  if not cfg then
    arbor.notify{ message = "Configuration not found", level = "error" }
    reopen(); return
  end

  arbor.settings.global.set("ui:run_settings_lang", lang)
  arbor.ui.form({
    title         = "Edit Global Run Configuration",
    description   = "Editing: " .. (cfg.label or cfg.id),
    submit_label  = "Save Changes",
    submit_action = "run:global_edit_save",
    cancel_action = "run:global_settings_noop",
    width         = "520px",
    state         = { cfg_id = cfg_id, lang = lang },
    nodes = {
      { type = "container", columns = 2, gap = 12, children = {
        { type = "text", name = "cfg_id_disp",  label = "Config ID",  default = cfg.id,           readonly = true },
        { type = "text", name = "run_lang_disp",label = "Platform",   default = lang_label(lang),  readonly = true },
      }},
      { type = "text",     name = "run_edit_label",   label = "Dropdown Label *", default = cfg.label   or "" },
      { type = "textarea", name = "run_edit_command",  label = "Command *",        default = cfg.command or "", rows = 2 },
      { type = "text",     name = "run_edit_cwd",      label = "Working Directory",default = cfg.cwd     or "",
        hint = "Leave empty to use the active repo root at run time" },
      { type = "kv_list",  name = "run_edit_env",      label = "Environment Variables",
        default = cfg.env or {},
        key_placeholder = "KEY", value_placeholder = "value" },
    },
  })
end

function M.handle_edit_save(ctx)
  local cfg_id = (ctx.state and ctx.state.cfg_id) or ""
  local lang   = (ctx.state and ctx.state.lang)   or ""
  local cmd    = ctx.run_edit_command or ""

  if cfg_id == "" or cmd == "" then
    arbor.notify{ message = "Command is required", level = "warning" }; return
  end

  local cfgs, updated = M.load(), false
  for i, c in ipairs(cfgs) do
    if c.id == cfg_id then
      local lbl = ctx.run_edit_label or ""
      cfgs[i] = {
        id      = c.id,
        lang    = c.lang or lang,
        label   = lbl ~= "" and lbl or c.id,
        command = cmd,
        cwd     = ctx.run_edit_cwd or "",
        env     = ctx.run_edit_env or {},
      }
      updated = true; break
    end
  end

  if updated then
    M.save(cfgs)
    arbor.notify{ message = "Run configuration saved", level = "success" }
  else
    arbor.notify{ message = "Configuration not found", level = "error" }
  end
  reopen()
end

return M
