-- Unicode \uXXXX escape (JSON-style). No key.

local function encode(input)
  local out = {}
  for i = 1, #input do
    local b = string.byte(input, i)
    if b >= 0x20 and b <= 0x7E and b ~= 0x5C then
      out[#out + 1] = string.char(b)
    else
      out[#out + 1] = string.format("\\u%04X", b)
    end
  end
  return table.concat(out)
end

local function decode(input)
  local s = input:gsub("\\u(%x%x%x%x)", function(h)
    local n = tonumber(h, 16) or 0
    if n <= 0x7F then return string.char(n) end
    if n <= 0x7FF then
      return string.char(0xC0 | (n >> 6))
          .. string.char(0x80 | (n & 0x3F))
    end
    return string.char(0xE0 | (n >> 12))
        .. string.char(0x80 | ((n >> 6) & 0x3F))
        .. string.char(0x80 | (n & 0x3F))
  end)
  return s
end

return {
  id = "unicode_escape", label = "Unicode \\uXXXX", group = "Encoding",
  encode = encode, decode = decode,
}
