-- The material's parameters: what controls they get, and how they become bytes.
--
-- The description comes from `arbor.shader.uniform` — names, types, and the byte offset of
-- each field, read by Bennu's own WGSL front end. This module never looks at the source. That
-- separation is deliberate and was learned the expensive way: two attempts at reading WGSL
-- outside Bennu both got the same two things wrong, and the second one had already shipped.
--
-- What is left here is genuinely presentation and arithmetic:
--
--   · which control a field gets, guessed from its name;
--   · packing the values into the buffer, at the offsets the description gives.

local M = {}

--- What control a field should get.
--
-- Guessing from the name is the right call and not a shortcut. WGSL has no way to say "this
-- vec4 is a colour" or "this scalar runs 0 to 1", and the alternative is four lanes of raw
-- float for a colour the author obviously meant to pick. A wrong guess costs a slider with an
-- odd range; no guess costs the panel its readability.
--
-- The vocabulary is the one shader authors actually use: each of these names means the same
-- thing in every shader that has one.
local function widget_for(field)
  -- A matrix gets no control. Deciding what a mat3x3 editor looks like is a real design
  -- question, and a wrong answer to it is worse than an honest "not editable here".
  if field.columns > 1 then
    return { widget = "readonly" }
  end

  -- An annotation beats the guess. `// @preview hot = #ff6b14` says outright that the lane is
  -- a colour and where it starts — the two things the name cannot say, and the reason a
  -- material whose colours are called `hot`, `deep` and `foam` used to open entirely black.
  local first = field.hints and field.hints[1]
  if field.rows >= 3 and first and type(first.hex) == "string" then
    return { widget = "color", alpha = field.rows == 4, hex = first.hex }
  end

  local n = field.name:lower()
  if field.rows >= 3 and (n:find("colou?r") or n:find("tint") or n:find("albedo") or n:find("emissive")) then
    return { widget = "color", alpha = field.rows == 4 }
  end
  if field.rows > 1 then
    return { widget = "vec" }
  end

  local ranges = {
    { "softness|strength|amount|mix|blend|alpha|opacity|roughness|metallic|intensity", 0, 1, 0.01 },
    { "radius|width|height|size|thickness|offset",                                     0, 1, 0.005 },
    { "speed|rate",                                                                   -4, 4, 0.01 },
    { "scale|density|freq",                                                            0, 64, 0.1 },
    { "count|arms|steps|octaves|segments",                                             1, 16, 1 },
    { "sharp|power|exp|contrast|gamma",                                                0.1, 12, 0.05 },
  }
  for _, r in ipairs(ranges) do
    for word in r[1]:gmatch("[^|]+") do
      if n:find(word) then
        return { widget = "range", min = r[2], max = r[3], step = r[4] }
      end
    end
  end
  return { widget = "range", min = -4, max = 4, step = 0.01 }
end

--- Is this control just padding?
--
-- A leading underscore means "there is nothing here" in every shader in this codebase and in
-- the Rust it mirrors: `_padding`, `_riserva_w`, `_inutilizzato`. A uniform must be a multiple
-- of sixteen bytes, so a material with three parameters has a fourth lane that exists only to
-- make the arithmetic work — and a slider for it is a control that does nothing, sitting
-- among controls that do.
local function is_filler(name)
  return type(name) == "string" and name:sub(1, 1) == "_"
end

--- One declared member, as the controls it should become.
--
-- Usually one. A member the author ANNOTATED lane by lane becomes one control per lane
-- instead: a `vec4` packing a frequency, two amounts and another frequency is four different
-- quantities that happen to share sixteen bytes, and offering it as one four-lane widget with
-- a single range is offering a control that cannot reach three of them.
--
-- Each lane becomes an ordinary scalar field at its own offset — four bytes along from the
-- last — so everything downstream (packing, defaults, saved looks) treats it as what it is
-- and needs to know nothing about where it came from.
--- Apply one `@preview` line to a control, over whatever the heuristic guessed.
--
-- The author knows the material; the heuristic knows the name. Where they disagree the author
-- wins — and where the author said nothing, the guess stands rather than being blanked.
local function apply_hint(control, h)
  if type(h) ~= "table" then return control end
  if h.label and h.label ~= "" then control.label = h.label end
  if h.min then control.min = h.min end
  if h.max then control.max = h.max end
  if h.default then control.default_value = h.default end
  if h.hint then control.hint = h.hint end
  return control
end

