-- config/run_project.lua — per-repo run-config CRUD + IntelliJ-style run modal.
--
-- Storage:
--   arbor.settings.project.run_configs  (JSON array of templated run configs)
--   arbor.settings.project.run_selected (selected run config id)

local state     = require("state")
local templates = require("config.run_templates")

local M = {}

-- ── Storage ───────────────────────────────────────────────────────────────────

function M.load()
  local raw = arbor.json.decode(arbor.settings.project.get("run_configs") or "[]")
  local cfgs = (raw and type(raw) == "table") and raw or {}
  -- Migration: drop legacy entries without template_id.
  local cleaned, changed = {}, false
  for _, c in ipairs(cfgs) do
    if c.template_id and templates.run_get(c.template_id) then
      cleaned[#cleaned+1] = c
    else
      changed = true
    end
  end

  -- One-shot migration (run once per repo): default `build_id = ""` to
  -- "__skip__" for every non-tomcat config. Only Tomcat needs a separate
  -- build step (the WAR is then deployed manually) — Spring, Cargo, npm,
  -- plain Java all delegate compilation to their own run command.
  if arbor.settings.project.get("run_skip_build_migrated") ~= "1" then
    for _, c in ipairs(cleaned) do
      local ct = c.config_type or ""
      if ct ~= "tomcat" and (c.build_id == nil or c.build_id == "") then
        c.build_id = "__skip__"
        changed = true
      end
    end
    arbor.settings.project.set("run_skip_build_migrated", "1")
  end

  if changed then M.save(cleaned) end
  return cleaned
end

function M.save(cfgs)
  local s = arbor.json.encode(cfgs or {})
  if s then arbor.settings.project.set("run_configs", s) end
end

function M.load_selected() return arbor.settings.project.get("run_selected") or "" end
function M.save_selected(value) arbor.settings.project.set("run_selected", value or "") end

function M.find(id)
  if not id or id == "" then return nil end
  for _, c in ipairs(M.load()) do
    if c.id == id then return c end
  end
  return nil
end

-- ── Legacy compat shims (still referenced by main.lua) ────────────────────────
-- The Tomcat-home and debug-port used to be stored project-wide. They are now
-- per-config. These helpers stay so the runtime `do_run` can fall back to the
-- currently-selected Tomcat config's values.

local function selected_tomcat_cfg()
  local sel = M.load_selected()
  if sel ~= "" then
    local c = M.find(sel)
    if c and (c.config_type or "") == "tomcat" then return c end
  end
  for _, c in ipairs(M.load()) do
    if (c.config_type or "") == "tomcat" then return c end
  end
  return nil
end

function M.load_tomcat_home()
  local c = selected_tomcat_cfg()
  if c and c.tomcat_home and c.tomcat_home ~= "" then return c.tomcat_home end
  return arbor.settings.project.get("tomcat_home") or ""
end

function M.load_debug_port()
  local c = selected_tomcat_cfg()
  if c and c.debug_port and c.debug_port ~= "" then return c.debug_port end
  return arbor.settings.project.get("tomcat_debug_port") or ""
end

function M.load_auto_stop_override()
  return arbor.settings.project.get("run_auto_stop_override") or ""
end
function M.save_auto_stop_override(value)
  arbor.settings.project.set("run_auto_stop_override", value or "")
end

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function reopen(repo_path)
  M.open_project_run_settings_form(repo_path or state.current_repo)
end

local function group_by_template(cfgs)
  local buckets = {}
  for _, c in ipairs(cfgs) do
    buckets[c.template_id] = buckets[c.template_id] or {}
    table.insert(buckets[c.template_id], c)
  end
  local ordered = {}
  for _, tid in ipairs(templates.run_order) do
    if buckets[tid] and #buckets[tid] > 0 then
      ordered[#ordered+1] = { template_id = tid, cfgs = buckets[tid] }
    end
  end
  return ordered
end

local function build_tree_nodes(grouped)
  local tree = {}
  for _, grp in ipairs(grouped) do
    local tpl = templates.run_get(grp.template_id)
    if tpl then
      local children = {}
      for _, c in ipairs(grp.cfgs) do
        children[#children+1] = {
          value       = c.id,
          label       = c.name or c.id,
          icon        = tpl.icon,
          tag         = tpl.tag,
          tag_variant = tpl.tag_variant,
        }
      end
      tree[#tree+1] = {
        value    = "grp_" .. tpl.id,
        label    = tpl.label,
        icon     = tpl.icon,
        group    = true,
        children = children,
      }
    end
  end
  return tree
end

local function build_new_menu_options()
  local opts = { { heading = true, label = "New run configuration" } }
  for _, tid in ipairs(templates.run_order) do
    local tpl = templates.run[tid]
    opts[#opts+1] = {
      label = tpl.label, icon = tpl.icon,
      action = "run:cfg_new", extra = { template = tid },
    }
  end
  return opts
end

-- One show-if-gated container per config — no chrome on the wrapper so the
-- inner sections (General / Behaviour / Run Options / Env / Per-profile /
-- Before Launch) read as standalone cards on the modal background. A bold
-- heading at the top names the active config + its template.
--
-- The Behaviour section is repo-wide (auto_stop_override applies to ALL
-- configs in this repo) but rendered INSIDE each cfg's flow, right under
-- General, so the user sees it in context while editing. Only one cfg's
-- container is visible at a time (show_if), so the duplicated render of the
-- single `auto_stop_override` field is harmless — the renderer collects
-- fields by name into a shared `values` map.
local function behaviour_section()
  local auto_stop_opts = {
    { value = "",      label = "Inherit from global settings"           },
    { value = "true",  label = "Always stop existing instance"          },
    { value = "false", label = "Never stop (allow multiple instances)" },
  }
  return {
    type = "section", title = "Behaviour",
    collapsible = true, collapsed = true,
    description = "Per-repository run behaviour. Overrides the global "
               .. "auto-stop setting for this repository.",
    children = {
      { type = "card_row",
        label       = "Stop existing instance",
        description = "Whether a running service is killed before relaunching.",
        children = {
          { type = "select", name = "auto_stop_override",
            default = M.load_auto_stop_override(), options = auto_stop_opts },
          { type = "button", label = "Apply",
            action = "run:project_set_auto_stop", variant = "primary" },
        }},
    },
  }
end

local function build_content_sections(cfgs)
  local out = {}
  if #cfgs == 0 then
    out[#out+1] = {
      type = "paragraph", variant = "muted",
      content = "No run configurations yet. Click the ＋ in the toolbar to create one.",
    }
    return out
  end
  for _, c in ipairs(cfgs) do
    local tpl = templates.run_get(c.template_id)
    if tpl then
      local children = {
        { type = "paragraph", variant = "heading",
          content = (c.name or c.id) .. "  ·  " .. tpl.label },
      }
      -- Insert Behaviour right after General. Convention: tpl.schema()
      -- always returns the General section as its first node (see
      -- compose() in run_templates.lua).
      local schema = tpl.schema(c)
      for i, n in ipairs(schema) do
        children[#children+1] = n
        if i == 1 then
          local b = behaviour_section()
          b.id = "rcfg_behaviour_" .. c.id   -- unique collapse-state key
          children[#children+1] = b
        end
      end

      out[#out+1] = {
        id       = "rsec_" .. c.id,
        type     = "container",
        show_if  = { field = "sel_rcfg", eq = c.id },
        style    = "display:flex;flex-direction:column;gap:14px;padding:4px 18px",
        children = children,
      }
    end
  end
  return out
end

-- Build the form body + state for the current run configs. Shared by
-- `open_project_run_settings_form` (first open) and `refresh_form` (in-place
-- replace on add/remove/duplicate).
local function build_form_body(cfgs, selected)
  local grouped    = group_by_template(cfgs)
  local tree_nodes = build_tree_nodes(grouped)

  local cfg_ids = {}
  for _, c in ipairs(cfgs) do cfg_ids[#cfg_ids+1] = c.id end

  -- Behaviour is now rendered inline inside each cfg's container (right
  -- after General) — see `build_content_sections` for the placement.
  local content = build_content_sections(cfgs)

  local nodes = {
    { id = "rcfg_root", type = "tree_layout",
      nav_width             = "250px",
      nav_collapsible       = true,
      nav_collapsed_default = false,
      nav_children          = {
        { id = "rcfg_toolbar", type = "row", gap = 4, align = "center",
          children = {
            { id = "rcfg_new_btn", type = "menu_button",
              icon = "Plus", icon_only = true, variant = "ghost",
              tooltip = "Add new run configuration",
              options = build_new_menu_options() },
            { id = "rcfg_rm_btn", type = "button",
              icon = "Minus", icon_only = true, variant = "ghost",
              tooltip = "Remove selected", action = "run:cfg_remove" },
            { id = "rcfg_dup_btn", type = "button",
              icon = "Copy", icon_only = true, variant = "ghost",
              tooltip = "Duplicate selected", action = "run:cfg_duplicate" },
            { id = "rcfg_export_btn", type = "button",
              icon = "Upload", icon_only = true, variant = "ghost",
              tooltip = "Export selected as JSON (copy to clipboard)",
              action = "run:cfg_export" },
            { id = "rcfg_import_btn", type = "button",
              icon = "Download", icon_only = true, variant = "ghost",
              tooltip = "Import a configuration from JSON",
              action = "run:cfg_import_open" },
          }},
        { id = "rcfg_tree", type = "tree", name = "sel_rcfg",
          default = selected or "", expanded = true, nodes = tree_nodes },
      },
      content_children = content,
    },
  }

  return { nodes = nodes, state = { cfg_ids = cfg_ids } }
end

-- In-place replace (no modal flicker).
local function refresh_form(selected_override)
  local cfgs = M.load()
  local selected = selected_override or M.load_selected()
  local body = build_form_body(cfgs, selected)
  local payload = { nodes = body.nodes, state = body.state }
  if selected_override then
    payload.set_values = { sel_rcfg = selected_override }
  end
  arbor.ui.form.replace(payload)
end

-- ── Form ──────────────────────────────────────────────────────────────────────

function M.open_project_run_settings_form(repo_path)
  local repo_label = (repo_path or ""):match("[/\\]([^/\\]+)$") or repo_path or "this repository"
  local cfgs       = M.load()

  local selected = M.load_selected()
  local has_sel  = false
  for _, c in ipairs(cfgs) do if c.id == selected then has_sel = true; break end end
  if not has_sel then selected = cfgs[1] and cfgs[1].id or "" end

  local body = build_form_body(cfgs, selected)

  arbor.ui.form({
    title         = "Run Configurations — " .. repo_label,
    width         = "940px",
    height        = "640px",
    submit_label  = "Save",
    submit_action = "run:cfg_save_all",
    cancel_label  = "Cancel",
    cancel_action = "run:cfg_cancel",
    state         = body.state,
    nodes         = body.nodes,
  })
end

-- ── Action handlers ───────────────────────────────────────────────────────────

local function apply_pending_edits(ctx)
  local known_ids = (ctx.state and ctx.state.cfg_ids) or {}
  local cfgs      = M.load()
  local known     = {}
  for _, id in ipairs(known_ids) do known[id] = true end
  for i, c in ipairs(cfgs) do
    if known[c.id] then
      templates.apply_ctx(c, ctx)
      cfgs[i] = c
    end
  end
  return cfgs
end

function M.handle_save_all(ctx)
  local cfgs = apply_pending_edits(ctx)
  M.save(cfgs)
  if ctx.sel_rcfg and ctx.sel_rcfg ~= "" then M.save_selected(ctx.sel_rcfg) end
  arbor.notify{ message = "Run configurations saved ✓", level = "success" }
  local combo = require("ui.run_combo")
  combo.refresh(M.load_selected())
end

function M.handle_cancel(_ctx) end

function M.handle_cfg_new(ctx)
  local tpl_id = ctx.template or ""
  local tpl    = templates.run_get(tpl_id)
  if not tpl then
    arbor.notify{ message = "Unknown template: " .. tpl_id, level = "error" }
    return
  end
  local cfgs    = apply_pending_edits(ctx)
  local new_cfg = templates.new_config(tpl_id)
  if not new_cfg then
    arbor.notify{ message = "Failed to create config", level = "error" }
    return
  end
  cfgs[#cfgs+1] = new_cfg
  M.save(cfgs)
  M.save_selected(new_cfg.id)
  local combo = require("ui.run_combo"); combo.refresh(new_cfg.id)
  refresh_form(new_cfg.id)
end

function M.handle_cfg_remove(ctx)
  local target = ctx.sel_rcfg or M.load_selected() or ""
  if target == "" then
    arbor.notify{ message = "Select a configuration first", level = "warning" }
    return
  end
  local cfgs = apply_pending_edits(ctx)
  local new_cfgs, found = {}, false
  for _, c in ipairs(cfgs) do
    if c.id == target then found = true
    else new_cfgs[#new_cfgs+1] = c end
  end
  if not found then
    arbor.notify{ message = "Configuration not found", level = "error" }
    return
  end
  M.save(new_cfgs)
  local new_sel = new_cfgs[1] and new_cfgs[1].id or ""
  if M.load_selected() == target then M.save_selected(new_sel) end
  local combo = require("ui.run_combo"); combo.refresh(new_sel)
  refresh_form(new_sel)
end

-- Export: persist pending edits, then copy the selected run config (without
-- runtime ids and the regenerated `command`) to the clipboard as JSON.
function M.handle_cfg_export(ctx)
  local target = ctx.sel_rcfg or M.load_selected() or ""
  if target == "" then
    arbor.notify{ message = "Select a configuration first", level = "warning" }
    return
  end
  local cfgs = apply_pending_edits(ctx)
  M.save(cfgs)

  local cfg
  for _, c in ipairs(cfgs) do
    if c.id == target then cfg = c; break end
  end
  if not cfg then
    arbor.notify{ message = "Configuration not found", level = "error" }
    return
  end

  local export = arbor.json.decode(arbor.json.encode(cfg))
  export.id      = nil   -- regenerated on import
  export.command = nil   -- regenerated from the template on import

  local json = arbor.json.encode(export)
  arbor.ui.copy_to_clipboard{
    text  = json,
    toast = "Run configuration JSON copied to clipboard",
  }
end

-- ── Import (in-place via form.replace) ──────────────────────────────────────
-- Same pattern as compile-action: swap the tree nodes for an import view
-- INSIDE the same modal so the underlying Run Configurations form stays
-- open. State (cfg_ids) is preserved across the swap; the inline Cancel /
-- Import buttons drive the flow.

local function build_import_view()
  return {
    { id = "rcfg_import_root", type = "container",
      style = "display:flex;flex-direction:column;gap:14px;padding:18px;"
           .. "max-width:640px;margin:0 auto",
      children = {
        { type = "paragraph", variant = "heading",
          content = "Import Run Configuration" },
        { type = "paragraph", variant = "muted",
          content = "Pick a JSON file exported from another repo, or paste "
                 .. "the JSON directly into the editor below. When both "
                 .. "are provided, the file wins." },

        { type = "file", pick_mode = "file", name = "import_file_path",
          extensions = { "json" },
          label = "Choose JSON file",
          placeholder = "Pick a .json file…" },

        { type = "textarea", name = "import_json",
          label = "Configuration JSON",
          rows  = 14,
          placeholder = '{ "template_id": "spring", "name": "…", … }' },

        { id = "rcfg_import_btns", type = "row", gap = 8, align = "center",
          children = {
            { type = "button", label = "Cancel import",
              icon = "ArrowLeft", variant = "ghost",
              action = "run:cfg_import_cancel" },
            { type = "container", style = "flex:1 1 auto", children = {} },
            { type = "button", label = "Import",
              icon = "Send", variant = "primary",
              action = "run:cfg_import_save" },
          }},
      }},
  }
end

function M.handle_cfg_import_open(ctx)
  local cfgs = apply_pending_edits(ctx)
  M.save(cfgs)

  arbor.ui.form.replace({ nodes = build_import_view() })
end

function M.handle_cfg_import_cancel(_ctx)
  refresh_form()
end

function M.handle_cfg_import_save(ctx)
  local raw = (ctx.import_json or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local file_path = ctx.import_file_path or ""

  if file_path ~= "" then
    local content, err = arbor.fs.read(file_path)
    if not content then
      arbor.notify{ message = "Could not read file: " .. tostring(err),
                    level = "error" }
      return
    end
    raw = (content or ""):gsub("^%s+", ""):gsub("%s+$", "")
  end

  if raw == "" then
    arbor.notify{ message = "Paste a JSON configuration or pick a file first",
                  level = "warning" }
    return
  end

  local ok, parsed = pcall(arbor.json.decode, raw)
  if not ok or type(parsed) ~= "table" then
    arbor.notify{ message = "Invalid JSON — could not parse",
                  level = "error" }
    return
  end
  local tpl = parsed.template_id and templates.run_get(parsed.template_id)
  if not tpl then
    arbor.notify{ message = "Unknown or missing template_id",
                  level = "error" }
    return
  end

  parsed.id          = "rcfg_" .. tostring(math.floor((os.time() % 1000000) * 1000)) ..
                       "_" .. tostring(math.random(1000, 9999))
  parsed.config_type = tpl.config_type
  parsed.command     = tpl.build_command(parsed)

  local cfgs = M.load()
  cfgs[#cfgs+1] = parsed
  M.save(cfgs)
  M.save_selected(parsed.id)

  local combo = require("ui.run_combo"); combo.refresh(parsed.id)
  arbor.notify{ message = "Run configuration imported ✓", level = "success" }

  refresh_form(parsed.id)
end

function M.handle_cfg_duplicate(ctx)
  local target = ctx.sel_rcfg or M.load_selected() or ""
  if target == "" then
    arbor.notify{ message = "Select a configuration first", level = "warning" }
    return
  end
  local cfgs = apply_pending_edits(ctx)
  local src
  for _, c in ipairs(cfgs) do
    if c.id == target then src = c; break end
  end
  if not src then
    arbor.notify{ message = "Configuration not found", level = "error" }
    return
  end
  local clone = arbor.json.decode(arbor.json.encode(src))
  clone.id   = "rcfg_" .. tostring(math.floor((os.time() % 1000000) * 1000)) ..
               "_" .. tostring(math.random(1000, 9999))
  clone.name = (clone.name or "Config") .. " (copy)"
  cfgs[#cfgs+1] = clone
  M.save(cfgs)
  M.save_selected(clone.id)
  local combo = require("ui.run_combo"); combo.refresh(clone.id)
  refresh_form(clone.id)
end

function M.handle_set_auto_stop(ctx)
  local val = ctx.auto_stop_override or ""
  pcall(M.save_auto_stop_override, val)
  local desc = val == "true"  and "always stop existing instance"
            or val == "false" and "never stop existing instance"
            or "inherit global setting"
  arbor.notify{ message = "Auto-stop: " .. desc, level = "success" }
  -- No refresh needed: the select is already bound to the new value.
end

return M
