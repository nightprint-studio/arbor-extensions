-- Octal (base 8). Positional, no key.
local U = require("lib.util")

return {
  id = "octal", label = "Octal (base 8)", group = "Numeric Bases",
  encode = function(s) return U.per_line(s, function(l) return U.to_base(U.parse_int(l), 8) end) end,
  decode = function(s) return U.per_line(s, function(l) return tostring(U.from_base(l, 8)) end) end,
}
