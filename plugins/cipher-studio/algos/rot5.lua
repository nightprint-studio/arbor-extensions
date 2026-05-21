-- ROT5 — shift digits by 5. Self-inverse.

local function rot(s)
  return (s:gsub("%d", function(c)
    return string.char(0x30 + ((c:byte() - 0x30 + 5) % 10))
  end))
end

return {
  id = "rot5", label = "ROT5 (digits)", group = "Substitution",
  encode = rot, decode = rot,
}
