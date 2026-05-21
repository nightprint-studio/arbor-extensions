-- cipher-studio / main.lua
--
-- Adds the "Cipher Studio" command: opens a modal with a dropdown of
-- classical ciphers and old-school encodings, two textareas (input /
-- output) and Encode / Decode / Swap / Clear buttons. Each algorithm
-- lives in its own file under `algos/<id>.lua` and exposes the shape:
--
--   return {
--     id     = "rot13",          -- unique key, matches filename
--     label  = "ROT13",          -- shown in the dropdown
--     group  = "Substitution",   -- dropdown section header
--     key    = { label = "Shift", placeholder = "3", default = "3" }
--                                -- optional; nil = keyless algo
--     encode = function(input, key) ... end,
--     decode = function(input, key) ... end,
--   }
--
-- The runtime here doesn't know anything about specific algorithms — it
-- just wires the dropdown selection to the module's `encode` / `decode`
-- and pushes the result back into the output textarea.

local ALGO_IDS = {
  -- Encoding
  "base64", "base32", "base16", "binary", "octal", "ascii_decimal",
  "url", "html_entities", "unicode_escape", "morse", "a1z26", "reverse",
  -- Substitution
  "rot13", "rot47", "rot5", "rot18",
  "caesar", "atbash", "affine",
  "vigenere", "beaufort", "autokey",
  -- Steganographic
  "bacon",
  -- Transposition
  "rail_fence", "columnar", "scytale",
  -- Grid
  "polybius", "nihilist",
  -- Bonus
  "playfair", "bifid", "xor",
}

local GROUP_ORDER = {
  "Encoding", "Substitution", "Steganographic",
  "Transposition", "Grid", "Bonus",
}

local algos = {}

local function load_algos()
  for _, id in ipairs(ALGO_IDS) do
    local ok, mod = pcall(require, "algos." .. id)
    if ok and type(mod) == "table" and mod.encode and mod.decode then
      algos[mod.id or id] = mod
    else
      arbor.log.warn("cipher-studio: failed to load algos." .. id .. ": " .. tostring(mod))
    end
  end
end

local function build_options()
  local by_group = {}
  for _, id in ipairs(ALGO_IDS) do
    local a = algos[id]
    if a then
      local g = a.group or "Other"
      by_group[g] = by_group[g] or {}
      table.insert(by_group[g], {
        value       = a.id,
        label       = a.label,
        description = a.key and ("key: " .. (a.key.label or "key")) or nil,
      })
    end
  end
  local options = {}
  local seen = {}
  for _, g in ipairs(GROUP_ORDER) do
    if by_group[g] then
      options[#options + 1] = { group = g, items = by_group[g] }
      seen[g] = true
    end
  end
  for g, items in pairs(by_group) do
    if not seen[g] then
      options[#options + 1] = { group = g, items = items }
    end
  end
  return options
end

local function keyed_algo_ids()
  -- IDs of algorithms that need a key. Used as `show_if.in_values` so the
  -- key field disappears entirely for keyless algos (ROT13, Base64, …).
  local ids = {}
  for _, id in ipairs(ALGO_IDS) do
    local a = algos[id]
    if a and a.key then ids[#ids + 1] = a.id end
  end
  return ids
end

local function open_modal()
  local keyed = keyed_algo_ids()
  arbor.ui.form({
    title         = "Cipher Studio",
    description   = "Classical ciphers and old-school encodings. Pick an algorithm, paste text, hit Encode or Decode.",
    width         = "960px",
    height        = "760px",
    submit_label  = "Close",
    submit_action = "cipher-studio:noop",
    nodes = {
      { type = "select", name = "algo", label = "Algorithm",
        options = build_options(), default = "rot13", searchable = true,
        style = "min-width: 0;" },
      { type = "text", name = "key", label = "Key / parameter",
        placeholder = "Vigenère: word · Caesar/Scytale: number · Affine: a,b · XOR: text · Columnar: keyword",
        show_if = { field = "algo", in_values = keyed } },
      { type = "textarea", name = "input", label = "Input",
        rows = 10, placeholder = "Paste or type the text to process…" },
      { type = "row", gap = 6, children = {
        { type = "button", label = "Encode",  variant = "primary",
          icon = "ArrowDown", action = "cipher-studio:run",
          extra = { mode = "encode" } },
        { type = "button", label = "Decode",  variant = "default",
          icon = "ArrowUp",   action = "cipher-studio:run",
          extra = { mode = "decode" } },
        { type = "button", label = "Swap",    variant = "ghost",
          icon = "ArrowDownUp", action = "cipher-studio:swap" },
        { type = "button", label = "Clear",   variant = "ghost",
          icon = "Eraser", action = "cipher-studio:clear" },
        { type = "button", label = "Use output as input", variant = "ghost",
          icon = "CornerUpLeft", action = "cipher-studio:reuse" },
      }},
      { type = "textarea", name = "output", label = "Output",
        rows = 10, placeholder = "Result appears here…" },
    },
  })
end

-- ─── action handlers ─────────────────────────────────────────────────────

arbor.events.on("cipher-studio:noop", function(_) end)

arbor.events.on("cipher-studio:run", function(ctx)
  local id    = (ctx and ctx.algo) or ""
  local mode  = (ctx and ctx.mode) or "encode"
  local input = (ctx and ctx.input) or ""
  local key   = (ctx and ctx.key) or ""
  local a = algos[id]
  if not a then
    arbor.notify{ message = "Unknown algorithm: " .. id, level = "error" }
    return
  end
  local fn = a[mode]
  if type(fn) ~= "function" then
    arbor.notify{
      message = a.label .. " does not support " .. mode .. ".",
      level   = "warning",
    }
    return
  end
  local ok, result = pcall(fn, input, key)
  if not ok then
    arbor.ui.form.set_value("output", "⚠ " .. tostring(result))
    arbor.notify{ message = a.label .. " " .. mode .. " failed.", level = "warning" }
    return
  end
  arbor.ui.form.set_value("output", result or "")
end)

arbor.events.on("cipher-studio:swap", function(ctx)
  local input  = (ctx and ctx.input)  or ""
  local output = (ctx and ctx.output) or ""
  arbor.ui.form.set_value("input",  output)
  arbor.ui.form.set_value("output", input)
end)

arbor.events.on("cipher-studio:clear", function(_)
  arbor.ui.form.set_value("input",  "")
  arbor.ui.form.set_value("output", "")
end)

arbor.events.on("cipher-studio:reuse", function(ctx)
  arbor.ui.form.set_value("input", (ctx and ctx.output) or "")
  arbor.ui.form.set_value("output", "")
end)

-- ─── wiring ──────────────────────────────────────────────────────────────

arbor.events.on("on_plugin_load", function(_)
  load_algos()
  arbor.command.register({
    id          = "open",
    title       = "Cipher Studio: open…",
    description = "Encode / decode text with classical ciphers and old-school encodings.",
    icon        = "KeyRound",
    group       = "Cipher Studio",
  })
  arbor.log.info("cipher-studio ready (" .. #ALGO_IDS .. " algos)")
end)

arbor.events.on("command:open", function(_) open_modal() end)
