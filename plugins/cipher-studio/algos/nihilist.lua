-- Nihilist cipher — Polybius square (5×5, I/J merged) coordinates added
-- to a Vigenère-style numeric stream derived from the key.

local SQUARE = "ABCDEFGHIKLMNOPQRSTUVWXYZ"
local POS = {}
for i = 1, 25 do
  POS[SQUARE:sub(i, i)] = (math.floor((i - 1) / 5) + 1) * 10 + ((i - 1) % 5 + 1)
end
POS["J"] = POS["I"]

local REV = {}
for c, n in pairs(POS) do REV[n] = c end
REV[POS["I"]] = "I" -- prefer "I" over "J" on decode

local function key_stream(key)
  local out = {}
  for c in (key or ""):upper():gmatch("[A-Z]") do
    out[#out + 1] = POS[c]
  end
  if #out == 0 then error("nihilist: key must contain at least one letter") end
  return out
end

local function encode(input, key)
  local stream = key_stream(key)
  local out, ki = {}, 0
  for c in input:upper():gmatch("[A-Z]") do
    local n = POS[c] + stream[(ki % #stream) + 1]
    out[#out + 1] = tostring(n)
    ki = ki + 1
  end
  return table.concat(out, " ")
end

local function decode(input, key)
  local stream = key_stream(key)
  local out, ki = {}, 0
  for tok in input:gmatch("%d+") do
    local n = tonumber(tok) or 0
    local p = n - stream[(ki % #stream) + 1]
    out[#out + 1] = REV[p] or "?"
    ki = ki + 1
  end
  return table.concat(out)
end

return {
  id = "nihilist", label = "Nihilist", group = "Grid",
  key = { label = "Keyword", placeholder = "DWWMA", default = "DWWMA" },
  encode = encode, decode = decode,
}
