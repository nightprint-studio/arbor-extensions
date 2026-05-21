-- profile_schema.lua — shape of an export profile + helpers to mutate one.
--
-- A profile is the editable unit stored per-repo under
-- `arbor.settings.project.profiles`.  Templates (global, shared preset of
-- stages/steps) have the exact same shape minus the `id`/`name` semantics —
-- they're used to seed new profiles.
--
--   {
--     id            : string   "cfg_<hex>"   stable, referenced by the combo
--     name          : string   "BancaRoma Core"
--     description   : string?  free-form
--     branch_src    : string?  source branch (default = current branch at run time)
--     branch_dest   : string?  destination branch (optional — pushes only when non-empty)
--     remote_url    : string?  dest remote URL (for the optional Push step placeholder)
--     log_level     : "debug"|"info"|"warn"|"error"    default "info"
--     variables     : { { key, value } }    user-defined placeholders
--     stages        : [ StageSchema ]       ordered top-level (sequential)
--     created_at    : int   unix millis
--     updated_at    : int   unix millis
--   }
--
--   StageSchema = {
--     id, name,
--     mode          : "sequential"|"parallel"   default "sequential"
--     max_parallel  : int?                      applies when mode=parallel
--     steps         : [ StepSchema ]
--   }
--
--   StepSchema = {
--     id, name,
--     kind          : string                 one of operations.lua keys
--     params        : table                  kind-specific (see operations.lua form)
--     allow_failure : boolean?               default false
--   }

local M = {}

