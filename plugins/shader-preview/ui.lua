-- The view's body: the viewport on top, everything that changes it underneath.
--
-- Split out because `main.lua` is about *what* to show and this is about *how* — and the how
-- is a pure function of the state, so there is never a half-updated panel.
--
-- It is a VIEW, not a form. A modal is for a question with an answer; a preview is neither —
-- nothing to submit, nothing to cancel — and putting it behind a dialog covered the shader you
-- were editing with a picture of it.
--
-- ## The shape, and why it is this one
--
-- Quiet sections, not cards. Six bordered boxes stacked in a column as narrow as Bennu's right
-- split read as six competing panels; a caption over a list of rows reads as one panel with
-- headings. Every group folds, and the ones you rarely touch open folded.
--
-- Compact rows, not stacked labels. A label above its own slider doubles the height of every
-- control, and a material with ten parameters then does not fit on a screen — which turns
-- comparing two of them into scrolling between them. The label column is pinned with
-- `--pf-label-col` so the sliders line up instead of stepping in and out with the names.

local M = {}

-- The label column, in px. Wide enough for `ridge_sharpness` at this font, narrow enough to
-- leave a slider worth dragging in a 320px panel.
local FIELD_COLUMN = "--pf-label-col: 92px"

-- How often a dragged control is allowed to reach the runtime.
--
-- Two numbers because the two surfaces cost different amounts. A material parameter sends new
-- bytes for one uniform, so it can keep up with a drag; a light or a background is IN the scene
-- document, so moving it rewrites the document and re-sends the mesh with it. Letting that run
-- at pointer rate is how a light slider turns into a slideshow.
local PARAM_MS = 40
local SCENE_MS = 150

--- A container whose children are compact rows sharing one label column.
local function rows(id, children)
  return {
    type     = "container",
    id       = id,
    style    = FIELD_COLUMN .. "; display: flex; flex-direction: column; gap: 3px",
    children = children,
  }
end

local function section(id, title, note, collapsed, children)
  return {
    type        = "section",
    id          = id,
    variant     = "quiet",
    title       = title,
    note        = note,
    collapsible = true,
    collapsed   = collapsed,
    children    = children,
  }
end

-- ── One control per declared value ───────────────────────────────────────────
--
-- The node type follows from what the field IS. A colour gets a colour picker because a shader
-- author who called it `sand_color` meant one; a scalar gets a slider AND its value, because
-- you drag to find a value and read the number to keep it.
--
-- `actions.change` as an OBJECT, not a bare string: a bare string takes the legacy path and
-- ships the whole form without saying which field moved, while the object form dispatches
-- scoped and carries `node_id` — the only thing that tells one of ten sliders from another.

local function colour_row(id, label, hex, action, debounce)
  return {
    type        = "color",
    id          = id,
    name        = id,
    label       = label,
    compact     = true,
    -- The swatch alone. A `#rrggbb` field beside it is a second way to say the same thing,
    -- and in a pinned label column it leaves the swatch too narrow to read as a colour.
    show_hex    = false,
    default     = hex,
    debounce_ms = debounce or PARAM_MS,
    actions     = { change = { kind = "action", name = action } },
  }
end

local function range_row(id, label, value, spec, action, hint, debounce)
  return {
    type        = "range",
    id          = id,
    name        = id,
    label       = label,
    hint        = hint,
    compact     = true,
    default     = value,
    min         = spec.min or 0,
    max         = spec.max or 1,
    step        = spec.step or 0.01,
    debounce_ms = debounce or PARAM_MS,
    actions     = { change = { kind = "action", name = action } },
  }
end

