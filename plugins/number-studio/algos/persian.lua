-- Persian / Extended Arabic-Indic digits ۰۱۲۳۴۵۶۷۸۹ (U+06F0..U+06F9).
-- Used in Persian, Urdu and other languages.
local U = require("lib.util")

local D = {}
for d = 0, 9 do D[d + 1] = utf8.char(0x06F0 + d) end

return {
  id = "persian", label = "Persian (Extended Arabic-Indic)", group = "Eastern Digits",
  encode = function(s) return U.digits_encode(s, D) end,
  decode = function(s) return U.digits_decode(s, D) end,
}
