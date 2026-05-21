-- Vigesimal (base 20). Uses 0-9 then A..J for 10..19.
local U = require("lib.util")

return {
  id = "vigesimal", label = "Vigesimal (base 20)", group = "Numeric Bases",
  encode = function(s) return U.per_line(s, function(l) return U.to_base(U.parse_int(l), 20, {upper = true}) end) end,
  decode = function(s) return U.per_line(s, function(l) return tostring(U.from_base(l, 20)) end) end,
}
