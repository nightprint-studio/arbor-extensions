-- Bengali digits ০১২৩৪৫৬৭৮৯ (U+09E6..U+09EF). Also used in Assamese.
local U = require("lib.util")

local D = {}
for d = 0, 9 do D[d + 1] = utf8.char(0x09E6 + d) end

return {
  id = "bengali", label = "Bengali", group = "Eastern Digits",
  encode = function(s) return U.digits_encode(s, D) end,
  decode = function(s) return U.digits_decode(s, D) end,
}
