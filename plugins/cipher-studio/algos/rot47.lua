-- ROT47 — rotate by 47 across the printable ASCII range 33..126. Self-inverse.

local function rot(s)
  local out = {}
  for i = 1, #s do
    local b = s:byte(i)
    if b >= 33 and b <= 126 then
      out[i] = string.char(33 + ((b - 33 + 47) % 94))
    else
      out[i] = string.char(b)
    end
  end
  return table.concat(out)
end

return {
  id = "rot47", label = "ROT47", group = "Substitution",
  encode = rot, decode = rot,
}
