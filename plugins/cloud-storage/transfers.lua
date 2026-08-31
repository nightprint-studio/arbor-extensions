-- transfers.lua — moving bytes, and saying so while it happens.
--
-- The loop that used to live in Arbor: a download is a sequence of ranged reads appended to
-- one file, an upload is a sequence of slices of a local file, and a sync is a plan followed
-- one entry at a time. All of it is here now, because none of it was ever Arbor's — what
-- Arbor lends is the progress card (`arbor.ui.operation`) and the two calls that move bytes
-- without them passing through Lua (`arbor.ext.call_to_file` / `call_from_file`).
--
-- ## Cancellation
--
-- A flag this module owns, checked between chunks. Not a host concept: the work is a Lua loop,
-- so the only thing that can stop it is the loop. `cancel(id)` sets it; the next chunk boundary
-- notices and finishes the card as cancelled, leaving the partial file where it is rather than
-- deleting something the user may want to resume.
--
-- ## Chunk size
--
-- 8 MiB. Small enough that a cancel is felt within a chunk and that neither the guest's linear
-- memory nor this process holds much; large enough that a 1 GiB object is 128 calls and not
-- 16 000. The setting exists because a slow link wants it smaller and a LAN wants it larger.

local provider = require("provider")
local toolkit  = require("toolkit")
local settings = require("settings")

local M = {}

local DEFAULT_CHUNK = 8 * 1024 * 1024

--- Live transfers, keyed by operation id. `{ cancelled = bool }`.
M._running = {}

local function chunk_size()
  local n = tonumber(settings.get_chunk_bytes and settings.get_chunk_bytes() or nil)
  if not n or n <= 0 then return DEFAULT_CHUNK end
  return math.floor(n)
end

local function new_id(kind)
  return kind .. ":" .. tostring(os.time()) .. ":" .. tostring(math.random(1000, 9999))
end

--- Ask a running transfer to stop at the next chunk boundary.
function M.cancel(id)
  local t = M._running[id]
  if t then t.cancelled = true end
end

function M.cancelled(id)
  local t = M._running[id]
  return t ~= nil and t.cancelled == true
end

-- ── The progress card ───────────────────────────────────────────────────────

--- Start an operation card with one step per phase. The steps are named up front because the
--- overlay draws a stepper: a card that grows steps as it goes reads as a list, not as
--- progress.
local function begin_card(id, title, subtitle, steps)
  arbor.ui.operation.start{
    id       = id,
    title    = title,
    subtitle = subtitle,
    steps    = steps,
    current  = steps[1] and steps[1].key or nil,
  }
end

local function step(id, key, detail)
  pcall(function() arbor.ui.operation.set_current(id, key, detail) end)
end

local function finish(id, summary, err)
  M._running[id] = nil
  pcall(function() arbor.ui.operation.finish(id, { summary = summary, error = err }) end)
end

--- Human-readable size, for the card's detail line.
local function human(n)
  local units = { "B", "KB", "MB", "GB", "TB" }
  local v, i = n or 0, 1
  while v >= 1024 and i < #units do v = v / 1024 i = i + 1 end
  if i == 1 then return string.format("%d %s", v, units[i]) end
  return string.format("%.1f %s", v, units[i])
end

-- ── Download ────────────────────────────────────────────────────────────────

--- One object → one local file, in ranges.
---
--- Returns the operation id, so a caller can offer Cancel. The transfer itself is synchronous
--- from Lua's point of view: each chunk is a blocking host call, and the card is what makes
--- that visible.
function M.download(conn, bucket, key, dest, opts)
  opts = opts or {}
  local id = opts.id or new_id("cloud:download")
  M._running[id] = { cancelled = false }

  local meta, err = provider.stat(conn, bucket, key)
  if err then
    finish(id, nil, "Could not read the object's size: " .. tostring(err))
    return id, err
  end
  local size = meta.size or 0

  begin_card(id, "Downloading " .. toolkit.name_of(key), human(size), {
    { key = "transfer", label = "Transferring" },
  })

  local ranges = toolkit.plan_ranges(size, chunk_size())
  local written = 0

  -- An empty object still produces a file: the caller asked for it, and a zero-byte object is
  -- a real thing in every store. `plan_ranges` returns nothing for it, so write once with no
  -- range and let the provider hand back nothing.
  if #ranges == 0 then
    local _, e = provider.read_to_file(conn, bucket, key, dest, nil, false)
    if e then finish(id, nil, tostring(e)) return id, e end
    finish(id, "0 B", nil)
    return id, nil
  end

  for i, r in ipairs(ranges) do
    if M.cancelled(id) then
      finish(id, "Cancelled after " .. human(written), nil)
      return id, nil
    end
    -- `append` is false only for the first range: that is what truncates a file left over
    -- from a previous attempt, instead of appending to it and producing a file twice the size.
    local n, e = provider.read_to_file(conn, bucket, key, dest, r, i > 1)
    if e then
      finish(id, nil, tostring(e))
      return id, e
    end
    written = written + (n or 0)
    step(id, "transfer", human(written) .. " of " .. human(size))
  end

  finish(id, human(written), nil)
  return id, nil
