-- Local pipeline file ops for run-action.
--
-- Same shape as the (removed) arbor.core.file module — kept here as a
-- plugin-local helper because the standard library now stops at arbor.fs.
-- Only the ops actually referenced by run-action's Tomcat pipeline are
-- registered (delete_file, copy_file). The companion plugin source-export
-- has its own copy with the full op set.
--
-- Op contract:
--   function(params, ctx) -> { exit_code, stdout, stderr? }

local U = require("arbor.core._util")

local M = {}

function M.copy_file(params, ctx)
  local src       = U.abs_path(params.src  or "", ctx)
  local dest      = U.abs_path(params.dest or "", ctx)
  local overwrite = params.overwrite and true or false
  local lines, add = U.new_log("copy_file")
  U.log_entry(add, "src      ", src)
  U.log_entry(add, "dest     ", dest)
  U.log_entry(add, "overwrite", overwrite)
  if not arbor.fs.exists(src) then
    return U.fail(lines, "source not found: " .. src)
  end
  local final_dest = dest
  if arbor.fs.is_dir(dest) then
    local base = src:match("[/\\]([^/\\]+)$") or src
    final_dest = arbor.fs.join(dest, base)
  end
  if not overwrite and arbor.fs.exists(final_dest) and not arbor.fs.is_dir(final_dest) then
    return U.fail(lines, "dest exists and overwrite=false: " .. final_dest)
  end
  local ok, err = arbor.fs.copy(src, dest)
  if not ok then return U.fail(lines, "copy " .. src .. " -> " .. dest .. ": " .. tostring(err)) end
  add("copied OK")
  return U.finish(lines)
end

function M.delete_file(params, ctx)
  local text = params.paths or ""
  local lines, add = U.new_log("delete_file")
  local any_failure = false
  for line in text:gmatch("[^\n\r]+") do
    local t = line:gsub("^%s+", ""):gsub("%s+$", "")
    if t ~= "" then
      local p = U.abs_path(t, ctx)
      if arbor.fs.exists(p) then
        local ok, err = arbor.fs.delete(p)
        if ok then add("rm    = " .. p)
        else add("err   = " .. p .. " (" .. tostring(err) .. ")"); any_failure = true end
      else
        add("skip  = " .. p .. " (not found)")
      end
    end
  end
  return U.finish(lines, any_failure and 1 or 0)
end

-- tomcat_clean_old: scans `target_dir` for the produced .war, then attempts
-- to delete the matching exploded directory + WAR file under `webapps/`.
-- On first deploy (no .war yet in `target_dir`) the step succeeds silently
-- — there is by definition nothing to clean. Resolves the war name at
-- runtime so the pipeline can be built before Build stage produces it.
function M.tomcat_clean_old(params, ctx)
  local target_dir = U.abs_path(params.target_dir or "", ctx)
  local webapps    = U.abs_path(params.webapps    or "", ctx)
  local lines, add = U.new_log("tomcat_clean_old")
  U.log_entry(add, "target_dir", target_dir)
  U.log_entry(add, "webapps   ", webapps)
  local hits = arbor.fs.glob{ root = target_dir, pattern = "*.war", max_depth = 0 } or {}
  if #hits == 0 then
    add("no .war in " .. target_dir .. " — nothing to clean (first deploy?)")
    return U.finish(lines)
  end
  local war_path = hits[1]
  local war_name = war_path:match("[/\\]([^/\\]+)$") or "app.war"
  local base     = war_name:gsub("%.war$", "")
  local old_war  = arbor.fs.join(webapps, war_name)
  local exploded = arbor.fs.join(webapps, base)
  local any_failure = false
  for _, p in ipairs({ old_war, exploded }) do
    if arbor.fs.exists(p) then
      local ok, err = arbor.fs.delete(p)
      if ok then add("rm    = " .. p)
      else add("err   = " .. p .. " (" .. tostring(err) .. ")"); any_failure = true end
    else
      add("skip  = " .. p .. " (not found)")
    end
  end
  return U.finish(lines, any_failure and 1 or 0)
end

-- tomcat_deploy_war: scans `target_dir` for the produced .war and copies it
-- to the Tomcat `webapps/`. Same runtime-resolution rationale as
-- tomcat_clean_old — Build stage produces the artifact before this op runs.
function M.tomcat_deploy_war(params, ctx)
  local target_dir = U.abs_path(params.target_dir or "", ctx)
  local webapps    = U.abs_path(params.webapps    or "", ctx)
  local lines, add = U.new_log("tomcat_deploy_war")
  U.log_entry(add, "target_dir", target_dir)
  U.log_entry(add, "webapps   ", webapps)
  local hits = arbor.fs.glob{ root = target_dir, pattern = "*.war", max_depth = 0 } or {}
  if #hits == 0 then
    return U.fail(lines, "no .war found in " .. target_dir)
  end
  local war_path = hits[1]
  local war_name = war_path:match("[/\\]([^/\\]+)$") or "app.war"
  local dest_war = arbor.fs.join(webapps, war_name)
  add("war  = " .. war_path)
  add("dest = " .. dest_war)
  local ok, err = arbor.fs.copy(war_path, webapps)
  if not ok then return U.fail(lines, "copy failed: " .. tostring(err)) end
  if not arbor.fs.exists(dest_war) then
    return U.fail(lines, "post-copy verify: " .. dest_war .. " missing")
  end
  add("deployed OK")
  return U.finish(lines)
end

function M.register()
  arbor.pipeline.register_op("copy_file",         M.copy_file)
  arbor.pipeline.register_op("delete_file",       M.delete_file)
  arbor.pipeline.register_op("tomcat_clean_old",  M.tomcat_clean_old)
  arbor.pipeline.register_op("tomcat_deploy_war", M.tomcat_deploy_war)
end

return M
