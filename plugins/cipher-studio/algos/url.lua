-- URL percent-encoding (RFC 3986 unreserved set). No key.

local UNRESERVED = {}
for c in ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~"):gmatch(".") do
  UNRESERVED[c] = true
end

local function encode(input)
  local out = {}
  for i = 1, #input do
    local c = input:sub(i, i)
    if UNRESERVED[c] then
      out[#out + 1] = c
    else
      out[#out + 1] = string.format("%%%02X", string.byte(c))
    end
  end
  return table.concat(out)
end

local function decode(input)
  -- Standard decode treats '+' as space (form-urlencoded) — keep it as a
  -- literal '+' instead, since this is a generic tool and '+' is legal in
  -- a URL path.
  local s = input:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
  return s
end

return {
  id = "url", label = "URL (percent)", group = "Encoding",
  encode = encode, decode = decode,
}
