-- Rail fence cipher. Key = number of rails (integer ≥ 2).

local function parse_rails(k)
  local n = tonumber(k) or 3
  if n < 2 then n = 2 end
  return math.floor(n)
end

-- Build the zig-zag rail index (0..rails-1) for each character position.
local function pattern(len, rails)
  local out = {}
  local r, dir = 0, 1
  for i = 1, len do
    out[i] = r
    if rails == 1 then r = 0
    else
      r = r + dir
      if r == 0 or r == rails - 1 then dir = -dir end
    end
  end
  return out
end

local function encode(s, key)
  local rails = parse_rails(key)
  local pat = pattern(#s, rails)
  local buckets = {}
  for r = 0, rails - 1 do buckets[r] = {} end
  for i = 1, #s do
    local b = buckets[pat[i]]
    b[#b + 1] = s:sub(i, i)
  end
  local out = {}
  for r = 0, rails - 1 do
    out[#out + 1] = table.concat(buckets[r])
  end
  return table.concat(out)
end

local function decode(s, key)
  local rails = parse_rails(key)
  local pat = pattern(#s, rails)
  -- Count chars per rail to figure out where each rail starts in `s`.
  local counts = {}
  for r = 0, rails - 1 do counts[r] = 0 end
  for i = 1, #s do counts[pat[i]] = counts[pat[i]] + 1 end
  local starts, acc = {}, 1
  for r = 0, rails - 1 do
    starts[r] = acc
    acc = acc + counts[r]
  end
  local cursor = {}
  for r = 0, rails - 1 do cursor[r] = 0 end
  local out = {}
  for i = 1, #s do
    local r = pat[i]
    local idx = starts[r] + cursor[r]
    out[i] = s:sub(idx, idx)
    cursor[r] = cursor[r] + 1
  end
  return table.concat(out)
end

return {
  id = "rail_fence", label = "Rail fence", group = "Transposition",
  key = { label = "Rails", placeholder = "integer ≥ 2 (default 3)", default = "3" },
  encode = encode, decode = decode,
}
