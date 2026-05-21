-- ui/sequence_modal.lua — editor modal for Source Export sequences.
--
-- Layout mirrors the profile editor for visual consistency:
--   · tree_layout outer
--     · nav  : toolbar (+ dup run del) + sequence tree
--     · body : tabs { Info | Items | History }
--
-- TAB BREAKDOWN
--   · Info       name / description / fail-fast / output root / global vars
--   · Items      inline picker (autocomplete + Add) at the top, then one
--                collapsible CARD per item titled by the PROJECT name; the
--                profile name appears as a subtitle to disambiguate within
--                the same repo. Move/delete live in the card's header_actions.
--   · History    runs of this specific sequence, most-recent first.
--
-- The profile picker is INLINE (no sub-modal): confirming a pick would
-- otherwise close the parent editor — a side effect of Tauri's one-modal
-- assumption.

local schema    = require("sequence_schema")
local seq_store = require("config.sequences")
local remote    = require("remote_profiles")

local M = {}

-- ── In-memory modal state ───────────────────────────────────────────────────

M.state = {
  selected_sequence_id = "",
  selected_item_id     = "",     -- focused row in the Items tab middle column
  active_tab           = "info", -- "info" | "items" | "history"
}

local function reset_state()
  M.state = {
    selected_sequence_id = "",
    selected_item_id     = "",
    active_tab           = "info",
  }
end

-- ── Small helpers ───────────────────────────────────────────────────────────

local function label(text, variant)
  return { type = "paragraph", content = text, variant = variant or "muted" }
end

local function format_ts(ms)
  if not ms or ms == 0 then return "—" end
  return os.date("%Y-%m-%d %H:%M:%S", math.floor(ms / 1000))
end

local function format_duration(started_at, finished_at)
  if not started_at or started_at == 0 then return "—" end
  local end_ms = (finished_at and finished_at > 0) and finished_at or (os.time() * 1000)
  local ms = end_ms - started_at
  if ms < 0 then ms = 0 end
  if ms < 1000 then return ms .. "ms" end
  local s = math.floor(ms / 1000)
  if s < 60 then return s .. "s" end
  local m = math.floor(s / 60)
  return string.format("%dm %02ds", m, s % 60)
end

