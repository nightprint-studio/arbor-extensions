-- Babylonian / Sumerian cuneiform numerals. Base-60 positional.
-- Within one sexagesimal "digit" (0..59):
--   • tens are written with the corner wedge 𒌋 (U+1230B), repeated up to 5×
--   • units are written with the vertical wedge 𒁹 (U+12079), repeated up to 9×
-- Zero is represented by the dedicated placeholder 𒑊 (U+12470) (later-period
-- usage; classical Babylonian had no zero glyph).
-- Sexagesimal positions are separated by ASCII spaces, big-endian.
-- Range supported: 1..(60^6 - 1).

local U = require("lib.util")

local TEN   = "\u{1230B}"  -- 𒌋
local UNIT  = "\u{12079}"  -- 𒁹
local ZERO  = "\u{12470}"  -- 𒑊

local function digit_to_glyphs(d)
  if d == 0 then return ZERO end
  local t = d // 10
  local u = d % 10
  return string.rep(TEN, t) .. string.rep(UNIT, u)
end

local function encode_one(line)
  local n = U.parse_int(line)
  if n < 1 then error("Babylonian numerals are positive only") end
  if n >= 60^6 then error("too large for Babylonian (max 60^6 - 1)") end
  local digits = {}
  while n > 0 do
    digits[#digits + 1] = n % 60
    n = n // 60
  end
  local rev = {}
  for i = #digits, 1, -1 do
    rev[#rev + 1] = digit_to_glyphs(digits[i])
  end
  return table.concat(rev, " ")
end

local function parse_digit(s)
  local d, i = 0, 1
  while i <= #s do
    if s:sub(i, i + #TEN - 1) == TEN then
      d = d + 10
      i = i + #TEN
    elseif s:sub(i, i + #UNIT - 1) == UNIT then
      d = d + 1
      i = i + #UNIT
    elseif s:sub(i, i + #ZERO - 1) == ZERO then
      -- a zero glyph swallows the rest of the position
      if d ~= 0 then error("zero glyph mixed with wedges") end
      i = i + #ZERO
    else
      error("invalid cuneiform byte at position " .. i)
    end
  end
  if d >= 60 then error("position has digit ≥ 60") end
  return d
end

local function decode_one(line)
  if not line:match("%S") then error("empty input") end
  local n = 0
  for chunk in (line .. " "):gmatch("(%S+)%s+") do
    n = n * 60 + parse_digit(chunk)
  end
  return tostring(n)
end

return {
  id = "babylonian", label = "Babylonian cuneiform", group = "Historical",
  hint = "base 60, positions separated by space",
  encode = function(s) return U.per_line(s, encode_one) end,
  decode = function(s) return U.per_line(s, decode_one) end,
}
