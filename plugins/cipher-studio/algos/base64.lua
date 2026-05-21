-- Base64 (RFC 4648). No key.
local CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local LOOKUP = {}
for i = 1, #CHARS do LOOKUP[CHARS:sub(i, i)] = i - 1 end

local function encode(input)
  if input == "" then return "" end
  local out = {}
  local i = 1
  while i <= #input do
    local b1 = string.byte(input, i) or 0
    local b2 = string.byte(input, i + 1) or 0
    local b3 = string.byte(input, i + 2) or 0
    local triplet = (b1 << 16) | (b2 << 8) | b3
    out[#out + 1] = CHARS:sub(((triplet >> 18) & 0x3F) + 1, ((triplet >> 18) & 0x3F) + 1)
    out[#out + 1] = CHARS:sub(((triplet >> 12) & 0x3F) + 1, ((triplet >> 12) & 0x3F) + 1)
    out[#out + 1] = (i + 1 <= #input)
      and CHARS:sub(((triplet >> 6) & 0x3F) + 1, ((triplet >> 6) & 0x3F) + 1) or "="
    out[#out + 1] = (i + 2 <= #input)
      and CHARS:sub((triplet & 0x3F) + 1, (triplet & 0x3F) + 1) or "="
    i = i + 3
  end
  return table.concat(out)
end

local function decode(input)
  input = input:gsub("[^A-Za-z0-9+/=]", "")
  if input == "" then return "" end
  local out = {}
  local i = 1
  while i <= #input do
    local s1 = input:sub(i,     i)
    local s2 = input:sub(i + 1, i + 1)
    local s3 = input:sub(i + 2, i + 2)
    local s4 = input:sub(i + 3, i + 3)
    local n1 = LOOKUP[s1] or 0
    local n2 = LOOKUP[s2] or 0
    local n3 = LOOKUP[s3] or 0
    local n4 = LOOKUP[s4] or 0
    local triplet = (n1 << 18) | (n2 << 12) | (n3 << 6) | n4
    out[#out + 1] = string.char((triplet >> 16) & 0xFF)
    if s3 ~= "=" and s3 ~= "" then
      out[#out + 1] = string.char((triplet >> 8) & 0xFF)
    end
    if s4 ~= "=" and s4 ~= "" then
      out[#out + 1] = string.char(triplet & 0xFF)
    end
    i = i + 4
  end
  return table.concat(out)
end

return {
  id = "base64", label = "Base64", group = "Encoding",
  encode = encode, decode = decode,
}
