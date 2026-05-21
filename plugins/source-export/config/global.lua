-- config/global.lua — plugin-wide settings (output folder, cleanup policy, templates).
-- Stored via arbor.settings.global (JSON, one key per concept).

local schema = require("profile_schema")

local M = {}

local KEY_OUTPUT_FOLDER   = "output_folder"
local KEY_KEEP_LAST_N     = "keep_last_n_runs"
local KEY_JU_BIN          = "ju_bin"
local KEY_TEMPLATES       = "templates"

local DEFAULT_KEEP_N = 5

-- ── Output folder ───────────────────────────────────────────────────────────

function M.get_output_folder()
  local v = arbor.settings.global.get(KEY_OUTPUT_FOLDER) or ""
  if v == "" then
    -- Fallback: OS temp dir + a stable "arbor-source-export" subfolder so runs
    -- from the same session cluster together.
    local tmp = os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
    local sep = arbor.meta.os() == "windows" and "\\" or "/"
    return tmp .. sep .. "arbor-source-export"
  end
  return v
end

function M.set_output_folder(v) arbor.settings.global.set(KEY_OUTPUT_FOLDER, v or "") end

-- ── Cleanup policy ──────────────────────────────────────────────────────────

function M.get_keep_last_n()
  local v = tonumber(arbor.settings.global.get(KEY_KEEP_LAST_N) or "") or DEFAULT_KEEP_N
  if v < 0 then v = 0 end
  return v
end

function M.set_keep_last_n(n)
  arbor.settings.global.set(KEY_KEEP_LAST_N, tostring(n or DEFAULT_KEEP_N))
end

-- ── ju binary path ──────────────────────────────────────────────────────────

function M.get_ju_bin() return arbor.settings.global.get(KEY_JU_BIN) or "" end
function M.set_ju_bin(v) arbor.settings.global.set(KEY_JU_BIN, v or "") end

-- ── Templates ───────────────────────────────────────────────────────────────
-- Templates are plugin-global: used to seed new profiles in any repo.

function M.load_templates()
  local raw = arbor.json.decode(arbor.settings.global.get(KEY_TEMPLATES) or "[]")
  return (raw and type(raw) == "table") and raw or {}
end

function M.save_templates(list)
  local s = arbor.json.encode(list or {})
  if s then arbor.settings.global.set(KEY_TEMPLATES, s) end
end

function M.find_template(id)
  if not id or id == "" then return nil end
  for _, t in ipairs(M.load_templates()) do
    if t.id == id then return t end
  end
end

function M.add_template(tpl)
  local list = M.load_templates()
  list[#list+1] = tpl
  M.save_templates(list)
end

function M.remove_template(id)
  local list, out = M.load_templates(), {}
  for _, t in ipairs(list) do
    if t.id ~= id then out[#out+1] = t end
  end
  M.save_templates(out)
end

function M.upsert_template(tpl)
  if not tpl or not tpl.id then return end
  local list = M.load_templates()
  local found = false
  for i, t in ipairs(list) do
    if t.id == tpl.id then list[i] = tpl; found = true; break end
  end
  if not found then list[#list+1] = tpl end
  M.save_templates(list)
end

-- Build a fresh profile seeded from a template (deep-cloned stages).
function M.instantiate_template(template_id, new_name)
  local tpl = M.find_template(template_id)
  if not tpl then return nil end
  local profile = schema.new_profile(new_name or (tpl.name .. " (copy)"))
  local cloned_stages = schema.clone(tpl.stages or {}) or {}
  -- Reassign fresh ids so duplicates don't collide.
  for _, st in ipairs(cloned_stages) do
    st.id = schema.new_id("stg")
    for _, s in ipairs(st.steps or {}) do s.id = schema.new_id("stp") end
  end
  profile.stages = cloned_stages
  return profile
end

return M
