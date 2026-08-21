-- shader-preview — look at a WGSL material while you edit it.
--
-- This plugin draws nothing, compiles nothing and reads no WGSL. It decides WHAT to show and
-- wires together four things that each do one job:
--
--   · bevy-runtime           a viewport, driven by a RON scene document
--   · shader-preview-meshes  geometry, as a wasm extension
--   · arbor.shader.uniform   what the material declares — Bennu's own WGSL front end
--   · scene.lua              the rig, as knobs that write the document
--
-- That division is the point, and the third part of it was learned the expensive way. Reading
-- a shader's parameter block looks like something this plugin could do with a few patterns,
-- and two attempts at that got the same two things wrong: WGSL block comments nest, and
-- `@group(0)` is the view's bind group rather than the material's. Bennu already reads WGSL
-- for highlighting and for checking a material's Rust half against its shader half, so it
-- answers and this asks.
--
-- ## The three ways this panel talks to the viewport
--
-- They cost wildly different amounts, and using the wrong one is what "the preview restarts
-- every time I touch a slider" is made of:
--
--   · `update`  — new bytes for the uniform. No mesh, no document, no recompile. This is what
--                 a parameter change sends, which is why parameters are live and need no
--                 button.
--   · `open`    — a new document, mesh included. What a mesh or a light change needs, because
--                 both are IN the document. The mesh vertices are cached, so the cost is the
--                 document and the shader.
--   · rebuilding the panel (`set_panel_content`) — remounts the frame and RESTARTS the Bevy
--                 app, several seconds of black. Only for a change in the panel's structure:
--                 a different shader, a reload. Everything else moves controls with
--                 `set_value` / `form.patch`, which leave the running app alone.

local M = {}

local ui        = require("ui")
local params    = require("params")
local templates = require("templates")
local scene     = require("scene")
local mesh      = require("mesh")

local deps = { ui = ui, params = params, templates = templates, scene = scene, mesh = mesh }

-- ── Where the other packages live ────────────────────────────────────────────
--
-- Siblings in the plugins folder. There is no API for "another package's directory", and
-- inventing one for this would be a host API serving one call site; a declared dependency plus
-- a sibling path is the honest version, and `plugin_loaded` turns a missing one into a
-- sentence instead of a blank frame.

local function runtime_dir()
  local dir = arbor.meta.plugin_dir()
  local parent = dir:match("^(.*)[/\\][^/\\]+$") or dir
  return arbor.fs.join(parent, "bevy-runtime")
end

local function runtime_page()
  return arbor.fs.join(runtime_dir(), "web", "index.html")
end

-- ── State for the open preview ───────────────────────────────────────────────

local VIEW_ID     = "preview"
local VIEWPORT_ID = "viewport"

local state = {
  path   = nil,   -- the shader file on disk
  source = nil,   -- its text
  mesh   = { id = "sphere", params = {} },
  scene  = scene.defaults(),
  desc   = nil,   -- what Bennu says the material declares
  fields = {},    -- those fields with their controls decided
  values = {},    -- what the controls currently hold
  runtime_page = nil,
  outbox = {},    -- messages queued for the frame; appending is what sends
  -- The clock. `at` is meaningful only while paused — a running virtual clock is recomputed
  -- from the real one every frame, so a value written into it is overwritten before anything
  -- is drawn.
  clock  = { paused = false, at = 0.0 },
  editor_wgsl = nil, -- the last .wgsl the editor showed, so a keystroke needs no picker
  vertex_entry = false, -- lo shader porta il proprio `@vertex`, quindi serve l'altro materiale
  plan   = nil,   -- the shader renumbered onto the runtime's slots, and the map back
  roles  = {},    -- what picture to put in each texture KIND — `normal`, `diffuse`, `pbr`
  blocked = nil,  -- bindings this preview cannot supply, as a sentence
  view_open = false,     -- the panel is on screen, so it should follow the editor
  own_group = false,     -- the material owns its bind group, rather than extending StandardMaterial
  flat = false,          -- the current mesh has one side (a quad), so it must face the camera
  spin_suspended = false, -- the turntable is off because WE stopped it, not the user
}

M.state = state

--- The name a material's saved looks are filed under.
--
-- The struct's name when the shader declared one, the bound variable's when it did not — a
-- material extension binding a bare `vec4<f32>` has no struct anywhere, and keying those by an
-- empty string would file every one of them together.
local function mat_key()
  if not state.desc then return "" end
  local k = state.desc.key
  if type(k) == "string" and k ~= "" then return k end
  local s = mat_key()
  if type(s) == "string" and s ~= "" then return s end
  return "material"
end

--- Put a message on the viewport's outbox and deliver it to the frame that is already up.
--
-- Two steps, both needed for a different reason. The outbox keeps being the truth: the panel
-- body is rebuilt from it, so a frame that mounts later replays it and catches up. The patch is
-- what reaches the frame running RIGHT NOW — a rebuild would do it too, but
-- `set_panel_content` re-keys the renderer, which remounts the iframe and throws away the Bevy
-- app mid-drag.
--
-- ## Why the outbox is a set and not a log
--
-- What a frame mounting this instant needs is not every message ever sent — it is the current
-- truth: the scene it should be showing, the last camera it was told, the latest bytes for the
-- uniform. Everything between them was superseded. Kept as a log, a session of dragging
-- sliders would append thousands of entries that exist only to be skipped, and the whole list
-- is re-serialised on every one of them.
--
-- This works because each message carries a `seq` and the `embed` node delivers by it rather
-- than by counting: the array can be rewritten freely and a frame still receives exactly what
-- it has not seen.
local seq = 0
local replay = {}