local function rand_hex(n)
  local chars = "0123456789abcdef"
  local t = {}
  for _ = 1, (n or 8) do
    local i = math.random(1, #chars)
    t[#t+1] = chars:sub(i, i)
  end
  return table.concat(t)
end

function M.now_ms()
  -- Lua os.time is seconds. Multiply + random suffix is close-enough to avoid
  -- collisions when several profiles are created in the same second.
  return (os.time() * 1000) + math.random(0, 999)
end

function M.new_id(prefix)
  return (prefix or "cfg") .. "_" .. rand_hex(12)
end

function M.new_profile(name)
  return {
    id          = M.new_id("cfg"),
    name        = name or "New Profile",
    description = "",
    branch_src  = "",
    branch_dest = "",
    remote_url  = "",
    log_level   = "info",
    -- When true (default), the runtime clones $SOURCE_PATH into $OUTPUT_PATH
    -- before the first stage runs. All subsequent steps default their cwd to
    -- $OUTPUT_PATH so transformations never touch the original repository.
    -- Disable only for workflows that truly want to run in-place (rare).
    auto_clone  = true,
    variables   = {},
    -- Process env overrides applied to every user-defined shell_command
    -- step (not to the synthetic auto_clone stage). Same array-of-pairs
    -- shape as `variables` for ordered ipairs compat. Values are expanded
    -- against profile vars + ${env:NAME} at compile time.
    env         = {},
    stages      = {},
    created_at  = M.now_ms(),
    updated_at  = M.now_ms(),
  }
end

function M.new_stage(name)
  return {
    id           = M.new_id("stg"),
    name         = name or "New Stage",
    mode         = "sequential",
    max_parallel = nil,
    steps        = {},
  }
end

function M.new_step(kind, name)
  return {
    id            = M.new_id("stp"),
    name          = name or "New Step",
    kind          = kind,
    params        = {},
    allow_failure = false,
  }
end

function M.new_template(name)
  -- Templates share the shape but live in global settings. `id` is also needed
  -- for the template list UI.
  return {
    id          = M.new_id("tpl"),
    name        = name or "New Template",
    description = "",
    stages      = {},
    created_at  = M.now_ms(),
  }
end

-- ── Deep clone (sufficient for profile/template trees) ──────────────────────
-- Uses JSON roundtrip: the profile tree is pure data, no metatables / functions.
function M.clone(obj)
  local s = arbor.json.encode(obj)
  if not s then return nil end
  return (arbor.json.decode(s))
end

-- ── Mutators used by the modal editor ───────────────────────────────────────

function M.find_stage(profile, stage_id)
  for i, s in ipairs(profile.stages or {}) do
    if s.id == stage_id then return s, i end
  end
end

function M.find_step(profile, stage_id, step_id)
  local stage = M.find_stage(profile, stage_id)
  if not stage then return nil end
  for i, st in ipairs(stage.steps or {}) do
    if st.id == step_id then return st, i, stage end
  end
end

-- ── Recursive tree helpers for if_block nesting ─────────────────────────────
-- These find/manipulate steps anywhere in the tree, including inside
-- `params.branches[i].steps` and `params.else_steps` of `if_block` steps.
-- The "parent_arr" returned is the table that DIRECTLY contains the step,
-- so callers can `table.remove(parent_arr, idx)` or splice without
-- needing to know the path.

local function _walk_steps_array(arr, target_id)
  if type(arr) ~= "table" then return nil end
  for i, st in ipairs(arr) do
    if st.id == target_id then return st, arr, i end
    if st.kind == "if_block" and type(st.params) == "table" then
      for _, br in ipairs(st.params.branches or {}) do
        local found, parent, idx = _walk_steps_array(br.steps, target_id)
        if found then return found, parent, idx end
      end
      local found, parent, idx = _walk_steps_array(st.params.else_steps, target_id)
      if found then return found, parent, idx end
    end
  end
  return nil
end

--- Find a step anywhere in the profile tree by id. Returns
--- `(step, parent_arr, idx_in_parent_arr, owning_stage)` or nil.
function M.find_step_anywhere(profile, step_id)
  for _, stage in ipairs(profile.stages or {}) do
    local found, parent, idx = _walk_steps_array(stage.steps, step_id)
    if found then return found, parent, idx, stage end
  end
end

--- Resolve a branch_id (`<step_id>/<idx>` or `<step_id>/else`) to the
--- mutable `steps` table that contains the branch's children, plus the
--- if_block step itself. Returns nil when the path doesn't resolve.
---
---   local target, parent_step = schema.find_branch_steps(profile, "stp_x/0")
---   -- target is now the array; append a step to add it to the branch.
function M.find_branch_steps(profile, branch_id)
  if type(branch_id) ~= "string" or branch_id == "" then return nil end
  local sep = branch_id:find("/")
  if not sep then return nil end
  local step_id  = branch_id:sub(1, sep - 1)
  local branch_k = branch_id:sub(sep + 1)
  local step = M.find_step_anywhere(profile, step_id)
  if not step or step.kind ~= "if_block" or type(step.params) ~= "table" then
    return nil
  end
  if branch_k == "else" then
    step.params.else_steps = step.params.else_steps or {}
    return step.params.else_steps, step
  end
  local idx = tonumber(branch_k)
  if not idx then return nil end
  step.params.branches = step.params.branches or {}
  -- Branch ids are 0-indexed in the editor (0 = "if", 1+ = "elif #N").
  local br = step.params.branches[idx + 1]
  if not br then return nil end
  br.steps = br.steps or {}
  return br.steps, step, idx + 1
end

--- Append a new branch (elif by default, else when `as_else=true`) to an
--- existing if_block step. Returns the new branch's `branch_id`.
function M.add_branch(profile, step_id, as_else)
  local step = M.find_step_anywhere(profile, step_id)
  if not step or step.kind ~= "if_block" then return nil end
  step.params = step.params or {}
  if as_else then
    step.params.else_steps = step.params.else_steps or {}
    profile.updated_at = M.now_ms()
    return step_id .. "/else"
  end
  step.params.branches = step.params.branches or {}
  step.params.branches[#step.params.branches + 1] = {
    expression = "",
    steps      = {},
  }
  profile.updated_at = M.now_ms()
  return step_id .. "/" .. tostring(#step.params.branches - 1)
end

--- Remove a branch (or the else clause) from an if_block step.
function M.remove_branch(profile, branch_id)
  if type(branch_id) ~= "string" or branch_id == "" then return end
  local sep = branch_id:find("/")
  if not sep then return end
  local step_id  = branch_id:sub(1, sep - 1)
  local branch_k = branch_id:sub(sep + 1)
  local step = M.find_step_anywhere(profile, step_id)
  if not step or step.kind ~= "if_block" or type(step.params) ~= "table" then return end
  if branch_k == "else" then
    step.params.else_steps = nil
  else
    local idx = tonumber(branch_k)
    if not idx or not step.params.branches then return end
    table.remove(step.params.branches, idx + 1)
  end
  profile.updated_at = M.now_ms()
end

--- Update a branch's expression string (no-op for else branches).
function M.update_branch_expression(profile, branch_id, expr)
  if type(branch_id) ~= "string" or branch_id == "" then return end
  local sep = branch_id:find("/")
  if not sep then return end
  local step_id  = branch_id:sub(1, sep - 1)
  local branch_k = branch_id:sub(sep + 1)
  if branch_k == "else" then return end       -- else has no condition
  local idx = tonumber(branch_k)
  if not idx then return end
  local step = M.find_step_anywhere(profile, step_id)
  if not step or step.kind ~= "if_block" or type(step.params) ~= "table" then return end
  step.params.branches = step.params.branches or {}
  if not step.params.branches[idx + 1] then return end
  step.params.branches[idx + 1].expression = expr or ""
  profile.updated_at = M.now_ms()
end

function M.add_stage(profile, stage, position)
  profile.stages = profile.stages or {}
  if position == nil or position > #profile.stages then
    profile.stages[#profile.stages+1] = stage
  else
    table.insert(profile.stages, math.max(1, position), stage)
  end
  profile.updated_at = M.now_ms()
end

function M.remove_stage(profile, stage_id)
  local _, i = M.find_stage(profile, stage_id)
  if i then table.remove(profile.stages, i); profile.updated_at = M.now_ms() end
end

function M.move_stage(profile, stage_id, delta)
  local _, i = M.find_stage(profile, stage_id)
  if not i then return end
  local j = math.max(1, math.min(#profile.stages, i + (delta or 0)))
  if j == i then return end
  local st = table.remove(profile.stages, i)
  table.insert(profile.stages, j, st)
  profile.updated_at = M.now_ms()
end

function M.add_step(profile, stage_id, step, position)
  local stage = M.find_stage(profile, stage_id)
  if not stage then return end
  stage.steps = stage.steps or {}
  if position == nil or position > #stage.steps then
    stage.steps[#stage.steps+1] = step
  else
    table.insert(stage.steps, math.max(1, position), step)
  end
  profile.updated_at = M.now_ms()
end

function M.remove_step(profile, stage_id, step_id)
  local _, idx, stage = M.find_step(profile, stage_id, step_id)
  if idx then table.remove(stage.steps, idx); profile.updated_at = M.now_ms() end
end

function M.move_step(profile, stage_id, step_id, delta)
  local _, idx, stage = M.find_step(profile, stage_id, step_id)
  if not idx then return end
  local j = math.max(1, math.min(#stage.steps, idx + (delta or 0)))
  if j == idx then return end
  local st = table.remove(stage.steps, idx)
  table.insert(stage.steps, j, st)
  profile.updated_at = M.now_ms()
end

-- Move a step across stages (uses destination index at the top by default).
function M.move_step_to_stage(profile, step_id, from_stage_id, to_stage_id, position)
  local _, idx, from = M.find_step(profile, from_stage_id, step_id)
  if not idx then return end
  local to = M.find_stage(profile, to_stage_id)
  if not to then return end
  local st = table.remove(from.steps, idx)
  to.steps = to.steps or {}
  if position == nil or position > #to.steps then
    to.steps[#to.steps+1] = st
  else
    table.insert(to.steps, math.max(1, position), st)
  end
  profile.updated_at = M.now_ms()
end

return M
