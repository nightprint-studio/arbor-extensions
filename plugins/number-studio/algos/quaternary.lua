-- Quaternary (base 4). Positional, no key.
local U = require("lib.util")

return {
  id = "quaternary", label = "Quaternary (base 4)", group = "Numeric Bases",
  encode = function(s) return U.per_line(s, function(l) return U.to_base(U.parse_int(l), 4) end) end,
  decode = function(s) return U.per_line(s, function(l) return tostring(U.from_base(l, 4)) end) end,
}
