-- Octal (3-digit groups, space-separated). No key.

local function encode(input)
  local out = {}
  for i = 1, #input do
    out[i] = string.format("%03o", string.byte(input, i))
  end
  return table.concat(out, " ")
end

local function decode(input)
  local out = {}
  for tok in input:gmatch("[0-7]+") do
    local n = tonumber(tok, 8)
    if n and n >= 0 and n <= 255 then
      out[#out + 1] = string.char(n)
    end
  end
  return table.concat(out)
end

return {
  id = "octal", label = "Octal", group = "Encoding",
  encode = encode, decode = decode,
}
