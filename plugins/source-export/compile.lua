-- compile.lua — turn a profile (operations catalog items with params) into
-- the shape `arbor.pipeline.define` expects, then delegate to the runtime.
--
-- Returns:
--   ok, run_id     on success — orchestrator started, lock acquired
--   false, err     on failure — nothing registered, caller shows the error

local vars       = require("variables")
local to_command = require("to_command")
local pcfg       = require("config.project")
local schema     = require("profile_schema")

local M = {}

local IS_WIN = arbor.meta.os() == "windows"

-- Kinds that compile into a `lua_op` step targeting a built-in op instead
-- of a shell command. Handlers are implemented in Rust under
-- `src-tauri/src/pipeline/builtin_ops.rs` and addressed via the reserved
-- sentinel plugin name `"arbor"` — source-export itself does not register
-- them. Handlers receive `params` as a table AND `ctx.cwd` for relative
-- path resolution.
--
-- Everything that's pure I/O + text transformation lives in the builtins;
-- shell-only concerns (git / mvn / gradle / npm / docker / arbitrary
-- shell_command / the two assert_* ops that wrap a command or an env var)
-- stay in to_command.lua.
local LUA_OP_KINDS = {
  -- File ops
  create_file     = true,
  touch_file      = true,
  append_file     = true,
  prepend_file    = true,
  copy_file       = true,
  move_file       = true,
  delete_file     = true,
  delete_pattern  = true,
  -- Content ops
  replace_in_file = true,
  replace_on_glob = true,
  properties_edit = true,
  env_merge       = true,
  template_render = true,
  insert_at_anchor = true,
  -- Structured edits
  json_edit = true,
  yaml_edit = true,
  toml_edit = true,
  xml_edit  = true,
  -- Validation
  assert_file_exists       = true,
  assert_file_not_contains = true,
  assert_glob_matches      = true,
  assert_version_bump      = true,
}

-- Kinds that compile straight to native runtime fields on StepDef
-- (`if_block`, `builtin`, `capture`) — no shell, no Lua VM. The runtime
-- evaluates them directly. Used by validate_steps so these don't show up
-- as "Op not implemented" and by the dispatcher in build_step_def below.
local NATIVE_KINDS = {
  if_block             = true,
  capture_var          = true,
  builtin_file_exists  = true,
  builtin_env          = true,
  builtin_set_var      = true,
  builtin_echo         = true,
  builtin_match        = true,
}

-- Helper: parse a "branches" / "else_steps" textarea field.  Accepts an
-- already-parsed table (when authored via the Lua API) OR a JSON string
-- (when edited via the textarea form).  Empty strings default to `[]`.
local function parse_json_or_table(v, default_table)
  if v == nil or v == "" then return default_table or {} end
  if type(v) == "table" then return v end
  if type(v) == "string" then
    local ok, parsed = pcall(arbor.json.decode, v)
    if ok and parsed ~= nil then return parsed end
  end
  return nil, ("invalid JSON: " .. tostring(v):sub(1, 60))
end

-- Build the `lua_op` spec for a step whose kind is native. Values are
-- pre-expanded against ctx.vars so the handler never has to redo variable
-- substitution.
--
-- For ops that need access to the full variable map (template_render expands
-- `{{VAR}}` placeholders dynamically from whatever the profile defines),
-- include a `__vars` snapshot — the orchestrator's per-step ctx is intentionally
-- narrow (cwd + plugin) so we stamp the resolved map at compile time.
local OPS_NEEDING_VARS = { template_render = true }

local function build_lua_op_params(step, ctx)
  local out = {}
  for k, v in pairs(step.params or {}) do
    if type(v) == "string" then
      out[k] = vars.expand(v, ctx.vars)
    else
      out[k] = v
    end
  end
  if OPS_NEEDING_VARS[step.kind] then
    local copy = {}
    for k, v in pairs(ctx.vars or {}) do copy[k] = tostring(v) end
    out.__vars = copy
  end
  return out
end

