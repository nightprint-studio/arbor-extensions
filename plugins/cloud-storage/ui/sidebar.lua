-- ui/sidebar.lua — IntelliJ "Big Data Tools"-style cloud storage browser.
--
-- Tree layout
--   ── [bucket / breadcrumb segments / current folder]   (clickable, jumps up)
--   ── (Loading… | empty | rows)
--
-- Each navigation does two `tree.set` calls so the user sees the "Loading…"
-- placeholder + skeleton breadcrumb before the network roundtrip finishes —
-- without that, the sidebar feels frozen because `arbor.cloud.list` blocks
-- the plugin VM for ~200–500ms per click.  The per-prefix listing cache
-- (`M._cache`) makes back-navigation instant; the toolbar's refresh button
-- clears it explicitly.

local state    = require("state")
local settings = require("settings")

local M = {}

local SIDEBAR_ID = "cloud"
local PLUGIN     = "cloud-storage"
local NS         = PLUGIN .. ":" .. SIDEBAR_ID

-- ── In-memory listing cache (per VM-lifetime) ──────────────────────────────
-- Shape: M._cache[<key>] = { items, truncated }   (final, fully-loaded page)
-- An in-flight stream keeps its partials in `M._inflight` until it `done`s,
-- then we commit them here so subsequent navigations are instant.
M._cache    = {}
M._inflight = nil   -- { stream_id, conn_id, bucket, prefix, title, crumb, items, truncated }

local function cache_key(conn_id, bucket, prefix)
  return (conn_id or "") .. "|" .. (bucket or "") .. "|" .. (prefix or "")
end

local function cache_get(conn_id, bucket, prefix)
  return M._cache[cache_key(conn_id, bucket, prefix)]
end

local function cache_put(conn_id, bucket, prefix, page)
  M._cache[cache_key(conn_id, bucket, prefix)] = page
end

