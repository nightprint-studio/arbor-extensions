-- main.lua — cloud-storage plugin entry point.
--
-- Thin event wiring:
--   · on_plugin_load → register sidebar + listen for progress / oauth events.
--   · Sidebar/toolbar/tree events → orchestrate via sidebar.lua / config_form.lua /
--     transfer.lua / arbor.cloud.* calls.

local state            = require("state")
local sidebar          = require("ui.sidebar")
local config_form      = require("ui.config_form")
local connections_modal = require("ui.connections_modal")
local transfer         = require("ui.transfer")
local settings         = require("settings")
local chunks           = require("chunks")

-- ── Lifecycle ───────────────────────────────────────────────────────────────

-- Right-click items. Re-runnable: it unregisters + re-contributes so the
-- chunk-related entries can appear/disappear based on whether any
-- chunk-handler plugin is currently contributing. Called at load + on every
-- sidebar open (`panel:open:cloud`), so installing/disabling a chunk-handler
-- plugin reflects on the next sidebar visit.
local function unregister_id(item_id)
  pcall(function()
    arbor.ui.unregister_contribution("cloud-storage:cloud:context_menu", item_id)
  end)
end

local function register_context_menu()
  -- Wipe everything we own first so toggling a chunk-handler plugin doesn't
  -- leave stale entries. Idempotent on missing ids. Includes the legacy
  -- "Copy gs:// URI" entries from earlier releases — drop on every refresh.
  for _, id in ipairs({
    "ctx-download", "ctx-stat", "ctx-reveal", "ctx-delete-file",
    "ctx-open", "ctx-sync-down-here", "ctx-delete-folder",
    "ctx-multi-download", "ctx-multi-chunks-auto", "ctx-multi-chunks-custom",
    "ctx-multi-sep", "ctx-multi-delete",
    "ctx-copy-uri-file", "ctx-copy-uri-folder",
  }) do unregister_id(id) end

  -- ── Single-row: object (file) ────────────────────────────────────────────
  arbor.ui.contribute("cloud-storage:cloud:context_menu", {
    id = "ctx-download",
    payload = { label = "Download…", action = "cloud:download_picker", icon = "Download" },
    when = { kind = "object", multi = false },
  })
  arbor.ui.contribute("cloud-storage:cloud:context_menu", {
    id = "ctx-stat",
    payload = { label = "Properties…", action = "cloud:stat_modal", icon = "Info" },
    when = { kind = "object", multi = false },
  })
  arbor.ui.contribute("cloud-storage:cloud:context_menu", {
    id = "ctx-reveal",
    payload = { label = "Reveal in folder", action = "cloud:reveal_in_folder", icon = "FolderOpen" },
    when = { kind = "object", multi = false },
  })
  arbor.ui.contribute("cloud-storage:cloud:context_menu", {
    id = "ctx-delete-file",
    payload = { label = "Delete…", action = "cloud:delete_object", icon = "Trash2", danger = true },
    when = { kind = "object", multi = false },
  })

  -- ── Single-row: folder ───────────────────────────────────────────────────
  arbor.ui.contribute("cloud-storage:cloud:context_menu", {
    id = "ctx-open",
    payload = { label = "Open", action = "cloud:open_folder", icon = "FolderOpen" },
    when = { kind = "folder", multi = false },
  })
  arbor.ui.contribute("cloud-storage:cloud:context_menu", {
    id = "ctx-sync-down-here",
    payload = { label = "Sync this folder → local…",
                action = "cloud:sync_down_here", icon = "ArrowDownToLine" },
    when = { kind = "folder", multi = false },
  })
  arbor.ui.contribute("cloud-storage:cloud:context_menu", {
    id = "ctx-delete-folder",
    payload = { label = "Delete (recursive)…",
                action = "cloud:delete_object_recursive", icon = "Trash2", danger = true },
    when = { kind = "folder", multi = false },
  })

  -- ── Multi-selection: bulk actions on N files ────────────────────────────
  arbor.ui.contribute("cloud-storage:cloud:context_menu", {
    id = "ctx-multi-download",
    payload = { label = "Download files…",
                action = "cloud:multi_download", icon = "Download" },
    when = { kind = "object", multi = true },
  })

  -- Chunk-merge entries are visible only when at least one chunk-handler
  -- plugin is currently contributing.
  if #chunks.list_handlers() > 0 then
    arbor.ui.contribute("cloud-storage:cloud:context_menu", {
      id = "ctx-multi-chunks-auto",
      payload = { label = "Download chunks (auto-order by date)",
                  action = "cloud:multi_dl_chunks_auto", icon = "Combine" },
      when = { kind = "object", multi = true },
    })
    arbor.ui.contribute("cloud-storage:cloud:context_menu", {
      id = "ctx-multi-chunks-custom",
      payload = { label = "Download chunks (custom order…)",
                  action = "cloud:multi_dl_chunks_custom", icon = "ListOrdered" },
      when = { kind = "object", multi = true },
    })
  end

  arbor.ui.contribute("cloud-storage:cloud:context_menu", {
    id = "ctx-multi-sep",
    payload = { separator = true },
    when = { kind = "object", multi = true },
  })
  arbor.ui.contribute("cloud-storage:cloud:context_menu", {
    id = "ctx-multi-delete",
    payload = { label = "Delete files…",
                action = "cloud:multi_delete", icon = "Trash2", danger = true },
    when = { kind = "object", multi = true },
  })
