-- ui/settings.lua — plugin-global settings panel.
--
-- The panel is registered via `arbor.ui.settings.panel(...)` from main.lua's
-- on_plugin_load — that registration alone is what surfaces the gear icon
-- next to the plugin row in the Plugin Manager (the only entry point for
-- plugin-wide settings; the toolbar combo only deals with per-repo profiles).
--
-- Contributions:
--   • One category "general" — single sidebar entry on the left.
--   • Four sections under that category:
--       - main         (output folder + run cleanup + external tools)
--       - templates    (read-only card_row list with rename/delete buttons)
--   The `main` section owns the on_save that persists output_folder /
--   keep_last_n_runs / ju_bin together. The `templates` section has no
--   on_save — its buttons fire actions directly.
--
-- Mutation handlers (`handle_*`) re-contribute sections when they touch
-- state visible in the panel, so the modal stays in sync without a manual
-- reload.

local gcfg   = require("config.global")

local CATEGORY_POINT = "source-export:settings:category"
local SECTION_POINT  = "source-export:settings:section"

local M = {}

local function label(text, variant)
  return { type = "paragraph", content = text, variant = variant or "muted" }
end

-- ─ Section builders ─────────────────────────────────────────────────────────

local function build_main_nodes()
  return {
    { type = "section", title = "Output folder", card = true, children = {
      { type = "text", name = "output_folder",
        label       = "Folder where clones and workspaces are written",
        default     = gcfg.get_output_folder(),
        placeholder = "(empty = OS temp dir)" },
      label("Ogni run crea una subdir `<profile>_<timestamp>` dentro questa folder."),
    }},

    { type = "section", title = "Run cleanup", card = true, children = {
      { type = "number", name = "keep_last_n_runs",
        label   = "Keep last N runs per profile (0 = unlimited)",
        default = gcfg.get_keep_last_n(), min = 0, max = 200 },
      label("Le run più vecchie vengono scartate automaticamente (rimosso anche il file su disco)."),
    }},

    { type = "section", title = "External tools", card = true, children = {
      { type = "text", name = "ju_bin",
        label       = "Path eseguibile ju (M2 offline) — vuoto = cerca nel PATH",
        default     = gcfg.get_ju_bin(),
        placeholder = "C:\\tools\\ju\\ju.exe" },
    }},
  }
end

local function build_template_nodes()
  local templates = gcfg.load_templates()
  local rows = {}
  for _, t in ipairs(templates) do
    rows[#rows+1] = {
      type        = "card_row",
      label       = t.name or t.id,
      description = t.description or "",
      children    = {
        { type = "paragraph", variant = "muted",
          content = tostring(#(t.stages or {})) .. " stage(s)" },
        { type = "button", label = "Rename",
          action = "source-export:settings_rename_template",
          extra  = { template_id = t.id } },
        { type = "button", label = "Delete", variant = "danger",
          action = "source-export:settings_delete_template",
          extra  = { template_id = t.id } },
      }
    }
  end
  if #rows == 0 then
    rows[#rows+1] = { type = "card_row", children = {
      label("Nessun template globale. Creali esportando un profilo come template."),
    }}
  end
  return rows, #templates
end

-- ─ Contribute (called by panel on_load + after each mutation) ───────────────

function M.refresh()
  arbor.ui.contribute(CATEGORY_POINT, {
    id       = "general",
    priority = 100,
    payload  = {
      label       = "General",
      icon        = "Settings",
      priority    = 100,
      description = "Source Export — plugin-wide settings",
    },
  })

  arbor.ui.contribute(SECTION_POINT, {
    id       = "main",
    priority = 100,
    payload  = {
      category = "general",
      label    = "Settings",
      nodes    = build_main_nodes(),
      on_save  = "source-export:settings_save",
    },
  })

  local tpl_nodes, tpl_count = build_template_nodes()
  arbor.ui.contribute(SECTION_POINT, {
    id       = "templates",
    priority = 200,
    payload  = {
      category = "general",
      label    = "Templates",
      count    = tpl_count,
      nodes    = tpl_nodes,
    },
  })
end

-- ─ Action handlers (fired by ContributableModal Save + inline buttons) ──────

function M.handle_save(ctx)
  gcfg.set_output_folder(ctx.output_folder or "")
  gcfg.set_keep_last_n(tonumber(ctx.keep_last_n_runs) or 5)
  gcfg.set_ju_bin(ctx.ju_bin or "")
  arbor.notify{ message = "Source Export settings saved ✓", level = "success" }
end

function M.handle_delete_template(ctx)
  local tid = ctx.template_id or ""
  if tid == "" then return end
  gcfg.remove_template(tid)
  arbor.notify{ message = "Template rimosso", level = "success" }
  M.refresh()
end

function M.handle_rename_template(ctx)
  local tid = ctx.template_id or ""
  local tpl = gcfg.find_template(tid)
  if not tpl then return end
  arbor.ui.form({
    title         = "Rename template",
    width         = "480px",
    submit_label  = "Save",
    submit_action = "source-export:settings_rename_template_save",
    cancel_label  = "Cancel",
    cancel_action = "source-export:settings_noop",
    nodes = {
      { type = "text", name = "tpl_new_name", label = "Nuovo nome",
        default = tpl.name or "" },
    },
    state = { template_id = tid },
  })
end

function M.handle_rename_template_save(ctx)
  local tid  = (ctx.state and ctx.state.template_id) or ""
  local name = ctx.tpl_new_name or ""
  if tid == "" or name == "" then return end
  local tpl = gcfg.find_template(tid)
  if not tpl then return end
  tpl.name = name
  gcfg.upsert_template(tpl)
  arbor.notify{ message = "Template rinominato", level = "success" }
  M.refresh()
end

return M
