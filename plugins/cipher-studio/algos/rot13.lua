-- ROT13. Self-inverse, no key.

local function rot(s)
  return (s:gsub("[A-Za-z]", function(c)
    local b = c:byte()
    local base = (b >= 0x61) and 0x61 or 0x41
    return string.char(((b - base + 13) % 26) + base)
  end))
end

return {
  id = "rot13", label = "ROT13", group = "Substitution",
  encode = rot, decode = rot,
}
