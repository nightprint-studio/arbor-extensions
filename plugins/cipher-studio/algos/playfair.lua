-- Playfair cipher (5×5 keyed grid, I/J merged). Key = keyword.
-- Pad rule: identical pair → insert 'X'. Odd length → append 'X'.

local function build_grid(key)
  key = (key or ""):upper():gsub("J", "I"):gsub("[^A-Z]", "")
  local seen, grid = {}, {}
  local function push(c)
    if not seen[c] then seen[c] = true; grid[#grid + 1] = c end
  end
  for i = 1, #key do push(key:sub(i, i)) end
  for c in ("ABCDEFGHIKLMNOPQRSTUVWXYZ"):gmatch(".") do push(c) end
  -- position lookup
  local pos = {}
  for i = 1, 25 do pos[grid[i]] = i - 1 end
  return grid, pos
end

local function prep_pairs(s)
  s = s:upper():gsub("J", "I"):gsub("[^A-Z]", "")
  local pairs_ = {}
  local i = 1
  while i <= #s do
    local a = s:sub(i, i)
    local b = s:sub(i + 1, i + 1)
    if b == "" then
      pairs_[#pairs_ + 1] = { a, "X" }; i = i + 1
    elseif a == b then
      pairs_[#pairs_ + 1] = { a, "X" }; i = i + 1
    else
      pairs_[#pairs_ + 1] = { a, b }; i = i + 2
    end
  end
  return pairs_
end

local function transform(s, key, sign)
  local grid, pos = build_grid(key)
  local out = {}
  for _, pr in ipairs(prep_pairs(s)) do
    local a, b = pr[1], pr[2]
    local ra, ca = pos[a] // 5, pos[a] % 5
    local rb, cb = pos[b] // 5, pos[b] % 5
    if ra == rb then
      ca = (ca + sign) % 5; cb = (cb + sign) % 5
    elseif ca == cb then
      ra = (ra + sign) % 5; rb = (rb + sign) % 5
    else
      ca, cb = cb, ca
    end
    out[#out + 1] = grid[ra * 5 + ca + 1]
    out[#out + 1] = grid[rb * 5 + cb + 1]
  end
  return table.concat(out)
end

return {
  id = "playfair", label = "Playfair", group = "Bonus",
  key = { label = "Keyword", placeholder = "MONARCHY", default = "MONARCHY" },
  encode = function(s, k) return transform(s, k,  1) end,
  decode = function(s, k) return transform(s, k, -1) end,
}
