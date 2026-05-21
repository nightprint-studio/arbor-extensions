-- International Morse code. Letters separated by space, words by "/".
-- Case-insensitive on encode; lowercase on decode.

local MAP = {
  A = ".-",   B = "-...", C = "-.-.", D = "-..",  E = ".",    F = "..-.",
  G = "--.",  H = "....", I = "..",   J = ".---", K = "-.-",  L = ".-..",
  M = "--",   N = "-.",   O = "---",  P = ".--.", Q = "--.-", R = ".-.",
  S = "...",  T = "-",    U = "..-",  V = "...-", W = ".--",  X = "-..-",
  Y = "-.--", Z = "--..",
  ["0"] = "-----", ["1"] = ".----", ["2"] = "..---", ["3"] = "...--",
  ["4"] = "....-", ["5"] = ".....", ["6"] = "-....", ["7"] = "--...",
  ["8"] = "---..", ["9"] = "----.",
  ["."] = ".-.-.-", [","] = "--..--", ["?"] = "..--..", ["'"] = ".----.",
  ["!"] = "-.-.--", ["/"] = "-..-.",  ["("] = "-.--.",  [")"] = "-.--.-",
  ["&"] = ".-...",  [":"] = "---...", [";"] = "-.-.-.", ["="] = "-...-",
  ["+"] = ".-.-.",  ["-"] = "-....-", ["_"] = "..--.-", ['"'] = ".-..-.",
  ["@"] = ".--.-.",
}

local REV = {}
for k, v in pairs(MAP) do REV[v] = k end

local function encode(input)
  local out = {}
  for word in input:upper():gmatch("%S+") do
    local letters = {}
    for i = 1, #word do
      local c = word:sub(i, i)
      letters[#letters + 1] = MAP[c] or "?"
    end
    out[#out + 1] = table.concat(letters, " ")
  end
  return table.concat(out, " / ")
end

local function decode(input)
  local words = {}
  -- Words separated by "/" with optional surrounding whitespace.
  for w in (input .. "/"):gmatch("([^/]+)/") do
    local letters = {}
    for tok in w:gmatch("[%.%-]+") do
      letters[#letters + 1] = REV[tok] or "?"
    end
    if #letters > 0 then words[#words + 1] = table.concat(letters) end
  end
  return table.concat(words, " "):lower()
end

return {
  id = "morse", label = "Morse code", group = "Encoding",
  encode = encode, decode = decode,
}
