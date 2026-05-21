-- Greek alphabetic numerals (Milesian / Ionian system).
--
-- Units:    α=1 β=2 γ=3 δ=4 ε=5 ϛ=6 (stigma) ζ=7 η=8 θ=9
-- Tens:     ι=10 κ=20 λ=30 μ=40 ν=50 ξ=60 ο=70 π=80 ϟ=90 (koppa)
-- Hundreds: ρ=100 σ=200 τ=300 υ=400 φ=500 χ=600 ψ=700 ω=800 ϡ=900 (sampi)
-- Keraia (ʹ U+0374) marks numerals; lower-left keraia (͵ U+0375) marks thousands.
-- Range supported: 1..999_999.

local U = require("lib.util")

local UNITS    = { "α","β","γ","δ","ε","ϛ","ζ","η","θ" }
local TENS     = { "ι","κ","λ","μ","ν","ξ","ο","π","ϟ" }
local HUNDREDS = { "ρ","σ","τ","υ","φ","χ","ψ","ω","ϡ" }

local function encode_hundreds(n)
  local out = ""
  local h = n // 100
  local t = (n % 100) // 10
  local u = n % 10
  if h > 0 then out = out .. HUNDREDS[h] end
  if t > 0 then out = out .. TENS[t] end
  if u > 0 then out = out .. UNITS[u] end
  return out
end

local KERAIA           = "\u{0374}"
local LOWER_KERAIA     = "\u{0375}"

local function encode_one(line)
  local n = U.parse_int(line)
  if n < 1 or n > 999999 then error("out of Greek alphabetic range (1..999999): " .. n) end
  local thousands = n // 1000
  local rest      = n % 1000
  local out = ""
  if thousands > 0 then
    out = LOWER_KERAIA .. encode_hundreds(thousands) .. " "
  end
  if rest > 0 then
    out = out .. encode_hundreds(rest) .. KERAIA
  else
    -- thousands-only: still terminate with keraia for unambiguous parsing
    out = out:gsub(" $", "") .. KERAIA
  end
  return out
end

local VALUE = {
  ["α"]=1,["β"]=2,["γ"]=3,["δ"]=4,["ε"]=5,["ϛ"]=6,["ζ"]=7,["η"]=8,["θ"]=9,
  ["ι"]=10,["κ"]=20,["λ"]=30,["μ"]=40,["ν"]=50,["ξ"]=60,["ο"]=70,["π"]=80,["ϟ"]=90,
  ["ρ"]=100,["σ"]=200,["τ"]=300,["υ"]=400,["φ"]=500,["χ"]=600,["ψ"]=700,["ω"]=800,["ϡ"]=900,
}

local function decode_one(line)
  line = line:gsub(KERAIA, ""):gsub("%s", "")
  if line == "" then error("empty input") end
  local thousands = 0
  -- Detect thousands prefix(es).
  while line:sub(1, #LOWER_KERAIA) == LOWER_KERAIA do
    line = line:sub(#LOWER_KERAIA + 1)
    -- read exactly one letter (greek letters are 2-byte utf8)
    if #line == 0 then error("dangling thousands prefix") end
    local g = line:sub(1, 2)
    local v = VALUE[g]
    if not v then error("invalid thousands digit") end
    thousands = thousands * 1000 + v * 1000
    line = line:sub(3)
  end
  local total = thousands
  local i = 1
  while i <= #line do
    local g = line:sub(i, i + 1) -- greek letters in UTF-8 are 2 bytes
    local v = VALUE[g]
    if not v then error("invalid digit at byte " .. i) end
    total = total + v
    i = i + 2
  end
  return tostring(total)
end

return {
  id = "greek_alphabetic", label = "Greek alphabetic (Milesian)", group = "Historical",
  hint = "1..999999, with ʹ keraia",
  encode = function(s) return U.per_line(s, encode_one) end,
  decode = function(s) return U.per_line(s, decode_one) end,
}
