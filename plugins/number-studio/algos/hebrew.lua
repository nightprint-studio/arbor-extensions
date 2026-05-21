-- Hebrew numerals (gematria). Letter-based, additive.
--   Units:    א=1 ב=2 ג=3 ד=4 ה=5 ו=6 ז=7 ח=8 ט=9
--   Tens:     י=10 כ=20 ל=30 מ=40 נ=50 ס=60 ע=70 פ=80 צ=90
--   Hundreds: ק=100 ר=200 ש=300 ת=400
--   500..900 are built additively (תק, תר, תש, תת, תתק).
--   Special cases: 15 = ט״ו (not יה) and 16 = ט״ז (not יו), to avoid
--   forming sacred names.
-- Range supported: 1..999.

local U = require("lib.util")

local UNITS    = { "א","ב","ג","ד","ה","ו","ז","ח","ט" }
local TENS     = { "י","כ","ל","מ","נ","ס","ע","פ","צ" }
local HUNDREDS = { "ק","ר","ש","ת" }   -- 100..400

local GERSHAYIM = "\u{05F4}"  -- ״
local GERESH    = "\u{05F3}"  -- ׳

local function encode_one(line)
  local n = U.parse_int(line)
  if n < 1 or n > 999 then error("out of Hebrew range (1..999): " .. n) end
  local out = ""
  -- Hundreds
  local h = n // 100
  while h > 4 do
    out = out .. "ת"
    h = h - 4
  end
  if h > 0 then out = out .. HUNDREDS[h] end
  -- Tens + units, with 15/16 quirk
  local r = n % 100
  if r == 15 then
    out = out .. "טו"
  elseif r == 16 then
    out = out .. "טז"
  else
    local t = r // 10
    local u = r % 10
    if t > 0 then out = out .. TENS[t] end
    if u > 0 then out = out .. UNITS[u] end
  end
  -- Punctuation: gershayim before final letter for multi-letter, geresh
  -- after the single letter for single-letter.
  if utf8.len(out) == 1 then
    out = out .. GERESH
  else
    local last_start
    for p, _ in utf8.codes(out) do last_start = p end
    out = out:sub(1, last_start - 1) .. GERSHAYIM .. out:sub(last_start)
  end
  return out
end

local VALUE = {
  ["א"]=1,["ב"]=2,["ג"]=3,["ד"]=4,["ה"]=5,["ו"]=6,["ז"]=7,["ח"]=8,["ט"]=9,
  ["י"]=10,["כ"]=20,["ל"]=30,["מ"]=40,["נ"]=50,["ס"]=60,["ע"]=70,["פ"]=80,["צ"]=90,
  ["ך"]=20,["ם"]=40,["ן"]=50,["ף"]=80,["ץ"]=90,  -- finals
  ["ק"]=100,["ר"]=200,["ש"]=300,["ת"]=400,
}

local function decode_one(line)
  -- strip gershayim / geresh / whitespace
  line = line:gsub(GERSHAYIM, ""):gsub(GERESH, ""):gsub("%s", "")
  if line == "" then error("empty input") end
  local total = 0
  for _, cp in utf8.codes(line) do
    local g = utf8.char(cp)
    local v = VALUE[g]
    if not v then error("invalid Hebrew letter: " .. g) end
    total = total + v
  end
  return tostring(total)
end

return {
  id = "hebrew", label = "Hebrew (gematria)", group = "Historical",
  hint = "1..999, with ׳/״",
  encode = function(s) return U.per_line(s, encode_one) end,
  decode = function(s) return U.per_line(s, decode_one) end,
}
