-- ui/transfer.lua — the file pickers and confirmations around a transfer.
--
-- What it does: ask for a local path, confirm the target, hand the work to `transfers`.
-- What it no longer does: hand the work to Arbor. The loop that moves the bytes is Lua now
-- (`transfers.lua`), the progress card is `arbor.ui.operation`, and the store is reached
-- through whichever provider package implements it — none of which this file needs to know.

local state     = require("state")
local transfers = require("transfers")
local provider  = require("provider")

--- Refuse early, and say which package is missing.
--
-- Every flow here starts with this. Discovering "no provider" three calls in surfaces as a
-- store error, and the user goes looking at their credentials for a problem that is an
-- uninstalled package.
local function ready(conn, title)
  if provider.available(conn) then return true end
  arbor.notify{ title = title, message = provider.missing_message(conn), level = "error" }
  return false
end

local M = {}

-- ── Download: object → local file ──────────────────────────────────────────

function M.download_picker(ctx)
  local d = ctx.data or {}
  if not d.path or d.path == "" or not d.bucket or d.bucket == "" then
    arbor.notify{ title = "Download", message = "Missing object info.", level = "error" }
    return
  end
  arbor.ui.pick_file({
    mode         = "save",
    title        = "Save " .. (d.path:match("([^/]+)$") or d.path) .. " as…",
    initial_path = d.path:match("([^/]+)$") or "download.bin",
    action       = "cloud:download_target_picked",
    -- IMPORTANT: do NOT name an `extra` field `path` — the picker's result
    -- already uses `ctx.path` for the local target the user picked, so a
    -- collision either overwrites the remote path (on confirm) or leaks
    -- the remote path through `ctx.path` on cancel and we end up firing
    -- a phantom download against the bucket. Keep remote keys prefixed.
    extra = {
      config_id   = d.config_id,
      bucket      = d.bucket,
      remote_path = d.path,
    },
  })
end

function M.download_target_picked(ctx)
  -- Empty path = picker cancelled. Bail out *before* touching anything else
  -- so we don't kick off an "Untitled" download job in the background.
  local local_path = ctx.path or ""
  if local_path == "" then return end
  if not ctx.remote_path or ctx.remote_path == "" then return end

  local conn = state.find(ctx.config_id)
  if not conn then
    arbor.notify{ title = "Download", message = "Connection no longer exists.", level = "error" }
    return
  end
  if not ready(conn, "Download") then return end

  local op_id, err = transfers.download(conn, ctx.bucket, ctx.remote_path, local_path)
  -- Remember the target so the completion listener can offer "Open folder" with the actual
  -- local destination.
  state.remember_job(op_id, {
    kind       = "download",
    local_path = local_path,
    reveal     = true,
    label      = (ctx.remote_path or "?") .. " → " .. local_path,
  })
  if err then
    arbor.notify{ title = "Download failed", message = tostring(err), level = "error" }
    return
  end
  arbor.notify{ title = "Download finished",
                message = (ctx.remote_path or "?") .. " → " .. local_path,
                level = "success",
                persist = false }
end

-- ── Upload: local file → object ────────────────────────────────────────────

function M.upload_picker()
  local conn = state.find(state.selected_id())
  if not conn then
    arbor.notify{ title = "Upload", message = "Select a connection first.", level = "warning" }
    return
  end
  arbor.ui.pick_file({
    mode    = "file",
    title   = "Choose a file to upload",
    action  = "cloud:upload_target_picked",
    extra   = { config_id = conn.id },
  })
end

function M.upload_target_picked(ctx)
  if not ctx.path or ctx.path == "" then return end -- user cancelled
  local conn = state.find(ctx.config_id)
  if not conn then return end
  local bucket = state.active_bucket(conn.id)
  if (bucket or "") == "" then bucket = conn.default_bucket or "" end
  if bucket == "" then
    arbor.notify{ title = "Upload", message = "No bucket selected.", level = "warning" }
    return
  end
  local prefix = state.active_prefix(conn.id) or ""
  local filename = ctx.path:match("[^/\\]+$") or "upload.bin"
  local target_default = prefix .. filename

  -- Confirm target key + overwrite policy in a tiny form.
  arbor.ui.form({
    title         = "Upload to " .. bucket,
    submit_label  = "Upload",
    submit_action = "cloud:upload_confirm",
    cancel_label  = "Cancel",
    cancel_action = "cloud:cancel_transfer",
    width         = "520px",
    height        = "360px",
    state         = { config_id = conn.id, bucket = bucket, local_path = ctx.path },
    nodes = {
      { type = "label", text = "Source: " .. ctx.path },
      { type = "input", name = "target", label = "Target object key *",
        default = target_default, required = true,
        hint = "Path inside the bucket. Folders are implied by `/`." },
      { type = "checkbox", name = "overwrite", label = "Overwrite if exists",
        default = false },
    },
  })