end

-- ── Upload ──────────────────────────────────────────────────────────────────

--- One local file → one object, in slices.
---
--- A store that only accepts whole objects gets one call; the slices exist so neither this
--- process nor the guest holds a large file, and a provider that supports resumable uploads
--- can use them as parts.
function M.upload(conn, bucket, key, source, opts)
  opts = opts or {}
  local id = opts.id or new_id("cloud:upload")
  M._running[id] = { cancelled = false }

  local size = opts.size or 0
  begin_card(id, "Uploading " .. toolkit.name_of(key), human(size), {
    { key = "transfer", label = "Transferring" },
  })

  -- Whole-object when the size is unknown or small enough: asking for a slice of a file whose
  -- length we are guessing at is how a truncated upload happens.
  if size <= 0 or size <= chunk_size() then
    local _, e = provider.write_from_file(conn, bucket, key, source, {
      content_type = opts.content_type,
    })
    if e then finish(id, nil, tostring(e)) return id, e end
    finish(id, size > 0 and human(size) or nil, nil)
    return id, nil
  end

  local sent = 0
  for _, r in ipairs(toolkit.plan_ranges(size, chunk_size())) do
    if M.cancelled(id) then
      finish(id, "Cancelled after " .. human(sent), nil)
      return id, nil
    end
    local _, e = provider.write_from_file(conn, bucket, key, source, {
      offset       = r.start,
      length       = r["end"] - r.start,
      content_type = opts.content_type,
    })
    if e then finish(id, nil, tostring(e)) return id, e end
    sent = sent + (r["end"] - r.start)
    step(id, "transfer", human(sent) .. " of " .. human(size))
  end

  finish(id, human(sent), nil)
  return id, nil
end

-- ── Many objects ────────────────────────────────────────────────────────────