local function send(message)
  seq = seq + 1
  message.seq = seq

  if message.type == "open" then
    -- An `open` carries scene, shader and mesh, so it supersedes everything before it —
    -- including a camera distance, which the runtime keeps across a rebuild by itself.
    replay = { open = message }
  else
    -- Camera commands are keyed by WHICH command, not just by "camera". They are not
    -- alternatives: `reset` puts the framing back and lets the turntable go, `spin` decides
    -- whether it runs, `absolute_distance` sets the distance. Collapsing them onto one key
    -- would let the last one written erase the one sent a line earlier — and the pair that
    -- faces a flat mesh at the camera is exactly two of them, in order.
    -- `time` is deliberately NOT split the way `camera` is: `paused` and `set` are two halves
    -- of one state and always travel together, so the latest pair is the whole truth.
    local key = message.type
    if key == "camera" then
      key = "camera:" .. (message.reset and "reset"
                          or (message.spin ~= nil and "spin")
                          or "distance")
    end
    replay[key] = message
  end

  local out = {}
  for _, m in pairs(replay) do out[#out + 1] = m end
  -- In the order they were sent: a replay has to open the scene before it patches it.
  table.sort(out, function(a, b) return a.seq < b.seq end)
  state.outbox = out

  pcall(function()
    arbor.ui.form.patch{
      { id = VIEWPORT_ID, set = { "send" }, value = state.outbox },
    }
  end)
end

--- How many `vec4` slots the runtime's extension material offers, at bindings 100 and up.
--
-- Must match `EXT_SLOTS` in the runtime. A hole the scene document names and nobody fills is a
-- scene that will not build, so every slot is supplied whether the shader reads it or not.
local EXT_SLOTS = 8

--- The material's parameters, in the shape the scene asks for.
--
-- Two shapes, and which one follows from the SHADER rather than from whether Bennu managed to
-- describe it. A material that binds its own block low owns the whole group and takes a byte
-- buffer; one that extends `StandardMaterial` puts its uniforms at binding 100 and up and
-- takes one `vec4` per binding. Sending the wrong one is not a wrong colour — it is a pipeline
-- whose layout does not match the shader, which wgpu refuses outright.
--- One role name per texture slot, in the order the runtime fills them.
--
-- POSITIONAL, and that is the whole subtlety: the runtime reads a flat list — the 2D slots
-- first, then the array textures, then the cubes — so a cube map in a shader with one ordinary
-- texture belongs at index 14 and not at index 1. The host has already worked that index out
-- (`t.index`), because it is the same arithmetic that renumbered the shader.
--
-- Holes are `""`, which the runtime reads as the neutral image. They are sent rather than
-- skipped: a list with the blanks squeezed out slides every later slot one place along.
local function texture_roles()
  local out, top = {}, 0
  for _, t in ipairs((state.plan and state.plan.textures) or {}) do
    local at = (tonumber(t.index) or 0) + 1
    -- FIRST writer wins. Several textures share one slot — deliberately when they are the same
    -- KIND, and because the viewport ran out when they are not — and the one that owns it is
    -- the one listed first. Letting the last win put the ambient-occlusion row's white in a
    -- normal map's slot, which as a normal is a vector along the diagonal: every face lit
    -- wrong, with nothing on screen to say why.
    if out[at] == nil then
      out[at] = state.roles[t.key] or t.image or ""
    end
    if at > top then top = at end
  end
  -- Never empty. A Lua table with nothing in it crosses the seam as a JSON **object**, not an
  -- array — Lua has one table type and no way to say which was meant — and the scene names
  -- this slot unconditionally, so `{}` is a document that will not build. One blank entry is
  -- an array of one, and a blank reads as the neutral image, which is what a material with no
  -- textures should get.
  for i = 1, math.max(1, top) do out[i] = out[i] or "" end
  return out
end

local function material_params()
  local textures = texture_roles()
  if state.desc and state.own_group then
    return {
      data = params.pack(state.desc, state.fields, state.values),
      textures = textures,
    }
  end

  local p = { textures = textures }
  local slots = state.desc and params.pack_slots(state.desc, state.fields, state.values) or {}
  for i = 1, EXT_SLOTS do
    -- A shader with no describable block at all still gets a full set: zeros show it rendering
    -- rather than not rendering, which is the more useful of the two failures.
    p["p" .. (i - 1)] = slots[i] or { 0, 0, 0, 0 }
  end
  return p
end

--- New bytes for the uniform, and nothing else.
--
-- The cheap path, and the reason a slider needs no Reload behind it: no mesh crosses the seam,
-- no document is written, the shader is not re-read. The runtime merges the patch into the
-- params it already has and rebuilds the entity, keeping the camera.
local function push_params()
  send{ type = "update", params = material_params() }
end

--- Send the clock where the panel says it is.
--
-- One message and one replay key: `paused` and `at` are two halves of one state, not two
-- commands, so a frame that mounts late needs the latest pair rather than the last thing
-- either of them did.
local function push_time()
  send{ type = "time", paused = state.clock.paused, set = state.clock.at }
end

--- Stop the clock, or let it run.
--
-- Pausing remembers WHERE it stopped, so the scrub opens on the instant you were looking at
-- rather than on zero. Unpausing sends no instant: the runtime carries on from where it is,
-- and sending one would make the picture jump the moment you pressed play.
local function set_paused(paused)
  state.clock.paused = paused == true
  -- No instant either way. Stopping the clock means stopping it WHERE IT IS, and where it is
  -- lives in the runtime — the panel's own `at` is the last thing it was told, which after a
  -- while of running is a moment the clock has long passed. Sending it back would ask for a
  -- jump backwards, and `Time::advance_to` asserts on exactly that.
  send{ type = "time", paused = state.clock.paused }
end

--- Point the camera at a mesh that only has one side, and stop turning it away.
--
-- Bevy culls back faces, so a quad seen from behind is not dim — it is gone. With the turntable
-- running, picking the plane means watching an empty frame for half of every revolution and
-- dragging it back by hand, which is what "it gets put on the side I cannot see" is.
--
-- Two commands and not one: `reset` brings the angle home (a fresh scene faces the camera, but
-- the turntable has been running since the panel opened), and `spin` keeps it there. `reset`
-- also releases the turntable, so it has to come first.
--
-- Only on the TRANSITION, and the turntable comes back only if this is what stopped it. Yanking
-- the camera on every rebuild would fight the angle somebody chose for a material, and turning
-- the spin back on unasked would fight somebody who stopped it themselves.
local function face_if_flat(flat)
  if flat and not state.flat then
    send{ type = "camera", reset = true }
    send{ type = "camera", spin = false }
    state.spin_suspended = true
  elseif not flat and state.spin_suspended then
    send{ type = "camera", spin = true }
    state.spin_suspended = false
  end
  state.flat = flat
end

--- The bindings this preview cannot supply, as a sentence — or nil when there are none.
--
-- Almost nothing, now. A previewer's bind-group layout is fixed when IT is compiled, so it
-- cannot grow a sampler at 101 because this shader wants one there — but the SHADER can be
-- moved onto the slots that do exist, which is what `arbor.shader.preview` does before any of
-- this runs. Textures and samplers are therefore ordinary.
--
-- What is left is what no renumbering reaches: a storage buffer, a storage texture, a
-- comparison sampler, a depth texture — things filled by a pass this preview does not run —
-- and anything past the slot counts. The host names each one and says why, and the panel
-- repeats it, because a validation abort inside the viewport is a dead canvas rather than a
-- message somebody can act on.
local function blocking_resources(plan)
  if not plan or type(plan.rejected) ~= "table" then return nil end
  local names = {}
  for _, r in ipairs(plan.rejected) do
    names[#names + 1] = r.name .. " (@" .. tostring(r.binding) .. ") — " .. tostring(r.reason)
  end
  if #names == 0 then return nil end
  return table.concat(names, "; ")
end

--- Rebuild everything: document, shader, mesh, parameters.
local function push_open()
  if not state.source then return end
  -- Refused rather than attempted: see `blocking_resources`.
  if state.blocked then return end

  local geometry, err = mesh.build(state.mesh.id, state.mesh.params)
  if not geometry then
    arbor.notify{ title = "Shader preview", message = "Mesh: " .. tostring(err), level = "error" }
    return
  end

  local p = material_params()
  p.shader = state.source
  p.mesh   = { Raw = geometry }

  -- Which MATERIAL the document asks for follows from whether the shader declares its own
  -- block. One written to Bevy's convention wants the lit extension and its four `vec4` holes;
  -- one with its own struct wants the raw material and a byte buffer. Sending a document that
  -- asks for holes nobody filled is what "this scene needs a `p0` param" was.
  send{
    type   = "open",
    scene  = scene.to_ron(state.scene, state.own_group, state.vertex_entry),
    params = p,
  }

  face_if_flat(mesh.is_flat(geometry))
end

M.push_open = push_open

--- (Re)build the panel body from the current state.
--
-- Expensive: it remounts the viewport and the Bevy app starts over. Only for a change in the
-- panel's STRUCTURE — a different shader, a reload, the view being reopened.
local function show()
  arbor.ui.set_panel_content(VIEW_ID, ui.build(state, deps))
end

M.show = show

--- Move controls to values the panel decided, without rebuilding it.
--
-- What makes "load a look" and "random params" honest. A panel that sends numbers its own
-- fields do not show has stopped being a description of what you are looking at — and doing it
-- with a rebuild would restart the viewport to move a slider.
local function apply_values(map)
  local ops = {}
  for _, f in ipairs(state.fields) do
    local v = map[f.name]
    if v ~= nil then
      state.values[f.name] = v
      if f.widget == "readonly" then
        -- Nothing to move.
      elseif f.widget == "color" then
        pcall(function() arbor.ui.form.set_value{ name = f.name, value = params.to_hex(v) } end)
      elseif f.rows == 1 then
        pcall(function() arbor.ui.form.set_value{ name = f.name, value = v } end)
      else
        -- A `vec_field` holds its lanes on the NODE, not in the form's values, so it moves by
        -- patch rather than by `set_value`.
        local axes, lanes = { "x", "y", "z", "w" }, {}
        for i = 1, math.min(#v, 4) do lanes[axes[i]] = v[i] end
        ops[#ops + 1] = { id = f.name, set = { "value" }, value = lanes }
      end
    end
  end
  if #ops > 0 then
    pcall(function() arbor.ui.form.patch(ops) end)
  end
  push_params()
end

--- Refresh the look picker in place, so saving one does not restart the viewport.
local function refresh_templates()
  if not state.desc then return end
  local names = templates.names(state.path, mat_key())
  local options, placeholder = ui.template_options(names)
  local current = templates.preferred(state.path, mat_key()) or ""
  pcall(function()
    arbor.ui.form.patch{
      { id = "template_pick", merge = { options = options, placeholder = placeholder } },
      { id = "template_drop", merge = { disabled = (#names == 0) } },
    }
    arbor.ui.form.set_value{ name = "template_pick", value = current }
    arbor.ui.form.set_value{ name = "template_name", value = current }
  end)
end

--- What the panel's controls are, as one string.
--
-- Compared across a reload to answer the only question that decides whether the panel has to
-- be rebuilt: did the CONTROLS change? Editing a shader's body does not change them, and a
-- rebuild costs the viewport its running Bevy app.
local function control_signature()
  if not state.desc then return "" end
  local parts = { mat_key() }
  for _, f in ipairs(state.fields) do
    parts[#parts + 1] = f.name .. ":" .. tostring(f.ty) .. ":" .. tostring(f.widget)
  end
  -- Textures count as controls: a shader that grows one grows a row, and a panel rebuilt only
  -- when a uniform changed would still be showing the texture list of the shader before last.
  for _, t in ipairs((state.plan and state.plan.textures) or {}) do
    parts[#parts + 1] = "tex:" .. tostring(t.name) .. ":" .. tostring(t.key)
  end
  return table.concat(parts, "|")
end

--- Read the shader and ask Bennu what it declares. Answers whether the CONTROLS changed.
--
-- Values SURVIVE where the field survives. Reload is "the file changed", not "start over": a
-- material whose sliders reset every time you saved the shader would throw away the tuning
-- that is the entire work — and would look exactly like a preview that ignores its own panel.
local function reload()
  if not state.path then return false end
  local text, err = arbor.fs.read(state.path)
  if not text then
    arbor.notify{ title = "Shader preview", message = tostring(err), level = "error" }
    return false
  end
  local before = control_signature()

  local previous = state.values or {}
  local was = mat_key()

  -- First: the shader RENUMBERED onto the runtime's fixed slots.
  --
  -- This is what lets a material with textures be previewed at all. A previewer's bind-group
  -- layout is decided when it is compiled, so it cannot be made to match whatever indices a
  -- shader happens to use — the shader is moved onto the layout instead. `tile.wgsl` binds a
  -- sampler at 101 and ten textures from 100 up; renumbered, they land on slots that exist.
  --
  -- Everything downstream reads the rewritten copy, including the description: `pack_slots`
  -- works out which slot a block is from its binding, which is only true once the block is on
  -- one. Names, offsets and `// @preview` lines are untouched — the rewrite moves numbers
  -- inside `@binding(…)` and nothing else.
  local pok, plan = pcall(function()
    return arbor.shader and arbor.shader.preview{ source = text } or nil
  end)
  state.plan = (pok and type(plan) == "table") and plan or nil
  state.source = state.plan and state.plan.source or text

  -- The one call that makes the panel about THIS material. `nil` means the shader binds
  -- nothing in the material's group that Bennu can lay out — an answer, not a failure.
  local ok, desc = pcall(function()
    return arbor.shader and arbor.shader.uniform{ source = state.source } or nil
  end)
  -- Usable when the host found a block — which is what `key` marks, and which an empty
  -- `struct` (a bare-value binding) must not fail.
  state.desc = (ok and type(desc) == "table" and (desc.key or desc.struct)) and desc or nil

  -- Which material the runtime has to build. `owns_group` is the host's reading of the binding
  -- indices — Bevy's convention puts an extension's own uniforms at 100 and up, leaving the
  -- lower ones to the `StandardMaterial` underneath. Read rather than offered as a setting:
  -- getting it wrong is a pipeline mismatch, not a preference.
  -- From the PLAN when there is one: it reads the same indices and answers even for a shader
  -- whose parameter block Bennu could not lay out — a material that is nothing but textures
  -- still has to be built as the right kind.
  if state.plan ~= nil then
    state.own_group = state.plan.owns_group == true
  else
    state.own_group = (state.desc and state.desc.owns_group) == true
  end
  state.blocked = blocking_resources(state.plan)
  -- Quale materiale raw costruire. Dal piano, come `own_group`: entrambi sono letti dal
  -- sorgente perché sbagliarli è un layout che non combacia, non una preferenza.
  state.vertex_entry = (state.plan and state.plan.vertex_entry) == true

  -- The choices survive a reload by KIND, for the same reason a slider's value does: what to
  -- put in a material's normal maps is a decision somebody made, and losing it every time the
  -- file is saved would be a panel that forgets what you told it. A kind the shader no longer
  -- samples drops out; a new one arrives on the guess from its variable's name.
  local kept = {}
  for _, t in ipairs((state.plan and state.plan.textures) or {}) do
    if state.roles[t.key] ~= nil then kept[t.key] = state.roles[t.key] end
  end
  state.roles = kept

  if state.desc then
    state.fields = params.decorate(state.desc)
    state.values = params.defaults(state.fields)

    -- Open on the look this material was left with. Finding those values IS the work, and
    -- starting from neutral defaults every session throws it away silently.
    local preferred = templates.preferred(state.path, mat_key())
    local saved = preferred and templates.load(state.path, mat_key(), preferred, state.fields)
    for k, v in pairs((saved and saved.params) or {}) do state.values[k] = v end
    -- The rig and the mesh the look was judged under, when it has them. Restored here rather
    -- than left to the load handler because this path is "the panel is opening on this
    -- material", and opening it under a different lamp than the one the values were chosen
    -- for shows a picture nobody saved.
    if saved and type(saved.scene) == "table" then state.scene = saved.scene end
    if saved and type(saved.mesh) == "table" and type(saved.mesh.id) == "string" then
      state.mesh = { id = saved.mesh.id, params = saved.mesh.params or {} }
    end

    -- Then what is on screen wins over both, for every field that still exists and still has
    -- the shape it had. A renamed or retyped field has no value to keep.
    if was == mat_key() then
      for _, f in ipairs(state.fields) do
        local prev = previous[f.name]
        if prev ~= nil and type(prev) == type(state.values[f.name]) then
          state.values[f.name] = prev
        end
      end
    end
  else
    state.fields, state.values = {}, {}
  end

  push_open()
  return control_signature() ~= before
end

--- Take a shader: read it, fill the panel, reveal the panel.
local function open(path)
  -- Ricostruisce il pannello solo se serve, come fa gia' il reload.
  --
  -- `show()` passa da `set_panel_content`, che ri-chiavizza il renderer e quindi **rimonta
  -- l'iframe** — e rimontarlo mentre Bevy sta girando strappa la canvas da sotto il ciclo di
  -- winit, che muore con `RefCell already borrowed`. Non e' fatale (la nuova istanza parte),
  -- ma e' rumore che nasconde i panic veri, e meta' delle volte era gratuito: aprire uno
  -- shader con gli stessi controlli non cambia niente nel corpo del pannello.
  --
  -- Uno shader con controlli DIVERSI lo rimonta ancora. Toglierlo del tutto vuol dire
  -- rappezzare le sezioni invece di riscriverle, che e' un lavoro a se'.
  local fresh = state.path == nil or state.source == nil
  state.path = path
  local changed = reload()
  if fresh or changed then show() end
  arbor.ui.open_panel(VIEW_ID)
end

-- ── Actions the view and the toolbar fire ────────────────────────────────────

arbor.events.on("command:shader_preview.open", function()
  -- From a palette there is no "this one", so it asks — unless the editor is already on a
  -- shader, which is the overwhelmingly common case and the one a keystroke is for.
  local path = state.path or state.editor_wgsl
  if type(path) == "string" and path ~= "" then
    arbor.events.emit("shader_preview:open_path", { path = path })
  else
    arbor.events.emit("shader_preview:pick", {})
  end
end)

-- The rest of the palette's verbs are the panel's own buttons, reached by name. Each is one
-- line because the action already exists: what was missing was a way to ask for it without
-- finding it first.
arbor.events.on("command:shader_preview.reload", function()
  arbor.events.emit("shader_preview:reload", {})
end)
arbor.events.on("command:shader_preview.pause", function()
  arbor.events.emit("shader_preview:pause", {})
end)
arbor.events.on("command:shader_preview.random", function()
  arbor.events.emit("shader_preview:random", {})
end)
arbor.events.on("command:shader_preview.reset_camera", function()
  -- Straight to the runtime, not through `shader_preview:camera` — that event is the distance
  -- slider and wants a number. Reset is a different command on the same channel.
  send{ type = "camera", reset = true }
end)
arbor.events.on("command:shader_preview.save_look", function()
  arbor.events.emit("shader_preview:template_save", {})
end)

arbor.events.on("shader_preview:pick", function(ctx)
  -- `action`, not a callback.
  --
  -- `arbor.ui.pick_file` serialises its whole options table to JSON and emits it, so a Lua
  -- function in there cannot cross — the call raises and the picker never opens. The result
  -- comes back as an EVENT instead, with the chosen path in `ctx.path` and an empty string for
  -- a cancel. This handler passed `on_confirm` and had therefore never opened anything.
  --
  -- `initial_path` when the caller has an opinion about where to start: the examples command
  -- lands in this package's own folder, the plain picker leaves it out and gets wherever the
  -- explorer was last.
  local start = ctx and ctx.start
  arbor.log.info("shader-preview: opening the file picker")
  arbor.ui.pick_file{
    mode         = "file",
    title        = (type(start) == "string") and "Open an example shader" or "Open a shader",
    extensions   = { "wgsl" },
    initial_path = (type(start) == "string") and start or nil,
    action       = "shader_preview:picked",
  }
end)

arbor.events.on("shader_preview:picked", function(ctx)
  local path = ctx and ctx.path
  -- Empty is a cancel, not a failure — the picker reports both the same way.
  if type(path) ~= "string" or path == "" then return end
  open(path)
end)

--- The examples that ship with this package.
--
-- Four materials that exist to be READ, not used: each is one technique carried far enough to
-- look like something — domain warping for magma, anisotropic noise for a waterfall, angular
-- folding for a kaleidoscope, ridged noise for a nebula. Every lane is annotated, so opening one
-- fills the panel with named controls and the fastest way to understand a technique is to drag
-- it until it breaks.
--
-- They live beside the plugin rather than in a settings folder because they are part of what
-- the package IS: a viewer with nothing to view teaches nobody anything.
arbor.events.on("command:shader_preview.examples", function()
  local ok, start = pcall(function()
    return arbor.fs.join(arbor.meta.plugin_dir(), "examples")
  end)
  -- Tracciato, e non per abitudine. Fra "la palette non ha chiamato il plugin", "il plugin non
  -- trova la propria cartella" e "il picker non si apre" non c'e' differenza visibile — sono
  -- tutte e tre "non succede niente" — e questa riga le separa in un colpo solo.
  arbor.log.info("shader-preview: examples command, start = " .. tostring(ok and start or "<none>"))
  arbor.events.emit("shader_preview:pick", { start = ok and start or nil })
end)

--- Re-read the file. The panel is rebuilt only if the CONTROLS changed.
--
-- Editing a shader's body is the common case and changes none of them, and a rebuild would
-- remount the frame and restart the Bevy app for nothing — several seconds of black in place
-- of the recompile you asked for.
arbor.events.on("shader_preview:reload", function()
  if reload() then show() end
end)

--- The editor toolbar button: preview THE FILE THAT IS OPEN.
--
-- The palette entry has to ask which file, because from a palette there is no "this one". From
-- the toolbar there is, and asking anyway would be a picker in front of an answer the user
-- already gave by opening the file.
arbor.events.on("shader_preview:open_path", function(ctx)
  local path = ctx and ctx.path
  if type(path) ~= "string" or path == "" then return end
  open(path)
end)

-- ── Reading a control back ───────────────────────────────────────────────────
--
-- Three shapes arrive on `value`, because three kinds of control send it: a `vec_field` lane
-- sends `{axis, index, value}`, a colour sends `#rrggbb`, and everything else sends a number.

--- The new value for `id`, given what the control sent and what it held before.
local function value_from(val, previous)
  -- A toggle sends a boolean, and `tonumber(false)` is nil — so without this arm every switch
  -- in the panel would read as "nothing changed" and do nothing at all.
  if type(val) == "boolean" then return val end
  if type(val) == "table" and type(val.value) == "boolean" then return val.value end
  if type(val) == "table" and val.index ~= nil and type(previous) == "table" then
    local i = (tonumber(val.index) or 0) + 1
    local n = tonumber(val.value)
    if n and i >= 1 and i <= #previous then
      local out = {}
      for k, v in ipairs(previous) do out[k] = v end
      out[i] = n
      return out
    end
    return nil
  end
  if type(val) == "string" and val:match("^#%x+$") then
    -- Converted back to linear here rather than at the boundary, because the previous value is
    -- what carries the alpha the field cannot show.
    return params.from_hex(val, previous)
  end
  local raw = type(val) == "table" and val.value or val
  -- A word, when a word is what was there before — a blend mode, a picker. Decided by the
  -- PREVIOUS value and not by the incoming one, so a numeric field that arrives as the string
  -- "0.5" is still read as a number.
  if type(previous) == "string" and type(raw) == "string" then return raw end
  return tonumber(raw)
end

--- The clock. Stop it, start it, or move it to an instant.
--
-- Three events and not one because they are three gestures: a button, a slider, and a pair of
-- nudges. All three land on the same two-field state, so whichever a frame sees last is right.
arbor.events.on("shader_preview:pause", function()
  -- The controls are NOT moved here. The runtime answers every clock command with what the
  -- clock now is, and that reply is what repaints the button and the scrub — one writer, and
  -- it is the one holding the truth. Moving them here as well would show the panel's intent
  -- for the frame or two before the reply lands, which is the window in which they disagree.
  set_paused(not state.clock.paused)
end)

arbor.events.on("shader_preview:time", function(ctx)
  local at = tonumber(type(ctx.value) == "table" and ctx.value.value or ctx.value)
  if at == nil then return end
  state.clock.at = math.max(0, at)
  -- Scrubbing IS asking for it to hold still: a running clock is recomputed from the real one
  -- every frame and would overwrite the instant before anything is drawn.
  state.clock.paused = true
  push_time()
end)

arbor.events.on("shader_preview:step", function(ctx)
  -- A delta, sent as a delta. The runtime knows where the clock is and the panel does not —
  -- adding to a remembered value and sending the sum is how the two drift apart, and the
  -- first symptom of that is a jump backwards, which panics.
  local by = tonumber(ctx and ctx.data and ctx.data.by) or 0.05
  send{ type = "time", paused = true, step = by }
end)

--- A texture KIND changed — what picture to fill its slot with.
--
-- The cheap path, like a slider: the roles ride in the same `update` the parameters do, so
-- the frame keeps its camera and its Bevy app. The image itself is generated once per role by
-- the runtime and cached, so flipping between them costs nothing after the first look.
arbor.events.on("shader_preview:texture", function(ctx)
  local name = ctx and ctx.node_id
  if type(name) ~= "string" then return end
  -- The node is named after the KIND, so one control drives every texture of that kind — both
  -- faces of a normal map, all four variants of an atlas. Which is the point: in a preview
  -- they would be handed the same generated picture anyway.
  local key = name:gsub("^tex%.", "")
  local role = ctx.value
  role = type(role) == "table" and role.value or role
  if type(role) ~= "string" then return end
  state.roles[key] = role
  push_params()
end)

--- One control of the material's own parameters moved.
--
-- Deliberately NOT followed by `show()`: rebuilding the panel on a slider tick would recreate
-- the viewport frame mid-drag and throw away the running Bevy app.
arbor.events.on("shader_preview:param", function(ctx)
  local id = ctx and ctx.node_id
  if type(id) ~= "string" then return end
  local next_value = value_from(ctx.value, state.values[id])
  if next_value == nil then return end
  state.values[id] = next_value
  push_params()
end)

--- A knob on the rig moved. In the document, so the document is rewritten and sent.
arbor.events.on("shader_preview:scene", function(ctx)
  local path = ctx and ctx.node_id
  if type(path) ~= "string" then return end
  local next_value = value_from(ctx.value, scene.get(state.scene, path))
  if next_value == nil then return end
  scene.set(state.scene, path, next_value)
  push_open()
end)

--- The camera. A command, not the document — see `ui.lua`'s camera section for why.
arbor.events.on("shader_preview:camera", function(ctx)
  local d = tonumber(type(ctx.value) == "table" and ctx.value.value or ctx.value)
  if not d then return end
  state.scene.camera.distance = d
  send{ type = "camera", absolute_distance = d }
end)

arbor.events.on("shader_preview:mesh", function(ctx)
  local id = ctx and ctx.value
  if type(id) ~= "string" or id == state.mesh.id then return end
  state.mesh = { id = id, params = mesh.defaults(mesh.kind(id)) }
  -- A different shape declares different knobs, so the form has to change with it — patched
  -- in rather than rebuilt, because a rebuild would restart the viewport to swap two rows.
  pcall(function()
    arbor.ui.form.patch{
      { id = "mesh_params", set = { "children" }, value = ui.mesh_param_nodes(state, mesh) },
      { id = "mesh", merge = { note = mesh.kind(id).label } },
    }
  end)
  push_open()
end)

arbor.events.on("shader_preview:mesh_param", function(ctx)
  local id = ctx and ctx.node_id
  if type(id) ~= "string" then return end
  local name = id:match("^mesh%.(.+)$")
  if not name then return end
  local raw = type(ctx.value) == "table" and ctx.value.value or ctx.value
  -- A number for a slider, a word for a picker. `block` chooses its solid with a word, and
  -- reading everything through `tonumber` dropped it on the floor — the control moved and the
  -- mesh did not.
  local value = tonumber(raw)
  if value == nil and type(raw) == "string" and raw ~= "" then value = raw end
  if value == nil then return end
  state.mesh.params[name] = value
  push_open()
end)

arbor.events.on("shader_preview:random", function()
  if not state.desc then return end
  apply_values(params.randomise(state.fields))
end)

-- ── Templates ────────────────────────────────────────────────────────────────

arbor.events.on("shader_preview:template_load", function(ctx)
  local name = ctx and ctx.value
  if not state.desc or type(name) ~= "string" or name == "" then return end
  local loaded = templates.load(state.path, mat_key(), name, state.fields)
  if not loaded then return end
  -- Loading marks it: the common case is settling on a look and carrying on with it, which
  -- should not need a second gesture to make stick.
  templates.set_preferred(state.path, mat_key(), name)

  -- The rig and the mesh come back with the numbers, when the look carried them. A look saved
  -- before they did has neither, and leaving what is on screen alone is the right answer for
  -- that — putting back a default rig would be inventing something the file never said.
  local rebuild = false
  if type(loaded.scene) == "table" then
    state.scene = loaded.scene
    rebuild = true
  end
  if type(loaded.mesh) == "table" and type(loaded.mesh.id) == "string" then
    state.mesh = { id = loaded.mesh.id, params = loaded.mesh.params or {} }
    rebuild = true
  end

  apply_values(loaded.params)
  if rebuild then
    -- A rig or a mesh is in the DOCUMENT, so it needs the scene resent — and the panel's own
    -- controls have to follow, or the sliders would describe a light that is no longer there.
    push_open()
    show()
  end
  pcall(function() arbor.ui.form.set_value{ name = "template_name", value = name } end)
end)

--- Read a field's live value out of a whole-form button payload.
--
-- A `button` node ships the form's VALUES at the top level and the plugin-owned opaque `state`
-- under `state`. The name you just typed is a value, so it is the top level that has it —
-- `state.template_name` is whatever the panel was BUILT with, which is the previous name or
-- nothing at all. Both are read, in that order, so a payload shaped either way works.
local function field_of(ctx, key)
  if type(ctx) ~= "table" then return nil end
  local v = ctx[key]
  if v == nil and type(ctx.state) == "table" then v = ctx.state[key] end
  return v
end

arbor.events.on("shader_preview:template_save", function(ctx)
  if not state.desc then return end
  local name = field_of(ctx, "template_name")
  name = (type(name) == "string") and name:match("^%s*(.-)%s*$") or ""
  if name == "" then
    arbor.notify{ title = "Shader preview", message = "Give the look a name first.", level = "warning" }
    return
  end
  templates.save(state.path, mat_key(), name, state.values, state.scene, state.mesh)
  refresh_templates()
end)

arbor.events.on("shader_preview:template_delete", function(ctx)
  if not state.desc then return end
  local name = field_of(ctx, "template_pick")
  if type(name) ~= "string" or name == "" then return end
  templates.remove(state.path, mat_key(), name)
  refresh_templates()
end)

--- Whatever the viewport says back.
arbor.events.on("shader_preview:message", function(ctx)
  local msg = ctx and ctx.value
  if type(msg) ~= "table" then return end
  if msg.type == "log" then
    -- The runtime's and the page's own trace lines, surfaced where the user can read them.
    arbor.log.info(tostring(msg.message))
  elseif msg.type == "error" then
    -- The runtime's own words: a WGSL error from Bevy names the line, and rewording it here
    -- would lose the only part that helps.
    --
    -- But two different failures ride this one channel, and calling both of them "the shader
    -- did not compile" sends somebody to read a file that is fine. A scene that will not parse
    -- is OURS — the panel wrote that document — and the difference is the difference between
    -- half an hour on the wrong file and reading one line.
    local text = tostring(msg.message)
    local ours = text:find("RON", 1, true) or text:find("scene", 1, true)
    arbor.notify{
      title   = ours and "Shader preview could not build the scene" or "Shader did not compile",
      message = text,
      level   = "error",
      -- Kept. A toast that fades takes the only explanation with it, and what the panel shows
      -- meanwhile is an empty viewport, which says nothing at all.
      persist = true,
    }
  elseif msg.type == "time" then
    -- The clock, as the runtime has it. The panel adopts rather than assumes: it is the only
    -- way the scrub can open on the instant you stopped at instead of on zero.
    local at = tonumber(msg.at)
    if at then state.clock.at = at end
    state.clock.paused = msg.paused == true
    pcall(function()
      arbor.ui.form.set_value{ name = "clock_at", value = state.clock.at }
      arbor.ui.form.patch{
        { id = "clock_at", merge = { disabled = not state.clock.paused } },
        { id = "clock_toggle", merge = {
          label   = state.clock.paused and "Play" or "Pause",
          icon    = state.clock.paused and "Play" or "Pause",
          tooltip = state.clock.paused and "Let the clock run again"
                                        or "Stop the clock, so a change is the only thing that moved",
        } },
      }
    end)
  elseif msg.type == "ready" then
    arbor.log.info("shader-preview: viewport ready")
  end
end)

-- ── Startup ──────────────────────────────────────────────────────────────────

arbor.events.on("arbor:plugin_load", function()
  if not arbor.meta.plugin_loaded("bevy-runtime") then
    arbor.notify{
      title = "Shader preview",
      message = "The bevy-runtime package is not installed — there is nothing to draw in.",
      level = "warning",
    }
    return
  end
  if not arbor.shader then
    -- Published by Bennu and by nothing else. Without it this plugin would have to read WGSL
    -- itself, which is exactly the thing it is built not to do.
    arbor.notify{
      title = "Shader preview",
      message = "This product does not read WGSL, so a material's own parameters cannot be shown.",
      level = "warning",
    }
  end

  state.runtime_page = runtime_page()
  -- The catalogue is NOT asked for here. `arbor.ext.call` reaches another package, and this
  -- hook runs while packages are still coming up; a call that came back empty would be the
  -- answer the picker kept. It is asked the first time the panel is built, which is after.

  -- ── Commands, and the keys that reach them ────────────────────────────────
  --
  -- Every action in this panel is on this list, and that is not tidiness: Arbor's working
  -- agreement is that a flow you cannot finish from the keyboard is a broken flow, and a panel
  -- whose only entry point is a toolbar icon fails it on the first gesture. The palette is also
  -- how somebody FINDS a verb — a button in a collapsed section is a button nobody knows about.
  for _, c in ipairs({
    { id = "open",           title = "Shader: preview a WGSL material",
      description = "Open a .wgsl file in a Bevy viewport with its own parameters on sliders.",
      icon = "eye" },
    { id = "reload",         title = "Shader preview: reload from disk",
      description = "Re-read the file and recompile, keeping the values you have tuned.",
      icon = "refresh-cw" },
    { id = "pause",          title = "Shader preview: stop or start the clock",
      description = "Pin the instant, so a parameter change is the only thing that moved.",
      icon = "pause" },
    { id = "random",         title = "Shader preview: random parameters",
      description = "Move every control somewhere inside its own range.",
      icon = "shuffle" },
    { id = "reset_camera",   title = "Shader preview: reset the camera",
      description = "Put the framing back where the scene asked for it.",
      icon = "video" },
    { id = "examples",       title = "Shader preview: open an example",
      description = "Four annotated materials — magma, waterfall, kaleidoscope, nebula.",
      icon = "sparkles" },
    { id = "save_look",      title = "Shader preview: save this look",
      description = "Keep the parameters, the light rig and the mesh under a name.",
      icon = "bookmark" },
  }) do
    arbor.command.register{
      id          = "shader_preview." .. c.id,
      title       = c.title,
      description = c.description,
      icon        = c.icon,
    }
  end

  -- Two keys, for the two things done often enough to deserve one. `Alt+Shift` and not
  -- `Ctrl+Alt`: on IT/DE/FR/ES keyboards Chromium drops `Ctrl+Alt+<letter>` to preserve AltGr.
  arbor.keybinding.register{
    key = "p", shift = true, alt = true,
    action = "command:shader_preview.open",
    description = "Preview the open WGSL material",
  }
  arbor.keybinding.register{
    key = "r", shift = true, alt = true,
    action = "command:shader_preview.reload",
    description = "Reload the previewed shader from disk",
  }

  -- A button on the editor's own toolbar, on shader files only. `path_pattern` is what keeps
  -- that bar meaning "what kind of file is this": without it this would be a plugin icon
  -- sitting on every Java class in the project.
  arbor.ui.contribute("arbor:editor-toolbar", {
    id      = "preview",
    payload = {
      icon         = "Eye",
      tooltip      = "Preview this shader in a 3D viewport",
      action       = "shader_preview:open_path",
      path_pattern = "*.wgsl",
    },
  })

  arbor.ui.add_view{
    id      = VIEW_ID,
    label   = "Shader preview",
    icon    = "Eye",
    tooltip = "The open .wgsl, rendered by Bevy",
  }

  arbor.log.info("shader-preview ready")
end)

--- The view was (re)opened. Content is not persisted across a plugin reload, so a panel that
--- was open before one would otherwise come back blank.
arbor.events.on("arbor:view_open", function(ctx)
  if ctx and ctx.view_id == VIEW_ID then
    state.view_open = true
    show()
  end
end)

arbor.events.on("arbor:view_close", function(ctx)
  if ctx and ctx.view_id == VIEW_ID then state.view_open = false end
end)

--- Follow the editor.
--
-- A preview of one shader, sitting beside a different one being edited, is a panel showing the
-- wrong thing — and the only clue is the file name in its own title. So an open preview follows
-- the tab.
--
-- Only when it is ALREADY open, and only for a shader. Opening the panel because somebody
-- clicked a `.wgsl` in the tree would be a plugin deciding what the screen is for; following a
-- panel you deliberately opened is finishing the job you asked for.
arbor.events.on("bennu:file_opened", function(ctx)
  local path = ctx and ctx.path
  if type(path) == "string" and (ctx.ext or ""):lower() == "wgsl" then
    -- Remembered even while the panel is shut. There is no way to ASK the editor what it is
    -- showing, so the only record of it is the one kept as it happens — and without it a
    -- keystroke meant for "preview this" has to open a file picker over a file already on
    -- screen, which is the kind of small insult that stops people using the key.
    state.editor_wgsl = path
  end
  if not state.view_open then return end
  if type(path) ~= "string" or path == "" or path == state.path then return end
  if (ctx.ext or ""):lower() ~= "wgsl" then return end
  open(path)
end)

M.runtime_page = runtime_page
return M
