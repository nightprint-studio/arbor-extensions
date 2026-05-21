-- Beaufort cipher. E(x) = (k - x) mod 26. Self-inverse, key = keyword.

local function run(s, key)
  local shifts = {}
  for c in (key or ""):upper():gmatch("[A-Z]") do
    shifts[#shifts + 1] = c:byte() - 0x41
  end
  if #shifts == 0 then error("beaufort: key must contain at least one letter") end
  local out, ki = {}, 0
  for i = 1, #s do
    local c = s:sub(i, i)
    local b = c:byte()
    if (b >= 0x41 and b <= 0x5A) or (b >= 0x61 and b <= 0x7A) then
      local base = (b >= 0x61) and 0x61 or 0x41
      local k = shifts[(ki % #shifts) + 1]
      out[i] = string.char(((k - (b - base)) % 26 + 26) % 26 + base)
      ki = ki + 1
    else
      out[i] = c
    end
  end
  return table.concat(out)
end

return {
  id = "beaufort", label = "Beaufort", group = "Substitution",
  key = { label = "Keyword", placeholder = "FORTIFICATION", default = "FORTIFICATION" },
  encode = run, decode = run,
}
