-- A1Z26 — A=1, B=2, …, Z=26. Letters joined with "-" inside words, words
-- separated by " / ". Non-letters drop on encode; decode is tolerant of
-- different separators.

local function encode(input)
  local words = {}
  for word in input:upper():gmatch("%S+") do
    local nums = {}
    for i = 1, #word do
      local b = word:byte(i)
      if b >= 0x41 and b <= 0x5A then
        nums[#nums + 1] = tostring(b - 0x40)
      end
    end
    if #nums > 0 then words[#words + 1] = table.concat(nums, "-") end
  end
  return table.concat(words, " / ")
end

local function decode(input)
  local words = {}
  for w in (input .. "/"):gmatch("([^/]+)/") do
    local letters = {}
    for tok in w:gmatch("%d+") do
      local n = tonumber(tok)
      if n and n >= 1 and n <= 26 then
        letters[#letters + 1] = string.char(0x40 + n)
      end
    end
    if #letters > 0 then words[#words + 1] = table.concat(letters) end
  end
  return table.concat(words, " "):lower()
end

return {
  id = "a1z26", label = "A1Z26", group = "Encoding",
  encode = encode, decode = decode,
}
