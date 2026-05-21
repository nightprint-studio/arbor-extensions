-- maven_central.lua — Resolve "what's the latest version on Maven Central?"
-- for many (group, artifact) coordinates.
--
-- We talk to Maven Central using the SAME endpoint Maven itself uses
-- (`mvn versions:display-dependency-updates`) and IntelliJ's classic Maven
-- plugin: the `maven-metadata.xml` file under each artifact's directory in
-- the public repository. Compared to the Solr search API this is:
--   · Predictable: stable XML schema published since Maven 1, never
--     returns "0 docs" silently on a successful HTTP — either the file
--     exists (200) or the artifact isn't on Central (404).
--   · Per-artifact: one URL per (group, artifact). No URL-encoding tricks,
--     no Lucene query syntax, no boolean OR quirks.
--   · Cacheable: Maven Central serves these with long Cache-Control
--     headers and edge-CDNs them aggressively.
--
-- URL format:
--   https://repo1.maven.org/maven2/<groupId/with/slashes>/<artifactId>/maven-metadata.xml
--
-- Response (relevant slice):
--   <metadata>
--     <groupId>org.springframework</groupId>
--     <artifactId>spring-core</artifactId>
--     <versioning>
--       <latest>5.3.20</latest>
--       <release>5.3.20</release>
--       <versions> ... </versions>
--     </versioning>
--   </metadata>
--
-- We extract <latest> (preferred) or <release> as fallback. SNAPSHOT-only
-- artifacts have no <latest> in the metadata; we don't care about those for
-- the "outdated" check anyway.
--
-- All requests go through `arbor.http.get` (native reqwest), so they do
-- NOT create Jobs panel entries. A small semaphore caps concurrency so
-- the first analysis on a 200-dep project doesn't open 200 simultaneous
-- TCP connections. With caching, subsequent analyses are instant.

local M = {}

local CACHE_KEY        = "mvn_central_cache"
local CACHE_TTL_SECS   = 7 * 24 * 60 * 60       -- found entries: 7 days
local MISS_TTL_SECS    = 24 * 60 * 60           -- "not found" entries: 1 day (so glitches self-heal fast)
local CACHE_GC_SECS    = 90 * 24 * 60 * 60      -- 90 days: max age before purge
local HTTP_TIMEOUT_MS  = 8000
local MAX_INFLIGHT     = 8                       -- concurrent HTTP requests
local NULL_LATEST      = ""                      -- sentinel for "not on Central"

-- ── In-memory cache (lazy-loaded from settings) ──────────────────────────────

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

local function cache_get_fresh(key)
  local c = load_cache()
  local entry = c[key]
  if type(entry) ~= "table" then return nil end
  local age = os.time() - (entry.at or 0)
  -- Found entries get the long TTL; misses get the short TTL so transient
  -- failures (network blip, Solr quirk) recover within a day.
  local ttl = (entry.latest == NULL_LATEST or entry.latest == nil) and MISS_TTL_SECS or CACHE_TTL_SECS
  if age > ttl then return nil end
  return entry.latest -- may be NULL_LATEST sentinel
end

local function cache_put(key, latest)
  local c = load_cache()
  c[key] = { latest = latest or NULL_LATEST, at = os.time() }
end

-- ── Version comparison ───────────────────────────────────────────────────────

