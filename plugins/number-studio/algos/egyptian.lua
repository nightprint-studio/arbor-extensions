-- Egyptian hieroglyphic numerals (additive). Each power of 10 has a
-- distinct glyph, repeated as needed.
--   1       = 𓏺  U+133FA (stroke)
--   10      = 𓎆  U+13386 (heel bone)
--   100     = 𓍢  U+13362 (coiled rope)
--   1000    = 𓆼  U+131BC (lotus)
--   10000   = 𓂭  U+130AD (finger)
--   100000  = 𓆐  U+13190 (tadpole)
--   1000000 = 𓁨  U+13068 (Heh, god with raised arms)
-- Range supported: 1..9_999_999.

local U = require("lib.util")

local PAIRS = {
  {1000000, "\u{13068}"},
  {100000,  "\u{13190}"},
  {10000,   "\u{130AD}"},
  {1000,    "\u{131BC}"},
  {100,     "\u{13362}"},
  {10,      "\u{13386}"},
  {1,       "\u{133FA}"},
}

local function encode_one(line)
  local n = U.parse_int(line)
  if n < 1 or n > 9999999 then error("out of Egyptian range (1..9999999): " .. n) end
  local out = {}
  for _, p in ipairs(PAIRS) do
    while n >= p[1] do
      out[#out + 1] = p[2]
      n = n - p[1]
    end
  end
  return table.concat(out)
end

local function decode_one(line)
  line = line:gsub("%s", "")
  if line == "" then error("empty input") end
  local lookup = {}
  for _, p in ipairs(PAIRS) do lookup[p[2]] = p[1] end
  local total, i = 0, 1
  while i <= #line do
    local matched = nil
    for _, p in ipairs(PAIRS) do
      local g = p[2]
      if line:sub(i, i + #g - 1) == g then matched = g; break end
    end
    if not matched then error("invalid hieroglyph at byte " .. i) end
    total = total + lookup[matched]
    i = i + #matched
  end
  return tostring(total)
end

return {
  id = "egyptian", label = "Egyptian hieroglyphic", group = "Historical",
  hint = "additive, 1..9999999",
  encode = function(s) return U.per_line(s, encode_one) end,
  decode = function(s) return U.per_line(s, decode_one) end,
}
