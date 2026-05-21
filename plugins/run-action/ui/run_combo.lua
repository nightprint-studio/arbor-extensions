-- ui/run_combo.lua — Run combo button registration and refresh

local rpcfg  = require("config.run_project")
local rgcfg  = require("config.run_global")
local state  = require("state")

local M = {}

--- Register the run combo button once at plugin load.
function M.register()
  arbor.ui.add_graph_combo({
    id            = "run:selector",
    run_icon      = "Play",
    run_action    = "run:run",
    select_action = "run:select",
    tooltip       = "Run selected application configuration",
    target        = "repo_actions",
    options       = {},
  })
end

--- Rebuild the run combo options from project + global run configs.
--- Running configs are prefixed with "● " so the button and dropdown make it
--- immediately visible which service is live.
--- @param selected string|nil  Value to pre-select (nil = keep current selection).
function M.refresh(selected)
  local opts = {}

  local ok, project_cfgs = pcall(rpcfg.load)
  if ok and type(project_cfgs) == "table" then
    for _, c in ipairs(project_cfgs) do
      local label = c.name or c.label or c.id
      local group = "Project"
      if state.get_running(c.id) then
        label = "● " .. label
        group = "▶ Running"
      end
      opts[#opts+1] = { value = c.id, label = label, group = group }
    end
  end

  for _, c in ipairs(rgcfg.load()) do
    local label = c.name or c.label or c.id
    local group = "Global"
    if state.get_running(c.id) then
      label = "● " .. label
      group = "▶ Running"
    end
    opts[#opts+1] = { value = c.id, label = label, group = group }
  end

  opts[#opts+1] = { value = "__run_project_settings__", label = "⚙ Run settings…", action = true }

  arbor.ui.set_combo_options{ id = "run:selector", options = opts, selected = selected }
end

return M
