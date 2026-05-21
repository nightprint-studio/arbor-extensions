-- to_command.lua — per-op compilers from step params to shell commands.
--
-- Phase 2 implements the subset of operations that covers the "export source
-- to customer repo" workflow (the primary driver of this plugin):
--
--   · shell_command           · log_message              · notify_toast
--   · delete_pattern          · delete_file              · copy_file
--   · move_file               · create_file              · touch_file
--   · append_file             · prepend_file
--   · replace_in_file         · replace_on_glob
--   · git_init · git_clone · git_commit · git_tag · git_push
--   · git_checkout · git_cherry_pick · git_merge · git_submodule_update
--   · m2_offline_ju
--   · assert_file_exists · assert_cmd_exit_zero · assert_env_set
--   · assert_branch_clean
--
-- Every other op declared in `operations.lua` returns `nil, "not implemented"`
-- and the profile compiler refuses to start a run that contains one, reporting
-- exactly which step(s) need an implementation. Phase 3 will fill the rest
-- (JSON/YAML/TOML/XML edit, template_render, compliance asserts, …).
--
-- Every compiler returns `command, cwd_override` where:
--   · `command`        is the shell one-liner (sh / cmd / powershell)
--   · `cwd_override`   overrides the default cwd (= $SOURCE_PATH) when set

local vars = require("variables")
local gcfg = require("config.global")

local M = {}

local IS_WIN = arbor.meta.os() == "windows"

local function q(s) return vars.quote(s or "") end
local function ex(s, ctx) return vars.expand(s or "", ctx.vars) end
local function exq(s, ctx) return q(ex(s, ctx)) end

