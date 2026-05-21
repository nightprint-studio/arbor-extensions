-- settings.lua — plugin-wide preferences and the settings panel.
--
-- Persistent state lives under `arbor.settings.global` (no per-repo state).
-- The panel is opened via the gear icon in the Plugin Manager and edits the
-- same backing keys.

local M = {}

local PANEL_ID = "main"

function M.parallel_downloads()
  local v = tonumber(arbor.settings.global.get("parallel_downloads") or "")
  if not v or v < 1 then v = 4 end
  if v > 16 then v = 16 end
  return v
end

function M.set_parallel_downloads(v)
  v = tonumber(v) or 4
  if v < 1 then v = 1 end
  if v > 16 then v = 16 end
  arbor.settings.global.set("parallel_downloads", tostring(math.floor(v)))
end

-- Maximum number of entries the streaming list will accumulate before
-- truncating. Hot path on huge folders — every row is a Lua table with
-- path/size/etag/mtime/content_type, so at ~6KB each in memory you trade
-- about 6MB of RAM per 1000 rows. Cap kept generous-but-finite so the
-- worst case stays bounded; users with multi-million-key buckets should
-- refine the breadcrumb instead of bumping this.
local LIST_CAP_MIN     = 500
local LIST_CAP_MAX     = 50000
local LIST_CAP_DEFAULT = 5000

function M.list_hard_cap()
  local v = tonumber(arbor.settings.global.get("list_hard_cap") or "")
  if not v or v < LIST_CAP_MIN then v = LIST_CAP_DEFAULT end
  if v > LIST_CAP_MAX then v = LIST_CAP_MAX end
  return math.floor(v)
end

function M.set_list_hard_cap(v)
  v = tonumber(v) or LIST_CAP_DEFAULT
  if v < LIST_CAP_MIN then v = LIST_CAP_MIN end
  if v > LIST_CAP_MAX then v = LIST_CAP_MAX end
  arbor.settings.global.set("list_hard_cap", tostring(math.floor(v)))
end

-- ── Settings panel ─────────────────────────────────────────────────────────

function M.register()
  arbor.ui.settings.panel({
    id           = PANEL_ID,
    title        = "Cloud Storage · Preferences",
    icon         = "Cloud",
    width        = "560px",
    submit_label = "Save",
    cancel_label = "Cancel",
    on_load      = "cloud:settings-refresh",
  })

  -- One section with the only knob we expose for v1.
  M.contribute_sections()
end

function M.contribute_sections()
  arbor.ui.contribute("cloud-storage:settings:section", {
    id      = "transfers",
    payload = {
      label    = "Transfers",
      icon     = "Download",
      priority = 100,
      on_save  = "cloud:settings-save",
      nodes = {
        { type = "label",
          text = "How many sub-downloads run in parallel during bulk operations "
              .. "(Download N files, chunk download, sync down/up)." },
        { type = "number", name = "parallel_downloads",
          label = "Parallel downloads",
          min = 1, max = 16, step = 1,
          default = M.parallel_downloads() },
      },
    },
  })

  arbor.ui.contribute("cloud-storage:settings:section", {
    id      = "browser",
    payload = {
      label    = "Browser",
      icon     = "FolderTree",
      priority = 200,
      on_save  = "cloud:settings-save",
      nodes = {
        { type = "label",
          text = "How many entries the sidebar will load from one folder "
              .. "before truncating. Each row is a small Lua table — at "
              .. "the default of 5000 expect ~30 MB extra RAM; pushing the "
              .. "cap to 50000 can grow it past 150 MB on big folders. If "
              .. "you hit the cap, refine the breadcrumb or use the remote "
              .. "search instead of bumping this." },
        { type = "number", name = "list_hard_cap",
          label = "Max entries per folder",
          min = 500, max = 50000, step = 500,
          default = M.list_hard_cap() },
      },
    },
  })
end

return M