end

arbor.events.on("on_plugin_load", function(ctx)
  -- Pure registration only — no fetches, no fire_hook_on cascades.
  sidebar.register()
  register_context_menu()
  settings.register()
  arbor.log.info("cloud-storage ready (api_version=" .. ctx.api_version .. ")")
end)

-- First-paint trigger. PluginTreeSidebar.svelte fires this on mount; we
-- also fire it once when the user re-selects the sidebar after closing it.
-- Re-registering the context menu here is how we react to chunk-handler
-- plugins being installed/disabled after our own load.
arbor.events.on("panel:open:cloud", function(_ctx)
  register_context_menu()
  sidebar.refresh()
end)

-- Settings panel hooks.
arbor.events.on("cloud:settings-refresh", function(_ctx)
  settings.contribute_sections()
end)
arbor.events.on("cloud:settings-save", function(ctx)
  if ctx.parallel_downloads ~= nil then
    settings.set_parallel_downloads(ctx.parallel_downloads)
  end
  if ctx.list_hard_cap ~= nil then
    settings.set_list_hard_cap(ctx.list_hard_cap)
  end
end)

-- Streaming list chunks land here. The host calls `fire_hook_on` on this
-- exact name from `cloud::ops::list_stream`; the sidebar accumulator
-- ignores stale streams via stream_id mismatch.
arbor.events.on("cloud-storage:list-chunk", function(ev)
  sidebar.on_chunk(ev)
end)

-- ── Toolbar actions ────────────────────────────────────────────────────────

arbor.events.on("cloud:refresh", function(_ctx)
  sidebar.refresh()
end)

-- Hard refresh — wipes the listing cache for the active connection before
-- re-fetching. Bound to the ↻ toolbar button.
arbor.events.on("cloud:hard_refresh", function(_ctx)
  local sel = state.selected_id()
  if sel ~= "" then sidebar.clear_cache(sel) end
  sidebar.refresh({ use_cache = false })
end)

-- ── Wildcard search ────────────────────────────────────────────────────────
--
-- The built-in PluginTreeSidebar search row (Local filter / Remote search
-- toggle) is the single entry point. Pressing Enter in "Remote" mode fires
-- `cloud:search_input_submit` and we run the backend wildcard search scoped
-- to the current breadcrumb folder.

arbor.events.on("cloud:search_input_submit", function(ctx)
  local pattern = ctx.pattern or ""
  if pattern == "" then return end
  sidebar.start_search(pattern, "current")
end)

arbor.events.on("cloud:search_clear", function(_ctx)
  sidebar.clear_search()
end)

-- Jump to an arbitrary breadcrumb level.
arbor.events.on("cloud:nav_to", function(ctx)
  local d = ctx.data or {}
  if not d.config_id then return end
  state.set_active_bucket(d.config_id, d.bucket or "")
  state.set_active_prefix(d.config_id, d.prefix or "")
  sidebar.refresh()
end)

