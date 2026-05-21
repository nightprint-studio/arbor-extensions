-- Tibetan digits ༠༡༢༣༤༥༦༧༨༩ (U+0F20..U+0F29).
local U = require("lib.util")

local D = {}
for d = 0, 9 do D[d + 1] = utf8.char(0x0F20 + d) end

return {
  id = "tibetan", label = "Tibetan", group = "Eastern Digits",
  encode = function(s) return U.digits_encode(s, D) end,
  decode = function(s) return U.digits_decode(s, D) end,
}
