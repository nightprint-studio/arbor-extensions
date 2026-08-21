-- The scene around the material: knobs, and the RON document they generate.
--
-- ## Why the document is generated and not read
--
-- Tuning a material IS mostly tuning the light on it. A normal perturbation that reads
-- beautifully under one key light disappears under another, and a panel that ships a fixed rig
-- lets you judge that exactly once. So the rig is a set of fields and the document is written
-- from them — which also means an invalid scene is not reachable by turning a knob, only by a
-- value being out of range.
--
-- The package's own `scenes/*.ron` files stay where they are: they are its examples, and this
-- is a panel writing its own.
--
-- ## What is NOT here
--
-- The camera. The runtime keeps the live camera across a rebuild on purpose — a slider must
-- not throw away the angle you dragged to — so the values in a regenerated document would be
-- ignored from the second open onward. The camera is driven by camera COMMANDS instead, which
-- is `main.lua`'s job.

local M = {}

local function F(path, label, kind, extra)
  local f = { path = path, label = label, kind = kind }
  for k, v in pairs(extra or {}) do f[k] = v end
  return f
end

--- The groups, in the order they appear.
--
-- `lit_only` marks the ones that mean nothing to a shader declaring its own bind group: it
-- owns the whole group and there is no `StandardMaterial` underneath to give a roughness to.
-- Showing those knobs anyway would be three controls that do nothing.
M.GROUPS = {
  {
    id = "environment", title = "Environment", collapsed = true,
    fields = {
      -- First, because it is the one that changes what the other two mean.
      F("environment.checker", "Backdrop grid", "toggle"),
      F("environment.background", "Background", "color"),
      -- Low by default and worth keeping low: raise ambient and every micro-normal washes
      -- out, which is the one thing a shader preview exists to show.
      F("environment.ambient", "Ambient", "range", { min = 0, max = 1, step = 0.01 }),
    },
  },
  {
    id = "material", title = "Material", collapsed = true, lit_only = true,
    fields = {
      F("material.base_color", "Base colour", "color"),
      F("material.perceptual_roughness", "Roughness", "range", { min = 0, max = 1, step = 0.01 }),
      F("material.metallic", "Metallic", "range", { min = 0, max = 1, step = 0.01 }),
      -- A material EXTENDING `StandardMaterial` inherits its blend mode from the material
      -- underneath, and Bevy's default is opaque. A shader that computes its own alpha — water,
      -- a glow, an overlay — is most of what it looks like, and rendered opaque it looks like
      -- the alpha never happened rather than like a setting being wrong. So it is a control,
      -- with the engine's own default, rather than a guess made once for every shader.
      F("material.alpha", "Blend", "select", {
        hint = "how the fragment's alpha is used",
        options = {
          { value = "opaque",        label = "Opaque",        description = "Alpha ignored." },
          { value = "blend",         label = "Blend",         description = "The usual transparency." },
          { value = "premultiplied", label = "Premultiplied", description = "Colour already multiplied by alpha." },
          { value = "add",           label = "Add",           description = "Light only — glows, sparks." },
          { value = "multiply",      label = "Multiply",      description = "Darkens what is behind." },
        },
      }),
    },
  },
  {
    id = "key", title = "Key light", collapsed = true,
    fields = {
      F("lights.1.direction", "Direction", "vec3", { min = -1, max = 1, step = 0.01 }),
      F("lights.1.color", "Colour", "color"),
      F("lights.1.illuminance", "Illuminance", "range", { min = 0, max = 30000, step = 100 }),
    },
  },
  {
    id = "fill", title = "Fill light", collapsed = true,
    fields = {
      F("lights.2.direction", "Direction", "vec3", { min = -1, max = 1, step = 0.01 }),
      F("lights.2.color", "Colour", "color"),
      F("lights.2.illuminance", "Illuminance", "range", { min = 0, max = 30000, step = 100 }),
    },
  },
}

