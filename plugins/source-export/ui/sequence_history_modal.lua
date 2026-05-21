-- ui/sequence_history_modal.lua — run history for Source Export sequences.
--
-- Read-only modal. One collapsible card per SequenceRun; the card title is
-- a rich status line (colored paragraph variant, count badge, duration).
-- Each per-item row shows a status glyph + profile@repo + duration.
--
-- Built to be calmly colorful: status glyphs give immediate read-out (green
-- check, red X, amber warn, spinning loader), durations use a mono font,
-- output paths are dimmed. No faux-tabs, no clutter.

local seq_store = require("config.sequences")

local M = {}

-- ── formatters ──────────────────────────────────────────────────────────────

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

-- Status → (Lucide icon name, semantic variant for paragraph/alert coloring)
-- The form renderer maps `paragraph.variant` to a CSS class; we piggyback on
-- existing variants (caption/muted/heading) to color without extending the
-- theme. Icons handled separately.
local STATUS_ICON = {
  success   = "CircleCheck",
  running   = "Loader2",
  failed    = "CircleX",
  partial   = "CircleAlert",
  cancelled = "Ban",
  pending   = "CircleDashed",
  skipped   = "MinusCircle",
}

local STATUS_VARIANT = {
  success   = "success",
  running   = "info",
  failed    = "danger",
  partial   = "warning",
  cancelled = "muted",
  pending   = "muted",
  skipped   = "muted",
}

local STATUS_LABEL = {
  success   = "Success",
  running   = "Running",
  failed    = "Failed",
  partial   = "Partial",
  cancelled = "Cancelled",
  pending   = "Pending",
  skipped   = "Skipped",
}

local function status_icon(status)    return STATUS_ICON[status]    or "Circle"  end
local function status_variant(status) return STATUS_VARIANT[status] or "default" end
local function status_label(status)   return STATUS_LABEL[status]   or (status or "?") end

-- ── Status colour helper ────────────────────────────────────────────────────
-- Maps run status to a CSS var so meta text and totals can pick up the
-- semantic color without a heavy Alert chrome around them.
local function status_color_var(status)
  if status == "success"                          then return "var(--success)"     end
  if status == "failed" or status == "cancelled"  then return "var(--error)"       end
  if status == "partial"                          then return "var(--warning)"     end
  if status == "running"                          then return "var(--accent)"      end
  return "var(--text-muted)"
end

-- ── Per-item row ────────────────────────────────────────────────────────────

local function build_item_row(it)
  -- Single inline row: [status glyph] [profile @ repo link] [duration].
  -- Padded by 2px vertically only — the row reads as a tight log line
  -- rather than a card-in-a-card.
  local duration = (it.started_at and it.started_at > 0)
    and format_duration(it.started_at, it.finished_at) or "—"
  local has_run = it.pipeline_run_id and it.pipeline_run_id ~= ""

  return {
    type = "row", gap = 8, align = "center",
    id   = "sr_item_" .. (it.item_id or "?"),
    style = "padding: 1px 0;",
    children = {
      { type = "icon", icon = status_icon(it.status),
        variant = status_variant(it.status),
        size = 14, tooltip = status_label(it.status) },
      { type = "button",
        icon  = has_run and "ExternalLink" or nil,
        label = (it.profile_name or "?") .. "  @  " .. (it.repo_label or "?"),
        variant  = "ghost",
        disabled = not has_run,
        tooltip  = has_run and "Open pipeline run in the Pipelines panel"
                           or "No pipeline run associated (item never started)",
        action   = "source-export:seq_nav_run",
        extra    = { run_id = it.pipeline_run_id or "" },
        style    = "flex:1 1 auto; justify-content:flex-start; min-width:0;" },
      { type = "paragraph", variant = "caption",
        content = duration,
        style = "margin:0; font-family: var(--font-code); min-width:54px; text-align:right;" },
    },
  }
end

-- ── Per-run card (collapsible) ──────────────────────────────────────────────

