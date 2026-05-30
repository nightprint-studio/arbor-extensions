-- ui-protocol-lab / main.lua
--
-- A hands-on test bench for everything the plugin UI dispatch + event/patch
-- protocol added. Open it from the Command Palette: "UI Lab: open playground".
--
--   Fase 5  — host widgets. The `editor` (CodeMirror 6): value-bearing (its
--             text is submitted as `doc`, and the host pushes content with
--             set_value) PLUS the scoped slots on_edit (debounced) / on_select.
--             The `diff`: a read-only, display-only viewer fed pre-diffed hunks,
--             swapped live with a patch (merge) — never re-mounted.
--             The `view` (arbor.ui.add_view): a main-area body surface rendering
--             the SAME FormNodeRenderer — opened from the activity bar / palette
--             / Alt+Shift+V, populated on on_view_open, updated live via the
--             same form.patch channel (ids distinct from the modal's).
--   Fase 3  — granular, no-remount updates: arbor.ui.form.patch (verbs
--             merge / set / append / remove) and arbor.ui.form.set_state_path.
--   Fase 2b — host built-in commands: a button `dispatch = { kind = "command",
--             id = "arbor:repo.refresh" }` and arbor.command.fire("arbor:...").
--   Fase 2a — command invocation: an `invocable` command fired from a button
--             `dispatch = { kind = "command", … }` and from arbor.command.fire.
--   Fase 1  — the dispatch union: bare `action` strings vs `dispatch` objects.

local PLUGIN = "ui-protocol-lab"

local SAMPLE = [[{
  "name": "arbor",
  "kind": "git-gui",
  "stack": ["rust", "tauri", "svelte"],
  "plugins": { "count": 18, "experimental": true }
}]]

-- Module-scope counters. `edits` is also mirrored into the form's opaque state
-- via set_state_path, so it round-trips back to us inside the scoped on_edit
-- payload (we declared `scope_state = { "edits" }` on the editor node).
local edits     = 0
local note_seq  = 0
local last_note = nil   -- id of the most-recently appended note (for `remove`)
local diff_var  = 0     -- which sample diff the `diff` widget currently shows

-- Two pre-diffed hunk sets for the read-only `diff` widget. The plugin supplies
-- hunks directly (kind/content per line); the host fills line numbers + header.
local DIFF_VARIANTS = {
  {  -- variant 0: a version bump
    { old_start = 1, new_start = 1, lines = {
      { kind = "context", content = '{' },
      { kind = "context", content = '  "name": "arbor",' },
      { kind = "removed", content = '  "version": "1.0.0",' },
      { kind = "added",   content = '  "version": "1.1.0",' },
      { kind = "context", content = '  "kind": "git-gui"' },
      { kind = "context", content = '}' },
    }},
  },
  {  -- variant 1: an added dependency block
    { old_start = 1, new_start = 1, lines = {
      { kind = "context", content = '{' },
      { kind = "context", content = '  "name": "arbor",' },
      { kind = "context", content = '  "version": "1.1.0",' },
      { kind = "removed", content = '  "stack": ["rust", "tauri"]' },
      { kind = "added",   content = '  "stack": ["rust", "tauri", "svelte"],' },
      { kind = "added",   content = '  "experimental": true' },
      { kind = "context", content = '}' },
    }},
  },
}

-- ── helpers ────────────────────────────────────────────────────────────────

local function line_count(s)
  if s == nil or s == "" then return 1 end
  local n = 1
  for _ in s:gmatch("\n") do n = n + 1 end
  return n
end

-- Validate JSON via the host parser. Returns ok, err.
local function validate_json(text)
  if not text:match("%S") then return nil, nil end   -- empty → neutral
  local decoded, err = arbor.json.decode(text)
  if decoded == nil or err ~= nil then return false, err end
  return true, nil
end

-- Push the live telemetry for `text` with a SINGLE granular patch — the form
-- is never re-mounted. Demonstrates the `set` verb (deep assign at a path
-- inside the node) and the `merge` verb (shallow prop merge).
local function refresh_stats(text)
  local ok, err = validate_json(text)
  local variant = (ok == true) and "success"
              or  (ok == false) and "error"
              or  "info"
  local message = (ok == true) and "JSON: valid"
              or  (ok == false) and ("JSON: invalid — " .. tostring(err))
              or  "JSON: (type something to validate)"

  arbor.ui.form.patch({
    { id = "stat_chars", set = { "text" }, value = "Characters: " .. #text },
    { id = "stat_lines", set = { "text" }, value = "Lines: " .. line_count(text) },
    { id = "stat_edits", set = { "text" }, value = "on_edit fires: " .. edits },
    { id = "stat_valid", merge = { variant = variant, text = message } },
  })
end

-- ── the playground form ──────────────────────────────────────────────────--

local function open_playground()
  edits, note_seq, last_note, diff_var = 0, 0, nil, 0

  local ok = validate_json(SAMPLE)

  arbor.ui.form({
    title        = "UI Protocol Lab",
    width        = "720px",
    height       = "660px",
    submit_label = "Done",
    -- Opaque state echoed back to handlers; slices of it are updated live
    -- with set_state_path and ride along in scoped payloads.
    state        = { edits = 0 },
    nodes = {
      -- ── Fase 5: the editor widget ──────────────────────────────────────
      { type = "section", title = "Editor widget — CodeMirror 6 (Fase 5)", id = "sec_editor", children = {
        { type = "editor",
          id          = "editor",
          name        = "doc",
          label       = "JSON document — edit me",
          language    = "json",
          height      = 240,
          default     = SAMPLE,
          -- A bare action string here STILL goes through the scoped channel:
          -- the editor's slots always ship `{ node_id, slot, value, state? }`,
          -- never the whole form. on_edit is debounced inside the widget.
          on_edit     = PLUGIN .. ":on_edit",
          debounce_ms = 250,
          on_select   = PLUGIN .. ":on_select",
          scope_state = { "edits" },   -- ride state.edits in the on_edit payload
          hint        = "on_edit is debounced + scoped; on_select fires on cursor / range changes.",
        },
        { type = "row", gap = 8, wrap = true, children = {
          -- Legacy `action` string — ships the whole form (so the handler
          -- can read values.doc to reformat it).
          { type = "button", label = "Load sample", icon = "FileJson",
            action = PLUGIN .. ":load_sample" },
          { type = "button", label = "Normalize", icon = "RefreshCw",
            action = PLUGIN .. ":normalize" },
          { type = "button", label = "Clear", icon = "Eraser", variant = "ghost",
            action = PLUGIN .. ":clear" },
          -- `dispatch` object → fires a registered command (Fase 2a) instead
          -- of this plugin's own action handler. `args` are static.
          { type = "button", label = "Apply via command", icon = "Play", variant = "primary",
            dispatch = { kind = "command", id = PLUGIN .. "::apply", args = { source = "button" } } },
        }},
      }},

      -- ── Fase 3: granular telemetry (patch · set_state_path) ────────────
      { type = "section", title = "Live telemetry — patch + set_state_path (Fase 3)", id = "sec_stats", children = {
        { type = "row", gap = 24, wrap = true, children = {
          { type = "label", id = "stat_chars", text = "Characters: " .. #SAMPLE },
          { type = "label", id = "stat_lines", text = "Lines: " .. line_count(SAMPLE) },
          { type = "label", id = "stat_edits", text = "on_edit fires: 0" },
        }},
        { type = "alert", id = "stat_valid",
          variant = (ok == true) and "success" or "info",
          text    = (ok == true) and "JSON: valid" or "JSON: (type something to validate)" },
        { type = "label", id = "sel_info", variant = "muted", text = "Selection: none" },
      }},

      -- ── Fase 3: append / remove children at runtime ────────────────────
      { type = "section", title = "Append / remove nodes (patch verbs)", id = "sec_notes", children = {
        { type = "row", gap = 8, wrap = true, children = {
          { type = "button", label = "Append note", icon = "Plus", variant = "ghost",
            action = PLUGIN .. ":append_note" },
          { type = "button", label = "Remove last note", icon = "Minus", variant = "ghost",
            action = PLUGIN .. ":remove_note" },
        }},
        -- Notes are pushed into this container's `children` via patch append.
        -- Seeded with a hint so `children` is a real (non-empty) array — an
        -- empty Lua `{}` would serialize to a JSON object, not `[]`.
        { type = "container", id = "notes", gap = 4, children = {
          { type = "label", id = "notes_hint", variant = "muted",
            text = "(appended notes show up here)" },
        }},
      }},

      -- ── Fase 4: scoped dispatch on a non-editor field ──────────────────
      { type = "section", title = "Scoped change on a select (Fase 4)", id = "sec_scoped", children = {
        { type = "select", id = "accent", name = "accent", label = "Pick a value",
          default = "blue",
          options = {
            { value = "blue",   label = "Blue" },
            { value = "green",  label = "Green" },
            { value = "purple", label = "Purple" },
          },
          -- A DispatchTarget on actions.change → scoped payload (not the whole
          -- form). A bare string here would keep the legacy whole-form payload.
          actions     = { change = { kind = "action", name = PLUGIN .. ":on_accent" } },
          scope_state = { "edits" },
          hint        = "Changing this fires a scoped `{ node_id, slot, value, state }` payload.",
        },
      }},

      -- ── Fase 5: the diff widget (read-only, display-only) ──────────────
      { type = "section", title = "Diff viewer — read-only (Fase 5)", id = "sec_diff", children = {
        { type = "diff",
          id        = "lab_diff",
          path      = "package.json",
          language  = "json",
          mode      = "unified",   -- the in-widget toggle flips unified/split
          height    = 220,
          hunks     = DIFF_VARIANTS[1],
          hint      = "Display-only — not submitted. Swap its hunks live with a patch.",
        },
        { type = "row", gap = 8, wrap = true, children = {
          { type = "button", label = "Swap diff", icon = "GitCompare", variant = "ghost",
            action = PLUGIN .. ":swap_diff" },
        }},
      }},

      -- ── Fase 5: the data_tree widget (lazy children + scoped events) ───
      { type = "section", title = "Data tree — lazy children + scoped (Fase 5)", id = "sec_tree", children = {
        { type = "tree",
          id        = "lab_tree",
          name      = "tree_sel",        -- value-bearing: selection → values.tree_sel
          lazy      = true,
          bordered  = true,
          height    = 200,
          -- Roots advertise children with `has_children` but ship none: the
          -- first expand fires on_expand (scoped) and the handler patches the
          -- children in (merge onto the row by its id, clearing the spinner).
          nodes = {
            { id = "root_src",   value = "src",     label = "src",       icon = "Folder",   has_children = true },
            { id = "root_tests", value = "tests",   label = "tests",     icon = "Folder",   has_children = true },
            {                    value = "readme",  label = "README.md", icon = "FileText" },
          },
          on_expand = PLUGIN .. ":tree_expand",
          on_select = PLUGIN .. ":tree_select",
          hint      = "Expand a folder → scoped on_expand fires, the plugin patches in children. ↑↓→← navigate.",
        },
        { type = "label", id = "tree_sel_info", variant = "muted", text = "Tree selection: none" },
      }},

      -- ── Fase 2b: invoking HOST built-in commands ──────────────────────────
      -- Same dispatch union as a plugin command, but the id is `arbor:area.verb`
      -- and Arbor itself runs it. We demo the two no-permission UI intents (this
      -- plugin only holds `command_invoke`); the `arbor:git.*` commands would
      -- additionally need `git = "write"` in the manifest.
      { type = "section", title = "Host commands (Fase 2b)", id = "sec_host_cmd", children = {
        { type = "paragraph", id = "host_cmd_intro",
          text = "Host built-ins are addressed as arbor:area.verb. Gated by command_invoke + "
              .. "the command's required tier. These two need no tier." },
        { type = "row", gap = 8, wrap = true, children = {
          -- Button → host command directly (no plugin action involved).
          { type = "button", label = "Refresh repo (arbor:repo.refresh)", icon = "RefreshCw", variant = "ghost",
            dispatch = { kind = "command", id = "arbor:repo.refresh" } },
          { type = "button", label = "Open Settings (arbor:app.open_settings)", icon = "Settings", variant = "ghost",
            dispatch = { kind = "command", id = "arbor:app.open_settings" } },
          -- Same thing at runtime via arbor.command.fire (routes identically).
          { type = "button", label = "Refresh via command.fire", icon = "Zap", variant = "ghost",
            action = PLUGIN .. ":fire_host_refresh" },
        }},
      }},
    },
  })
end

-- ── scoped slot handlers (Fase 5 / Fase 4) ────────────────────────────────

-- Scoped payload: { node_id, slot = "edit", value = <full text>, state }.
arbor.events.on(PLUGIN .. ":on_edit", function(ctx)
  local text = (ctx and ctx.value) or ""
  edits = edits + 1
  -- Mirror the counter into the opaque form state (one slice, no re-render).
  arbor.ui.form.set_state_path({ "edits" }, edits)
  -- Verify the round-trip: state.edits we set last time rode back in `state`.
  arbor.log.info(("on_edit #%d — %d chars (state.edits seen = %s)")
    :format(edits, #text, tostring(ctx and ctx.state and ctx.state.edits)))
  refresh_stats(text)
end)

-- Scoped payload: { node_id, slot = "select", value = { from, to, text } }.
arbor.events.on(PLUGIN .. ":on_select", function(ctx)
  local sel = (ctx and ctx.value) or {}
  local from, to = sel.from or 0, sel.to or 0
  arbor.ui.form.set_state_path({ "last_selection" }, { from = from, to = to })
  local msg
  if from == to then
    msg = ("Selection: caret at offset %d"):format(from)
  else
    msg = ("Selection: %d–%d (%d chars)"):format(from, to, #(sel.text or ""))
  end
  arbor.ui.form.patch({ { id = "sel_info", set = { "text" }, value = msg } })
end)

arbor.events.on(PLUGIN .. ":on_accent", function(ctx)
  arbor.log.info(("accent scoped change → node=%s slot=%s value=%s")
    :format(tostring(ctx and ctx.node_id), tostring(ctx and ctx.slot), tostring(ctx and ctx.value)))
  arbor.notify{ title = "UI Lab", message = "Accent → " .. tostring(ctx and ctx.value), level = "info" }
end)

-- ── whole-form action handlers (Fase 1 — legacy action strings) ───────────

arbor.events.on(PLUGIN .. ":load_sample", function(_)
  arbor.ui.form.set_value("doc", SAMPLE)   -- host pushes content into the editor
  edits = 0
  refresh_stats(SAMPLE)
end)

arbor.events.on(PLUGIN .. ":normalize", function(ctx)
  local doc = (ctx and ctx.doc) or ""     -- whole-form payload → values at top level
  local decoded, err = arbor.json.decode(doc)
  if decoded == nil or err ~= nil then
    arbor.notify{ title = "UI Lab", message = "Can't normalize — invalid JSON.", level = "warning" }
    return
  end
  local encoded = arbor.json.encode(decoded) or doc
  arbor.ui.form.set_value("doc", encoded)
  refresh_stats(encoded)
end)

arbor.events.on(PLUGIN .. ":clear", function(_)
  arbor.ui.form.set_value("doc", "")
  refresh_stats("")
end)

arbor.events.on(PLUGIN .. ":append_note", function(_)
  note_seq = note_seq + 1
  last_note = "note_" .. note_seq
  arbor.ui.form.patch({
    { id = "notes", to = "children",
      append = { type = "label", id = last_note, variant = "muted",
                 text = ("• note #%d appended at %s"):format(note_seq, os.date("%H:%M:%S")) } },
  })
end)

arbor.events.on(PLUGIN .. ":remove_note", function(_)
  if not last_note then
    arbor.notify{ title = "UI Lab", message = "No notes to remove.", level = "info" }
    return
  end
  -- Remove a CHILD by targeting it with its own id.
  arbor.ui.form.patch({ { id = last_note, remove = true } })
  last_note = nil
end)

-- Swap the read-only diff's content with a SINGLE granular patch — `merge`
-- shallow-assigns props on the node, so only `hunks` changes and the widget
-- (local unified/split toggle, scroll position) is never re-mounted.
arbor.events.on(PLUGIN .. ":swap_diff", function(_)
  diff_var = (diff_var + 1) % #DIFF_VARIANTS
  arbor.ui.form.patch({
    { id = "lab_diff", merge = { hunks = DIFF_VARIANTS[diff_var + 1] } },
  })
end)

-- ── data_tree (Fase 5): lazy children + scoped selection ──────────────────

-- Children fetched lazily on expand, keyed by the expanded row's id. Nested
-- folders (e.g. "src_lib") advertise has_children themselves → a second level
-- of lazy loading.
local TREE_CHILDREN = {
  root_src = {
    { id = "src_lib", value = "src/lib", label = "lib", icon = "Folder", has_children = true },
    {                 value = "src/main.rs", label = "main.rs", icon = "FileCode" },
  },
  src_lib = {
    { value = "src/lib/a.rs", label = "a.rs", icon = "FileCode" },
    { value = "src/lib/b.rs", label = "b.rs", icon = "FileCode" },
  },
  root_tests = {
    { value = "tests/it.rs", label = "integration.rs", icon = "FileCode" },
  },
}

-- Scoped payload: { node_id, slot = "expand", value = { id, value, path } }.
arbor.events.on(PLUGIN .. ":tree_expand", function(ctx)
  local v   = (ctx and ctx.value) or {}
  local id  = v.id
  local kids = id and TREE_CHILDREN[id]
  arbor.log.info(("tree expand → id=%s (%s children)")
    :format(tostring(id), kids and #kids or 0))
  if kids then
    -- Fill the children + clear the spinner with one granular patch.
    arbor.ui.form.patch({ { id = id, merge = { children = kids, loading = false } } })
  else
    -- Nothing under it after all — drop the expander, clear the spinner.
    arbor.ui.form.patch({ { id = id, merge = { children = {}, has_children = false, loading = false } } })
  end
end)

-- Scoped payload: { node_id, slot = "select", value = <selected value> }.
arbor.events.on(PLUGIN .. ":tree_select", function(ctx)
  local val = (ctx and ctx.value) or "?"
  arbor.ui.form.patch({
    { id = "tree_sel_info", set = { "text" }, value = "Tree selection: " .. tostring(val) },
  })
end)

-- ── main-area view (Fase 5 — arbor.ui.add_view) ───────────────────────────
--
-- A view occupies the body (where the commit graph lives) and renders the FULL
-- FormNodeRenderer — so the dispatch / scoped / patch protocol works exactly as
-- in the modal. We populate it on `on_view_open` with `set_panel_content`, then
-- update it live with `arbor.ui.form.patch`. Its node ids are distinct from the
-- modal's, so the shared (plugin-scoped) patch channel never cross-talks even
-- if both the modal and the view are open at once.

local VIEW_ID    = "dashboard"
local view_ticks = 0

local function view_content()
  return {
    title = "UI Lab — Dashboard view",
    nodes = {
      { type = "section", title = "This is a plugin main-area view", id = "v_sec", children = {
        { type = "paragraph", id = "v_intro",
          text = "Registered with arbor.ui.add_view. Same FormNodeRenderer as a modal — "
              .. "every node type plus the live patch / dispatch / scoped protocol." },
        { type = "row", gap = 24, wrap = true, children = {
          { type = "label", id = "v_ticks", text = "Ticks: 0" },
          { type = "label", id = "v_doc",   variant = "muted", text = "Editor below is value-bearing." },
        }},
        { type = "alert", id = "v_status", variant = "info",
          text = "Press Tick → a single form.patch updates this view in place (no re-mount)." },
      }},
      { type = "section", title = "Editor in the body", id = "v_sec_editor", children = {
        { type = "editor", id = "v_editor", name = "view_doc", language = "json",
          height = 220, default = SAMPLE,
          on_edit = PLUGIN .. ":view_edit", debounce_ms = 250,
          hint = "Scoped on_edit fires here too — the body surface shares the protocol." },
      }},
      { type = "row", gap = 8, wrap = true, children = {
        { type = "button", label = "Tick", icon = "Plus", variant = "primary",
          action = PLUGIN .. ":view_tick" },
        { type = "button", label = "Apply via command", icon = "Play",
          dispatch = { kind = "command", id = PLUGIN .. "::apply", args = { source = "view" } } },
      }},
    },
    actions = {
      { label = "Reset", action = PLUGIN .. ":view_reset" },
    },
  }
end

arbor.events.on("on_view_open", function(ctx)
  if not (ctx and ctx.view_id == VIEW_ID) then return end
  view_ticks = 0
  arbor.ui.set_panel_content(VIEW_ID, view_content())
  arbor.log.info("view opened: " .. VIEW_ID)
end)

arbor.events.on("on_view_close", function(ctx)
  if ctx and ctx.view_id == VIEW_ID then
    arbor.log.info("view closed: " .. VIEW_ID)
  end
end)

arbor.events.on(PLUGIN .. ":view_tick", function(_)
  view_ticks = view_ticks + 1
  -- One granular patch updates the mounted view body in place.
  arbor.ui.form.patch({
    { id = "v_ticks",  set = { "text" }, value = "Ticks: " .. view_ticks },
    { id = "v_status", merge = { variant = "success",
        text = ("Patched in place ×%d at %s"):format(view_ticks, os.date("%H:%M:%S")) } },
  })
end)

arbor.events.on(PLUGIN .. ":view_edit", function(ctx)
  local text = (ctx and ctx.value) or ""
  arbor.ui.form.patch({
    { id = "v_doc", set = { "text" }, value = ("Editor: %d chars"):format(#text) },
  })
end)

arbor.events.on(PLUGIN .. ":view_reset", function(_)
  view_ticks = 0
  arbor.ui.set_panel_content(VIEW_ID, view_content())   -- full rebuild
end)

-- ── command invocation (Fase 2a) ──────────────────────────────────────────

arbor.events.on("command:apply", function(ctx)
  local doc    = (ctx and ctx.doc) or ""                       -- present when fired from the open form
  local source = (ctx and ctx.args and ctx.args.source) or "palette"
  local decoded, err = arbor.json.decode(doc)
  if doc:match("%S") and decoded ~= nil and err == nil then
    arbor.notify{ title = "UI Lab",
      message = ("Applied %d chars of valid JSON (via %s)."):format(#doc, source),
      level   = "success" }
  else
    arbor.notify{ title = "UI Lab",
      message = ("Nothing valid to apply (via %s)."):format(source),
      level   = "warning" }
  end
end)

arbor.events.on("command:fire-apply", function(_)
  -- Runtime invocation of a registered command (same route as a button's
  -- `dispatch = { kind = "command", … }`). Cross-plugin works identically —
  -- another plugin holding `command_invoke` fires "ui-protocol-lab::apply".
  local okc = pcall(function()
    arbor.command.fire(PLUGIN .. "::apply", { source = "command.fire" })
  end)
  if not okc then
    arbor.notify{ title = "UI Lab", message = "command.fire failed.", level = "error" }
  end
end)

-- ── host built-in command invocation (Fase 2b) ────────────────────────────

arbor.events.on(PLUGIN .. ":fire_host_refresh", function(_)
  -- A host built-in (`arbor:area.verb`) fired at runtime — same route as a
  -- button's `dispatch = { kind = "command", id = "arbor:..." }`. No tier
  -- needed for repo.refresh (only command_invoke).
  local okc = pcall(function() arbor.command.fire("arbor:repo.refresh") end)
  arbor.notify{
    title   = "UI Lab",
    message = okc and "Asked the host to refresh the repo." or "Host command.fire failed.",
    level   = okc and "info" or "error",
  }
end)

-- ── wiring ─────────────────────────────────────────────────────────────────

arbor.events.on("command:open", function(_) open_playground() end)

arbor.events.on("on_plugin_load", function(_)
  arbor.command.register({
    id          = "open",
    title       = "UI Lab: open playground",
    description = "Editor widget + scoped events + granular patch + command invocation, all in one modal.",
    icon        = "Sliders",
    group       = "UI Lab",
  })
  arbor.command.register({
    id          = "apply",
    title       = "UI Lab: apply current document",
    description = "Validate the editor's JSON and report. Invocable by other plugins via command.fire.",
    icon        = "Play",
    group       = "UI Lab",
    invocable   = true,   -- other plugins may fire "ui-protocol-lab::apply"
    required    = {},     -- no permission tier required of the caller
  })
  arbor.command.register({
    id          = "fire-apply",
    title       = "UI Lab: fire apply via command.fire",
    description = "Demonstrates arbor.command.fire at runtime (fires the apply command).",
    icon        = "Zap",
    group       = "UI Lab",
  })
  -- Fase 5: a main-area view. Surfaces as an activity-bar icon + a palette
  -- "Open View: …" entry + the Alt+Shift+V toggle. placement="graph" keeps the
  -- tab bar + bottom panel; switch to "main" to take over the whole body.
  arbor.ui.add_view({
    id        = VIEW_ID,
    label     = "UI Lab Dashboard",
    icon      = "LayoutDashboard",
    placement = "graph",
    tooltip   = "Plugin main-area view demo",
  })
  arbor.log.info("ui-protocol-lab ready")
end)
