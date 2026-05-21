-- Byte-wise reverse. Self-inverse, no key.

local function flip(s) return string.reverse(s) end

return {
  id = "reverse", label = "Reverse", group = "Encoding",
  encode = flip, decode = flip,
}
