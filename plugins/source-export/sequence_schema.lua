-- sequence_schema.lua — data shape for a Source Export "Sequence".
--
-- A Sequence is a cross-repo meta-export: an ordered list of (repo, profile)
-- items that all run against a SHARED output root, optionally with
-- matrix-style variable injection (global + per-item overrides).
--
-- Storage is GLOBAL (not per-repo) because a single sequence may fan out
-- profiles that live in different repositories / workspaces. Profiles
-- themselves remain per-repo.
--
-- Shape:
--   {
--     id           : "seq_<hex>"
--     name         : string
--     description  : string?
--     fail_fast    : boolean          -- true → first item failure halts the run
--     output_root  : string?          -- empty = auto: <global_output>/sequence_<safe>_<ts>
--     variables    : [ { key, value } ]    -- applied to every item
--     items        : [ SequenceItem ]      -- ordered, runs top-to-bottom
--     created_at   : int ms
--     updated_at   : int ms
--   }
--
--   SequenceItem = {
--     id            : "it_<hex>"
--     repo_id       : string       -- arbor workspace registry id (cached)
--     repo_path     : string       -- absolute path (cached, used for actual run)
--     repo_label    : string       -- display name (cached for UI)
--     profile_id    : string       -- target profile id inside that repo
--     profile_name  : string       -- cached for UI
--     variables     : [ { key, value } ]    -- override / extend sequence globals
--     allow_failure : boolean                -- item-level (ignored if fail_fast=false)
--     enabled       : boolean                -- skip without removing
--   }
--
-- Caching `repo_label`, `repo_path`, `profile_name` in the item avoids having to
-- re-read every repo's config.json just to render the sequence list. The
-- modal editor refreshes these whenever the user opens the picker.

local M = {}

local function rand_hex(n)
  local chars = "0123456789abcdef"
  local t = {}
  for _ = 1, (n or 8) do
    local i = math.random(1, #chars)
    t[#t+1] = chars:sub(i, i)
  end
  return table.concat(t)
end

function M.now_ms()
  return (os.time() * 1000) + math.random(0, 999)
end

function M.new_id(prefix)
  return (prefix or "seq") .. "_" .. rand_hex(12)
end

function M.new_sequence(name)
  return {
    id          = M.new_id("seq"),
    name        = name or "New Sequence",
    description = "",
    fail_fast   = false,
    output_root = "",
    variables   = {},
    items       = {},
    created_at  = M.now_ms(),
    updated_at  = M.now_ms(),
  }
end

function M.new_item(repo_entry, profile)
  return {
    id            = M.new_id("it"),
    repo_id       = (repo_entry and repo_entry.id)           or "",
    repo_path     = (repo_entry and repo_entry.path)         or "",
    repo_label    = (repo_entry and repo_entry.display_name) or "",
    profile_id    = (profile and profile.id)                 or "",
    profile_name  = (profile and profile.name)               or "",
    variables     = {},
    allow_failure = false,
    enabled       = true,
  }
end

-- Deep-clone via JSON roundtrip (pure-data tree).
function M.clone(obj)
  local s = arbor.json.encode(obj)
  if not s then return nil end
  return (arbor.json.decode(s))
end

-- ── Mutators ────────────────────────────────────────────────────────────────

function M.find_item(sequence, item_id)
  for i, it in ipairs(sequence.items or {}) do
    if it.id == item_id then return it, i end
  end
end

function M.add_item(sequence, item, position)
  sequence.items = sequence.items or {}
  if position == nil or position > #sequence.items then
    sequence.items[#sequence.items+1] = item
  else
    table.insert(sequence.items, math.max(1, position), item)
  end
  sequence.updated_at = M.now_ms()
end

function M.remove_item(sequence, item_id)
  local _, idx = M.find_item(sequence, item_id)
  if idx then
    table.remove(sequence.items, idx)
    sequence.updated_at = M.now_ms()
  end
end

function M.move_item(sequence, item_id, delta)
  local _, idx = M.find_item(sequence, item_id)
  if not idx then return end
  local j = math.max(1, math.min(#sequence.items, idx + (delta or 0)))
  if j == idx then return end
  local it = table.remove(sequence.items, idx)
  table.insert(sequence.items, j, it)
  sequence.updated_at = M.now_ms()
end

return M
