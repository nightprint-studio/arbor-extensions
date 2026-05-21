-- Scytale cipher — wrap the message around a rod of given diameter
-- (= number of columns). Pad with 'X' so the grid is rectangular.

local function parse_diameter(k)
  local n = tonumber(k) or 4
  if n < 2 then n = 2 end
  return math.floor(n)
end

local function encode(s, key)
  local cols = parse_diameter(key)
  local rows = math.ceil(#s / cols)
  local padded = s .. string.rep("X", rows * cols - #s)
  local out = {}
  for c = 1, cols do
    for r = 1, rows do
      out[#out + 1] = padded:sub((r - 1) * cols + c, (r - 1) * cols + c)
    end
  end
  return table.concat(out)
end

local function decode(s, key)
  local cols = parse_diameter(key)
  local rows = math.ceil(#s / cols)
  if rows * cols ~= #s then
    error("scytale: ciphertext length must be a multiple of diameter " ..
          "(got " .. #s .. ", expected multiple of " .. cols .. ")")
  end
  local grid = {}
  for c = 1, cols do
    grid[c] = s:sub((c - 1) * rows + 1, c * rows)
  end
  local out = {}
  for r = 1, rows do
    for c = 1, cols do
      out[#out + 1] = grid[c]:sub(r, r)
    end
  end
  return table.concat(out)
end

return {
  id = "scytale", label = "Scytale", group = "Transposition",
  key = { label = "Diameter", placeholder = "integer ≥ 2 (default 4)", default = "4" },
  encode = encode, decode = decode,
}
