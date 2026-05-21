-- run-monitor — dedicated bottom panel for run-action services.
--
-- At load time we tell run-action to flip its `hide_services` flag on, which
-- makes every "Services"-category job it spawns from then on enter the
-- registry as `hidden = true`. The host's default JobsOverlay + status-bar
-- badge skip hidden jobs (revealable via the "Show hidden" toggle), so this
-- panel becomes the canonical surface for running services without
-- duplicating their entries.
--
-- The panel itself is just a polling view over `arbor.job.list()` filtered
-- by category. There is no global `on_job_started`/`on_job_done` hook in the
-- host, and adding one for a single consumer would be premature — a 1.5 s
-- timer plus a refresh on `panel:open` is plenty for the human-paced read
-- ("did my Tomcat come up yet?") and costs almost nothing (one mutex lock +
-- a few JSON conversions).
--
-- Click on a card → `arbor.ui.open_job_output(job_id)` → the host loads the
-- buffer and swaps the bottom section to the existing JobOutputPanel, where
-- the job's stdout streams live. Closing JobOutputPanel returns control to
-- our panel via the right-bottom ActivityBar icon.

local M = {}

local TIMER_MS  = 1500
local CATEGORY  = "Services"
local PANEL_ID  = "services"

-- Cached cancel handle for the polling timer so on_plugin_unload can stop
-- the background thread (otherwise it keeps firing the hook into a Lua VM
-- that's about to be torn down).
local refresh_timer = nil

-- Format an elapsed-time string from a unix-seconds start. Mirrors the
-- "4s" / "1m 12s" / "2h 3m" shape used by JobsOverlay so users see the same
-- vocabulary across surfaces.
--
-- For terminated jobs we want the duration to FREEZE at the stopping time,
-- not keep counting up forever. The host stamps `finished_at` on every
-- terminal status transition, so when the job isn't running we use that as
-- the upper bound. Falls back to `os.time()` if a job has somehow ended
-- without a finished_at (defensive — shouldn't happen with current host).
local function elapsed(j)
  if not j then return "0s" end
  local started = j.started_at or 0
  local end_at
  local running = (j.status and j.status.type) == "running"
  if running then
    end_at = os.time()
  else
    end_at = j.finished_at or j.started_at or os.time()
  end
  local secs = math.max(0, end_at - started)
  if secs < 60   then return secs .. "s" end
  if secs < 3600 then
    local m = math.floor(secs / 60)
    local s = secs % 60
    return m .. "m " .. s .. "s"
  end
  local h = math.floor(secs / 3600)
  local m = math.floor((secs % 3600) / 60)
  return h .. "h " .. m .. "m"
end

-- Map a JobInfo.status table → (icon, variant, label, is_running).
-- `status.type` is one of running | completed | failed | cancelled; for
-- "completed" we still bucket exit_code 0 / non-zero so the user can tell
-- a clean exit from a crash without opening the output.
local function status_visual(status)
  local t = (status and status.type) or "running"
  if t == "running" then
    return "Loader",       "accent",  "running",  true
  elseif t == "completed" then
    if (status.exit_code or 0) == 0 then
      return "CheckCircle2", "success", "exit 0",   false
    end
    return   "XCircle",     "danger",  "exit " .. tostring(status.exit_code or "?"), false
  elseif t == "cancelled" then
    return   "MinusCircle", "muted",   "cancelled", false
  else
    return   "XCircle",     "danger",  "failed",    false
  end
end

-- Build the list of card_item nodes shown in the panel body. Sorted with
-- running services on top, then most-recently-started first within each
-- bucket — matches what users glance at most ("what's still up right now").
local function build_service_nodes(jobs)
  local services = {}
  for _, j in ipairs(jobs or {}) do
    if (j.category or "") == CATEGORY then
      services[#services + 1] = j
    end
  end
  table.sort(services, function(a, b)
    local ar = (a.status and a.status.type == "running") and 1 or 0
    local br = (b.status and b.status.type == "running") and 1 or 0
    if ar ~= br then return ar > br end
    return (a.started_at or 0) > (b.started_at or 0)
  end)

  local nodes = {}
  for _, j in ipairs(services) do
    local icon, variant, status_label, is_running = status_visual(j.status)
    local meta = {
      { text = elapsed(j),            variant = is_running and "accent" or "muted" },
      { text = status_label,          variant = variant },
    }
    if (j.plugin_name or "") ~= "" then
      meta[#meta + 1] = { text = j.plugin_name, variant = "muted" }
    end

    -- Stop only appears for running services. When present it's red and
    -- pinned (always_visible) so the user doesn't have to hover the row to
    -- discover it — critical for a "kill that runaway service" interaction.
    -- Open-output stays hover-revealed since it's the same action as
    -- clicking the card body. Trash for finished rows is the panel footer.
    local actions = {}
    if is_running then
      actions[#actions + 1] = {
        action         = "run-monitor:cancel",
        icon           = "Square",
        tooltip        = "Stop service",
        variant        = "danger",
        always_visible = true,
      }
    end
    actions[#actions + 1] = {
      action  = "run-monitor:open_output",
      icon    = "ExternalLink",
      tooltip = "Open output",
    }

    nodes[#nodes + 1] = {
      type         = "card_item",
      id           = j.id,
      icon         = icon,
      icon_spin    = is_running,
      icon_variant = variant,
      title        = j.name or j.id,
      subtitle     = j.command,
      tooltip      = j.command,
      meta         = meta,
      -- Primary click on the card body opens the output panel directly —
      -- the most common interaction. Per-card secondary actions (cancel,
      -- open-output) sit on the right and don't bubble.
      action       = "run-monitor:open_output",
      actions      = actions,
    }
  end
  return nodes
end

-- Push a fresh snapshot into the panel. Always safe to call: the host's
-- contribution store dedupes by (plugin, panel) so calling this when nobody
-- has the panel open is just a cheap write-through with no UI cost.
local function refresh()
  local ok, jobs = pcall(arbor.job.list)
  if not ok then jobs = {} end
  local nodes = build_service_nodes(jobs)

  -- Count terminated entries so we only surface the trash when there's
  -- actually something to clear. Avoids an inert footer button when the
  -- panel is showing only running services.
  local has_finished = false
  for _, j in ipairs(jobs or {}) do
    if (j.category or "") == CATEGORY
       and j.status and j.status.type ~= "running"
    then has_finished = true; break end
  end

  if #nodes == 0 then
    nodes = {
      { type = "label",
        text = "No services running. Launch one from the Build & Run panel "
            .. "(or via Shift+F10) and it will appear here." },
    }
  end

  local actions = nil
  if has_finished then
    actions = {
      { label  = "Clear stopped",
        icon   = "Trash2",
        action = "run-monitor:clear_finished" },
    }
  end

  arbor.ui.set_panel_content(PANEL_ID, {
    title   = "Services",
    nodes   = nodes,
    actions = actions,
  })
end

-- ── Lifecycle ────────────────────────────────────────────────────────────────

arbor.events.on("on_plugin_load", function(_ctx)
  arbor.ui.add_sidebar({
    id       = PANEL_ID,
    icon     = "Server",
    label    = "Services",
    tooltip  = "Running application services",
    side     = "right",
    position = "bottom",
  })

  -- Claim ownership of Services display from run-action. Best-effort: when
  -- run-action is disabled the call returns `not_found`, which is fine —
  -- there will be no Services jobs to show anyway.
  arbor.service.call("run-action.set_hide_services", { value = true })

  -- Pre-warm the panel so opening it for the first time doesn't render the
  -- "Waiting for content…" skeleton. Cheap (one job.list call).
  refresh()

  refresh_timer = arbor.timer.every(TIMER_MS, function() refresh() end)
  arbor.log.info("ready (timer=" .. TIMER_MS .. "ms)")
end)

arbor.events.on("on_plugin_unload", function(_ctx)
  if refresh_timer then
    pcall(function() arbor.timer.cancel(refresh_timer) end)
    refresh_timer = nil
  end
  -- Release ownership so run-action's services come back into the global
  -- Jobs overlay / status badge. Best-effort for the same reason as above.
  arbor.service.call("run-action.set_hide_services", { value = false })
end)

-- Re-pushed on every open so the panel reflects state at the moment the
-- user clicked the icon, not whatever the last poll captured.
arbor.events.on("panel:open:" .. PANEL_ID, function(_ctx)
  refresh()
end)

-- ── Action handlers ─────────────────────────────────────────────────────────

arbor.events.on("run-monitor:open_output", function(ctx)
  local id = ctx and ctx.id or ""
  if id == "" then return end
  arbor.ui.open_job_output(id)
end)

arbor.events.on("run-monitor:cancel", function(ctx)
  local id = ctx and ctx.id or ""
  if id == "" then return end
  arbor.job.cancel(id)
  -- Immediate refresh so the cancel is reflected without waiting for the
  -- next poll tick — feels snappier on click.
  refresh()
end)

-- Footer "Clear stopped" → drop every terminated job from the host registry.
-- We deliberately use the host's clear_finished (which iterates ALL terminal
-- jobs, not just our category) because that matches the user's mental model
-- of "tidy up the registry": there's no per-plugin Clear-finished anywhere
-- else, and singling out Services here would leak old completed Builds /
-- ad-hoc jobs across the same surface.
arbor.events.on("run-monitor:clear_finished", function(_ctx)
  arbor.job.clear_finished()
  refresh()
end)

return M
