-- Base32 (RFC 4648). No key.
local CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

local LOOKUP = {}
for i = 1, #CHARS do LOOKUP[CHARS:sub(i, i)] = i - 1 end

local PAD = { 0, 6, 4, 3, 1 } -- pad chars for input length mod 5 == {0,1,2,3,4}

local function encode(input)
  if input == "" then return "" end
  local out = {}
  local i = 1
  while i <= #input do
    local b = {}
    for k = 0, 4 do b[k + 1] = string.byte(input, i + k) or 0 end
    local n = (b[1] << 32) | (b[2] << 24) | (b[3] << 16) | (b[4] << 8) | b[5]
    out[#out + 1] = CHARS:sub(((n >> 35) & 0x1F) + 1, ((n >> 35) & 0x1F) + 1)
    out[#out + 1] = CHARS:sub(((n >> 30) & 0x1F) + 1, ((n >> 30) & 0x1F) + 1)
    out[#out + 1] = CHARS:sub(((n >> 25) & 0x1F) + 1, ((n >> 25) & 0x1F) + 1)
    out[#out + 1] = CHARS:sub(((n >> 20) & 0x1F) + 1, ((n >> 20) & 0x1F) + 1)
    out[#out + 1] = CHARS:sub(((n >> 15) & 0x1F) + 1, ((n >> 15) & 0x1F) + 1)
    out[#out + 1] = CHARS:sub(((n >> 10) & 0x1F) + 1, ((n >> 10) & 0x1F) + 1)
    out[#out + 1] = CHARS:sub(((n >>  5) & 0x1F) + 1, ((n >>  5) & 0x1F) + 1)
    out[#out + 1] = CHARS:sub(( n        & 0x1F) + 1, ( n        & 0x1F) + 1)
    i = i + 5
  end
  -- Trim and pad according to original length
  local pad = PAD[(#input % 5) + 1]
  if pad > 0 then
    local s = table.concat(out)
    s = s:sub(1, #s - pad) .. string.rep("=", pad)
    return s
  end
  return table.concat(out)
end

local function decode(input)
  input = input:upper():gsub("[^A-Z2-7=]", "")
  if input == "" then return "" end
  local out = {}
  local i = 1
  while i <= #input do
    local s = {}
    for k = 0, 7 do s[k + 1] = input:sub(i + k, i + k) end
    local n = 0
    local last = 8
    for k = 1, 8 do
      if s[k] == "=" or s[k] == "" then last = k - 1; break end
      n = (n << 5) | (LOOKUP[s[k]] or 0)
    end
    -- left-shift to align 40 bits
    n = n << ((8 - last) * 5)
    out[#out + 1] = string.char((n >> 32) & 0xFF)
    if last >= 4 then out[#out + 1] = string.char((n >> 24) & 0xFF) end
    if last >= 5 then out[#out + 1] = string.char((n >> 16) & 0xFF) end
    if last >= 7 then out[#out + 1] = string.char((n >>  8) & 0xFF) end
    if last == 8 then out[#out + 1] = string.char( n        & 0xFF) end
    i = i + 8
  end
  return table.concat(out)
end

return {
  id = "base32", label = "Base32", group = "Encoding",
  encode = encode, decode = decode,
}
