-- repo-bookmarks / main.lua
--
-- Per-repo file bookmarks. Keeps a JSON-encoded list of {label, path}
-- in arbor.settings.project under the key "bookmarks", and exposes three
-- Command Palette entries:
--
--   · "Bookmark a file…"      → file picker → label form → save
--   · "Open bookmark…"        → select form → arbor.ui.open_path
--   · "Manage bookmarks…"     → cfg_list with rename / delete actions
--
-- The chosen file is opened with the OS default handler via
-- arbor.ui.open_path. We deliberately avoid keeping any global registry:
-- bookmarks are local to the repo (carried by the workspace settings),
-- so the same plugin can serve any number of repos without collisions.

-- ─────────────────────────────────────────────────────────────────────────
-- Storage
-- ─────────────────────────────────────────────────────────────────────────

local function load_bookmarks()
  local raw = arbor.settings.project.get("bookmarks") or ""
  if raw == "" then return {} end
  local ok, decoded = pcall(arbor.json.decode, raw)
  if not ok or type(decoded) ~= "table" then return {} end
  -- Defensive: filter out anything that isn't a {label, path} table so a
  -- corrupted setting (manual edit, schema drift) can't crash the modal.
  local out = {}
  for _, b in ipairs(decoded) do
    if type(b) == "table" and type(b.path) == "string" and b.path ~= "" then
      out[#out + 1] = {
        label = type(b.label) == "string" and b.label ~= "" and b.label or b.path,
        path  = b.path,
      }
    end
  end
  return out
end

local function save_bookmarks(list)
  arbor.settings.project.set("bookmarks", arbor.json.encode(list or {}))
end

local function find_index(list, path)
  for i, b in ipairs(list) do
    if b.path == path then return i end
  end
  return nil
end

-- ─────────────────────────────────────────────────────────────────────────
-- Path helpers
-- ─────────────────────────────────────────────────────────────────────────

local function normalize_slashes(p)
  return (p or ""):gsub("\\", "/")
end