function M.is_outdated(current, latest)
  -- Empty `current` (artifact not installed locally — e.g. an optional npm
  -- dep whose binary isn't for this OS) MUST NOT compare as outdated. The
  -- previous version did, because parts("") yielded {} which compared as
  -- 0.0.0 against any real version.
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

-- ── Single-artifact fetcher (maven-metadata.xml) ─────────────────────────────

local function build_url(group, artifact)
  -- groupId path: dots → slashes. `org.springframework` → `org/springframework`.
  -- Then `<group_path>/<artifactId>/maven-metadata.xml`.
  local group_path = group:gsub("%.", "/")
  return string.format(
    "https://repo1.maven.org/maven2/%s/%s/maven-metadata.xml",
    group_path, artifact)
end

-- Pull the latest published version from the maven-metadata.xml. Prefers
-- `<latest>`; falls back to `<release>` when missing (some metadata files,
-- especially older ones, only ship <release>). Returns nil if neither tag
-- has a non-empty value.
--
-- Parsing is a deliberately simple pair of regexes — the file is small
-- (a few KB), the schema is stable, and pulling in a real XML parser
-- inside the Lua sandbox would be wildly disproportionate.
local function extract_latest(xml_body)
  if not xml_body or xml_body == "" then return nil end
  -- Strip XML comments first so a commented-out <latest> can't be matched.
  local body = xml_body:gsub("<!%-%-.-%-%->", "")
  local versioning = body:match("<versioning>(.-)</versioning>") or body
  local latest = versioning:match("<latest>%s*([^<%s]+)%s*</latest>")
  if latest and latest ~= "" then return latest end
  local release = versioning:match("<release>%s*([^<%s]+)%s*</release>")
  if release and release ~= "" then return release end
  return nil
end

-- ── Concurrency-limited dispatcher ───────────────────────────────────────────
-- A simple FIFO queue + counter. When a request finishes we kick the next
-- queued one. Avoids 200 simultaneous TCP handshakes against Maven Central.

local _inflight = 0
local _queue    = {}

local function pump()
  while _inflight < MAX_INFLIGHT and #_queue > 0 do
    local job = table.remove(_queue, 1)
    _inflight = _inflight + 1
    arbor.http.get(job.url, { timeout_ms = HTTP_TIMEOUT_MS }, function(response)
      _inflight = _inflight - 1
      local latest      = nil
      local cache_value = nil  -- nil = "don't cache; let it retry"
      if response then
        if response.ok and response.body then
          -- 200: the artifact exists; extract and cache the version (or
          -- NULL_LATEST if the metadata has no usable <latest>/<release>).
          latest      = extract_latest(response.body)
          cache_value = latest or NULL_LATEST
        elseif response.status == 404 then
          -- Definitively not on Central — cache the negative.
          cache_value = NULL_LATEST
        else
          -- 5xx / network error / timeout — leave the cache untouched so
          -- the next analysis tries again instead of treating a glitch as
          -- a permanent miss. The MISS_TTL_SECS shortcut wouldn't help
          -- here because we never wrote anything for this key.
          arbor.log.warn(string.format(
            "[deps-explorer/maven-central] %s -> HTTP %d%s",
            job.key, response.status or 0,
            response.error and (" — " .. response.error) or ""))
        end
      end
      if cache_value ~= nil then cache_put(job.key, cache_value) end
      pcall(job.on_done, latest)
      pump() -- drain the next queued job
    end)
  end
end

local function enqueue(group, artifact, on_done)
  local key = group .. ":" .. artifact
  table.insert(_queue, {
    url     = build_url(group, artifact),
    key     = key,
    on_done = on_done,
  })
  pump()
end

-- ── Public ───────────────────────────────────────────────────────────────────

function M.fetch_many(pairs_list, on_complete)
  if #pairs_list == 0 then pcall(on_complete, {}); return end

  -- Phase 1: cache hits first.
  local results = {}
  local misses  = {}
  for _, p in ipairs(pairs_list) do
    if p.group and p.artifact and p.group ~= "" and p.artifact ~= "" then
      local key = p.group .. ":" .. p.artifact
      local cached = cache_get_fresh(key)
      if cached ~= nil then
        if cached ~= NULL_LATEST then results[key] = cached end
      else
        misses[#misses + 1] = p
      end
    end
  end

  if #misses == 0 then
    pcall(on_complete, results)
    return
  end

  -- Phase 2: enqueue every miss, fire `on_complete` once they all settle.
  local pending = #misses
  for _, p in ipairs(misses) do
    enqueue(p.group, p.artifact, function(latest)
      if latest then
        results[p.group .. ":" .. p.artifact] = latest
      end
      pending = pending - 1
      if pending == 0 then
        save_cache()
        pcall(on_complete, results)
      end
    end)
  end
end

function M.fetch_latest(group, artifact, on_done)
  M.fetch_many({ { group = group, artifact = artifact } }, function(results)
    on_done(results[group .. ":" .. artifact])
  end)
end

-- Drop every cache entry that says "not on Central" (NULL_LATEST). Used by
-- the modal's Refresh action to flush poisoning from a previous broken
-- query run — found entries stay (they're costly to recompute and unlikely
-- to be wrong).
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
