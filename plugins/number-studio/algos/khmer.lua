-- Khmer digits ០១២៣៤៥៦៧៨៩ (U+17E0..U+17E9). Used in Cambodian.
local U = require("lib.util")

local D = {}
for d = 0, 9 do D[d + 1] = utf8.char(0x17E0 + d) end

return {
  id = "khmer", label = "Khmer", group = "Eastern Digits",
  encode = function(s) return U.digits_encode(s, D) end,
  decode = function(s) return U.digits_decode(s, D) end,
}
