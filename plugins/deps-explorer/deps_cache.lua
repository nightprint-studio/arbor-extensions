-- deps_cache.lua — Per-module dependency-tree cache, persisted to disk.
--
-- The cache key is `<template>:<module_dir>`; the entry stores:
--   · `fingerprint` — content-hash of the source files that determine the
--                     resolved tree (pom.xml, Cargo.toml + Cargo.lock,
--                     package.json + lockfile, build.gradle…). When ANY of
--                     them changes the fingerprint changes and we re-run
--                     the resolver instead of returning stale data.
--   · `snapshot`    — the bare tree snapshot (BEFORE the Maven Central
--                     pass) so opening a previously-analysed module is
--                     instant. The Central pass runs on top and is itself
--                     cached separately (see maven_central.lua).
--   · `at`          — write timestamp; entries older than CACHE_GC_SECS
--                     are dropped at save time.
--
-- File format: a single JSON object at
--   <user-data>/arbor/deps-explorer/tree-cache.json
-- where <user-data> is %APPDATA% on Windows / $HOME/.arbor on Unix. The
-- file is loaded lazily, kept in module memory, and rewritten on every
-- mutation (cheap — even a few thousand entries fit in well under 1 MB).

local M = {}

local TTL_SECS    = 30 * 24 * 60 * 60   -- 30 days — older entries refresh on next look-up.
local CACHE_GC_SECS = 90 * 24 * 60 * 60 -- 90 days — purged at save time.

-- ── Paths ────────────────────────────────────────────────────────────────────

local function is_windows() return package.config:sub(1, 1) == "\\" end

local function user_data_root()
  if is_windows() then
    return os.getenv("APPDATA")
        or arbor.fs.join(os.getenv("USERPROFILE") or "C:\\", "AppData\\Roaming")
  end
  return arbor.fs.join(os.getenv("HOME") or "/tmp", ".arbor")
end

local function cache_dir()
  if is_windows() then
    return arbor.fs.join(user_data_root(), "arbor\\deps-explorer")
  end
  return arbor.fs.join(user_data_root(), "deps-explorer")
end

local function cache_path()
  return arbor.fs.join(cache_dir(), "tree-cache.json")
end

-- ── FNV-1a 32-bit hash ───────────────────────────────────────────────────────
-- Chosen over a real cryptographic hash because we don't have one in the
-- sandbox and because false-positive collisions are harmless: a collision
-- would just cause us to serve a wrong cached entry until the user clicks
-- Refresh. The probability is microscopic for the file-size hashes we
-- actually fingerprint.
local function fnv1a(s)
  local h = 2166136261
  for i = 1, #s do
    h = (h ~ s:byte(i)) * 16777619 & 0xffffffff
  end
  return string.format("%08x", h)
end

-- ── Lazy load / save ─────────────────────────────────────────────────────────

local _cache = nil

local function load()
  if _cache ~= nil then return _cache end
  local path = cache_path()
  local body = arbor.fs.is_file(path) and arbor.fs.read(path) or ""
  if body and body ~= "" then
    local ok, parsed = pcall(arbor.json.decode, body)
    _cache = (ok and type(parsed) == "table") and parsed or {}
  else
    _cache = {}
  end
  return _cache
end

local function save()
  if _cache == nil then return end
  local now = os.time()
  -- GC stale entries before serialising.
  for k, v in pairs(_cache) do
    if type(v) ~= "table" or type(v.at) ~= "number" or (now - v.at) > CACHE_GC_SECS then
      _cache[k] = nil
    end
  end
  local encoded = arbor.json.encode(_cache)
  if not encoded then return end
  -- Best-effort: arbor.fs.write is expected to create parent dirs.
  arbor.fs.write(cache_path(), encoded)
end

-- ── Fingerprint a list of files ──────────────────────────────────────────────
-- Concatenates `<path>:<size>:<content-hash>` per existing file. Missing
-- files contribute a sentinel so adding/removing a lockfile flips the
-- fingerprint — that's a meaningful change for npm/cargo trees.
local function fingerprint(files)
  local parts = {}
  for _, f in ipairs(files) do
    if arbor.fs.is_file(f) then
      local body = arbor.fs.read(f) or ""
      parts[#parts + 1] = f .. ":" .. tostring(#body) .. ":" .. fnv1a(body)
    else
      parts[#parts + 1] = f .. ":(absent)"
    end
  end
  return fnv1a(table.concat(parts, "|"))
end

-- ── Public API ───────────────────────────────────────────────────────────────

-- Look up a cached snapshot. Returns the stored snapshot or nil when:
--   · we have no entry for the key, OR
--   · the entry is older than TTL_SECS, OR
--   · any of the input files changed since the entry was written.
function M.lookup(key, files)
  local cache = load()
  local entry = cache[key]
  if type(entry) ~= "table" then return nil end
  if (os.time() - (entry.at or 0)) > TTL_SECS then return nil end
  if entry.fingerprint ~= fingerprint(files) then return nil end
  return entry.snapshot
end

-- Store a snapshot. Re-fingerprints `files` so we don't trust a stale
-- fingerprint passed in by the caller.
function M.put(key, files, snapshot)
  local cache = load()
  cache[key] = {
    fingerprint = fingerprint(files),
    snapshot    = snapshot,
    at          = os.time(),
  }
  save()
end

function M.invalidate(key)
  local cache = load()
  cache[key] = nil
  save()
end

function M.invalidate_all()
  _cache = {}
  save()
end

-- Drop every cache entry whose embedded module dir is `path_prefix` itself
-- or any descendant directory of it. Used by the `on_repo_deregistered`
-- plugin hook to wipe a repo's tree-cache entries when it's removed from
-- Arbor (registry deletion, last-workspace removal, or tab close on an
-- orphan). Returns the number of entries removed so callers can log /
-- notify usefully.
--
-- The cache key format depends on the toolchain:
--   maven       → "maven:<dir>"
--   gradle      → "gradle:<dir>"
--   cargo       → "cargo:<dir>"  | "cargo-ws:<dir>"
--   npm         → "npm:<pm>:<dir>"  (pm = npm | pnpm | yarn)
-- Rather than parse each variant, we match on the path's appearance as a
-- terminal substring of the key — paths are absolute (start with `/` or
-- a Windows drive letter) so they cannot collide with the template prefix.
function M.invalidate_path(path_prefix)
  if not path_prefix or path_prefix == "" then return 0 end
  -- Normalise both sides to forward slashes so Windows paths stored from
  -- different code paths (some with `\`, some with `/`) all match.
  local function norm(p) return (p:gsub("\\", "/")) end
  local prefix = norm(path_prefix):gsub("/+$", "") -- trim trailing /
  local cache = load()
  local removed = 0
  for k, _ in pairs(cache) do
    local nk = norm(k)
    -- An entry matches if the key ends with `:<prefix>` (the module IS the
    -- repo) or if it contains `:<prefix>/` somewhere (the module is a
    -- subdirectory). The colon prefix prevents accidentally matching a
    -- sibling whose path starts with the same name (`/repo/foo` vs
    -- `/repo/foobar`).
    local needle_eq   = ":" .. prefix
    local needle_sub  = ":" .. prefix .. "/"
    if nk:sub(-#needle_eq) == needle_eq or nk:find(needle_sub, 1, true) then
      cache[k] = nil
      removed = removed + 1
    end
  end
  if removed > 0 then save() end
  return removed
end

return M
