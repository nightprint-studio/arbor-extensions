-- Senary (base 6). Positional, no key.
local U = require("lib.util")

return {
  id = "senary", label = "Senary (base 6)", group = "Numeric Bases",
  encode = function(s) return U.per_line(s, function(l) return U.to_base(U.parse_int(l), 6) end) end,
  decode = function(s) return U.per_line(s, function(l) return tostring(U.from_base(l, 6)) end) end,
}
