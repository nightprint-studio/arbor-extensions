-- parsers/maven_tree.lua — Parse `mvn -B dependency:tree -DoutputType=text`.
--
-- Each line strips the optional `[INFO] ` prefix; the remainder is either:
--   · the root coordinate (no indentation), or
--   · an indented child of the form `<prefix>+- <coord>` / `<prefix>\- <coord>`,
--     where `<prefix>` is a sequence of `|  ` (continuation) or `   ` (gap).
--
-- A coordinate looks like one of:
--   groupId:artifactId:packaging:version
--   groupId:artifactId:packaging:version:scope
--   groupId:artifactId:packaging:classifier:version:scope
--   groupId:artifactId:packaging:version:scope (omitted for duplicate)
--   groupId:artifactId:packaging:version:scope (omitted for conflict with X)
--
-- We capture as much detail as Maven gives and return a tree of plain Lua
-- tables. The deps-explorer module wraps each table in a TreeNode shape
-- compatible with the contribution model.

local M = {}

-- Strip surrounding ANSI colour codes (some Maven plugins inject them even
-- with -B). Cheap and good enough for the artifacts we care about.
local function strip_ansi(s)
  return (s:gsub("\27%[[%d;]*[A-Za-z]", ""))
end

-- Strip the `[INFO] `, `[WARNING] `, `[ERROR] ` prefixes. Returns nil if the
-- line is not part of the dependency:tree output.
local function strip_log_prefix(line)
  local body = line:match("^%[INFO%]%s?(.*)$")
  if body then return body end
  -- Other log levels never carry tree data.
  if line:match("^%[%w+%]") then return nil end
  return line
end

-- ASCII branch glyphs (3 chars: glyph-glyph-space). Unicode equivalents
-- below — Maven emits ASCII when -DoutputType=text is set, but some setups
-- still produce the Unicode tree (e.g. when a global ~/.mavenrc forces it).
local ASCII_BRANCHES = { "+- ", "\\- " }
-- Unicode glyphs (each is 3-byte UTF-8 → " " is one byte). Branch glyphs
-- are 7 bytes total: `├── ` and `└── `. Indent slot is 4 bytes:
-- `│   ` (3-byte vertical bar + 3 spaces) or `    ` (4 spaces).
local UNICODE_BRANCHES = { "\xe2\x94\x9c\xe2\x94\x80\xe2\x94\x80 ",  -- ├──
                          "\xe2\x94\x94\xe2\x94\x80\xe2\x94\x80 " } -- └──

local function find_branch(body)
  for _, g in ipairs(ASCII_BRANCHES) do
    local i = body:find(g, 1, true)
    if i then return i, #g, 3 end -- 3-char-wide indent slots in ASCII
  end
  for _, g in ipairs(UNICODE_BRANCHES) do
    local i = body:find(g, 1, true)
    if i then return i, #g, 4 end -- 4-byte-wide indent slots in Unicode
  end
  return nil
end

-- Compute (depth, payload) from a tree-formatted line.
-- depth = 0 for the root. Returns nil when the line isn't a tree row.
local function split_tree_line(body)
  local idx, glyph_len, slot_w = find_branch(body)
  if not idx then
    -- Root row: no branch glyph, just the coordinate.
    if body == "" or body:find("^%s*$") then return nil end
    if body:find("^[%-%=]+$") then return nil end
    -- Reject obvious non-coordinates: must contain at least 3 colon-separated
    -- segments to look like a Maven coord (g:a:type[:v[:scope]]).
    local _, colons = body:gsub(":", ":")
    if colons < 3 then return nil end
    return 0, body
  end

  local indent_len = idx - 1
  local depth      = math.floor(indent_len / slot_w) + 1
  local payload    = body:sub(idx + glyph_len)
  return depth, payload
end

