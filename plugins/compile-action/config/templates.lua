-- config/templates.lua — Build config templates for compile-action.
--
-- Each template exposes:
--   · metadata       (label, icon, tag, tag_variant, toolchain_kind)
--   · new_defaults() — initial template-specific field values for a fresh
--                       config (excludes the common keys handled by `compose`)
--   · schema(cfg)    — list of FormNode for the config's editor card.
--                       Field names MUST be prefixed via fn(id, key).
--   · build_command(cfg) — final shell command derived from the config
--
-- Storage format (per config):
--   { id, template_id, name, toolchain_id, cwd, env, command,
--     description, notify_on_completion,
--     profile_env = { dev = {...}, prod = {...}, test = {...} },
--     before_launch = { { step_type, target, cwd? }, ... },
--     ...template-specific fields (flat, top-level)... }

local M = {}

-- Prefixed field name: cfg_<id>__<key>.
-- Using double underscore between id and key so ids containing underscores
-- cannot alias into the field-key namespace.
local function fn(id, key) return "cfg_" .. id .. "__" .. key end
M.fn = fn

-- Profiles whose env we offer per-config overrides for.
local PROFILE_KEYS = { "dev", "prod", "test" }

-- Common defaults shared by every template.
local function common_defaults()
  return {
    description          = "",
    notify_on_completion = true,
    extra_args           = "",
    profile_env          = { dev = {}, prod = {}, test = {} },
    before_launch       = {},
  }
end

-- ── Layout helpers ────────────────────────────────────────────────────────────
-- All template editors share the same overall structure (collapsible cards
-- on a flat background — no outer wrapper, see project.lua):
--   · "General"               — name, toolchain, cwd, description, notify
--   · "Build Options"         — template-specific fields (per template)
--   · "Environment Variables" — base env (always applied)
--   · "Per-profile Environment" — overrides applied when the matching
--                                  profile is active (dev/prod/test pill)
--   · "Before Launch"         — tasks to run sequentially before this build
-- Followed by the resolved command preview with floating Copy button.
-- General starts expanded; the rest start collapsed to keep the card compact.

