-- Sexagesimal (base 60). Each base-60 digit (0..59) is written in
-- decimal and separated by commas — the standard scholarly convention
-- (e.g. 3661 = "1,1,1" = 1·3600 + 1·60 + 1).
local U = require("lib.util")

local function encode_one(line)
  local n = U.parse_int(line)
  if n == 0 then return "0" end
  local neg = n < 0
  if neg then n = -n end
  local parts = {}
  while n > 0 do
    parts[#parts + 1] = tostring(n % 60)
    n = n // 60
  end
  local rev = {}
  for i = #parts, 1, -1 do rev[#rev + 1] = parts[i] end
  return (neg and "-" or "") .. table.concat(rev, ",")
end

local function decode_one(line)
  line = line:gsub("%s", "")
  if line == "" then error("empty number") end
  local neg = false
  if line:sub(1, 1) == "-" then
    neg = true
    line = line:sub(2)
  end
  local n = 0
  for chunk in (line .. ","):gmatch("([^,]*),") do
    local d = tonumber(chunk)
    if not d then error("invalid digit: '" .. chunk .. "'") end
    if d < 0 or d >= 60 then error("digit out of range 0..59: " .. chunk) end
    n = n * 60 + d
  end
  if neg then n = -n end
  return tostring(n)
end

return {
  id = "sexagesimal", label = "Sexagesimal (base 60)", group = "Numeric Bases",
  hint = "digits separated by commas",
  encode = function(s) return U.per_line(s, encode_one) end,
  decode = function(s) return U.per_line(s, decode_one) end,
}
