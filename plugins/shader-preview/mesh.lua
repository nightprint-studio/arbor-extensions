-- The geometry: what the picker offers, what each shape asks for, and the vertices themselves.
--
-- All three come from the `mesh-source` extension rather than being written here. That is what
-- lets a second mesh package — one built from your own engine, never published — appear in
-- this panel without a line changing.
--
-- ## Why a shape declares its own parameters
--
-- A mesh is not always "pick a name". A sphere's segment count decides whether a perturbed
-- normal reads or shimmers, and too few segments makes a smooth shader look faceted — which is
-- easy to mistake for the shader being wrong. So the catalogue carries a JSON Schema per shape
-- and the form is built from it. The alternative, a hand-written form per shape, is how the
-- picker and the panel drift apart the day somebody adds one.

local M = {}

local catalogue_cache = nil

--- Every installed `mesh-source` package, in a stable order.
--
-- `primitives` first when it is there, because it is the one everybody has and the picker
-- should open on a sphere rather than on whatever a third-party package happens to sort
-- before it. The rest alphabetically, so the list does not reshuffle between two opens.
local function providers()
  local ok, entries = pcall(function() return arbor.ext.list() end)
  if not ok or type(entries) ~= "table" then return {} end

  local ids = {}
  for _, e in ipairs(entries) do
    if e.interface == "mesh-source" and type(e.id) == "string" then
      ids[#ids + 1] = e.id
    end
  end
  table.sort(ids, function(a, b)
    if a == "primitives" then return true end
    if b == "primitives" then return false end
    return a < b
  end)
  return ids
end

--- What every installed mesh package offers, as one list.
--
-- Every package and not one, which is the whole promise the interface makes: "build a second
-- mesh-source from your own crates, drop it in the plugins folder, and it appears beside
-- these". Asking a hard-coded `primitives` was that promise going unkept — a package could be
-- installed, loaded and exporting correctly, and the picker would never say its name.
--
-- Ids are qualified as `<provider>/<shape>`, exactly as the WIT file says a host addresses
-- one. Two packages offering `cube` therefore do not collide, and neither has to know the
-- other exists.
--
-- Asked once and kept — a catalogue does not change under us. The fallback is deliberately NOT
-- cached: a call that fails because an extension has not finished coming up would otherwise
-- pin the picker to one entry for the rest of the session, which looks exactly like a package
-- that ships a single shape.
function M.catalogue()
  if catalogue_cache then return catalogue_cache end

  local out = {}
  for _, provider in ipairs(providers()) do
    local ok, entries = pcall(function()
      return arbor.ext.call{ interface = "mesh-source", id = provider, method = "catalogue" }
    end)
    if ok and type(entries) == "table" then
      for _, k in ipairs(entries) do
        out[#out + 1] = {
          id          = provider .. "/" .. k.id,
          provider    = provider,
          shape       = k.id,
          label       = k.label,
          description = k.description,
          -- Entrambe le grafie. WIT scrive `params-schema` col trattino e il host ora
          -- consegna anche l'alias in snake_case; leggere solo quest'ultimo legava il
          -- pannello a una versione del host, e leggere solo il primo non è come si scrive
          -- Lua. Il costo di accettarli entrambi è una riga.
          schema      = k.params_schema or k["params-schema"],
        }
      end
    end
  end

  if #out == 0 then
    -- The picker still has to have something in it: an empty dropdown reads as a broken panel
    -- rather than as a missing package, and it would hand the host an empty Lua table — a JSON
    -- object, not an array — which is the "{} is not iterable" crash.
    return { {
      id = "primitives/sphere", provider = "primitives", shape = "sphere",
      label = "Sphere", description = "", schema = "{}",
    } }
  end
  catalogue_cache = out
  return out
end

--- The catalogue entry for an id, qualified or not.
--
-- The bare form is accepted because it is what saved looks and older panels hold: this picker
-- used to address a shape as `sphere`, and a template written then must not come back pointing
-- at nothing. First exact, then by shape name — so `sphere` finds `primitives/sphere` and a
-- package that also offers one does not steal it.
function M.kind(id)
  local all = M.catalogue()
  for _, k in ipairs(all) do
    if k.id == id then return k end
  end
  for _, k in ipairs(all) do
    if k.shape == id then return k end
  end
  return all[1]
end

--- Turn a name into a label the way a person would write it: `ring_count` → `Ring count`.
local function prettify(s)
  s = s:gsub("_", " ")
  return (s:gsub("^%l", string.upper))
end

--- The controls a shape asks for, read out of its JSON Schema.
--
-- Numbers become sliders and a **string with an `enum`** becomes a picker. Not every JSON
-- Schema construct — a free string, an object, an array would each need a widget and a
-- decision about what it means, and inventing those ahead of a caller is how a guess becomes a
-- contract nobody chose. What is NOT skipped silently is anything else: a property this cannot
-- render is logged by name, because a control that simply is not there looks like a package
-- that forgot to declare it.
--
-- Keys are sorted rather than left in decode order: a Lua table has none, so an unsorted form
-- would reshuffle its own rows between two identical opens.
function M.fields(kind)
  local ok, schema = pcall(function() return arbor.json.decode(kind.schema or "{}") end)
  if not ok then
    -- Said out loud, and this is the one that mattered. A schema that will not parse and a
    -- shape that declares no parameters produce the identical empty section, so a package with
    -- one stray comma in its JSON looks exactly like a package that simply has no knobs —
    -- which is how a broken schema survives a hand-written one being read three times.
    arbor.log.error(
      "shader-preview: the mesh `" .. tostring(kind.id) .. "` has a params schema that will " ..
      "not parse, so it is shown with no controls: " .. tostring(schema)
    )
    return {}
  end
  if type(schema) ~= "table" or type(schema.properties) ~= "table" then return {} end

  local names = {}
  for name in pairs(schema.properties) do names[#names + 1] = name end
  table.sort(names)

  local out = {}
  for _, name in ipairs(names) do
    local p = schema.properties[name]
    local ty = p.type
    if ty == "integer" or ty == "number" then
      local int = ty == "integer"
      out[#out + 1] = {
        kind    = "range",
        name    = name,
        label   = p.title or prettify(name),
        hint    = p.description,
        min     = tonumber(p.minimum) or 0,
        max     = tonumber(p.maximum) or (int and 16 or 1),
        step    = int and 1 or 0.01,
        default = tonumber(p.default) or tonumber(p.minimum) or 0,
      }
    elseif ty == "string" and type(p.enum) == "table" and #p.enum > 0 then
      -- A closed set of words. `block` picks its solid this way — cube, octahedron,
      -- rhombohedron, bipyramid — and without a control for it the shape has a parameter that
      -- decides most of what it looks like and no way to reach it.
      local options = {}
      for i, v in ipairs(p.enum) do
        options[i] = { value = tostring(v), label = prettify(tostring(v)) }
      end
      out[#out + 1] = {
        kind    = "select",
        name    = name,
        label   = p.title or prettify(name),
        hint    = p.description,
        options = options,
        default = tostring(p.default or p.enum[1]),
      }
    else
      -- Said out loud. A property with no control is indistinguishable from one nobody
      -- declared, and a mesh package author has no other way to find out that half their
      -- schema is being ignored.
      arbor.log.warn(
        "shader-preview: no control for mesh parameter '" .. name ..
        "' (type " .. tostring(ty) .. ") — it keeps its default"
      )
    end
  end
  return out
end

--- The starting values for a shape's own parameters.
--- The starting values for a shape's own parameters.
--
-- Read from the SCHEMA and not from the fields, so a property with no control still gets its
-- declared default. Otherwise a parameter this panel cannot draw would also be one it never
-- sends, and the generator would silently build something else.
function M.defaults(kind)
  local out = {}
  local ok, schema = pcall(function() return arbor.json.decode(kind.schema or "{}") end)
  if ok and type(schema) == "table" and type(schema.properties) == "table" then
    for name, p in pairs(schema.properties) do
      if p.default ~= nil then out[name] = p.default end
    end
  end
  for _, f in ipairs(M.fields(kind)) do
    if out[f.name] == nil then out[f.name] = f.default end
  end
  return out
end

-- ── Vertices ─────────────────────────────────────────────────────────────────

local built = {}

local function cache_key(id, params)
  local ok, text = pcall(function() return arbor.json.encode(params or {}) end)
  return id .. "|" .. (ok and text or "?")
end

--- Does this mesh have one side?
--
-- True when every normal points the same way — which is what a quad is, and what nothing with
-- volume is. It matters because Bevy culls back faces: a flat mesh seen from behind is not
-- dimly lit, it is *absent*, and a turntable carries it there for half of every revolution.
--
-- Read off the vertices rather than declared in the catalogue on purpose. "Flat" is a property
-- of the geometry a package produced, not a claim it has to remember to make — and a mesh
-- source written by somebody else gets this for free. The loop leaves on the first normal that
-- disagrees, so anything with volume costs three comparisons.
function M.is_flat(data)
  local n = data and data.normals
  if type(n) ~= "table" or #n < 3 then return false end
  local x, y, z = n[1], n[2], n[3]
  for i = 4, #n - 2, 3 do
    if math.abs(n[i] - x) > 1e-3 or math.abs(n[i + 1] - y) > 1e-3 or math.abs(n[i + 2] - z) > 1e-3 then
      return false
    end
  end
  return true
end

--- Build a mesh, or hand back the one already built for these exact values.
--
-- The cache is what makes a light slider cheap. Every scene change re-sends the whole `open`
-- message, vertices included, and a subdivided plane is tens of thousands of floats crossing
-- the plugin seam — paid once here instead of on every drag.
function M.build(id, params)
  local key = cache_key(id, params)
  if built[key] then return built[key], nil end

  -- The id says which package owns the shape, so the call goes there. Resolved through
  -- `M.kind` rather than by splitting the string: that also accepts the unqualified form a
  -- saved look may hold, and it is the one place that knows what the catalogue actually has.
  local kind = M.kind(id)
  if not kind then return nil, "no mesh source is installed" end

  local ok, result = pcall(function()
    return arbor.ext.call{
      interface = "mesh-source", id = kind.provider, method = "build",
      args = { kind.shape, arbor.json.encode(params or {}) },
    }
  end)
  if not ok then return nil, tostring(result) end

  local data = {
    positions = result.positions,
    normals   = result.normals,
    uvs       = result.uvs,
    indices   = result.indices,
  }
  built[key] = data
  return data, nil
end

return M
