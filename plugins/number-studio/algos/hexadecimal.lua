-- Hexadecimal (base 16). Uppercase digits.
local U = require("lib.util")

return {
  id = "hexadecimal", label = "Hexadecimal (base 16)", group = "Numeric Bases",
  encode = function(s) return U.per_line(s, function(l) return U.to_base(U.parse_int(l), 16, {upper = true}) end) end,
  decode = function(s) return U.per_line(s, function(l) return tostring(U.from_base(l, 16)) end) end,
}
