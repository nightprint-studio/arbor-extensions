-- Base16 / Hex. No key.

local function encode(input)
  local out = {}
  for i = 1, #input do
    out[i] = string.format("%02X", string.byte(input, i))
  end
  return table.concat(out)
end

local function decode(input)
  input = input:gsub("[^0-9A-Fa-f]", "")
  if #input % 2 ~= 0 then
    error("hex input has odd length")
  end
  local out = {}
  for i = 1, #input, 2 do
    out[#out + 1] = string.char(tonumber(input:sub(i, i + 1), 16))
  end
  return table.concat(out)
end

return {
  id = "base16", label = "Base16 / Hex", group = "Encoding",
  encode = encode, decode = decode,
}
