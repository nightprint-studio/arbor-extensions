-- Arabic-Indic digits ٠١٢٣٤٥٦٧٨٩ (U+0660..U+0669). Used in Arabic.
local U = require("lib.util")

local D = {}
for d = 0, 9 do D[d + 1] = utf8.char(0x0660 + d) end

return {
  id = "arabic_indic", label = "Arabic-Indic digits", group = "Eastern Digits",
  encode = function(s) return U.digits_encode(s, D) end,
  decode = function(s) return U.digits_decode(s, D) end,
}
