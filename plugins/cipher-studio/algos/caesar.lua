-- Caesar cipher. Key = integer shift (default 3).

local function shift_of(key)
  local n = tonumber(key)
  if not n then n = 3 end
  return ((n % 26) + 26) % 26
end

local function caesar(s, shift)
  return (s:gsub("[A-Za-z]", function(c)
    local b = c:byte()
    local base = (b >= 0x61) and 0x61 or 0x41
    return string.char(((b - base + shift) % 26) + base)
  end))
end

return {
  id = "caesar", label = "Caesar (custom shift)", group = "Substitution",
  key = { label = "Shift", placeholder = "integer (default 3)", default = "3" },
  encode = function(s, k) return caesar(s,  shift_of(k)) end,
  decode = function(s, k) return caesar(s, -shift_of(k)) end,
}
