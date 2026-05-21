-- Mayan numerals. Base-20 positional. Each digit 0..19 has its own
-- Unicode glyph in U+1D2E0..U+1D2F3 (𝋠..𝋳). Positions separated by
-- ASCII spaces, big-endian.

local U = require("lib.util")

local DIGITS = {}
for d = 0, 19 do
  -- U+1D2E0 + d
  DIGITS[d] = utf8.char(0x1D2E0 + d)
end

local LOOKUP = {}
for d, g in pairs(DIGITS) do LOOKUP[g] = d end

local function encode_one(line)
  local n = U.parse_int(line)
  if n < 0 then error("Mayan numerals are non-negative") end
  if n == 0 then return DIGITS[0] end
  local parts = {}
  while n > 0 do
    parts[#parts + 1] = DIGITS[n % 20]
    n = n // 20
  end
  local rev = {}
  for i = #parts, 1, -1 do rev[#rev + 1] = parts[i] end
  return table.concat(rev, " ")
end

local function decode_one(line)
  if not line:match("%S") then error("empty input") end
  local n = 0
  for chunk in (line .. " "):gmatch("(%S+)%s+") do
    local d = LOOKUP[chunk]
    if not d then error("invalid Mayan digit: " .. chunk) end
    n = n * 20 + d
  end
  return tostring(n)
end

return {
  id = "mayan", label = "Mayan", group = "Historical",
  hint = "base 20, positions separated by space",
  encode = function(s) return U.per_line(s, encode_one) end,
  decode = function(s) return U.per_line(s, decode_one) end,
}
