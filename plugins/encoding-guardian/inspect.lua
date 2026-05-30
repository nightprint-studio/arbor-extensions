-- inspect.lua — per-file encoding inspection.
--
-- Each inspector consumes the file's raw bytes and produces a yes/no
-- verdict (or a short label). No transcoding happens here — Lua strings
-- are byte buffers, and `arbor.fs.read` hands them back verbatim.

local mojibake = require("mojibake")

local M = {}

-- ── BOM ────────────────────────────────────────────────────────────────────

function M.has_utf8_bom(content)
  return #content >= 3
     and string.byte(content, 1) == 0xEF
     and string.byte(content, 2) == 0xBB
     and string.byte(content, 3) == 0xBF
end

function M.has_utf16_bom(content)
  if #content < 2 then return false end
  local b1, b2 = string.byte(content, 1), string.byte(content, 2)
  return (b1 == 0xFE and b2 == 0xFF) or (b1 == 0xFF and b2 == 0xFE)
end

-- ── Line endings ───────────────────────────────────────────────────────────

-- Sample the first 64 KiB only — multi-MB files don't need a full scan
-- to settle the question. Returns "lf" | "crlf" | "mixed" | "none".
function M.detect_eol(content)
  local slice = #content > 65536 and content:sub(1, 65536) or content
  local crlf_hits   = select(2, slice:gsub("\r\n", ""))
  local lf_only     = select(2, slice:gsub("[^\r]\n", ""))
  -- The leading byte (no predecessor) is missed by the `[^\r]\n` pattern;
  -- count it explicitly when it's a bare LF.
  if #slice >= 1 and slice:byte(1) == 0x0A then lf_only = lf_only + 1 end
  if crlf_hits > 0 and lf_only > 0 then return "mixed" end
  if crlf_hits > 0 then return "crlf" end
  if lf_only > 0   then return "lf"   end
  return "none"
end

-- ── UTF-8 validity ─────────────────────────────────────────────────────────

function M.is_valid_utf8(content)
  return utf8.len(content) ~= nil
end

-- ── Per-file aggregate ─────────────────────────────────────────────────────

-- Runs every check the project configuration asks for. Returns nil when
-- the file is clean, otherwise `{ path, problems = { "..." } }` with
-- one human-readable string per failing check.
function M.inspect_file(rel_path, full_path, cfg)
  local content, read_err = arbor.fs.read(full_path)
  if not content then
    return { path = rel_path, problems = { "read failed: " .. tostring(read_err) } }
  end

  local problems = {}
  local function flag(message) problems[#problems + 1] = message end

  if cfg.block_mojibake then
    local detection = mojibake.detect(content)
    if detection.total > 0 then
      flag("mojibake: " .. mojibake.summarise(detection))
    end
    if detection.exotic > 0 then
      flag(string.format(
        "mojibake (exotic): %d unrecognised `%s` sequence(s) — fix by hand",
        detection.exotic, mojibake.sample_prefix()
      ))
    end
  end

  if cfg.block_charset and cfg.default_charset == "utf-8" then
    if not M.is_valid_utf8(content) then
      flag("invalid UTF-8 byte sequence")
    end
    if M.has_utf16_bom(content) then
      flag("UTF-16 BOM detected (project declares UTF-8)")
    end
  end

  if cfg.block_bom then
    local has_bom = M.has_utf8_bom(content)
    if cfg.default_charset == "utf-8" and has_bom then
      flag("UTF-8 BOM present (project declares utf-8 without BOM)")
    elseif cfg.default_charset == "utf-8-bom" and not has_bom then
      flag("missing UTF-8 BOM (project declares utf-8-bom)")
    end
  end

  if cfg.block_eol and cfg.default_eol ~= "any" then
    local eol = M.detect_eol(content)
    if eol == "mixed" then
      flag("mixed line endings (LF + CRLF)")
    elseif eol ~= "none" and eol ~= cfg.default_eol then
      flag(string.format("EOL is %s (project declares %s)", eol, cfg.default_eol))
    end
  end

  if #problems == 0 then return nil end
  return { path = rel_path, problems = problems }
end

return M
