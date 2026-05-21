-- Tamil digits ௦௧௨௩௪௫௬௭௮௯ (U+0BE6..U+0BEF). Modern Tamil typically uses
-- Hindu-Arabic digits, but the historical Tamil digits are still encoded.
local U = require("lib.util")

local D = {}
for d = 0, 9 do D[d + 1] = utf8.char(0x0BE6 + d) end

return {
  id = "tamil", label = "Tamil", group = "Eastern Digits",
  encode = function(s) return U.digits_encode(s, D) end,
  decode = function(s) return U.digits_decode(s, D) end,
}
