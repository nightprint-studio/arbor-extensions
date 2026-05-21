-- Thai digits ๐๑๒๓๔๕๖๗๘๙ (U+0E50..U+0E59).
local U = require("lib.util")

local D = {}
for d = 0, 9 do D[d + 1] = utf8.char(0x0E50 + d) end

return {
  id = "thai", label = "Thai", group = "Eastern Digits",
  encode = function(s) return U.digits_encode(s, D) end,
  decode = function(s) return U.digits_decode(s, D) end,
}
