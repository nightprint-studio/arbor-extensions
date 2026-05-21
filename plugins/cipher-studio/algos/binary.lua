-- Binary (8-bit groups, space-separated). No key.

local function byte_to_bits(b)
  local out = {}
  for i = 7, 0, -1 do
    out[#out + 1] = ((b >> i) & 1) == 1 and "1" or "0"
  end
  return table.concat(out)
end

local function encode(input)
  local out = {}
  for i = 1, #input do
    out[i] = byte_to_bits(string.byte(input, i))
  end
  return table.concat(out, " ")
end

local function decode(input)
  input = input:gsub("[^01]", "")
  if #input % 8 ~= 0 then
    error("binary input length must be a multiple of 8 (got " .. #input .. ")")
  end
  local out = {}
  for i = 1, #input, 8 do
    out[#out + 1] = string.char(tonumber(input:sub(i, i + 7), 2))
  end
  return table.concat(out)
end

return {
  id = "binary", label = "Binary", group = "Encoding",
  encode = encode, decode = decode,
}
