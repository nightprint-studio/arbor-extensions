-- parsers/gradle_deps.lua — Parse `gradle dependencies --configuration <cfg>`.
--
-- Layout:
--   ------------------------------------------------------------
--   Root project 'my-app'
--   ------------------------------------------------------------
--
--   runtimeClasspath - Runtime classpath of source set 'main'.
--   +--- org.springframework.boot:spring-boot-starter-web -> 2.5.0
--   |    +--- org.springframework.boot:spring-boot-starter:2.5.0
--   |    |    \--- org.springframework.boot:spring-boot:2.5.0
--   \--- com.example:my-lib:1.0.0
--
-- Branch glyphs: `+--- ` (non-last) and `\--- ` (last). Indent slot is 5
-- chars (`|    ` or `     `). Coordinate forms accepted:
--   group:name:version
--   group:name -> requested-version (force/conflict resolution applied)
--   group:name:requested -> resolved
--   project :path                          (project dependency, no version)
-- We capture the resolved version when present; otherwise the requested one.

local M = {}

local function strip_ansi(s) return (s:gsub("\27%[[%d;]*[A-Za-z]", "")) end

local function find_branch(line)
  for _, glyph in ipairs({ "+--- ", "\\--- " }) do
    local idx = line:find(glyph, 1, true)
    if idx then return idx, #glyph end
  end
  return nil
end

-- Parse the payload after the branch glyph. Returns nil for unrecognised.
local function parse_payload(payload)
  -- Project dep: `project :path[:something]`
  local proj = payload:match("^project (%S+)")
  if proj then
    return {
      group     = "(project)",
      artifact  = proj,
      version   = "",
      scope     = nil,
      omitted   = nil,
      requested = "",
    }
  end

  -- Strip omission markers like `(*)` (already shown), `(c)` (constraint).
  local omitted = payload:match("%((%*?c?)%)$")
  local clean = payload:gsub("%s*%([%*c]+%)%s*$", "")

  -- Forced/replaced: `g:a:reqVer -> resolvedVer` OR `g:a -> resolvedVer`.
  local pre, arrow = clean:match("^(.-)%s*%->%s*(%S+)$")
  if pre then
    -- pre can be `g:a` or `g:a:requested`.
    local g, a, req = pre:match("^([^:]+):([^:]+):(.+)$")
    if g and a then
      return {
        group = g, artifact = a, version = arrow,
        requested = req, omitted = omitted,
      }
    end
    g, a = pre:match("^([^:]+):([^:]+)$")
    if g and a then
      return {
        group = g, artifact = a, version = arrow,
        requested = "", omitted = omitted,
      }
    end
  end

  -- Plain `g:a:v`.
  local g, a, v = clean:match("^([^:]+):([^:]+):(%S+)$")
  if g and a and v then
    return { group = g, artifact = a, version = v, requested = "", omitted = omitted }
  end

  return nil
end

-- Extract one section from the output and parse it as an indented tree.
-- The section header looks like `<configuration> - <description>`. We stop
-- when the next section header is encountered or two blank lines arrive.
function M.parse(output, configuration)
  if not output or output == "" then return nil end
  -- CRLF → LF normalisation: gradle's stdout is captured via a shell
  -- redirect on Windows, which yields CRLF line endings; the iterator
  -- below assumes bare LF.
  output = output:gsub("\r\n", "\n"):gsub("\r", "\n")
  local cfg_marker = configuration or "runtimeClasspath"

  local lines = {}
  for raw in (output .. "\n"):gmatch("([^\r\n]*)\n") do
    lines[#lines + 1] = strip_ansi(raw)
  end

  -- Find header line matching the chosen configuration.
  local start_idx = nil
  for i, ln in ipairs(lines) do
    -- Match `<cfg> - …` (Gradle) or `<cfg>` alone (just in case).
    if ln == cfg_marker or ln:match("^" .. cfg_marker:gsub("[-]", "%%-") .. "%s+%-") then
      start_idx = i + 1
      break
    end
  end
  if not start_idx then return nil end

  local entries = {}
  for i = start_idx, #lines do
    local ln = lines[i]
    -- Stop on next section header (blank then word-with-` - `).
    if ln:match("^%S+%s%-%s.+$") and not ln:find("%->") then break end
    -- Skip `(omitted ...)` etc.
    local idx, glyph_len = find_branch(ln)
    if idx then
      local indent_len = idx - 1
      local depth = math.floor(indent_len / 5) + 1
      local payload = ln:sub(idx + glyph_len)
      local coord = parse_payload(payload)
      if coord then
        entries[#entries + 1] = { depth = depth, coord = coord }
      end
    end
  end

  if #entries == 0 then return nil end

  -- Synthesise a virtual root so the rest of the pipeline matches the
  -- maven/cargo layout (one root with N children). The visible name is the
  -- configuration so the user knows which classpath they're inspecting.
  local root = {
    coord = { group = "", artifact = cfg_marker, version = "", scope = "" },
    children = {},
  }
  local stack = { [0] = root }
  for _, entry in ipairs(entries) do
    local node = { coord = entry.coord, children = {} }
    local parent = stack[entry.depth - 1]
    if parent then parent.children[#parent.children + 1] = node end
    stack[entry.depth] = node
  end
  return root
end

return M
