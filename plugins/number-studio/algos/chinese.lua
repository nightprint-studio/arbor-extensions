-- Chinese numerals (simplified, modern). Range 0..(10^16 - 1).
--   digits:   零一二三四五六七八九
--   small:    十(10) 百(100) 千(1000)
--   big:      万(10^4) 亿(10^8) 兆(10^12)
-- Within a 4-digit block, internal zero-gaps collapse to a single 零;
-- the leading 一十 at the very start of the number is shortened to 十.

local U = require("lib.util")

local DIGITS    = { [0]="零", "一","二","三","四","五","六","七","八","九" }
local SMALL     = { "", "十", "百", "千" }
local BIG       = { "", "万", "亿", "兆" }  -- 10^0, 10^4, 10^8, 10^12

-- Encode 1..9999 (block size 4). Returns "" for 0.
local function block_to_zh(n, is_first_block)
  if n == 0 then return "" end
  local digits = { 0, 0, 0, 0 }
  for i = 1, 4 do
    digits[i] = n % 10
    n = n // 10
  end
  local out = ""
  local pending_zero = false
  for i = 4, 1, -1 do
    local d = digits[i]
    if d == 0 then
      pending_zero = true
    else
      if pending_zero and out ~= "" then
        out = out .. "零"
      end
      pending_zero = false
      out = out .. DIGITS[d] .. SMALL[i]
    end
  end
  -- "一十X" at the very start → "十X".
  if is_first_block and out:sub(1, #"一十") == "一十" then
    out = out:sub(#"一" + 1)
  end
  return out
end

local function encode_one(line)
  local n = U.parse_int(line)
  if n < 0 then error("Chinese numerals: negative not supported") end
  if n >= 10000000000000000 then error("too large (max 10^16 - 1)") end
  if n == 0 then return "零" end

  -- Split into 4-digit blocks, low-to-high.
  local blocks = {}
  while n > 0 do
    blocks[#blocks + 1] = n % 10000
    n = n // 10000
  end
  -- Emit high-to-low, joining with 万/亿/兆.
  local out = ""
  for i = #blocks, 1, -1 do
    local first = (out == "")
    local txt = block_to_zh(blocks[i], first)
    if txt ~= "" then
      out = out .. txt .. BIG[i]
    elseif out ~= "" and out:sub(-#"零") ~= "零" then
      out = out .. "零"
    end
  end
  return out
end

-- ── decoder ──────────────────────────────────────────────────────────────
local VAL = {
  ["零"]=0,["〇"]=0,
  ["一"]=1,["二"]=2,["三"]=3,["四"]=4,["五"]=5,
  ["六"]=6,["七"]=7,["八"]=8,["九"]=9,["两"]=2,
}
local SMALL_M = { ["十"]=10, ["百"]=100, ["千"]=1000 }
local BIG_M   = { ["万"]=10000, ["亿"]=10^8, ["兆"]=10^12 }

local function utf8_chars(s)
  local out = {}
  for _, cp in utf8.codes(s) do out[#out + 1] = utf8.char(cp) end
  return out
end

local function decode_one(line)
  line = line:gsub("%s", "")
  if line == "" then error("empty input") end
  local chars = utf8_chars(line)
  -- Walk a section between big multipliers, accumulating into a 4-digit total.
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
      last_digit = VAL[c]
      if c == "零" or c == "〇" then last_digit = nil end
    elseif SMALL_M[c] then
      local d = last_digit or 1  -- leading 十 means 一十
      section = section + d * SMALL_M[c]
      last_digit = nil
    elseif BIG_M[c] then
      flush(BIG_M[c])
    else
      error("unknown Chinese numeral character: " .. c)
    end
  end
  flush(1)
  return tostring(math.tointeger(total) or total)
end

return {
  id = "chinese", label = "Chinese (simplified)", group = "East Asian",
  hint = "0..10^16-1",
  encode = function(s) return U.per_line(s, encode_one) end,
  decode = function(s) return U.per_line(s, decode_one) end,
}
