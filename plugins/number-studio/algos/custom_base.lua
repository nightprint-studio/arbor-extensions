-- Custom positional base. Key = radix (integer 2..36).
local U = require("lib.util")

local function radix_of(key)
  local b = tonumber(key)
  if not b then error("base required (key must be 2..36)") end
  b = math.tointeger(b) or math.floor(b)
  if b < 2 or b > 36 then error("base must be in 2..36, got " .. b) end
  return b
end

return {
  id = "custom_base", label = "Custom base (2..36)", group = "Numeric Bases",
  key = { label = "Base", placeholder = "e.g. 7", default = "16" },
  encode = function(s, key)
    local b = radix_of(key)
    return U.per_line(s, function(l) return U.to_base(U.parse_int(l), b, {upper = true}) end)
  end,
  decode = function(s, key)
    local b = radix_of(key)
    return U.per_line(s, function(l) return tostring(U.from_base(l, b)) end)
  end,
}
