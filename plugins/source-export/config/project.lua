-- config/project.lua — per-repo profile CRUD (profiles are repo-scoped, like
-- IntelliJ run/build configurations).

local schema = require("profile_schema")

local M = {}

local KEY_PROFILES = "profiles"
local KEY_SELECTED = "selected_profile"

-- ── Load / save ─────────────────────────────────────────────────────────────

-- `arbor.settings.project.get` raises "no active repository" when the host
-- has no current repo (tombstone tab, fresh app start before a tab is
-- selected, …). Read-side helpers swallow that and return defaults so the
-- combo button + run handlers degrade to "no profile to run" instead of
-- bubbling a runtime error up the hook dispatcher.
function M.load()
  local ok, s = pcall(arbor.settings.project.get, KEY_PROFILES)
  if not ok then return {} end
  local raw = arbor.json.decode(s or "[]")
  return (raw and type(raw) == "table") and raw or {}
end

function M.save(list)
  local s = arbor.json.encode(list or {})
  if s then arbor.settings.project.set(KEY_PROFILES, s) end
end

function M.load_selected()
  local ok, s = pcall(arbor.settings.project.get, KEY_SELECTED)
  if not ok then return "" end
  return s or ""
end

function M.save_selected(id)
  arbor.settings.project.set(KEY_SELECTED, id or "")
end

function M.find(id)
  if not id or id == "" then return nil end
  for _, p in ipairs(M.load()) do
    if p.id == id then return p end
  end
end

-- ── Mutators ────────────────────────────────────────────────────────────────

function M.upsert(profile)
  if not profile or not profile.id then return end
  profile.updated_at = schema.now_ms()
  local list = M.load()
  local found = false
  for i, p in ipairs(list) do
    if p.id == profile.id then list[i] = profile; found = true; break end
  end
  if not found then list[#list+1] = profile end
  M.save(list)
end

function M.remove(id)
  local list, out = M.load(), {}
  for _, p in ipairs(list) do
    if p.id ~= id then out[#out+1] = p end
  end
  M.save(out)
  if M.load_selected() == id then M.save_selected("") end
end

function M.duplicate(id)
  local src = M.find(id)
  if not src then return nil end
  local copy = schema.clone(src)
  if not copy then return nil end
  copy.id   = schema.new_id("cfg")
  copy.name = (copy.name or "Profile") .. " (copy)"
  copy.created_at = schema.now_ms()
  copy.updated_at = copy.created_at
  -- Fresh ids on inner stages/steps so they are independent after duplicate.
  for _, st in ipairs(copy.stages or {}) do
    st.id = schema.new_id("stg")
    for _, s in ipairs(st.steps or {}) do s.id = schema.new_id("stp") end
  end
  local list = M.load()
  list[#list+1] = copy
  M.save(list)
  return copy
end

return M
