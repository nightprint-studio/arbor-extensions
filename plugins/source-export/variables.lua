-- variables.lua — $VAR / ${VAR} placeholder expansion used by every step.
--
--   expand(str, vars)      → string   (safe: unresolved placeholders kept verbatim)
--   build_ctx(profile)     → table    (builtins + user variables merged, with
--                                       built-ins winning on collision)
--
-- Syntax:
--   $NAME               match alphanumeric + underscore greedily
--   ${NAME}             explicit brace form (for when NAME is followed by letters)
--   ${NAME:default}     brace form with fallback — default is used when NAME
--                       is unset OR empty. The default runs to the next `}`
--                       (plain text, not recursively expanded). Useful on
--                       `profile.branch_src`, optional args, URLs, etc.
--   $$                  literal '$' escape
--
-- Unresolved `$NAME` / `${NAME}` (no default) are returned as-is — keeps
-- commands readable when debugging and lets plugin authors decide how to
-- react (fail-fast with a custom Assert step, or ignore).

local M = {}

local function shell_path(p)
  -- Best-effort: no quoting is added here. Quoting happens at command-compose
  -- time in each op (`to_command`). This helper just normalizes separators on
  -- Windows so downstream shells do not choke on Unix-style paths.
  if arbor.meta.os() == "windows" then
    return (p or ""):gsub("/", "\\")
  end
  return p or ""
end

-- ── Built-in variables derived from repo + profile + run context ────────────

function M.build_ctx(profile, opts)
  opts = opts or {}

  local source_path = opts.source_path or arbor.repo.current() or ""
  local repo_name   = source_path:match("[/\\]([^/\\]+)[/\\]?$") or ""
  local branch_src  = (profile.branch_src and profile.branch_src ~= "")
                      and profile.branch_src
                      or (arbor.repo.branch() or "")
  local branch_dest = profile.branch_dest or ""
  -- Millisecond-ish timestamp to avoid colliding output folders when the
  -- same profile is re-run rapidly (plain os.time() gives second precision,
  -- which is not enough for back-to-back retries after a failure).
  local timestamp   = opts.timestamp
                     or (os.time() * 1000 + math.random(0, 999))

  -- Resolve OUTPUT_PATH:
  --   · standalone run: <global_output_folder>/<profile_safe>_<timestamp>
  --   · sequence  run: <opts.output_folder> verbatim (the runner already
  --                    builds a per-item unique path under the sequence's
  --                    own output_root, so adding another <safe>_<timestamp>
  --                    layer just inflates the path. On Windows the extra
  --                    nesting pushes the .git/objects/info/commit-graphs/…
  --                    files past MAX_PATH (260) and `git clone` fails with
  --                    "fatal: failed to unlink … Filename too long".)
  local gcfg = require("config.global")
  local sep  = arbor.meta.os() == "windows" and "\\" or "/"
  local output_path
  if opts.output_folder and opts.output_folder ~= "" then
    output_path = opts.output_folder
  else
    local base = gcfg.get_output_folder()
    local safe = (profile.name or profile.id):gsub("[^%w%-_.]+", "_")
    output_path = base .. sep .. safe .. "_" .. tostring(timestamp)
  end

  local commit_sha = ""
  -- Best-effort head sha — keep exceptions contained.
  pcall(function()
    if source_path ~= "" then
      local result = arbor.terminal and arbor.terminal.exec
        and arbor.terminal.exec({
          command = "git rev-parse HEAD",
          cwd     = source_path,
        })
      if result and result.exit_code == 0 and result.stdout then
        commit_sha = (result.stdout:match("^%s*(.-)%s*$") or "")
      end
    end
  end)

  local logical_run_id = opts.run_id
    or ("se_" .. tostring(timestamp) .. "_"
        .. string.format("%04x", math.random(0, 0xffff)))

  local builtins = {
    SOURCE_PATH = shell_path(source_path),
    OUTPUT_PATH = shell_path(output_path),
    BRANCH_SRC  = branch_src,
    BRANCH_DEST = branch_dest,
    PROFILE     = profile.name or "",
    RUN_ID      = logical_run_id,
    TIMESTAMP   = tostring(timestamp),
    COMMIT_SHA  = commit_sha,
    REPO_NAME   = repo_name,
  }

  -- User vars first, then overwrite with builtins so system names always win.
  local merged = {}
  for _, v in ipairs(profile.variables or {}) do
    if v.key and v.key ~= "" then merged[v.key] = v.value or "" end
  end
  for k, v in pairs(builtins) do merged[k] = v end

  return {
    vars       = merged,
    builtins   = builtins,
    source_path = source_path,
    output_path = output_path,
    run_id      = logical_run_id,
  }
