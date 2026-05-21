-- Polybius square (5×5, I/J merged). No key. Each letter → "rc" digit pair.

local SQUARE = "ABCDEFGHIKLMNOPQRSTUVWXYZ" -- 25 letters, I=J

local POS = {}
for i = 1, 25 do
  POS[SQUARE:sub(i, i)] = string.format("%d%d",
    math.floor((i - 1) / 5) + 1, ((i - 1) % 5) + 1)
end
POS["J"] = POS["I"]

local function encode(input)
  local out = {}
  for c in input:upper():gmatch("[A-Z]") do
    out[#out + 1] = POS[c]
  end
  return table.concat(out, " ")
end

local function decode(input)
  local digits = input:gsub("[^1-5]", "")
  if #digits % 2 ~= 0 then
    error("polybius: stripped digit count (" .. #digits .. ") must be even")
  end
  local out = {}
  for i = 1, #digits, 2 do
    local r = tonumber(digits:sub(i,     i)) or 0
    local c = tonumber(digits:sub(i + 1, i + 1)) or 0
    local idx = (r - 1) * 5 + c
    if idx >= 1 and idx <= 25 then
      out[#out + 1] = SQUARE:sub(idx, idx)
    else
      out[#out + 1] = "?"
    end
  end
  return table.concat(out)
end

return {
  id = "polybius", label = "Polybius square", group = "Grid",
  encode = encode, decode = decode,
}