-- Build the automatic clone stage prepended to every run when
-- `profile.auto_clone` is true (default). The clone creates the output folder
-- from $SOURCE_PATH at the configured branch/tag so transformations never
-- touch the original working copy.
local function build_auto_clone_stage(profile)
  local branch = profile.branch_src or ""
  local branch_arg = (branch ~= "") and (" --branch " .. (IS_WIN and ('"' .. branch .. '"') or ("'" .. branch .. "'"))) or ""
  local q = IS_WIN and '"' or "'"
  local cmd = "git clone --progress" .. branch_arg
           .. " -- " .. q .. "$SOURCE_PATH" .. q
           .. " "    .. q .. "$OUTPUT_PATH" .. q
  -- Note: $SOURCE_PATH and $OUTPUT_PATH get expanded by to_command-side
  -- substitution via the ctx.vars map right before execution (we reuse the
  -- shell_command kind to benefit from the same pipeline the user-defined
  -- steps go through).
  return {
    id           = "__auto_clone__",
    name         = "Auto clone (sorgente → output)",
    mode         = "sequential",
    max_parallel = nil,
    steps = {
      {
        id            = "__auto_clone_step__",
        name          = "git clone " .. (branch ~= "" and ("@ " .. branch) or "@ HEAD"),
        kind          = "shell_command",
        allow_failure = false,
        -- cwd must be an existing directory for process spawn; $OUTPUT_PATH
        -- doesn't exist yet (the clone is going to create it). Anchor to the
        -- source repo which is guaranteed to exist at run start.
        params        = { command = cmd, cwd = "$SOURCE_PATH" },
      },
    },
  }
end

local function pipeline_id_for(profile)
  return "profile:" .. profile.id
end

-- ── Validation: every step must map to an implemented op OR a LuaOp kind
-- OR a native runtime kind. Recurses into `if_block` branches/else_steps so
-- nested steps are validated with the same rules as top-level ones.
local function validate_steps(profile)
  local problems = {}

  local function known(kind)
    return NATIVE_KINDS[kind]
        or LUA_OP_KINDS[kind]
        or to_command.is_implemented(kind)
  end

  local function check_step(step, stage_name)
    if not known(step.kind) then
      problems[#problems+1] = {
        stage_name = stage_name,
        step_name  = step.name or step.id,
        kind       = step.kind,
        reason     = "Op '" .. tostring(step.kind) .. "' non implementata",
      }
    end
    if step.kind == "if_block" then
      local p = step.params or {}
      local branches   = parse_json_or_table(p.branches,   {})
      local else_steps = parse_json_or_table(p.else_steps, {})
      if type(branches) == "table" then
        for _, br in ipairs(branches) do
          for _, child in ipairs(br.steps or {}) do
            check_step(child, stage_name .. " / if-branch")
          end
        end
      end
      if type(else_steps) == "table" then
        for _, child in ipairs(else_steps) do
          check_step(child, stage_name .. " / else")
        end
      end
    end
  end

  for _, stage in ipairs(profile.stages or {}) do
    for _, step in ipairs(stage.steps or {}) do
      check_step(step, stage.name or stage.id)
    end
  end
  return problems
end

-- Build the {KEY=value} map of process env overrides applied to user shell
-- steps. Each value is expanded against ctx.vars (so $VAR / ${env:HOST_VAR})
-- — same machinery as commands. Empty keys / nil values dropped. Returns
-- nil when no entries (signals "no env override" to keep the JSON tight).
local function build_profile_env(profile, ctx)
  local out, has = {}, false
  for _, e in ipairs(profile.env or {}) do
    if e and e.key then
      local k = tostring(e.key):gsub("^%s+", ""):gsub("%s+$", "")
      if k ~= "" then
        out[k] = vars.expand(tostring(e.value or ""), ctx.vars)
        has = true
      end
    end
  end
  return has and out or nil
end

