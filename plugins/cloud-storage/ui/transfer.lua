-- ui/transfer.lua — file picker + confirmation flows for up/download/sync.
--
-- Pure orchestration: the heavy lifting (streaming, progress, jobs) lives
-- on the Rust side. From Lua we only:
--   1. Ask for a local path with arbor.ui.pick_file.
--   2. Confirm the target (overwrite? recursive?).
--   3. Fire arbor.cloud.upload / download / sync and let JobRegistry take over.

local state = require("state")

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
  local job_id, err = arbor.cloud.download({
    conn      = state.envelope(conn),
    bucket    = ctx.bucket,
    path      = ctx.remote_path,
    -- `local` is a Lua reserved word so we have to bracket-quote it as a
    -- table key. Rust-side the field is plain `local: String`.
    ["local"] = local_path,
  })
  if err then
    arbor.notify{ title = "Download failed to start", message = tostring(err), level = "error" }
    return
  end
  -- Remember the target so the cloud-storage:job-done listener can show a
  -- "Done — Open folder" notification with the actual local destination.
  state.remember_job(job_id, {
    kind       = "download",
    local_path = local_path,
    reveal     = true,
    label      = (ctx.remote_path or "?") .. " → " .. local_path,
  })
  arbor.notify{ title = "Download started",
                message = (ctx.remote_path or "?") .. " → " .. local_path,
                level = "info",
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
  local env = state.envelope(conn)
  local job_id, err = arbor.cloud.upload({
    conn      = env,
    bucket    = sctx.bucket,
    path      = ctx.target or "",
    ["local"] = sctx.local_path or "",
    overwrite = ctx.overwrite and true or false,
  })
  if err then
    arbor.notify{ title = "Upload failed to start", message = tostring(err), level = "error" }
    return
  end
  arbor.notify{ title = "Upload started", message = "Job " .. (job_id or "?"), level = "info" }
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
  local env = state.envelope(conn)
  local job_id, err = arbor.cloud.sync({
    conn          = env,
    bucket        = sctx.bucket,
    remote_prefix = ctx.remote_prefix or "",
    ["local"]     = sctx.local_path or "",
    direction     = sctx.direction or "down",
    delete        = ctx.delete and true or false,
  })
  if err then
    arbor.notify{ title = "Sync failed to start", message = tostring(err), level = "error" }
    return
  end
  arbor.notify{ title = "Sync started", message = "Job " .. (job_id or "?"), level = "info" }
end

return M
