-- English number names. Range: 0..(10^15 - 1).
-- Style: "one hundred twenty-three thousand four hundred fifty-six".
-- "and" is omitted (US convention).

local U = require("lib.util")

local ONES = {
  [0]="zero", "one","two","three","four","five","six","seven","eight","nine",
  "ten","eleven","twelve","thirteen","fourteen","fifteen","sixteen","seventeen","eighteen","nineteen",
}
local TENS = {
  [2]="twenty",[3]="thirty",[4]="forty",[5]="fifty",[6]="sixty",[7]="seventy",[8]="eighty",[9]="ninety",
}
local SCALES = {
  "thousand", "million", "billion", "trillion",
}

local function under_1000(n)
  if n == 0 then return "" end
  local out = {}
  local h = n // 100
  local r = n % 100
  if h > 0 then out[#out + 1] = ONES[h] .. " hundred" end
  if r > 0 then
    if r < 20 then
      out[#out + 1] = ONES[r]
    else
      local t = r // 10
      local u = r % 10
      if u == 0 then
        out[#out + 1] = TENS[t]
      else
        out[#out + 1] = TENS[t] .. "-" .. ONES[u]
      end
    end
  end
  return table.concat(out, " ")
end

local function encode_one(line)
  local n = U.parse_int(line)
  if n == 0 then return ONES[0] end
  local neg = n < 0
  if neg then n = -n end
  if n >= 1000000000000000 then error("too large (max 10^15 - 1): " .. line) end
  local groups, scale = {}, 0
  while n > 0 do
    local triplet = n % 1000
    if triplet > 0 then
      local txt = under_1000(triplet)
      if scale > 0 then txt = txt .. " " .. SCALES[scale] end
      groups[#groups + 1] = txt
    end
    n = n // 1000
    scale = scale + 1
  end
  -- reverse
  local rev = {}
  for i = #groups, 1, -1 do rev[#rev + 1] = groups[i] end
  return (neg and "negative " or "") .. table.concat(rev, " ")
end

-- ── decoder ──────────────────────────────────────────────────────────────
local W = {
  zero=0, one=1, two=2, three=3, four=4, five=5, six=6, seven=7, eight=8, nine=9,
  ten=10, eleven=11, twelve=12, thirteen=13, fourteen=14, fifteen=15,
  sixteen=16, seventeen=17, eighteen=18, nineteen=19,
  twenty=20, thirty=30, forty=40, fifty=50, sixty=60, seventy=70, eighty=80, ninety=90,
}
local MUL = { hundred=100 }
local SCL = { thousand=1000, million=1000000, billion=1000000000, trillion=1000000000000 }

local function decode_one(line)
  local s = line:lower():gsub("[,%-]", " "):gsub("%sand%s", " ")
  local neg = false
  if s:match("^%s*negative") then neg = true; s = s:gsub("^%s*negative", "") end
  local total, current = 0, 0
  for word in s:gmatch("%S+") do
    if W[word] then
      current = current + W[word]
    elseif MUL[word] then
      if current == 0 then current = 1 end
      current = current * MUL[word]
    elseif SCL[word] then
      if current == 0 then current = 1 end
      total = total + current * SCL[word]
      current = 0
    else
      error("unknown word: " .. word)
    end
  end
  total = total + current
  if neg then total = -total end
  return tostring(total)
end

return {
  id = "english_words", label = "English words", group = "Spelled Out",
  hint = "0..10^15-1, negative supported",
  encode = function(s) return U.per_line(s, encode_one) end,
  decode = function(s) return U.per_line(s, decode_one) end,
}
