-- chunks.lua — multi-selection bulk actions + chunk-merge orchestration.
--
-- Single source of truth for everything that operates on >1 selected files.
-- Single-file context actions stay in main.lua.
--
-- Chunk-merge flow:
--   1. user picks "Download chunks (auto)" / "(custom order)" on N files
--   2. we pick the output path (save picker), resolve handler (radio if >1)
--   3. for "custom": a `reorder_list` form; its value IS the order
--   4. with no handler package: the parts are appended to the output as they arrive, so the
--      download IS the concatenation — no temp directory, nothing written twice
--   5. with a handler package: the parts land in a temp directory and the package is called
--      with them in order, because some merges are not concatenations

local state     = require("state")
local transfers = require("transfers")
local provider  = require("provider")

--- Size for a person, for the order list's right-hand column.
local function human_size(n)
  local units = { "B", "KB", "MB", "GB", "TB" }
  local v, i = n or 0, 1
  while v >= 1024 and i < #units do v = v / 1024 i = i + 1 end
  if i == 1 then return string.format("%d %s", v, units[i]) end
  return string.format("%.1f %s", v, units[i])
end
local sidebar  = require("ui.sidebar")
local settings = require("settings")

local M = {}

local CHUNK_HANDLERS_POINT = "cloud-storage:cloud:chunk-handlers"

-- Re-entrancy guard for the chunk-merge entry flow. Cleared when either
-- (a) the save-picker is cancelled, (b) the handler-picker is cancelled,
-- or (c) the download has started (from there on the flow runs to its end
-- inside one call, so there is nothing left to re-enter).
-- Without this guard, a double-fire of `cloud:multi_dl_chunks_auto` (e.g.
-- a double-clicked context-menu entry) would launch two parallel
-- download_many runs, both pointing at the same temp dir and the same
-- output path — producing twin OperationsOverlay cards that race on the
-- same filesystem locations.
M._chunks_flow_busy = false

function M.list_handlers()
  local items, err = arbor.contribution.list(CHUNK_HANDLERS_POINT)
  if err or not items then return {} end
  return items
end

local function ts_now_id(prefix)
  math.randomseed(os.time() + math.floor((os.clock() * 1000000) % 1000000))
  return (prefix or "stream") .. "-" .. tostring(math.random(0, 0xffffff))
                                .. "-" .. tostring(math.floor(os.time()))
end

