-- state.lua — shared mutable state for run-action
-- Holds the currently active repo path and running job tracking.

local M = {}

M.current_repo = ""

-- Runtime-only flag flipped by sibling plugins (e.g. run-monitor) via the
-- `run-action.set_hide_services` cross-plugin service. When true, every
-- "Services"-category job we spawn is marked `hidden = true` so it stays
-- out of the host's default Jobs overlay / status badge. There is no on-disk
-- persistence and no UI: reload resets to false, only another plugin can
-- ever flip it. Lives here (not in main.lua) so tomcat_pipeline.lua and any
-- future spawn site can read it without an `arbor.service.call` round-trip.
M.hide_services = false
function M.set_hide_services(v) M.hide_services = v and true or false end

-- Decide whether the NEXT Services-category job should spawn hidden.
--
-- The set_hide_services flag is the "primary" channel — run-monitor flips it
-- via arbor.service.call when it loads/unloads. But that call is async (it
-- spawns a thread that waits for the plugin_host mutex held by the reload
-- loop), so there are three drift windows where the flag lies:
--   1. App startup: run-monitor's on_plugin_load fires before its
--      service.call thread has gotten the lock → flag still false.
--   2. Mid-session reload of run-action only: our state module re-evaluates,
--      M.hide_services drops back to false, but run-monitor isn't notified
--      to re-call.
--   3. Lock poisoning on the host side silently no-ops the service.call.
--
-- The synchronous `arbor.meta.plugin_loaded(name)` host API closes all three
-- by reading the live plugin list directly. We OR it with the flag so an
-- explicit `set_hide_services(false)` (e.g. run-monitor unload) still wins
-- over the presence check while run-monitor is still being torn down.
function M.services_hidden()
  if M.hide_services then return true end
  local ok, present = pcall(arbor.meta.plugin_loaded, "run-monitor")
  return ok and present == true
end

-- Tracks currently running run-jobs, scoped per repo:
--   { [repo_path] = { [run_config_id] = job_id } }
-- Scoping is essential so that launching a run in one repo never cancels
-- or shadows a run that belongs to another repo — same cfg_id can legitimately
-- exist in two different repos (e.g. two clones, or global configs reused
-- across tabs).
M.running_jobs = {}

-- Per-repo queued run: { [repo_path] = { run_cfg, build_cfg } }
-- A run queued to launch once the build for that repo finishes.
-- build_cfg is a snapshot of the build config the user chose, so the
-- post-build handler does not have to query compile-action again.
M.pending_runs = {}

function M.set_repo(path)
  M.current_repo = path or ""
end

--- Record a spawned run job for a specific repo.
function M.track_run(repo_path, cfg_id, job_id)
  repo_path = repo_path or M.current_repo or ""
  local t = M.running_jobs[repo_path]
  if not t then
    t = {}
    M.running_jobs[repo_path] = t
  end
  t[cfg_id] = job_id
end

--- Clear a finished/cancelled run job for a specific repo.
function M.untrack_run(repo_path, cfg_id)
  repo_path = repo_path or M.current_repo or ""
  local t = M.running_jobs[repo_path]
  if not t then return end
  t[cfg_id] = nil
  if next(t) == nil then M.running_jobs[repo_path] = nil end
end

--- Return the job_id of the currently running instance of cfg_id in repo_path,
--- or nil. When repo_path is omitted, uses the currently-active repo.
function M.get_running(repo_path, cfg_id)
  -- Backwards-compat: allow single-arg call using current_repo.
  if cfg_id == nil then
    cfg_id    = repo_path
    repo_path = M.current_repo or ""
  end
  local t = M.running_jobs[repo_path]
  return t and t[cfg_id] or nil
end

--- Return the map of { [cfg_id] = job_id } for a specific repo, or an empty
--- table. Never returns nil so callers can `pairs()` it safely.
function M.list_running(repo_path)
  return M.running_jobs[repo_path or M.current_repo or ""] or {}
end

--- Queue a run config to launch once the build for repo_path finishes.
--- run_cfg  : full run-config snapshot (captured while the correct tab was active)
--- build_cfg: full build-config snapshot (received from compile-action.spawn_build)
function M.enqueue_run(run_cfg, build_cfg, repo_path)
  M.pending_runs[repo_path] = { run_cfg = run_cfg, build_cfg = build_cfg }
  arbor.log.info("[state] enqueue_run  repo=" .. tostring(repo_path)
    .. "  run_cfg.id=" .. tostring(run_cfg and run_cfg.id)
    .. "  build_cfg.id=" .. tostring(build_cfg and build_cfg.id))
end

--- Pop and return the queued run for repo_path (if any).
function M.dequeue_run(repo_path)
  local r = M.pending_runs[repo_path]
  M.pending_runs[repo_path] = nil
  return r
end

--- Drop any queued run for repo_path (used when a build fails / is cancelled).
function M.drop_run(repo_path)
  M.pending_runs[repo_path] = nil
end

return M
