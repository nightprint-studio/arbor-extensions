-- Duodecimal (base 12). Uses 0-9 then A,B for 10/11.
local U = require("lib.util")

return {
  id = "duodecimal", label = "Duodecimal (base 12)", group = "Numeric Bases",
  encode = function(s) return U.per_line(s, function(l) return U.to_base(U.parse_int(l), 12, {upper = true}) end) end,
  decode = function(s) return U.per_line(s, function(l) return tostring(U.from_base(l, 12)) end) end,
}
