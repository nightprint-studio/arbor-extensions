-- Autokey cipher — Vigenère where the plaintext extends the key.

local function letters_of(s)
  local out = {}
  for c in s:upper():gmatch("[A-Z]") do out[#out + 1] = c:byte() - 0x41 end
  return out
end

local function encode(s, key)
  local key_buf = letters_of(key or "")
  if #key_buf == 0 then error("autokey: key must contain at least one letter") end
  local out, ki = {}, 0
  for i = 1, #s do
    local c = s:sub(i, i)
    local b = c:byte()
    if (b >= 0x41 and b <= 0x5A) or (b >= 0x61 and b <= 0x7A) then
      local base = (b >= 0x61) and 0x61 or 0x41
      local x    = b - base
      local k    = key_buf[ki + 1]
      out[i] = string.char(((x + k) % 26) + base)
      key_buf[#key_buf + 1] = x -- extend with plaintext letter
      ki = ki + 1
    else
      out[i] = c
    end
  end
  return table.concat(out)
end

local function decode(s, key)
  local key_buf = letters_of(key or "")
  if #key_buf == 0 then error("autokey: key must contain at least one letter") end
  local out, ki = {}, 0
  for i = 1, #s do
    local c = s:sub(i, i)
    local b = c:byte()
    if (b >= 0x41 and b <= 0x5A) or (b >= 0x61 and b <= 0x7A) then
      local base = (b >= 0x61) and 0x61 or 0x41
      local y    = b - base
      local k    = key_buf[ki + 1]
      local x    = (y - k + 26) % 26
      out[i] = string.char(x + base)
      key_buf[#key_buf + 1] = x -- recovered plaintext extends the key
      ki = ki + 1
    else
      out[i] = c
    end
  end
  return table.concat(out)
end

return {
  id = "autokey", label = "Autokey (Vigenère)", group = "Substitution",
  key = { label = "Keyword", placeholder = "QUEENLY", default = "QUEENLY" },
  encode = encode, decode = decode,
}