-- Lightweight indicator strings used on the items tree rows.
local function item_desc(it)
  local parts = {}
  if it.enabled == false then parts[#parts+1] = "disabled" end
  if it.variables and #it.variables > 0 then
    parts[#parts+1] = tostring(#it.variables) ..
      " override" .. (#it.variables == 1 and "" or "s")
  end
  if #parts == 0 then return it.profile_name or "" end
  return (it.profile_name or "") .. "  ·  " .. table.concat(parts, " · ")
end

-- ── Tab: Info ───────────────────────────────────────────────────────────────

local function build_info_tab(sequence)
  -- kv_list takes Record<string,string>, NOT array-of-{key,value}. Array
  -- renders as "[object Object]" because the DSL does Object.entries on
  -- the value. The on-disk format stays an ordered array for ipairs compat;
  -- conversion happens here at the UI boundary.
  local vars_default = {}
  for _, v in ipairs(sequence.variables or {}) do
    if v.key and v.key ~= "" then vars_default[v.key] = v.value or "" end
  end

  return {
    { id = "seq_info_card", type = "section", card = true, title = "Sequence",
      children = {
        { type = "text", name = "seq_name", label = "Name",
          default = sequence.name or "", placeholder = "Nightly multi-export" },
        { type = "textarea", name = "seq_description", label = "Description",
          default = sequence.description or "", rows = 2 },
        { type = "checkbox", name = "seq_fail_fast",
          label = "Fail-fast — stop on first failure (unchecked = continue with remaining items)",
          default = sequence.fail_fast and true or false },
        { type = "text", name = "seq_output_root", label = "Output root (empty = auto)",
          default = sequence.output_root or "",
          placeholder = "/shared/exports/nightly  (a timestamped subfolder is appended)" },
        label("Every item runs against its referenced repo but writes its " ..
              "output under this shared root. Leave empty to use the " ..
              "plugin-global output folder + a `sequence_<name>_<ts>` subdir."),
      } },

    { id = "seq_globals_card", type = "section", card = true,
      title = "Global variables (applied to every item)",
      children = {
        { type = "kv_list", name = "seq_vars",
          key_label = "Name", value_label = "Value",
          key_placeholder = "ENV", value_placeholder = "prod",
          default = vars_default },
        label("Usable anywhere as $NAME or ${NAME} in step parameters. " ..
              "Per-item overrides under the Items tab win on name collision. " ..
              "Fallback syntax: `${NAME:default}` uses `default` when NAME " ..
              "is unset or empty."),
      } },
  }
end

-- ── Tab: Items — 3-column layout (palette | tree | detail) ─────────────────
--
-- Inspired by the profile editor's "Regole export" tab: left palette lets
-- you ADD things, middle shows the current sequence, right is the inspector
-- for the currently selected row.
--
--   · Palette     one collapsible card per known repo (with ≥1 profile),
--                 each profile a ghost button that appends an item.
--   · Items tree  flat tree of the sequence's items (stable ordering, click
--                 to select). No inline controls — those live in the detail
--                 column so they're never cramped.
--   · Detail      toolbar (move up/down/delete) + "Profile" card (identity)
--                 + "Runtime" card (enabled/allow_failure) + "Variable
--                 overrides for this item" card (kv_list). The explicit
--                 section title resolves the "+Add" ambiguity the old
--                 single-column layout had.

local function build_palette_column()
  local repos = remote.list_all_repos_with_profiles()
  local children = {}
  for _, r in ipairs(repos) do
    if r.profiles and #r.profiles > 0 then
      local buttons = {}
      for _, p in ipairs(r.profiles) do
        buttons[#buttons+1] = {
          id = "pal_" .. r.repo_id .. "_" .. p.id,
          type    = "button",
          icon    = "FileText",
          label   = p.name or p.id,
          variant = "ghost",
          class   = "pal-row",     -- tight flush-left row style (see PluginFormModal CSS)
          -- Clicking a palette entry appends an item. `extra` carries the
          -- full reference so the handler doesn't need to re-scan repos.
          action  = "source-export:seq_palette_add",
          extra   = {
            repo_id    = r.repo_id,
            profile_id = p.id,
            repo_path  = r.repo_path,
          },
        }
      end
      children[#children+1] = {
        id = "palrepo_" .. r.repo_id,
        type = "section", card = true, collapsible = true,
        class = "pf-card-compact",    -- dense body padding for list mode
        title = r.repo_label or r.repo_path or r.repo_id,
        count = #r.profiles,
        children = buttons,
      }
    end
  end
  if #children == 0 then
    children[#children+1] = {
      id = "pal_empty",
      type = "alert", variant = "info",
      text = "No source-export profiles in any known repo. Create a " ..
             "profile in any project — it'll show up here automatically." }
  end
  return children
end

local function build_items_tree(sequence, sel_item_id)
  local items = sequence.items or {}
  local tree_nodes = {}
  for idx, it in ipairs(items) do
    tree_nodes[#tree_nodes+1] = {
      value       = it.id,
      label       = string.format("%02d.  %s", idx, it.repo_label or it.repo_path or "?"),
      description = item_desc(it),
      icon        = "Workflow",
    }
  end
  if #tree_nodes == 0 then
    tree_nodes[#tree_nodes+1] = { value = "__none__",
      label = "(no items)", icon = "CircleSlash" }
  end

  -- Toolbar-style header — small-caps title on the left, count pill on the
  -- right. Mirrors the profile editor's "SEQUENZA OPERAZIONI" bar so the
  -- two modals visually line up.
  return {
    { id = "items_tree_head",
      type = "row", gap = 8, align = "center",
      style = "padding:4px 2px 8px; border-bottom:1px solid var(--border-subtle); margin-bottom:6px;",
      children = {
        { id = "items_tree_title",
          type = "paragraph", variant = "caption",
          content = "Sequence items",
          style = "margin:0; flex:1 1 auto; font-weight:600; " ..
                  "text-transform:uppercase; letter-spacing:0.3px; " ..
                  "color: var(--text-secondary);" },
        { id = "items_tree_count",
          type = "paragraph", variant = "caption",
          content = tostring(#items),
          style = "margin:0; font-family: var(--font-code); " ..
                  "background: var(--bg-base); border: 1px solid var(--border-subtle); " ..
                  "border-radius: 999px; padding:1px 7px; font-size: 10px; " ..
                  "color: var(--text-muted);" },
      } },
    { id = "items_tree", type = "tree", name = "sel_item",
      default = sel_item_id,
      expanded = true,
      change_action = "source-export:seq_item_select",
      nodes = tree_nodes },
  }
end

local function build_detail_column(sequence, sel_item_id)
  local items = sequence.items or {}
  local selected, idx, total = nil, 0, #items
  if sel_item_id ~= "" then
    for i, it in ipairs(items) do
      if it.id == sel_item_id then selected = it; idx = i; break end
    end
  end

  if not selected then
    -- Centered placeholder mirroring the profile editor's "Seleziona un
    -- gruppo o uno step…" affordance. `margin:auto` in a flex-column
    -- parent centers vertically AND horizontally; the max-width keeps the
    -- prose readable.
    return {
      { id = "dt_empty",
        type = "paragraph", variant = "muted",
        content = "Select an item on the left to edit its runtime settings " ..
                  "and variable overrides.\n\nAdd new items from the palette " ..
                  "on the far left.",
        style = "margin:auto; max-width:320px; text-align:center; " ..
                "white-space:pre-wrap; font-size:12px; line-height:1.55;" },
    }
  end

  -- kv_list default is Record<string,string>. See note in build_info_tab().
  local item_vars = {}
  for _, v in ipairs(selected.variables or {}) do
    if v.key and v.key ~= "" then item_vars[v.key] = v.value or "" end
  end

  return {
    { id = "dt_toolbar_" .. selected.id,
      type = "row", gap = 4, align = "center", children = {
        { id = "dt_up_" .. selected.id,
          type = "button", icon = "ArrowUp", icon_only = true, variant = "ghost",
          tooltip = "Move up",
          action = "source-export:seq_item_move_up",
          extra = { item_id = selected.id },
          disabled = (idx == 1) },
        { id = "dt_dn_" .. selected.id,
          type = "button", icon = "ArrowDown", icon_only = true, variant = "ghost",
          tooltip = "Move down",
          action = "source-export:seq_item_move_down",
          extra = { item_id = selected.id },
          disabled = (idx == total) },
        { id = "dt_rm_" .. selected.id,
          type = "button", icon = "Trash2", icon_only = true, variant = "ghost",
          tooltip = "Remove item",
          action = "source-export:seq_item_remove",
          extra = { item_id = selected.id } },
      } },

    { id = "dt_id_" .. selected.id,
      type = "section", card = true, title = "Profile",
      children = {
        { id = "dt_prof_" .. selected.id,
          type = "paragraph", variant = "heading",
          content = selected.profile_name or "(unknown profile)",
          style = "margin:0;" },
        { id = "dt_repo_" .. selected.id,
          type = "paragraph", variant = "caption",
          content = selected.repo_label or "?",
          style = "margin:2px 0 6px;" },
        { id = "dt_path_" .. selected.id,
          type = "copy_link", font = "mono",
          text    = selected.repo_path or "",
          toast   = "Repo path copied",
          tooltip = "Click to copy repo path",
          style   = "max-width:100%;" },
      } },

    { id = "dt_rt_" .. selected.id,
      type = "section", card = true, title = "Runtime",
      children = {
        { id = "dt_en_" .. selected.id,
          type = "checkbox", name = "item_enabled_" .. selected.id,
          label   = "Enabled — uncheck to skip this item without removing it",
          default = (selected.enabled ~= false) },
        { id = "dt_af_" .. selected.id,
          type = "checkbox", name = "item_allow_fail_" .. selected.id,
          label   = "Allow failure — honored only when the sequence is fail-fast",
          default = selected.allow_failure and true or false },
      } },

    { id = "dt_vars_" .. selected.id,
      type = "section", card = true,
      title = "Variable overrides for this item",
      children = {
        { id = "dt_vars_kv_" .. selected.id,
          type = "kv_list", name = "item_vars_" .. selected.id,
          key_label = "Name", value_label = "Value override",
          key_placeholder = "ENV", value_placeholder = "staging",
          default = item_vars },
        label("Merged on top of the sequence's global variables. " ..
              "A matching NAME replaces the global; unrelated names are " ..
              "added to the effective env for this item only."),
      } },
  }
end

local function build_items_tab(sequence)
  local sel_item_id = M.state.selected_item_id or ""

  -- The 3-col row takes all the available height so each column scrolls
  -- independently. `align: stretch` makes columns equal height; internal
  -- scroll on each container keeps the modal body height stable.
  return {
    { id = "items_row",
      type = "row", gap = 0, align = "stretch",
      style = "flex: 1 1 auto; min-height: 0; height: 100%;",
      children = {
        -- ── Palette (left) ────────────────────────────────────────────
        { id = "items_palette",
          type = "container",
          style = "flex: 0 0 280px; display:flex; flex-direction:column; " ..
                  "gap:8px; overflow-y:auto; min-height:0; padding:0 8px 0 0;",
          children = build_palette_column(),
        },
        -- ── Items tree (middle) ───────────────────────────────────────
        { id = "items_tree_col",
          type = "container",
          style = "flex: 0 0 260px; display:flex; flex-direction:column; " ..
                  "gap:6px; overflow-y:auto; min-height:0; padding:0 10px; " ..
                  "border-left:1px solid var(--border-subtle); " ..
                  "border-right:1px solid var(--border-subtle);",
          children = build_items_tree(sequence, sel_item_id),
        },
        -- ── Detail (right) ────────────────────────────────────────────
        { id = "items_detail",
          type = "container",
          style = "flex: 1 1 auto; display:flex; flex-direction:column; " ..
                  "gap:10px; overflow-y:auto; min-height:0; padding:0 0 0 10px;",
          children = build_detail_column(sequence, sel_item_id),
        },
      },
    },
  }
end

-- ── Tab: History (runs of THIS sequence) ────────────────────────────────────

local function build_history_tab(sequence)
  local all = seq_store.load_runs()
  local mine = {}
  for _, r in ipairs(all) do
    if r.sequence_id == sequence.id then mine[#mine+1] = r end
  end
  table.sort(mine, function(a, b)
    return (a.started_at or 0) > (b.started_at or 0)
  end)

  if #mine == 0 then
    return {
      { type = "alert", variant = "info",
        text = "No runs for this sequence yet. Start one from the sidebar — " ..
               "or the Run icon in the toolbar above — and entries will land here." },
    }
  end

  -- Compact rows. Header actions on each card let the user cancel/discard.
  local STATUS_ICON = {
    success   = "CircleCheck",
    running   = "Loader2",
    failed    = "CircleX",
    partial   = "CircleAlert",
    cancelled = "Ban",
  }
  local STATUS_VARIANT = {
    success   = "success",
    running   = "info",
    failed    = "danger",
    partial   = "warning",
    cancelled = "muted",
  }

  local out = {}
  for _, r in ipairs(mine) do
    local s = r.status or "?"
    local head_actions = {}
    if s == "running" then
      head_actions[#head_actions+1] = {
        icon = "Ban", tooltip = "Cancel run", variant = "danger",
        action = "source-export:seq_run_cancel", extra = { id = r.id } }
    end
    head_actions[#head_actions+1] = {
      icon = "Trash2", tooltip = "Discard from history", variant = "danger",
      action = "source-export:seq_run_discard", extra = { id = r.id } }

    local items_rows = {}
    for _, it in ipairs(r.items or {}) do
      local dur = (it.started_at and it.started_at > 0)
        and format_duration(it.started_at, it.finished_at) or "—"
      items_rows[#items_rows+1] = {
        id = "hist_row_" .. r.id .. "_" .. (it.item_id or "?"),
        type = "row", gap = 8, align = "center", children = {
          { id = "hist_ic_" .. r.id .. "_" .. (it.item_id or "?"),
            type = "icon", icon = STATUS_ICON[it.status] or "Circle",
            variant = STATUS_VARIANT[it.status] or "default",
            size = 14, tooltip = it.status or "" },
          { id = "hist_lbl_" .. r.id .. "_" .. (it.item_id or "?"),
            type = "paragraph",
            content = (it.profile_name or "?") .. "  @  " .. (it.repo_label or "?"),
            style = "flex:1 1 auto; margin:0;" },
          { id = "hist_dur_" .. r.id .. "_" .. (it.item_id or "?"),
            type = "paragraph", variant = "caption",
            content = dur,
            style = "margin:0; font-family: var(--font-code); min-width:56px; text-align:right;" },
        } }
    end

    local run_children = {
      { id = "hist_meta_" .. r.id,
        type = "paragraph", variant = "caption",
        content = format_ts(r.started_at) ..
                  "  ·  " .. format_duration(r.started_at, r.finished_at),
        style = "margin:0;" },
    }
    if r.output_root and r.output_root ~= "" then
      run_children[#run_children+1] = {
        id = "hist_out_" .. r.id,
        type = "copy_link", font = "mono",
        text    = r.output_root,
        toast   = "Output path copied",
        tooltip = "Click to copy output root",
        style   = "max-width:100%;" }
    end
    for _, row in ipairs(items_rows) do run_children[#run_children+1] = row end

    out[#out+1] = {
      id = "hist_run_" .. r.id,
      type = "section", card = true, collapsible = true,
      title = string.upper(s) .. "  ·  " .. (r.sequence_name or r.sequence_id),
      count = #(r.items or {}),
      header_actions = head_actions,
      children = run_children,
    }
  end
  return out
end

-- ── Sequence tree (left column) ─────────────────────────────────────────────

local function build_sequence_tree(list, selected_id)
  local nodes = {}
  for _, s in ipairs(list) do
    local suffix = ""
    local n = #(s.items or {})
    if n > 0 then suffix = "  (" .. n .. ")" end
    nodes[#nodes+1] = {
      value = s.id,
      label = (s.name or s.id) .. suffix,
      icon  = "Workflow",
    }
  end
  if #nodes == 0 then
    nodes[#nodes+1] = { value = "__none__",
      label = "(no sequences yet)", icon = "CircleSlash" }
  end
  return {
    { value = "grp_sequences", label = "Sequences", group = true, children = nodes }
  }
end

-- ── Body builder ────────────────────────────────────────────────────────────

local function build_body(list, state)
  local sel_id = state.selected_sequence_id
  local selected
  if sel_id ~= "" then
    for _, s in ipairs(list) do
      if s.id == sel_id then selected = s; break end
    end
  end
  if not selected then
    selected = list[1]
    if selected then state.selected_sequence_id = selected.id end
  end

  local nav_toolbar = { type = "row", gap = 4, align = "center", children = {
    { type = "button", icon = "Plus", icon_only = true, tooltip = "New sequence",
      variant = "ghost",
      action = "source-export:seq_new_in_modal" },
    { type = "button", icon = "Copy", icon_only = true, variant = "ghost",
      tooltip = "Duplicate",
      action = "source-export:seq_duplicate_in_modal",
      extra  = { sequence_id = sel_id } },
    { type = "button", icon = "Play", icon_only = true, variant = "ghost",
      tooltip = "Run now",
      action = "source-export:seq_run",
      extra  = { sequence_id = sel_id } },
    { type = "button", icon = "Trash2", icon_only = true, variant = "ghost",
      tooltip = "Delete",
      action = "source-export:seq_delete_in_modal",
      extra  = { sequence_id = sel_id } },
  }}

  local nav_children = {
    nav_toolbar,
    { type = "tree", name = "sel_sequence", default = state.selected_sequence_id,
      expanded = true,
      change_action = "source-export:seq_select",
      nodes = build_sequence_tree(list, state.selected_sequence_id) },
  }

  local content
  if selected then
    -- Stable tabs id preserves the active-tab selection across rebuilds
    -- (form.replace keys by node.id — auto-gen id would reset every render).
    local active = state.active_tab or "info"
    content = {
      { id = "seq_tabs", type = "tabs", default_tab = active, tabs = {
        { id = "info",    label = "Info",    icon = "Info",
          children = build_info_tab(selected) },
        -- `flush = true` so the 3-column row can fill the tab body
        -- edge-to-edge; the inner containers handle their own scroll.
        { id = "items",   label = "Items",   icon = "Workflow",
          flush = true,
          children = build_items_tab(selected) },
        { id = "history", label = "History", icon = "History",
          children = build_history_tab(selected) },
      } },
    }
  else
    content = {
      { type = "alert", variant = "info",
        text = "No sequence selected. Create one with the + button above." },
    }
  end

  return {
    state = {
      sel_sequence = state.selected_sequence_id,
      sel_item     = state.selected_item_id,
      active_tab   = state.active_tab,
    },
    nodes = {
      -- nav_width matches the profile editor (modal.lua) so both modals
      -- read as the same surface. `tree_layout` + section cards inherit
      -- every visual token (borders, radii, colors) from PluginFormModal.
      { id = "seq_root", type = "tree_layout",
        nav_width             = "240px",
        nav_collapsible       = true,
        nav_collapsed_default = false,
        nav_children          = nav_children,
        content_children      = content },
    },
  }
end

-- ── Open / refresh ──────────────────────────────────────────────────────────

function M.refresh()
  local list = seq_store.load()
  local body = build_body(list, M.state)

  -- Echo back defaults so the form picks them up after the rebuild (form.replace
  -- preserves existing user edits whose field name is unchanged, but for
  -- fields belonging to a different selected item we need to push fresh
  -- values via set_values). kv_list defaults use Record<string,string>.
  local set = {}
  local selected
  for _, s in ipairs(list) do
    if s.id == M.state.selected_sequence_id then selected = s; break end
  end
  if selected then
    set.seq_name        = selected.name or ""
    set.seq_description = selected.description or ""
    set.seq_fail_fast   = selected.fail_fast and true or false
    set.seq_output_root = selected.output_root or ""
    local vars = {}
    for _, v in ipairs(selected.variables or {}) do
      if v.key and v.key ~= "" then vars[v.key] = v.value or "" end
    end
    set.seq_vars = vars

    -- Push the SELECTED item's field defaults so switching items in the
    -- tree refreshes the detail column. Without this, the checkboxes keep
    -- whatever value they had for the previous item (same field name
    -- because IDs change per item).
    local sel_item_id = M.state.selected_item_id or ""
    if sel_item_id ~= "" then
      for _, it in ipairs(selected.items or {}) do
        if it.id == sel_item_id then
          set["item_enabled_" .. it.id]    = (it.enabled ~= false)
          set["item_allow_fail_" .. it.id] = it.allow_failure and true or false
          local ivars = {}
          for _, v in ipairs(it.variables or {}) do
            if v.key and v.key ~= "" then ivars[v.key] = v.value or "" end
          end
          set["item_vars_" .. it.id] = ivars
          break
        end
      end
    end
    set.sel_item = sel_item_id
  end

  arbor.ui.form.replace({
    nodes      = body.nodes,
    state      = body.state,
    set_values = set,
  })
end

function M.open(initial_sequence_id)
  reset_state()
  local list = seq_store.load()
  if initial_sequence_id and initial_sequence_id ~= "" then
    M.state.selected_sequence_id = initial_sequence_id
  else
    M.state.selected_sequence_id = list[1] and list[1].id or ""
  end
  local body = build_body(list, M.state)
  arbor.ui.form({
    title         = "Sequences",
    -- 1180 × 780 fits the 3-col Items tab (240 nav + 280 palette + 260 tree
    -- + detail flex) with breathing room, and still lands comfortably on a
    -- 14" laptop screen.
    width         = "1180px",
    height        = "780px",
    submit_label  = "Save",
    submit_action = "source-export:seq_save_all",
    cancel_label  = "Close",
    cancel_action = "source-export:seq_cancel",
    state         = body.state,
    nodes         = body.nodes,
  })
end

return M
