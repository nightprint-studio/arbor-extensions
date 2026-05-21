-- ui/combo.lua — ActivityBar / RepoActions split-button for Source Export.
--
-- Entries in the dropdown (grouped):
--   [profiles…]  one per repo-scoped profile
--   [actions]    New profile / Edit configurations
--
-- Plugin-wide settings are reached via the Plugin Manager modal — keeping
-- them out of this combo matches the convention used by every other plugin.
--
-- Sequences live EXCLUSIVELY in the right-side sidebar — keeping them out of
-- the combo enforces a clean separation: the toolbar is per-repo
-- (profiles); the sidebar is cross-repo (sequences).
--
-- The primary click (run_action) triggers the currently selected profile.
-- The select_action just persists the selection.

local pcfg = require("config.project")

local M = {}

-- Magic values — picked so they cannot collide with real config ids.
M.NEW_PROFILE     = "__new_profile__"
M.EDIT_CONFIGS    = "__edit_configs__"

function M.register()
  arbor.ui.add_graph_combo({
    id            = "source-export:selector",
    run_icon      = "Share2",          -- export-ish icon
    run_action    = "source-export:run",
    select_action = "source-export:select",
    tooltip       = "Run selected export profile",
    target        = "repo_actions",
    options       = {},
  })
end

function M.refresh(selected)
  local opts = {}
  local ok, profiles = pcall(pcfg.load)
  if ok and type(profiles) == "table" then
    for _, p in ipairs(profiles) do
      opts[#opts+1] = { value = p.id, label = p.name or p.id, group = "Profiles" }
    end
  end
  if #opts == 0 then
    opts[#opts+1] = { value = M.NEW_PROFILE,  label = "⊕ New profile…",      action = true }
  else
    opts[#opts+1] = { value = M.NEW_PROFILE,  label = "⊕ New profile…",              action = true }
    opts[#opts+1] = { value = M.EDIT_CONFIGS, label = "⚙ Edit configurations…",      action = true }
  end

  local sel = selected or pcfg.load_selected()
  -- Only preserve `selected` if it points at a real profile.
  if sel ~= "" then
    local hit = false
    for _, o in ipairs(opts) do
      if o.value == sel then hit = true; break end
    end
    if not hit then sel = nil end
  else
    sel = nil
  end

  arbor.ui.set_combo_options{ id = "source-export:selector", options = opts, selected = sel }
end

return M
