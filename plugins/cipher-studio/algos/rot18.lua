-- ROT18 — ROT13 on letters + ROT5 on digits. Self-inverse.

local function rot(s)
  s = s:gsub("[A-Za-z]", function(c)
    local b = c:byte()
    local base = (b >= 0x61) and 0x61 or 0x41
    return string.char(((b - base + 13) % 26) + base)
  end)
  s = s:gsub("%d", function(c)
    return string.char(0x30 + ((c:byte() - 0x30 + 5) % 10))
  end)
  return s
end

return {
  id = "rot18", label = "ROT18 (ROT13 + ROT5)", group = "Substitution",
  encode = rot, decode = rot,
}
