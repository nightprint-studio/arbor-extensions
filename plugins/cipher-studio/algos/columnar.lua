-- Columnar transposition. Key = keyword; columns are read in the order
-- their letters sort alphabetically (ties broken by original position).
-- Pad character on encode: 'X'.

local function order_from_key(key)
  key = (key or ""):upper():gsub("[^A-Z]", "")
  if #key == 0 then error("columnar: key must contain at least one letter") end
  local cols = {}
  for i = 1, #key do cols[i] = { letter = key:sub(i, i), pos = i } end
  table.sort(cols, function(a, b)
    if a.letter == b.letter then return a.pos < b.pos end
    return a.letter < b.letter
  end)
  local read_order = {}
  for i = 1, #cols do read_order[i] = cols[i].pos end
  return read_order, #key
end

local function encode(s, key)
  local read_order, cols = order_from_key(key)
  local rows = math.ceil(#s / cols)
  local padded = s .. string.rep("X", rows * cols - #s)
  local grid = {}
  for r = 1, rows do
    grid[r] = padded:sub((r - 1) * cols + 1, r * cols)
  end
  local out = {}
  for _, c in ipairs(read_order) do
    for r = 1, rows do
      out[#out + 1] = grid[r]:sub(c, c)
    end
  end
  return table.concat(out)
end

local function decode(s, key)
  local read_order, cols = order_from_key(key)
  local rows = math.ceil(#s / cols)
  if rows * cols ~= #s then
    error("columnar: ciphertext length must be a multiple of key length " ..
          "(got " .. #s .. ", expected multiple of " .. cols .. ")")
  end
  local col_contents = {}
  for idx, c in ipairs(read_order) do
    col_contents[c] = s:sub((idx - 1) * rows + 1, idx * rows)
  end
  local out = {}
  for r = 1, rows do
    for c = 1, cols do
      out[#out + 1] = col_contents[c]:sub(r, r)
    end
  end
  return table.concat(out)
end

return {
  id = "columnar", label = "Columnar transposition", group = "Transposition",
  key = { label = "Keyword", placeholder = "ZEBRAS", default = "ZEBRAS" },
  encode = encode, decode = decode,
}
