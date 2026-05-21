-- Chinese financial (大写) numerals — the anti-fraud forms used on
-- cheques and contracts. Same algorithm as the standard form, just
-- different glyphs.
--   digits:   零壹贰叁肆伍陆柒捌玖
--   small:    拾(10) 佰(100) 仟(1000)
--   big:      萬(10^4) 億(10^8) 兆(10^12)

local U = require("lib.util")

local DIGITS = { [0]="零", "壹","贰","叁","肆","伍","陆","柒","捌","玖" }
local SMALL  = { "", "拾", "佰", "仟" }
local BIG    = { "", "萬", "億", "兆" }

local function block(n, is_first)
  if n == 0 then return "" end
  local d = { 0, 0, 0, 0 }
  for i = 1, 4 do d[i] = n % 10; n = n // 10 end
  local out, pending_zero = "", false
  for i = 4, 1, -1 do
    if d[i] == 0 then
      pending_zero = true
    else
      if pending_zero and out ~= "" then out = out .. "零" end
      pending_zero = false
      out = out .. DIGITS[d[i]] .. SMALL[i]
    end
  end
  if is_first and out:sub(1, #"壹拾") == "壹拾" then
    out = out:sub(#"壹" + 1)
  end
  return out
end

local function encode_one(line)
  local n = U.parse_int(line)
  if n < 0 then error("Chinese financial: negative not supported") end
  if n >= 10000000000000000 then error("too large (max 10^16 - 1)") end
  if n == 0 then return "零" end
  local blocks = {}
  while n > 0 do
    blocks[#blocks + 1] = n % 10000
    n = n // 10000
  end
  local out = ""
  for i = #blocks, 1, -1 do
    local first = (out == "")
    local txt = block(blocks[i], first)
    if txt ~= "" then
      out = out .. txt .. BIG[i]
    elseif out ~= "" and out:sub(-#"零") ~= "零" then
      out = out .. "零"
    end
  end
  return out
end

local VAL = {
  ["零"]=0,
  ["壹"]=1,["贰"]=2,["貳"]=2,["叁"]=3,["參"]=3,["肆"]=4,["伍"]=5,
  ["陆"]=6,["陸"]=6,["柒"]=7,["捌"]=8,["玖"]=9,
}
local SMALL_M = { ["拾"]=10, ["佰"]=100, ["仟"]=1000 }
local BIG_M   = { ["萬"]=10000, ["万"]=10000, ["億"]=10^8, ["亿"]=10^8, ["兆"]=10^12 }

local function utf8_chars(s)
  local out = {}
  for _, cp in utf8.codes(s) do out[#out + 1] = utf8.char(cp) end
  return out
end

local function decode_one(line)
  line = line:gsub("%s", "")
  if line == "" then error("empty input") end
  local chars = utf8_chars(line)
  local total = 0
  local section, last_digit = 0, nil
  local function flush(big_mul)
    if last_digit then section = section + last_digit end
    last_digit = nil
    total = total + section * (big_mul or 1)
    section = 0
  end
  for _, c in ipairs(chars) do
    if VAL[c] then
      if c == "零" then last_digit = nil else last_digit = VAL[c] end
    elseif SMALL_M[c] then
      local d = last_digit or 1
      section = section + d * SMALL_M[c]
      last_digit = nil
    elseif BIG_M[c] then
      flush(BIG_M[c])
    else
      error("unknown character: " .. c)
    end
  end
  flush(1)
  return tostring(math.tointeger(total) or total)
end

return {
  id = "chinese_financial", label = "Chinese financial (大写)", group = "East Asian",
  hint = "0..10^16-1",
  encode = function(s) return U.per_line(s, encode_one) end,
  decode = function(s) return U.per_line(s, decode_one) end,
}