--- Download a list of keys into one folder. Returns the operation id.
---
--- `on_file(key, path)` is called per finished file, which is what the chunk-merge flow needs:
--- it collects the local paths in the order the user chose.
function M.download_many(conn, bucket, keys, dir, opts)
  opts = opts or {}
  local id = opts.id or new_id("cloud:download-many")
  M._running[id] = { cancelled = false }

  begin_card(id, "Downloading " .. #keys .. " files", opts.subtitle, {
    { key = "files", label = "Files" },
  })

  local done, paths = 0, {}
  for _, key in ipairs(keys) do
    if M.cancelled(id) then
      finish(id, "Cancelled after " .. done .. " of " .. #keys, nil)
      return id, nil, paths
    end
    local path = toolkit.join_key(dir, toolkit.name_of(key))
    -- Each file is its own ranged loop, but NOT its own card: one operation with a running
    -- count is what the user asked for, and forty cards is what they would get otherwise.
    local sub = id .. ":" .. done
    M._running[sub] = M._running[id]
    local _, e = M.download(conn, bucket, key, path, { id = sub })
    if e then
      finish(id, nil, "Failed on " .. toolkit.name_of(key) .. ": " .. tostring(e))
      return id, e, paths
    end
    done = done + 1
    paths[#paths + 1] = path
    if opts.on_file then opts.on_file(key, path) end
    step(id, "files", done .. " of " .. #keys)
  end

  finish(id, done .. " files", nil)
  return id, nil, paths
end

--- Download split parts straight into ONE file, in the order given.
---
--- This is the chunk-merge flow, and it no longer has a merge step. Every part is appended to
--- the same destination as it arrives, so the concatenation IS the download: nothing is
--- written twice, no temporary files are left behind, and a 40 GB archive never exists twice
--- on the disk. The old shape — download N files, then concatenate them — needed twice the
--- space and a second pass over every byte.
---
--- The order is the caller's, and it matters absolutely: parts appended in the wrong order
--- produce a file that looks complete and is corrupt. `toolkit.order_chunks` is what the
--- caller should have used to build the list.
function M.download_concat(conn, bucket, keys, dest, opts)
  opts = opts or {}
  local id = opts.id or new_id("cloud:chunks")
  M._running[id] = { cancelled = false }

  begin_card(id, "Downloading " .. #keys .. " parts", opts.subtitle or toolkit.name_of(dest), {
    { key = "parts", label = "Parts" },
  })

  local written = 0
  for i, key in ipairs(keys) do
    if M.cancelled(id) then
      -- The partial file is left where it is. A cancelled merge has produced a prefix of the
      -- real file, and deleting it silently would throw away work the user may want to resume.
      finish(id, "Cancelled after " .. (i - 1) .. " of " .. #keys .. " parts", nil)
      return id, nil
    end

    local meta, serr = provider.stat(conn, bucket, key)
    if serr then finish(id, nil, tostring(serr)) return id, serr end
    local size = meta.size or 0

    local ranges = toolkit.plan_ranges(size, chunk_size())
    if #ranges == 0 then ranges = { { start = 0, ["end"] = 0 } } end

    for ri, r in ipairs(ranges) do
      if M.cancelled(id) then
        finish(id, "Cancelled after " .. (i - 1) .. " of " .. #keys .. " parts", nil)
        return id, nil
      end
      -- Truncate exactly once, on the very first range of the very first part. Everything
      -- after appends — that single boolean is what makes this a concatenation.
      local append = not (i == 1 and ri == 1)
      local n, e = provider.read_to_file(conn, bucket, key, dest, r, append)
      if e then
        finish(id, nil, "Failed on part " .. i .. " (" .. toolkit.name_of(key) .. "): " .. tostring(e))
        return id, e
      end
      written = written + (n or 0)
      step(id, "parts", "part " .. i .. " of " .. #keys .. " · " .. human(written))
    end
  end

  finish(id, human(written) .. " in " .. #keys .. " parts", nil)
  return id, nil
end

-- ── Sync ────────────────────────────────────────────────────────────────────

--- Bucket → folder, by a plan the caller can see first.
---
--- `local_entries` is the caller's listing of the destination — this module does not walk the
--- filesystem, because which files are "in" a sync is a question about the user's intent
--- (hidden files, ignored patterns) rather than about storage.
function M.sync_down(conn, bucket, prefix, dir, local_entries, policy, opts)
  opts = opts or {}
  local id = opts.id or new_id("cloud:sync")
  M._running[id] = { cancelled = false }

  begin_card(id, "Syncing " .. (prefix ~= "" and prefix or bucket), dir, {
    { key = "plan",     label = "Planning" },
    { key = "transfer", label = "Transferring" },
  })

  step(id, "plan", "Listing the bucket…")
  local listing, err = provider.list_all(conn, bucket, prefix, {
    cancelled = function() return M.cancelled(id) end,
  })
  if err then finish(id, nil, tostring(err)) return id, err end

  local remote = {}
  for _, e in ipairs(listing.entries or {}) do
    if not e.prefix then
      remote[#remote + 1] = {
        key      = e.key,
        size     = e.size or 0,
        modified = e.modified,
        etag     = e.etag,
      }
    end
  end

  local plan, perr = toolkit.sync_plan(remote, local_entries or {}, policy)
  if perr then finish(id, nil, perr) return id, perr end

  local moving = {}
  for _, a in ipairs(plan.actions or {}) do
    -- The variant arrives as a tagged table; both spellings of a field cross, so `create` and
    -- `update` are read by name rather than by position.
    local key = a.create and a.create[1] or a.update and a.update[1]
    if key then moving[#moving + 1] = key end
  end

  step(id, "transfer", #moving .. " files, " .. human(plan.bytes or 0))
  local done, sent = 0, 0
  for _, key in ipairs(moving) do
    if M.cancelled(id) then
      finish(id, "Cancelled after " .. done .. " of " .. #moving, nil)
      return id, nil
    end
    local rel  = key
    if prefix ~= "" and key:sub(1, #prefix) == prefix then rel = key:sub(#prefix + 1) end
    local dest = toolkit.join_key(dir, rel)
    local sub  = id .. ":" .. done
    M._running[sub] = M._running[id]
    local _, e = M.download(conn, bucket, key, dest, { id = sub })
    if e then finish(id, nil, "Failed on " .. rel .. ": " .. tostring(e)) return id, e end
    done = done + 1
    sent = sent + 1
    step(id, "transfer", done .. " of " .. #moving)
  end

  local skipped = #(plan.actions or {}) - #moving
  finish(id, done .. " transferred, " .. skipped .. " already current", nil)
  return id, nil, plan
end

return M
