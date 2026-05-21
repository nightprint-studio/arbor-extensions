-- Local pipeline file ops for source-export.
--
-- Same shape as the (removed) arbor.core.file module — kept as a plugin-local
-- helper because the standard library now stops at arbor.fs / arbor.text.
-- See arbor.core.assert and arbor.core.edit for similarly-shaped op modules
-- that ARE still part of the SDK.
--
-- Every function follows the standard pipeline-op contract:
--   function(params, ctx) -> { exit_code, stdout, stderr? }
--
-- Ops
--   · create_file   { path, content?, overwrite? }
--   · touch_file    { path }
--   · append_file   { path, content }
--   · prepend_file  { path, content }
--   · copy_file     { src, dest, overwrite? }
--   · move_file     { src, dest }
--   · delete_file   { paths }        -- newline-separated list; FAILS LOUD on lock
--   · delete_pattern{ patterns }     -- glob sweep; exit 0 regardless of hits

local U = require("arbor.core._util")

local M = {}

function M.create_file(params, ctx)
  local path      = U.abs_path(params.path or "", ctx)
  local content   = params.content or ""
  local overwrite = params.overwrite and true or false
  local lines, add = U.new_log("create_file")
  U.log_entry(add, "path     ", path)
  U.log_entry(add, "bytes    ", #content)
  U.log_entry(add, "overwrite", overwrite)
  if not overwrite and arbor.fs.exists(path) then
    add("skip (file already exists)")
    return U.finish(lines)
  end
  local ok, err = arbor.fs.write(path, content)
  if not ok then return U.fail(lines, "write " .. path .. ": " .. tostring(err)) end
  add("wrote OK")
  return U.finish(lines)
end

function M.touch_file(params, ctx)
  local path = U.abs_path(params.path or "", ctx)
  local lines, add = U.new_log("touch_file")
  U.log_entry(add, "path  ", path)
  local existed = arbor.fs.exists(path)
  local ok, err = arbor.fs.touch(path)
  if not ok then return U.fail(lines, "touch " .. path .. ": " .. tostring(err)) end
  add(existed and "updated mtime" or "created empty")
  return U.finish(lines)
end

function M.append_file(params, ctx)
  local path    = U.abs_path(params.path or "", ctx)
  local content = params.content or ""
  local lines, add = U.new_log("append_file")
  U.log_entry(add, "path  ", path)
  U.log_entry(add, "bytes ", #content)
  local ok, err = arbor.fs.append(path, content)
  if not ok then return U.fail(lines, "append " .. path .. ": " .. tostring(err)) end
  add("appended OK")
  return U.finish(lines)
end

function M.prepend_file(params, ctx)
  local path    = U.abs_path(params.path or "", ctx)
  local content = params.content or ""
  local lines, add = U.new_log("prepend_file")
  U.log_entry(add, "path  ", path)
  U.log_entry(add, "bytes ", #content)
  local existing = arbor.fs.exists(path) and (arbor.fs.read(path) or "") or ""
  local ok, err = arbor.fs.write(path, content .. existing)
  if not ok then return U.fail(lines, "write " .. path .. ": " .. tostring(err)) end
  add("prepended OK")
  return U.finish(lines)
end

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
  -- When dest is an existing directory, the underlying arbor.fs.copy puts
  -- the source INSIDE it (same semantics as `cp`). The overwrite check
  -- below therefore targets the resolved final path.
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

function M.move_file(params, ctx)
  local src  = U.abs_path(params.src  or "", ctx)
  local dest = U.abs_path(params.dest or "", ctx)
  local lines, add = U.new_log("move_file")
  U.log_entry(add, "src ", src)
  U.log_entry(add, "dest", dest)
  if not arbor.fs.exists(src) then
    return U.fail(lines, "source not found: " .. src)
  end
  local ok, err = arbor.fs.move{ src = src, dest = dest, overwrite = true }
  if not ok then return U.fail(lines, "move " .. src .. " -> " .. dest .. ": " .. tostring(err)) end
  add("moved OK")
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

function M.delete_pattern(params, ctx)
  local text = params.patterns or ""
  local root = (ctx and ctx.cwd) or ""
  local lines, add = U.new_log("delete_pattern")
  U.log_entry(add, "root     ", root)
  local total = 0
  for pat in text:gmatch("[^\n\r]+") do
    pat = pat:gsub("^%s+", ""):gsub("%s+$", "")
    if pat ~= "" then
      -- Reduce `**/*.tmp` -> `*.tmp`; recursion is implicit in arbor.fs.glob.
      local basename = pat:match("[^/\\]+$") or pat
      U.log_entry(add, "pattern  ", pat .. "  -> basename " .. basename)
      local hits = arbor.fs.glob{ root = root, pattern = basename } or {}
      for _, p in ipairs(hits) do
        add("rm       = " .. p)
        arbor.fs.delete(p)
        total = total + 1
      end
    end
  end
  U.log_entry(add, "removed  ", total)
  return U.finish(lines)
end

function M.register()
  arbor.pipeline.register_op("create_file",    M.create_file)
  arbor.pipeline.register_op("touch_file",     M.touch_file)
  arbor.pipeline.register_op("append_file",    M.append_file)
  arbor.pipeline.register_op("prepend_file",   M.prepend_file)
  arbor.pipeline.register_op("copy_file",      M.copy_file)
  arbor.pipeline.register_op("move_file",      M.move_file)
  arbor.pipeline.register_op("delete_file",    M.delete_file)
  arbor.pipeline.register_op("delete_pattern", M.delete_pattern)
end

return M