end

function M.upload_confirm(ctx)
  local sctx = ctx.state or {}
  local conn = state.find(sctx.config_id)
  if not conn then return end
  if not ready(conn, "Upload") then return end

  local key = ctx.target or ""
  -- Overwrite is checked here rather than passed down: a store has no "create if absent" for
  -- an object write, so the only honest implementation is to look first — and looking is a
  -- `stat`, which is one request and tells the user before anything is sent.
  if not ctx.overwrite then
    local existing = provider.stat(conn, sctx.bucket, key)
    if existing then
      arbor.notify{
        title   = "Upload",
        message = key .. " already exists. Tick \"Overwrite if exists\" to replace it.",
        level   = "warning",
      }
      return
    end
  end

  local size = tonumber(sctx.local_size) or 0
  local _, err = transfers.upload(conn, sctx.bucket, key, sctx.local_path or "", { size = size })
  if err then
    arbor.notify{ title = "Upload failed", message = tostring(err), level = "error" }
    return
  end
  arbor.notify{ title = "Upload finished", message = key, level = "success" }
end

-- ── Sync (recursive) ───────────────────────────────────────────────────────

function M.sync_picker(direction)
  local conn = state.find(state.selected_id())
  if not conn then
    arbor.notify{ title = "Sync", message = "Select a connection first.", level = "warning" }
    return
  end
  local mode = (direction == "up") and "folder" or "folder"
  arbor.ui.pick_file({
    mode   = mode,
    title  = direction == "up"
              and "Choose local folder to sync UP to the cloud"
              or  "Choose local folder to sync DOWN from the cloud",
    action = "cloud:sync_target_picked",
    extra  = { config_id = conn.id, direction = direction },
  })
end

function M.sync_target_picked(ctx)
  if not ctx.path or ctx.path == "" then return end
  local conn = state.find(ctx.config_id)
  if not conn then return end
  local bucket = state.active_bucket(conn.id)
  if (bucket or "") == "" then bucket = conn.default_bucket or "" end
  local prefix = state.active_prefix(conn.id) or ""
  arbor.ui.form({
    title         = (ctx.direction == "up" and "Sync ↑ to " or "Sync ↓ from ") .. bucket,
    submit_label  = "Start sync",
    submit_action = "cloud:sync_confirm",
    cancel_label  = "Cancel",
    cancel_action = "cloud:cancel_transfer",
    width         = "560px",
    height        = "380px",
    state         = {
      config_id  = conn.id, bucket = bucket,
      local_path = ctx.path, direction = ctx.direction,
    },
    nodes = {
      { type = "label", text = "Local: " .. ctx.path },
      { type = "input", name = "remote_prefix", label = "Remote prefix",
        default = prefix,
        hint = "Empty syncs against the bucket root." },
      { type = "checkbox", name = "delete",
        label = "Delete files at the destination that don't exist at the source",
        default = false,
        hint = "Use with care — this mirrors the source instead of merging." },
    },
  })
end

function M.sync_confirm(ctx)
  local sctx = ctx.state or {}
  local conn = state.find(sctx.config_id)
  if not conn then return end
  if not ready(conn, "Sync") then return end

  local dir = sctx.local_path or ""
  if (sctx.direction or "down") ~= "down" then
    -- Sync UP walks the local tree, and which files are "in" it is a question about the
    -- user's intent (hidden files, ignore rules) that this flow has never asked. Rather than
    -- guess at it, say so: the download direction is the one that has a plan behind it.
    arbor.notify{
      title   = "Sync up",
      message = "Only sync DOWN is available. Upload a folder with Upload instead.",
      level   = "warning",
    }
    return
  end

  -- The destination, as the planner compares it: keys relative to the folder, with the size
  -- and mtime the filesystem reports. Built here because "which local files count" is this
  -- flow's decision, not the planner's.
  local local_entries = {}
  for _, path in ipairs(arbor.fs.glob(dir, "*") or {}) do
    -- `glob` walks recursively and returns paths; `stat` is what carries the size and the
    -- mtime the plan compares against. Two calls per file, both local.
    local info = arbor.fs.stat(path)
    if info and info.is_file then
      local rel = path:sub(#dir + 2)
      local_entries[#local_entries + 1] = {
        key      = (rel:gsub("\\", "/")),
        size     = info.size or 0,
        modified = info.modified,
      }
    end
  end

  local _, err = transfers.sync_down(
    conn, sctx.bucket, ctx.remote_prefix or "", dir, local_entries,
    { overwrite = "if-newer", ["delete-extraneous"] = ctx.delete and true or false }
  )
  if err then
    arbor.notify{ title = "Sync failed", message = tostring(err), level = "error" }
    return
  end
end

return M
