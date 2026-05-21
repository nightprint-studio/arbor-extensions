-- Devanagari digits ०१२३४५६७८९ (U+0966..U+096F). Used in Hindi, Sanskrit
-- and many other Indian languages.
local U = require("lib.util")

local D = {}
for d = 0, 9 do D[d + 1] = utf8.char(0x0966 + d) end

return {
  id = "devanagari", label = "Devanagari", group = "Eastern Digits",
  encode = function(s) return U.digits_encode(s, D) end,
  decode = function(s) return U.digits_decode(s, D) end,
}
