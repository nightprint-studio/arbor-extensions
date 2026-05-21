-- Local pipeline content ops for source-export.
--
-- Same shape as the (removed) arbor.core.content module — kept as a
-- plugin-local helper because the standard library now stops at arbor.fs /
-- arbor.text. See arbor.core.assert and arbor.core.edit for op modules that
-- ARE still part of the SDK.
--
-- Every function follows the pipeline-op contract:
--   function(params, ctx) -> { exit_code, stdout, stderr? }
--
-- Ops
--   · replace_in_file   { path, find, replace, plain? }
--   · replace_on_glob   { glob, find, replace, plain? }      -- iterates ctx.cwd
--   · properties_edit   { path, entries }                    -- key=value upsert
--   · env_merge         { path, entries }                    -- key=value upsert
--   · template_render   { src, dest, __vars }                -- {{KEY}} substitution
--   · insert_at_anchor  { path, anchor, content, position? } -- before|after

local U = require("arbor.core._util")

local M = {}

function M.replace_in_file(params, ctx)
  local path    = U.abs_path(params.path or "", ctx)
  local find    = params.find    or ""
  local replace = params.replace or ""
  local plain   = params.plain and true or false
  local lines, add = U.new_log("replace_in_file")
  U.log_entry(add, "file ", path)
  U.log_entry(add, "mode ", plain and "plain (literal)" or "regex")
  U.log_entry(add, "find#", #find)
  U.log_entry(add, "repl#", #replace)
  if not arbor.fs.exists(path) then
    return U.fail(lines, "file not found: " .. path)
  end
  local src = arbor.fs.read(path) or ""
  local out, count = arbor.text.replace{ content = src, pattern = find, replacement = replace, plain = plain }
  U.log_entry(add, "hits ", count)
  if count == 0 then
    add("no changes")
  else
    arbor.fs.write(path, out)
    add("written")
  end
  return U.finish(lines)
end

function M.replace_on_glob(params, ctx)
  local glob    = params.glob    or ""
  local find    = params.find    or ""
  local replace = params.replace or ""
  local plain   = params.plain and true or false
  local root    = (ctx and ctx.cwd) or ""
  local lines, add = U.new_log("replace_on_glob")
  U.log_entry(add, "root ", root)
  U.log_entry(add, "glob ", glob)
  U.log_entry(add, "mode ", plain and "plain (literal)" or "regex")
  local basename = glob:match("[^/\\]+$") or glob
  if basename ~= glob then U.log_entry(add, "glob norm", basename) end
  local files = arbor.fs.glob{ root = root, pattern = basename } or {}
  U.log_entry(add, "matched", #files)
  local changed = 0
  for _, p in ipairs(files) do
    local src = arbor.fs.read(p) or ""
    local out, count = arbor.text.replace{ content = src, pattern = find, replacement = replace, plain = plain }
    if count > 0 then
      arbor.fs.write(p, out)
      add("edit   = " .. p .. " (" .. count .. " hits)")
      changed = changed + 1
    end
  end
  U.log_entry(add, "changed", changed)
  return U.finish(lines)
end

local function parse_kv(text)
  local out = {}
  for line in (text or ""):gmatch("[^\n\r]+") do
    local trimmed = line:gsub("^%s+", "")
    if trimmed ~= "" and trimmed:sub(1,1) ~= "#" then
      local k, v = trimmed:match("^([^=]+)=(.*)$")
      if k then
        k = k:gsub("^%s+", ""):gsub("%s+$", "")
        if k ~= "" then out[#out+1] = { k = k, v = v or "" } end
      end
    end
  end
  return out
end

local function kv_upsert(kind, params, ctx)
  local path    = U.abs_path(params.path or "", ctx)
  local entries = parse_kv(params.entries or "")
  local lines_log, add = U.new_log(kind)
  U.log_entry(add, "file    ", path)
  U.log_entry(add, "entries ", #entries)
  if #entries == 0 then
    return U.fail(lines_log, "no valid key=value entries to upsert")
  end
  local raw = ""
  if arbor.fs.exists(path) then raw = arbor.fs.read(path) or "" end
  local line_end = raw:find("\r\n", 1, true) and "\r\n" or "\n"
  local file_lines = {}
  for segment in (raw .. line_end):gmatch("([^\r\n]*)" .. line_end) do
    file_lines[#file_lines+1] = segment
  end
  if #file_lines > 0 and file_lines[#file_lines] == "" then
    table.remove(file_lines)
  end
  local function line_key_matches(line, key)
    local eq = line:find("=", 1, true)
    if not eq then return false end
    local kp = line:sub(1, eq - 1):gsub("^%s+", ""):gsub("%s+$", "")
    return kp == key
  end
  local touched = 0
  for _, e in ipairs(entries) do
    local found = false
    for i = 1, #file_lines do
      if line_key_matches(file_lines[i], e.k) then
        file_lines[i] = e.k .. "=" .. e.v
        found = true
        touched = touched + 1
        break
      end
    end
    if not found then
      file_lines[#file_lines+1] = e.k .. "=" .. e.v
      touched = touched + 1
    end
  end
  arbor.fs.write(path, table.concat(file_lines, line_end) .. line_end)
  U.log_entry(add, "touched ", touched)
  return U.finish(lines_log)
end

function M.properties_edit(params, ctx) return kv_upsert("properties_edit", params, ctx) end
function M.env_merge       (params, ctx) return kv_upsert("env_merge",       params, ctx) end

function M.template_render(params, ctx)
  local src  = U.abs_path(params.src  or "", ctx)
  local dest = U.abs_path(params.dest or "", ctx)
  local lines, add = U.new_log("template_render")
  U.log_entry(add, "src ", src)
  U.log_entry(add, "dest", dest)
  if not arbor.fs.exists(src) then
    return U.fail(lines, "template not found: " .. src)
  end
  local content = arbor.fs.read(src) or ""
  local subbed = 0
  local vars = params.__vars or {}
  for key, val in pairs(vars) do
    local placeholder = "{{" .. key .. "}}"
    local new_content, count = arbor.text.replace{ content = content, pattern = placeholder, replacement = tostring(val), plain = true }
    if count > 0 then
      content = new_content
      subbed = subbed + count
    end
  end
  U.log_entry(add, "vars available", (function() local n = 0; for _ in pairs(vars) do n = n + 1 end; return n end)())
  U.log_entry(add, "subbed        ", subbed)
  arbor.fs.write(dest, content)
  add("rendered -> " .. dest)
  return U.finish(lines)
end

function M.insert_at_anchor(params, ctx)
  local path    = U.abs_path(params.path or "", ctx)
  local anchor  = params.anchor  or ""
  local content = params.content or ""
  local pos     = params.position or "after"
  if pos ~= "after" and pos ~= "before" then pos = "after" end
  local lines_log, add = U.new_log("insert_at_anchor")
  U.log_entry(add, "file    ", path)
  U.log_entry(add, "position", pos)
  if not arbor.fs.exists(path) then
    return U.fail(lines_log, "file not found: " .. path)
  end
  local raw = arbor.fs.read(path) or ""
  local line_end = raw:find("\r\n", 1, true) and "\r\n" or "\n"
  local file_lines = {}
  for segment in (raw .. line_end):gmatch("([^\r\n]*)" .. line_end) do
    file_lines[#file_lines+1] = segment
  end
  if #file_lines > 0 and file_lines[#file_lines] == "" then
    table.remove(file_lines)
  end
  local block_lines = {}
  for segment in (content .. "\n"):gmatch("([^\n]*)\n") do
    block_lines[#block_lines+1] = segment
  end
  if #block_lines > 0 and block_lines[#block_lines] == "" then
    table.remove(block_lines)
  end
  local out = {}
  local done = false
  for _, ln in ipairs(file_lines) do
    if not done and arbor.text.contains{ content = ln, pattern = anchor, plain = false } then
      if pos == "before" then
        for _, b in ipairs(block_lines) do out[#out+1] = b end
        out[#out+1] = ln
      else
        out[#out+1] = ln
        for _, b in ipairs(block_lines) do out[#out+1] = b end
      end
      done = true
    else
      out[#out+1] = ln
    end
  end
  if not done then
    return U.fail(lines_log, "anchor pattern not found: " .. anchor)
  end
  arbor.fs.write(path, table.concat(out, line_end) .. line_end)
  U.log_entry(add, "inserted", #block_lines .. " line(s)")
  return U.finish(lines_log)
end

function M.register()
  arbor.pipeline.register_op("replace_in_file",  M.replace_in_file)
  arbor.pipeline.register_op("replace_on_glob",  M.replace_on_glob)
  arbor.pipeline.register_op("properties_edit",  M.properties_edit)
  arbor.pipeline.register_op("env_merge",        M.env_merge)
  arbor.pipeline.register_op("template_render",  M.template_render)
  arbor.pipeline.register_op("insert_at_anchor", M.insert_at_anchor)
end

return M