local function build_run_card(run)
  -- Header actions: cancel (if running) + discard.
  local header_actions = {}
  if run.status == "running" then
    header_actions[#header_actions+1] = {
      icon = "Ban", tooltip = "Cancel run",
      variant = "danger",
      action = "source-export:seq_run_cancel",
      extra = { id = run.id } }
  end
  header_actions[#header_actions+1] = {
    icon = "Trash2", tooltip = "Discard from history",
    variant = "danger",
    action = "source-export:seq_run_discard",
    extra = { id = run.id } }

  -- ── Tally items by terminal state ────────────────────────────────────────
  local s_ok, s_ko, s_other = 0, 0, 0
  for _, it in ipairs(run.items or {}) do
    if it.status == "success" then s_ok = s_ok + 1
    elseif it.status == "failed" or it.status == "cancelled" then s_ko = s_ko + 1
    else s_other = s_other + 1 end
  end

  -- ── Compact meta row ─────────────────────────────────────────────────────
  -- Single line: colored status word · duration · timestamp · (only when
  -- the breakdown adds info beyond the per-item rows) tally chips. No
  -- Alert chrome — that was eating ~40px of vertical space for what is
  -- ultimately a one-line summary.
  local meta_color = status_color_var(run.status)
  local meta_children = {
    { type = "paragraph",
      content = status_label(run.status),
      style = "margin:0; font-weight:600; font-size:12px; color: " .. meta_color .. ";" },
    { type = "paragraph", variant = "caption",
      content = "·  " .. format_duration(run.started_at, run.finished_at)
              .. "  ·  " .. format_ts(run.started_at),
      style = "margin:0; flex:1 1 auto;" },
  }

  -- Tally chips: only meaningful when the run has more than one item, AND
  -- only when a category has a non-zero count. For single-item runs the
  -- per-item row is already self-explanatory and the chip would just
  -- duplicate it.
  local total_items = #(run.items or {})
  if total_items > 1 then
    local chip = "margin:0; padding:0 7px; border-radius:999px; " ..
                 "font-size:10px; font-weight:600; border:1px solid;"
    if s_ok > 0 then
      meta_children[#meta_children+1] = { type = "paragraph",
        content = "✓ " .. s_ok,
        style = chip ..
                " color: var(--success); " ..
                "border-color: color-mix(in srgb, var(--success) 35%, transparent);" }
    end
    if s_ko > 0 then
      meta_children[#meta_children+1] = { type = "paragraph",
        content = "✗ " .. s_ko,
        style = chip ..
                " color: var(--error); " ..
                "border-color: color-mix(in srgb, var(--error) 35%, transparent);" }
    end
    if s_other > 0 then
      meta_children[#meta_children+1] = { type = "paragraph",
        content = "⏸ " .. s_other,
        style = chip ..
                " color: var(--text-muted); " ..
                "border-color: var(--border-subtle);" }
    end
  end

  local children = {
    { type = "row", gap = 8, align = "center",
      style = "padding: 0 0 4px; border-bottom: 1px solid var(--border-subtle); margin-bottom: 4px;",
      children = meta_children },
  }

  -- ── Item rows (no section label — count badge in the card header
  --    already conveys "N steps") ──────────────────────────────────────────
  for _, it in ipairs(run.items or {}) do
    children[#children+1] = build_item_row(it)
  end

  -- ── Output folder ────────────────────────────────────────────────────────
  -- Inline single row at the bottom: a folder glyph hints the row's role,
  -- the path is a copy_link, the trailing button opens it. No section
  -- label — the icon is enough context for one path.
  if run.output_root and run.output_root ~= "" then
    children[#children+1] = {
      type = "row", gap = 6, align = "center",
      id   = "sr_out_" .. run.id,
      style = "margin-top: 4px; padding-top: 4px; " ..
              "border-top: 1px solid var(--border-subtle);",
      children = {
        { type = "icon", icon = "Folder", variant = "muted", size = 12 },
        { type = "copy_link", font = "mono",
          text    = run.output_root,
          toast   = "Output path copied",
          tooltip = "Click to copy",
          style   = "flex:1 1 auto; min-width:0; font-size:11px;" },
        { type = "button", icon = "FolderOpen", icon_only = true,
          variant = "ghost", tooltip = "Open in file manager",
          action  = "source-export:seq_open_output",
          extra   = { path = run.output_root } },
      },
    }
  end

  -- Title prefixes the sequence name with a small status glyph so the user
  -- still gets the outcome at a glance when the card is collapsed (the body
  -- alert is hidden in that state). Glyphs render reliably on every platform
  -- and stay readable even in monochrome — the colored banner inside the
  -- body adds the chromatic layer when the card is expanded.
  local TITLE_GLYPH = {
    success   = "✓ ",
    failed    = "✗ ",
    partial   = "◐ ",
    cancelled = "⊘ ",
    running   = "● ",
    pending   = "○ ",
  }
  local title = (TITLE_GLYPH[run.status] or "")
              .. (run.sequence_name or run.sequence_id)

  return {
    id = "sr_" .. run.id,
    type = "section", card = true, collapsible = true,
    title = title,
    header_actions = header_actions,
    count = #(run.items or {}),
    children = children,
  }
end

-- ── Body + open ─────────────────────────────────────────────────────────────

local function build_body()
  local runs = seq_store.load_runs()
  local nodes = {}

  if #runs == 0 then
    nodes[#nodes+1] = { type = "alert", variant = "info",
      text = "No sequence runs yet. Start a sequence from the right-side " ..
             "sidebar — runs land here most-recent first, capped at the last 50." }
    return nodes
  end

  -- ── Top toolbar ──────────────────────────────────────────────────────────
  -- Compact summary: total + per-status tallies as coloured pills, then a
  -- "Clear all" danger button on the right. The pills give an immediate
  -- read-out of how many runs succeeded / failed without scrolling.
  local tot_ok, tot_ko, tot_running = 0, 0, 0
  for _, r in ipairs(runs) do
    if r.status == "success" then tot_ok = tot_ok + 1
    elseif r.status == "failed" or r.status == "cancelled" then tot_ko = tot_ko + 1
    elseif r.status == "running" then tot_running = tot_running + 1
    end
  end

  local pill_style = "margin:0; padding:1px 9px; border-radius:999px; " ..
                     "font-size:11px; font-weight:600; " ..
                     "border:1px solid; background:transparent;"

  local toolbar_children = {
    { type = "paragraph", variant = "heading",
      content = tostring(#runs) .. " run" .. (#runs == 1 and "" or "s"),
      style = "margin:0; font-size:13px;" },
  }
  if tot_ok > 0 then
    toolbar_children[#toolbar_children+1] = { type = "paragraph",
      content = "✓ " .. tot_ok,
      style = pill_style ..
              " color: var(--success); " ..
              "border-color: color-mix(in srgb, var(--success) 35%, transparent);" }
  end
  if tot_ko > 0 then
    toolbar_children[#toolbar_children+1] = { type = "paragraph",
      content = "✗ " .. tot_ko,
      style = pill_style ..
              " color: var(--error); " ..
              "border-color: color-mix(in srgb, var(--error) 35%, transparent);" }
  end
  if tot_running > 0 then
    toolbar_children[#toolbar_children+1] = { type = "paragraph",
      content = "● " .. tot_running .. " running",
      style = pill_style ..
              " color: var(--accent); " ..
              "border-color: color-mix(in srgb, var(--accent) 35%, transparent);" }
  end
  -- Spacer pushes the danger button to the far right.
  toolbar_children[#toolbar_children+1] = { type = "paragraph", content = "",
    style = "flex:1 1 auto; margin:0;" }
  toolbar_children[#toolbar_children+1] = { type = "button",
    icon = "Trash", label = "Clear all",
    variant = "danger",
    action = "source-export:seq_history_clear" }

  nodes[#nodes+1] = {
    type = "row", gap = 10, align = "center",
    style = "padding: 0 0 8px; border-bottom: 1px solid var(--border-subtle); " ..
            "margin-bottom: 4px;",
    children = toolbar_children,
  }

  for _, r in ipairs(runs) do
    nodes[#nodes+1] = build_run_card(r)
  end
  return nodes
end

function M.open()
  arbor.ui.form({
    title         = "Sequence History",
    width         = "920px",
    height        = "720px",
    -- Read-only: hide the ghost Cancel button; the primary Close is enough.
    hide_cancel   = true,
    submit_label  = "Close",
    submit_action = "source-export:seq_noop",
    nodes         = build_body(),
  })
end

function M.refresh()
  arbor.ui.form.replace({ nodes = build_body() })
end

return M
