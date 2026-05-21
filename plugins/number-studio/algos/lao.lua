-- Lao digits ໐໑໒໓໔໕໖໗໘໙ (U+0ED0..U+0ED9).
local U = require("lib.util")

local D = {}
for d = 0, 9 do D[d + 1] = utf8.char(0x0ED0 + d) end

return {
  id = "lao", label = "Lao", group = "Eastern Digits",
  encode = function(s) return U.digits_encode(s, D) end,
  decode = function(s) return U.digits_decode(s, D) end,
}