function M.clear_cache(conn_id)
  if not conn_id then M._cache = {}; return end
  local prefix = (conn_id or "") .. "|"
  for k in pairs(M._cache) do
    if k:sub(1, #prefix) == prefix then M._cache[k] = nil end
  end
end

-- Monotonic stream id source — embedded in the chunk events so stale streams
-- (when the user navigates mid-load) can be ignored.
M._stream_counter = 0
local function new_stream_id()
  M._stream_counter = M._stream_counter + 1
  return "cs-" .. tostring(M._stream_counter) .. "-" .. tostring(math.floor(os.time()))
end

-- Current search state (nil when in regular browse mode). When active the
-- sidebar renders a flat result list instead of the folder browser.
--   { stream_id, conn_id, bucket, root_prefix, pattern, scope, items, done }
M._search = nil

-- ── Public: register the section ───────────────────────────────────────────

function M.register()
  arbor.ui.add_sidebar({
    id          = SIDEBAR_ID,
    label       = "Cloud Storage",
    icon        = "Cloud",
    side        = "right",
    position    = "top",
    kind        = "tree",
    tooltip     = "Cloud Storage — browse, upload, download",
    collapsable = false,
    -- Built-in search row: two modes via the host PluginTreeSidebar toggle.
    --   "local"  — substring filter on already-loaded rows (cheap, default).
    --   "remote" — Enter fires `cloud:search_input_submit` and runs a
    --              recursive wildcard search against the bucket (`*`, `?`,
    --              `**` per doc.html). The wildcard hint nudges users who
    --              start typing globs in local mode to swap over.
    search = {
      modes              = { "local", "remote" },
      default            = "local",
      remote_action      = "cloud:search_input_submit",
      placeholder_local  = "Filter loaded rows…",
      placeholder_remote = "Search bucket (Enter to run, wildcards *, ?)",
      wildcard_hint      = true,
    },
  })

  arbor.ui.add_toolbar_action({
    id      = "refresh",
    target  = NS .. ":toolbar",
    action  = "cloud:hard_refresh",
    icon    = "RefreshCw",
    tooltip = "Refresh listing (clears cache)",
  })
  arbor.ui.add_toolbar_action({
    id      = "manage-conns",
    target  = NS .. ":toolbar",
    action  = "cloud:manage_connections",
    icon    = "Settings2",
    tooltip = "Manage connections… (add, edit, delete)",
  })
  arbor.ui.add_toolbar_action({
    id      = "upload",
    target  = NS .. ":toolbar",
    action  = "cloud:upload_picker",
    icon    = "Upload",
    tooltip = "Upload a local file…",
  })
  arbor.ui.add_toolbar_action({
    id      = "sync-down",
    target  = NS .. ":toolbar",
    action  = "cloud:sync_down",
    icon    = "ArrowDownToLine",
    tooltip = "Sync down (cloud → local)",
  })
  arbor.ui.add_toolbar_action({
    id      = "sync-up",
    target  = NS .. ":toolbar",
    action  = "cloud:sync_up",
    icon    = "ArrowUpToLine",
    tooltip = "Sync up (local → cloud)",
  })

  arbor.ui.contribution_point({
    name = NS .. ":toolbar",
    description = "Header toolbar buttons for the cloud-storage sidebar.",
  })
  arbor.ui.contribution_point({
    name = NS .. ":context_menu",
    description = "Right-click menu items on cloud-storage tree rows.",
  })
end

-- ── Connection picker ──────────────────────────────────────────────────────

function M.refresh_connection_combo()
  local conns = state.load_connections()
  local options = {}
  if #conns == 0 then
    options[#options + 1] = {
      value = "__new__", label = "(no connections — click to create)",
      icon = "Plus", action = true,
    }
  else
    for _, c in ipairs(conns) do
      options[#options + 1] = {
        value    = c.id,
        label    = c.name or c.id,
        subtitle = c.provider == "gcs" and "Google Cloud Storage"
                or c.provider == "s3"  and "Amazon S3"
                or c.provider == "azblob" and "Azure Blob"
                or c.provider,
        icon     = "Cloud",
      }
    end
    options[#options + 1] = { value = "__divider__", label = "", group = "Actions" }
    options[#options + 1] = {
      value = "__new__",  label = "New connection…", icon = "Plus", action = true,
      group = "Actions",
    }
  end

  arbor.ui.contribute(NS .. ":connections", {
    id      = "list",
    payload = {
      selected = state.selected_id(),
      options  = options,
      action   = "cloud:select_connection",
    },
  })
end

-- ── Helpers ────────────────────────────────────────────────────────────────

local function human_bytes(n)
  if not n or n <= 0 then return "" end
  local KB, MB, GB = 1024, 1024 * 1024, 1024 * 1024 * 1024
  if     n >= GB then return string.format("%.2f GB", n / GB)
  elseif n >= MB then return string.format("%.2f MB", n / MB)
  elseif n >= KB then return string.format("%.1f KB", n / KB)
  else                return tostring(n) .. " B" end
end

local function last_segment(path)
  if not path or path == "" then return "" end
  local s = path:gsub("/$", "")
  return s:match("([^/]+)$") or s
end

-- Split "a/b/c/" → { "a/", "a/b/", "a/b/c/" }.
local function explode_prefix(prefix)
  if not prefix or prefix == "" then return {} end
  local parts = {}
  local acc = ""
  for seg in (prefix .. "/"):gmatch("([^/]+)") do
    acc = acc .. seg .. "/"
    parts[#parts + 1] = acc
  end
  return parts
end

local function info_node(message, icon)
  return { id = "info::" .. (icon or "Info"), label = message, icon = icon or "Info",
           kind = "section", badge_kind = "muted" }
end

local function err_node(message)
  return { id = "err", label = message, icon = "AlertTriangle",
           kind = "section", badge_kind = "error" }
end

-- ── Breadcrumb builder ─────────────────────────────────────────────────────
-- Returns a list of segments compatible with arbor.ui.tree.set{breadcrumb=...}.
-- The Svelte side renders them as chips above the tree; the last segment is
-- marked non-interactive (no action) so it renders as the current location.

local function build_breadcrumb(conn, bucket, prefix)
  local segs = {}
  -- Root chip: bucket name. Always clickable, even when we're at the root —
  -- the click is then a no-op-ish navigation back to "" which the host
  -- coalesces.  When prefix is empty we mark it as current.
  local at_root = (prefix == nil or prefix == "")
  segs[#segs + 1] = {
    label   = bucket,
    icon    = "FolderTree",
    tooltip = "Bucket root",
    action  = at_root and nil or "cloud:nav_to",
    data    = { config_id = conn.id, bucket = bucket, prefix = "" },
    badge   = at_root and "here" or nil,
  }
  local parts = explode_prefix(prefix or "")
  for i, p in ipairs(parts) do
    local is_last = (i == #parts)
    segs[#segs + 1] = {
      label   = last_segment(p),
      icon    = is_last and "FolderOpen" or "Folder",
      action  = (not is_last) and "cloud:nav_to" or nil,
      data    = { config_id = conn.id, bucket = bucket, prefix = p },
      badge   = is_last and "here" or nil,
      tooltip = p,
    }
  end
  return segs
end

-- ── Sort helper ────────────────────────────────────────────────────────────
-- Folders first, then files, alphabetical inside each group. Stable so the
-- visible order doesn't reshuffle as new batches stream in (we sort the
-- *cumulative* list each chunk).
local function sort_rows(rows)
  table.sort(rows, function(a, b)
    if a.kind ~= b.kind then return a.kind == "folder" end
    return (a.label or "") < (b.label or "")
  end)
  return rows
end

-- Build TreeNode rows directly from a flat items list (streaming).
local function rows_from_items(items, conn_id, bucket)
  local rows = {}
  for _, obj in ipairs(items or {}) do
    local seg = last_segment(obj.path) or obj.path
    if obj.is_dir then
      rows[#rows + 1] = {
        id             = "d:" .. obj.path,
        label          = seg,
        icon           = "Folder",
        kind           = "folder",
        selectable     = true,
        default_action = "cloud:open_folder",
        data           = { config_id = conn_id, bucket = bucket, path = obj.path },
      }
    else
      rows[#rows + 1] = {
        id             = "f:" .. obj.path,
        label          = seg,
        icon           = "FileText",
        kind           = "object",
        selectable     = true,
        default_action = "cloud:download_picker",
        badge          = human_bytes(obj.size),
        badge_kind     = "muted",
        data           = {
          config_id    = conn_id,
          bucket       = bucket,
          path         = obj.path,
          size         = obj.size,
          content_type = obj.content_type,
        },
      }
    end
  end
  return sort_rows(rows)
end

-- ── Streaming chunk handler ────────────────────────────────────────────────
-- Fired by main.lua on `cloud-storage:list-chunk` hooks. Two cost-sensitive
-- rules drive the shape here:
--   1. fire_hook_on locks `plugin_host` while the Lua handler runs. Any work
--      we do here serialises against every other plugin-host operation on
--      the host (open_repo, fire_plugin_action, …) and freezes the UI when
--      it's slow. So mid-stream we render ONLY a tiny counter row — no
--      sort, no per-item tree-node rebuild, no large JSON payload.
--   2. The full sort + render only runs on `done`. Cost: O(N log N) once
--      instead of O(N² / 2) per chunk.
-- Stale streams are silently dropped by stream_id mismatch.

local MID_STREAM_PAINT_MS = 250  -- throttle the counter updates

function M.on_chunk(ev)
  local inflight = M._inflight
  if not inflight or not ev or ev.stream_id ~= inflight.stream_id then
    return
  end

  -- Accumulate the new batch — append-only, no sort.
  for _, it in ipairs(ev.items or {}) do
    inflight.items[#inflight.items + 1] = it
  end

  if ev.error and ev.error ~= "" then
    arbor.ui.tree.set(SIDEBAR_ID, {
      title      = inflight.title,
      breadcrumb = inflight.crumb,
      nodes      = { err_node("List failed: " .. tostring(ev.error)) },
    })
    M._inflight = nil
    return
  end

  if ev.done then
    -- Final render: sort once, build all rows, push the full tree.
    local rows = rows_from_items(inflight.items, inflight.conn_id, inflight.bucket)
    if ev.truncated then
      rows[#rows + 1] = info_node(
        "Listing truncated at " .. tostring(#inflight.items)
        .. " entries — refine the prefix to see more.", "Hash")
    end
    arbor.ui.tree.set(SIDEBAR_ID, {
      title                       = inflight.title,
      breadcrumb                  = inflight.crumb,
      breadcrumb_edit_action      = "cloud:nav_to_typed_path",
      breadcrumb_edit_placeholder = "Type a path, e.g. data/2024/chunks/",
      nodes                       = #rows == 0 and { info_node("Empty folder.", "FolderSearch") } or rows,
    })
    cache_put(inflight.conn_id, inflight.bucket, inflight.prefix, {
      items     = inflight.items,
      truncated = ev.truncated and true or false,
    })
    M._inflight = nil
    return
  end

  -- Mid-stream: throttled lightweight counter. We use os.clock which counts
  -- CPU time on the main VM thread — fine here for "elapsed since last paint".
  local now_ms = math.floor((os.clock() * 1000))
  if now_ms - (inflight.last_paint_ms or 0) < MID_STREAM_PAINT_MS then
    return
  end
  inflight.last_paint_ms = now_ms

  arbor.ui.tree.set(SIDEBAR_ID, {
    title                       = inflight.title,
    breadcrumb                  = inflight.crumb,
    breadcrumb_edit_action      = "cloud:nav_to_typed_path",
    breadcrumb_edit_placeholder = "Type a path, e.g. data/2024/chunks/",
    nodes                       = { {
      id = "stream-loading",
      label = "Loading… (" .. tostring(#inflight.items) .. " items)",
      icon = "Spinner", kind = "section", badge_kind = "muted",
    } },
  })
end

-- ── Refresh entry-point ────────────────────────────────────────────────────
-- `opts.use_cache` (default true) — when false, bypass the cache and re-stream.

function M.refresh(opts)
  opts = opts or {}
  local use_cache = opts.use_cache ~= false

  M.refresh_connection_combo()

  local conns = state.load_connections()
  local sel   = state.selected_id()

  if sel == "" or not state.find(sel) then
    sel = (conns[1] and conns[1].id) or ""
    state.set_selected(sel)
  end

  if #conns == 0 then
    arbor.ui.tree.set(SIDEBAR_ID, { title = "Cloud Storage", nodes = {
      { id = "empty", label = "No connections yet — click + to create one.",
        icon = "Cloud", kind = "section" }
    } })
    return
  end

  local conn = state.find(sel)
  if not conn then
    arbor.ui.tree.set(SIDEBAR_ID, { title = "Cloud Storage",
      nodes = { err_node("Selected connection is missing.") } })
    return
  end

  local bucket = state.active_bucket(conn.id)
  if (bucket or "") == "" then bucket = conn.default_bucket or "" end
  local prefix = state.active_prefix(conn.id) or ""
  local title  = conn.name or conn.id

  if bucket == "" then
    arbor.ui.tree.set(SIDEBAR_ID, { title = title, nodes = {
      info_node("No bucket set — open Edit and fill in a default bucket.", "FolderInput")
    } })
    return
  end

  local crumb = build_breadcrumb(conn, bucket, prefix)

  -- ── Cache hit: render immediately, no roundtrip ─────────────────────────
  local cached = use_cache and cache_get(conn.id, bucket, prefix) or nil
  if cached then
    local rows = rows_from_items(cached.items or {}, conn.id, bucket)
    if cached.truncated then
      rows[#rows + 1] = info_node(
        "Listing truncated at " .. tostring(#cached.items)
        .. " entries — refine the prefix to see more.", "Hash")
    end
    arbor.ui.tree.set(SIDEBAR_ID, {
      title                       = title,
      breadcrumb                  = crumb,
      breadcrumb_edit_action      = "cloud:nav_to_typed_path",
      breadcrumb_edit_placeholder = "Type a path, e.g. data/2024/chunks/",
      nodes                       = #rows == 0 and { info_node("Empty folder.", "FolderSearch") } or rows,
    })
    return
  end

  -- ── Cancel any in-flight stream from a previous navigation ──────────────
  if M._inflight and M._inflight.stream_id then
    pcall(function() arbor.cloud.cancel(M._inflight.stream_id) end)
  end

  -- ── Start a new streaming listing ───────────────────────────────────────
  local stream_id = new_stream_id()
  M._inflight = {
    stream_id = stream_id,
    conn_id   = conn.id,
    bucket    = bucket,
    prefix    = prefix,
    title     = title,
    crumb     = crumb,
    items     = {},
  }

  -- Paint the breadcrumb + initial "Loading…" before kicking off the stream
  -- so the navigation feels instant even when the first chunk hasn't landed.
  arbor.ui.tree.set(SIDEBAR_ID, {
    title                       = title,
    breadcrumb                  = crumb,
    breadcrumb_edit_action      = "cloud:nav_to_typed_path",
    breadcrumb_edit_placeholder = "Type a path, e.g. data/2024/chunks/",
    nodes                       = { { id = "loading", label = "Loading…", icon = "Spinner",
                                      kind = "section", badge_kind = "muted" } },
  })

  local _, err = arbor.cloud.list_stream({
    conn      = state.envelope(conn),
    bucket    = bucket,
    prefix    = prefix,
    stream_id = stream_id,
    cap       = settings.list_hard_cap(),
  })
  if err then
    M._inflight = nil
    arbor.ui.tree.set(SIDEBAR_ID, {
      title      = title,
      breadcrumb = crumb,
      nodes      = { err_node("List failed: " .. tostring(err)) },
    })
  end
end

-- ── Search mode ────────────────────────────────────────────────────────────

local function search_breadcrumb(s)
  -- A compact "Search · <pattern>" pill + clear chip that doubles as the
  -- exit-search button.
  local scope_label = s.scope == "bucket" and "bucket-wide"
                                          or  ("under " .. (s.root_prefix ~= "" and s.root_prefix or "/"))
  return {
    { label   = "Search",
      icon    = "Search",
      tooltip = scope_label,
      action  = nil, -- non-interactive header pill
      data    = {},
      badge   = scope_label },
    { label   = s.pattern,
      icon    = nil,
      tooltip = "Click to clear and go back to browse mode",
      action  = "cloud:search_clear",
      data    = { config_id = s.conn_id },
      badge   = "clear ✕" },
  }
end

local function rows_from_search_items(items, conn_id, bucket, root_prefix)
  -- Flat list. Label = path relative to root_prefix, so the user sees the
  -- folder context inline. Default action = download_picker (same as a
  -- single object row in browse mode).
  local rows = {}
  for _, obj in ipairs(items or {}) do
    local rel = obj.path
    if root_prefix and root_prefix ~= "" and rel:sub(1, #root_prefix) == root_prefix then
      rel = rel:sub(#root_prefix + 1)
    end
    rows[#rows + 1] = {
      id             = "s:" .. obj.path,
      label          = rel,
      icon           = "FileText",
      kind           = "object",
      selectable     = true,
      default_action = "cloud:download_picker",
      badge          = human_bytes(obj.size),
      badge_kind     = "muted",
      data           = {
        config_id    = conn_id,
        bucket       = bucket,
        path         = obj.path,
        size         = obj.size,
        content_type = obj.content_type,
        last_modified = obj.last_modified,
      },
    }
  end
  return rows
end

local function paint_search()
  local s = M._search
  if not s then return end
  local title = "Cloud Storage"
  local conn  = state.find(s.conn_id)
  if conn then title = (conn.name or s.conn_id) .. " · search" end

  local rows = rows_from_search_items(s.items, s.conn_id, s.bucket, s.root_prefix)
  if not s.done then
    rows[#rows + 1] = {
      id = "search-loading",
      label = "Searching… (" .. tostring(#s.items) .. " matches"
              .. (s.scanned and (", " .. tostring(s.scanned) .. " scanned)") or ")"),
      icon = "Spinner", kind = "section", badge_kind = "muted",
    }
  elseif #rows == 0 then
    rows = { info_node(
      "No matches (scanned " .. tostring(s.scanned or 0) .. " entries).", "SearchX") }
    -- Diagnostic: when opendal returned entries but the regex matched none,
    -- show the first few raw paths so we can see what opendal is feeding us
    -- (full keys vs. relative? leading slash?).
    if s.regex then
      rows[#rows + 1] = info_node("Regex: " .. tostring(s.regex), "Code")
    end
    if s.combined and s.combined ~= "" then
      rows[#rows + 1] = info_node("Listing prefix: " .. tostring(s.combined), "FolderTree")
    end
    if s.sample_paths and #s.sample_paths > 0 then
      for i, p in ipairs(s.sample_paths) do
        rows[#rows + 1] = info_node("Sample " .. tostring(i) .. ": " .. tostring(p), "FileText")
      end
    end
  elseif s.truncated then
    rows[#rows + 1] = info_node(
      "Result list capped at " .. tostring(#s.items)
        .. " entries — refine the pattern to see more.", "Hash")
  end

  arbor.ui.tree.set(SIDEBAR_ID, {
    title      = title,
    breadcrumb = search_breadcrumb(s),
    nodes      = rows,
  })
end

-- Entry point: start a new search. Cancels any in-flight search/list.
function M.start_search(pattern, scope)
  if not pattern or pattern == "" then return end
  local sel  = state.selected_id()
  local conn = state.find(sel)
  if not conn then
    arbor.notify{ title = "Search", message = "Select a connection first.", level = "warning" }
    return
  end
  local bucket = state.active_bucket(conn.id)
  if (bucket or "") == "" then bucket = conn.default_bucket or "" end
  if bucket == "" then
    arbor.notify{ title = "Search", message = "No bucket selected.", level = "warning" }
    return
  end
  local root_prefix = ""
  if scope == "current" then
    root_prefix = state.active_prefix(conn.id) or ""
  end

  -- Cancel any previous in-flight ops.
  if M._inflight and M._inflight.stream_id then
    pcall(function() arbor.cloud.cancel(M._inflight.stream_id) end)
    M._inflight = nil
  end
  if M._search and M._search.stream_id and not M._search.done then
    pcall(function() arbor.cloud.cancel(M._search.stream_id) end)
  end

  local sid = new_stream_id()
  M._search = {
    stream_id    = sid,
    conn_id      = conn.id,
    bucket       = bucket,
    root_prefix  = root_prefix,
    pattern      = pattern,
    scope        = scope,
    items        = {},
    done         = false,
    truncated    = false,
    scanned      = 0,
  }
  paint_search()

  local _, err = arbor.cloud.search_stream({
    conn        = state.envelope(conn),
    bucket      = bucket,
    root_prefix = root_prefix,
    pattern     = pattern,
    stream_id   = sid,
  })
  if err then
    M._search.done  = true
    M._search.error = tostring(err)
    arbor.notify{ title = "Search failed", message = tostring(err), level = "error" }
    paint_search()
  end
end

function M.clear_search()
  if M._search and M._search.stream_id and not M._search.done then
    pcall(function() arbor.cloud.cancel(M._search.stream_id) end)
  end
  M._search = nil
  M.refresh()
end

-- on_chunk dispatch: distinguish "list" stream events (current sidebar
-- browse) from "search" stream events. We multiplex on the `kind` field.
local orig_on_chunk = M.on_chunk
function M.on_chunk(ev)
  if ev and ev.kind == "search" then
    local s = M._search
    if not s or ev.stream_id ~= s.stream_id then return end
    for _, it in ipairs(ev.items or {}) do
      s.items[#s.items + 1] = it
    end
    if ev.scanned then s.scanned = ev.scanned end
    if ev.done then
      s.done         = true
      s.truncated    = ev.truncated and true or false
      s.regex        = ev.regex
      s.combined     = ev.combined
      s.sample_paths = ev.sample_paths or {}
      if ev.error and ev.error ~= "" then s.error = ev.error end
    end
    paint_search()
    return
  end
  orig_on_chunk(ev)
end

return M
