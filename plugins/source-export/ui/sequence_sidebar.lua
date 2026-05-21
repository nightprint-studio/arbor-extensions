-- ui/sequence_sidebar.lua — right-side sidebar panel for sequences.
--
-- Clean list view only:
--   · One "card" per sequence with title + short metadata + icon-only inline
--     toolbar (Run / Edit / Duplicate / Delete) rendered as ghost buttons so
--     the cards stay visually calm.
--   · Footer: "New sequence" + "History…" (opens a full-screen modal for the
--     run cronologia — the sidebar is not the right surface for a log view).
--
-- Panel id: "sequences"  (registered in main.lua).

local seq_store = require("config.sequences")

local M = {}

local PANEL_ID = "sequences"

-- ── Sequence card ───────────────────────────────────────────────────────────
--
-- Uses the shared `card_item` node (see PluginSidebarPanel.svelte) so the
-- row reads as the same surface as built-in sidebars (MrSidebar / Reflog).
-- Layout: state icon · title · count badge / subtitle (description) /
-- colored meta chips. The primary click on the body opens the editor
-- (detail view); Run/Duplicate/Delete are hover-revealed icon buttons so
-- the destructive/expensive action is never one stray click away.
local function build_card(seq, last_run_status)
  local items = seq.items or {}
  local total = #items
  local enabled_count = 0
  for _, it in ipairs(items) do
    if it.enabled ~= false then enabled_count = enabled_count + 1 end
  end

  -- Meta chips: item count + fail-fast flag + last run status (color-coded).
  local meta = {
    { text = string.format("%d enabled", enabled_count), variant = "muted" },
  }
  if seq.fail_fast then
    meta[#meta+1] = { text = "fail-fast", variant = "warning" }
  end
  if last_run_status == "success" then
    meta[#meta+1] = { text = "last: success", variant = "success" }
  elseif last_run_status == "running" then
    meta[#meta+1] = { text = "running", variant = "accent" }
  elseif last_run_status == "failed" then
    meta[#meta+1] = { text = "last: failed", variant = "danger" }
  elseif last_run_status == "partial" then
    meta[#meta+1] = { text = "last: partial", variant = "warning" }
  end

  return {
    id       = seq.id,
    type     = "card_item",
    icon     = "Route",
    -- Status-colored icon hints at activity: orange when running, neutral
    -- otherwise. Keeps the card calm 99 % of the time.
    icon_variant = (last_run_status == "running") and "accent" or nil,
    title    = seq.name or seq.id,
    badge    = (total > 0) and tostring(total) or nil,
    subtitle = (seq.description and seq.description ~= "") and seq.description or nil,
    meta     = meta,
    tooltip  = "Click to edit · use Play to run",
    action   = "source-export:seq_edit",
    actions  = {
      { icon = "Play", tooltip = "Run sequence", variant = "accent",
        action = "source-export:seq_run" },
      { icon = "Copy", tooltip = "Duplicate sequence",
        action = "source-export:seq_duplicate" },
      { icon = "Trash2", tooltip = "Delete sequence", variant = "danger",
        action = "source-export:seq_delete" },
    },
  }
end

-- ── Push content ────────────────────────────────────────────────────────────

-- Pick the most recent run's status per sequence so the card can flag
-- "last: failed" / "running" inline. Scan runs once (they're capped at 50).
local function latest_status_per_sequence()
  local by_seq = {}
  for _, r in ipairs(seq_store.load_runs()) do
    local prev = by_seq[r.sequence_id]
    if not prev or (r.started_at or 0) > (prev.started_at or 0) then
      by_seq[r.sequence_id] = r
    end
  end
  local out = {}
  for sid, r in pairs(by_seq) do out[sid] = r.status end
  return out
end

function M.push()
  local list    = seq_store.load()
  local statuses = latest_status_per_sequence()
  local nodes   = {}

  if #list == 0 then
    nodes[#nodes+1] = { type = "paragraph",
      text = "No sequences yet. A sequence runs several export profiles in " ..
             "order across different repos and shares a single output folder." }
    nodes[#nodes+1] = {
      type = "button", icon = "Plus", label = "Create first sequence",
      variant = "primary",
      action = "source-export:seq_new",
    }
  else
    for _, seq in ipairs(list) do
      nodes[#nodes+1] = build_card(seq, statuses[seq.id])
    end
  end

  -- Footer actions: primary "New" + neutral "History…" (opens the run
  -- cronologia as a full modal — see sequence_history_modal.lua).
  local footer = {
    { label = "New sequence", icon = "Plus",
      action = "source-export:seq_new" },
    { label = "History…",     icon = "History",
      action = "source-export:seq_history_open" },
  }

  arbor.ui.set_panel_content(PANEL_ID, {
    title   = "Export Sequences",
    nodes   = nodes,
    actions = footer,
  })
end

function M.refresh() M.push() end

function M.register()
  arbor.ui.add_sidebar({
    id       = PANEL_ID,
    icon     = "Route",
    label    = "Export Sequences",
    tooltip  = "Multi-export sequences (Source Export)",
    side     = "right",
    position = "top",
  })
end

return M