--- The groups that apply to this material.
function M.groups(raw)
  local out = {}
  for _, g in ipairs(M.GROUPS) do
    if not (raw and g.lit_only) then out[#out + 1] = g end
  end
  return out
end

--- The shipped rig, so the panel opens on the scene the package actually ships.
function M.defaults()
  return {
    camera      = { distance = 2.6, pitch = 0.30, auto_spin = 0.35 },
    -- The grid is ON by default. A material that computes its own alpha — which is most of
    -- what this previews — looks identical over any single colour: you cannot tell 60% opacity
    -- from 100% until there is something behind it with structure. The squares are that
    -- something, and the Background colour is still what they are made of.
    environment = { background = { 0.055, 0.062, 0.078 }, ambient = 0.14, checker = true },
    material    = {
      base_color = { 0.62, 0.60, 0.57 }, perceptual_roughness = 0.85, metallic = 0.0,
      alpha = "opaque",
    },
    lights = {
      { direction = { -0.45, -0.72, -0.52 }, color = { 1.0, 0.96, 0.90 }, illuminance = 11000 },
      { direction = { 0.62, -0.25, 0.74 },   color = { 0.55, 0.66, 0.85 }, illuminance = 2600 },
    },
  }
end

-- ── Model access ─────────────────────────────────────────────────────────────
--
-- A dotted path addresses the model; a numeric segment indexes a list. Lua's lists are
-- 1-based and the paths above are written that way, so `lights.1` really is the key light.

local function segments(path)
  local out = {}
  for seg in path:gmatch("[^.]+") do out[#out + 1] = tonumber(seg) or seg end
  return out
end

function M.get(model, path)
  local cur = model
  for _, k in ipairs(segments(path)) do
    if type(cur) ~= "table" then return nil end
    cur = cur[k]
  end
  return cur
end

function M.set(model, path, value)
  local segs = segments(path)
  local last = table.remove(segs)
  local cur = model
  for _, k in ipairs(segs) do
    if type(cur[k]) ~= "table" then cur[k] = {} end
    cur = cur[k]
  end
  cur[last] = value
end

-- ── RON ──────────────────────────────────────────────────────────────────────

--- A float RON will accept.
--
-- Always with a decimal point: the runtime's fields are `f32`, and RON reads a bare `11000` as
-- an integer and refuses it. `%.4f` then trimmed, because `tostring` on a float is free to
-- print `1e-05` — which RON does not read either.
local function num(v)
  local s = string.format("%.4f", tonumber(v) or 0)
  s = (s:gsub("0+$", ""))
  s = (s:gsub("%.$", ".0"))
  return s
end

local function tuple(a)
  local parts = {}
  for i, v in ipairs(a) do parts[i] = num(v) end
  return "(" .. table.concat(parts, ", ") .. ")"
end

--- The material a shader written to BEVY's convention gets: an extension of
--- `StandardMaterial` with `vec4`s at bindings 100 and up, lit by the rig above.
local function lit_material(m)
  return table.concat({
    "Shader(",
    '                source: Param("shader"),',
    -- Eight, matching the runtime's slot count. A material extension declares one uniform per
    -- binding from 100 up, and a shader that binds 104 against a material offering four is not
    -- a shader missing a parameter — wgpu refuses the whole pipeline and the viewport goes
    -- black with a validation panic.
    '                params: [ Param("p0"), Param("p1"), Param("p2"), Param("p3"),',
    '                          Param("p4"), Param("p5"), Param("p6"), Param("p7") ],',
    -- One role name per texture slot. Supplied whether or not the shader samples anything: a
    -- hole the document names and nobody fills is a scene that will not build.
    '                textures: Param("textures"),',
    "                base_color: " .. tuple({ m.material.base_color[1], m.material.base_color[2],
                                             m.material.base_color[3], 1.0 }) .. ",",
    "                perceptual_roughness: " .. num(m.material.perceptual_roughness) .. ",",
    "                metallic: " .. num(m.material.metallic) .. ",",
    '                alpha: "' .. tostring(m.material.alpha or "opaque") .. '",',
    "            )",
  }, "\n")
end

--- The material a shader that declares its OWN struct gets.
--
-- No base colour, no roughness, no light: it binds its own block at binding 0 and returns
-- colour from `fragment`, so it owns the whole bind group and there is no `StandardMaterial`
-- underneath to configure. The block arrives as bytes under `data` — the runtime uploads it
-- without ever learning a field name.
local function raw_material(vertex)
  return table.concat({
    "Raw(",
    '                source: Param("shader"),',
    '                data: Param("data"),',
    '                textures: Param("textures"),',
    '                alpha: "blend",',
    -- Se lo shader porta il proprio `@vertex`. Non è una preferenza: `Material::vertex_shader`
    -- è un metodo statico, quindi sono due tipi di materiale e sceglierne uno sbagliato non dà
    -- un'immagine diversa — o il `@vertex` viene ignorato in silenzio, o la pipeline non
    -- compila perché la funzione non c'è.
    "                vertex: " .. tostring(vertex == true) .. ",",
    "            )",
  }, "\n")
end

--- Serialise the model into the document the runtime parses.
function M.to_ron(m, raw, vertex)
  local lights = {}
  for i, l in ipairs(m.lights) do
    lights[i] = table.concat({
      "        Directional(",
      "            direction: " .. tuple(l.direction) .. ",",
      "            color: " .. tuple(l.color) .. ",",
      "            illuminance: " .. num(l.illuminance) .. ",",
      "        ),",
    }, "\n")
  end

  local spin = (tonumber(m.camera.auto_spin) or 0) > 0
    and ("Some(" .. num(m.camera.auto_spin) .. ")") or "None"

  return table.concat({
    "// Generated by shader-preview from the panel — turn the knobs, not this.",
    "(",
    '    id: "shader_preview",',
    '    name: "Shader preview",',
    '    description: "One material, one mesh, a turntable and a two-light rig.",',
    "",
    "    camera: Orbit(",
    "        distance: Single(" .. num(m.camera.distance) .. "),",
    "        pitch: " .. num(m.camera.pitch) .. ",",
    "        auto_spin: " .. spin .. ",",
    "        fov: None,",
    "    ),",
    "",
    "    environment: (",
    "        background: " .. tuple(m.environment.background) .. ",",
    "        ambient: " .. num(m.environment.ambient) .. ",",
    -- RON reads `true`/`false` bare, so the Lua boolean is written as its own text rather
    -- than through `num`.
    "        checker: " .. tostring(m.environment.checker == true) .. ",",
    "    ),",
    "",
    "    lights: [",
    table.concat(lights, "\n"),
    "    ],",
    "",
    "    entities: [",
    "        (",
    '            mesh: Param("mesh"),',
    "            material: " .. (raw and raw_material(vertex) or lit_material(m)) .. ",",
    "            position: (0.0, 0.0, 0.0),",
    "            scale: 1.0,",
    "            spin: 0.0,",
    "        ),",
    "    ],",
    "",
    "    controls: [],",
    ")",
  }, "\n")
end

return M