--- The field, copied, with its widget decided.
local function as_control(f)
  local merged = {}
  for k, v in pairs(f) do merged[k] = v end
  for k, v in pairs(widget_for(f)) do merged[k] = v end
  return merged
end

--- One declared member, as the controls it should become.
--
-- Usually one. A member the author ANNOTATED lane by lane becomes one control per lane
-- instead: a `vec4` packing a frequency, two amounts and another frequency is four different
-- quantities that happen to share sixteen bytes, and offering it as one four-lane widget with
-- a single range is offering a control that cannot reach three of them.
--
-- Each lane becomes an ordinary scalar field at its own offset — four bytes along from the
-- last — so everything downstream (packing, defaults, saved looks) treats it as what it is and
-- needs to know nothing about where it came from.
--
-- Three cases and not two, which is the shape the first version got wrong: a SCALAR with a
-- hint is neither "no hints" nor "lanes to name", and falling between them dropped its label,
-- its range, its default and its description on the floor — silently, since a control with a
-- guessed range still looks like a control.
local function expand(f)
  local hints = f.hints
  local lanes = f.rows or 1
  local has_hints = type(hints) == "table" and #hints > 0

  -- A matrix: one read-only row, and lanes would mean nothing on it anyway.
  if (f.columns or 1) > 1 then
    return { apply_hint(as_control(f), has_hints and hints[1] or nil) }
  end

  -- A scalar: one control, the author's word over the guess.
  if lanes == 1 then
    return { apply_hint(as_control(f), has_hints and hints[1] or nil) }
  end

  -- A vector nobody annotated: one widget, as before.
  if not has_hints then
    return { as_control(f) }
  end

  -- A vector the author called a COLOUR: one picker, not four sliders.
  --
  -- Without this the annotation made things worse than no annotation at all: any hint at all
  -- on a vector means "name the lanes", so `// @preview hot = #ff6b14` turned one colour into
  -- `hot.x`, `hot.y`, `hot.z`, `hot.w`. The hex is the thing that says otherwise — it is not a
  -- lane name, it is a statement about the whole vector.
  if lanes >= 3 and type(hints[1].hex) == "string" then
    return { apply_hint(as_control(f), hints[1]) }
  end

  -- A vector, lane by lane.
  local out = {}
  local axes = { "x", "y", "z", "w" }
  for i = 1, lanes do
    local axis = axes[i] or tostring(i)
    local lane = {
      -- A key of its own, so two lanes of one vector are two values and not one.
      name    = f.name .. "." .. axis,
      label   = f.name .. "." .. axis,
      ty      = "f32",
      -- Four bytes along per lane: a vector's components are contiguous, whatever the
      -- vector's own alignment was.
      offset  = (f.offset or 0) + (i - 1) * 4,
      size    = 4,
      columns = 1,
      rows    = 1,
      column_stride = 4,
      widget  = "range",
      -- An unannotated lane of an annotated vector still has no range anybody knows, so it
      -- falls back to the same wide default a nameless scalar gets.
      min     = -4,
      max     = 4,
      step    = 0.01,
    }
    out[i] = apply_hint(lane, hints[i])
  end
  return out
end