local function general_section(cfg, toolchain_kind)
  local id = cfg.id

  -- Row 1: Name + Toolchain (when applicable). Falls back to a single
  -- field when there's no toolchain so we don't render a half-empty grid.
  local row1
  if toolchain_kind then
    local tc_opts = { { value = "", label = "Use global default" } }
    local list_ok, list = pcall(arbor.toolchain.list, toolchain_kind)
    if list_ok and list then
      for _, t in ipairs(list) do
        tc_opts[#tc_opts+1] = { value = t.id, label = t.label }
      end
    end
    local tc_label = toolchain_kind == "jdk"  and "JDK"
                  or toolchain_kind == "node" and "Node.js"
                  or toolchain_kind == "rust" and "Rust toolchain"
                  or "Toolchain"
    row1 = { id = "gen_row1_" .. id, type = "container", columns = 2, gap = 12,
      children = {
        { type = "text",   name = fn(id, "name"),
          label = "Name", default = cfg.name or "",
          placeholder = "My Config" },
        { type = "select", name = fn(id, "toolchain_id"),
          label = tc_label, default = cfg.toolchain_id or "", options = tc_opts },
      }}
  else
    row1 = { type = "text", name = fn(id, "name"),
      label = "Name", default = cfg.name or "", placeholder = "My Config" }
  end

  -- `notify_on_completion` defaults to true on missing — we treat the
  -- absence of the field as "yes please notify" so existing configs keep
  -- their previous behaviour.
  local notify_default = cfg.notify_on_completion
  if notify_default == nil then notify_default = true end

  return {
    id          = "gen_" .. id,
    type        = "section",
    title       = "General",
    collapsible = true,
    collapsed   = false,
    children    = {
      row1,
      { type = "file", pick_mode = "folder", name = fn(id, "cwd"),
        label = "Working Directory", default = cfg.cwd or "",
        placeholder = "Repo root (leave empty)" },
      { type = "textarea", name = fn(id, "description"),
        label = "Description", default = cfg.description or "",
        placeholder = "Optional — what this configuration is for",
        rows = 2 },
      { type = "toggle", name = fn(id, "notify_on_completion"),
        label = "Notify on completion",
        hint  = "Toast a success/failure notification when the build finishes.",
        default = notify_default },
    },
  }
end

local function env_section(cfg)
  local id = cfg.id
  return {
    id          = "env_" .. id,
    type        = "section",
    title       = "Environment Variables",
    collapsible = true,
    collapsed   = true,
    description = "Always applied to this build. Per-profile overrides below "
               .. "win when a matching profile is active.",
    children = {
      { type = "kv_list", name = fn(id, "env"),
        default = cfg.env or {},
        key_placeholder = "KEY", value_placeholder = "value" },
    },
  }
end

local function profile_env_section(cfg)
  local id = cfg.id
  local pe = cfg.profile_env or {}
  local children = {}
  for _, p in ipairs(PROFILE_KEYS) do
    children[#children+1] = { type = "paragraph", variant = "heading",
      content = p }
    children[#children+1] = { type = "kv_list",
      name = fn(id, "profile_env__" .. p),
      default = pe[p] or {},
      key_placeholder = "KEY", value_placeholder = "value" }
  end
  return {
    id          = "profenv_" .. id,
    type        = "section",
    title       = "Per-profile Environment",
    collapsible = true,
    collapsed   = true,
    description = "Variables here override the base environment when the "
               .. "matching profile is selected in the title-bar pill.",
    children    = children,
  }
end

local function before_launch_section(cfg)
  local id = cfg.id
  return {
    id          = "prelaunch_" .. id,
    type        = "section",
    title       = "Before Launch",
    collapsible = true,
    collapsed   = true,
    description = "Tasks executed sequentially before this build. The chain "
               .. "stops on the first failure.",
    children    = {
      { type = "table", name = fn(id, "before_launch"),
        default = cfg.before_launch or {},
        columns = {
          { key = "step_type", label = "Type", type = "select", width = "120px",
            options = {
              { value = "build", label = "Run build…" },
              { value = "shell", label = "Shell command" },
            }},
          { key = "target", label = "Target",
            placeholder = "Build config id, or shell command" },
          { key = "cwd", label = "Working dir", width = "180px",
            placeholder = "Optional (shell only)" },
        }},
      { type = "alert", variant = "info",
        text = "Tip: paste another config's id (e.g. cfg_123…) for a "
            .. "build-type step. For shell steps, the target is the "
            .. "literal command line to run." },
    },
  }
end

local function build_options_section(id, children)
  return {
    id          = "build_" .. id,
    type        = "section",
    title       = "Build Options",
    collapsible = true,
    collapsed   = true,
    children    = children,
  }
end

-- Common free-form command-line arguments, appended verbatim to every
-- template's resolved command. This is where ad-hoc `-D` system properties
-- live (e.g. `-Dfilter=xxx`, `-DskipITs`) — distinct from MAVEN_OPTS /
-- GRADLE_OPTS, which are JVM flags for the build tool process, not args
-- handed to the build itself.
local function extra_args_field(id, cfg)
  return { type = "text", name = fn(id, "extra_args"),
    label = "Additional arguments", default = cfg.extra_args or "",
    placeholder = "-Dfilter=xxx -DskipITs",
    hint  = "Appended verbatim to the command line — e.g. -D system "
         .. "properties passed to the build tool. For npm/pnpm, prefix "
         .. "with -- to forward args to the script." }
end

local function resolved_command(cfg, tpl)
  return {
    { type = "divider" },
    { type = "paragraph", variant = "caption",
      content = "Resolved command" },
    { type = "code", language = "bash", copy = true,
      toast = "Command copied",
      text  = M.full_command(cfg) },
  }
end

-- Compose the full schema from the parts above. The common "Additional
-- arguments" field is tacked onto the end of the template's own build
-- options so it appears in the same card for every template.
local function compose(cfg, tpl, options_children)
  local id = cfg.id
  local build_children = {}
  for _, c in ipairs(options_children) do build_children[#build_children+1] = c end
  build_children[#build_children+1] = extra_args_field(id, cfg)

  local nodes = {
    general_section(cfg, tpl.toolchain_kind),
    build_options_section(id, build_children),
    env_section(cfg),
    profile_env_section(cfg),
    before_launch_section(cfg),
  }
  for _, n in ipairs(resolved_command(cfg, tpl)) do
    nodes[#nodes+1] = n
  end
  return nodes
end

-- ── Template registry ─────────────────────────────────────────────────────────

M.build = {}

-- Helper: an integer-valued text field that allows "" (off) or a positive
-- integer like Maven's `-T <n>`.
local function int_field(id, key, label, default, hint)
  return { type = "text", name = fn(id, key),
    label = label, default = default or "",
    placeholder = "auto",
    hint  = hint }
end

M.build.maven = {
  id             = "maven",
  label          = "Maven",
  icon           = "Coffee",
  tag            = "Maven",
  tag_variant    = "ok",
  toolchain_kind = "jdk",
  new_defaults   = function()
    return { name = "Maven build", goals = "clean package",
             profiles = "", skip_tests = false,
             offline = false, parallel_threads = "",
             update_snapshots = false, maven_opts = "" }
  end,
  schema = function(cfg)
    local id = cfg.id
    local options = {
      { type = "text", name = fn(id, "goals"),
        label = "Goals", default = cfg.goals or "clean package",
        hint  = "Space-separated Maven goals (e.g. 'clean package install')" },
      { type = "text", name = fn(id, "profiles"),
        label = "Profiles", default = cfg.profiles or "",
        hint  = "Comma-separated, e.g. 'dev,prod'" },
      { id = "mvn_row1_" .. id, type = "container", columns = 3, gap = 12,
        children = {
          { type = "checkbox", name = fn(id, "skip_tests"),
            label = "Skip tests", default = cfg.skip_tests or false },
          { type = "checkbox", name = fn(id, "offline"),
            label = "Offline (-o)", default = cfg.offline or false },
          { type = "checkbox", name = fn(id, "update_snapshots"),
            label = "Update snapshots (-U)",
            default = cfg.update_snapshots or false },
        }},
      int_field(id, "parallel_threads", "Parallel threads (-T)",
        cfg.parallel_threads,
        "Empty = single-threaded; '4' or '1C' (= 1 thread per core)."),
      { type = "text", name = fn(id, "maven_opts"),
        label = "MAVEN_OPTS", default = cfg.maven_opts or "",
        placeholder = "-Xmx2g -XX:+UseG1GC",
        hint  = "Injected into the build env as MAVEN_OPTS." },
    }
    return compose(cfg, M.build.maven, options)
  end,
  build_command = function(cfg)
    local parts = { "mvn" }
    if cfg.offline          then parts[#parts+1] = "-o" end
    if cfg.update_snapshots then parts[#parts+1] = "-U" end
    if cfg.parallel_threads and cfg.parallel_threads ~= "" then
      parts[#parts+1] = "-T " .. cfg.parallel_threads
    end
    if cfg.profiles and cfg.profiles ~= "" then
      parts[#parts+1] = "-P " .. cfg.profiles
    end
    if cfg.skip_tests then parts[#parts+1] = "-DskipTests" end
    parts[#parts+1] = cfg.goals or "clean package"
    return table.concat(parts, " ")
  end,
  -- Extra env keys derived from template-specific fields (merged on top of
  -- the user's explicit env, before profile overrides).
  derived_env = function(cfg)
    local env = {}
    if cfg.maven_opts and cfg.maven_opts ~= "" then
      env["MAVEN_OPTS"] = cfg.maven_opts
    end
    return env
  end,
}

M.build.gradle = {
  id             = "gradle",
  label          = "Gradle",
  icon           = "Coffee",
  tag            = "Gradle",
  tag_variant    = "ok",
  toolchain_kind = "jdk",
  new_defaults   = function()
    return { name = "Gradle build", tasks = "build",
             refresh_deps = false, init_script = "",
             use_wrapper = true, parallel = false,
             no_daemon = false, gradle_opts = "" }
  end,
  schema = function(cfg)
    local id = cfg.id
    -- `use_wrapper` defaults to true on missing — preferring `./gradlew`
    -- matches what most projects ship and avoids surprising behaviour.
    local wrapper_default = cfg.use_wrapper
    if wrapper_default == nil then wrapper_default = true end
    local options = {
      { type = "text", name = fn(id, "tasks"),
        label = "Tasks", default = cfg.tasks or "build",
        hint  = "Space-separated tasks (e.g. 'clean build')" },
      { id = "gradle_row1_" .. id, type = "container", columns = 3, gap = 12,
        children = {
          { type = "checkbox", name = fn(id, "use_wrapper"),
            label = "Use ./gradlew", default = wrapper_default },
          { type = "checkbox", name = fn(id, "parallel"),
            label = "Parallel (--parallel)",
            default = cfg.parallel or false },
          { type = "checkbox", name = fn(id, "no_daemon"),
            label = "No daemon (--no-daemon)",
            default = cfg.no_daemon or false },
        }},
      { type = "checkbox", name = fn(id, "refresh_deps"),
        label = "Refresh dependencies (--refresh-dependencies)",
        default = cfg.refresh_deps or false },
      { type = "file", pick_mode = "file", name = fn(id, "init_script"),
        label = "Init script", default = cfg.init_script or "",
        placeholder = "Optional — init.gradle(.kts)" },
      { type = "text", name = fn(id, "gradle_opts"),
        label = "GRADLE_OPTS", default = cfg.gradle_opts or "",
        placeholder = "-Xmx2g -Dorg.gradle.daemon=false",
        hint  = "Injected into the build env as GRADLE_OPTS." },
    }
    return compose(cfg, M.build.gradle, options)
  end,
  build_command = function(cfg)
    local use_wrapper = cfg.use_wrapper
    if use_wrapper == nil then use_wrapper = true end
    local parts = { use_wrapper and "./gradlew" or "gradle" }
    if cfg.parallel        then parts[#parts+1] = "--parallel" end
    if cfg.no_daemon       then parts[#parts+1] = "--no-daemon" end
    if cfg.refresh_deps    then parts[#parts+1] = "--refresh-dependencies" end
    if cfg.init_script and cfg.init_script ~= "" then
      parts[#parts+1] = "-I \"" .. cfg.init_script .. "\""
    end
    parts[#parts+1] = cfg.tasks or "build"
    return table.concat(parts, " ")
  end,
  derived_env = function(cfg)
    local env = {}
    if cfg.gradle_opts and cfg.gradle_opts ~= "" then
      env["GRADLE_OPTS"] = cfg.gradle_opts
    end
    return env
  end,
}

M.build.cargo = {
  id             = "cargo",
  label          = "Cargo",
  icon           = "Package",
  tag            = "Cargo",
  tag_variant    = "accent",
  toolchain_kind = "rust",
  new_defaults   = function()
    return { name = "Cargo build", subcommand = "build",
             features = "", release = false,
             target = "", backtrace = "short",
             all_features = false, no_default_features = false,
             rustflags = "", workspace_member = "" }
  end,
  schema = function(cfg)
    local id = cfg.id
    local options = {
      { id = "cargo_row1_" .. id, type = "container", columns = 2, gap = 12,
        children = {
          { type = "select", name = fn(id, "subcommand"),
            label = "Subcommand", default = cfg.subcommand or "build",
            options = {
              { value = "build",  label = "build"  },
              { value = "check",  label = "check"  },
              { value = "test",   label = "test"   },
              { value = "clippy", label = "clippy" },
            }},
          { type = "text", name = fn(id, "target"),
            label = "Target triple", default = cfg.target or "",
            placeholder = "Optional — e.g. x86_64-unknown-linux-gnu" },
        }},
      { type = "text", name = fn(id, "workspace_member"),
        label = "Workspace member (-p)",
        default = cfg.workspace_member or "",
        placeholder = "Optional — package name when in a workspace",
        hint  = "Maps to `cargo <sub> -p <name>`." },
      { type = "text", name = fn(id, "features"),
        label = "Features", default = cfg.features or "",
        placeholder = "Comma-separated, e.g. feat_a,feat_b",
        hint  = "Ignored when 'all features' is on." },
      { id = "cargo_row2_" .. id, type = "container", columns = 3, gap = 12,
        children = {
          { type = "checkbox", name = fn(id, "release"),
            label = "Release (--release)",
            default = cfg.release or false },
          { type = "checkbox", name = fn(id, "all_features"),
            label = "All features",
            default = cfg.all_features or false },
          { type = "checkbox", name = fn(id, "no_default_features"),
            label = "No default features",
            default = cfg.no_default_features or false },
        }},
      { id = "cargo_row3_" .. id, type = "container", columns = 2, gap = 12,
        children = {
          { type = "select", name = fn(id, "backtrace"),
            label = "Backtrace", default = cfg.backtrace or "short",
            options = {
              { value = "",      label = "Off"   },
              { value = "short", label = "Short" },
              { value = "full",  label = "Full"  },
            }},
          { type = "text", name = fn(id, "rustflags"),
            label = "RUSTFLAGS", default = cfg.rustflags or "",
            placeholder = "-C target-cpu=native",
            hint = "Injected as RUSTFLAGS into the build env." },
        }},
    }
    return compose(cfg, M.build.cargo, options)
  end,
  build_command = function(cfg)
    local parts = { "cargo", cfg.subcommand or "build" }
    if cfg.workspace_member and cfg.workspace_member ~= "" then
      parts[#parts+1] = "-p " .. cfg.workspace_member
    end
    if cfg.release             then parts[#parts+1] = "--release" end
    if cfg.no_default_features then parts[#parts+1] = "--no-default-features" end
    if cfg.all_features then
      parts[#parts+1] = "--all-features"
    elseif cfg.features and cfg.features ~= "" then
      parts[#parts+1] = "--features " .. cfg.features
    end
    if cfg.target and cfg.target ~= "" then
      parts[#parts+1] = "--target " .. cfg.target
    end
    return table.concat(parts, " ")
  end,
  derived_env = function(cfg)
    local env = {}
    if cfg.backtrace and cfg.backtrace ~= "" then
      env["RUST_BACKTRACE"] = cfg.backtrace
    end
    if cfg.rustflags and cfg.rustflags ~= "" then
      env["RUSTFLAGS"] = cfg.rustflags
    end
    return env
  end,
}

M.build.npm = {
  id             = "npm",
  label          = "npm / Yarn / pnpm",
  icon           = "Triangle",
  tag            = "npm",
  tag_variant    = "warn",
  toolchain_kind = "node",
  new_defaults   = function()
    return { name = "npm build", package_manager = "npm", script = "build",
             node_options = "" }
  end,
  schema = function(cfg)
    local id = cfg.id
    local options = {
      { id = "npm_row1_" .. id, type = "container", columns = 2, gap = 12,
        children = {
          { type = "select", name = fn(id, "package_manager"),
            label = "Package manager", default = cfg.package_manager or "npm",
            options = {
              { value = "npm",  label = "npm"  },
              { value = "yarn", label = "yarn" },
              { value = "pnpm", label = "pnpm" },
            }},
          { type = "text", name = fn(id, "script"),
            label = "Script", default = cfg.script or "build",
            hint  = "package.json script (e.g. 'build', 'lint')" },
        }},
      { type = "text", name = fn(id, "node_options"),
        label = "NODE_OPTIONS", default = cfg.node_options or "",
        placeholder = "--max-old-space-size=4096",
        hint  = "Injected into the build env as NODE_OPTIONS." },
    }
    return compose(cfg, M.build.npm, options)
  end,
  build_command = function(cfg)
    local pm  = cfg.package_manager or "npm"
    local scr = cfg.script or "build"
    if pm == "yarn" then return "yarn " .. scr end
    return pm .. " run " .. scr
  end,
  derived_env = function(cfg)
    local env = {}
    if cfg.node_options and cfg.node_options ~= "" then
      env["NODE_OPTIONS"] = cfg.node_options
    end
    return env
  end,
}

M.build.make = {
  id             = "make",
  label          = "Makefile",
  icon           = "Hammer",
  tag            = "Make",
  tag_variant    = "neutral",
  toolchain_kind = nil,
  new_defaults   = function()
    return { name = "Makefile target", target = "all", jobs = "" }
  end,
  schema = function(cfg)
    local id = cfg.id
    local options = {
      { type = "text", name = fn(id, "target"),
        label = "Target", default = cfg.target or "all",
        hint  = "Makefile target (e.g. 'all', 'install')" },
      int_field(id, "jobs", "Parallel jobs (-j)",
        cfg.jobs,
        "Empty = sequential. '4' = -j4. '0' = -j (use all cores)."),
    }
    return compose(cfg, M.build.make, options)
  end,
  build_command = function(cfg)
    local parts = { "make" }
    local j = cfg.jobs or ""
    if j == "0" then
      parts[#parts+1] = "-j"
    elseif j ~= "" then
      parts[#parts+1] = "-j" .. j
    end
    parts[#parts+1] = cfg.target or "all"
    return table.concat(parts, " ")
  end,
}

-- Ordered list for the "New ▾" menu + tree grouping.
M.build_order = { "maven", "gradle", "cargo", "npm", "make" }

function M.build_get(template_id)
  return M.build[template_id]
end

-- Resolve the final shell command: the template's own command plus the
-- common free-form `extra_args` (appended verbatim). Every call site that
-- needs the runnable command — the editor preview, apply_ctx, new_config —
-- goes through here so the two pieces never drift apart.
function M.full_command(cfg)
  local tpl = M.build_get(cfg.template_id)
  if not tpl then return cfg.command or "" end
  local base  = tpl.build_command(cfg)
  local extra = cfg.extra_args or ""
  if extra ~= "" then return base .. " " .. extra end
  return base
end

-- Resolve a config's effective env layered as:
--   base env  →  template-derived env  →  active-profile overrides
-- Where each later layer wins. Caller passes `active_profile` (string) —
-- when nil/empty/missing-from-cfg, only the first two layers apply.
-- Returns a flat string→string map ready to feed `arbor.job.spawn{ env = … }`.
function M.resolve_effective_env(cfg, active_profile)
  local out = {}
  for k, v in pairs(cfg.env or {}) do out[k] = v end

  local tpl = M.build_get(cfg.template_id)
  if tpl and tpl.derived_env then
    for k, v in pairs(tpl.derived_env(cfg) or {}) do
      out[k] = v
    end
  end

  if active_profile and active_profile ~= "" then
    local pe = (cfg.profile_env or {})[active_profile]
    if type(pe) == "table" then
      for k, v in pairs(pe) do out[k] = v end
    end
  end
  return out
end

-- Apply ctx values onto a config, regenerate command. Handles common keys
-- (name/cwd/env/toolchain/description/notify/profile_env/before_launch)
-- plus every key declared by the template's `new_defaults`.
function M.apply_ctx(cfg, ctx)
  local tpl = M.build_get(cfg.template_id)
  if not tpl then return cfg end
  local id = cfg.id
  local function v(key) return ctx["cfg_" .. id .. "__" .. key] end

  local name = v("name"); if name ~= nil and name ~= "" then cfg.name = name end
  local cwd  = v("cwd");  if cwd  ~= nil then cfg.cwd = cwd end
  local env  = v("env");  if env  ~= nil then cfg.env = env end
  if tpl.toolchain_kind then
    local tcid = v("toolchain_id")
    if tcid ~= nil then cfg.toolchain_id = tcid end
  end

  -- Common: description, notify_on_completion, extra_args, before_launch.
  local desc = v("description"); if desc ~= nil then cfg.description = desc end
  local notify = v("notify_on_completion")
  if notify ~= nil then cfg.notify_on_completion = notify and true or false end
  local ea = v("extra_args"); if ea ~= nil then cfg.extra_args = ea end
  local bl = v("before_launch")
  if bl ~= nil then
    -- Strip rows where both target and step type are blank — empty
    -- placeholders inserted by the table widget shouldn't survive save.
    local cleaned = {}
    for _, row in ipairs(bl) do
      local t = (row.target or ""):gsub("^%s+", ""):gsub("%s+$", "")
      if t ~= "" then
        -- The table widget creates fresh rows with step_type="" — fall
        -- back to "shell" so a row with only a target typed in still does
        -- something sensible. Users that meant `build` need to flip the
        -- type select explicitly.
        local kind = row.step_type
        if not kind or kind == "" then kind = "shell" end
        cleaned[#cleaned+1] = {
          step_type = kind,
          target    = t,
          cwd       = (row.cwd or "") ~= "" and row.cwd or nil,
        }
      end
    end
    cfg.before_launch = cleaned
  end

  -- Per-profile env: each profile's kv_list lives in its own field.
  cfg.profile_env = cfg.profile_env or { dev = {}, prod = {}, test = {} }
  for _, p in ipairs(PROFILE_KEYS) do
    local pe = v("profile_env__" .. p)
    if pe ~= nil then cfg.profile_env[p] = pe end
  end

  -- Walk template defaults to know which keys are "template-specific".
  for k, _ in pairs(tpl.new_defaults()) do
    if k ~= "name" then
      local cv = v(k)
      if cv ~= nil then cfg[k] = cv end
    end
  end

  cfg.command = M.full_command(cfg)
  return cfg
end

-- Fresh config from a template.
function M.new_config(template_id)
  local tpl = M.build_get(template_id)
  if not tpl then return nil end
  local id = "cfg_" .. tostring(math.floor((os.time() % 1000000) * 1000)) ..
             "_" .. tostring(math.random(1000, 9999))
  local cfg = {
    id           = id,
    template_id  = template_id,
    toolchain_id = "",
    cwd          = "",
    env          = {},
  }
  for k, v in pairs(common_defaults())   do cfg[k] = v end
  for k, v in pairs(tpl.new_defaults())  do cfg[k] = v end
  cfg.command = M.full_command(cfg)
  return cfg
end

return M
