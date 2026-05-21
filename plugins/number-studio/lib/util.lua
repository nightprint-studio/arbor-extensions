-- Shared helpers for number-studio algorithms.
--
-- Convention used by every algo:
--   encode(text, key) — text is one decimal integer per line, returns the
--                       same lines converted into the target system.
--   decode(text, key) — text is one number per line in the target system,
--                       returns the same lines as decimal integers.
--
-- Empty lines are preserved. Per-line errors are emitted as "⚠ <reason>"
-- so a partially-bad batch still produces useful output.

local M = {}

-- Parse a (possibly signed, possibly whitespace-padded) decimal integer.
function M.parse_int(s)
  s = (s or ""):gsub("[%s,_]", "")
  if s == "" then error("empty input") end
  local n = tonumber(s)
  if not n then error("not a decimal integer: " .. s) end
  if n ~= math.floor(n) then error("not an integer: " .. s) end
  return math.tointeger(n) or n
end

-- Generic positional base encoder/decoder (radix 2..36).
local DIGITS_LOWER = "0123456789abcdefghijklmnopqrstuvwxyz"

function M.to_base(n, b, opts)
  opts = opts or {}
  if n == 0 then return "0" end
  local neg = n < 0
  if neg then n = -n end
  local out = {}
  while n > 0 do
    local d = n % b
    out[#out + 1] = DIGITS_LOWER:sub(d + 1, d + 1)
    n = (n - d) // b
  end
  -- reverse
  local rev = {}
  for i = #out, 1, -1 do rev[#rev + 1] = out[i] end
  local s = table.concat(rev)
  if opts.upper then s = s:upper() end
  if neg then s = "-" .. s end
  return s
end

function M.from_base(s, b)
  s = (s or ""):gsub("[%s_]", "")
  if s == "" then error("empty input") end
  local neg = false
  if s:sub(1, 1) == "-" then
    neg = true
    s = s:sub(2)
  end
  if s == "" then error("empty number") end
  -- strip common prefixes
  local p2 = s:sub(1, 2):lower()
  if (b == 2  and p2 == "0b")
  or (b == 8  and p2 == "0o")
  or (b == 16 and p2 == "0x") then
    s = s:sub(3)
  end
  if s == "" then error("empty number after prefix") end
  local n = 0
  for i = 1, #s do
    local c = s:sub(i, i):lower()
    local d = DIGITS_LOWER:find(c, 1, true)
    if not d then error("invalid digit: '" .. s:sub(i, i) .. "'") end
    d = d - 1
    if d >= b then error("digit '" .. c .. "' invalid for base " .. b) end
    n = n * b + d
  end
  if neg then n = -n end
  return n
end

-- Apply `fn` to every non-empty line; preserve blank lines.
function M.per_line(s, fn)
  local out = {}
  for line in (s .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("%S") then
      local ok, res = pcall(fn, line)
      out[#out + 1] = ok and tostring(res) or ("⚠ " .. tostring(res))
    else
      out[#out + 1] = ""
    end
  end
  -- drop trailing empty line we synthesised
  if out[#out] == "" then table.remove(out) end
  return table.concat(out, "\n")
end

-- Encode using a 10-element table of glyphs (digits[i] = glyph for i-1).
function M.digits_encode(s, digits)
  return M.per_line(s, function(line)
    local n = M.parse_int(line)
    local neg = n < 0
    if neg then n = -n end
    if n == 0 then return (neg and "-" or "") .. digits[1] end
    local out = ""
    while n > 0 do
      out = digits[(n % 10) + 1] .. out
      n = n // 10
    end
    return (neg and "-" or "") .. out
  end)
end

-- Reverse the above: parse glyphs back to decimal.
function M.digits_decode(s, digits)
  local lookup = {}
  local glyphs = {}
  for i, g in ipairs(digits) do
    lookup[g] = i - 1
    glyphs[#glyphs + 1] = g
  end
  -- Longest first, to handle multi-byte sequences cleanly.
  table.sort(glyphs, function(a, b) return #a > #b end)

  return M.per_line(s, function(line)
    line = line:gsub("%s", "")
    if line == "" then error("empty number") end
    local neg = false
    if line:sub(1, 1) == "-" then
      neg = true
      line = line:sub(2)
    end
    if line == "" then error("empty number") end
    local digits_out = {}
    local i = 1
    while i <= #line do
      local matched = nil
      for _, g in ipairs(glyphs) do
        if line:sub(i, i + #g - 1) == g then
          matched = g
          break
        end
      end
      if not matched then
        error("invalid digit at byte " .. i .. ": '" .. line:sub(i, i + 3) .. "'")
      end
      digits_out[#digits_out + 1] = lookup[matched]
      i = i + #matched
    end
    local n = 0
    for _, d in ipairs(digits_out) do n = n * 10 + d end
    if neg then n = -n end
    return tostring(n)
  end)
end

return M
