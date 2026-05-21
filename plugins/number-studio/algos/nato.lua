-- NATO / aviation digit spelling (digit-by-digit), e.g.
--   123 → "One Two Three"
--   1024 → "One Zero Two Four"
-- "Niner" is used for 9 (to disambiguate from German "nein"),
-- "Fife" for 5 (to disambiguate from "fire" in heavy accents).

local U = require("lib.util")

local DIGITS = {
  [0]="Zero", "One", "Two", "Three", "Fower", "Fife",
  "Six", "Seven", "Eight", "Niner",
}

local LOOKUP = {}
for d, w in pairs(DIGITS) do LOOKUP[w:lower()] = d end
-- common civilian variants
LOOKUP["four"]  = 4
LOOKUP["five"]  = 5
LOOKUP["nine"]  = 9

local function encode_one(line)
  line = line:gsub("[%s,_]", "")
  if line == "" then error("empty input") end
  local neg = false
  if line:sub(1, 1) == "-" then
    neg = true
    line = line:sub(2)
  end
  if not line:match("^%d+$") then error("not an integer: " .. line) end
  local out = {}
  for i = 1, #line do
    out[#out + 1] = DIGITS[tonumber(line:sub(i, i))]
  end
  return (neg and "Minus " or "") .. table.concat(out, " ")
end

local function decode_one(line)
  local s = line:lower()
  local neg = false
  if s:match("^%s*minus%s") then neg = true; s = s:gsub("^%s*minus%s", "") end
  local out = {}
  for word in s:gmatch("%S+") do
    local d = LOOKUP[word]
    if not d then error("unknown word: " .. word) end
    out[#out + 1] = tostring(d)
  end
  if #out == 0 then error("empty input") end
  return (neg and "-" or "") .. table.concat(out)
end

return {
  id = "nato", label = "NATO digits", group = "Spelled Out",
  hint = "Zero One Two Three Fower Fife Six Seven Eight Niner",
  encode = function(s) return U.per_line(s, encode_one) end,
  decode = function(s) return U.per_line(s, decode_one) end,
}
