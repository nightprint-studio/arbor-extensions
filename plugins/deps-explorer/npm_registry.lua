-- npm_registry.lua — Resolve "what's the latest version on npmjs.org?" for
-- many package names. Mirrors maven_central.lua's design exactly:
--   · Native HTTP via arbor.http.get (no Jobs panel pollution).
--   · Per-package URL — npm registry has a /<package>/latest endpoint that
--     returns a tiny JSON document with { name, version, ... }.
--   · Persistent in-process cache (arbor.settings.global) with separate
--     TTLs for hits (7 days) and misses (24 h).
--   · Concurrency capped at MAX_INFLIGHT so first-time analyses don't
--     open a connection per package against npmjs.org all at once.
--
-- URL format:
--   https://registry.npmjs.org/<package_name>/latest
--   Scoped packages keep the slash unencoded — registry handles it
--   directly (e.g. /@types/node/latest).
--
-- Response (relevant slice):
--   { "name": "lodash", "version": "4.17.21", "description": "...", ... }

local M = {}

local CACHE_KEY        = "npm_registry_cache"
local CACHE_TTL_SECS   = 7 * 24 * 60 * 60
local MISS_TTL_SECS    = 24 * 60 * 60
local CACHE_GC_SECS    = 90 * 24 * 60 * 60
local HTTP_TIMEOUT_MS  = 8000
local MAX_INFLIGHT     = 8
local NULL_LATEST      = ""

-- ── Cache (settings-backed) ─────────────────────────────────────────────────

local _cache = nil

local function load_cache()
  if _cache ~= nil then return _cache end
  local ok, val = pcall(arbor.settings.global.get, CACHE_KEY)
  _cache = (ok and type(val) == "table") and val or {}
  return _cache
end

local function save_cache()
  if _cache == nil then return end
  local now = os.time()
  for k, v in pairs(_cache) do
    if type(v) ~= "table" or type(v.at) ~= "number" or (now - v.at) > CACHE_GC_SECS then
      _cache[k] = nil
    end
  end
  pcall(arbor.settings.global.set, CACHE_KEY, _cache)
end

local function cache_get_fresh(name)
  local entry = load_cache()[name]
  if type(entry) ~= "table" then return nil end
  local age = os.time() - (entry.at or 0)
  local ttl = (entry.latest == NULL_LATEST or entry.latest == nil) and MISS_TTL_SECS or CACHE_TTL_SECS
  if age > ttl then return nil end
  return entry.latest
end

local function cache_put(name, latest)
  load_cache()[name] = { latest = latest or NULL_LATEST, at = os.time() }
end

-- Re-export the maven_central comparator so callers don't need to import
-- both modules. Identical semver-ish logic — npm versions follow the same
-- numeric-segments-with-suffix pattern.
function M.is_outdated(current, latest)
  -- Empty `current` = package isn't installed locally (typical for missing
  -- optional deps); refuse to flag those as outdated.
  if not current or current == "" or not latest or latest == NULL_LATEST or current == latest then
    return false
  end
  local function parts(v)
    local out = {}
    for seg in v:gmatch("[^%.%-]+") do out[#out + 1] = seg end
    return out
  end
  local a, b = parts(current), parts(latest)
  for i = 1, math.max(#a, #b) do
    local pa, pb = a[i] or "0", b[i] or "0"
    local na, nb = tonumber(pa), tonumber(pb)
    if na and nb then
      if na ~= nb then return na < nb end
    else
      if pa ~= pb then return tostring(pa) < tostring(pb) end
    end
  end
  return false
end

-- ── Single-package fetcher ───────────────────────────────────────────────────

local function build_url(name)
  -- The npm registry accepts scoped names with the slash unencoded
  -- (`/@types/node/latest` works directly).
  return "https://registry.npmjs.org/" .. name .. "/latest"
end

local function extract_latest(json_body)
  if not json_body or json_body == "" then return nil end
  local ok, parsed = pcall(arbor.json.decode, json_body)
  if ok and type(parsed) == "table" and type(parsed.version) == "string" and parsed.version ~= "" then
    return parsed.version
  end
  -- Regex fallback in case arbor.json fails for any reason.
  return json_body:match('"version"%s*:%s*"([^"]+)"')
end

-- ── Concurrency-limited dispatcher ───────────────────────────────────────────

local _inflight = 0
local _queue    = {}

local function pump()
  while _inflight < MAX_INFLIGHT and #_queue > 0 do
    local job = table.remove(_queue, 1)
    _inflight = _inflight + 1
    arbor.http.get(job.url, { timeout_ms = HTTP_TIMEOUT_MS }, function(response)
      _inflight = _inflight - 1
      local latest      = nil
      local cache_value = nil
      if response then
        if response.ok and response.body then
          latest      = extract_latest(response.body)
          cache_value = latest or NULL_LATEST
        elseif response.status == 404 then
          cache_value = NULL_LATEST   -- private/removed/typoed package
        else
          arbor.log.warn(string.format(
            "[deps-explorer/npm-registry] %s -> HTTP %d%s",
            job.name, response.status or 0,
            response.error and (" — " .. response.error) or ""))
        end
      end
      if cache_value ~= nil then cache_put(job.name, cache_value) end
      pcall(job.on_done, latest)
      pump()
    end)
  end
end

local function enqueue(name, on_done)
  table.insert(_queue, { url = build_url(name), name = name, on_done = on_done })
  pump()
end

-- ── Public ───────────────────────────────────────────────────────────────────

-- Lookup the latest version for many packages. on_complete(results) gets a
-- `name → latest` map covering every input name (cached + fetched).
function M.fetch_many(names, on_complete)
  if #names == 0 then pcall(on_complete, {}); return end

  local results = {}
  local misses  = {}
  local seen    = {}
  for _, n in ipairs(names) do
    if type(n) == "string" and n ~= "" and not seen[n] then
      seen[n] = true
      local cached = cache_get_fresh(n)
      if cached ~= nil then
        if cached ~= NULL_LATEST then results[n] = cached end
      else
        misses[#misses + 1] = n
      end
    end
  end

  if #misses == 0 then pcall(on_complete, results); return end

  local pending = #misses
  for _, n in ipairs(misses) do
    enqueue(n, function(latest)
      if latest then results[n] = latest end
      pending = pending - 1
      if pending == 0 then
        save_cache()
        pcall(on_complete, results)
      end
    end)
  end
end

function M.invalidate_misses()
  local c = load_cache()
  for k, v in pairs(c) do
    if type(v) == "table" and (v.latest == nil or v.latest == NULL_LATEST) then
      c[k] = nil
    end
  end
  save_cache()
end

function M.clear_cache()
  _cache = {}
  save_cache()
end

return M
