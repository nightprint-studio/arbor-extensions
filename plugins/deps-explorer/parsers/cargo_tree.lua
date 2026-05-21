-- parsers/cargo_tree.lua — Parse `cargo tree --charset ascii --color never`.
--
-- Output format (ASCII):
--   my-crate v0.1.0 (/path)
--   |-- serde v1.0.140
--   |   |-- serde_derive v1.0.140 (proc-macro)
--   |   |   |-- proc-macro2 v1.0.43
--   |   |   `-- quote v1.0.21
--   |   `-- syn v1.0.99 (*)
--   `-- tokio v1.20.1
--
-- Branch glyphs: `|-- ` (non-last), `\`-- ` (last). Indent slots: `|   ` or
-- `    ` (4 chars). Trailing notes captured: `(*)`, `(proc-macro)`,
-- `(/path)` (path dep), `(http://…)` (alt registry).
--
-- We compute depth from the leading indent and split the payload into
-- name, version, source-note. Cargo doesn't publish scope on its tree —
-- dev/build dependencies need `-e all`. For v1 we keep it simple.

local M = {}

local function strip_ansi(s) return (s:gsub("\27%[[%d;]*[A-Za-z]", "")) end

-- Each branch glyph is one of:
--   "|-- "  non-last child (ASCII pipe)
--   "`-- "  last child
--   "+-- "  some shells emit + for non-last
local function find_branch(line)
  for _, glyph in ipairs({ "|-- ", "`-- ", "+-- " }) do
    local idx = line:find(glyph, 1, true)
    if idx then return idx, #glyph end
  end
  return nil
end

local function parse_payload(payload)
  -- Format: `name vX.Y.Z [extras...]`. The extras start with `(` and may be
  -- `(*)` (duplicate), `(proc-macro)`, `(/abs/path)`, `(http://…)`.
  local name, ver_with_rest = payload:match("^(%S+)%s+(.+)$")
  if not name then return nil end
  local version, rest = ver_with_rest:match("^v(%S+)%s*(.*)$")
  if not version then return nil end
  -- Strip notes; the first one we care about is `(*)` → duplicate.
  local duplicate = false
  local source    = ""
  for note in rest:gmatch("%((.-)%)") do
    if note == "*" then duplicate = true
    elseif source == "" then source = note end
  end
  return {
    artifact   = name,
    group      = "",       -- crates.io has no group/namespace
    version    = version,
    source     = source,
    duplicate  = duplicate,
    scope      = "normal", -- cargo tree's default scope is "normal"
  }
end

-- Fold a flat (depth, coord) sequence into a tree using stack-based
-- reconstruction. The first depth-0 entry is the root; subsequent entries
-- attach to the most recent ancestor at depth-1.
local function fold_one(entries)
  if #entries == 0 then return nil end
  local stack = {}
  local root  = nil
  for _, entry in ipairs(entries) do
    local node = { coord = entry.coord, children = {} }
    if entry.depth == 0 then
      root = node
      stack[0] = node
    else
      local parent = stack[entry.depth - 1]
      if parent then parent.children[#parent.children + 1] = node end
      stack[entry.depth] = node
    end
  end
  return root
end

-- Returns an ARRAY of trees. With `cargo tree --workspace`, cargo emits one
-- tree per member separated by blank lines, each starting with a depth-0
-- coordinate. Non-workspace runs return a single-element array — the
-- caller can branch on `#trees == 1` to keep the simple case simple.
function M.parse(output)
  if not output or output == "" then return nil end
  -- Normalise CRLF → LF so the line iterator below doesn't drop every
  -- non-empty line on Windows (cargo's stdout is redirected via shell, which
  -- inherits the platform's default line terminator).
  output = output:gsub("\r\n", "\n"):gsub("\r", "\n")
  local trees = {}
  local current_entries = nil

  local function flush()
    if current_entries and #current_entries > 0 then
      local tree = fold_one(current_entries)
      if tree then trees[#trees + 1] = tree end
    end
    current_entries = nil
  end

  for raw in (output .. "\n"):gmatch("([^\r\n]*)\n") do
    local line = strip_ansi(raw)
    -- Cargo prefixes some metadata lines with `Compiling`/`Finished`/`error`
    -- — those don't have branch glyphs nor a leading `name v` token, so the
    -- depth computation below filters them naturally. We still bail on lines
    -- starting with a known prefix to keep the parser predictable.
    if line == "" then
      -- Blank line ends the current tree; --workspace separates members
      -- with blanks, so this is our cut point.
      flush()
    elseif not line:match("^(Compiling|Finished|error|warning)") then
      local idx, glyph_len = find_branch(line)
      if not idx then
        -- Root row of a (possibly new) tree.
        local payload = parse_payload(line)
        if payload then
          flush() -- close any previous tree first
          current_entries = { { depth = 0, coord = payload } }
        end
      else
        if not current_entries then current_entries = {} end
        local indent_len = idx - 1
        -- 4-char indent slots; depth 1 means 0 indent + glyph.
        local depth = math.floor(indent_len / 4) + 1
        local payload_str = line:sub(idx + glyph_len)
        local payload = parse_payload(payload_str)
        if payload then
          current_entries[#current_entries + 1] = { depth = depth, coord = payload }
        end
      end
    end
  end
  flush()

  if #trees == 0 then return nil end
  return trees
end

return M
