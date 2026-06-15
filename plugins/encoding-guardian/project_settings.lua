-- project_settings.lua — per-repository encoding contract.
--
-- Opened from the Command Palette ("Encoding Guardian: Project settings")
-- rather than the Plugin Manager gear: these settings are scoped to the
-- active repo, so they belong where a repo is unambiguously in context.
-- A single plain modal (arbor.ui.form) is enough — there's one section, so
-- the contributable multi-category panel would be overkill.

local settings = require("settings")

local M = {}

local CHARSET_OPTIONS = {
  { value = "utf-8",     label = "utf-8 (no BOM)" },
  { value = "utf-8-bom", label = "utf-8 with BOM" },
  { value = "latin1",       label = "latin1 (ISO-8859-1)" },
  { value = "windows-1252", label = "windows-1252 (CP1252)" },
  { value = "utf-16le",     label = "utf-16le" },
  { value = "utf-16be",  label = "utf-16be" },
}
local EOL_OPTIONS = {
  { value = "any",  label = "any (don't check)" },
  { value = "lf",   label = "lf (Unix)" },
  { value = "crlf", label = "crlf (Windows)" },
}

-- kv_list takes/returns a JSON object { key = value }, not an array of rows.
-- Globs are keys with an empty value (the value column is unused here).
local function glob_map(globs)
  local out = {}
  for _, g in ipairs(globs) do out[g] = "" end
  return out
end

-- kv_list submits a JSON object { glob = value }; the globs are its keys.
-- pairs() (not ipairs) because the keys are arbitrary strings, not indices.
-- Sorted for a stable on-disk order independent of hash iteration.
local function keys_of(kv_map)
  if type(kv_map) ~= "table" then return nil end
  local out = {}
  for k, _ in pairs(kv_map) do
    if type(k) == "string" and k ~= "" then out[#out + 1] = k end
  end
  table.sort(out)
  return out
end

-- ── Form ─────────────────────────────────────────────────────────────────

local function build_nodes()
  return {
    { type = "section_header", title = "This project" },
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

    { type = "section_header", title = "Checks" },
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

    { type = "section_header", title = "Scan scope" },
    { type = "kv_list", name = "include_globs",
      label   = "Include globs (one per row, leave value empty)",
      default = glob_map(settings.project_list("include_globs",
                                               settings.DEFAULT_INCLUDE_GLOBS)),
      hint    = "Default covers common text source extensions." },
    { type = "kv_list", name = "exclude_globs",
      label   = "Exclude globs",
      default = glob_map(settings.project_list("exclude_globs", {})) },
  }
end

local function open()
  if not arbor.repo.current() then
    arbor.notify{ message = "Open a repository first.", level = "warning" }
    return
  end
  arbor.ui.form({
    title         = "Encoding Guardian - Project settings",
    width         = "640px",
    height        = "560px",
    nodes         = build_nodes(),
    submit_label  = "Save",
    submit_action = "egd:project_save",
    cancel_label  = "Close",
  })
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
end

-- ── Registration ───────────────────────────────────────────────────────────

function M.register()
  arbor.command.register({
    id          = "project_settings",
    title       = "Encoding Guardian: Project settings",
    description = "Charset / EOL / checks / scan scope for the active repo.",
    icon        = "ShieldCheck",
    group       = "Encoding Guardian",
  })
  arbor.events.on("command:project_settings", function(_ctx) open() end)
  arbor.events.on("egd:project_save", function(ctx)
    persist(ctx or {})
    pcall(function() arbor.ui.form.close() end)
    arbor.notify{ message = "Encoding settings saved for this project.", level = "success" }
  end)
end

return M
