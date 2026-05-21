-- Vigenère cipher. Key = keyword (letters only).

local function key_shifts(key)
  local shifts = {}
  for c in key:upper():gmatch("[A-Z]") do
    shifts[#shifts + 1] = c:byte() - 0x41
  end
  return shifts
end

local function run(s, key, sign)
  local shifts = key_shifts(key or "")
  if #shifts == 0 then error("vigenère: key must contain at least one letter") end
  local out, ki = {}, 0
  for i = 1, #s do
    local c = s:sub(i, i)
    local b = c:byte()
    if (b >= 0x41 and b <= 0x5A) or (b >= 0x61 and b <= 0x7A) then
      local base = (b >= 0x61) and 0x61 or 0x41
      local shift = shifts[(ki % #shifts) + 1] * sign
      out[i] = string.char(((b - base + shift) % 26 + 26) % 26 + base)
      ki = ki + 1
    else
      out[i] = c
    end
  end
  return table.concat(out)
end

return {
  id = "vigenere", label = "Vigenère", group = "Substitution",
  key = { label = "Keyword", placeholder = "LEMON", default = "LEMON" },
  encode = function(s, k) return run(s, k,  1) end,
  decode = function(s, k) return run(s, k, -1) end,
}