--- Every field of every block, with its control decided, in binding then declaration order.
--
-- Across ALL blocks, because a Bevy material extension does not have one: it declares a
-- separate `var<uniform>` per binding from 100 up, and a panel built from the first alone
-- offers one fifth of the material's controls while the rest sit at their defaults.
--
-- Each field remembers which block it came from and where in it, which is what `pack` needs:
-- an extension's blocks are separate bindings and go to separate slots, not to one buffer.
function M.decorate(desc)
  local out = {}
  local blocks = desc.blocks
  -- A description from an older host, or one that only filled the flat fields.
  if type(blocks) ~= "table" or #blocks == 0 then
    blocks = { { binding = desc.binding or 0, size = desc.size or 0, fields = desc.fields or {} } }
  end

  for bi, b in ipairs(blocks) do
    for _, f in ipairs(b.fields or {}) do
      for _, decorated in ipairs(expand(f)) do
        if not is_filler(decorated.label or decorated.name) then
          decorated.block = bi
          decorated.binding = b.binding
          out[#out + 1] = decorated
        end
      end
    end
  end
  return out
end

--- The blocks a description carries, normalised to a list.
function M.blocks(desc)
  if type(desc.blocks) == "table" and #desc.blocks > 0 then return desc.blocks end
  return { { binding = desc.binding or 0, size = desc.size or 0, fields = desc.fields or {} } }
end

--- Starting colours, in declaration order.
--
-- NOT all the same grey. Two colours a shader mixes are almost always a base and a detail —
-- `sand_color` and `dark_color`, albedo and tint — and giving both the same neutral makes the
-- first frame a flat wash with the structure invisible. A material whose whole point is that
-- mix then looks broken before a single slider has been touched.
--
-- Linear, like everything the material sees; the panel converts to sRGB for the picker.
local PALETTE = {
  { 0.72, 0.42, 0.16 },  -- warm base
  { 0.06, 0.05, 0.05 },  -- near-black detail, so the first mix reads
  { 0.16, 0.30, 0.58 },  -- cool third
  { 0.70, 0.70, 0.66 },  -- neutral, from here on
}

local function palette(i)
  local c = PALETTE[i] or PALETTE[#PALETTE]
  return { c[1], c[2], c[3] }
end

--- A value the field's own slider could actually produce.
--
-- A range input snaps to `min + n * step`, so a default that falls between two stops is one the
-- control can never return to — and, worse, one it does not even display: the browser shows the
-- snapped number while the panel keeps sending the unsnapped one, so the readout and the
-- picture disagree from the first frame.
--
-- It is not only cosmetic. A field named `arms` gets a step of 1 because arms are whole things,
-- and a spiral shader that turns `atan2` into an angle is periodic ONLY at whole arm counts: at
-- 4.25 the angle jumps by a quarter turn across the branch cut and leaves a hard seam along the
-- ray where `atan2` wraps. A default of `(1 + 16) / 4` put every such shader on the wrong side
-- of that until the first drag.
local function snap(v, f)
  local step = tonumber(f.step) or 0
  local min, max = tonumber(f.min) or 0, tonumber(f.max) or 1
  if step > 0 then
    v = min + math.floor((v - min) / step + 0.5) * step
    -- `min + n * step` in binary floats lands on 3.0200000000000005; the extra digits are
    -- noise that would show in a readout and in a saved look.
    v = math.floor(v * 1e6 + 0.5) / 1e6
  end
  if v < min then v = min elseif v > max then v = max end
  return v
end

--- A starting value per field — mid-range for a scalar, a palette entry for a colour.
function M.defaults(fields)
  local out = {}
  local colour_index = 0
  for _, f in ipairs(fields) do
    if f.widget == "color" then
      -- The colour the SHADER declared, when it declared one. The palette is the fallback for
      -- a material that only said "this is a colour" — it makes two colours differ, which is
      -- better than two identical greys, but it is still a guess, and an author who wrote the
      -- hex should not have to re-find it every time the panel opens.
      if type(f.hex) == "string" then
        out[f.name] = M.from_hex(f.hex, f.alpha and { 0, 0, 0, 1 } or { 0, 0, 0 })
      else
        colour_index = colour_index + 1
        local c = palette(colour_index)
        if f.alpha then c[4] = 1.0 end
        out[f.name] = c
      end
    elseif f.columns > 1 or f.rows > 1 then
      local n = (f.columns > 1) and (f.columns * f.rows) or f.rows
      local v = {}
      for i = 1, n do v[i] = 0.0 end
      out[f.name] = v
    elseif f.default_value ~= nil then
      -- What the author wrote wins over anything derived from the range: they know the value
      -- the material is actually used at, and a preview opening on it is the picture from the
      -- game rather than a plausible one.
      out[f.name] = tonumber(f.default_value) or 0.0
    else
      out[f.name] = snap((f.min < 0) and 0.0 or (f.min + f.max) / 4, f)
    end
  end
  return out
end

--- Pack the values into the flat float buffer the uniform expects.
--
-- Offsets come from the description, so the padding a `vec4` forces after three scalars is
-- real padding here too — and a matrix is written column by column at its own stride, which is
-- the rule that makes a `mat3x3<f32>` 48 bytes and not 36.
--
-- Lua arrays are 1-based and buffer offsets are not, which is the one place this could go
-- quietly wrong: `offset` is in BYTES from the start, so the slot is `offset / 4 + 1`.
--- Pack ONE block's fields into its own flat float buffer.
function M.pack_block(block, fields, values)
  local floats = {}
  for i = 1, (block.size or 0) / 4 do floats[i] = 0.0 end

  for _, f in ipairs(fields) do
    local v = values[f.name]
    if v ~= nil then
      if f.columns > 1 then
        for c = 0, f.columns - 1 do
          local at = (f.offset + c * f.column_stride) / 4
          for r = 1, f.rows do
            floats[at + r] = tonumber(v[c * f.rows + r]) or 0.0
          end
        end
      elseif f.rows == 1 then
        floats[f.offset / 4 + 1] = tonumber(v) or 0.0
      else
        for i = 1, f.rows do
          floats[f.offset / 4 + i] = tonumber(v[i]) or 0.0
        end
      end
    end
  end
  return floats
end

--- The first block's buffer — what a material owning its whole bind group needs.
function M.pack(desc, fields, values)
  local blocks = M.blocks(desc)
  local own = {}
  for _, f in ipairs(fields) do
    if (f.block or 1) == 1 then own[#own + 1] = f end
  end
  return M.pack_block(blocks[1], own, values)
end

--- One `vec4` per block, in binding order — what a material EXTENSION needs.
--
-- Four floats each, because that is the shape the extension material offers at every binding
-- from 100 up. A block bigger than one `vec4` cannot be driven this way and is written as far
-- as it fits: the alternative is refusing to preview a material over a parameter nobody moved.
function M.pack_slots(desc, fields, values)
  local blocks = M.blocks(desc)
  local slots = {}
  for bi, b in ipairs(blocks) do
    local own = {}
    for _, f in ipairs(fields) do
      if (f.block or 1) == bi then own[#own + 1] = f end
    end
    local packed = M.pack_block(b, own, values)
    local slot = {}
    -- The WHOLE block, not its first four floats. A runtime slot holds 512 bytes and a shader
    -- reads however much of it it declared, so a binding holding a struct or a matrix — which
    -- is an ordinary thing for a material extension to declare — used to arrive with
    -- everything past its first `vec4` cut off, and the missing part read as zero.
    local n = math.max(4, #packed)
    for i = 1, n do slot[i] = packed[i] or 0.0 end
    -- The binding decides the slot, not the order: a shader binding 100 and 102 leaves 101
    -- empty, and shifting them up would feed each parameter to the wrong one.
    local index = math.max(0, (b.binding or 100) - 100)
    slots[index + 1] = slot
  end
  return slots
end

-- ── The last mile ────────────────────────────────────────────────────────────
--
-- Tuning happens here and the numbers live in Rust. Without this the final gesture is reading
-- eleven floats off a panel and typing them into a `Default` impl by hand, which is where the
-- decimal point goes missing — and where the tuning quietly stops matching the picture that
-- was approved.

--- A number Rust will read as an `f32`.
--
-- Always with a decimal point, because `1` is an integer literal and `Vec4::new(1, 0, 0, 1)`
-- does not compile. Trimmed after four places: the value came off a slider whose step is a
-- hundredth, and `0.44999998` is noise pretending to be precision.
local function rust_num(v)
  local n = tonumber(v) or 0
  local s = string.format("%.4f", n):gsub("0+$", "")
  if s:sub(-1) == "." then s = s .. "0" end
  return s
end

--- One member, as the Rust expression that produces it.
local function rust_value(f, floats)
  local at = (f.offset or 0) / 4
  if (f.columns or 1) > 1 then
    -- A matrix is columns, each padded on its own — so it is read back the way it was
    -- written and not as one contiguous run.
    local cols = {}
    for c = 0, f.columns - 1 do
      local base = (f.offset + c * f.column_stride) / 4
      local parts = {}
      for r = 1, f.rows do parts[r] = rust_num(floats[base + r]) end
      cols[c + 1] = "Vec" .. f.rows .. "::new(" .. table.concat(parts, ", ") .. ")"
    end
    return "Mat" .. f.columns .. "::from_cols(" .. table.concat(cols, ", ") .. ")"
  end
  if (f.rows or 1) == 1 then
    -- An integer member is stored in the buffer as a float here, because the panel has one
    -- kind of control; on the way back out it has to look like what the struct declares.
    local t = tostring(f.type or "f32")
    if t == "u32" or t == "i32" then
      return tostring(math.floor((tonumber(floats[at + 1]) or 0) + 0.5))
    end
    return rust_num(floats[at + 1])
  end
  local parts = {}
  for i = 1, f.rows do parts[i] = rust_num(floats[at + i]) end
  return "Vec" .. f.rows .. "::new(" .. table.concat(parts, ", ") .. ")"
end

--- The tuned values as a Rust struct literal, ready to paste into the material's `Default`.
--
-- Built from the PACKED buffer rather than from the controls, and that is the whole reason it
-- can be trusted: the panel's controls are not the shader's members. A `vec4` with four
-- `@preview` lanes is four sliders, a filler lane is no slider at all, and a matrix is one
-- control holding nine numbers. Packing puts every value at the offset the shader reads it
-- from — which is the arithmetic that was written once, here, and is right — and reading it
-- back out by member gives the shape the Rust side declares.
function M.to_rust(desc, fields, values)
  local out = {}
  for bi, b in ipairs(M.blocks(desc)) do
    local own = {}
    for _, f in ipairs(fields) do
      if (f.block or 1) == bi then own[#own + 1] = f end
    end
    local floats = M.pack_block(b, own, values)

    local name = b.struct
    if type(name) ~= "string" or name == "" then name = desc.struct end
    if type(name) ~= "string" or name == "" then name = b.variable or "Params" end

    local lines = { name .. " {" }
    for _, f in ipairs(b.fields or {}) do
      -- Filler lanes are named `_something` and exist to make a uniform a multiple of 16
      -- bytes. They are members of the shader's struct and usually not of the Rust one, so
      -- they are written commented out rather than dropped: whoever pastes this can see there
      -- was padding there and decide.
      local line = "    " .. f.name .. ": " .. rust_value(f, floats) .. ","
      if is_filler(f.name) then line = "    // " .. f.name .. ": padding" end
      lines[#lines + 1] = line
    end
    lines[#lines + 1] = "}"
    out[#out + 1] = table.concat(lines, "\n")
  end
  return table.concat(out, "\n\n")
end

--- Random values inside each field's own range — a colour stays a colour.
--
-- Not a toy: a shader whose parameters you have not explored yet is faster to understand from
-- four random looks than from four deliberate ones, because the deliberate ones all start from
-- what you already expected it to do.
function M.randomise(fields)
  local out = {}
  local function r(min, max) return min + math.random() * (max - min) end

  for _, f in ipairs(fields) do
    if f.widget == "color" then
      local c = { math.random(), math.random(), math.random() }
      if f.alpha then c[4] = 1.0 end
      out[f.name] = c
    elseif f.columns > 1 then
      -- Left alone: a random matrix is a mangled transform, not an interesting one.
      local v = {}
      for i = 1, f.columns * f.rows do v[i] = 0.0 end
      out[f.name] = v
    elseif f.rows > 1 then
      local v = {}
      for i = 1, f.rows do v[i] = r(-1, 1) end
      out[f.name] = v
    else
      -- Through the same snap: a random value the slider cannot represent has exactly the
      -- problem the defaults had, and this is the surface most likely to hit it.
      out[f.name] = snap(r(f.min, f.max), f)
    end
  end
  return out
end

-- ── Colour, between a hex field and linear floats ────────────────────────────
--
-- Bevy's colours are linear; the host's `color` node is an sRGB hex string, because that is
-- what an `<input type=color>` speaks. Skipping the conversion is the classic way to end up
-- with a preview that is subtly, unaccountably darker than the game.

local function to_srgb(c)
  if c <= 0.0031308 then return c * 12.92 end
  return 1.055 * c ^ (1 / 2.4) - 0.055
end

local function to_linear(c)
  if c <= 0.04045 then return c / 12.92 end
  return ((c + 0.055) / 1.055) ^ 2.4
end

local function clamp01(v)
  if v < 0 then return 0 elseif v > 1 then return 1 else return v end
end

--- Linear floats → `#rrggbb`. Alpha is dropped: the field has no room for it, and a material
--- that wants a separate alpha declares one.
function M.to_hex(rgb)
  local out = "#"
  for i = 1, 3 do
    local v = math.floor(clamp01(to_srgb(tonumber(rgb[i]) or 0)) * 255 + 0.5)
    out = out .. string.format("%02x", v)
  end
  return out
end

--- `#rrggbb` → linear floats, keeping the alpha the value already had.
function M.from_hex(hex, previous)
  local r, g, b = hex:match("^#?(%x%x)(%x%x)(%x%x)$")
  if not r then return previous end
  local out = {
    to_linear(tonumber(r, 16) / 255),
    to_linear(tonumber(g, 16) / 255),
    to_linear(tonumber(b, 16) / 255),
  }
  if previous and #previous == 4 then out[4] = previous[4] end
  return out
end

return M
