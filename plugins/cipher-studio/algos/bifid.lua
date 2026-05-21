-- Bifid cipher (Delastelle). 5×5 Polybius square (I/J merged), key = keyword.
-- Period = full message (classical full-period variant).

local function build_square(key)
  key = (key or ""):upper():gsub("J", "I"):gsub("[^A-Z]", "")
  local seen, sq = {}, {}
  local function push(c)
    if not seen[c] then seen[c] = true; sq[#sq + 1] = c end
  end
  for i = 1, #key do push(key:sub(i, i)) end
  for c in ("ABCDEFGHIKLMNOPQRSTUVWXYZ"):gmatch(".") do push(c) end
  local pos = {}
  for i = 1, 25 do pos[sq[i]] = i - 1 end
  return sq, pos
end

local function encode(s, key)
  local sq, pos = build_square(key)
  local cleaned = s:upper():gsub("J", "I"):gsub("[^A-Z]", "")
  local rows, cols = {}, {}
  for i = 1, #cleaned do
    local p = pos[cleaned:sub(i, i)]
    rows[i] = p // 5 + 1
    cols[i] = p %  5 + 1
  end
  local digits = {}
  for _, r in ipairs(rows) do digits[#digits + 1] = r end
  for _, c in ipairs(cols) do digits[#digits + 1] = c end
  local out = {}
  for i = 1, #cleaned do
    local r = digits[2 * i - 1] - 1
    local c = digits[2 * i]     - 1
    out[#out + 1] = sq[r * 5 + c + 1]
  end
  return table.concat(out)
end

local function decode(s, key)
  local sq, pos = build_square(key)
  local cleaned = s:upper():gsub("J", "I"):gsub("[^A-Z]", "")
  local digits = {}
  for i = 1, #cleaned do
    local p = pos[cleaned:sub(i, i)]
    digits[#digits + 1] = p // 5 + 1
    digits[#digits + 1] = p %  5 + 1
  end
  local n = #cleaned
  local out = {}
  for i = 1, n do
    local r = digits[i]     - 1
    local c = digits[n + i] - 1
    out[#out + 1] = sq[r * 5 + c + 1]
  end
  return table.concat(out)
end

return {
  id = "bifid", label = "Bifid (Delastelle)", group = "Bonus",
  key = { label = "Keyword", placeholder = "BGWKZQPNDSIOAXEFCLUMTHYVR", default = "BGWKZQPNDSIOAXEFCLUMTHYVR" },
  encode = encode, decode = decode,
}