local function nodes_of_kind(ctx, kind)
  local out = {}
  for _, n in ipairs(ctx.nodes or {}) do
    if (n.kind or "") == (kind or n.kind) then out[#out + 1] = n end
  end
  return out
end

local function ctx_connection(ctx)
  -- Every selected node carries `data.config_id` and `data.bucket` (set by
  -- sidebar.rows_from_items). All selected files belong to the same
  -- connection in practice, so we just take the first.
  local first = (ctx.nodes and ctx.nodes[1]) or nil
  if not first then return nil, nil, nil end
  local d = first.data or {}
  local conn = state.find(d.config_id)
  return conn, d.config_id, d.bucket
end

local function paths_in_order(ctx)
  local out = {}
  for _, n in ipairs(ctx.nodes or {}) do
    local d = n.data or {}
    if d.path then out[#out + 1] = d.path end
  end
  return out
end

local function file_items_for_picker(ctx)
  -- Items for the drag-reorder modal — preserve every field we'll need
  -- back at order-picked time.
  local out = {}
  for _, n in ipairs(ctx.nodes or {}) do
    local d = n.data or {}
    out[#out + 1] = {
      label = n.label or d.path,
      path  = d.path,
      size  = d.size,
    }
  end
  return out
end

-- ── Multi-download (N files preserving original basenames) ────────────────

function M.multi_download(ctx)
  local conn, _config_id, bucket = ctx_connection(ctx)
  if not conn then
    arbor.notify{ title = "Download", message = "No active connection.", level = "warning" }
    return
  end
  local paths = paths_in_order(ctx)
  if #paths == 0 then return end

  arbor.ui.pick_file({
    mode   = "folder",
    title  = "Download " .. #paths .. " file(s) to…",
    action = "cloud:multi_download_target_picked",
    extra  = {
      config_id = conn.id,
      bucket    = bucket,
      paths     = paths,
    },
  })
end

arbor.events.on("cloud:multi_download_target_picked", function(ctx)
  local local_dir = ctx.path or ""
  if local_dir == "" then return end -- cancelled
  local conn = state.find(ctx.config_id)
  if not conn or not ctx.bucket then return end

  local _, err = transfers.download_many(conn, ctx.bucket, ctx.paths, local_dir, {
    subtitle = local_dir,
  })
  if err then
    arbor.notify{ title = "Download", message = tostring(err), level = "error" }
    return
  end
  arbor.notify{
    title   = "Download complete",
    message = #ctx.paths .. " file(s) saved to " .. local_dir,
    level   = "success",
    action  = { kind = "open-path", label = "Open folder", path = local_dir, reveal = false },
  }
end)

-- ── Multi-delete ──────────────────────────────────────────────────────────

function M.multi_delete(ctx)
  local conn, _config_id, bucket = ctx_connection(ctx)
  if not conn then return end
  local paths = paths_in_order(ctx)
  if #paths == 0 then return end

  arbor.ui.confirm({
    title         = "Delete " .. #paths .. " file(s)",
    message       = "Permanently delete " .. #paths .. " object(s) from bucket `"
                 .. bucket .. "`? This can't be undone.",
    confirm_label = "Delete",
    confirm_kind  = "danger",
    cancel_label  = "Cancel",
    on_confirm    = function()
      local fails = 0
      for _, p in ipairs(paths) do
        local _, err = provider.delete(conn, bucket, p)
        if err then fails = fails + 1 end
      end
      if fails > 0 then
        arbor.notify{ title = "Delete",
                      message = "Failed on " .. fails .. " of " .. #paths .. " object(s).",
                      level = "warning" }
      else
        arbor.notify{ title = "Deleted",
                      message = #paths .. " object(s) removed.",
                      level = "success" }
      end
      sidebar.clear_cache(conn.id)
      sidebar.refresh({ use_cache = false })
    end,
  })
end

-- ── Chunk merge: entry-points ─────────────────────────────────────────────
-- mode = "auto"   → order by last_modified ascending, no picker
-- mode = "custom" → open the drag-reorder modal first

function M.multi_dl_chunks(ctx, mode)
  if M._chunks_flow_busy then
    -- Defensive: ignore the second of a same-tick double-fire. Real
    -- back-to-back flows from the user clear the flag at either
    -- _kick_off_download (success path) or on cancel.
    return
  end

  -- No handler check here, and no `arbor.service.call` check either. Both were preconditions
  -- of the old shape, where the parts landed in a temp folder and something else joined them.
  -- The download IS the concatenation now, so zero handlers is the ordinary case; the handler
  -- branch in `_kick_off_download` is the one that needs `arbor.service.call`, and it tests
  -- for it there, where a failure can still be told apart from "nothing to merge".

  local conn, _config_id, bucket = ctx_connection(ctx)
  if not conn then return end

  -- The host already supplies last_modified on each CloudObject's data; the
  -- tree rows carry that through.  For the "auto" mode we just sort here;
  -- for "custom" we hand off to the drag-reorder modal.
  local nodes = nodes_of_kind(ctx, "object")
  if #nodes < 2 then
    arbor.notify{ title = "Chunks", message = "Select at least two parts.",
                  level = "warning" }
    return
  end

  -- Save-picker for the merged output file. We stash everything we need
  -- in `extra` so the downstream actions don't need plugin-local state.
  local default_name = (nodes[1].data and nodes[1].data.path or "merged")
                         :match("([^/]+)$") or "merged"
  -- Strip a trailing .NNN if present (split-archive convention).
  default_name = default_name:gsub("%.%d+$", "")

  -- Arm the re-entrancy guard now that we're committed to opening the
  -- save picker. Cleared in `cloud:multi_chunks_target_picked` (both on
  -- empty path = cancel and on successful kickoff).
  M._chunks_flow_busy = true

  arbor.ui.pick_file({
    mode         = "save",
    title        = "Save merged output as…",
    initial_path = default_name,
    action       = "cloud:multi_chunks_target_picked",
    extra = {
      config_id = conn.id,
      bucket    = bucket,
      mode      = mode,
      nodes     = nodes,
    },
  })
end

arbor.events.on("cloud:multi_chunks_target_picked", function(ctx)
  local output = ctx.path or ""
  if output == "" then
    -- User cancelled the save picker — release the flow guard so the
    -- next "Download chunks…" click is allowed through.
    M._chunks_flow_busy = false
    return
  end
  local conn = state.find(ctx.config_id)
  if not conn then
    M._chunks_flow_busy = false
    return
  end

  -- Resolve the handler: none (the common case — concatenate on the way down), the only one
  -- installed, or a radio prompt when several are. Without the zero case this fell through to
  -- the prompt below and asked the user to choose from an empty list.
  local handlers = M.list_handlers()
  if #handlers <= 1 then
    M._pending_setup = {
      conn = conn, bucket = ctx.bucket, mode = ctx.mode, nodes = ctx.nodes,
      -- nil when none is installed, which `_kick_off_download` reads as "concatenate on the
      -- way down". One and none take the same path because neither has anything to ask.
      output = output, handler = handlers[1],
    }
    M._after_handler_resolved()
    return
  end

  -- >1: ask via radio form. Reply lands in `cloud:chunk-handler-picked`.
  local opts = {}
  for _, h in ipairs(handlers) do
    local p = h.payload or {}
    opts[#opts + 1] = {
      value = h.item_id,
      label = (p.label or h.item_id) .. "  ·  " .. (h.plugin_name or ""),
    }
  end
  M._pending_setup = {
    conn = conn, bucket = ctx.bucket, mode = ctx.mode, nodes = ctx.nodes,
    output = output, handlers = handlers,
  }
  arbor.ui.form({
    title         = "Choose chunk handler",
    description   = "Multiple chunk-merger plugins are installed. Pick one for this operation.",
    width         = "520px",
    height        = "300px",
    submit_label  = "Continue",
    submit_action = "cloud:chunk-handler-picked",
    cancel_label  = "Cancel",
    cancel_action = "cloud:noop",
    nodes = {
      { type = "radio", name = "handler_id", label = "Handler", options = opts,
        default = handlers[1] and handlers[1].item_id, required = true },
    },
  })
end)

function M.on_handler_picked(ctx)
  local sel = ctx.handler_id or ""
  local setup = M._pending_setup
  if not setup or sel == "" then
    M._chunks_flow_busy = false
    return
  end
  local handlers = setup.handlers or {}
  local picked = nil
  for _, h in ipairs(handlers) do
    if h.item_id == sel then picked = h; break end
  end
  if not picked then
    M._chunks_flow_busy = false
    return
  end
  setup.handler = picked
  setup.handlers = nil
  M._after_handler_resolved()
end

function M._after_handler_resolved()
  local setup = M._pending_setup
  if not setup then return end
  if setup.mode == "custom" then
    -- Open the drag-reorder picker first. Default order: by last_modified.
    local items = {}
    for _, n in ipairs(setup.nodes) do
      local d = n.data or {}
      items[#items + 1] = {
        label = (n.label or d.path),
        path  = d.path,
        size  = d.size,
        meta  = nil,  -- modified-date display deferred to v2
      }
    end
    -- Sort by last_modified asc (same as auto) as a sane starting point.
    table.sort(items, function(a, b) return (a.path or "") < (b.path or "") end)

    -- A form the plugin owns, not a modal the host carries: `reorder_list` is a form node
    -- like any other, and the order it answers with is the sequence the concatenation uses.
    -- Keyboard-first (Alt+↑/↓), which the old drag-only dialog was not — and which mattered
    -- more than it sounds, because HTML5 drag does not work on Windows' WebView2 at all.
    local rows = {}
    for _, it in ipairs(items) do
      rows[#rows + 1] = {
        id       = it.path,
        label    = it.label or it.path,
        sublabel = it.meta,
        meta     = it.size and human_size(it.size) or nil,
      }
    end
    arbor.ui.form({
      title        = "Order chunks for merge",
      width        = "640px",
      height       = "520px",
      submit_label = "Download and merge",
      cancel_label = "Cancel",
      submit_action = "cloud:chunk-order-picked",
      nodes = {
        { type = "label",
          text = "The top row is written first. Alt+↑ / Alt+↓ move the selected part." },
        { type = "reorder_list", name = "order", items = rows },
      },
    })
    return
  end
  -- Auto: sort by last_modified ascending right now.
  M._kick_off_download(setup, M._sorted_paths_by_date(setup.nodes))
end

function M._sorted_paths_by_date(nodes)
  -- Each tree-node `data` carries `last_modified` (ISO string) from the
  -- backend listing.  Sort ascending; tie-break alphabetic on path so the
  -- order stays stable when timestamps match (split-archive uploads often
  -- finish within the same second).
  local copy = {}
  for _, n in ipairs(nodes) do copy[#copy + 1] = n end
  table.sort(copy, function(a, b)
    local da = (a.data and a.data.last_modified) or ""
    local db = (b.data and b.data.last_modified) or ""
    if da == db then
      return ((a.data and a.data.path) or "") < ((b.data and b.data.path) or "")
    end
    return da < db
  end)
  local out = {}
  for _, n in ipairs(copy) do
    if n.data and n.data.path then out[#out + 1] = n.data.path end
  end
  return out
end

function M.on_chunk_order_picked(ctx)
  local setup = M._pending_setup
  if not setup then
    M._chunks_flow_busy = false
    return
  end
  -- The node's value is the ids in the order shown, and the ids are the object keys — so the
  -- form answers with exactly the list the download needs.
  local ordered = ctx.order
  if type(ordered) ~= "table" or #ordered == 0 then
    M._pending_setup = nil
    M._chunks_flow_busy = false
    return
  end
  pcall(function() arbor.ui.form.close() end)
  M._kick_off_download(setup, ordered)
end

function M._kick_off_download(setup, ordered_paths)
  M._pending_setup = nil
  M._chunks_flow_busy = false
  if #ordered_paths == 0 then return end

  local out_name = setup.output:match("([^/\\]+)$") or "merged"
  local handler_payload = (setup.handler and setup.handler.payload) or {}
  local service_name    = handler_payload.service

  -- ── The common case: there is nothing to merge ────────────────────────────
  --
  -- Parts appended to the output as they arrive ARE the concatenation. No temp directory,
  -- nothing written twice, and a 40 GB archive never exists twice on the disk — which the
  -- download-then-merge shape required, along with a second pass over every byte.
  if not service_name or service_name == "" then
    local _, err = transfers.download_concat(setup.conn, setup.bucket, ordered_paths, setup.output, {
      subtitle = out_name,
    })
    if err then
      arbor.notify{ title = "Chunks download failed", message = tostring(err), level = "error" }
      return
    end
    arbor.notify{
      title   = "Chunks merged",
      message = #ordered_paths .. " parts → " .. out_name,
      level   = "success",
      action  = (setup.output and setup.output ~= "") and {
        kind = "open-path", label = "Open folder", path = setup.output, reveal = true,
      } or nil,
    }
    return
  end

  -- ── A handler package wants the parts ─────────────────────────────────────
  --
  -- Some merges are not concatenations: a format with a header per part, one that needs
  -- padding stripped, one that verifies a checksum. Those packages get what they have always
  -- got — the parts on disk, in order — and the temp directory exists for them alone.
  local tempdir = setup.output .. ".chunks"
  local _, err, paths = transfers.download_many(setup.conn, setup.bucket, ordered_paths, tempdir, {
    subtitle = out_name,
  })
  if err then
    arbor.notify{ title = "Chunks download failed", message = tostring(err), level = "error" }
    return
  end

  if type(arbor.service) ~= "table" or type(arbor.service.call) ~= "function" then
    arbor.notify{
      title   = "Merge skipped",
      message = "arbor.service.call is unavailable — click Refresh in the Plugin Manager to "
             .. "apply the latest plugin.toml.",
      level   = "error",
    }
    return
  end

  -- Its own card: the download's has already closed, and a merge that takes minutes with no
  -- progress anywhere reads as a hang.
  local op_id = "cloud:merge:" .. tostring(os.time())
  arbor.ui.operation.start{
    id       = op_id,
    title    = "Merging " .. #paths .. " parts",
    subtitle = out_name,
    steps    = { { key = "merge", label = "Merging" } },
    current  = "merge",
  }

  arbor.service.call(service_name, {
    inputs       = paths,
    output       = setup.output,
    source_paths = ordered_paths,
    tempdir      = tempdir,
  }):ok(function(result)
    local ok  = (result and result.ok ~= false) and not result.error
    local err2 = result and result.error or nil
    pcall(function()
      arbor.ui.operation.finish(op_id, {
        summary = ok and ("Merged into " .. out_name) or nil,
        error   = err2,
      })
    end)
    if ok then
      for _, p_in in ipairs(paths) do pcall(function() arbor.fs.delete(p_in) end) end
      pcall(function() arbor.fs.delete(tempdir) end)
      arbor.notify{
        title   = "Chunks merged",
        message = #paths .. " chunks → " .. out_name,
        level   = "success",
        action  = (setup.output and setup.output ~= "") and {
          kind = "open-path", label = "Open folder", path = setup.output, reveal = true,
        } or nil,
      }
    else
      arbor.notify{ title = "Chunk merge failed", message = tostring(err2 or "merge failed"),
                    level = "error" }
    end
  end):err(function(e)
    local msg = tostring(e and e.message or e)
    pcall(function() arbor.ui.operation.finish(op_id, { error = "merge handler error: " .. msg }) end)
    arbor.notify{ title = "Chunk merge failed", message = msg, level = "error" }
  end)
end

return M