-- Jump to a path typed by the user in the breadcrumb's edit-in-place input.
-- Object stores have no real "directory exists" concept — prefixes are
-- inferred from object keys — so we navigate and let the listing decide
-- whether to surface "Empty folder." or content. If the user typed a path
-- that turns out to have no objects, we additionally surface a one-shot
-- notify so they realise it wasn't a typo on our side.
arbor.events.on("cloud:nav_to_typed_path", function(ctx)
  local sel = state.selected_id()
  if sel == "" then return end
  local conn = state.find(sel)
  if not conn then return end

  -- Normalise: trim leading slashes, collapse repeated slashes, ensure the
  -- result ends with `/` (opendal needs that for prefix listing). Empty
  -- input == jump back to bucket root.
  local raw = ctx.path or ""
  local path = raw:gsub("^[/\\]+", ""):gsub("[\\]+", "/"):gsub("//+", "/")
  if path ~= "" and not path:match("/$") then path = path .. "/" end

  local bucket = state.active_bucket(conn.id)
  if (bucket or "") == "" then bucket = conn.default_bucket or "" end

  -- Synchronous probe with a tiny limit just to detect "no objects at all".
  -- We deliberately use the non-streaming `arbor.cloud.list` so we know the
  -- answer before navigating — keeps the notify in sync with the listing.
  local page, err = arbor.cloud.list({
    conn   = state.envelope(conn),
    bucket = bucket,
    prefix = path,
    limit  = 1,
  })
  if err then
    arbor.notify{ title = "Go to path", level = "error",
      message = "Listing failed: " .. tostring(err) }
    return
  end

  state.set_active_bucket(conn.id, bucket)
  state.set_active_prefix(conn.id, path)
  sidebar.refresh({ use_cache = false })

  local empty = (not page) or (not page.items) or (#page.items == 0)
  if empty and path ~= "" then
    arbor.notify{
      title   = "No objects under \"" .. path .. "\"",
      message = "Either the path doesn't exist yet, or you can't list its "
             .. "objects. Use the breadcrumb chips to back out.",
      level   = "warning",
    }
  end
end)

-- ── Connections-manager modal (replaces new/edit/delete toolbar trio) ─────

arbor.events.on("cloud:manage_connections", function(_ctx)
  connections_modal.open()
end)
arbor.events.on("cloud:conn_modal_select",        function(ctx) connections_modal.on_select(ctx)        end)
arbor.events.on("cloud:conn_modal_add",           function(ctx) connections_modal.on_add(ctx)           end)
arbor.events.on("cloud:conn_modal_delete",        function(ctx) connections_modal.on_delete(ctx)        end)
arbor.events.on("cloud:conn_modal_delete_active", function(ctx) connections_modal.on_delete_active(ctx) end)
arbor.events.on("cloud:conn_modal_test",   function(ctx) connections_modal.on_test(ctx)   end)
arbor.events.on("cloud:conn_modal_oauth",  function(ctx) connections_modal.on_oauth(ctx)  end)
arbor.events.on("cloud:conn_modal_save",   function(ctx)
  connections_modal.on_save(ctx)
  sidebar.refresh()
end)
arbor.events.on("cloud:conn_modal_close",  function(ctx) connections_modal.on_close(ctx)  end)

arbor.events.on("cloud:upload_picker", function(_ctx)
  transfer.upload_picker()
end)

-- ── Connection picker / navigation ─────────────────────────────────────────

arbor.events.on("cloud:select_connection", function(ctx)
  local v = ctx.value or ""
  if v == "__new__" then
    connections_modal.open()
    return
  end
  if v == "__divider__" then return end
  state.set_selected(v)
  state.set_active_prefix(v, "") -- reset breadcrumb when switching
  sidebar.refresh()
end)

arbor.events.on("cloud:open_folder", function(ctx)
  local d = ctx.data or {}
  if not d.config_id or not d.path then return end
  state.set_active_bucket(d.config_id, d.bucket or "")
  state.set_active_prefix(d.config_id, d.path)
  sidebar.refresh()
end)

arbor.events.on("cloud:go_up", function(ctx)
  local d = ctx.data or {}
  if not d.config_id then return end
  local prefix = d.prefix or ""
  if prefix == "" then return end
  -- Strip the last segment: "a/b/c/" → "a/b/".
  local parent = prefix:gsub("/$", ""):gsub("/[^/]+$", "/")
  if parent == prefix then parent = "" end
  state.set_active_prefix(d.config_id, parent)
  sidebar.refresh()
end)

-- ── Download / upload / sync from sidebar context ──────────────────────────

arbor.events.on("cloud:download_picker",       transfer.download_picker)
arbor.events.on("cloud:download_target_picked", transfer.download_target_picked)
arbor.events.on("cloud:upload_target_picked",   transfer.upload_target_picked)
arbor.events.on("cloud:upload_confirm",         transfer.upload_confirm)
arbor.events.on("cloud:sync_target_picked",     transfer.sync_target_picked)
arbor.events.on("cloud:sync_confirm",           transfer.sync_confirm)
arbor.events.on("cloud:cancel_transfer",        function(_ctx) end)

arbor.events.on("cloud:sync_up",   function(_ctx) transfer.sync_picker("up")   end)
arbor.events.on("cloud:sync_down", function(_ctx) transfer.sync_picker("down") end)

-- ── Context-menu actions ───────────────────────────────────────────────────

arbor.events.on("cloud:noop", function(_ctx) end)

-- ── Multi-selection bulk actions ───────────────────────────────────────────

arbor.events.on("cloud:multi_download",        function(ctx) chunks.multi_download(ctx)        end)
arbor.events.on("cloud:multi_dl_chunks_auto",  function(ctx) chunks.multi_dl_chunks(ctx, "auto")   end)
arbor.events.on("cloud:multi_dl_chunks_custom",function(ctx) chunks.multi_dl_chunks(ctx, "custom") end)
arbor.events.on("cloud:multi_delete",          function(ctx) chunks.multi_delete(ctx)          end)

-- Chunk-merge orchestrator: when the host has finished downloading the
-- N chunks, this hook fires with the local_paths. We forward them to the
-- selected chunk-handler service and emit the modal terminal update.
arbor.events.on("cloud-storage:download-many-done", function(ev)
  chunks.on_download_many_done(ev)
end)

-- Drag-reorder picker reply (custom-order chunks flow).
arbor.events.on("cloud:chunk-order-picked", function(ctx)
  chunks.on_chunk_order_picked(ctx)
end)

-- Chunk-handler radio-picker reply.
arbor.events.on("cloud:chunk-handler-picked", function(ctx)
  chunks.on_handler_picked(ctx)
end)

arbor.events.on("cloud:stat_modal", function(ctx)
  local d = ctx.data or {}
  local conn = state.find(d.config_id)
  if not conn or not d.bucket or not d.path then return end
  local obj, err = arbor.cloud.stat({
    conn   = state.envelope(conn),
    bucket = d.bucket,
    path   = d.path,
  })
  if err then
    arbor.notify{ title = "Properties failed", message = tostring(err), level = "error" }
    return
  end
  arbor.ui.form({
    title         = "Object properties",
    submit_label  = "Close",
    submit_action = "cloud:noop",
    cancel_label  = nil,
    width         = "560px",
    height        = "520px",
    nodes = {
      { type = "text", name = "path",  label = "Path",         default = obj.path or "",                  readonly = true },
      { type = "text", name = "size",  label = "Size (bytes)", default = tostring(obj.size or ""),        readonly = true },
      { type = "text", name = "type",  label = "Content type", default = obj.content_type or "",          readonly = true },
      { type = "text", name = "etag",  label = "ETag",         default = obj.etag or "",                  readonly = true },
      { type = "text", name = "mtime", label = "Last modified",default = obj.last_modified or "",         readonly = true },
    },
  })
end)

arbor.events.on("cloud:delete_object_recursive", function(ctx)
  -- Same flow as `cloud:delete_object` but forces recursive = true (used by
  -- the folder variant of the context menu).
  local d = ctx.data or {}
  d.is_dir = true
  arbor.events.emit("cloud:delete_object", { data = d })
end)

arbor.events.on("cloud:sync_down_here", function(ctx)
  -- Right-click "Sync this folder → local…" — preselects the folder's
  -- prefix in the sync flow so the user only has to pick the local target.
  local d = ctx.data or {}
  if not d.config_id or not d.bucket or not d.path then return end
  state.set_active_prefix(d.config_id, d.path)
  transfer.sync_picker("down")
end)

-- Right-click "Reveal in folder" — jump the breadcrumb to the parent of the
-- selected object. Most useful from a search-result row (where the user
-- sees a flat path and wants the surrounding folder) but works everywhere.
-- If the user is currently in search mode we exit it so the browser opens
-- on the parent prefix instead of a still-filtered result list.
arbor.events.on("cloud:reveal_in_folder", function(ctx)
  local d = ctx.data or {}
  if not d.config_id or not d.path then return end
  -- "a/b/c/file.bin" → "a/b/c/"; root-level file → "".
  local parent = d.path:match("^(.*/)") or ""
  state.set_active_bucket(d.config_id, d.bucket or "")
  state.set_active_prefix(d.config_id, parent)
  -- clear_search is a safe no-op when not in search mode; in either case
  -- it calls sidebar.refresh() so no second refresh is needed here.
  sidebar.clear_search()
end)

-- Right-click on a folder / object opens a small confirmation form for delete.
arbor.events.on("cloud:delete_object", function(ctx)
  local d = ctx.data or {}
  if not d.config_id or not d.bucket or not d.path then return end
  local conn = state.find(d.config_id)
  if not conn then return end
  arbor.ui.confirm({
    title         = "Delete from cloud",
    message       = "Permanently delete `" .. d.path .. "` from bucket `" .. d.bucket .. "`?",
    confirm_label = "Delete",
    confirm_kind  = "danger",
    cancel_label  = "Cancel",
    on_confirm    = function()
      local _, err = arbor.cloud.delete({
        conn      = state.envelope(conn),
        bucket    = d.bucket,
        path      = d.path,
        recursive = d.is_dir and true or false,
      })
      if err then
        arbor.notify{ title = "Delete failed", message = tostring(err), level = "error" }
      else
        arbor.notify{ title = "Deleted", message = d.path, level = "success" }
        -- Object disappeared → cached listings are stale.
        sidebar.clear_cache(d.config_id)
        sidebar.refresh({ use_cache = false })
      end
    end,
  })
end)

-- Any transfer completion invalidates the cache (uploads change the listing,
-- downloads don't, but it's cheaper to invalidate than to guess from the
-- event payload — the next click re-fetches in ~300ms). When the job was
-- previously registered via `state.remember_job` (single download / bulk),
-- we also surface a success notification with an "Open folder" action that
-- reveals the resulting file (reveal=true) or opens the target folder.
arbor.events.on("cloud-storage:job-done", function(ev)
  if not ev then return end
  local job_id = ev.job_id or ""
  local meta   = state.take_pending_job(job_id)

  if ev.ok then
    local sel = state.selected_id()
    if sel ~= "" then sidebar.clear_cache(sel) end
    -- Don't auto-refresh; the user may have navigated away. They'll see the
    -- fresh listing on their next click. (Auto-refreshing here can fight a
    -- user mid-navigation and feels jumpy.)

    if meta and meta.local_path and meta.local_path ~= "" then
      local title = (meta.kind == "download") and "Download complete"
                 or (meta.kind == "merge")    and "Chunks merged"
                 or "Done"
      arbor.notify{
        title   = title,
        message = meta.label or meta.local_path,
        level   = "success",
        action  = {
          kind   = "open-path",
          label  = "Open folder",
          path   = meta.local_path,
          reveal = meta.reveal ~= false,  -- default true
        },
      }
    end
  elseif meta and meta.local_path then
    -- Failed: notify too, but without the Open-folder action since the
    -- file may be partial or absent. Users still want to know it ended.
    arbor.notify{
      title   = (meta.kind == "download") and "Download failed"
             or (meta.kind == "merge")    and "Chunk merge failed"
             or "Job failed",
      message = tostring(ev.error or "transfer failed"),
      level   = "error",
    }
  end
end)

-- ── Config form submission ─────────────────────────────────────────────────

local function read_form_into_conn(ctx, sctx)
  local conn = state.find(sctx.conn_id) or {
    id = sctx.conn_id, provider = "gcs", gcs = {},
  }
  conn.name           = (ctx.name or ""):gsub("^%s+", ""):gsub("%s+$", "")
  conn.provider       = ctx.provider or "gcs"
  conn.project_id     = ctx.project_id or ""
  conn.default_bucket = ctx.default_bucket or ""
  conn.gcs            = conn.gcs or {}
  conn.gcs.method     = ctx.auth_method or conn.gcs.method or "sa_file"

  if conn.gcs.method == "sa_file" then
    conn.gcs.path = ctx.sa_path or ""
    conn.gcs.secret_ref = nil
  elseif conn.gcs.method == "sa_inline" then
    conn.gcs.secret_ref = "gcs/" .. conn.id
    -- The textarea content is stored to the keyring once on save and never
    -- echoed back to the UI on subsequent edits.
    if ctx.sa_json and ctx.sa_json ~= "" then
      local _, err = arbor.cloud.secret_set(conn.gcs.secret_ref, ctx.sa_json)
      if err then arbor.log.warn("save SA inline secret: " .. tostring(err)) end
    end
  elseif conn.gcs.method == "adc" or conn.gcs.method == "gcloud_cli" then
    conn.gcs.secret_ref = nil
    conn.gcs.path       = nil
  elseif conn.gcs.method == "oauth" then
    conn.gcs.secret_ref = "gcs/" .. conn.id .. "/oauth"
    conn.gcs.client_id  = ctx.oauth_client_id or conn.gcs.client_id or ""
  end
  return conn
end

arbor.events.on("cloud:save_connection", function(ctx)
  local sctx = ctx.state or {}
  if not sctx.conn_id then return end
  if (ctx.name or "") == "" then
    arbor.notify{ title = "Save", message = "Name is required.", level = "warning" }
    return
  end
  local conn = read_form_into_conn(ctx, sctx)
  state.upsert(conn)
  if state.selected_id() == "" then state.set_selected(conn.id) end

  -- For oauth-mode connections without a refresh token yet, kick off
  -- the flow immediately so the user lands on a connected state.
  if conn.gcs.method == "oauth"
     and (not conn.gcs.secret_ref or
          not select(1, arbor.cloud.secret_exists(conn.gcs.secret_ref))) then
    arbor.events.emit("cloud:start_oauth_for", { config_id = conn.id })
  end

  arbor.notify{ title = "Connection saved", message = conn.name, level = "success" }
  sidebar.refresh()
end)

arbor.events.on("cloud:cancel_form", function(_ctx) end)

-- ── Inline buttons inside the form ─────────────────────────────────────────

arbor.events.on("cloud:test_connection_inline", function(ctx)
  local sctx = ctx.state or {}
  local conn = read_form_into_conn(ctx, sctx)
  local env  = state.envelope(conn)
  -- Non-blocking: arbor freezes for the duration of test_connection on slow
  -- networks. Dispatch and listen for the result instead so the form stays
  -- responsive. A simple counter scopes each click to its own callback.
  arbor.notify{ title = "Testing connection…", message = conn.name or "", level = "info" }
  arbor.cloud.test_connection_async({
    conn       = env,
    bucket     = ctx.default_bucket or conn.default_bucket or "",
    on_done    = "cloud:test_connection_inline_done",
    request_id = tostring(conn.id or "inline"),
  })
end)

-- Shared handler for both the inline-form and the connections-modal tests —
-- the only difference between the two flows is the event name (so a
-- modal-triggered test never lands on an inline form callback or vice
-- versa). Same result UX in both cases.
local function handle_test_done(ev)
  if not ev.ok then
    arbor.notify{ title = "Test failed", message = tostring(ev.error or "unknown error"), level = "error" }
    return
  end
  local rep = ev.reply or {}
  if rep.ok then
    local detail = "Auth: " .. (rep.auth_method or "?")
    if rep.identity and rep.identity ~= "" then detail = detail .. " · " .. rep.identity end
    arbor.notify{ title = "Connection OK", message = detail, level = "success" }
  else
    arbor.notify{
      title = "Connection failed",
      message = rep.error or "unknown error",
      level = "error"
    }
  end
end

arbor.events.on("cloud:test_connection_inline_done", handle_test_done)
arbor.events.on("cloud:test_connection_modal_done",  handle_test_done)

arbor.events.on("cloud:start_oauth_inline", function(ctx)
  local sctx = ctx.state or {}
  local conn = read_form_into_conn(ctx, sctx)
  -- Persist the connection so the secret_ref it uses matches what we
  -- store after the flow completes. The OAuth-done handler refreshes
  -- the sidebar; we don't close the form so the user can verify.
  state.upsert(conn)
  arbor.events.emit("cloud:start_oauth_for", {
    config_id     = conn.id,
    client_id     = ctx.oauth_client_id or "",
    client_secret = ctx.oauth_client_secret or "",
  })
end)

arbor.events.on("cloud:start_oauth_for", function(ev)
  local conn = state.find(ev.config_id)
  if not conn or conn.gcs.method ~= "oauth" then return end
  local _, err = arbor.cloud.oauth_start({
    secret_ref    = conn.gcs.secret_ref,
    client_id     = ev.client_id     or conn.gcs.client_id or "",
    client_secret = ev.client_secret or "",
  })
  if err then
    arbor.notify{ title = "Authorize failed", message = tostring(err), level = "error" }
    return
  end
  arbor.notify{
    title = "Authorize with Google",
    message = "A browser window opened. Approve the request, then come back.",
    level = "info",
  }
end)

-- Backend fires the `cloud-storage:oauth-done` hook with {ok, error?, secret_ref?}
-- once the loopback callback completes.
arbor.events.on("cloud-storage:oauth-done", function(ev)
  if ev and ev.ok then
    arbor.notify{
      title = "Cloud Storage",
      message = "Google authorization successful — refresh token stored.",
      level = "success",
    }
    sidebar.refresh()
  else
    arbor.notify{
      title = "Authorize failed",
      message = (ev and ev.error) or "unknown error",
      level = "error",
    }
  end
end)

-- ── Delete connection (from a small confirm flow) ──────────────────────────

arbor.events.on("cloud:delete_connection", function(_ctx)
  local id = state.selected_id()
  if id == "" then return end
  local conn = state.find(id)
  if not conn then return end
  arbor.ui.confirm({
    title         = "Delete connection",
    message       = "Remove \"" .. (conn.name or id) .. "\"? Any secret stored "
                  .. "in your keyring for this connection will be wiped.",
    confirm_label = "Delete",
    confirm_kind  = "danger",
    cancel_label  = "Cancel",
    on_confirm    = function()
      state.drop_secrets_for(conn)
      state.delete(id)
      state.set_selected("")
      sidebar.refresh()
      arbor.notify{ title = "Connection deleted", message = conn.name or id, level = "info" }
    end,
  })
end)

-- ── Sync via command palette / future menu entry ───────────────────────────

arbor.command.register({
  id          = "sync-down",
  title       = "Cloud Storage · Sync down (cloud → local)",
  description = "Mirror a remote prefix onto a local folder.",
  icon        = "ArrowDownToLine",
})
arbor.command.register({
  id          = "sync-up",
  title       = "Cloud Storage · Sync up (local → cloud)",
  description = "Mirror a local folder onto a remote prefix.",
  icon        = "ArrowUpToLine",
})
arbor.command.register({
  id          = "manage-connections",
  title       = "Cloud Storage · Manage connections…",
  description = "Open the connections manager (add / edit / delete).",
  icon        = "Settings2",
})

arbor.events.on("command:sync-down",          function(_ctx) transfer.sync_picker("down") end)
arbor.events.on("command:sync-up",            function(_ctx) transfer.sync_picker("up")   end)
arbor.events.on("command:manage-connections", function(_ctx) connections_modal.open() end)

-- TODO(drag-drop): when arbor exposes a folder/file drop event for tree
-- sidebars, wire it here so the user can drag local files onto the cloud
-- sidebar to upload — see project_cloud_storage_plugin.md.