-- Parse a coordinate string into its components. Handles the two layouts
-- (4/5 segments without classifier, 5/6 with) and the optional
-- `(omitted for …)` trailing note Maven adds in verbose mode.
local function parse_coord(coord)
  -- Detach `(omitted ...)` first so the segment count is stable.
  local omitted = coord:match("%((omitted[^%)]*)%)")
  local clean   = coord:gsub("%s*%(omitted[^%)]*%)", ""):gsub("%s+$", "")

  -- Split on ':' — but artifact ids never contain ':' so this is safe.
  local parts = {}
  for seg in clean:gmatch("([^:]+)") do parts[#parts+1] = seg end

  local group, artifact, packaging, classifier, version, scope
  if #parts == 4 then
    group, artifact, packaging, version = parts[1], parts[2], parts[3], parts[4]
  elseif #parts == 5 then
    group, artifact, packaging, version, scope = parts[1], parts[2], parts[3], parts[4], parts[5]
  elseif #parts >= 6 then
    group, artifact, packaging, classifier, version, scope = parts[1], parts[2], parts[3], parts[4], parts[5], parts[6]
  else
    return nil
  end

  return {
    group      = group,
    artifact   = artifact,
    packaging  = packaging,
    classifier = classifier,
    version    = version,
    scope      = scope,
    omitted    = omitted, -- e.g. "omitted for duplicate" / "omitted for conflict with 1.2.3"
  }
end

-- Walk parsed (depth, coord) sequence into a tree.
-- Stack-based reconstruction: each entry's parent is the most recent entry
-- with depth-1.
local function fold_tree(entries)
  if #entries == 0 then return nil end
  local stack = {}
  local root = nil
  for _, entry in ipairs(entries) do
    local node = {
      coord    = entry.coord,
      children = {},
    }
    if entry.depth == 0 then
      root = node
      stack[0] = node
    else
      local parent = stack[entry.depth - 1]
      if parent then
        parent.children[#parent.children + 1] = node
      end
      stack[entry.depth] = node
    end
  end
  return root
end

-- Scan output, isolate the tree section(s), parse and return a tree per
-- module. Multi-module reactor builds emit one section per module separated
-- by `------------------------< group:artifact >------------------------`.
-- For our use case (single module per analysis) we return the FIRST tree
-- found that has a recognisable root and at least one child OR matches the
-- expected coordinate prefix when provided.
function M.parse(output, expected_artifact)
  if not output or output == "" then return nil end

  -- Strip a UTF-8 BOM if present (Maven's outputFile sometimes leaves one
  -- when the JVM was started with -Dfile.encoding=UTF-8). The BOM at the
  -- root coordinate would prevent it from parsing as a colon-separated
  -- triple and the whole tree would silently collapse to nil.
  if output:sub(1, 3) == "\xef\xbb\xbf" then output = output:sub(4) end
  -- Normalise line endings: Maven on Windows writes CRLF and the line
  -- iterator below assumes a bare \n terminator. Without this, every
  -- non-empty line is skipped because the \r blocks `[^\r\n]*\n` matching.
  output = output:gsub("\r\n", "\n"):gsub("\r", "\n")

  local entries = {}
  local found_root = false
  for raw in (output .. "\n"):gmatch("([^\r\n]*)\n") do
    local line = strip_ansi(raw)
    local body = strip_log_prefix(line)
    if body and body ~= "" then
      local depth, payload = split_tree_line(body)
      if depth and payload then
        local coord = parse_coord(payload)
        if coord then
          if depth == 0 then
            -- New tree starts. If we already collected a tree, prefer
            -- continuing only if it doesn't match the expected artifact.
            if found_root and (not expected_artifact
              or entries[1].coord.artifact == expected_artifact) then
              break
            end
            entries     = { { depth = 0, coord = coord } }
            found_root  = true
          else
            entries[#entries + 1] = { depth = depth, coord = coord }
          end
        end
      end
    end
  end

  return fold_tree(entries)
end

return M
