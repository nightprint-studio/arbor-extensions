-- Roman numerals (subtractive form). Range 1..3999.
local U = require("lib.util")

local PAIRS = {
  {1000,"M"}, {900,"CM"}, {500,"D"}, {400,"CD"},
  {100, "C"}, {90, "XC"}, {50, "L"}, {40, "XL"},
  {10,  "X"}, {9,  "IX"}, {5,  "V"}, {4,  "IV"},
  {1,   "I"},
}

local VALUE = {
  I = 1, V = 5, X = 10, L = 50, C = 100, D = 500, M = 1000,
}

local function encode_one(line)
  local n = U.parse_int(line)
  if n < 1 or n > 3999 then error("out of Roman range (1..3999): " .. n) end
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
  local s = line:gsub("%s", ""):upper()
  if s == "" then error("empty input") end
  local total, prev = 0, 0
  for i = #s, 1, -1 do
    local v = VALUE[s:sub(i, i)]
    if not v then error("invalid Roman digit: '" .. s:sub(i, i) .. "'") end
    if v < prev then total = total - v else total = total + v end
    prev = v
  end
  -- Round-trip validation: re-encode and compare to canonical form.
  local canon = encode_one(tostring(total))
  if canon ~= s then error("malformed Roman numeral: " .. s .. " (canonical: " .. canon .. ")") end
  return tostring(total)
end

return {
  id = "roman", label = "Roman", group = "Historical",
  hint = "1..3999",
  encode = function(s) return U.per_line(s, encode_one) end,
  decode = function(s) return U.per_line(s, decode_one) end,
}
