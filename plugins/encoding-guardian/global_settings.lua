-- global_settings.lua — the gear-icon panel opened from the Plugin Manager.
--
-- Plugin-manager settings are GLOBAL by nature: the manager isn't scoped to
-- any repository, so a per-repo toggle reached from there is misleading.
-- This panel therefore carries ONLY the cross-project switches. Per-repo
-- settings (charset / EOL / checks / scope) live in project_settings.lua,
-- opened from the Command Palette where a repo is unambiguously in context.

local settings = require("settings")

local M = {}

local CATEGORY_POINT = "encoding-guardian:settings:category"
local SECTION_POINT  = "encoding-guardian:settings:section"

local function global_card()
  return {
    category = "general",
    label    = "Global",
    card     = true,
    description = "Applies to every project. Per-repository settings live in "
               .. "the Command Palette: \"Encoding Guardian: Project settings\".",
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

local function refresh()
  arbor.ui.contribute(CATEGORY_POINT, {
    id       = "general",
    priority = 100,
    payload  = {
      label       = "Encoding",
      icon        = "ShieldCheck",
      priority    = 100,
      description = "Global encoding-guardian switches",
    },
  })
  arbor.ui.contribute(SECTION_POINT, { id = "global", priority = 100, payload = global_card() })
end

local function persist(fields)
  settings.global_set("enabled",   fields.global_enabled and true or false)
  settings.global_set("max_files", tonumber(fields.max_files) or settings.DEFAULT_MAX_FILES)
end

function M.register()
  arbor.ui.settings.panel({
    id           = "main",
    title        = "Encoding Guardian - Global settings",
    icon         = "ShieldCheck",
    width        = "560px",
    height       = "360px",
    submit_label = "Save",
    cancel_label = "Close",
    on_load      = "egd:global_refresh",
    on_save      = "egd:global_save",
  })

  arbor.events.on("egd:global_refresh", function(_ctx) refresh() end)
  arbor.events.on("egd:global_save", function(ctx)
    local fields = (ctx.sections and ctx.sections["encoding-guardian"]) or ctx or {}
    persist(fields)
    arbor.notify{ message = "Global encoding settings saved.", level = "success" }
  end)
end

return M
