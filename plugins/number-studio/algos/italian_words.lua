-- Italian number names. Range: 0..(10^12 - 1).
-- Style: "milleduecentotrentaquattro", "due milioni", "ventitré".
-- Handles standard elisions (ventuno, ventotto) and the accented tré at
-- the end of compounds.
--
-- Decoding free-form Italian back to decimal is intentionally not
-- supported — too many euphonic variants to handle cleanly.

local U = require("lib.util")

local UNITS = { [0]="zero",
  "uno","due","tre","quattro","cinque","sei","sette","otto","nove",
  "dieci","undici","dodici","tredici","quattordici","quindici","sedici",
  "diciassette","diciotto","diciannove",
}
local TENS  = { [2]="venti",[3]="trenta",[4]="quaranta",[5]="cinquanta",
                [6]="sessanta",[7]="settanta",[8]="ottanta",[9]="novanta" }

local function under_100(n)
  if n < 20 then return UNITS[n] end
  local t = n // 10
  local u = n % 10
  local base = TENS[t]
  if u == 0 then return base end
  if u == 1 or u == 8 then base = base:sub(1, -2) end  -- drop final vowel
  local unit = UNITS[u]
  if u == 3 then unit = "tré" end
  return base .. unit
end

local function under_1000(n)
  if n == 0 then return "" end
  if n < 100 then return under_100(n) end
  local h = n // 100
  local r = n % 100
  local hp = (h == 1) and "cento" or (UNITS[h] .. "cento")
  if r == 0 then return hp end
  return hp .. under_100(r)
end

local function under_million(n)
  if n < 1000 then return under_1000(n) end
  local th = n // 1000
  local r  = n % 1000
  local thp
  if th == 1 then thp = "mille" else thp = under_1000(th) .. "mila" end
  if r == 0 then return thp end
  return thp .. under_1000(r)
end

local function encode_one(line)
  local n = U.parse_int(line)
  if n == 0 then return UNITS[0] end
  local neg = n < 0
  if neg then n = -n end
  if n >= 1000000000000 then error("too large (max 10^12 - 1): " .. line) end

  local parts = {}
  local billions  = n // 1000000000;  n = n % 1000000000
  local millions  = n // 1000000;     n = n % 1000000
  local rest      = n

  if billions > 0 then
    parts[#parts + 1] = (billions == 1) and "un miliardo" or (under_million(billions) .. " miliardi")
  end
  if millions > 0 then
    parts[#parts + 1] = (millions == 1) and "un milione" or (under_million(millions) .. " milioni")
  end
  if rest > 0 then
    parts[#parts + 1] = under_million(rest)
  end
  return (neg and "meno " or "") .. table.concat(parts, " ")
end

return {
  id = "italian_words", label = "Italian (parole)", group = "Spelled Out",
  hint = "0..10^12-1, encode only",
  encode = function(s) return U.per_line(s, encode_one) end,
  decode = function() error("Italian → decimal not supported (encode only)") end,
}