-- Display path relative to the repo root when the bookmark sits inside it
-- — keeps the picker rows scannable. Outside-repo bookmarks (rare) keep
-- their absolute form so the user sees they're crossing the boundary.
local function display_path(path)
  local repo = arbor.repo.current()
  if not repo or repo == "" then return path end
  local r = normalize_slashes(repo)
  local p = normalize_slashes(path)
  if p:sub(1, #r + 1) == (r .. "/") then
    return p:sub(#r + 2)
  end
  return path
end

-- ─────────────────────────────────────────────────────────────────────────
-- "Bookmark a file…" — file picker → label form → save
-- ─────────────────────────────────────────────────────────────────────────

local function start_bookmark_flow()
  local repo = arbor.repo.current()
  if not repo or repo == "" then
    arbor.notify{ message = "No active repository.", level = "warning" }
    return
  end
  arbor.ui.pick_file({
    mode         = "file",
    title        = "Pick a file to bookmark",
    initial_path = repo,
    action       = "repo-bookmarks:on_file_picked",
  })
end

-- One-flow-at-a-time staging slot: the file picker hands us a path on
-- one event, the label form posts back on a separate event, and the form
-- DSL has no hidden field. Stashing the path here is simpler than
-- threading it through `extra` payloads on every node.
local pending = { path = nil, original_label = nil }

arbor.events.on("repo-bookmarks:on_file_picked", function(ctx)
  local path = ctx and ctx.path or ""
  if path == "" then return end -- user cancelled

  local list = load_bookmarks()
  if find_index(list, path) then
    arbor.notify{ message = "That file is already bookmarked.", level = "info" }
    return
  end

  -- Pre-fill the label with the basename so single-file bookmarks need
  -- zero typing — the user just hits Enter to accept.
  local default_label = path:match("([^/\\]+)$") or path
  pending.path = path

  arbor.ui.form({
    title         = "Bookmark file",
    width         = "520px",
    height        = "300px",
    submit_label  = "Save bookmark",
    submit_action = "repo-bookmarks:save_new",
    nodes = {
      { type = "label", text = "Path: " .. display_path(path) },
      { type = "text", name = "label", label = "Label",
        default = default_label, placeholder = "How you'll see it in the picker" },
    },
  })
end)

arbor.events.on("repo-bookmarks:save_new", function(ctx)
  local path  = pending.path or ""
  pending.path = nil
  local label = ctx and ctx.label or ""
  if path == "" then return end
  label = (label:gsub("^%s+", ""):gsub("%s+$", ""))
  if label == "" then label = path:match("([^/\\]+)$") or path end

  local list = load_bookmarks()
  if find_index(list, path) then
    arbor.notify{ message = "That file is already bookmarked.", level = "info" }
    return
  end
  list[#list + 1] = { label = label, path = path }
  save_bookmarks(list)
  arbor.notify{ message = "Bookmarked: " .. label, level = "success" }
end)

-- ─────────────────────────────────────────────────────────────────────────
-- "Open bookmark…" — select + Open
-- ─────────────────────────────────────────────────────────────────────────

local function open_picker()
  local list = load_bookmarks()
  if #list == 0 then
    arbor.notify{
      message = "No bookmarks for this repo. Use \"Bookmark a file…\" first.",
      level   = "info",
    }
    return
  end

  local options = {}
  for i, b in ipairs(list) do
    options[i] = {
      value = b.path,
      label = b.label .. "    —    " .. display_path(b.path),
    }
  end

  arbor.ui.form({
    title         = "Open bookmark",
    width         = "560px",
    height        = "260px",
    submit_label  = "Open",
    submit_action = "repo-bookmarks:open",
    nodes = {
      { type = "select", name = "path", label = "Bookmark",
        options = options, default = list[1].path },
    },
  })
end

arbor.events.on("repo-bookmarks:open", function(ctx)
  local path = ctx and ctx.path or ""
  if path == "" then return end
  if not arbor.fs.exists(path) then
    arbor.notify{
      title   = "File missing",
      message = "Bookmark target no longer exists: " .. display_path(path),
      level   = "warning",
    }
    return
  end
  local ok, err = pcall(function() arbor.ui.open_path(path) end)
  if not ok then
    arbor.notify{ title = "Open failed", message = tostring(err), level = "error" }
  end
end)

-- ─────────────────────────────────────────────────────────────────────────
-- "Manage bookmarks…" — list with rename / delete
-- ─────────────────────────────────────────────────────────────────────────

local function manage_modal()
  local list = load_bookmarks()
  if #list == 0 then
    arbor.notify{ message = "No bookmarks for this repo.", level = "info" }
    return
  end

  local items = {}
  for _, b in ipairs(list) do
    -- Tag the row "missing" when the file is gone so the user can clean
    -- up stale entries without juggling another tool.
    local tags = {}
    if not arbor.fs.exists(b.path) then
      tags[#tags + 1] = { text = "missing", variant = "error" }
    end
    items[#items + 1] = {
      id            = b.path,
      label         = b.label .. "    " .. display_path(b.path),
      tags          = tags,
      edit_action   = "repo-bookmarks:rename_prompt",
      delete_action = "repo-bookmarks:delete",
    }
  end

  arbor.ui.form({
    title         = "Manage bookmarks",
    width         = "640px",
    height        = "520px",
    submit_label  = "Close",
    submit_action = "repo-bookmarks:noop",
    nodes = {
      { type = "label", text = "Click the pencil to rename, the trash to remove." },
      { type = "cfg_list", items = items },
    },
  })
end

arbor.events.on("repo-bookmarks:noop", function(_) end)

arbor.events.on("repo-bookmarks:rename_prompt", function(ctx)
  local path = ctx and ctx.id or ""
  if path == "" then return end
  local list = load_bookmarks()
  local i = find_index(list, path)
  if not i then return end
  pending.path = path
  arbor.ui.form({
    title         = "Rename bookmark",
    width         = "520px",
    height        = "300px",
    submit_label  = "Save",
    submit_action = "repo-bookmarks:rename_apply",
    nodes = {
      { type = "label", text = "Path: " .. display_path(path) },
      { type = "text", name = "label", label = "Label", default = list[i].label },
    },
  })
end)

arbor.events.on("repo-bookmarks:rename_apply", function(ctx)
  local path  = pending.path or ""
  pending.path = nil
  local label = ctx and ctx.label or ""
  if path == "" then return end
  label = (label:gsub("^%s+", ""):gsub("%s+$", ""))
  if label == "" then return end

  local list = load_bookmarks()
  local i = find_index(list, path)
  if not i then return end
  list[i].label = label
  save_bookmarks(list)
  arbor.notify{ message = "Bookmark renamed.", level = "success" }
  manage_modal()
end)

arbor.events.on("repo-bookmarks:delete", function(ctx)
  local path = ctx and ctx.id or ""
  if path == "" then return end
  local list = load_bookmarks()
  local i = find_index(list, path)
  if not i then return end
  table.remove(list, i)
  save_bookmarks(list)
  arbor.notify{ message = "Bookmark removed.", level = "info" }
  manage_modal()
end)

-- ─────────────────────────────────────────────────────────────────────────
-- Wiring
-- ─────────────────────────────────────────────────────────────────────────

arbor.events.on("on_plugin_load", function(_ctx)
  arbor.command.register({
    id          = "add",
    title       = "Bookmark a file…",
    description = "Pick a file in the active repo and pin it under a label.",
    icon        = "BookmarkPlus",
    group       = "Bookmarks",
  })
  arbor.command.register({
    id          = "open",
    title       = "Open bookmark…",
    description = "Pick one of this repo's bookmarks and open it.",
    icon        = "Bookmark",
    group       = "Bookmarks",
  })
  arbor.command.register({
    id          = "manage",
    title       = "Manage bookmarks…",
    description = "Rename or remove bookmarks for this repo.",
    icon        = "Settings",
    group       = "Bookmarks",
  })
  arbor.log.info("repo-bookmarks ready")
end)

arbor.events.on("command:add",    function(_) start_bookmark_flow() end)
arbor.events.on("command:open",   function(_) open_picker() end)
arbor.events.on("command:manage", function(_) manage_modal() end)
