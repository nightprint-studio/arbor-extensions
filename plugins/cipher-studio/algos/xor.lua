-- Repeating-key XOR. Ciphertext is rendered as uppercase hex on encode;
-- decode accepts whitespace-tolerant hex and returns the original text.

local function xor_bytes(input, key)
  if key == nil or key == "" then error("xor: key must not be empty") end
  local out = {}
  for i = 1, #input do
    local k = key:byte(((i - 1) % #key) + 1)
    out[i] = string.char(input:byte(i) ~ k)
  end
  return table.concat(out)
end

local function to_hex(s)
  local out = {}
  for i = 1, #s do out[i] = string.format("%02X", s:byte(i)) end
  return table.concat(out)
end

local function from_hex(s)
  s = s:gsub("[^0-9A-Fa-f]", "")
  if #s % 2 ~= 0 then error("xor: hex input has odd length") end
  local out = {}
  for i = 1, #s, 2 do out[#out + 1] = string.char(tonumber(s:sub(i, i + 1), 16)) end
  return table.concat(out)
end

return {
  id = "xor", label = "XOR (repeating key, hex output)", group = "Bonus",
  key = { label = "Key", placeholder = "any non-empty string", default = "secret" },
  encode = function(s, k) return to_hex(xor_bytes(s, k or "")) end,
  decode = function(s, k) return xor_bytes(from_hex(s), k or "") end,
}