local function vec_row(id, label, values, spec, action, debounce)
  local axes = { "x", "y", "z", "w" }
  local lanes, v = {}, {}
  for i = 1, math.min(#values, 4) do
    lanes[i] = axes[i]
    v[axes[i]] = values[i]
  end
  -- A slider only where the range is KNOWN. A light direction runs −1 to 1 and a colour
  -- channel 0 to 1, so dragging one is the natural gesture; a shader's own `vec4` has no range
  -- anybody can guess — `mole_params.x` is a panel count in the tens and `.z` is a depth in
  -- [0,1] — and a slider pinned to an invented 0..1 cannot even reach the value the shader
  -- wants. Where nothing is known the lanes are typed, which is the control that always works.
  local ranged = spec.min ~= nil and spec.max ~= nil

  return {
    type     = "vec_field",
    id       = id,
    label    = label,
    compact  = true,
    axes     = lanes,
    value    = v,
    slider   = ranged,
    min      = spec.min or 0,
    max      = spec.max or 1,
    step     = spec.step or 0.01,
    debounce_ms = debounce or PARAM_MS,
    -- Here a bare string is right: `vec_field` dispatches scoped either way, so the node ships
    -- `{node_id, slot, value:{axis, index, value}}` and one handler serves every lane.
    dispatch = action,
  }
end

--- One control for one parameter the material declares.
--
-- `f.label` when the shader's author named it in a `// @preview` line, `f.name` otherwise —
-- which for an expanded lane is the only name there is, and for everything else is the name
-- WGSL already gave.
local function control_for(f, value, params)
  local label = f.label or f.name
  if f.widget == "readonly" then
    -- A matrix. Shown so the panel does not silently omit a parameter the material has, not
    -- editable because deciding what a mat3x3 editor looks like is a design question of its
    -- own and a wrong answer is worse than an honest gap.
    -- A leaf `field`, not a `label` node: `label` renders its text and nothing else, so the
    -- parameter's NAME — the only part worth keeping — would not appear.
    return {
      type    = "field",
      id      = "ro." .. f.name,
      label   = label,
      kind    = "readonly",
      value   = f.ty .. " — not editable here",
      compact = true,
    }
  end
  if f.widget == "color" then
    -- The node speaks sRGB hex because that is what a colour input speaks; the material speaks
    -- linear. `params` owns the conversion so it is written once.
    return colour_row(f.name, label, params.to_hex(value), "shader_preview:param")
  end
  if f.rows == 1 then
    -- A scalar gets a real slider, not a one-lane vector: an "X" label on `spiral_speed` is
    -- noise that reads as a mistake.
    return range_row(f.name, label, value, f, "shader_preview:param", f.hint)
  end
  return vec_row(f.name, label, value, f, "shader_preview:param")
end

-- ── The template bar ─────────────────────────────────────────────────────────
--
-- Many looks per material, and the last one used opens by itself. Two gestures, both cheap:
-- pick from the list to switch, or type a name and press Save to keep what is on screen.
--
-- The name is an input node rather than a dialog: the working agreement rules the browser's
-- prompts out entirely, and a field beside the button is the version that also lets Enter
-- finish the job.
--- The name this material's saved looks are filed under — see `mat_key` in `main.lua`.
local function mat_key(state)
  local d = state.desc or {}
  if type(d.key) == "string" and d.key ~= "" then return d.key end
  if type(d.struct) == "string" and d.struct ~= "" then return d.struct end
  return "material"
end

local function template_bar(state, templates)
  local names = templates.names(state.path, mat_key(state))
  local current = templates.preferred(state.path, mat_key(state))

  -- Built only when there is something in it, and the key is OMITTED otherwise: Lua has one
  -- table type, so an empty `{}` serialises as a JSON object rather than an array.
  local options = nil
  if #names > 0 then
    options = {}
    for i, n in ipairs(names) do options[i] = { value = n, label = n } end
  end

  return {
    type     = "row",
    gap      = 6,
    align    = "end",
    children = {
      {
        type    = "select",
        id      = "template_pick",
        name    = "template_pick",
        label   = "Look",
        default = current,
        -- Says what the state IS rather than sitting blank: "nothing saved yet" is an answer,
        -- an empty dropdown is a puzzle.
        placeholder = (#names > 0) and "pick a look" or "no looks saved yet",
        options = options,
        style   = "flex: 2 1 0; min-width: 0",
        actions = { change = "shader_preview:template_load" },
      },
      {
        type          = "text",
        id            = "template_name",
        name          = "template_name",
        placeholder   = "name…",
        default       = current or "",
        size          = "sm",
        style         = "flex: 1 1 0; min-width: 0",
        submit_action = "shader_preview:template_save",
      },
      -- A `button` ships the whole form, so the name typed beside it and the look picked
      -- from the list arrive on their own. (`scope_state` is a scoped-slot thing; a button
      -- does not take the scoped path, and asking for it here would read as if it did.)
      {
        type      = "button",
        icon      = "Save",
        icon_only = true,
        action    = "shader_preview:template_save",
        tooltip   = "Keep the values on screen under this name",
      },
      {
        type      = "button",
        id        = "template_drop",
        icon      = "Trash2",
        icon_only = true,
        action    = "shader_preview:template_delete",
        tooltip   = "Forget the selected look",
        disabled  = (#names == 0),
      },
    },
  }
end

-- ── Groups ───────────────────────────────────────────────────────────────────

--- One control for one mesh parameter, whichever kind it is.
--
-- Shared by the section and the patch path, because a mesh change swaps these rows in place
-- and the two ways of producing them must not be two ways of deciding what they look like.
local function mesh_row(f, value)
  if f.kind == "select" then
    return {
      type    = "select",
      id      = "mesh." .. f.name,
      name    = "mesh." .. f.name,
      label   = f.label,
      compact = true,
      hint    = f.hint,
      default = tostring(value or f.default),
      options = f.options,
      actions = { change = "shader_preview:mesh_param" },
      style   = FIELD_COLUMN,
    }
  end
  return range_row("mesh." .. f.name, f.label, value or f.default, f,
                   "shader_preview:mesh_param", f.hint, SCENE_MS)
end

local function mesh_section(state, mesh)
  local kind = mesh.kind(state.mesh.id)
  local options = {}
  for i, k in ipairs(mesh.catalogue()) do
    options[i] = { value = k.id, label = k.label, description = k.description }
  end

  local fields = {}
  for _, f in ipairs(mesh.fields(kind)) do
    fields[#fields + 1] = mesh_row(f, state.mesh.params[f.name])
  end

  return section("mesh", "Mesh", kind.label, false, {
    {
      type    = "select",
      id      = "mesh_pick",
      name    = "mesh_pick",
      label   = "Shape",
      compact = true,
      -- The RESOLVED id, not the stored one. Ids are qualified as `<provider>/<shape>` now
      -- that the picker lists every installed mesh package, and a state carrying the bare
      -- `sphere` — the default, or a look saved before — would match no option and leave the
      -- dropdown blank on a panel that is showing a sphere.
      default = kind.id,
      options = options,
      -- `actions.change`, NOT `change_action`. The bare key is legacy and only the `tree` node
      -- still reads it — on a `select` it is silently ignored, which is a picker that changes
      -- its own label and tells nobody.
      actions = { change = "shader_preview:mesh" },
      style   = FIELD_COLUMN,
    },
    rows("mesh_params", fields),
  })
end

--- The camera, driven by a COMMAND and not by the scene document.
--
-- The runtime keeps the live camera across a rebuild on purpose — a slider must not throw away
-- the angle you dragged to — so a distance written into a regenerated document would be
-- ignored from the second open onward.
--
-- One control, deliberately. Orbit, zoom, turntable and reset are all on the picture already,
-- as the buttons floating over the viewport and as drag and wheel; repeating them down here
-- would be a second place to do the same thing, and a turntable checkbox would additionally go
-- stale the moment somebody grabs the model — the runtime stops spinning and has no way to say
-- so. What a field adds that the picture cannot is a distance you can read and return to.
local function camera_section(state)
  return section("camera", "Camera", "drag to orbit", true, {
    rows("camera_rows", {
      range_row("camera.distance", "Distance", state.scene.camera.distance,
                { min = 0.6, max = 12, step = 0.05 }, "shader_preview:camera"),
    }),
  })
end

--- The pictures a texture slot can be filled with, and what each one means.
--
-- Words rather than files, because a preview has no assets: the atlas this material is fed in
-- the game lives in a project the viewport cannot reach. What it CAN do is generate the
-- picture, and which one is a better answer than flat white follows from what the texture IS —
-- which is why the default comes from the kind and this is an override rather than a required
-- choice.
local TEXTURE_IMAGES = {
  { value = "checker", label = "Chequer",  description = "Two greys. Shows where the UVs go." },
  { value = "white",   label = "White",    description = "Neutral to multiply by — an albedo, a mask, an AO." },
  { value = "grey",    label = "Grey",     description = "Mid. A height, a roughness, a packed PBR map." },
  { value = "black",   label = "Black",    description = "Nothing added — an emissive that is off." },
  { value = "normal",  label = "Flat normal", description = "(0.5, 0.5, 1). The map that perturbs nothing." },
  { value = "noise",   label = "Noise",    description = "Tiling value noise, for a map that needs structure." },
  { value = "uv",      label = "UV",       description = "The coordinates as red and green. The diagnostic one." },
}

--- The binding a declaration has IN THE FILE, not the one the preview moved it to.
--
-- Everything downstream of the rewrite sees the renumbered copy, so a row reading `@120` sends
-- somebody looking for a `@binding(120)` their shader does not contain. The plan keeps both
-- numbers precisely so the panel can show the one that is true of the file.
local function original_binding(state, name, fallback)
  for _, family in ipairs({ "textures", "samplers", "uniforms" }) do
    for _, r in ipairs((state.plan and state.plan[family]) or {}) do
      if r.name == name then return r.from end
    end
  end
  return fallback
end

--- One row per KIND of texture the material samples.
--
-- Per kind and not per variable, because a preview has no assets: `top_normal` and
-- `side_normal` would be handed byte-identical generated pictures, so listing both is two
-- controls for one decision — and, with four slots in the browser, two slots for one picture.
-- Sharing them is not a compromise; it is what makes a ten-texture material fit.
--
-- The variables under each kind are named on the row, so nothing is hidden: you can still see
-- that `normal` means those two. An author who genuinely wants them apart says so in the
-- shader — `// @preview normal.top` and `// @preview normal.side` are two kinds.
local function texture_section(state)
  local list = state.plan and state.plan.textures
  if type(list) ~= "table" or #list == 0 then return nil end

  -- Grouped in first-seen order, which is binding order — so the row that owns a slot is the
  -- row listed first, and the panel reads in the order the shader declares things.
  local order, group = {}, {}
  for _, t in ipairs(list) do
    local k = t.key or "diffuse"
    if group[k] == nil then
      group[k] = { key = k, members = {}, aliased = t.aliased, image = t.image, hint = t.hint }
      order[#order + 1] = k
    end
    local g = group[k]
    g.members[#g.members + 1] = t.name
    -- A kind is short of a slot only if every one of its textures is.
    g.aliased = g.aliased and t.aliased
  end

  local fields, shared = {}, 0
  for _, k in ipairs(order) do
    local g = group[k]
    if g.aliased then shared = shared + 1 end
    fields[#fields + 1] = {
      type    = "select",
      id      = "tex." .. k,
      name    = "tex." .. k,
      label   = k,
      compact = true,
      -- Which variables this drives. The one thing a keyed row must not do is make you guess
      -- what it covers.
      hint    = g.hint or table.concat(g.members, ", "),
      default = state.roles[k] or g.image or "checker",
      options = TEXTURE_IMAGES,
      actions = { change = "shader_preview:texture" },
      style   = FIELD_COLUMN,
    }
  end

  local note = #order .. " · " .. #list .. " bindings"
  if shared > 0 then note = note .. " · " .. shared .. " sharing" end
  local children = { rows("texture_body", fields) }
  if shared > 0 then
    -- The real number, read from the plan rather than written here: it is not one number. A
    -- material extending StandardMaterial has its six textures underneath it and a material
    -- owning its bind group has none, so the same window has room for more of the second.
    local slots = tonumber(state.plan and state.plan.layout and state.plan.layout.textures) or 0
    table.insert(children, 1, {
      type    = "alert",
      id      = "tex_shared",
      variant = "info",
      style   = "inline",
      title   = "More kinds of texture than the viewport has slots",
      text    = "A fragment stage in the browser gets sixteen texture units in total, across "
             .. "every bind group, used or not — and the engine has spent most of them before "
             .. "the material is reached. This one has " .. slots .. ". The kinds past that "
             .. "read another one's picture; `bennu_shader_render` runs natively and has twelve.",
    })
  end
  return section("textures", "Textures", note, false, children)
end

local function scene_sections(state, scene, params)
  local out = {}
  for _, g in ipairs(scene.groups(state.own_group)) do
    local fields = {}
    for _, f in ipairs(g.fields) do
      local value = scene.get(state.scene, f.path)
      if f.kind == "toggle" then
        -- No `compact`: a toggle renders its own label inline, so the three-column grid would
        -- leave the label column empty and squeeze the switch into it.
        fields[#fields + 1] = {
          type    = "toggle",
          id      = f.path,
          name    = f.path,
          label   = f.label,
          default = value == true,
          actions = { change = { kind = "action", name = "shader_preview:scene" } },
        }
      elseif f.kind == "color" then
        fields[#fields + 1] = colour_row(f.path, f.label, params.to_hex(value),
                                         "shader_preview:scene", SCENE_MS)
      elseif f.kind == "vec3" then
        fields[#fields + 1] = vec_row(f.path, f.label, value, f, "shader_preview:scene", SCENE_MS)
      elseif f.kind == "select" then
        fields[#fields + 1] = {
          type    = "select",
          id      = f.path,
          name    = f.path,
          label   = f.label,
          compact = true,
          hint    = f.hint,
          default = value,
          options = f.options,
          actions = { change = "shader_preview:scene" },
          style   = FIELD_COLUMN,
        }
      else
        fields[#fields + 1] = range_row(f.path, f.label, value, f, "shader_preview:scene",
                                        nil, SCENE_MS)
      end
    end
    out[#out + 1] = section(g.id, g.title, nil, g.collapsed, { rows(g.id .. "_rows", fields) })
  end
  return out
end

-- ── The panel ────────────────────────────────────────────────────────────────

function M.build(state, deps)
  local templates, params, scene, mesh = deps.templates, deps.params, deps.scene, deps.mesh
  local nodes = {}

  if not state.source then
    return {
      title = "Shader preview",
      nodes = { {
        type    = "state_block",
        variant = "empty",
        title   = "No shader open",
        message = "Open a .wgsl file and press the eye on the editor toolbar.",
      } },
    }
  end

  -- A material this previewer cannot build. Said in place of the viewport rather than beside
  -- it: a black frame next to an explanation reads as a broken preview, and there is nothing
  -- wrong here except that a texture is not a number.
  if state.blocked then
    return {
      title = "Shader preview — " .. (state.path and state.path:match("[^/\\]+$") or ""),
      nodes = { {
        type    = "state_block",
        variant = "empty",
        title   = "This material binds something the preview cannot make",
        message = "It binds " .. state.blocked .. ". Textures and samplers are fine — the "
               .. "shader is renumbered onto slots that exist. What is left here is filled by "
               .. "a pass this preview does not run, or is past the slots it has, and no "
               .. "renumbering reaches either.",
      } },
    }
  end

  -- The viewport. `send` is the outbox: the node tracks how much it has already delivered, so
  -- a slider does not replay the `open`. It fills whatever height the panel has left — in a
  -- split you drag to make the picture bigger, and a viewport that ignores the drag is one you
  -- cannot judge a material in.
  nodes[#nodes + 1] = {
    type        = "embed",
    -- Stable id: `main.lua` patches this node by id to deliver messages without rebuilding the
    -- panel. Change it here and the viewport goes deaf.
    id          = "viewport",
    src         = state.runtime_page,
    height      = "fill",
    min_height  = 280,
    -- The page fetches its own wasm, and WebKit will not let an opaque-origin frame do that.
    -- It still cannot reach the app: the plugin scheme is not the app's.
    same_origin = true,
    send        = state.outbox,
    on_message  = "shader_preview:message",
  }

  -- The two actions stay above the folding groups: they are what you press, and a button that
  -- scrolls away under four collapsed sections is a button you hunt for.
  local actions = {
    {
      type    = "button",
      id      = "reload",
      label   = "Reload",
      icon    = "RefreshCw",
      variant = "primary",
      action  = "shader_preview:reload",
      tooltip = "Re-read the file from disk and recompile",
      style   = "flex: 1",
    },
  }
  if state.desc then
    actions[#actions + 1] = {
      type    = "button",
      id      = "randomise",
      label   = "Random params",
      icon    = "Shuffle",
      action  = "shader_preview:random",
      tooltip = "Move every control somewhere inside its own range",
      style   = "flex: 1",
    }
  end
  nodes[#nodes + 1] = { type = "row", id = "actions", gap = 6, children = actions }

  -- ── The clock ───────────────────────────────────────────────────────────────
  --
  -- The gesture this panel exists for is *change one number, look at the difference*. On a
  -- material that animates that gesture does not work at all while the clock runs: between the
  -- before and the after everything else has moved too, and there is no telling which change
  -- you are looking at. So it stops.
  --
  -- Above the folding sections, beside Reload, because it is pressed as often — and because a
  -- transport hidden under a collapsed header is one nobody finds.
  local paused = state.clock and state.clock.paused
  nodes[#nodes + 1] = {
    type = "row", id = "clock", gap = 6, children = {
      {
        type    = "button",
        id      = "clock_toggle",
        label   = paused and "Play" or "Pause",
        icon    = paused and "Play" or "Pause",
        action  = "shader_preview:pause",
        tooltip = paused and "Let the clock run again"
                          or "Stop the clock, so a change is the only thing that moved",
      },
      -- Steps, for walking a cycle. A twentieth of a second is about a frame and a half at 30
      -- Hz: fine enough to see a wave crest move, coarse enough that holding the button gets
      -- somewhere.
      { type = "button", id = "clock_back", icon = "ChevronLeft", tooltip = "Back 0.05 s",
        action = "shader_preview:step", data = { by = -0.05 } },
      { type = "button", id = "clock_fwd", icon = "ChevronRight", tooltip = "Forward 0.05 s",
        action = "shader_preview:step", data = { by = 0.05 } },
      {
        type     = "field",
        id       = "clock_at",
        name     = "clock_at",
        kind     = "range",
        label    = "t",
        compact  = true,
        min      = 0,
        max      = 10,
        step     = 0.01,
        default  = (state.clock and state.clock.at) or 0,
        -- Only while stopped. A running virtual clock is recomputed from the real one every
        -- frame, so a scrubbed instant would be overwritten before anything is drawn — and a
        -- slider that silently does nothing is worse than one that is visibly unavailable.
        disabled = not paused,
        hint     = "seconds since the scene opened",
        actions  = { change = "shader_preview:time" },
        style    = FIELD_COLUMN .. "; flex: 1",
      },
    },
  }

  if state.desc then
    local fields = {}
    for _, f in ipairs(state.fields) do
      fields[#fields + 1] = control_for(f, state.values[f.name], params)
    end

    nodes[#nodes + 1] = section(
      "params", "Shader parameters",
      -- Named after what the SHADER called it. The whole point of asking Bennu is that a panel
      -- saying "binding 100 · x y z w" makes you remember that lane 2 of the second row is
      -- `spiral_arms` — which is the job the author already did by naming it.
      mat_key(state) .. " · " .. #state.fields,
      false,
      {
        template_bar(state, templates),
        rows("param_body", fields),
        -- The last mile. Tuning happens here and the numbers live in Rust, and without this
        -- the final gesture is reading eleven floats off a panel and typing them into a
        -- `Default` impl — which is where a decimal point goes missing and the shipped
        -- material quietly stops being the one that was approved.
        {
          type          = "copy_button",
          id            = "copy_rust",
          variant       = "inline",
          label         = "Copy as Rust",
          copied_label  = "Copied",
          tooltip       = "The tuned values as a struct literal, for the material's Default impl",
          toast_success = "Struct literal copied",
          value         = params.to_rust(state.desc, state.fields, state.values),
        },
      }
    )

    -- Samplers stay in "Also bound": there is nothing to decide about one. A sampler has no
    -- content — it is how a texture is read — so a row for it would be a control with a single
    -- possible value.
    if state.desc.resources and #state.desc.resources > 0 then
      local res = {}
      for _, r in ipairs(state.desc.resources) do
        -- Textures have their own section, with a control. Listing them twice would be two
        -- places saying different things about the same binding.
        if r.kind ~= "texture" then
          -- What it IS, in words rather than a classifier's name. `uniform_array` on a row a
          -- user is reading means nothing; "supplied at runtime" says why there is no control
          -- for it, which is the actual question a greyed-out row raises.
          local what = ({
            storage_texture = "storage texture",
            sampler         = "sampler — how a texture is read",
            storage         = "storage buffer",
            uniform_array   = "array — supplied at runtime",
          })[r.kind] or r.kind
          res[#res + 1] = {
            type    = "field",
            id      = "res." .. r.name,
            label   = r.name,
            kind    = "readonly",
            value   = what .. "  @" .. original_binding(state, r.name, r.binding),
            hint    = r.type,
            compact = true,
          }
        end
      end
      if #res > 0 then
        nodes[#nodes + 1] = section("resources", "Also bound", tostring(#res),
                                    true, { rows("resource_body", res) })
      end
    end
  else
    nodes[#nodes + 1] = {
      type    = "alert",
      id      = "no_block",
      variant = "info",
      style   = "inline",
      title   = "No parameter block",
      text    = "This shader declares nothing in the material's bind group that can be laid "
             .. "out, so it is previewed with the four vec4 slots a Bevy material extension "
             .. "conventionally uses.",
    }
  end

  local tex = texture_section(state)
  if tex then nodes[#nodes + 1] = tex end

  nodes[#nodes + 1] = mesh_section(state, mesh)
  nodes[#nodes + 1] = camera_section(state)
  for _, s in ipairs(scene_sections(state, scene, params)) do nodes[#nodes + 1] = s end

  local name = state.path and state.path:match("[^/\\]+$") or ""
  return {
    title = "Shader preview — " .. name,
    nodes = nodes,
    state = {
      template_pick = state.desc and templates.preferred(state.path, mat_key(state)) or "",
      template_name = state.desc and (templates.preferred(state.path, mat_key(state)) or "") or "",
    },
  }
end

--- The nodes for one shape's own parameters, so a mesh change can be patched in rather than
--- rebuilding the panel — a rebuild remounts the viewport and restarts the Bevy app.
function M.mesh_param_nodes(state, mesh)
  local out = {}
  for _, f in ipairs(mesh.fields(mesh.kind(state.mesh.id))) do
    out[#out + 1] = mesh_row(f, state.mesh.params[f.name])
  end
  return out
end

--- The options for the look picker, and the placeholder that goes with an empty one.
function M.template_options(names)
  local options = {}
  for i, n in ipairs(names) do options[i] = { value = n, label = n } end
  return options, (#names > 0) and "pick a look" or "no looks saved yet"
end

return M
