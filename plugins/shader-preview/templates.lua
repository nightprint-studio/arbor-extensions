-- Saved parameter sets, kept beside the shaders and restored when a material opens again.
--
-- ## Why they are not a setting
--
-- Finding the values that make a material read well is the work. Ten sliders reach a look
-- after a few minutes of pushing them around, and closing the panel throws every one of those
-- minutes away — silently, with the next session starting from neutral defaults.
--
-- ## Why beside the shaders and not in `.arbor/`
--
-- `.arbor/` is the per-repo location for machine-local state, and it is **gitignored**. A look
-- kept there stays on the machine where the dragging happened, which is the one outcome this
-- file exists to prevent: these numbers are worth showing someone, and worth committing.
--
-- The cost, named honestly rather than inflated: in a Bevy project shaders live under
-- `assets/`, which ships with the game, so a few kilobytes of editor state ship too. It is not
-- a load error — the AssetServer loads on demand by path and never asks for a file nobody
-- references. Clutter and a few KB, against a feature that otherwise does not work at all.
--
-- **One file per folder**, not one per shader: twenty shaders should not become forty entries
-- in a directory somebody has to read, and a single file is what you diff when a look changes.

local M = {}

local FILE = "shader-previews.json"

local function store_path(shader_path)
  local dir = shader_path:match("^(.*)[/\\][^/\\]+$") or "."
  return arbor.fs.join(dir, FILE)
end

--- Everything saved in the shader's folder, as `{ [struct] = { [name] = values } }`.
--
-- A missing or unreadable file is an empty store rather than an error: the next save writes a
-- good one, and losing saved looks costs less than a panel that refuses to open.
local function read_all(shader_path)
  local path = store_path(shader_path)
  if not arbor.fs.exists(path) then return {} end
  local text = arbor.fs.read(path)
  if type(text) ~= "string" or text == "" then return {} end
  local ok, data = pcall(function() return arbor.json.decode(text) end)
  if not ok or type(data) ~= "table" then
    arbor.log.warn("shader-previews.json is not readable, starting fresh: " .. path)
    return {}
  end
  return data
end

local function write_all(shader_path, data)
  local ok, err = pcall(function()
    arbor.fs.write(store_path(shader_path), arbor.json.encode(data))
  end)
  if not ok then
    -- Saving is a convenience, not a promise: a read-only checkout should not stop you
    -- previewing, it should stop you keeping looks.
    arbor.notify{
      title = "Shader preview",
      message = "Could not save the look: " .. tostring(err),
      level = "warning",
    }
  end
end

--- The names saved for a material, sorted.
--
-- Keyed by the STRUCT the shader declares, not by the file path: a shader that is moved or
-- renamed keeps its looks, and two files declaring the same block share them — which is
-- usually what somebody who copied one meant.
function M.names(shader_path, struct)
  local bucket = read_all(shader_path)[struct] or {}
  local out = {}
  for name in pairs(bucket) do out[#out + 1] = name end
  table.sort(out)
  return out
end

--- Keep a look: the parameters, the rig, and the geometry it was judged on.
--
-- All three, because tuning a material is in large part tuning the LIGHT on it — a normal
-- perturbation that reads beautifully under one key light disappears under another — and
-- because a term that is right on a sphere can be wrong in a saddle. A look that remembered
-- only the numbers would put them back under a different lamp on a different shape, which is
-- a different picture and no longer the thing that was saved.
function M.save(shader_path, struct, name, values, scene, mesh)
  local data = read_all(shader_path)
  data[struct] = data[struct] or {}
  data[struct][name] = { params = values, scene = scene, mesh = mesh }
  data.__default = data.__default or {}
  -- Saving marks it: the common case is settling on a look and carrying on with it, which
  -- should not need a second gesture to make stick.
  data.__default[struct] = name
  write_all(shader_path, data)
end

function M.remove(shader_path, struct, name)
  local data = read_all(shader_path)
  if data[struct] then
    data[struct][name] = nil
    if next(data[struct]) == nil then data[struct] = nil end
  end
  if data.__default and data.__default[struct] == name then
    data.__default[struct] = nil
  end
  write_all(shader_path, data)
end

--- The values saved under a name, restricted to fields the material still has.
--
-- Dropping the rest rather than restoring it: a field removed from the shader has no offset
-- any more, and one whose type changed would take a value shaped for the old one. What
-- survives is what still means what it meant.
--- A look, in the two shapes it has ever had.
--
-- The first was a flat map of parameter names to values. The second wraps that under `params`
-- and adds the things that turned out to be part of a look too — the light rig and the mesh.
-- Both are read, because the first is what is already committed beside people's shaders and a
-- format change that orphans saved work is not an improvement.
--
-- Told apart by `params`: a parameter can never be called that, because it would have to be a
-- WGSL member name and the wrapper key is chosen not to be one anybody writes.
function M.load(shader_path, struct, name, fields)
  local saved = (read_all(shader_path)[struct] or {})[name]
  if type(saved) ~= "table" then return nil end

  local values = type(saved.params) == "table" and saved.params or saved
  local out = { params = {}, scene = saved.scene, mesh = saved.mesh }
  for _, f in ipairs(fields) do
    if values[f.name] ~= nil then out.params[f.name] = values[f.name] end
  end
  return out
end

--- The name a material opens with — the last one loaded or saved.
function M.preferred(shader_path, struct)
  local data = read_all(shader_path)
  return (data.__default or {})[struct]
end

function M.set_preferred(shader_path, struct, name)
  local data = read_all(shader_path)
  data.__default = data.__default or {}
  data.__default[struct] = name
  write_all(shader_path, data)
end

return M
