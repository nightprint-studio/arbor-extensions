-- main.lua — encoding-guardian entry point.
--
-- This file is thin on purpose: every real concern lives in a focused
-- submodule under `plugins/encoding-guardian/`. The lifecycle hook below
-- registers each submodule's contributions exactly once.
--
--   settings.lua          - typed accessors over arbor.settings
--   mojibake.lua          - patterns + detect + fix
--   inspect.lua           - per-file BOM/EOL/UTF-8/mojibake checks
--   scan.lua              - directory walk + scan_project orchestration
--   precommit.lua         - on_pre_commit veto handler
--   commands.lua          - Command Palette scan/fix entries + result modal
--   settings_panel.lua    - gear-icon settings UI
--   editorconfig/parser.lua  - parse + serialise .editorconfig
--   editorconfig/studio.lua  - tree-on-left + form-on-right editor modal
--
-- See doc.html for the user-facing tour.

local commands       = require("commands")
local precommit      = require("precommit")
local settings_panel = require("settings_panel")
local studio         = require("editorconfig.studio")

arbor.events.on("on_plugin_load", function(ctx)
  settings_panel.register()
  commands.register()
  studio.register()
  precommit.register()
  arbor.log.info(
    "encoding-guardian ready (api_version=" .. tostring(ctx.api_version) .. ")"
  )
end)
