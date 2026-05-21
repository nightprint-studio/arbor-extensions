-- Gujarati digits ૦૧૨૩૪૫૬૭૮૯ (U+0AE6..U+0AEF).
local U = require("lib.util")

local D = {}
for d = 0, 9 do D[d + 1] = utf8.char(0x0AE6 + d) end

return {
  id = "gujarati", label = "Gujarati", group = "Eastern Digits",
  encode = function(s) return U.digits_encode(s, D) end,
  decode = function(s) return U.digits_decode(s, D) end,
}
