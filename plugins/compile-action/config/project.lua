-- config/project.lua — per-repo build-config CRUD + IntelliJ-style settings form.
--
-- Storage:
--   arbor.settings.project.project_configs  (JSON array of templated configs)
--   arbor.settings.project.selected         (selected config id)
--
-- The authoring UI is a tree_layout: tree on the left grouped by template,
-- card-section per config on the right, pre-rendered and shown via show_if
-- against `values.sel_cfg`. Toolbar: +▾ new-from-template, − remove, 📋 duplicate.

local state     = require("state")
local templates = require("config.templates")

local M = {}

-- ── Storage ───────────────────────────────────────────────────────────────────

function M.load()
  local raw = arbor.json.decode(arbor.settings.project.get("project_configs") or "[]")
  local cfgs = (raw and type(raw) == "table") and raw or {}
  -- Migration: drop any config that doesn't declare a template_id. The new
  -- format is mandatory; old bare command-string configs can't be edited here.
  local cleaned, changed = {}, false
  for _, c in ipairs(cfgs) do
    if c.template_id and templates.build_get(c.template_id) then
      cleaned[#cleaned+1] = c
    else
      changed = true
    end
  end
  if changed then M.save(cleaned) end
  return cleaned
end

function M.save(cfgs)
  local s = arbor.json.encode(cfgs or {})
  if s then arbor.settings.project.set("project_configs", s) end
end

function M.load_selected()
  return arbor.settings.project.get("selected") or ""
end

function M.save_selected(value)
  arbor.settings.project.set("selected", value or "")
end

function M.find(id)
  if not id or id == "" then return nil end
  for _, c in ipairs(M.load()) do
    if c.id == id then return c end
  end
  return nil
end

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function reopen(repo_path)
  M.open_project_settings_form(repo_path or state.current_repo)
end

-- Group configs by template_id, preserving template_order.
local function group_by_template(cfgs)
  local buckets = {}
  for _, c in ipairs(cfgs) do
    buckets[c.template_id] = buckets[c.template_id] or {}
    table.insert(buckets[c.template_id], c)
  end
  local ordered = {}
  for _, tid in ipairs(templates.build_order) do
    if buckets[tid] and #buckets[tid] > 0 then
      ordered[#ordered+1] = { template_id = tid, cfgs = buckets[tid] }
    end
  end
  return ordered
end

-- Build the tree nodes (groups → leaves).
local function build_tree_nodes(grouped)
  local tree = {}
  for _, grp in ipairs(grouped) do
    local tpl = templates.build_get(grp.template_id)
    if tpl then
      local children = {}
      for _, c in ipairs(grp.cfgs) do
        children[#children+1] = {
          value = c.id,
          label = c.name or c.id,
          icon  = tpl.icon,
          tag   = tpl.tag,
          tag_variant = tpl.tag_variant,
        }
      end
      tree[#tree+1] = {
        value    = "grp_" .. tpl.id,
        label    = tpl.label,
        icon    = tpl.icon,
        group    = true,
        children = children,
      }
    end
  end
  return tree
end

-- Build the "+ ▾" menu options: one entry per template.
local function build_new_menu_options()
  local opts = {}
  opts[#opts+1] = { heading = true, label = "New configuration" }
  for _, tid in ipairs(templates.build_order) do
    local tpl = templates.build[tid]
    opts[#opts+1] = {
      label  = tpl.label,
      icon   = tpl.icon,
      action = "compile:cfg_new",
      extra  = { template = tid },
    }
  end
  return opts
end

-- Build the content sections: one show-if-gated container per config. The
-- container is plain (no chrome) so the inner sections — General / Build
-- Options / Environment — read as standalone cards on the modal background
-- rather than as a heavy nested card-in-card. A bold heading at the top
-- names the active config + its template.
local function build_content_sections(cfgs)
  local out = {}
  if #cfgs == 0 then
    out[#out+1] = {
      type    = "paragraph",
      variant = "muted",
      content = "No build configurations yet. Click the ＋ in the toolbar to create one.",
    }
    return out
  end
  for _, c in ipairs(cfgs) do
    local tpl = templates.build_get(c.template_id)
    if tpl then
      local children = {
        { type = "paragraph", variant = "heading",
          content = (c.name or c.id) .. "  ·  " .. tpl.label },
      }
      for _, n in ipairs(tpl.schema(c)) do children[#children+1] = n end

      out[#out+1] = {
        id       = "sec_" .. c.id,
        type     = "container",
        show_if  = { field = "sel_cfg", eq = c.id },
        style    = "display:flex;flex-direction:column;gap:14px;padding:4px 18px",
        children = children,
      }
    end
  end
  return out
end

-- Build the form body + state for the current list of configs. Shared by
-- `open_project_settings_form` (first open) and `refresh_form` (in-place
-- replace on add/remove/duplicate).
local function build_form_body(cfgs, selected)
  local grouped    = group_by_template(cfgs)
  local tree_nodes = build_tree_nodes(grouped)

  local cfg_ids = {}
  for _, c in ipairs(cfgs) do cfg_ids[#cfg_ids+1] = c.id end

  local nodes = {
    { id = "cfg_root", type = "tree_layout",
      nav_width             = "240px",
      nav_collapsible       = true,
      nav_collapsed_default = false,
      nav_children          = {
        { id = "cfg_toolbar", type = "row", gap = 4, align = "center",
          children = {
            { id = "cfg_new_btn", type = "menu_button",
              icon = "Plus", icon_only = true,
              tooltip = "Add new configuration",
              variant = "ghost",
              options = build_new_menu_options() },
            { id = "cfg_rm_btn", type = "button",
              icon = "Minus", icon_only = true,
              tooltip = "Remove selected",
              variant = "ghost",
              action = "compile:cfg_remove" },
            { id = "cfg_dup_btn", type = "button",
              icon = "Copy",  icon_only = true,
              tooltip = "Duplicate selected",
              variant = "ghost",
              action = "compile:cfg_duplicate" },
            { id = "cfg_export_btn", type = "button",
              icon = "Upload", icon_only = true,
              tooltip = "Export selected as JSON (copy to clipboard)",
              variant = "ghost",
              action = "compile:cfg_export" },
            { id = "cfg_import_btn", type = "button",
              icon = "Download", icon_only = true,
              tooltip = "Import a configuration from JSON",
              variant = "ghost",
              action = "compile:cfg_import_open" },
          }},
        { id = "cfg_tree", type = "tree", name = "sel_cfg",
          default  = selected or "", expanded = true,
          nodes    = tree_nodes },
      },
      content_children = build_content_sections(cfgs),
    },
  }
  return { nodes = nodes, state = { cfg_ids = cfg_ids } }
end

-- In-place replace (no modal flicker). `selected_override` forces the tree
-- selection to a specific config id; pass nil to keep the current selection.
local function refresh_form(selected_override)
  local cfgs = M.load()
  local selected = selected_override or M.load_selected()
  local body = build_form_body(cfgs, selected)
  local payload = { nodes = body.nodes, state = body.state }
  if selected_override then
    payload.set_values = { sel_cfg = selected_override }
  end
  arbor.ui.form.replace(payload)
end

-- ── Form ──────────────────────────────────────────────────────────────────────

function M.open_project_settings_form(repo_path)
  local repo_label = (repo_path or ""):match("[/\\]([^/\\]+)$") or repo_path or "this repository"
  local cfgs       = M.load()

  local selected = M.load_selected()
  local has_sel  = false
  for _, c in ipairs(cfgs) do if c.id == selected then has_sel = true; break end end
  if not has_sel then selected = cfgs[1] and cfgs[1].id or "" end

  local body = build_form_body(cfgs, selected)

  arbor.ui.form({
    title         = "Build Configurations — " .. repo_label,
    width         = "920px",
    height        = "620px",
    submit_label  = "Save",
    submit_action = "compile:cfg_save_all",
    cancel_label  = "Cancel",
    cancel_action = "compile:cfg_cancel",
    state         = body.state,
    nodes         = body.nodes,
  })
end

-- ── Action handlers ───────────────────────────────────────────────────────────

-- Apply the current form values in `ctx` to every known config. Returns the
-- updated list (not yet written to storage).
local function apply_pending_edits(ctx)
  local known_ids = (ctx.state and ctx.state.cfg_ids) or {}
  local cfgs      = M.load()
  -- Only keep configs that are still present in storage AND were known when
  -- the form opened (so we don't resurrect configs deleted mid-session).
  local known_set = {}
  for _, id in ipairs(known_ids) do known_set[id] = true end

  for i, c in ipairs(cfgs) do
    if known_set[c.id] then
      templates.apply_ctx(c, ctx)
      cfgs[i] = c
    end
  end
  return cfgs
end

-- Submit: save all pending edits, toast, close (modal auto-closes).
function M.handle_save_all(ctx)
  local cfgs = apply_pending_edits(ctx)
  M.save(cfgs)
  -- Persist current tree selection too.
  if ctx.sel_cfg and ctx.sel_cfg ~= "" then M.save_selected(ctx.sel_cfg) end
  arbor.notify{ message = "Build configurations saved ✓", level = "success" }
  local combo = require("ui.combo")
  combo.refresh(M.load_selected())
end

-- Cancel: just close — pending edits discarded.
function M.handle_cancel(_ctx) end

-- New: save pending edits, create from template, refresh in-place.
function M.handle_cfg_new(ctx)
  local tpl_id = ctx.template or ""
  local tpl    = templates.build_get(tpl_id)
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

  local combo = require("ui.combo"); combo.refresh(new_cfg.id)
  refresh_form(new_cfg.id)
end

-- Remove: save pending edits, remove selected, refresh in-place.
function M.handle_cfg_remove(ctx)
  local target = ctx.sel_cfg or M.load_selected() or ""
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

  local combo = require("ui.combo"); combo.refresh(new_sel)
  refresh_form(new_sel)
end

-- Export: save pending edits, then copy the selected config (without runtime
-- ids and the regenerated `command` field) to the clipboard as JSON.
function M.handle_cfg_export(ctx)
  local target = ctx.sel_cfg or M.load_selected() or ""
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

  -- Snapshot, then strip runtime-only fields. `id` is regenerated on import
  -- so two copies of the same config don't collide; `command` is recomputed
  -- from the template after import in case the JSON was hand-tweaked.
  local export = arbor.json.decode(arbor.json.encode(cfg))
  export.id      = nil
  export.command = nil

  local json = arbor.json.encode(export)
  arbor.ui.copy_to_clipboard{
    text  = json,
    toast = "Configuration JSON copied to clipboard",
  }
end

-- ── Import (in-place via form.replace) ──────────────────────────────────────
-- Swap the settings-tree nodes for an import view INSIDE the same modal so
-- the underlying Build Configurations form stays open. The footer Save
-- button is dormant in this view (its handler returns early when no
-- pending edits exist) — the inline Import / Cancel-import buttons drive
-- the flow.

local function build_import_view()
  return {
    { id = "cfg_import_root", type = "container",
      style = "display:flex;flex-direction:column;gap:14px;padding:18px;"
           .. "max-width:640px;margin:0 auto",
      children = {
        { type = "paragraph", variant = "heading",
          content = "Import Build Configuration" },
        { type = "paragraph", variant = "muted",
          content = "Pick a JSON file exported from another build, or paste "
                 .. "the JSON directly into the editor below. When both "
                 .. "are provided, the file wins." },

        { type = "file", pick_mode = "file", name = "import_file_path",
          extensions = { "json" },
          label = "Choose JSON file",
          placeholder = "Pick a .json file…" },

        { type = "textarea", name = "import_json",
          label = "Configuration JSON",
          rows  = 14,
          placeholder = '{ "template_id": "maven", "name": "…", … }' },

        { id = "cfg_import_btns", type = "row", gap = 8, align = "center",
          children = {
            { type = "button", label = "Cancel import",
              icon = "ArrowLeft", variant = "ghost",
              action = "compile:cfg_import_cancel" },
            { type = "container", style = "flex:1 1 auto", children = {} },
            { type = "button", label = "Import",
              icon = "Send", variant = "primary",
              action = "compile:cfg_import_save" },
          }},
      }},
  }
end

-- Open: persist pending edits then swap the form nodes in-place. State
-- (cfg_ids) is preserved across the swap because we don't pass `state` —
-- form.replace leaves the existing live state untouched in that case.
function M.handle_cfg_import_open(ctx)
  local cfgs = apply_pending_edits(ctx)
  M.save(cfgs)

  arbor.ui.form.replace({ nodes = build_import_view() })
end

-- Cancel import: swap back to the settings tree. Reuses refresh_form so
-- the rebuild is identical to the original open path.
function M.handle_cfg_import_cancel(_ctx)
  refresh_form()
end

-- Save: validate, regenerate id + command, persist, swap back to the tree
-- with the imported config selected. Errors stay inline (toast) so the
-- import view keeps the user's input — they can fix and retry without
-- re-pasting.
function M.handle_cfg_import_save(ctx)
  local raw = (ctx.import_json or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local file_path = ctx.import_file_path or ""

  -- File wins over the textarea — matches the description shown to the user.
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
  local tpl = parsed.template_id and templates.build_get(parsed.template_id)
  if not tpl then
    arbor.notify{ message = "Unknown or missing template_id",
                  level = "error" }
    return
  end

  parsed.id      = "cfg_" .. tostring(math.floor((os.time() % 1000000) * 1000)) ..
                   "_" .. tostring(math.random(1000, 9999))
  parsed.command = templates.full_command(parsed)

  local cfgs = M.load()
  cfgs[#cfgs+1] = parsed
  M.save(cfgs)
  M.save_selected(parsed.id)

  local combo = require("ui.combo"); combo.refresh(parsed.id)
  arbor.notify{ message = "Configuration imported ✓", level = "success" }

  -- Swap the form back to the settings tree, with the imported cfg
  -- selected — same in-place transition as the import-open path.
  refresh_form(parsed.id)
end

-- Duplicate: save pending edits, clone selected with new id, refresh in-place.
function M.handle_cfg_duplicate(ctx)
  local target = ctx.sel_cfg or M.load_selected() or ""
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
  clone.id   = "cfg_" .. tostring(math.floor((os.time() % 1000000) * 1000)) ..
               "_" .. tostring(math.random(1000, 9999))
  clone.name = (clone.name or "Config") .. " (copy)"
  cfgs[#cfgs+1] = clone
  M.save(cfgs)
  M.save_selected(clone.id)

  local combo = require("ui.combo"); combo.refresh(clone.id)
  refresh_form(clone.id)
end

return M
