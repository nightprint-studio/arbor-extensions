-- remote_profiles.lua — read profiles from a repo OTHER than the active one.
--
-- The sequence editor needs to show profiles from every known repo (not just
-- the active tab). `arbor.settings.project.*` is scoped to the active repo,
-- so we fall back to reading the plugin's per-repo JSON store directly.
-- Storage layout is stable:  <repo>/.arbor/plugins/source-export/project.json
--
-- All helpers return best-effort results: any read failure yields `{}` rather
-- than raising. The editor filters out empty repos before rendering.

local M = {}

local IS_WIN = arbor.meta.os() == "windows"
local PSEP   = IS_WIN and "\\" or "/"

local function join(a, b) return (a or "") .. PSEP .. (b or "") end

local function project_json_path(repo_path)
  return join(join(join(join(repo_path, ".arbor"), "plugins"), "source-export"),
              "project.json")
end

--- Load the full profile list for a repo by reading its project.json file.
--- @param repo_path string  absolute repo path
--- @return table            list of profiles (empty on any error / missing file)
function M.load_profiles(repo_path)
  if not repo_path or repo_path == "" then return {} end
  local path = project_json_path(repo_path)
  local ok, content = pcall(function() return arbor.fs.read(path) end)
  if not ok or type(content) ~= "string" or content == "" then return {} end

  -- project.json holds a { "<key>": "<json_string>" } object. The profile list
  -- lives under the "profiles" key, already JSON-stringified (mirrors how
  -- arbor.settings stores values as strings).
  local store_ok, store = pcall(arbor.json.decode, content)
  if not store_ok or type(store) ~= "table" then return {} end
  local raw = store.profiles
  if type(raw) ~= "string" or raw == "" then return {} end
  local list_ok, list = pcall(arbor.json.decode, raw)
  if not list_ok or type(list) ~= "table" then return {} end
  return list
end

--- List every known repo + its profiles, suitable for the sequence picker.
---
--- Returns:  [ { repo_id, repo_path, repo_label, remote_url, profiles = [...] } ]
--- Sorted alphabetically by display name. Repos with zero profiles are
--- included (the picker shows a greyed-out "No profiles" row so the user
--- sees why a repo has nothing to add).
function M.list_all_repos_with_profiles()
  local out = {}
  local ok, repos = pcall(function() return arbor.workspace.list_repos() end)
  if not ok or type(repos) ~= "table" then return out end

  for _, r in ipairs(repos) do
    local profiles = M.load_profiles(r.path)
    out[#out+1] = {
      repo_id    = r.id or "",
      repo_path  = r.path or "",
      repo_label = r.display_name or r.path or r.id or "?",
      remote_url = r.remote_url or "",
      profiles   = profiles,
    }
  end

  table.sort(out, function(a, b)
    return (a.repo_label or ""):lower() < (b.repo_label or ""):lower()
  end)
  return out
end

--- Resolve a profile by repo path + id, reading on-disk state. Used at
--- sequence run time so the run always picks up the latest edit to the
--- referenced profile, not a stale cached copy.
function M.find_profile(repo_path, profile_id)
  if not repo_path or not profile_id or profile_id == "" then return nil end
  for _, p in ipairs(M.load_profiles(repo_path)) do
    if p.id == profile_id then return p end
  end
  return nil
end

return M
