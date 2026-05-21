-- Binary (base 2). Positional, no key.
local U = require("lib.util")

return {
  id = "binary", label = "Binary (base 2)", group = "Numeric Bases",
  encode = function(s) return U.per_line(s, function(l) return U.to_base(U.parse_int(l), 2) end) end,
  decode = function(s) return U.per_line(s, function(l) return tostring(U.from_base(l, 2)) end) end,
}
