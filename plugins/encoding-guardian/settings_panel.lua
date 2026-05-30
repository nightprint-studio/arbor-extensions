-- settings_panel.lua — gear-icon settings UI.
--
-- Contributes one category and four cards (project / checks / scope /
-- global) to the panel registered in main.lua. The save handler unpacks
-- the panel-level payload (`ctx.sections["encoding-guardian"]`) and
-- persists into both project and global scopes.

local settings = require("settings")

local M = {}

local CATEGORY_POINT = "encoding-guardian:settings:category"
local SECTION_POINT  = "encoding-guardian:settings:section"

-- Common option sets reused across the panel.
local CHARSET_OPTIONS = {
  { value = "utf-8",     label = "utf-8 (no BOM)" },
  { value = "utf-8-bom", label = "utf-8 with BOM" },
  { value = "latin1",    label = "latin1" },
  { value = "utf-16le",  label = "utf-16le" },
  { value = "utf-16be",  label = "utf-16be" },
}
local EOL_OPTIONS = {
  { value = "any",  label = "any (don't check)" },
  { value = "lf",   label = "lf (Unix)" },
  { value = "crlf", label = "crlf (Windows)" },
}

-- ── Card builders ──────────────────────────────────────────────────────────

local function project_card()
  return {
    category = "general",
    label    = "This project",
    card     = true,
    description = "Settings here are per-repository - toggling them only "
               .. "affects the active repo.",
    nodes = {
      { type = "checkbox", name = "enabled",
        label   = "Enable pre-commit encoding check for this project",
        default = settings.project_bool("enabled", false) },
      { type = "select",   name = "default_charset",
        label   = "Project charset",
        options = CHARSET_OPTIONS,
        default = settings.project_get("default_charset", "utf-8") },
      { type = "select",   name = "default_eol",
        label   = "Expected line ending",
        options = EOL_OPTIONS,
        default = settings.project_get("default_eol", "any") },
    },
  }
end

local function checks_card()
  return {
    category = "general",
    label    = "Checks",
    card     = true,
    nodes = {
      { type = "checkbox", name = "block_mojibake",
        label   = "Block on mojibake",
        default = settings.project_bool("block_mojibake", true) },
      { type = "checkbox", name = "block_charset",
        label   = "Block when a file isn't valid in the project charset",
        default = settings.project_bool("block_charset", true) },
      { type = "checkbox", name = "block_bom",
        label   = "Block on BOM mismatch",
        default = settings.project_bool("block_bom", false) },
      { type = "checkbox", name = "block_eol",
        label   = "Block on EOL mismatch",
        default = settings.project_bool("block_eol", false) },
    },
  }
end

local function glob_rows(globs)
  local out = {}
  for _, g in ipairs(globs) do out[#out + 1] = { key = g, value = "" } end
  return out
end

local function scope_card()
  return {
    category = "general",
    label    = "Scan scope",
    card     = true,
    nodes = {
      { type = "kv_list", name = "include_globs",
        label   = "Include globs (one per row, leave value empty)",
        default = glob_rows(settings.project_list("include_globs",
                                                  settings.DEFAULT_INCLUDE_GLOBS)),
        hint    = "Default covers common text source extensions." },
      { type = "kv_list", name = "exclude_globs",
        label   = "Exclude globs",
        default = glob_rows(settings.project_list("exclude_globs", {})) },
    },
  }
end

local function global_card()
  return {
    category = "general",
    label    = "Global",
    card     = true,
    description = "Applies to every project.",
    nodes = {
      { type = "checkbox", name = "global_enabled",
        label   = "Master kill switch",
        default = settings.global_bool("enabled", true),
        hint    = "When off, the pre-commit hook never runs regardless of "
               .. "per-project settings." },
      { type = "number",   name = "max_files",
        label   = "Safety cap - max files per scan",
        default = settings.global_get("max_files", settings.DEFAULT_MAX_FILES),
        min     = 100, max = 100000 },
    },
  }
end

-- ── Contributions ──────────────────────────────────────────────────────────

local function refresh()
  arbor.ui.contribute(CATEGORY_POINT, {
    id       = "general",
    priority = 100,
    payload  = {
      label       = "Encoding",
      icon        = "ShieldCheck",
      priority    = 100,
      description = "Per-project encoding contract + pre-commit checks",
    },
  })

  arbor.ui.contribute(SECTION_POINT, { id = "project", priority = 100, payload = project_card() })
  arbor.ui.contribute(SECTION_POINT, { id = "checks",  priority = 200, payload = checks_card()  })
  arbor.ui.contribute(SECTION_POINT, { id = "scope",   priority = 300, payload = scope_card()   })
  arbor.ui.contribute(SECTION_POINT, { id = "global",  priority = 400, payload = global_card()  })
end

-- ── Save ───────────────────────────────────────────────────────────────────

local function keys_of(kv_list)
  if type(kv_list) ~= "table" then return nil end
  local out = {}
  for _, row in ipairs(kv_list) do
    local k = row and (row.key or row[1])
    if k and k ~= "" then out[#out + 1] = k end
  end
  return out
end

local function persist(fields)
  settings.project_set("enabled",         fields.enabled and true or false)
  settings.project_set("default_charset", fields.default_charset)
  settings.project_set("default_eol",     fields.default_eol)
  settings.project_set("block_mojibake",  fields.block_mojibake and true or false)
  settings.project_set("block_charset",   fields.block_charset  and true or false)
  settings.project_set("block_bom",       fields.block_bom      and true or false)
  settings.project_set("block_eol",       fields.block_eol      and true or false)
  settings.project_set("include_globs",   keys_of(fields.include_globs))
  settings.project_set("exclude_globs",   keys_of(fields.exclude_globs))

  settings.global_set("enabled",   fields.global_enabled and true or false)
  settings.global_set("max_files", tonumber(fields.max_files) or settings.DEFAULT_MAX_FILES)
end

-- ── Registration ───────────────────────────────────────────────────────────

function M.register()
  arbor.ui.settings.panel({
    id           = "main",
    title        = "Encoding Guardian - Settings",
    icon         = "ShieldCheck",
    width        = "720px",
    height       = "640px",
    submit_label = "Save",
    cancel_label = "Close",
    on_load      = "egd:settings_refresh",
    on_save      = "egd:save_config",
  })

  arbor.events.on("egd:settings_refresh", function(_ctx) refresh() end)
  arbor.events.on("egd:save_config", function(ctx)
    local fields = (ctx.sections and ctx.sections["encoding-guardian"]) or ctx or {}
    persist(fields)
    arbor.notify{ message = "Encoding Guardian settings saved.", level = "success" }
  end)
end

return M
