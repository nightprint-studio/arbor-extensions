-- Atbash: A↔Z, B↔Y, … Self-inverse, no key.

local function atbash(s)
  return (s:gsub("[A-Za-z]", function(c)
    local b = c:byte()
    if b >= 0x61 then return string.char(0x61 + 0x7A - b)
    else               return string.char(0x41 + 0x5A - b) end
  end))
end

return {
  id = "atbash", label = "Atbash", group = "Substitution",
  encode = atbash, decode = atbash,
}
