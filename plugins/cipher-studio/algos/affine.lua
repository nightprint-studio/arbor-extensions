-- Affine cipher. E(x) = (a*x + b) mod 26. Key = "a,b" with gcd(a,26)=1.

local function parse_key(k)
  local a, b = (k or ""):match("^%s*(%-?%d+)%s*[, ]%s*(%-?%d+)%s*$")
  a = tonumber(a) or 5
  b = tonumber(b) or 8
  return a, b
end

local function modinv(a, m)
  a = ((a % m) + m) % m
  for x = 1, m - 1 do
    if (a * x) % m == 1 then return x end
  end
  return nil
end

local function affine(s, a, b)
  return (s:gsub("[A-Za-z]", function(c)
    local byt  = c:byte()
    local base = (byt >= 0x61) and 0x61 or 0x41
    local x    = byt - base
    return string.char(((a * x + b) % 26 + 26) % 26 + base)
  end))
end

local function encode(s, k)
  local a, b = parse_key(k)
  if not modinv(a, 26) then
    error("affine: 'a' (" .. a .. ") must be coprime with 26")
  end
  return affine(s, a, b)
end

local function decode(s, k)
  local a, b = parse_key(k)
  local inv = modinv(a, 26)
  if not inv then
    error("affine: 'a' (" .. a .. ") must be coprime with 26")
  end
  return (s:gsub("[A-Za-z]", function(c)
    local byt  = c:byte()
    local base = (byt >= 0x61) and 0x61 or 0x41
    local y    = byt - base
    return string.char(((inv * (y - b)) % 26 + 26) % 26 + base)
  end))
end

return {
  id = "affine", label = "Affine", group = "Substitution",
  key = { label = "a,b", placeholder = "5,8", default = "5,8" },
  encode = encode, decode = decode,
}
