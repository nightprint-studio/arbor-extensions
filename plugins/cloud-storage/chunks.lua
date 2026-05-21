-- chunks.lua — multi-selection bulk actions + chunk-merge orchestration.
--
-- Single source of truth for everything that operates on >1 selected files.
-- Single-file context actions stay in main.lua.
--
-- Chunk-merge flow:
--   1. user picks "Download chunks (auto)" / "(custom order)" on N files
--   2. we pick the output path (save picker), resolve handler (radio if >1)
--   3. for "custom": open the drag-reorder modal; receive the order
--   4. download_many to a temp dir → host streams + modal updates
--   5. on download-many-done, fire the chosen chunk-handler service with the
--      local_paths in the requested order
--   6. push the merge phase + done events to the modal via report_progress
--      / report_done

local state    = require("state")
local sidebar  = require("ui.sidebar")
local settings = require("settings")

local M = {}

local CHUNK_HANDLERS_POINT = "cloud-storage:cloud:chunk-handlers"

-- In-flight chunk-merge bookkeeping keyed by stream_id. Populated when we
-- kick off download_many and consumed in the `done` hook.
M._pending = {}

-- Re-entrancy guard for the chunk-merge entry flow. Cleared when either
-- (a) the save-picker is cancelled, (b) the handler-picker is cancelled,
-- or (c) the download_many call has been spawned (we hold the actual
-- per-stream state in `M._pending[stream_id]` after that point).
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

  local stream_id = ts_now_id("cloud-bulk")
  local _, err = arbor.cloud.download_many({
    conn      = state.envelope(conn),
    bucket    = ctx.bucket,
    paths     = ctx.paths,
    local_dir = local_dir,
    parallel  = settings.parallel_downloads(),
    op_label  = "Downloading " .. #ctx.paths .. " file(s)",
    stream_id = stream_id,
  })
  if err then
    arbor.notify{ title = "Download", message = tostring(err), level = "error" }
    return
  end
  -- The modal auto-opens on the first progress event. No merge phase here.
  -- `local_dir` is stashed so on_download_many_done can show a notify with
  -- an "Open folder" action pointing at the destination directory.
  M._pending[stream_id] = {
    kind      = "bulk",
    local_dir = local_dir,
    count     = #ctx.paths,
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
      local env = state.envelope(conn)
      local fails = 0
      for _, p in ipairs(paths) do
        local _, err = arbor.cloud.delete({ conn = env, bucket = bucket, path = p })
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

  local handlers = M.list_handlers()
  if #handlers == 0 then
    arbor.notify{
      title = "No chunk handler",
      message = "Install a chunk-merger plugin to download and merge multi-part files.",
      level = "warning",
    }
    return
  end

  -- Fail fast if the `arbor.service.call` API isn't available. cloud-storage
  -- declares `service_call = true` in plugin.toml, so this only trips when
  -- someone has stripped the permission — and the symptom (a card stuck on
  -- "Concatenating chunks…" with no :err callback) is awful to diagnose.
  if type(arbor.service) ~= "table" or type(arbor.service.call) ~= "function" then
    arbor.notify{
      title   = "Cloud Storage misconfigured",
      message = "arbor.service.call is unavailable — add `service_call = true` to "
             .. "cloud-storage's plugin.toml [permissions] section.",
      level   = "error",
    }
    return
  end

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

  -- Resolve the handler (radio prompt if >1 installed).
  local handlers = M.list_handlers()
  if #handlers == 1 then
    M._pending_setup = {
      conn = conn, bucket = ctx.bucket, mode = ctx.mode, nodes = ctx.nodes,
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

    arbor.cloud.pick_chunk_order({
      op_label = "Order chunks for merge",
      action   = "cloud:chunk-order-picked",
      items    = items,
      extra    = { setup_key = "current" },
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
  if not ctx.ok then
    M._pending_setup = nil
    M._chunks_flow_busy = false
    return
  end
  M._kick_off_download(setup, ctx.ordered_paths or {})
end

function M._kick_off_download(setup, ordered_paths)
  M._pending_setup = nil
  -- Flow guard can be released here: per-stream state now lives in
  -- M._pending[stream_id] keyed by the unique stream id, so any further
  -- entries to multi_dl_chunks would race on disjoint streams (and that's
  -- a legitimate flow we don't want to block).
  M._chunks_flow_busy = false
  if #ordered_paths == 0 then return end

  -- Per-stream temp dir under the user's chosen output: place chunks under
  -- `<output>.chunks/` so cleanup is obvious if the merge fails mid-way.
  local tempdir = setup.output .. ".chunks"
  local stream_id = ts_now_id("cloud-merge")
  local out_name  = setup.output:match("([^/\\]+)$") or "merged"

  M._pending[stream_id] = {
    kind         = "merge",
    handler      = setup.handler,
    output       = setup.output,
    tempdir      = tempdir,
    ordered_paths = ordered_paths,
  }

  -- `keep_open=true` + an appended "merge" step makes the OperationsOverlay
  -- card span both phases. After all per-file download steps complete the
  -- card stays open showing the "merge" step pending; the merge orchestrator
  -- below activates it via `report_progress` and closes via `report_done`.
  local _, err = arbor.cloud.download_many({
    conn        = state.envelope(setup.conn),
    bucket      = setup.bucket,
    paths       = ordered_paths,
    local_dir   = tempdir,
    parallel    = settings.parallel_downloads(),
    op_label    = "Downloading " .. #ordered_paths .. " chunk(s) · " .. out_name,
    stream_id   = stream_id,
    extra_steps = {
      { key = "merge", label = "Merge chunks → " .. out_name },
    },
    keep_open   = true,
  })
  if err then
    arbor.notify{ title = "Download chunks", message = tostring(err), level = "error" }
    M._pending[stream_id] = nil
  end
end

-- ── download-many-done — bulk vs merge ────────────────────────────────────

function M.on_download_many_done(ev)
  local p = M._pending[ev.stream_id]
  if not p then return end
  M._pending[ev.stream_id] = nil

  if p.kind == "bulk" then
    if ev.ok then
      local n = p.count or (ev.local_paths and #ev.local_paths) or 0
      local msg = (n > 0)
        and (tostring(n) .. " file" .. (n == 1 and "" or "s")
             .. " saved to " .. (p.local_dir or "?"))
        or  "Done."
      arbor.notify{
        title   = "Download complete",
        message = msg,
        level   = "success",
        action  = (p.local_dir and p.local_dir ~= "") and {
          kind   = "open-path",
          label  = "Open folder",
          path   = p.local_dir,
          reveal = false,  -- local_dir IS the folder; just open it
        } or nil,
      }
    else
      arbor.notify{ title = "Download failed",
                    message = tostring(ev.error or "failed"),
                    level = "error" }
    end
    return
  end

  if p.kind == "merge" then
    if not ev.ok then
      -- Download phase failed/cancelled: the backend already closed the
      -- card with an error summary, so report_done would be a no-op here.
      -- The pending-ops map was already wiped on that path too. Still
      -- surface a bell notification so the user has a persistent record
      -- of the failure outside the auto-dismissed OperationsOverlay.
      arbor.notify{
        title   = "Chunks download failed",
        message = tostring(ev.error or "download failed"),
        level   = "error",
      }
      return
    end

    -- Activate the appended "merge" step on the same OperationsOverlay
    -- card the download phase populated.
    arbor.cloud.report_progress({
      stream_id = ev.stream_id,
      step      = "merge",
      detail    = "Concatenating " .. #ev.local_paths .. " chunk(s)…",
    })

    local handler_payload = (p.handler and p.handler.payload) or {}
    local service_name = handler_payload.service
    local out_name = (p.output or ""):match("([^/\\]+)$") or "merged"
    if not service_name or service_name == "" then
      arbor.cloud.report_done({
        stream_id = ev.stream_id, ok = false,
        error     = "handler has no service",
      })
      return
    end

    -- Second line of defence: even though `multi_dl_chunks` already gates
    -- on `arbor.service.call` at entry, the VM that's actually running
    -- this hook handler may be stale (manifest edited mid-session,
    -- plugin not refreshed since). If `arbor.service` is nil here we'd
    -- index-nil at the .call site, the hook dispatcher would swallow the
    -- runtime error, and the OperationsOverlay card would never close.
    -- Close it explicitly with a user-actionable error instead.
    if type(arbor.service) ~= "table" or type(arbor.service.call) ~= "function" then
      arbor.cloud.report_done({
        stream_id = ev.stream_id, ok = false,
        error     = "arbor.service.call unavailable — Refresh Plugins after "
                 .. "manifest changes (or add `service_call = true` to "
                 .. "cloud-storage's plugin.toml [permissions]).",
      })
      arbor.notify{
        title   = "Merge skipped",
        message = "cloud-storage VM is stale — click Refresh in the Plugin "
               .. "Manager to apply the latest plugin.toml.",
        level   = "error",
      }
      return
    end

    arbor.service.call(service_name, {
      stream_id    = ev.stream_id,
      inputs       = ev.local_paths,
      output       = p.output,
      source_paths = p.ordered_paths,
      tempdir      = p.tempdir,
    }):ok(function(result)
      local ok    = (result and result.ok ~= false) and not result.error
      local err   = result and result.error or nil
      arbor.cloud.report_done({
        stream_id = ev.stream_id,
        ok        = ok,
        summary   = ok and ("Merged into " .. out_name) or nil,
        error     = err,
      })
      if ok then
        -- Best-effort cleanup of the chunk temp dir.
        for _, p_in in ipairs(ev.local_paths) do
          pcall(function() arbor.fs.delete(p_in) end)
        end
        pcall(function() arbor.fs.delete(p.tempdir) end)
        -- Persisted bell notification with an "Open folder" action that
        -- reveals the merged file in Explorer/Finder. Sticking around in
        -- the bell archive is intentional: the OperationsOverlay card
        -- auto-dismisses after a few seconds, but the user may glance
        -- back later wanting "where did that merged file go?".
        arbor.notify{
          title   = "Chunks merged",
          message = #ev.local_paths .. " chunks → " .. out_name,
          level   = "success",
          action  = (p.output and p.output ~= "") and {
            kind   = "open-path",
            label  = "Open folder",
            path   = p.output,
            reveal = true,  -- p.output is the merged file; reveal its parent
          } or nil,
        }
      else
        arbor.notify{
          title   = "Chunk merge failed",
          message = tostring(err or "merge failed"),
          level   = "error",
        }
      end
    end):err(function(e)
      arbor.cloud.report_done({
        stream_id = ev.stream_id,
        ok        = false,
        error     = "merge handler error: " .. tostring(e and e.message or e),
      })
      arbor.notify{
        title   = "Chunk merge failed",
        message = tostring(e and e.message or e),
        level   = "error",
      }
    end)
  end
end

return M
