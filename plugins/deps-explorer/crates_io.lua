-- crates_io.lua — Resolve "what's the latest version on crates.io?" for many
-- crate names. Mirrors maven_central.lua / npm_registry.lua exactly: native
-- HTTP via arbor.http.get (no Jobs panel pollution), persistent settings-
-- backed cache with split TTLs, in-process concurrency limit.
--
-- URL format:
--   https://crates.io/api/v1/crates/<name>
--
-- Response (relevant slice — `crate.max_stable_version` is what we surface
-- for the "outdated" check; we explicitly avoid `max_version` because that
-- can include pre-releases and yanked versions):
--   { "crate": { "id": "serde", "max_stable_version": "1.0.193", … }, … }
--
-- crates.io's user-agent policy asks for a contact identifier; arbor.http.get
-- sets `arbor-plugin/1.0` which is generic but acceptable for the very low
-- request volume we generate (one per unique crate, cached for 7 days).

local M = {}

local CACHE_KEY        = "crates_io_cache"
local CACHE_TTL_SECS   = 7 * 24 * 60 * 60
local MISS_TTL_SECS    = 24 * 60 * 60
local CACHE_GC_SECS    = 90 * 24 * 60 * 60
local HTTP_TIMEOUT_MS  = 8000
local MAX_INFLIGHT     = 6                 -- a touch lower than npm/maven; crates.io is more sensitive to bursts
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

function M.is_outdated(current, latest)
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

local function build_url(name)
  return "https://crates.io/api/v1/crates/" .. name
end

local function extract_latest(json_body)
  if not json_body or json_body == "" then return nil end
  local ok, parsed = pcall(arbor.json.decode, json_body)
  if ok and type(parsed) == "table" and type(parsed.crate) == "table" then
    local c = parsed.crate
    if type(c.max_stable_version) == "string" and c.max_stable_version ~= "" then
      return c.max_stable_version
    end
    if type(c.max_version) == "string" and c.max_version ~= "" then
      return c.max_version
    end
  end
  -- Regex fallback.
  return json_body:match('"max_stable_version"%s*:%s*"([^"]+)"')
      or json_body:match('"max_version"%s*:%s*"([^"]+)"')
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
          cache_value = NULL_LATEST   -- typoed / yanked / never published
        else
          arbor.log.warn(string.format(
            "[deps-explorer/crates-io] %s -> HTTP %d%s",
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
