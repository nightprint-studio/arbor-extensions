-- import_export.lua — JSON import / export of export profiles.
-- Files are just the profile shape (see profile_schema.lua) serialized as JSON.

local schema = require("profile_schema")
local pcfg   = require("config.project")
local gcfg   = require("config.global")

local M = {}

local EXPORTS_SUBDIR = "arbor-source-export-profiles"

local function exports_dir()
  local sep = arbor.meta.os() == "windows" and "\\" or "/"
  local home = os.getenv("HOME") or os.getenv("USERPROFILE") or ""
  if home == "" then
    return (os.getenv("TMPDIR") or os.getenv("TEMP") or "/tmp") .. sep .. EXPORTS_SUBDIR
  end
  return home .. sep .. "Documents" .. sep .. EXPORTS_SUBDIR
end

-- ── Export ──────────────────────────────────────────────────────────────────

function M.export_profile(profile_id)
  local p = pcfg.find(profile_id)
  if not p then
    arbor.notify{ message = "Profile not found", level = "error" }
    return
  end
  local dir = exports_dir()
  local sep = arbor.meta.os() == "windows" and "\\" or "/"
  local safe_name = (p.name or p.id):gsub("[^%w%-_.]+", "_")
  local file = dir .. sep .. safe_name .. "_" .. os.time() .. ".json"
  local payload = {
    arbor_plugin = "source-export",
    arbor_plugin_version = "0.1.0",
    kind = "profile",
    exported_at = schema.now_ms(),
    profile = p,
  }
  -- arbor.fs.write creates parent dirs automatically and raises on failure.
  local ok, err = pcall(function()
    arbor.fs.write(file, arbor.json.encode(payload) or "{}")
  end)
  if ok then
    arbor.notify{ title = "Profile exported", message = file, level = "success" }
  else
    arbor.notify{ title = "Export failed", message = tostring(err or "?"), level = "error" }
  end
end

-- ── Import ──────────────────────────────────────────────────────────────────
-- MVP path: the user picks a JSON file via a file picker we don't yet have
-- exposed for plugins. Until then we read a conventional path
-- `<exports_dir>/profile.json` — the UI will expose a real picker once the
-- filesystem picker plugin API lands.

function M.import_profile(path)
  local src = path or (exports_dir() .. "/profile.json")
  local ok, content = pcall(function() return arbor.fs.read(src) end)
  if not ok or not content or content == "" then
    arbor.notify{ title = "Import failed", message = "Cannot read " .. src .. ": " .. tostring(content or "?"), level = "error" }
    return
  end
  local data = arbor.json.decode(content)
  if type(data) ~= "table" or data.arbor_plugin ~= "source-export" then
    arbor.notify{ title = "Import failed", message = "Not a Source Export profile JSON", level = "error" }
    return
  end
  local p = data.profile
  if type(p) ~= "table" or not p.name then
    arbor.notify{ title = "Import failed", message = "Malformed profile payload", level = "error" }
    return
  end

  -- Collision handling: auto-rename with timestamp suffix.
  local existing = pcfg.find(p.id)
  if existing then
    p.id   = schema.new_id("cfg")
    p.name = p.name .. "_imported_" .. os.time()
  end
  p.created_at = p.created_at or schema.now_ms()
  p.updated_at = schema.now_ms()

  pcfg.upsert(p)
  arbor.notify{ title = "Profile imported", message = p.name, level = "success" }
  return p
end

-- ── Stage export / import (single group within the active profile) ─────────
-- Payload kind = "stage" (vs kind = "profile" above) so the import side can
-- refuse a profile JSON dumped into a stage slot and vice-versa.

function M.export_stage(profile_id, stage_id)
  local p = pcfg.find(profile_id)
  if not p then
    arbor.notify{ message = "Profile not found", level = "error" }
    return
  end
  local stage
  for _, s in ipairs(p.stages or {}) do
    if s.id == stage_id then stage = s; break end
  end
  if not stage then
    arbor.notify{ message = "Group not found", level = "error" }
    return
  end

  local dir = exports_dir()
  local sep = arbor.meta.os() == "windows" and "\\" or "/"
  local safe_profile = (p.name     or p.id    ):gsub("[^%w%-_.]+", "_")
  local safe_stage   = (stage.name or stage.id):gsub("[^%w%-_.]+", "_")
  local file = dir .. sep .. safe_profile .. "__" .. safe_stage .. "_" .. os.time() .. ".json"
  local payload = {
    arbor_plugin = "source-export",
    arbor_plugin_version = "0.1.0",
    kind = "stage",
    exported_at = schema.now_ms(),
    source_profile = { id = p.id, name = p.name },
    stage = stage,
  }
  local ok, err = pcall(function()
    arbor.fs.write(file, arbor.json.encode(payload) or "{}")
  end)
  if ok then
    arbor.notify{ title = "Group exported", message = file, level = "success" }
  else
    arbor.notify{ title = "Export failed", message = tostring(err or "?"), level = "error" }
  end
end

function M.import_stage(profile_id, path)
  local p = pcfg.find(profile_id)
  if not p then
    arbor.notify{ message = "Profile not found", level = "error" }
    return
  end
  -- Same MVP convention as profile import: read from a conventional file
  -- (`<exports_dir>/stage.json`) until the file picker plugin API lands.
  local src = path or (exports_dir() .. (arbor.meta.os() == "windows" and "\\" or "/") .. "stage.json")
  local ok, content = pcall(function() return arbor.fs.read(src) end)
  if not ok or not content or content == "" then
    arbor.notify{ title = "Import failed", message = "Cannot read " .. src .. ": " .. tostring(content or "?"), level = "error" }
    return
  end
  local data = arbor.json.decode(content)
  if type(data) ~= "table" or data.arbor_plugin ~= "source-export" or data.kind ~= "stage" then
    arbor.notify{ title = "Import failed", message = "Not a Source Export group JSON", level = "error" }
    return
  end
  local st = data.stage
  if type(st) ~= "table" then
    arbor.notify{ title = "Import failed", message = "Malformed group payload", level = "error" }
    return
  end
  -- Refresh ids so the imported stage + its steps don't collide with existing
  -- ones (important: stable ids drive selection state + action targets).
  st.id = schema.new_id("stg")
  for _, step in ipairs(st.steps or {}) do
    step.id = schema.new_id("stp")
  end
  schema.add_stage(p, st)
  pcfg.upsert(p)
  arbor.notify{ title = "Group imported", message = st.name or st.id, level = "success" }
  return st
end

-- ── Export as template (plugin-global) ──────────────────────────────────────

function M.save_profile_as_template(profile_id, template_name)
  local p = pcfg.find(profile_id)
  if not p then return end
  local tpl = schema.new_template(template_name or (p.name .. " (template)"))
  tpl.stages = schema.clone(p.stages or {}) or {}
  -- Fresh ids on template copies so subsequent instantiation stays clean.
  for _, st in ipairs(tpl.stages) do
    st.id = schema.new_id("stg")
    for _, s in ipairs(st.steps or {}) do s.id = schema.new_id("stp") end
  end
  gcfg.upsert_template(tpl)
  arbor.notify{ title = "Saved as template", message = tpl.name, level = "success" }
  return tpl
end

return M
