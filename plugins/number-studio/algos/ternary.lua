-- Ternary (base 3). Positional, no key.
local U = require("lib.util")

return {
  id = "ternary", label = "Ternary (base 3)", group = "Numeric Bases",
  encode = function(s) return U.per_line(s, function(l) return U.to_base(U.parse_int(l), 3) end) end,
  decode = function(s) return U.per_line(s, function(l) return tostring(U.from_base(l, 3)) end) end,
}