end

-- ── Expansion ───────────────────────────────────────────────────────────────

local IDENT = "[%w_]"

--- Expand placeholders in `s` against the `vars` map.
--- @param  s    string  input
--- @param  vars table   { VAR = "value", ... }
--- @return string
function M.expand(s, vars)
  if type(s) ~= "string" or s == "" then return s or "" end
  vars = vars or {}

  local out, i, n = {}, 1, #s
  while i <= n do
    local c = s:sub(i, i)
    if c ~= "$" then
      out[#out+1] = c
      i = i + 1
    else
      local nextc = s:sub(i + 1, i + 1)
      if nextc == "$" then              -- $$  → literal $
        out[#out+1] = "$"
        i = i + 2
      elseif nextc == "{" then          -- ${NAME}, ${NAME:default}, or ${env:NAME[:default]}
        local close = s:find("}", i + 2, true)
        if close then
          local body = s:sub(i + 2, close - 1)
          local val, default
          if body:sub(1, 4) == "env:" then
            -- ${env:NAME} / ${env:NAME:default} — system env var lookup. We
            -- consume "env:" first so the inner "NAME[:default]" follows
            -- the same first-colon split rule as the regular form. Lets
            -- profiles reference user-level env (JAVA_HOME_11, GH_TOKEN, …)
            -- without baking host paths into the saved JSON.
            local rest  = body:sub(5)
            local colon = rest:find(":", 1, true)
            local name
            if colon then
              name    = rest:sub(1, colon - 1)
              default = rest:sub(colon + 1)
            else
              name    = rest
            end
            val = (name ~= "") and os.getenv(name) or nil
            if val == nil or val == "" then
              if default ~= nil then
                out[#out+1] = default
              else
                out[#out+1] = "${env:" .. name .. "}"
              end
            else
              out[#out+1] = tostring(val)
            end
          else
            -- Split on the FIRST colon so the default can itself contain `:`
            -- (common in URLs / Windows paths). No escape mechanism: default
            -- runs verbatim to the closing `}` (no nesting, no recursion —
            -- keep it simple; wrap in a profile variable if you need depth).
            local colon = body:find(":", 1, true)
            local name
            if colon then
              name    = body:sub(1, colon - 1)
              default = body:sub(colon + 1)
            else
              name    = body
            end
            val = vars[name]
            -- Fallback when unset OR empty — matches bash `${VAR:-default}`
            -- semantics. An empty variable almost always means "nothing
            -- meaningful", so the default should kick in.
            if val == nil or val == "" then
              if default ~= nil then
                out[#out+1] = default
              else
                out[#out+1] = "${" .. name .. "}"
              end
            else
              out[#out+1] = tostring(val)
            end
          end
          i = close + 1
        else
          out[#out+1] = "$"; i = i + 1      -- unmatched brace → leave as-is
        end
      else                               -- $NAME
        local j = i + 1
        while j <= n and s:sub(j, j):match(IDENT) do j = j + 1 end
        if j == i + 1 then
          out[#out+1] = "$"; i = i + 1      -- bare $ followed by non-ident
        else
          local name = s:sub(i + 1, j - 1)
          local val  = vars[name]
          out[#out+1] = (val ~= nil) and tostring(val) or ("$" .. name)
          i = j
        end
      end
    end
  end
  return table.concat(out)
end

-- ── Shell-quoting helpers ───────────────────────────────────────────────────
--
-- These are used by op.to_command builders to paste user-supplied paths /
-- patterns into shell commands safely. The quoting rules are:
--   • Windows cmd.exe: wrap in `"..."`, escape embedded `"` as `""`.
--   • POSIX sh: wrap in `'...'`, escape embedded `'` as `'\''`.
-- The helpers handle empty strings by returning a pair of quotes so callers
-- don't accidentally concatenate an unquoted token.

function M.quote(s)
  s = s or ""
  if arbor.meta.os() == "windows" then
    return '"' .. s:gsub('"', '""') .. '"'
  end
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- Expand + quote in one shot.
function M.exq(s, vars) return M.quote(M.expand(s, vars)) end

return M
