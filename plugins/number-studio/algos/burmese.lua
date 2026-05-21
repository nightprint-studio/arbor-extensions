-- Burmese / Myanmar digits ၀၁၂၃၄၅၆၇၈၉ (U+1040..U+1049).
local U = require("lib.util")

local D = {}
for d = 0, 9 do D[d + 1] = utf8.char(0x1040 + d) end

return {
  id = "burmese", label = "Burmese (Myanmar)", group = "Eastern Digits",
  encode = function(s) return U.digits_encode(s, D) end,
  decode = function(s) return U.digits_decode(s, D) end,
}
