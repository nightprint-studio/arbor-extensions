-- Bacon cipher (26-letter variant). Each letter → 5-character A/B group.

local CODES = {
  A = "AAAAA", B = "AAAAB", C = "AAABA", D = "AAABB", E = "AABAA",
  F = "AABAB", G = "AABBA", H = "AABBB", I = "ABAAA", J = "ABAAB",
  K = "ABABA", L = "ABABB", M = "ABBAA", N = "ABBAB", O = "ABBBA",
  P = "ABBBB", Q = "BAAAA", R = "BAAAB", S = "BAABA", T = "BAABB",
  U = "BABAA", V = "BABAB", W = "BABBA", X = "BABBB", Y = "BBAAA",
  Z = "BBAAB",
}
local REV = {}
for k, v in pairs(CODES) do REV[v] = k end

local function encode(input)
  local out = {}
  for c in input:upper():gmatch("[A-Z]") do
    out[#out + 1] = CODES[c] or ""
  end
  return table.concat(out, " ")
end

local function decode(input)
  -- Accept either "A/B" or "a/b" — fold to A/B then chunk into 5.
  local stripped = input:upper():gsub("[^AB]", "")
  if #stripped % 5 ~= 0 then
    error("bacon: stripped input length (" .. #stripped .. ") must be a multiple of 5")
  end
  local out = {}
  for i = 1, #stripped, 5 do
    out[#out + 1] = REV[stripped:sub(i, i + 4)] or "?"
  end
  return table.concat(out)
end

return {
  id = "bacon", label = "Bacon", group = "Steganographic",
  encode = encode, decode = decode,
}