-- ── Build the pipeline table expected by arbor.pipeline.define.
-- One stage per profile-stage; one step per profile-step. Preserves ids so the
-- runtime emits events the cronologia tab can correlate back.
-- When `profile.auto_clone != false`, a synthetic clone stage is prepended so
-- the output folder is populated from the source repo before any user step
-- runs. This is what makes $OUTPUT_PATH safe as the default step cwd.
local function build_pipeline_table(profile, ctx, _opts)
  local stages_source = {}
  if profile.auto_clone ~= false then
    stages_source[#stages_source+1] = build_auto_clone_stage(profile)
  end
  for _, s in ipairs(profile.stages or {}) do stages_source[#stages_source+1] = s end

  -- profile-level env (e.g. JAVA_HOME=…). Only applied to user shell steps;
  -- auto-clone runs git and shouldn't risk a fudged PATH override.
  local profile_env = build_profile_env(profile, ctx)

  -- Forward decl so build_if_block + compile_step can recurse through each
  -- other (every nested step is itself a profile-shaped step → uses the
  -- same compile_step path → can re-nest if_blocks indefinitely).
  local compile_step  -- function(step, ctx, profile_env, is_synthetic) -> step_def | nil, err

  -- Build a runtime IfBlock from a profile-style if_block step.  Profile
  -- shape (authored via the visual editor):
  --   step.params = {
  --     branches   = { { expression = "${var} == ...", steps = {...} }, ... },
  --     else_steps = { ... },                    -- optional
  --   }
  -- `expression` is a free-form string parsed at run time by the Rust
  -- `pipeline::condition_parser`.  Empty / missing expressions become a
  -- `Condition::Never` so the branch silently skips (the user-visible
  -- effect: a half-authored elif is simply not chosen).
  local function build_if_block(step, ctx, profile_env, is_synthetic)
    local p = step.params or {}
    -- Tolerate a stray legacy textarea-JSON shape (older imports). New
    -- profiles always store tables.
    local branches, err = parse_json_or_table(p.branches, {})
    if not branches then return nil, "if_block.branches: " .. (err or "invalid") end
    local else_steps
    else_steps, err = parse_json_or_table(p.else_steps, {})
    if not else_steps then return nil, "if_block.else_steps: " .. (err or "invalid") end

    local function compile_branch_steps(arr, ctx_path)
      local out = {}
      for j, child in ipairs(arr or {}) do
        local def, cerr = compile_step(child, ctx, profile_env, is_synthetic)
        if not def then
          return nil, (ctx_path .. "[" .. j .. "]: " .. (cerr or "compile failed"))
        end
        out[#out+1] = def
      end
      return out
    end

    local out_branches = {}
    for i, br in ipairs(branches) do
      if type(br) ~= "table" then
        return nil, "if_block.branches[" .. i .. "]: not a table"
      end
      local steps_compiled, serr = compile_branch_steps(br.steps, "if_block.branches[" .. i .. "].steps")
      if not steps_compiled then return nil, serr end
      -- Three input shapes accepted, in priority order:
      --   1. `expression` (string)             — new visual editor
      --   2. `condition`  (structured table)   — programmatic / legacy
      --   3. nothing                           — Never (skip silently)
      local condition
      if type(br.expression) == "string" and br.expression:match("%S") then
        condition = { kind = "expr", expr = br.expression }
      elseif type(br.condition) == "table" then
        condition = br.condition
      else
        condition = { kind = "never" }
      end
      out_branches[#out_branches+1] = { condition = condition, steps = steps_compiled }
    end

    local out_else, eerr = compile_branch_steps(else_steps, "if_block.else_steps")
    if not out_else then return nil, eerr end

    return { branches = out_branches, else_steps = out_else }
  end

  -- Compile a single step (top-level OR nested under an if_block).
  -- Returns the StepDef table accepted by `arbor.pipeline.define`, or
  -- (nil, err) on failure.
  compile_step = function(step, ctx_local, profile_env_local, is_synthetic)
    local default_cwd = ctx_local.output_path or ctx_local.source_path or nil
    local capture     = step.capture  -- pass-through if author set one

    -- ── set_variable: compile-time intercept ────────────────────────────
    -- Mutate ctx.vars so subsequent steps in the same run see the new value
    -- during their own to_command.compile. Compile-time rebind only — for
    -- runtime captures (stdout of another step) use kind="capture_var".
    if step.kind == "set_variable" then
      local name  = (step.params and step.params.name  or ""):gsub("^%s+", ""):gsub("%s+$", "")
      local value = vars.expand(step.params and step.params.value or "", ctx_local.vars)
      if name ~= "" then
        ctx_local.vars[name] = value
      end
      local echo_cmd = IS_WIN
        and ("echo [set_variable] " .. name .. " = " .. value:gsub('"', "'"))
        or  ("echo '[set_variable] " .. name .. " = " .. value:gsub("'", "'\\''") .. "'")
      return {
        id            = step.id,
        name          = step.name or step.id,
        command       = echo_cmd,
        cwd           = default_cwd,
        allow_failure = step.allow_failure and true or false,
        env           = (not is_synthetic) and profile_env_local or nil,
        capture       = capture,
      }
    end

    -- ── if_block: native control step ───────────────────────────────────
    if step.kind == "if_block" then
      local block, berr = build_if_block(step, ctx_local, profile_env_local, is_synthetic)
      if not block then return nil, berr end
      return {
        id            = step.id,
        name          = step.name or step.id,
        if_block      = block,
        cwd           = default_cwd,
        allow_failure = step.allow_failure and true or false,
        capture       = capture,
      }
    end

    -- ── capture_var: shell + capture in one fluent op ───────────────────
    if step.kind == "capture_var" then
      local p = step.params or {}
      local var_name = (p.var or ""):gsub("^%s+", ""):gsub("%s+$", "")
      if var_name == "" then
        return nil, "capture_var: 'var' is required"
      end
      local cmd = vars.expand(p.command or "", ctx_local.vars)
      if cmd == "" then
        return nil, "capture_var: 'command' is required"
      end
      local transforms, terr = parse_json_or_table(p.transforms, {})
      if not transforms then return nil, "capture_var: " .. (terr or "invalid transforms") end
      return {
        id            = step.id,
        name          = step.name or step.id,
        command       = cmd,
        cwd           = default_cwd,
        allow_failure = step.allow_failure and true or false,
        env           = (not is_synthetic) and profile_env_local or nil,
        capture       = {
          var        = var_name,
          source     = p.source or "stdout",
          transforms = transforms,
        },
      }
    end

    -- ── Built-in ops (file_exists / env / set_var / echo / match) ───────
    if step.kind == "builtin_file_exists" then
      local p = step.params or {}
      return {
        id            = step.id,
        name          = step.name or step.id,
        builtin       = { kind = "file_exists",
                          path = vars.expand(p.path or "", ctx_local.vars) },
        cwd           = default_cwd,
        allow_failure = step.allow_failure and true or false,
        capture       = capture or (p.var and p.var ~= ""
                          and { var = p.var, source = "return_value" }
                          or nil),
      }
    end
    if step.kind == "builtin_env" then
      local p = step.params or {}
      return {
        id            = step.id,
        name          = step.name or step.id,
        builtin       = { kind = "env",
                          name = vars.expand(p.name or "", ctx_local.vars),
                          default = (p.default and p.default ~= "")
                                    and vars.expand(p.default, ctx_local.vars) or nil },
        cwd           = default_cwd,
        allow_failure = step.allow_failure and true or false,
        capture       = capture or (p.var and p.var ~= ""
                          and { var = p.var, source = "return_value",
                                transforms = { { kind = "trim" } } }
                          or nil),
      }
    end
    if step.kind == "builtin_set_var" then
      local p = step.params or {}
      local raw_value = p.value
      -- Accept either a JSON string (textarea path) or a Lua table
      -- (programmatic path). Wrap a bare string in JSON quotes when
      -- it doesn't look like JSON already, so users can write `production`
      -- without remembering to quote it.
      local parsed
      if type(raw_value) == "string" then
        local s = raw_value:gsub("^%s+", ""):gsub("%s+$", "")
        if s == "" then
          parsed = nil
        else
          local first = s:sub(1,1)
          local looks_like_json = first == '"' or first == '{' or first == '['
            or first == '-' or first == 't' or first == 'f' or first == 'n'
            or (first >= '0' and first <= '9')
          if looks_like_json then
            local ok, val = pcall(arbor.json.decode, s)
            parsed = ok and val or s
          else
            parsed = s
          end
        end
      else
        parsed = raw_value
      end
      return {
        id            = step.id,
        name          = step.name or step.id,
        builtin       = { kind = "set_var", value = parsed },
        cwd           = default_cwd,
        allow_failure = step.allow_failure and true or false,
        capture       = capture or (p.var and p.var ~= ""
                          and { var = p.var, source = "return_value" }
                          or nil),
      }
    end
    if step.kind == "builtin_echo" then
      local p = step.params or {}
      local out = {
        id            = step.id,
        name          = step.name or step.id,
        builtin       = { kind = "echo",
                          message = p.message or "" },
        cwd           = default_cwd,
        allow_failure = step.allow_failure and true or false,
      }
      out.capture = capture or (p.var and p.var ~= ""
        and { var = p.var, source = "return_value" }
        or nil)
      return out
    end
    if step.kind == "builtin_match" then
      local p = step.params or {}
      return {
        id            = step.id,
        name          = step.name or step.id,
        builtin       = { kind = "match",
                          target  = p.target  or "",
                          pattern = (p.pattern and p.pattern ~= "") and p.pattern or nil,
                          regex   = (p.regex   and p.regex   ~= "") and p.regex   or nil },
        cwd           = default_cwd,
        allow_failure = step.allow_failure and true or false,
        capture       = capture or (p.var and p.var ~= ""
                          and { var = p.var, source = "return_value" }
                          or nil),
      }
    end

    -- ── LuaOp dispatch (catalog of arbor.core.* handlers) ──────────────
    if LUA_OP_KINDS[step.kind] then
      local params = build_lua_op_params(step, ctx_local)
      return {
        id            = step.id,
        name          = step.name or step.id,
        lua_op        = { op = step.kind, params = params },
        cwd           = default_cwd,
        allow_failure = step.allow_failure and true or false,
        capture       = capture,
      }
    end

    -- ── Shell command via to_command.compile ────────────────────────────
    local cmd, cwd_or_err = to_command.compile(step, ctx_local)
    if not cmd then
      return nil, tostring(cwd_or_err)
    end
    return {
      id            = step.id,
      name          = step.name or step.id,
      command       = cmd,
      cwd           = (cwd_or_err and cwd_or_err ~= "") and cwd_or_err or default_cwd,
      allow_failure = step.allow_failure and true or false,
      env           = (not is_synthetic) and profile_env_local or nil,
      capture       = capture,
    }
  end

  local stages_out = {}
  for _, stage in ipairs(stages_source) do
    local is_synthetic = stage.id == "__auto_clone__"
    local steps_out = {}
    for _, step in ipairs(stage.steps or {}) do
      local step_def, err = compile_step(step, ctx, profile_env, is_synthetic)
      if not step_def then
        return nil, ("step '" .. (step.name or step.id) .. "': " .. tostring(err))
      end
      steps_out[#steps_out+1] = step_def
    end
    stages_out[#stages_out+1] = {
      id           = stage.id,
      name         = stage.name or stage.id,
      mode         = stage.mode or "sequential",
      max_parallel = stage.max_parallel,
      steps        = steps_out,
    }
  end

  return {
    id          = pipeline_id_for(profile),
    name        = profile.name or profile.id,
    description = profile.description or "",
    icon        = "Share2",
    lock_key    = "source-export:" .. profile.id,
    log_level   = profile.log_level or "info",
    stages      = stages_out,
  }
end

-- ── Public entry points ────────────────────────────────────────────────

--- Compile the profile into a live PipelineDef and start a run.
---@param profile table
---@param opts table|nil {
---   source_path   = "/path/to/other/repo",      -- override $SOURCE_PATH (used by sequences)
---   output_folder = "/path/to/seq-root/item/",  -- final $OUTPUT_PATH (used as-is, no nested timestamp)
---   extra_vars    = { { key, value } },         -- additional variables to merge on top of profile.variables
---   pipeline_name_suffix = " · seq",            -- decoration in the Pipelines panel
---  }
---@return boolean|string ok_or_false
---@return string       run_id_or_error
function M.run(profile, opts)
  opts = opts or {}
  if not profile or not profile.stages or #profile.stages == 0 then
    return false, "Profile is empty: add at least one stage before running."
  end

  local problems = validate_steps(profile)
  if #problems > 0 then
    local lines = { "Cannot run: " .. tostring(#problems) .. " step(s) not implemented:" }
    for _, p in ipairs(problems) do
      lines[#lines+1] = string.format("  • %s / %s (%s)", p.stage_name, p.step_name, p.kind)
    end
    return false, table.concat(lines, "\n")
  end

  -- Merge extra_vars INTO profile.variables (non-destructive: we work on a
  -- shallow copy so the saved profile on disk stays untouched). The runner
  -- for sequences uses this to inject both the sequence-global vars and the
  -- per-item overrides in one pass.
  local effective_profile = profile
  if opts.extra_vars and #opts.extra_vars > 0 then
    effective_profile = {}
    for k, v in pairs(profile) do effective_profile[k] = v end
    local merged_vars = {}
    for _, v in ipairs(profile.variables or {}) do
      merged_vars[#merged_vars+1] = { key = v.key, value = v.value }
    end
    for _, v in ipairs(opts.extra_vars) do
      if v and v.key and v.key ~= "" then
        -- Last writer wins: sequence items can override profile defaults.
        local replaced = false
        for _, existing in ipairs(merged_vars) do
          if existing.key == v.key then
            existing.value = v.value
            replaced = true
            break
          end
        end
        if not replaced then
          merged_vars[#merged_vars+1] = { key = v.key, value = v.value }
        end
      end
    end
    effective_profile.variables = merged_vars
  end
  profile = effective_profile

  local ctx = vars.build_ctx(profile, {
    source_path   = opts.source_path,
    output_folder = opts.output_folder,
  })

  -- When auto_clone is disabled the output folder is normally created by
  -- the user's first step (or by a previous run). If neither has happened,
  -- spawning any step with cwd=$OUTPUT_PATH would fail with "Nome di
  -- directory non valido" on Windows (os error 267) / ENOENT on POSIX.
  -- arbor.fs.touch creates parent dirs as a side effect — we touch a
  -- harmless sentinel inside the output folder, then delete it.
  arbor.log.info("[run] auto_clone=" .. tostring(profile.auto_clone)
    .. " source=" .. tostring(ctx.source_path)
    .. " output=" .. tostring(ctx.output_path))
  if profile.auto_clone == false and ctx.output_path and ctx.output_path ~= "" then
    local sep = IS_WIN and "\\" or "/"
    local marker = ctx.output_path .. sep .. ".arbor_keep"
    local ok_t, err_t = arbor.fs.touch(marker)
    if not ok_t then
      arbor.log.warn("[ensure-output] failed: " .. tostring(err_t)
        .. " (path=" .. tostring(ctx.output_path) .. ")")
    else
      arbor.log.info("[ensure-output] dir ok: " .. ctx.output_path)
      pcall(function() arbor.fs.delete(marker) end)
    end
  end

  local def, err = build_pipeline_table(profile, ctx)
  if not def then return false, err end

  -- Optional name decoration: sequences append " · seq <N>/<M>" so the
  -- Pipelines panel can distinguish a standalone run from a fan-out. The
  -- pipeline id stays the same so runs still cluster under the profile.
  if opts.pipeline_name_suffix and opts.pipeline_name_suffix ~= "" then
    def.name = (def.name or "") .. opts.pipeline_name_suffix
  end

  -- Register (or replace) and run.
  local define_ok, define_err = pcall(function() arbor.pipeline.define(def) end)
  if not define_ok then return false, "define failed: " .. tostring(define_err) end

  -- Release Arbor's libgit2 repository handles before handing control over
  -- to the pipeline's external shell processes. Without this, Arbor holds
  -- memory-mapped packfiles open (and sometimes a `.git/index.lock`), which
  -- on Windows blocks git clone / rm -rf from deleting or replacing those
  -- files — surfacing as ERROR_SHARING_VIOLATION or "file is in use".
  -- Handles are re-opened lazily on the next UI action that needs them.
  pcall(function() arbor.repo.release_handles() end)

  local run_id, run_err = arbor.pipeline.run{ pipeline_id = def.id, cwd = ctx.source_path }
  if not run_id then
    return false, "run failed: " .. tostring(run_err)
  end

  return true, run_id
end

--- Return the pipeline id this plugin uses for a given profile.
--- Useful when the cronologia tab needs to filter runs by profile.
function M.pipeline_id_for(profile_id)
  -- Accept either a profile table or just the id string.
  if type(profile_id) == "table" then return pipeline_id_for(profile_id) end
  return "profile:" .. tostring(profile_id or "")
end

return M
