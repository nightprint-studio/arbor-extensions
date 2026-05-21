-- Base36 (positional, 0-9 then A-Z). The largest base built into util.lua.
local U = require("lib.util")

return {
  id = "base36", label = "Base36 (positional)", group = "Numeric Bases",
  encode = function(s) return U.per_line(s, function(l) return U.to_base(U.parse_int(l), 36, {upper = true}) end) end,
  decode = function(s) return U.per_line(s, function(l) return tostring(U.from_base(l, 36)) end) end,
}
