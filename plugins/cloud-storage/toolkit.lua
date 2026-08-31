-- toolkit.lua — the shared object-storage logic, reached the way a plugin reaches any package.
--
-- `cloud-toolkit` exports the parts that are the same for every store: splitting keys, matching
-- globs, planning ranges, planning a sync, ordering split parts. The providers link the same
-- crate directly (a guest cannot call another guest), so a key sorted here and a key sorted
-- inside `cloud-gcs` are sorted by the same code.
--
-- ## Why the fallbacks
--
-- Every function here answers even when the package is absent, because the panel must not stop
-- working over a missing dependency — a browse that cannot split a key would show nothing at
-- all. The fallbacks are deliberately the SIMPLE reading: plain string work, no glob subtleties,
-- no sync planning. When the toolkit is missing, `sync_plan` says so instead of guessing, since
-- a wrong sync plan deletes files.

local M = {}

local INTERFACE = "cloud-util"
local ID        = "core"

--- Call the toolkit. Returns `(value, nil)` or `(nil, err)` — never raises, because most
--- callers here have a local answer to fall back on.
local function call(method, args)
  local ok, result = pcall(function()
    return arbor.ext.call{ interface = INTERFACE, id = ID, method = method, args = args or {} }
  end)
  if not ok then return nil, tostring(result) end
  return result, nil
end

--- Whether the package is installed and enabled.
function M.available()
  for _, e in ipairs(arbor.ext.list() or {}) do
    if e.interface == INTERFACE and e.id == ID then return true end
  end
  return false
end

-- ── Keys ────────────────────────────────────────────────────────────────────

function M.split_key(key)
  local out = call("split-key", { key or "" })
  if out then return out[1], out[2] end
  -- The prefix keeps its trailing slash: without it, `prefix=logs` also lists `logs-archive/`.
  local dir, name = (key or ""):match("^(.*/)([^/]*)$")
  return dir or "", name or (key or "")
end

function M.name_of(key)
  local _, name = M.split_key(key)
  return name
end

function M.join_key(prefix, name)
  local out = call("join-key", { prefix or "", name or "" })
  if out then return out end
  if (prefix or "") == "" then return (name or ""):gsub("^/+", "") end
  return (prefix:gsub("/+$", "")) .. "/" .. ((name or ""):gsub("^/+", ""))
end

function M.parent_prefix(prefix)
  local out = call("parent-prefix", { prefix or "" })
  if out then return out end
  local trimmed = (prefix or ""):gsub("/+$", "")
  return trimmed:match("^(.*/)") or ""
end

-- ── Matching ────────────────────────────────────────────────────────────────

--- Whether `key` matches `pattern`. `?` is one character and `*` any run, neither crossing
--- `/`; `**` crosses.
function M.glob_match(pattern, key)
  local out = call("glob-match", { pattern or "", key or "" })
  if out ~= nil then return out and true or false end
  -- The fallback is a plain substring test, and it is deliberately not a hand-rolled glob:
  -- a second, subtly different matcher is how a search starts returning different results
  -- depending on which packages happen to be installed.
  local needle = (pattern or ""):gsub("%*+", ""):gsub("%?", "")
  return needle == "" or (key or ""):find(needle, 1, true) ~= nil
end

-- ── Transfers ───────────────────────────────────────────────────────────────

--- The byte ranges a transfer of `size` should ask for, at most `chunk` each.
function M.plan_ranges(size, chunk)
  local out = call("plan-ranges", { size or 0, chunk or 0 })
  if out then return out end
  local ranges = {}
  local step = (chunk and chunk > 0) and chunk or (size or 0)
  local at = 0
  while at < (size or 0) do
    local stop = math.min(at + step, size)
    ranges[#ranges + 1] = { start = at, ["end"] = stop }
    at = stop
  end
  return ranges
end

--- Order split parts for concatenation: `"natural"` (digits as numbers) or `"date"`.
function M.order_chunks(chunks, order)
  local out = call("order-chunks", { chunks or {}, order or "natural" })
  if out then return out end
  -- Lexicographic, which is the order that put `part10` before `part2` in the first place.
  -- Said plainly rather than pretended otherwise: the caller shows this list for confirmation.
  local copy = {}
  for i, c in ipairs(chunks or {}) do copy[i] = c end
  table.sort(copy, function(a, b) return (a.key or "") < (b.key or "") end)
  return copy
end

--- What a download would create, update, skip or delete — decided before anything moves.
---
--- Returns `(plan, nil)` or `(nil, err)`. No fallback: guessing a sync plan is how files get
--- overwritten or deleted for a reason nobody can reconstruct.
function M.sync_plan(remote, local_files, policy)
  local out, err = call("sync-plan", { remote or {}, local_files or {}, policy })
  if err then
    return nil, "The cloud-toolkit package is needed to plan a sync (" .. err .. ")"
  end
  return out, nil
end

return M
