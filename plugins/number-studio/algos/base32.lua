-- Base32 numeric (positional). NOT RFC 4648 — that one is in cipher-studio
-- as an *encoding*. This one is a true positional radix.
local U = require("lib.util")

return {
  id = "base32", label = "Base32 (positional)", group = "Numeric Bases",
  encode = function(s) return U.per_line(s, function(l) return U.to_base(U.parse_int(l), 32, {upper = true}) end) end,
  decode = function(s) return U.per_line(s, function(l) return tostring(U.from_base(l, 32)) end) end,
}