-- ╔══════════════════════════════════════════════════════════════════════════╗
-- ║ WINDOWS QUOTING INVARIANT                                                 ║
-- ╠══════════════════════════════════════════════════════════════════════════╣
-- ║ Any PS script passed through `q(ps)` to `cmd /C powershell -Command "…"` ║
-- ║ MUST NOT contain a literal `"` character. Why:                            ║
-- ║                                                                           ║
-- ║   `q()` wraps in `"…"` and doubles internal `"` as `""`. The handoff      ║
-- ║   chain (cmd.exe → CreateProcess → powershell's argv parser) does NOT     ║
-- ║   reliably collapse `""` back to a literal `"` — depending on Windows     ║
-- ║   version and PS flavour, `""` can be seen as "close quote + open quote"  ║
-- ║   which breaks the -Command argument grouping and surfaces as             ║
-- ║   "Carattere di terminazione mancante nella stringa" / "TerminatorExpected". ║
-- ║                                                                           ║
-- ║ Rules to stay safe:                                                       ║
-- ║   · Wrap user paths / short strings with `psq()` (PS single-quoted).      ║
-- ║   · Wrap file content / multi-line / regex with `b64()` + `b64_decode()`. ║
-- ║   · Never write `"` inside a Lua string that will be passed to `q(ps)`.   ║
-- ║   · For newline splitting inside PS, use `[char]10` (NOT `"`n"`).         ║
-- ║                                                                           ║
-- ║ For direct cmd.exe `echo` prefixes (NOT wrapped by q) use `cmd_echo_val`  ║
-- ║ on user-supplied values to strip `"` — an embedded `"` there would flip   ║
-- ║ cmd.exe's quoting mode and a trailing `&&` would be absorbed as literal.  ║
-- ╚══════════════════════════════════════════════════════════════════════════╝
local function psq(s)
  s = s or ""
  return "'" .. s:gsub("'", "''") .. "'"
end

-- ── Base64 encode (UTF-8 bytes) ────────────────────────────────────────────
-- Lua 5.4 has no built-in base64; we keep the table inline. Output contains
-- only [A-Za-z0-9+/=] — none of them are special to cmd.exe or PowerShell,
-- so arbitrary strings round-trip safely through `cmd /C powershell -Command`.
local B64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function b64(s)
  s = s or ""
  local len = #s
  if len == 0 then return "" end
  local out = {}
  local i = 1
  while i <= len do
    local b1 = s:byte(i) or 0
    local b2 = s:byte(i + 1) or 0
    local b3 = s:byte(i + 2) or 0
    local n = b1 * 65536 + b2 * 256 + b3
    local c1 = math.floor(n / 262144) % 64
    local c2 = math.floor(n / 4096)   % 64
    local c3 = math.floor(n / 64)     % 64
    local c4 = n % 64
    out[#out+1] = B64_ALPHABET:sub(c1 + 1, c1 + 1)
    out[#out+1] = B64_ALPHABET:sub(c2 + 1, c2 + 1)
    out[#out+1] = (i + 1 <= len) and B64_ALPHABET:sub(c3 + 1, c3 + 1) or "="
    out[#out+1] = (i + 2 <= len) and B64_ALPHABET:sub(c4 + 1, c4 + 1) or "="
    i = i + 3
  end
  return table.concat(out)
end

-- PowerShell snippet that decodes a base64 literal back into a string variable.
-- Usage: `local ps_script = b64_decode(content, "$body") .. "; Set-Content …"`
-- `$varname` gets the decoded UTF-8 string (use `-Value $varname` on it).
local function b64_decode(content, varname)
  return varname .. " = [Text.Encoding]::UTF8.GetString("
       .. "[Convert]::FromBase64String('" .. b64(content) .. "'))"
end

-- ── Diagnostic logging helpers ─────────────────────────────────────────────
-- Every op prepends a few `[<op>] key = value` lines to stdout so the user can
-- see exactly what's about to happen before the actual command runs. Shared
-- first line is always `cwd = <absolute>` so relative paths can be traced back
-- to where they anchor.

-- PS static log: `Write-Output '[kind] msg'` (safe for short literal text).
local function ps_log(kind, msg)
  return "Write-Output '[" .. kind .. "] " .. msg:gsub("'", "''") .. "'"
end

-- PS dynamic log: `Write-Output ('[kind] label = ' + <ps_expr>)` — value comes
-- from a PowerShell expression that runs inside the script (e.g. a variable).
local function ps_logv(kind, label, ps_expr)
  return "Write-Output ('[" .. kind .. "] " .. label .. " = ' + (" .. ps_expr .. "))"
end

-- PS header snippet: emits `cwd = <current location>` which is always useful.
local function ps_header(kind)
  return ps_logv(kind, "cwd", "(Get-Location).Path")
end

-- POSIX echo: `echo '[kind] msg'` safe for short literal text.
local function sh_log(kind, msg)
  return "echo '[" .. kind .. "] " .. msg:gsub("'", "'\\''") .. "'"
end

-- PowerShell 5.1 gotcha: `Set-Content -Encoding UTF8` writes files WITH a
-- 3-byte BOM (`EF BB BF`). Many parsers (serde_json, serde_yaml, the Rust
-- `toml` crate) reject BOMs — the file becomes unreadable by subsequent
-- LuaOp steps like json_edit/yaml_edit/toml_edit. Use
-- `[System.IO.File]::WriteAllText(path, content, utf8NoBom)` via this helper
-- instead. Both path_expr and content_expr are PS expressions (e.g. `$body`).
local function ps_write_utf8_no_bom(path_expr, content_expr)
  return "[System.IO.File]::WriteAllText(" .. path_expr .. ", "
      .. content_expr .. ", (New-Object System.Text.UTF8Encoding $false))"
end

-- Append variant. Reads existing content (if any), concatenates, and writes
-- back as a whole — PS 5.1 has no built-in "append UTF-8 without BOM" API
-- that's reliable across versions.
local function ps_append_utf8_no_bom(path_expr, content_expr)
  return "$__existing = if (Test-Path -LiteralPath " .. path_expr .. ") { "
      ..   "[System.IO.File]::ReadAllText(" .. path_expr .. ") "
      .. "} else { '' }; "
      .. ps_write_utf8_no_bom(path_expr, "$__existing + " .. content_expr)
end

local function chain(lines)
  -- Fail-fast chain: on POSIX `&&`, on Windows `&&` is also supported by
  -- modern cmd.exe (Vista+). Keep it as one token per line so the runtime
  -- can show the full command in a single step output panel.
  return table.concat(lines, " && ")
end

local function dirname_unix(p)
  return (p or ""):match("^(.*)/[^/]*$") or "."
end

local function resolve_cwd(step_cwd, ctx)
  -- Default cwd is the OUTPUT folder (where the auto-clone landed). This
  -- means per-step transformations (delete, replace, …) operate on the
  -- working copy, never on the source repository. Set an explicit cwd on
  -- the step (or use $SOURCE_PATH in a path param) when you need to reach
  -- back into the original source.
  local c = ex(step_cwd or "", ctx)
  if c ~= "" then return c end
  return ctx.output_path or ctx.source_path or ""
end

-- ────────────────────────────────────────────────────────────────────────────
-- EXECUTION
-- ────────────────────────────────────────────────────────────────────────────

function M.shell_command(step, ctx)
  local cmd = ex(step.params.command or "", ctx)
  if cmd == "" then return nil, "shell_command: 'command' is empty" end
  local cwd = resolve_cwd(step.params.cwd, ctx)
  -- Prefix with a single-line announcement so the user sees the actual
  -- command that will run (after variable expansion) and where.
  local prefix
  if IS_WIN then
    prefix = "echo [shell_command] at \"" .. cwd .. "\"" .. " && "
  else
    prefix = sh_log("shell_command", "at " .. cwd) .. " && "
  end
  return prefix .. cmd, cwd
end

-- ────────────────────────────────────────────────────────────────────────────
-- FLOW: log / notify (surface via stdout → captured as DEBUG log events)
-- ────────────────────────────────────────────────────────────────────────────

function M.log_message(step, ctx)
  local level = (step.params.level or "info"):upper()
  local msg   = ex(step.params.message or "", ctx)
  return "echo [" .. level .. "] " .. q(msg)
end

function M.notify_toast(step, ctx)
  local title = ex(step.params.title   or "", ctx)
  local msg   = ex(step.params.message or "", ctx)
  return "echo [NOTIFY] " .. q(title .. (msg ~= "" and (" — " .. msg) or ""))
end

-- ────────────────────────────────────────────────────────────────────────────
-- FILE operations
-- ────────────────────────────────────────────────────────────────────────────

function M.delete_pattern(step, ctx)
  local text = ex(step.params.patterns or "", ctx)
  local patterns = {}
  for line in text:gmatch("[^\n\r]+") do
    local t = line:gsub("^%s+", ""):gsub("%s+$", "")
    if t ~= "" then patterns[#patterns+1] = t end
  end
  if #patterns == 0 then return nil, "delete_pattern: no patterns provided" end

  local cwd = ctx.output_path or ctx.source_path or "."
  if IS_WIN then
    -- PowerShell gotcha: `Get-ChildItem -Include` matches BASENAMES, not paths.
    -- So `-Include '**/*.tmp'` matches nothing (no file basename contains `/`).
    -- Recursion is already handled by `-Recurse`, so for the common shell-glob
    -- user input we reduce the pattern to its leaf:
    --   **/*.tmp     → *.tmp       (recursion handled by -Recurse)
    --   src/**/*.tmp → *.tmp       (directory scoping lost — use a step `cwd`
    --                               to narrow, or split into multiple steps)
    --   *.tmp        → *.tmp       (unchanged)
    --   file.ext     → file.ext    (unchanged)
    local function basename_glob(p) return p:match("[^/\\]+$") or p end
    local includes, normalised = {}, {}
    for _, p in ipairs(patterns) do
      local bn = basename_glob(p)
      includes[#includes+1]  = psq(bn)
      normalised[#normalised+1] = bn
    end
    local ps = ps_header("delete_pattern") .. "; "
            .. ps_log("delete_pattern", "patterns  : " .. table.concat(patterns,  ", ")) .. "; "
            .. ps_log("delete_pattern", "normalised: " .. table.concat(normalised, ", ")) .. "; "
            .. "$root = " .. psq(cwd) .. "; "
            .. ps_logv("delete_pattern", "scan root", "$root") .. "; "
            .. "$matches = @(Get-ChildItem -Path $root -Recurse -Force -Include "
            .. table.concat(includes, ",") .. "); "
            .. ps_logv("delete_pattern", "matched", "$matches.Count") .. "; "
            .. "foreach ($m in $matches) { "
            ..   "Write-Output ('[delete_pattern] rm   = ' + $m.FullName); "
            ..   "Remove-Item -LiteralPath $m.FullName -Recurse -Force "
            .. "}; "
            .. ps_log("delete_pattern", "done")
    return "powershell -NoProfile -Command " .. q(ps), cwd
  else
    -- bash + shopt globstar enables `**` recursive globs.
    local parts = { sh_log("delete_pattern", "cwd=" .. cwd .. " patterns=" .. table.concat(patterns, ",")) }
    for _, p in ipairs(patterns) do
      parts[#parts+1] = "bash -c " .. q("shopt -s globstar nullglob; for f in " .. p .. "; do echo \"[delete_pattern] rm   = $f\"; rm -rf \"$f\"; done")
    end
    return chain(parts), cwd
  end
end

function M.delete_file(step, ctx)
  local text = ex(step.params.paths or "", ctx)
  local paths = {}
  for line in text:gmatch("[^\n\r]+") do
    local t = line:gsub("^%s+", ""):gsub("%s+$", "")
    if t ~= "" then paths[#paths+1] = t end
  end
  if #paths == 0 then return nil, "delete_file: no paths provided" end

  if IS_WIN then
    -- Build a single PS script that walks the list — far fewer process spawns
    -- than one `powershell -Command` per path, and we can log per-item hits /
    -- misses from one context.
    local parts = { ps_header("delete_file") }
    for _, p in ipairs(paths) do
      local t = psq(p)
      parts[#parts+1] = "$t = " .. t .. "; "
                     .. "if (Test-Path -LiteralPath $t) { "
                     ..   ps_logv("delete_file", "rm     ", "$t") .. "; "
                     ..   "Remove-Item -LiteralPath $t -Recurse -Force "
                     .. "} else { "
                     ..   ps_logv("delete_file", "skip NX", "$t") .. " "
                     .. "}"
    end
    return "powershell -NoProfile -Command " .. q(table.concat(parts, "; "))
  else
    local cmds = { sh_log("delete_file", "paths=" .. table.concat(paths, ",")) }
    for _, p in ipairs(paths) do
      cmds[#cmds+1] = "([ -e " .. q(p) .. " ] && (echo '[delete_file] rm    = " .. p .. "'; rm -rf " .. q(p) .. ")) || echo '[delete_file] skip  = " .. p .. "'"
    end
    return chain(cmds)
  end
end

function M.copy_file(step, ctx)
  local src  = ex(step.params.src  or "", ctx)
  local dest = ex(step.params.dest or "", ctx)
  if src == "" or dest == "" then
    return nil, "copy_file: 'src' and 'dest' are required"
  end
  local overwrite = step.params.overwrite and true or false
  if IS_WIN then
    local ps = ps_header("copy_file") .. "; "
            .. ps_log("copy_file", "src       = " .. src) .. "; "
            .. ps_log("copy_file", "dest      = " .. dest) .. "; "
            .. ps_log("copy_file", "overwrite = " .. tostring(overwrite)) .. "; "
            .. "if (-not (Test-Path -LiteralPath " .. psq(src) .. ")) { "
            ..   "Write-Error '[copy_file] source missing: " .. src:gsub("'", "''") .. "'; exit 1 "
            .. "}; "
            .. "Copy-Item -LiteralPath " .. psq(src) .. " -Destination " .. psq(dest)
            .. " -Recurse" .. (overwrite and " -Force" or "") .. "; "
            .. "if (Test-Path -LiteralPath " .. psq(dest) .. ") { "
            ..   "$item = Get-Item -LiteralPath " .. psq(dest) .. "; "
            ..   "if ($item.PSIsContainer) { "
            ..     "$n = (Get-ChildItem -Recurse -Force -LiteralPath $item.FullName | Measure-Object).Count; "
            ..     ps_logv("copy_file", "copied dir", "'with ' + $n + ' entries'") .. " "
            ..   "} else { "
            ..     ps_logv("copy_file", "copied    ", "$item.Length.ToString() + ' bytes'") .. " "
            ..   "} "
            .. "} else { "
            ..   "Write-Error '[copy_file] post-copy check FAILED: dest not found'; exit 1 "
            .. "}"
    return "powershell -NoProfile -Command " .. q(ps)
  else
    local flag = overwrite and "-af" or "-an"
    return sh_log("copy_file", "cp " .. flag .. " " .. src .. " → " .. dest) .. " && "
        .. "cp " .. flag .. " " .. q(src) .. " " .. q(dest)
  end
end

function M.move_file(step, ctx)
  local src  = ex(step.params.src  or "", ctx)
  local dest = ex(step.params.dest or "", ctx)
  if src == "" or dest == "" then
    return nil, "move_file: 'src' and 'dest' are required"
  end
  if IS_WIN then
    local ps = ps_header("move_file") .. "; "
            .. ps_log("move_file", "src  = " .. src) .. "; "
            .. ps_log("move_file", "dest = " .. dest) .. "; "
            .. "if (-not (Test-Path -LiteralPath " .. psq(src) .. ")) { "
            ..   "Write-Error '[move_file] source missing: " .. src:gsub("'", "''") .. "'; exit 1 "
            .. "}; "
            .. "Move-Item -LiteralPath " .. psq(src) .. " -Destination " .. psq(dest) .. " -Force; "
            .. ps_log("move_file", "done")
    return "powershell -NoProfile -Command " .. q(ps)
  else
    return sh_log("move_file", "mv " .. src .. " → " .. dest) .. " && "
        .. "mv " .. q(src) .. " " .. q(dest)
  end
end

function M.create_file(step, ctx)
  local path    = ex(step.params.path or "", ctx)
  local content = ex(step.params.content or "", ctx)
  if path == "" then return nil, "create_file: 'path' is required" end

  if IS_WIN then
    -- Multi-line content + special characters trip up the cmd.exe → PS
    -- handoff, so we ship the body as base64 and let PowerShell decode it
    -- after arrival. The surrounding command string stays ASCII-safe.
    -- Verbose logging: print cwd, input path, resolved absolute path and the
    -- decoded body length BEFORE writing — this way if the step reports
    -- success but the file doesn't appear, the log shows where it was
    -- actually written (relative paths anchor to the step cwd, not to
    -- $OUTPUT_PATH by default).
    local ps = b64_decode(content, "$body") .. "; "
            .. "$target = " .. psq(path) .. "; "
            .. "$cwd = (Get-Location).Path; "
            .. "$full = if ([System.IO.Path]::IsPathRooted($target)) { $target } "
            .. "else { [System.IO.Path]::GetFullPath((Join-Path $cwd $target)) }; "
            .. "Write-Output ('[create_file] cwd      = ' + $cwd); "
            .. "Write-Output ('[create_file] path     = ' + $target); "
            .. "Write-Output ('[create_file] absolute = ' + $full); "
            .. "Write-Output ('[create_file] bytes    = ' + $body.Length); "
            .. "$dir = Split-Path -Parent $full; "
            .. "if ($dir -and -not (Test-Path -LiteralPath $dir)) { "
            ..   "Write-Output ('[create_file] mkdir    = ' + $dir); "
            ..   "New-Item -ItemType Directory -Force -Path $dir | Out-Null "
            .. "}; "
            .. ps_write_utf8_no_bom("$full", "$body") .. "; "
            .. "if (Test-Path -LiteralPath $full) { "
            ..   "$sz = (Get-Item -LiteralPath $full).Length; "
            ..   "Write-Output ('[create_file] wrote OK (' + $sz + ' bytes on disk)') "
            .. "} else { "
            ..   "Write-Error ('[create_file] post-write check FAILED: ' + $full + ' does not exist'); exit 1 "
            .. "}"
    return "powershell -NoProfile -Command " .. q(ps)
  else
    return "mkdir -p " .. q(dirname_unix(path)) .. " && "
        .. "printf %s " .. q(content) .. " > " .. q(path)
  end
end

function M.touch_file(step, ctx)
  local path = ex(step.params.path or "", ctx)
  if path == "" then return nil, "touch_file: 'path' is required" end
  if IS_WIN then
    local ps = ps_header("touch_file") .. "; "
            .. "$target = " .. psq(path) .. "; "
            .. ps_logv("touch_file", "path   ", "$target") .. "; "
            .. "if (Test-Path -LiteralPath $target) { "
            ..   ps_log("touch_file", "exists — updating LastWriteTime") .. "; "
            ..   "(Get-Item -LiteralPath $target).LastWriteTime = Get-Date "
            .. "} else { "
            ..   ps_log("touch_file", "creating new empty file") .. "; "
            ..   "$dir = Split-Path -Parent $target; "
            ..   "if ($dir -and -not (Test-Path -LiteralPath $dir)) { "
            ..     ps_logv("touch_file", "mkdir  ", "$dir") .. "; "
            ..     "New-Item -ItemType Directory -Force -Path $dir | Out-Null "
            ..   "}; "
            ..   "New-Item -ItemType File -Force -Path $target | Out-Null "
            .. "}"
    return "powershell -NoProfile -Command " .. q(ps)
  else
    return sh_log("touch_file", "path=" .. path) .. " && "
        .. "mkdir -p " .. q(dirname_unix(path)) .. " && touch " .. q(path)
  end
end

function M.append_file(step, ctx)
  local path    = ex(step.params.path    or "", ctx)
  local content = ex(step.params.content or "", ctx)
  if path == "" then return nil, "append_file: 'path' is required" end
  if IS_WIN then
    local ps = b64_decode(content, "$body") .. "; "
            .. "$target = " .. psq(path) .. "; "
            .. ps_header("append_file") .. "; "
            .. ps_logv("append_file", "path    ", "$target") .. "; "
            .. ps_logv("append_file", "bytes   ", "$body.Length") .. "; "
            .. "$before = if (Test-Path -LiteralPath $target) "
            ..   "{ (Get-Item -LiteralPath $target).Length } else { 0 }; "
            .. ps_logv("append_file", "size pre", "$before") .. "; "
            .. ps_append_utf8_no_bom("$target", "$body") .. "; "
            .. "$after = (Get-Item -LiteralPath $target).Length; "
            .. ps_logv("append_file", "size post", "$after")
    return "powershell -NoProfile -Command " .. q(ps)
  else
    return sh_log("append_file", "path=" .. path .. " bytes=" .. #content) .. " && "
        .. "printf %s " .. q(content) .. " >> " .. q(path)
  end
end

function M.prepend_file(step, ctx)
  local path    = ex(step.params.path    or "", ctx)
  local content = ex(step.params.content or "", ctx)
  if path == "" then return nil, "prepend_file: 'path' is required" end
  if IS_WIN then
    local ps = b64_decode(content, "$body") .. "; "
            .. "$target = " .. psq(path) .. "; "
            .. ps_header("prepend_file") .. "; "
            .. ps_logv("prepend_file", "path    ", "$target") .. "; "
            .. ps_logv("prepend_file", "bytes   ", "$body.Length") .. "; "
            .. "$old = if (Test-Path -LiteralPath $target) "
            ..   "{ [System.IO.File]::ReadAllText($target) } else { '' }; "
            .. ps_logv("prepend_file", "old len ", "$old.Length") .. "; "
            .. ps_write_utf8_no_bom("$target", "($body + $old)") .. "; "
            .. "$sz = (Get-Item -LiteralPath $target).Length; "
            .. ps_logv("prepend_file", "final sz", "$sz")
    return "powershell -NoProfile -Command " .. q(ps)
  else
    -- Write to a temp file then atomic rename.
    local tmp = q(path .. ".se.tmp")
    return sh_log("prepend_file", "path=" .. path .. " bytes=" .. #content) .. " && "
        .. "printf %s " .. q(content) .. " > " .. tmp
        .. " && cat " .. q(path) .. " >> " .. tmp
        .. " && mv " .. tmp .. " " .. q(path)
  end
end

-- ────────────────────────────────────────────────────────────────────────────
-- CONTENT: replace
-- ────────────────────────────────────────────────────────────────────────────

function M.replace_in_file(step, ctx)
  local path    = ex(step.params.path    or "", ctx)
  local find    = ex(step.params.find    or "", ctx)
  local replace = ex(step.params.replace or "", ctx)
  if path == "" or find == "" then
    return nil, "replace_in_file: 'path' and 'find' are required"
  end
  local plain = step.params.plain and true or false
  if IS_WIN then
    -- Base64 find/replace too: multi-line or quote-heavy patterns would
    -- otherwise break the cmd.exe → powershell handoff (same reason as
    -- create_file). The -replace / .Replace operators work fine with string
    -- variables, so we just materialise $find / $replace and reference them.
    local body = b64_decode(find,    "$find")    .. "; "
              .. b64_decode(replace, "$replace") .. "; "
              .. "$target = " .. psq(path) .. "; "
              .. ps_header("replace_in_file") .. "; "
              .. ps_logv("replace_in_file", "file    ", "$target") .. "; "
              .. ps_log("replace_in_file",  "mode    = " .. (plain and "plain (literal)" or "regex")) .. "; "
              .. ps_logv("replace_in_file", "find len", "$find.Length") .. "; "
              .. ps_logv("replace_in_file", "repl len", "$replace.Length") .. "; "
              .. "if (-not (Test-Path -LiteralPath $target)) { "
              ..   "Write-Error ('[replace_in_file] file missing: ' + $target); exit 1 "
              .. "}; "
              .. "$src = [System.IO.File]::ReadAllText($target); "
              .. "$dst = " .. (plain and "$src.Replace($find, $replace)"
                                      or "$src -replace $find, $replace") .. "; "
              .. "if ($src -eq $dst) { "
              ..   ps_log("replace_in_file", "no changes (find pattern not present)") .. " "
              .. "} else { "
              ..   ps_logv("replace_in_file", "delta   ", "'old=' + $src.Length + ' new=' + $dst.Length") .. "; "
              ..   ps_write_utf8_no_bom("$target", "$dst") .. "; "
              ..   ps_log("replace_in_file", "written") .. " "
              .. "}"
    return "powershell -NoProfile -Command " .. q(body)
  else
    -- Always use perl: sed's `-i` has portability pitfalls between BSD/GNU.
    local pre = sh_log("replace_in_file", "file=" .. path .. " mode=" .. (plain and "plain" or "regex"))
    if plain then
      -- perl -pe with \Q...\E quotes metacharacters for a true literal.
      return pre .. " && perl -pi -e " .. q("s/\\Q" .. find .. "\\E/" .. replace:gsub("/", "\\/") .. "/g") .. " " .. q(path)
    end
    return pre .. " && perl -pi -e " .. q("s/" .. find:gsub("/", "\\/") .. "/" .. replace:gsub("/", "\\/") .. "/g") .. " " .. q(path)
  end
end

function M.replace_on_glob(step, ctx)
  local glob    = ex(step.params.glob    or "", ctx)
  local find    = ex(step.params.find    or "", ctx)
  local replace = ex(step.params.replace or "", ctx)
  if glob == "" or find == "" then
    return nil, "replace_on_glob: 'glob' and 'find' are required"
  end
  local plain = step.params.plain and true or false
  local root  = ctx.output_path or ctx.source_path or "."
  if IS_WIN then
    local body = b64_decode(find,    "$find")    .. "; "
              .. b64_decode(replace, "$replace") .. "; "
              .. "$root = " .. psq(root)         .. "; "
              .. ps_header("replace_on_glob") .. "; "
              .. ps_logv("replace_on_glob", "scan   ", "$root") .. "; "
              .. ps_log("replace_on_glob",  "glob   = " .. glob) .. "; "
              .. ps_log("replace_on_glob",  "mode   = " .. (plain and "plain (literal)" or "regex")) .. "; "
              .. ps_logv("replace_on_glob", "find ln", "$find.Length") .. "; "
              .. ps_logv("replace_on_glob", "repl ln", "$replace.Length") .. "; "
              .. "$files = @(Get-ChildItem -Path $root -Recurse -Force -Include "
              .. psq(glob) .. "); "
              .. ps_logv("replace_on_glob", "matched", "$files.Count") .. "; "
              .. "$changed = 0; "
              .. "foreach ($f in $files) { "
              ..   "if ($f.PSIsContainer) { continue }; "
              ..   "$src = [System.IO.File]::ReadAllText($f.FullName); "
              ..   "$dst = " .. (plain and "$src.Replace($find, $replace)"
                                        or "$src -replace $find, $replace") .. "; "
              ..   "if ($src -ne $dst) { "
              ..     "Write-Output ('[replace_on_glob] edit   = ' + $f.FullName); "
              ..     ps_write_utf8_no_bom("$f.FullName", "$dst") .. "; "
              ..     "$changed++ "
              ..   "} "
              .. "}; "
              .. ps_logv("replace_on_glob", "changed", "$changed")
    return "powershell -NoProfile -Command " .. q(body)
  else
    local f = find:gsub("/", "\\/")
    local r = replace:gsub("/", "\\/")
    local pattern = plain and ("s/\\Q" .. f .. "\\E/" .. r .. "/g")
                           or ("s/" .. f .. "/" .. r .. "/g")
    return sh_log("replace_on_glob", "root=" .. root .. " glob=" .. glob .. " mode=" .. (plain and "plain" or "regex")) .. " && "
        .. "find " .. q(root) .. " -type f -name " .. q(glob)
        .. " -exec perl -pi -e " .. q(pattern) .. " {} +"
  end
end

-- ────────────────────────────────────────────────────────────────────────────
-- CONTENT: structured (properties / env / template / anchor insert)
-- ────────────────────────────────────────────────────────────────────────────

-- Parse a "KEY=VALUE" textarea into an ordered list of {k, v} pairs.
-- Lines starting with `#` and blank lines are skipped. Whitespace around KEY is
-- trimmed; VALUE is kept verbatim (incl. trailing spaces).
local function parse_kv_entries(text)
  local out = {}
  for line in (text or ""):gmatch("[^\n\r]+") do
    local stripped = line:gsub("^%s+", "")
    if stripped ~= "" and stripped:sub(1,1) ~= "#" then
      local k, v = stripped:match("^([^=]+)=(.*)$")
      if k then
        k = k:gsub("^%s+", ""):gsub("%s+$", "")
        if k ~= "" then out[#out+1] = { k = k, v = v or "" } end
      end
    end
  end
  return out
end

-- Shared PS helper: emits a ScriptBlock that upserts key=value pairs in a
-- java-.properties / .env style file. Lines matching `^key\s*=` get replaced
-- in place; missing keys get appended at the end. Comments / blanks are kept.
--
--   $target   — file path (expected set by caller)
--   $entries  — array of @{ k=; v= } (expected set by caller)
--
local PS_UPSERT_KV = [=[
if (-not (Test-Path -LiteralPath $target)) {
  [System.IO.File]::WriteAllText($target, '', (New-Object System.Text.UTF8Encoding $false))
};
$raw = [System.IO.File]::ReadAllText($target);
$lines = if ($raw.Length -eq 0) { @() } else { @($raw -split "`r?`n") };
$touched = 0;
foreach ($e in $entries) {
  $rx = '^' + [regex]::Escape($e.k) + '\s*=.*$';
  $found = $false;
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match $rx) { $lines[$i] = $e.k + '=' + $e.v; $found = $true; $touched++; break }
  };
  if (-not $found) { $lines += ($e.k + '=' + $e.v); $touched++ }
};
[System.IO.File]::WriteAllText($target, ($lines -join [Environment]::NewLine), (New-Object System.Text.UTF8Encoding $false))
]=]

local function compile_kv_upsert(kind, path, entries_text, ctx)
  if path == "" then return nil, kind .. ": 'path' is required" end
  local entries = parse_kv_entries(entries_text)
  if #entries == 0 then return nil, kind .. ": at least one key=value entry required" end

  if IS_WIN then
    -- Build $entries = @(@{k='foo';v='bar'}, ...). psq() escapes apostrophes.
    local entry_parts = {}
    for _, e in ipairs(entries) do
      entry_parts[#entry_parts+1] = "@{k=" .. psq(e.k) .. ";v=" .. psq(e.v) .. "}"
    end
    local ps = ps_header(kind) .. "; "
            .. "$target  = " .. psq(path) .. "; "
            .. ps_logv(kind, "file   ", "$target") .. "; "
            .. "$entries = @(" .. table.concat(entry_parts, ", ") .. "); "
            .. ps_logv(kind, "entries", "$entries.Count") .. "; "
            .. PS_UPSERT_KV:gsub("\n", ""):gsub("%s+", " ") .. "; "
            .. ps_logv(kind, "touched", "$touched")
    return "powershell -NoProfile -Command " .. q(ps)
  else
    -- POSIX: use awk for in-place key replacement and append missing keys.
    -- Simpler approach: emit a shell loop calling sed for each entry.
    local parts = { sh_log(kind, "file=" .. path .. " entries=" .. #entries) }
    parts[#parts+1] = "touch " .. q(path)
    for _, e in ipairs(entries) do
      -- Escape slashes & ampersands for sed replacement.
      local esc_v = e.v:gsub("([\\/&])", "\\%1")
      local esc_k = e.k:gsub("([.^$*+?()[%]{}|\\])", "\\%1")
      parts[#parts+1] = "(grep -qE " .. q("^" .. e.k .. "[[:space:]]*=") .. " " .. q(path)
        .. " && sed -i -E " .. q("s|^" .. esc_k .. "[[:space:]]*=.*|" .. e.k .. "=" .. esc_v .. "|") .. " " .. q(path)
        .. ") || echo " .. q(e.k .. "=" .. e.v) .. " >> " .. q(path)
    end
    return chain(parts)
  end
end

function M.properties_edit(step, ctx)
  local path    = ex(step.params.path    or "", ctx)
  local entries = ex(step.params.entries or "", ctx)
  return compile_kv_upsert("properties_edit", path, entries, ctx)
end

function M.env_merge(step, ctx)
  local path    = ex(step.params.path    or "", ctx)
  local entries = ex(step.params.entries or "", ctx)
  return compile_kv_upsert("env_merge", path, entries, ctx)
end

function M.template_render(step, ctx)
  local src  = ex(step.params.src  or "", ctx)
  local dest = ex(step.params.dest or "", ctx)
  if src  == "" then return nil, "template_render: 'src' is required" end
  if dest == "" then return nil, "template_render: 'dest' is required" end

  -- Build a (key, value) replace list from ctx.vars. Escape both via psq so PS
  -- sees literal single-quoted strings. `-replace` uses regex by default — we
  -- want plain, so we [regex]::Escape each key.
  if IS_WIN then
    local entry_parts = {}
    for k, v in pairs(ctx.vars or {}) do
      entry_parts[#entry_parts+1] = "@{k=" .. psq(k) .. ";v=" .. psq(tostring(v)) .. "}"
    end
    local ps = ps_header("template_render") .. "; "
            .. "$src  = " .. psq(src)  .. "; "
            .. "$dest = " .. psq(dest) .. "; "
            .. ps_logv("template_render", "src    ", "$src")  .. "; "
            .. ps_logv("template_render", "dest   ", "$dest") .. "; "
            .. "if (-not (Test-Path -LiteralPath $src)) { Write-Error ('[template_render] FAIL: src missing: ' + $src); exit 1 }; "
            .. "$content = [System.IO.File]::ReadAllText($src); "
            .. "$entries = @(" .. table.concat(entry_parts, ", ") .. "); "
            .. ps_logv("template_render", "vars   ", "$entries.Count") .. "; "
            .. "$subbed = 0; "
            .. "foreach ($e in $entries) { "
            ..   "$placeholder = '{{' + $e.k + '}}'; "
            ..   "$before = $content; "
            ..   "$content = $content.Replace($placeholder, $e.v); "
            ..   "if ($content -ne $before) { $subbed++ } "
            .. "}; "
            .. ps_logv("template_render", "subbed ", "$subbed") .. "; "
            .. "$dir = Split-Path -Parent $dest; "
            .. "if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }; "
            .. ps_write_utf8_no_bom("$dest", "$content") .. "; "
            .. ps_log("template_render", "done")
    return "powershell -NoProfile -Command " .. q(ps)
  else
    -- POSIX: chain sed invocations.
    local parts = { sh_log("template_render", "src=" .. src .. " dest=" .. dest) }
    parts[#parts+1] = "mkdir -p " .. q(dirname_unix(dest))
    -- Seed dest with src content then sed in place.
    parts[#parts+1] = "cp " .. q(src) .. " " .. q(dest)
    for k, v in pairs(ctx.vars or {}) do
      local esc_v = tostring(v):gsub("([\\/&])", "\\%1")
      local esc_k = k:gsub("([.^$*+?()[%]{}|\\])", "\\%1")
      parts[#parts+1] = "sed -i -E " .. q("s|\\{\\{" .. esc_k .. "\\}\\}|" .. esc_v .. "|g") .. " " .. q(dest)
    end
    return chain(parts)
  end
end

function M.insert_at_anchor(step, ctx)
  local path    = ex(step.params.path    or "", ctx)
  local anchor  = ex(step.params.anchor  or "", ctx)
  local content = ex(step.params.content or "", ctx)
  local pos     = step.params.position or "after"
  if path    == "" then return nil, "insert_at_anchor: 'path' is required" end
  if anchor  == "" then return nil, "insert_at_anchor: 'anchor' is required" end
  if pos ~= "after" and pos ~= "before" then pos = "after" end

  if IS_WIN then
    local ps = b64_decode(content, "$block") .. "; "
            .. b64_decode(anchor,  "$anchor") .. "; "
            .. "$target = " .. psq(path) .. "; "
            .. ps_header("insert_at_anchor") .. "; "
            .. ps_logv("insert_at_anchor", "file    ", "$target") .. "; "
            .. ps_log("insert_at_anchor",  "position = " .. pos) .. "; "
            .. "if (-not (Test-Path -LiteralPath $target)) { Write-Error '[insert_at_anchor] FAIL: file missing'; exit 1 }; "
            .. "$raw = [System.IO.File]::ReadAllText($target); "
            .. "$lines = $raw -split \"`r?`n\"; "
            .. "$rx = [regex]$anchor; "
            .. "$out = @(); "
            .. "$done = $false; "
            .. "foreach ($ln in $lines) { "
            ..   "if (-not $done -and $rx.IsMatch($ln)) { "
            ..     (pos == "before"
                      and "$out += $block.Split([char]10); $out += $ln; "
                      or  "$out += $ln; $out += $block.Split([char]10); ")
            ..     "$done = $true "
            ..   "} else { $out += $ln } "
            .. "}; "
            .. "if (-not $done) { Write-Error '[insert_at_anchor] FAIL: anchor pattern not found'; exit 1 }; "
            .. ps_write_utf8_no_bom("$target", "($out -join [char]10)") .. "; "
            .. ps_log("insert_at_anchor", "done")
    return "powershell -NoProfile -Command " .. q(ps)
  else
    -- POSIX: awk one-liner — insert BLOCK before/after first match of ANCHOR.
    local pattern_esc = anchor:gsub('/', '\\/')
    local block_literal = content:gsub("\n", "\\n"):gsub("'", "'\\''")
    local prog
    if pos == "before" then
      prog = "$0 ~ /" .. pattern_esc .. "/ && !done { printf \"%s\\n\", \"" .. block_literal .. "\"; done=1 } { print }"
    else
      prog = "{ print } $0 ~ /" .. pattern_esc .. "/ && !done { printf \"%s\\n\", \"" .. block_literal .. "\"; done=1 }"
    end
    return sh_log("insert_at_anchor", "file=" .. path .. " pos=" .. pos)
        .. " && awk '" .. prog .. "' " .. q(path) .. " > " .. q(path .. ".se.tmp")
        .. " && mv " .. q(path .. ".se.tmp") .. " " .. q(path)
  end
end

-- ── Structured edits: JSON via PS ConvertFrom-Json, XML via Select-Xml.
-- YAML and TOML require an external parser (yq / dasel) — intentionally left
-- unimplemented in Phase 3; users who need them can call the external tool via
-- `shell_command` or set one up in plugin settings.

-- Walk a dotted path on a PSObject / Hashtable, creating intermediate nodes if
-- they don't exist. Setting is done by the caller on the returned container.
local PS_JSON_SET = [=[
function Set-JsonPath($root, $path, $value) {
  $parts = $path -replace '^\$\.?', '' -split '\.';
  $cur = $root;
  for ($i = 0; $i -lt $parts.Count - 1; $i++) {
    $p = $parts[$i];
    if ($cur.PSObject.Properties[$p] -eq $null -or $cur.$p -eq $null) {
      $cur | Add-Member -NotePropertyName $p -NotePropertyValue (New-Object PSObject) -Force
    };
    $cur = $cur.$p
  };
  $leaf = $parts[$parts.Count - 1];
  $cur | Add-Member -NotePropertyName $leaf -NotePropertyValue $value -Force
}
]=]

function M.json_edit(step, ctx)
  local path  = ex(step.params.path  or "", ctx)
  local jpath = ex(step.params.jpath or "", ctx)
  local value = ex(step.params.value or "", ctx)
  if path  == "" then return nil, "json_edit: 'path' is required" end
  if jpath == "" then return nil, "json_edit: 'jpath' is required" end
  if IS_WIN then
    -- Value is treated as raw JSON literal if it parses as JSON, else as string.
    -- Users can pass `true`, `42`, `"foo"`, or `{"x":1}` and get the right type.
    local ps = ps_header("json_edit") .. "; "
            .. b64_decode(value, "$raw") .. "; "
            .. "$file = " .. psq(path)  .. "; "
            .. "$jp   = " .. psq(jpath) .. "; "
            .. ps_logv("json_edit", "file ", "$file") .. "; "
            .. ps_logv("json_edit", "jpath", "$jp") .. "; "
            .. "if (-not (Test-Path -LiteralPath $file)) { Write-Error '[json_edit] FAIL: file missing'; exit 1 }; "
            .. PS_JSON_SET:gsub("\n", ""):gsub("%s+", " ") .. "; "
            .. "$obj = [System.IO.File]::ReadAllText($file) | ConvertFrom-Json; "
            .. "try { $val = $raw | ConvertFrom-Json -ErrorAction Stop } catch { $val = $raw }; "
            .. ps_logv("json_edit", "value type", "$val.GetType().Name") .. "; "
            .. "Set-JsonPath $obj $jp $val; "
            .. ps_write_utf8_no_bom("$file", "($obj | ConvertTo-Json -Depth 100)") .. "; "
            .. ps_log("json_edit", "done")
    return "powershell -NoProfile -Command " .. q(ps)
  else
    return nil, "json_edit: not implemented on POSIX yet (use shell_command + jq)"
  end
end

function M.xml_edit(step, ctx)
  local path  = ex(step.params.path  or "", ctx)
  local xpath = ex(step.params.xpath or "", ctx)
  local value = ex(step.params.value or "", ctx)
  if path  == "" then return nil, "xml_edit: 'path' is required" end
  if xpath == "" then return nil, "xml_edit: 'xpath' is required" end
  if IS_WIN then
    -- PS XPath + InnerText. For attribute edits use XPath like `//foo/@attr`.
    local ps = ps_header("xml_edit") .. "; "
            .. b64_decode(value, "$new") .. "; "
            .. "$file = " .. psq(path)  .. "; "
            .. "$xp   = " .. psq(xpath) .. "; "
            .. ps_logv("xml_edit", "file ", "$file") .. "; "
            .. ps_logv("xml_edit", "xpath", "$xp") .. "; "
            .. "if (-not (Test-Path -LiteralPath $file)) { Write-Error '[xml_edit] FAIL: file missing'; exit 1 }; "
            .. "[xml]$doc = Get-Content -Raw -LiteralPath $file; "
            .. "$nodes = Select-Xml -Xml $doc -XPath $xp; "
            .. "if (-not $nodes) { Write-Error '[xml_edit] FAIL: XPath matched nothing'; exit 1 }; "
            .. ps_logv("xml_edit", "nodes", "$nodes.Count") .. "; "
            .. "foreach ($n in $nodes) { "
            ..   "if ($n.Node -is [System.Xml.XmlAttribute]) { $n.Node.Value = $new } "
            ..   "else { $n.Node.InnerText = $new } "
            .. "}; "
            .. "$doc.Save($file); "
            .. ps_log("xml_edit", "done")
    return "powershell -NoProfile -Command " .. q(ps)
  else
    return nil, "xml_edit: not implemented on POSIX yet (use shell_command + xmlstarlet)"
  end
end

-- ────────────────────────────────────────────────────────────────────────────
-- FLOW: set_variable (compile-time intercept)
-- ────────────────────────────────────────────────────────────────────────────
-- Important: `set_variable` is normally intercepted in compile.lua BEFORE
-- reaching this compiler — the handler mutates ctx.vars so subsequent steps
-- see the new value at command-compose time. The stub below is a safety net:
-- if compile.lua ever fails to intercept, we at least log the intent without
-- blowing up the run.
function M.set_variable(step, ctx)
  local name  = ex(step.params.name  or "", ctx)
  local value = ex(step.params.value or "", ctx)
  if name == "" then return nil, "set_variable: 'name' is required" end
  return "echo [set_variable] " .. name .. " = " .. cmd_echo_val(value)
end

-- ────────────────────────────────────────────────────────────────────────────
-- GIT
-- ────────────────────────────────────────────────────────────────────────────

-- Sanitise a value for safe display inside a cmd.exe `echo` command.
-- Embedded `"` flips cmd.exe's in-quotes mode and a subsequent `&&` is then
-- absorbed as literal — breaking the chain (the real command never runs).
-- Since these are prefix logs only (the actual command uses q() quoting
-- separately), swapping `"` for `'` is cosmetic + safe.
local function cmd_echo_val(s)
  return (s or ""):gsub('"', "'")
end

-- Echo helper for git ops: cross-shell `echo [tag] kv...` prefix so the user
-- sees exactly which cwd/branch/etc. the command is using (variable expansion
-- happens up-front in Lua; this just surfaces the resolved values).
local function echo_prefix(kind, kvs)
  return "echo [" .. kind .. "] " .. table.concat(kvs, " ")
end

function M.git_init(step, ctx)
  local cwd    = ex(step.params.cwd or ctx.output_path or "", ctx)
  local branch = ex(step.params.default_branch or "main", ctx)
  if cwd == "" then return nil, "git_init: 'cwd' (or $OUTPUT_PATH) is required" end
  -- `git init -b <branch>` requires git ≥ 2.28. Fallback to init + symbolic-ref.
  return chain({
    echo_prefix("git_init", { "cwd=\"" .. cwd .. "\"", "branch=" .. branch }),
    "git init " .. q(cwd),
    "git -C " .. q(cwd) .. " symbolic-ref HEAD refs/heads/" .. branch,
  })
end

function M.git_clone(step, ctx)
  local url    = ex(step.params.url    or "", ctx)
  local dest   = ex(step.params.dest   or ctx.output_path or "", ctx)
  local branch = ex(step.params.branch or "", ctx)
  if url == ""  then return nil, "git_clone: 'url' is required" end
  if dest == "" then return nil, "git_clone: 'dest' is required" end
  local flags = {}
  if branch ~= ""           then flags[#flags+1] = "branch=" .. branch end
  if step.params.shallow    then flags[#flags+1] = "depth=1" end
  if step.params.submodules then flags[#flags+1] = "submodules" end
  local args = { "git clone --progress" }
  if branch ~= "" then args[#args+1] = "--branch " .. q(branch) end
  if step.params.shallow    then args[#args+1] = "--depth 1" end
  if step.params.submodules then args[#args+1] = "--recurse-submodules" end
  args[#args+1] = "--"
  args[#args+1] = q(url)
  args[#args+1] = q(dest)
  return chain({
    echo_prefix("git_clone", {
      "url=\"" .. cmd_echo_val(url) .. "\"", "dest=\"" .. cmd_echo_val(dest) .. "\"",
      #flags > 0 and "flags=[" .. table.concat(flags, ",") .. "]" or "flags=[]"
    }),
    table.concat(args, " "),
  })
end

function M.git_commit(step, ctx)
  local cwd       = ex(step.params.cwd     or ctx.output_path or "", ctx)
  local message   = ex(step.params.message or "", ctx)
  local author    = ex(step.params.author  or "", ctx)
  if cwd == ""     then return nil, "git_commit: 'cwd' (or $OUTPUT_PATH) is required" end
  if message == "" then return nil, "git_commit: 'message' is required" end

  -- Commit message is free-form user text — defensively escape `"` before
  -- embedding in the echo prefix, otherwise a `"` in the message would flip
  -- cmd.exe quoting mode and the trailing `&&` would be absorbed, skipping
  -- the actual `git add` / `git commit` steps.
  local preview = cmd_echo_val(message:sub(1, 80):gsub("\n", " ")) .. (message:len() > 80 and "…" or "")
  local parts = {
    echo_prefix("git_commit", {
      "cwd=\"" .. cwd .. "\"",
      "msg=\"" .. preview .. "\"",
      author ~= "" and "author=\"" .. cmd_echo_val(author) .. "\"" or "author=(default)",
      step.params.all ~= false and "add=-A" or "add=none",
      step.params.allow_empty and "allow_empty=true" or "allow_empty=false",
    }),
  }
  if step.params.all ~= false then parts[#parts+1] = "git -C " .. q(cwd) .. " add -A" end
  local c = "git -C " .. q(cwd) .. " commit -m " .. q(message)
  if author ~= "" then c = c .. " --author " .. q(author) end
  if step.params.allow_empty then c = c .. " --allow-empty" end
  parts[#parts+1] = c
  return chain(parts)
end

function M.git_tag(step, ctx)
  local cwd  = ex(step.params.cwd  or ctx.output_path or "", ctx)
  local name = ex(step.params.name or "", ctx)
  local msg  = ex(step.params.message or "", ctx)
  if cwd == ""  then return nil, "git_tag: 'cwd' is required" end
  if name == "" then return nil, "git_tag: 'name' is required" end
  local args = { "git -C " .. q(cwd) .. " tag" }
  if step.params.force then args[#args+1] = "-f" end
  if msg ~= "" then
    args[#args+1] = "-a"
    args[#args+1] = q(name)
    args[#args+1] = "-m " .. q(msg)
  else
    args[#args+1] = q(name)
  end
  return chain({
    echo_prefix("git_tag", {
      "cwd=\"" .. cwd .. "\"", "name=" .. name,
      step.params.force and "force=true" or "force=false",
      msg ~= "" and "annotated=true" or "annotated=false",
    }),
    table.concat(args, " "),
  })
end

function M.git_push(step, ctx)
  local cwd    = ex(step.params.cwd    or ctx.output_path or "", ctx)
  local remote = ex(step.params.remote or "origin", ctx)
  local ref    = ex(step.params.ref    or "", ctx)
  if cwd == "" then return nil, "git_push: 'cwd' is required" end
  if ref == "" then return nil, "git_push: 'ref' (branch or tag) is required" end
  local args = { "git -C " .. q(cwd) .. " push" }
  if step.params.force_with_lease then args[#args+1] = "--force-with-lease" end
  if step.params.tags             then args[#args+1] = "--tags" end
  args[#args+1] = q(remote)
  args[#args+1] = q(ref)
  return chain({
    echo_prefix("git_push", {
      "cwd=\"" .. cwd .. "\"", "remote=" .. remote, "ref=" .. ref,
      step.params.force_with_lease and "force_with_lease=true" or "force_with_lease=false",
      step.params.tags and "tags=true" or "tags=false",
    }),
    table.concat(args, " "),
  })
end

function M.git_checkout(step, ctx)
  local cwd    = ex(step.params.cwd    or ctx.output_path or "", ctx)
  local branch = ex(step.params.branch or "", ctx)
  if cwd == ""    then return nil, "git_checkout: 'cwd' is required" end
  if branch == "" then return nil, "git_checkout: 'branch' is required" end
  local create = step.params.create ~= false
  local flag = create and "-B " or ""
  return chain({
    echo_prefix("git_checkout", {
      "cwd=\"" .. cwd .. "\"", "branch=" .. branch,
      create and "create=true" or "create=false",
    }),
    "git -C " .. q(cwd) .. " checkout " .. flag .. q(branch),
  })
end

function M.git_cherry_pick(step, ctx)
  local cwd  = ex(step.params.cwd  or ctx.output_path or "", ctx)
  local shas = ex(step.params.shas or "", ctx)
  if cwd == ""  then return nil, "git_cherry_pick: 'cwd' is required" end
  if shas == "" then return nil, "git_cherry_pick: 'shas' is required" end
  return chain({
    echo_prefix("git_cherry_pick", { "cwd=\"" .. cwd .. "\"", "shas=" .. shas }),
    "git -C " .. q(cwd) .. " cherry-pick " .. shas,
  })
end

function M.git_merge(step, ctx)
  local cwd    = ex(step.params.cwd    or ctx.output_path or "", ctx)
  local branch = ex(step.params.branch or "", ctx)
  if cwd == ""    then return nil, "git_merge: 'cwd' is required" end
  if branch == "" then return nil, "git_merge: 'branch' is required" end
  local strat = step.params.strategy or "default"
  local flag = ""
  if     strat == "ff_only" then flag = " --ff-only"
  elseif strat == "no_ff"   then flag = " --no-ff" end
  return chain({
    echo_prefix("git_merge", {
      "cwd=\"" .. cwd .. "\"", "branch=" .. branch, "strategy=" .. strat,
    }),
    "git -C " .. q(cwd) .. " merge" .. flag .. " " .. q(branch),
  })
end

function M.git_submodule_update(step, ctx)
  local cwd = ex(step.params.cwd or ctx.output_path or "", ctx)
  if cwd == "" then return nil, "git_submodule_update: 'cwd' is required" end
  return chain({
    echo_prefix("git_submodule_update", { "cwd=\"" .. cwd .. "\"" }),
    "git -C " .. q(cwd) .. " submodule update --init --recursive",
  })
end

-- ────────────────────────────────────────────────────────────────────────────
-- BUILD: Offline M2 via external `ju` tool (configured in plugin settings)
-- ────────────────────────────────────────────────────────────────────────────

function M.m2_offline_ju(step, ctx)
  local source = ex(step.params.source_path or "$SOURCE_PATH", ctx)
  local jdk    = ex(step.params.jdk         or "Jdk1_8", ctx)
  local dest   = ex(step.params.dest_m2     or "$OUTPUT_PATH", ctx)
  local bin    = step.params.ju_bin and step.params.ju_bin ~= ""
                   and step.params.ju_bin
                   or  gcfg.get_ju_bin()
  if bin == "" then bin = "ju" end
  -- Example: ju -ed --path=<source> --jdk=<jdk> -dp=<dest>
  return chain({
    echo_prefix("m2_offline_ju", {
      "bin=\"" .. bin .. "\"", "source=\"" .. source .. "\"",
      "jdk=" .. jdk, "dest=\"" .. dest .. "\"",
    }),
    q(bin) .. " -ed --path=" .. q(source)
         .. " --jdk=" .. q(jdk) .. " -dp=" .. q(dest),
  })
end

-- Helper: prefer a project-local wrapper script (mvnw, gradlew) when present,
-- fall back to PATH. Returns a cross-shell command snippet that runs inside
-- the given cwd. On Windows `.cmd`/`.bat` wrappers are preferred.
--
-- Example output (Windows, gradle):
--   (if exist "<cwd>\gradlew.bat" ("<cwd>\gradlew.bat" TASKS) else (gradle TASKS))
local function wrapper_or_bin(cwd, wrapper, bin, tail)
  if IS_WIN then
    local wrap_bat = cwd .. "\\" .. wrapper .. ".bat"
    local wrap_cmd = cwd .. "\\" .. wrapper .. ".cmd"
    return "(if exist " .. q(wrap_bat) .. " (" .. q(wrap_bat) .. " " .. tail .. ") "
         .. "else if exist " .. q(wrap_cmd) .. " (" .. q(wrap_cmd) .. " " .. tail .. ") "
         .. "else (" .. bin .. " " .. tail .. "))"
  else
    return "(if [ -x " .. q(cwd .. "/" .. wrapper) .. " ]; then "
         .. q(cwd .. "/" .. wrapper) .. " " .. tail .. "; "
         .. "else " .. bin .. " " .. tail .. "; fi)"
  end
end

function M.mvn_set_version(step, ctx)
  local cwd     = ex(step.params.cwd     or ctx.output_path or "", ctx)
  local version = ex(step.params.version or "", ctx)
  if cwd == ""     then return nil, "mvn_set_version: 'cwd' (or $OUTPUT_PATH) is required" end
  if version == "" then return nil, "mvn_set_version: 'version' is required" end
  local tail = "versions:set -DnewVersion=" .. q(version) .. " -DgenerateBackupPoms=false"
  return chain({
    echo_prefix("mvn_set_version", { "cwd=\"" .. cwd .. "\"", "version=" .. version }),
    wrapper_or_bin(cwd, "mvnw", "mvn", tail),
  }), cwd
end

function M.mvn_deploy(step, ctx)
  local cwd     = ex(step.params.cwd     or ctx.output_path or "", ctx)
  local profile = ex(step.params.profile or "", ctx)
  local extra   = ex(step.params.extra   or "", ctx)
  if cwd == "" then return nil, "mvn_deploy: 'cwd' (or $OUTPUT_PATH) is required" end
  local tail = "deploy"
  if profile ~= "" then tail = tail .. " -P" .. q(profile) end
  if extra   ~= "" then tail = tail .. " " .. extra end
  return chain({
    echo_prefix("mvn_deploy", {
      "cwd=\"" .. cwd .. "\"",
      profile ~= "" and ("profile=" .. profile) or "profile=(default)",
      extra ~= "" and ("extra=\"" .. cmd_echo_val(extra) .. "\"") or "extra=",
    }),
    wrapper_or_bin(cwd, "mvnw", "mvn", tail),
  }), cwd
end

function M.gradle_task(step, ctx)
  local cwd   = ex(step.params.cwd   or ctx.output_path or "", ctx)
  local tasks = ex(step.params.tasks or "", ctx)
  if cwd   == "" then return nil, "gradle_task: 'cwd' (or $OUTPUT_PATH) is required" end
  if tasks == "" then return nil, "gradle_task: 'tasks' is required" end
  return chain({
    echo_prefix("gradle_task", { "cwd=\"" .. cwd .. "\"", "tasks=\"" .. cmd_echo_val(tasks) .. "\"" }),
    wrapper_or_bin(cwd, "gradlew", "gradle", tasks),
  }), cwd
end

function M.gradle_offline(step, ctx)
  -- Populating a full offline cache is project-specific. This basic version
  -- runs `gradle dependencies --refresh-dependencies` then copies the user's
  -- Gradle cache directory to `dest`. Real distributions often want
  -- `--init-script` or custom cache locations — document and punt.
  local cwd  = ex(step.params.cwd  or ctx.output_path or "", ctx)
  local dest = ex(step.params.dest or (ctx.output_path and (ctx.output_path .. (IS_WIN and "\\gradle-cache" or "/gradle-cache"))) or "", ctx)
  if cwd  == "" then return nil, "gradle_offline: 'cwd' is required" end
  if dest == "" then return nil, "gradle_offline: 'dest' is required" end
  local copy_cache
  if IS_WIN then
    copy_cache = "robocopy \"%USERPROFILE%\\.gradle\\caches\" " .. q(dest) .. " /E /NFL /NDL /NJH /NJS & if %errorlevel% lss 8 exit /b 0 else exit /b 1"
  else
    copy_cache = "mkdir -p " .. q(dest) .. " && cp -R \"$HOME/.gradle/caches/\" " .. q(dest)
  end
  return chain({
    echo_prefix("gradle_offline", { "cwd=\"" .. cwd .. "\"", "dest=\"" .. dest .. "\"" }),
    wrapper_or_bin(cwd, "gradlew", "gradle", "dependencies --refresh-dependencies"),
    copy_cache,
  }), cwd
end

function M.npm_install(step, ctx)
  local cwd = ex(step.params.cwd or ctx.output_path or "", ctx)
  if cwd == "" then return nil, "npm_install: 'cwd' is required" end
  -- `npm ci` is strict: fails if lockfile is missing or out of sync — exactly
  -- what a reproducible export wants.
  return chain({
    echo_prefix("npm_install", { "cwd=\"" .. cwd .. "\"", "cmd=npm ci" }),
    "npm ci",
  }), cwd
end

function M.pnpm_install(step, ctx)
  local cwd = ex(step.params.cwd or ctx.output_path or "", ctx)
  if cwd == "" then return nil, "pnpm_install: 'cwd' is required" end
  return chain({
    echo_prefix("pnpm_install", { "cwd=\"" .. cwd .. "\"", "cmd=pnpm install --frozen-lockfile" }),
    "pnpm install --frozen-lockfile",
  }), cwd
end

function M.npm_pack(step, ctx)
  local cwd = ex(step.params.cwd or ctx.output_path or "", ctx)
  if cwd == "" then return nil, "npm_pack: 'cwd' is required" end
  return chain({
    echo_prefix("npm_pack", { "cwd=\"" .. cwd .. "\"" }),
    "npm pack",
  }), cwd
end

function M.docker_build(step, ctx)
  local context    = ex(step.params.context    or ".", ctx)
  local dockerfile = ex(step.params.dockerfile or "Dockerfile", ctx)
  local tag        = ex(step.params.tag        or "", ctx)
  if tag == "" then return nil, "docker_build: 'tag' is required" end
  local cmd = "docker build -t " .. q(tag) .. " -f " .. q(dockerfile) .. " " .. q(context)
  return chain({
    echo_prefix("docker_build", {
      "tag=\"" .. cmd_echo_val(tag) .. "\"",
      "dockerfile=\"" .. cmd_echo_val(dockerfile) .. "\"",
      "context=\"" .. cmd_echo_val(context) .. "\"",
    }),
    cmd,
  })
end

function M.docker_push(step, ctx)
  local tag = ex(step.params.tag or "", ctx)
  if tag == "" then return nil, "docker_push: 'tag' is required" end
  return chain({
    echo_prefix("docker_push", { "tag=\"" .. cmd_echo_val(tag) .. "\"" }),
    "docker push " .. q(tag),
  })
end

-- ────────────────────────────────────────────────────────────────────────────
-- VALIDATION
-- ────────────────────────────────────────────────────────────────────────────

function M.assert_file_exists(step, ctx)
  local path = ex(step.params.path or "", ctx)
  if path == "" then return nil, "assert_file_exists: 'path' is required" end
  local neg  = step.params.negate and true or false
  -- NOTE: label uses ` NOT` suffix (no parens). Parens in a cmd.exe token
  -- (when the op builds a `(…) && (…) || …` chain, like assert_cmd_exit_zero)
  -- are interpreted as a nested group by cmd — `(NOT)` would try to run `NOT`
  -- as a command and surface as "] non atteso". Keeping the label paren-free
  -- across all asserts for consistency.
  local kind = neg and "assert_file_exists NOT" or "assert_file_exists"
  local expect = neg and "file must NOT exist" or "file must exist"
  if IS_WIN then
    -- When negate=true, PASS means file is absent. Structured via expected-cond
    -- rather than branching the whole script.
    local cond = neg and "-not (Test-Path -LiteralPath $target)" or "Test-Path -LiteralPath $target"
    local ps = ps_header(kind) .. "; "
            .. "$target = " .. psq(path) .. "; "
            .. ps_logv(kind, "check ", "$target") .. "; "
            .. ps_log(kind, "expect = " .. expect) .. "; "
            .. "if (" .. cond .. ") { "
            ..   ps_log(kind, "PASS") .. " "
            .. "} else { "
            ..   "Write-Error '[" .. kind .. "] FAIL: expected " .. expect .. " — got opposite'; exit 1 "
            .. "}"
    return "powershell -NoProfile -Command " .. q(ps)
  else
    local test = neg and "[ ! -e " .. q(path) .. " ]" or "[ -e " .. q(path) .. " ]"
    return sh_log(kind, "check=" .. path .. " expect='" .. expect .. "'")
        .. " && (" .. test .. " && echo '[" .. kind .. "] PASS' || (echo '[" .. kind .. "] FAIL: expected " .. expect .. "' && exit 1))"
  end
end

function M.assert_cmd_exit_zero(step, ctx)
  local cmd = ex(step.params.command or "", ctx)
  if cmd == "" then return nil, "assert_cmd_exit_zero: 'command' is required" end
  local cwd  = resolve_cwd(step.params.cwd, ctx)
  local neg  = step.params.negate and true or false
  -- ` NOT` (no parens): this op builds a cmd.exe chain with `(…)` groups and
  -- nested `()` from a label would flip cmd into a sub-group parse →
  -- "] non atteso" error. See assert_file_exists for the same rationale.
  local kind = neg and "assert_cmd_exit_zero NOT" or "assert_cmd_exit_zero"
  -- When negate=true, PASS when cmd exits non-zero. We wrap via `cmd && exit 1
  -- || exit 0` form. Both cmd.exe and bash understand the chained `&& / ||`.
  local prefix, suffix
  if IS_WIN then
    prefix = "echo [" .. kind .. "] at \"" .. cwd .. "\" && echo [" .. kind .. "] expect = " .. (neg and "non-zero exit" or "zero exit") .. " && "
    suffix = neg
      and " && (echo [" .. kind .. "] FAIL: exit was 0 & exit /b 1) || echo [" .. kind .. "] PASS"
      or  ""
  else
    prefix = sh_log(kind, "at " .. cwd .. " expect='" .. (neg and "non-zero exit" or "zero exit") .. "'") .. " && "
    suffix = neg
      and " && (echo '[" .. kind .. "] FAIL: exit was 0' && exit 1) || echo '[" .. kind .. "] PASS'"
      or  ""
  end
  return prefix .. cmd .. suffix, cwd
end

function M.assert_env_set(step, ctx)
  local name = ex(step.params.var or "", ctx)
  if name == "" then return nil, "assert_env_set: 'var' is required" end
  local neg  = step.params.negate and true or false
  local kind = neg and "assert_env_set NOT" or "assert_env_set"
  local expect = neg and "var must NOT be set" or "var must be set"
  if IS_WIN then
    local fail_cond = neg
      and "-not [string]::IsNullOrEmpty($v)"
      or  "[string]::IsNullOrEmpty($v)"
    local ps = ps_header(kind) .. "; "
            .. "$name = " .. psq(name) .. "; "
            .. ps_logv(kind, "var   ", "$name") .. "; "
            .. ps_log(kind, "expect = " .. expect) .. "; "
            .. "$v = [Environment]::GetEnvironmentVariable($name); "
            .. "if (" .. fail_cond .. ") { "
            ..   "Write-Error '[" .. kind .. "] FAIL: expected " .. expect .. "'; exit 1 "
            .. "} else { "
            ..   ps_logv(kind, "PASS ", "'length=' + ([string]$v).Length") .. " "
            .. "}"
    return "powershell -NoProfile -Command " .. q(ps)
  else
    local test = neg and "test -z " .. q("${" .. name .. ":-}") or "test -n " .. q("${" .. name .. ":-}")
    return sh_log(kind, "var=" .. name .. " expect='" .. expect .. "'")
        .. " && (" .. test .. " && echo '[" .. kind .. "] PASS' || (echo '[" .. kind .. "] FAIL: expected " .. expect .. "' && exit 1))"
  end
end

function M.assert_branch_clean(step, ctx)
  local cwd = ex(step.params.cwd or ctx.output_path or ctx.source_path or "", ctx)
  if cwd == "" then return nil, "assert_branch_clean: 'cwd' is required" end
  local neg  = step.params.negate and true or false
  local kind = neg and "assert_branch_clean NOT" or "assert_branch_clean"
  local expect = neg and "working copy must be DIRTY" or "working copy must be clean"
  -- git status --porcelain returns no output when clean; any output fails.
  if IS_WIN then
    local fail_cond = neg and "-not $d" or "$d"
    -- NEVER embed `"` inside a PS script that q() will wrap in "…" — cmd.exe
    -- strips outer + balances inner quotes and PowerShell loses the -Command
    -- arg ("Carattere di terminazione mancante nella stringa"). Use PS char
    -- literals (`[char]10`) / single-quoted strings (psq) instead.
    local ps = ps_header(kind) .. "; "
            .. "$cwd = " .. psq(cwd) .. "; "
            .. ps_logv(kind, "repo  ", "$cwd") .. "; "
            .. ps_log(kind, "expect = " .. expect) .. "; "
            .. "$d = git -C $cwd status --porcelain; "
            .. "if ($d) { "
            ..   "Write-Output '[" .. kind .. "] status:'; "
            ..   "$d.Trim() -split [char]10 | ForEach-Object { Write-Output ('  ' + $_) } "
            .. "}; "
            .. "if (" .. fail_cond .. ") { "
            ..   "Write-Error '[" .. kind .. "] FAIL: expected " .. expect .. "'; exit 1 "
            .. "} else { "
            ..   ps_log(kind, "PASS") .. " "
            .. "}"
    return "powershell -NoProfile -Command " .. q(ps)
  else
    local test = neg
      and "[ -n \"$(git -C " .. q(cwd) .. " status --porcelain)\" ]"
      or  "[ -z \"$(git -C " .. q(cwd) .. " status --porcelain)\" ]"
    return sh_log(kind, "repo=" .. cwd .. " expect='" .. expect .. "'")
        .. " && (" .. test .. " && echo '[" .. kind .. "] PASS' || (git -C " .. q(cwd) .. " status --porcelain; echo '[" .. kind .. "] FAIL: expected " .. expect .. "' && exit 1))"
  end
end

function M.assert_file_not_contains(step, ctx)
  local path    = ex(step.params.path    or "", ctx)
  local pattern = ex(step.params.pattern or "", ctx)
  if path    == "" then return nil, "assert_file_not_contains: 'path' is required" end
  if pattern == "" then return nil, "assert_file_not_contains: 'pattern' is required" end
  local neg  = step.params.negate and true or false
  -- Default op = "must NOT contain". With negate=true, flips to "MUST contain".
  local kind = neg and "assert_file_not_contains NOT" or "assert_file_not_contains"
  local expect = neg and "pattern MUST be present" or "pattern must NOT be present"
  if IS_WIN then
    -- Pattern goes through base64: regex metacharacters + multi-line patterns
    -- would otherwise tangle the cmd.exe → PS handoff.
    local fail_cond = neg and "-not $match" or "$match"
    local ps = ps_header(kind) .. "; "
            .. b64_decode(pattern, "$pattern") .. "; "
            .. "$target = " .. psq(path) .. "; "
            .. ps_logv(kind, "file  ", "$target") .. "; "
            .. ps_logv(kind, "pattern len", "$pattern.Length") .. "; "
            .. ps_log(kind, "expect = " .. expect) .. "; "
            .. "if (-not (Test-Path -LiteralPath $target)) { "
            ..   "Write-Error ('[" .. kind .. "] FAIL: file missing: ' + $target); exit 1 "
            .. "}; "
            .. "$hits = @(Select-String -LiteralPath $target -Pattern $pattern -AllMatches); "
            .. "$match = $hits.Count -gt 0; "
            .. ps_logv(kind, "matches", "$hits.Count") .. "; "
            .. "if (" .. fail_cond .. ") { "
            ..   "Write-Error '[" .. kind .. "] FAIL: expected " .. expect .. "'; exit 1 "
            .. "} else { "
            ..   ps_log(kind, "PASS") .. " "
            .. "}"
    return "powershell -NoProfile -Command " .. q(ps)
  else
    -- grep exit 0 = match found, 1 = no match. -q silences output, -E extended regex.
    local test = neg
      and "grep -qE " .. q(pattern) .. " " .. q(path)
      or  "! grep -qE " .. q(pattern) .. " " .. q(path)
    return sh_log(kind, "file=" .. path .. " expect='" .. expect .. "'")
        .. " && (" .. test .. " && echo '[" .. kind .. "] PASS' || (echo '[" .. kind .. "] FAIL: expected " .. expect .. "' && exit 1))"
  end
end

function M.assert_glob_matches(step, ctx)
  local glob = ex(step.params.glob or "", ctx)
  if glob == "" then return nil, "assert_glob_matches: 'glob' is required" end
  local min  = tonumber(step.params.min) or 1
  local max  = tonumber(step.params.max)     -- nil = unlimited
  local root = ctx.output_path or ctx.source_path or "."
  local kind = "assert_glob_matches"
  if IS_WIN then
    -- Reduce path globs (`**/*.java`) to basename (`*.java`) for -Include,
    -- same limitation as delete_pattern.
    local bn = glob:match("[^/\\]+$") or glob
    local ps = ps_header(kind) .. "; "
            .. "$root = " .. psq(root) .. "; "
            .. ps_log(kind, "glob        = " .. glob) .. "; "
            .. ps_log(kind, "normalised  = " .. bn) .. "; "
            .. ps_log(kind, "min = " .. tostring(min) .. (max and ", max = " .. tostring(max) or ", max = (unlimited)")) .. "; "
            .. "$hits = @(Get-ChildItem -Path $root -Recurse -Force -File -Include "
            .. psq(bn) .. "); "
            .. "$n = $hits.Count; "
            .. ps_logv(kind, "found", "$n") .. "; "
            .. "if ($n -lt " .. tostring(min) .. ") { "
            ..   "Write-Error ('[" .. kind .. "] FAIL: expected >= " .. tostring(min) .. ", got ' + $n); exit 1 "
            .. "}; "
            .. (max and ("if ($n -gt " .. tostring(max) .. ") { "
            ..   "Write-Error ('[" .. kind .. "] FAIL: expected <= " .. tostring(max) .. ", got ' + $n); exit 1 "
            .. "}; ") or "")
            .. ps_log(kind, "PASS")
    return "powershell -NoProfile -Command " .. q(ps), root
  else
    -- Use find + wc -l. GNU find, bash arithmetic.
    local max_clause = max and (" && [ $n -le " .. tostring(max) .. " ]") or ""
    return sh_log(kind, "root=" .. root .. " glob=" .. glob .. " min=" .. tostring(min) .. " max=" .. tostring(max or "unlimited"))
        .. " && n=$(find " .. q(root) .. " -type f -name " .. q(glob) .. " | wc -l)"
        .. " && echo '[" .. kind .. "] found = '$n"
        .. " && ([ $n -ge " .. tostring(min) .. " ] " .. max_clause .. " && echo '[" .. kind .. "] PASS' || (echo '[" .. kind .. "] FAIL: got '$n && exit 1))"
  end
end

function M.assert_version_bump(step, ctx)
  local file        = ex(step.params.file        or "", ctx)
  local new_version = ex(step.params.new_version or "", ctx)
  if file        == "" then return nil, "assert_version_bump: 'file' is required" end
  if new_version == "" then return nil, "assert_version_bump: 'new_version' is required" end
  local kind = "assert_version_bump"
  if IS_WIN then
    -- Heuristic extractor for the current version:
    --   · pom.xml       → first `<version>...</version>` (project, not parent ideally)
    --   · package.json  → `"version": "X"` via ConvertFrom-Json
    --   · Cargo.toml    → `version = "X"` in [package]
    -- Numeric semver comparison (major.minor.patch); prerelease tags ignored.
    local ps = ps_header(kind) .. "; "
            .. "$file = " .. psq(file) .. "; "
            .. "$new  = " .. psq(new_version) .. "; "
            .. ps_logv(kind, "file ", "$file") .. "; "
            .. ps_logv(kind, "new  ", "$new") .. "; "
            .. "if (-not (Test-Path -LiteralPath $file)) { Write-Error ('[" .. kind .. "] FAIL: file missing: ' + $file); exit 1 }; "
            .. "$curr = $null; "
            .. "if ($file -match 'pom\\.xml$') { "
            ..   "$c = Get-Content -Raw -LiteralPath $file; "
            ..   "$m = [regex]::Match($c, '<version>([^<]+)</version>'); "
            ..   "if ($m.Success) { $curr = $m.Groups[1].Value } "
            .. "} elseif ($file -match 'package\\.json$') { "
            ..   "$obj = Get-Content -Raw -LiteralPath $file | ConvertFrom-Json; "
            ..   "$curr = [string]$obj.version "
            .. "} elseif ($file -match 'Cargo\\.toml$') { "
            ..   "$c = Get-Content -Raw -LiteralPath $file; "
            ..   "$m = [regex]::Match($c, 'version\\s*=\\s*[" .. "\\x22" .. "]([^" .. "\\x22" .. "]+)[" .. "\\x22" .. "]'); "
            ..   "if ($m.Success) { $curr = $m.Groups[1].Value } "
            .. "} else { Write-Error '[" .. kind .. "] FAIL: unsupported file kind'; exit 1 }; "
            .. "if (-not $curr) { Write-Error ('[" .. kind .. "] FAIL: could not extract current version from ' + $file); exit 1 }; "
            .. ps_logv(kind, "current", "$curr") .. "; "
            .. "function Cmp($a,$b) { "
            ..   "$pa = ($a -split '\\.' | Where-Object { $_ -match '^[0-9]+$' } | ForEach-Object { [int]$_ }); "
            ..   "$pb = ($b -split '\\.' | Where-Object { $_ -match '^[0-9]+$' } | ForEach-Object { [int]$_ }); "
            ..   "$n = [Math]::Max($pa.Count, $pb.Count); "
            ..   "for ($i = 0; $i -lt $n; $i++) { "
            ..     "$x = if ($i -lt $pa.Count) { $pa[$i] } else { 0 }; "
            ..     "$y = if ($i -lt $pb.Count) { $pb[$i] } else { 0 }; "
            ..     "if ($x -ne $y) { return ($y - $x) } "
            ..   "}; return 0 "
            .. "}; "
            .. "$d = Cmp $curr $new; "
            .. "if ($d -gt 0) { "
            ..   ps_log(kind, "PASS") .. "; "
            ..   "Write-Output ('[" .. kind .. "] ' + $curr + ' -> ' + $new) "
            .. "} elseif ($d -eq 0) { "
            ..   "Write-Error ('[" .. kind .. "] FAIL: same version (' + $curr + '), not a bump'); exit 1 "
            .. "} else { "
            ..   "Write-Error ('[" .. kind .. "] FAIL: new < current (' + $new + ' < ' + $curr + ')'); exit 1 "
            .. "}"
    return "powershell -NoProfile -Command " .. q(ps)
  else
    -- POSIX: delegate the comparison to PowerShell via `pwsh` when available,
    -- otherwise a minimal awk version. Keep this simple: shell out to grep +
    -- sort -V which GNU sort supports natively.
    return sh_log(kind, "file=" .. file .. " new=" .. new_version)
        .. " && (" .. "curr=$(grep -oE '<version>[^<]+' " .. q(file) .. " | head -1 | sed 's/<version>//') "
        .. "; if [ -z \"$curr\" ]; then curr=$(grep -oE '\"version\"\\s*:\\s*\"[^\"]+' " .. q(file) .. " | head -1 | sed 's/.*\"//'); fi"
        .. "; if [ -z \"$curr\" ]; then curr=$(grep -oE '^version\\s*=\\s*\"[^\"]+' " .. q(file) .. " | head -1 | sed 's/.*\"//'); fi"
        .. "; if [ -z \"$curr\" ]; then echo '[" .. kind .. "] FAIL: could not extract version'; exit 1; fi"
        .. "; echo '[" .. kind .. "] current = '$curr' -> new = " .. new_version .. "'"
        .. "; if [ \"$(printf '%s\\n%s' \"$curr\" \"" .. new_version .. "\" | sort -V | head -1)\" = \"" .. new_version .. "\" ] && [ \"$curr\" != \"" .. new_version .. "\" ]"
        .. "; then echo '[" .. kind .. "] FAIL: new <= current'; exit 1"
        .. "; else echo '[" .. kind .. "] PASS'; fi)"
  end
end

-- ────────────────────────────────────────────────────────────────────────────
-- Dispatcher
-- ────────────────────────────────────────────────────────────────────────────

-- Map of kind → shell compiler. Anything listed here is a shell-bound op
-- (git CLI, build tools, shell_command/env/cmd-exit asserts, echo-style
-- flow ops). Everything else that used to live here (create_file, replace_*,
-- properties_edit, assert_file_*, …) is served by the arbor.core.* op
-- modules registered in main.lua — compile.lua routes those via
-- StepKind::LuaOp before ever reaching this table, so the old shell impls
-- (still in this file as historical reference) are unreachable.
local IMPLEMENTED = {
  -- Shell / flow
  shell_command            = M.shell_command,
  log_message              = M.log_message,
  notify_toast             = M.notify_toast,
  set_variable             = M.set_variable,   -- intercept still routes via compile.lua
  -- Git CLI
  git_init                 = M.git_init,
  git_clone                = M.git_clone,
  git_commit               = M.git_commit,
  git_tag                  = M.git_tag,
  git_push                 = M.git_push,
  git_checkout             = M.git_checkout,
  git_cherry_pick          = M.git_cherry_pick,
  git_merge                = M.git_merge,
  git_submodule_update     = M.git_submodule_update,
  -- Build tooling (external processes)
  m2_offline_ju            = M.m2_offline_ju,
  mvn_set_version          = M.mvn_set_version,
  mvn_deploy               = M.mvn_deploy,
  gradle_task              = M.gradle_task,
  gradle_offline           = M.gradle_offline,
  npm_install              = M.npm_install,
  pnpm_install             = M.pnpm_install,
  npm_pack                 = M.npm_pack,
  docker_build             = M.docker_build,
  docker_push              = M.docker_push,
  -- Process / environment asserts (inherently shell-bound)
  assert_cmd_exit_zero     = M.assert_cmd_exit_zero,
  assert_env_set           = M.assert_env_set,
  assert_branch_clean      = M.assert_branch_clean,
}

--- Compile a step into (command, cwd_override). Returns `nil, err` on failure.
function M.compile(step, ctx)
  local impl = IMPLEMENTED[step.kind]
  if not impl then
    return nil, "Operation '" .. step.kind .. "' is not implemented yet (planned for Phase 3)"
  end
  local ok, cmd, cwd = pcall(impl, step, ctx)
  if not ok then return nil, tostring(cmd) end
  if not cmd or cmd == "" then
    return nil, (cwd or ("Operation '" .. step.kind .. "' returned an empty command"))
  end
  return cmd, cwd
end

function M.is_implemented(kind)
  return IMPLEMENTED[kind] ~= nil
end

return M
