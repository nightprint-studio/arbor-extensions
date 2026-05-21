-- Attic (acrophonic) Greek numerals.
--   Ι = 1, Π = 5, Δ = 10, Η = 100, Χ = 1000, Μ = 10000
--   Compounds for 50/500/5000/50000 use Π enclosing Δ/Η/Χ/Μ — in plain
--   text we approximate them with the Unicode acrophonic symbols:
--     𐅄 = 50, 𐅅 = 500, 𐅆 = 5000, 𐅇 = 50000.
-- Additive, like Roman. Range 1..99999.

local U = require("lib.util")

local PAIRS = {
  {50000, "\u{10147}"},  -- 𐅇
  {10000, "Μ"},
  {5000,  "\u{10146}"},  -- 𐅆
  {1000,  "Χ"},
  {500,   "\u{10145}"},  -- 𐅅
  {100,   "Η"},
  {50,    "\u{10144}"},  -- 𐅄
  {10,    "Δ"},
  {5,     "Π"},
  {1,     "Ι"},
}

local function encode_one(line)
  local n = U.parse_int(line)
  if n < 1 or n > 99999 then error("out of Attic Greek range (1..99999): " .. n) end
  local out = {}
  for _, p in ipairs(PAIRS) do
    while n >= p[1] do
      out[#out + 1] = p[2]
      n = n - p[1]
    end
  end
  return table.concat(out)
end

local function decode_one(line)
  line = line:gsub("%s", "")
  if line == "" then error("empty input") end
  local lookup = {}
  for _, p in ipairs(PAIRS) do lookup[p[2]] = p[1] end
  local total, i = 0, 1
  while i <= #line do
    local matched = nil
    for _, p in ipairs(PAIRS) do
      local g = p[2]
      if line:sub(i, i + #g - 1) == g then matched = g; break end
    end
    if not matched then error("invalid Attic digit at byte " .. i) end
    total = total + lookup[matched]
    i = i + #matched
  end
  return tostring(total)
end

return {
  id = "attic_greek", label = "Attic Greek (acrophonic)", group = "Historical",
  hint = "1..99999, additive",
  encode = function(s) return U.per_line(s, encode_one) end,
  decode = function(s) return U.per_line(s, decode_one) end,
}
