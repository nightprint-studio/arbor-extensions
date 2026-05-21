-- Decimal ASCII (space-separated code points). No key.

local function encode(input)
  local out = {}
  for i = 1, #input do
    out[i] = tostring(string.byte(input, i))
  end
  return table.concat(out, " ")
end

local function decode(input)
  local out = {}
  for tok in input:gmatch("%d+") do
    local n = tonumber(tok)
    if n and n >= 0 and n <= 0x10FFFF then
      if n <= 127 then
        out[#out + 1] = string.char(n)
      else
        -- Re-encode as UTF-8 so non-ASCII code points round-trip via
        -- unicode-escape and html-entities decoders too.
        if n <= 0x7FF then
          out[#out + 1] = string.char(0xC0 | (n >> 6))
          out[#out + 1] = string.char(0x80 | (n & 0x3F))
        elseif n <= 0xFFFF then
          out[#out + 1] = string.char(0xE0 | (n >> 12))
          out[#out + 1] = string.char(0x80 | ((n >> 6) & 0x3F))
          out[#out + 1] = string.char(0x80 | (n & 0x3F))
        else
          out[#out + 1] = string.char(0xF0 | (n >> 18))
          out[#out + 1] = string.char(0x80 | ((n >> 12) & 0x3F))
          out[#out + 1] = string.char(0x80 | ((n >>  6) & 0x3F))
          out[#out + 1] = string.char(0x80 | (n & 0x3F))
        end
      end
    end
  end
  return table.concat(out)
end

return {
  id = "ascii_decimal", label = "Decimal ASCII", group = "Encoding",
  encode = encode, decode = decode,
}
