-- number-studio / main.lua
--
-- Adds the "Number Studio" command: opens a modal with a dropdown of
-- numeral systems, two textareas (input / output) and convert / swap /
-- clear buttons. Each system lives in its own file under
-- `algos/<id>.lua` and exposes:
--
--   return {
--     id     = "roman",
--     label  = "Roman",
--     group  = "Historical",
--     key    = { label = "Base", placeholder = "8" }  -- optional
--     encode = function(text, key) ... end,  -- decimal → this system
--     decode = function(text, key) ... end,  -- this system → decimal
--   }
--
-- Input/output are line-oriented: one number per line, so you can paste
-- a column of values and convert them all at once.

local ALGO_IDS = {
  -- Numeric bases
  "binary", "ternary", "quaternary", "senary", "octal",
  "duodecimal", "hexadecimal", "vigesimal",
  "base32", "base36", "sexagesimal", "custom_base",
  -- Historical numerals
  "roman", "greek_alphabetic", "attic_greek",
  "egyptian", "babylonian", "mayan", "hebrew",
  -- Eastern digit scripts
  "arabic_indic", "persian", "devanagari", "bengali", "gujarati",
  "tamil", "thai", "khmer", "burmese", "lao", "tibetan",
  -- East Asian
  "chinese", "chinese_financial",
  -- Spelled out
  "english_words", "italian_words", "nato",
}

local GROUP_ORDER = {
  "Numeric Bases",
  "Historical",
  "Eastern Digits",
  "East Asian",
  "Spelled Out",
}

local algos = {}

local function load_algos()
  for _, id in ipairs(ALGO_IDS) do
    local ok, mod = pcall(require, "algos." .. id)
    if ok and type(mod) == "table" and mod.encode and mod.decode then
      algos[mod.id or id] = mod
    else
      arbor.log.warn("number-studio: failed to load algos." .. id .. ": " .. tostring(mod))
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
        description = a.hint or (a.key and ("key: " .. (a.key.label or "key"))) or nil,
      })
    end
  end
  local options, seen = {}, {}
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
    title         = "Number Studio",
    description   = "Convert integers between numeral systems. One number per line.",
    width         = "960px",
    height        = "780px",
    submit_label  = "Close",
    submit_action = "number-studio:noop",
    nodes = {
      { type = "select", name = "algo", label = "Numeral system",
        options = build_options(), default = "binary", searchable = true,
        style = "min-width: 0;" },
      { type = "text", name = "key", label = "Key / parameter",
        placeholder = "Custom base: 2..36 · most other systems are keyless",
        show_if = { field = "algo", in_values = keyed } },
      { type = "textarea", name = "input", label = "Input",
        rows = 10, placeholder = "One integer per line…" },
      { type = "row", gap = 6, children = {
        { type = "button", label = "To system",  variant = "primary",
          icon = "ArrowDown", action = "number-studio:run",
          extra = { mode = "encode" } },
        { type = "button", label = "To decimal", variant = "default",
          icon = "ArrowUp",   action = "number-studio:run",
          extra = { mode = "decode" } },
        { type = "button", label = "Swap",       variant = "ghost",
          icon = "ArrowDownUp", action = "number-studio:swap" },
        { type = "button", label = "Clear",      variant = "ghost",
          icon = "Eraser", action = "number-studio:clear" },
        { type = "button", label = "Use output as input", variant = "ghost",
          icon = "CornerUpLeft", action = "number-studio:reuse" },
      }},
      { type = "textarea", name = "output", label = "Output",
        rows = 10, placeholder = "Result appears here…" },
    },
  })
end

-- ─── action handlers ─────────────────────────────────────────────────────

arbor.events.on("number-studio:noop", function(_) end)

arbor.events.on("number-studio:run", function(ctx)
  local id    = (ctx and ctx.algo) or ""
  local mode  = (ctx and ctx.mode) or "encode"
  local input = (ctx and ctx.input) or ""
  local key   = (ctx and ctx.key) or ""
  local a = algos[id]
  if not a then
    arbor.notify{ message = "Unknown system: " .. id, level = "error" }
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

arbor.events.on("number-studio:swap", function(ctx)
  local input  = (ctx and ctx.input)  or ""
  local output = (ctx and ctx.output) or ""
  arbor.ui.form.set_value("input",  output)
  arbor.ui.form.set_value("output", input)
end)

arbor.events.on("number-studio:clear", function(_)
  arbor.ui.form.set_value("input",  "")
  arbor.ui.form.set_value("output", "")
end)

arbor.events.on("number-studio:reuse", function(ctx)
  arbor.ui.form.set_value("input", (ctx and ctx.output) or "")
  arbor.ui.form.set_value("output", "")
end)

-- ─── wiring ──────────────────────────────────────────────────────────────

arbor.events.on("on_plugin_load", function(_)
  load_algos()
  arbor.command.register({
    id          = "open",
    title       = "Number Studio: open…",
    description = "Convert integers between numeral systems (bases, Roman, Chinese, Devanagari, …).",
    icon        = "Hash",
    group       = "Number Studio",
  })
  arbor.log.info("number-studio ready (" .. #ALGO_IDS .. " systems)")
end)

arbor.events.on("command:open", function(_) open_modal() end)
