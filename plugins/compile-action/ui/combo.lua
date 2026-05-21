-- ui/combo.lua — RepoActions combo button registration and refresh

local gcfg  = require("config.global")
local pcfg  = require("config.project")
local state = require("state")

local M = {}

--- Register the combo button once at plugin load.
function M.register()
  arbor.ui.add_graph_combo({
    id            = "compile:selector",
    run_icon      = "Hammer",
    run_action    = "compile:run",
    select_action = "compile:select",
    tooltip       = "Build selected configuration",
    target        = "repo_actions",
    options       = {},
  })
end

--- Rebuild the combo options from project + global configs for the current repo.
--- @param selected string|nil  The value to select in the combo (nil = keep current).
function M.refresh(selected)
  local opts = {}

  -- pcall guards against "no active repository" errors (project settings require a repo).
  local ok, project_cfgs = pcall(pcfg.load)
  if ok and type(project_cfgs) == "table" then
    for _, c in ipairs(project_cfgs) do
      opts[#opts+1] = { value = c.id, label = c.name or c.label or c.id, group = "Project" }
    end
  end

  for _, c in ipairs(gcfg.load()) do
    opts[#opts+1] = { value = c.id, label = c.label or c.name, group = "Global" }
  end
  opts[#opts+1] = { value = "__project_settings__", label = "⚙ Project settings…", action = true }

  arbor.ui.set_combo_options{ id = "compile:selector", options = opts, selected = selected }
end

return M
