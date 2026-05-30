-- editorconfig/parser.lua — tiny, lossy-ish `.editorconfig` round-tripper.
--
-- Comments above a section header travel with the section (so a re-emit
-- keeps the human-written context). Keys are emitted alphabetically so
-- diffs after a structured edit don't churn on reordering.

local M = {}

-- ── Read ───────────────────────────────────────────────────────────────────

local function trim(line)
  return line:match("^%s*(.-)%s*$") or line
end

local function is_comment(line) return line:match("^[#;]") ~= nil end
local function is_section(line) return line:match("^%[.*%]$") ~= nil end

-- `text` is the raw file contents (or an empty string for a fresh file).
-- Returns:
--   { root = bool,
--     sections = { { pattern = string, keys = {k=v}, comments = {string} }, ... } }
function M.parse(text)
  local out = { root = false, sections = {} }
  if not text or text == "" then return out end

  local current = nil
  local floating_comments = {}

  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local trimmed = trim(line)
    if trimmed == "" then
      -- ignore blank lines
    elseif is_comment(trimmed) then
      floating_comments[#floating_comments + 1] = trimmed
    elseif is_section(trimmed) then
      current = {
        pattern  = trimmed:match("^%[(.*)%]$"),
        keys     = {},
        comments = floating_comments,
      }
      floating_comments = {}
      out.sections[#out.sections + 1] = current
    else
      local k, v = trimmed:match("^([%w_]+)%s*=%s*(.*)$")
      if k then
        k = k:lower()
        v = trim(v)
        if current == nil then
          if k == "root" then out.root = (v:lower() == "true") end
        else
          current.keys[k] = v
        end
      end
    end
  end

  return out
end

-- ── Write ──────────────────────────────────────────────────────────────────

local function sorted_keys(t)
  local out = {}
  for k in pairs(t) do out[#out + 1] = k end
  table.sort(out)
  return out
end

local function emit_section(lines, section)
  if section.comments then
    for _, c in ipairs(section.comments) do lines[#lines + 1] = c end
  end
  lines[#lines + 1] = "[" .. section.pattern .. "]"
  for _, k in ipairs(sorted_keys(section.keys)) do
    lines[#lines + 1] = k .. " = " .. tostring(section.keys[k])
  end
  lines[#lines + 1] = ""
end

function M.serialise(cfg)
  local lines = {}
  if cfg.root then
    lines[#lines + 1] = "root = true"
    lines[#lines + 1] = ""
  end
  for _, section in ipairs(cfg.sections) do
    emit_section(lines, section)
  end
  return table.concat(lines, "\n")
end

-- ── Path helper ────────────────────────────────────────────────────────────

function M.path_in_active_repo()
  local repo = arbor.repo.current()
  if not repo then return nil end
  return arbor.fs.join(repo, ".editorconfig")
end

return M
