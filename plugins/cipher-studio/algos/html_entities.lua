-- HTML numeric entities. No key.
--
-- Encode escapes the canonical "dangerous" five (& < > " ') by name and
-- every non-ASCII byte as a numeric &#NNN; entity. Decode understands
-- &amp; &lt; &gt; &quot; &apos; &nbsp; plus &#N; / &#xN; numeric forms.

local NAMED_ENC = { ["&"]="&amp;", ["<"]="&lt;", [">"]="&gt;", ['"']="&quot;", ["'"]="&apos;" }
local NAMED_DEC = {
  amp = 38, lt = 60, gt = 62, quot = 34, apos = 39, nbsp = 160,
}

local function encode(input)
  local out = {}
  for i = 1, #input do
    local b = string.byte(input, i)
    local c = string.char(b)
    if NAMED_ENC[c] then
      out[#out + 1] = NAMED_ENC[c]
    elseif b < 0x80 then
      out[#out + 1] = c
    else
      out[#out + 1] = string.format("&#%d;", b)
    end
  end
  return table.concat(out)
end

local function decode(input)
  local s = input
  s = s:gsub("&#x(%x+);", function(h)
    local n = tonumber(h, 16) or 0
    if n <= 255 then return string.char(n) end
    return string.format("\\u%04X", n)
  end)
  s = s:gsub("&#(%d+);", function(d)
    local n = tonumber(d) or 0
    if n <= 255 then return string.char(n) end
    return string.format("\\u%04X", n)
  end)
  s = s:gsub("&(%a+);", function(name)
    local n = NAMED_DEC[name]
    if n then return string.char(n) end
    return "&" .. name .. ";"
  end)
  return s
end

return {
  id = "html_entities", label = "HTML entities", group = "Encoding",
  encode = encode, decode = decode,
}
