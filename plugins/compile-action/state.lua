-- state.lua — shared mutable state for compile-action (build-only).
-- The run-side state now lives in the run-action plugin.

local M = {}

M.current_repo = ""

-- Per-repo build tracking: { [repo_path] = job_id }
-- Allows concurrent builds across different repositories.
M.active_builds = {}

function M.set_repo(path)
  M.current_repo = path or ""
end

--- Record the active build job for a specific repo.
function M.track_build(repo_path, job_id)
  local prev = M.active_builds[repo_path]
  M.active_builds[repo_path] = job_id
  arbor.log.info("[state] track_build  repo=" .. tostring(repo_path)
    .. "  job_id=" .. tostring(job_id)
    .. (prev and ("  (was=" .. prev .. ")") or ""))
end

--- Clear the active build job for a specific repo.
function M.untrack_build(repo_path)
  local prev = M.active_builds[repo_path]
  M.active_builds[repo_path] = nil
  arbor.log.info("[state] untrack_build  repo=" .. tostring(repo_path)
    .. "  was_job=" .. tostring(prev))
end

--- Return the running build job_id for a repo, or nil.
function M.get_build(repo_path)
  return M.active_builds[repo_path]
end

return M
