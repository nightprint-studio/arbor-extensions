-- config/run_templates.lua — Run config templates for run-action.
--
-- Each template exposes:
--   · metadata       (label, icon, tag, tag_variant, toolchain_kind, config_type)
--   · new_defaults() — initial template-specific field values for a fresh
--                       config (excludes the common keys handled by `compose`)
--   · schema(cfg)    — list of FormNode for the config's editor card
--   · build_command(cfg) — final shell command (Tomcat: placeholder — runtime
--                          does the deploy+start dance instead)
--   · build_env(cfg)     — extra env vars derived from template fields
--                          (vm_args, JPDA, NODE_OPTIONS, …)
--
-- Storage format (per config):
--   { id, template_id, config_type (for runtime), name, toolchain_id, cwd,
--     env, command, build_id,
--     description, notify_on_completion,
--     profile_env  = { dev = {...}, prod = {...}, test = {...} },
--     before_launch = { { step_type, target, cwd? }, ... },
--     ...template-specific fields... }

local M = {}

-- Prefixed field name: rcfg_<id>__<key>.
local function fn(id, key) return "rcfg_" .. id .. "__" .. key end
M.fn = fn

-- Profiles whose env we offer per-config overrides for. Mirrors compile-action.
local PROFILE_KEYS = { "dev", "prod", "test" }

local function common_defaults()
  return {
    description          = "",
    notify_on_completion = true,
    profile_env          = { dev = {}, prod = {}, test = {} },
    before_launch       = {},
  }
end

-- ── Shared Java debug-agent flag ──────────────────────────────────────────────

local function jdwp_flag(port)
  if not port or port == "" then return "" end
  return "-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=*:" .. port
end

-- ── Build-before-run picker options ───────────────────────────────────────────

local function build_before_run_opts()
  return {
    { value = "",         label = "Use currently-selected build configuration" },
    { value = "__skip__", label = "Skip build (run command handles it)"         },
  }
end

-- ── Layout helpers ────────────────────────────────────────────────────────────
-- Same overall structure as compile-action's editor:
--   · "General"               — name, toolchain, cwd, build-before-run,
--                                description, notify
--   · "Run Options"           — template-specific fields
--   · "Environment Variables" — base env (always applied)
--   · "Per-profile Environment" — overrides applied when the matching
--                                  active-profile is selected (dev/prod/test)
--   · "Before Launch"         — extra tasks run sequentially BEFORE the run
--                                (in addition to the build chosen above)
-- Followed by the resolved-command preview with floating Copy button.

local function general_section(cfg, toolchain_kind, default_build_id)
  local id = cfg.id

  -- Row 1: Name + Toolchain (when applicable). Falls back to a single field
  -- when there's no toolchain so we don't render a half-empty grid.
  local row1
  if toolchain_kind then
    local tc_opts = { { value = "", label = "Use global default" } }
    local ok, list = pcall(arbor.toolchain.list, toolchain_kind)
    if ok and list then
      for _, t in ipairs(list) do
        tc_opts[#tc_opts+1] = { value = t.id, label = t.label }
      end
    end
    local tc_label = toolchain_kind == "jdk"  and "JDK"
                  or toolchain_kind == "node" and "Node.js"
                  or toolchain_kind == "rust" and "Rust toolchain"
                  or "Toolchain"
    row1 = { id = "rgen_row1_" .. id, type = "container", columns = 2, gap = 12,
      children = {
        { type = "text", name = fn(id, "name"),
          label = "Name", default = cfg.name or "", placeholder = "My Config" },
        { type = "select", name = fn(id, "toolchain_id"),
          label = tc_label, default = cfg.toolchain_id or "", options = tc_opts },
      }}
  else
    row1 = { type = "text", name = fn(id, "name"),
      label = "Name", default = cfg.name or "", placeholder = "My Config" }
  end

  local notify_default = cfg.notify_on_completion
  if notify_default == nil then notify_default = true end

  return {
    id          = "rgen_" .. id,
    type        = "section",
    title       = "General",
    collapsible = true,
    collapsed   = false,
    children    = {
      row1,
      { type = "file", pick_mode = "folder", name = fn(id, "cwd"),
        label = "Working Directory", default = cfg.cwd or "",
        placeholder = "Repo root (leave empty)" },
      { type = "select", name = fn(id, "build_id"),
        label   = "Build before run",
        default = cfg.build_id or default_build_id or "",
        options = build_before_run_opts() },
      { type = "textarea", name = fn(id, "description"),
        label = "Description", default = cfg.description or "",
        placeholder = "Optional — what this run configuration is for",
        rows  = 2 },
      { type = "toggle", name = fn(id, "notify_on_completion"),
        label = "Notify on completion",
        hint  = "Toast a notification when the application exits.",
        default = notify_default },
    },
  }
end

local function run_options_section(id, children)
  return {
    id          = "rrun_" .. id,
    type        = "section",
    title       = "Run Options",
    collapsible = true,
    collapsed   = true,
    children    = children,
  }
end

local function env_section(cfg)
  local id = cfg.id
  return {
    id          = "renv_" .. id,
    type        = "section",
    title       = "Environment Variables",
    collapsible = true,
    collapsed   = true,
    description = "Always applied. Per-profile overrides below win when a "
               .. "matching profile is active.",
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
    id          = "rprofenv_" .. id,
    type        = "section",
    title       = "Per-profile Environment",
    collapsible = true,
    collapsed   = true,
    description = "Overrides applied when the matching profile is selected "
               .. "in the title-bar pill.",
    children    = children,
  }
end

local function before_launch_section(cfg)
  local id = cfg.id
  return {
    id          = "rprelaunch_" .. id,
    type        = "section",
    title       = "Before Launch",
    collapsible = true,
    collapsed   = true,
    description = "Tasks executed sequentially before the run (after the "
               .. "build, if any). The chain stops on the first failure.",
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
    },
  }
end

local function resolved_command(cfg, tpl)
  local caption = tpl.id == "tomcat"
    and "Runtime deploys the WAR into <tomcat_home>/webapps, then starts catalina:"
    or  "Resolved command"
  return {
    { type = "divider" },
    { type = "paragraph", variant = "caption", content = caption },
    { type = "code", language = "bash", copy = true,
      toast = "Command copied",
      text  = tpl.build_command(cfg) },
  }
end

-- Compose the full schema from the parts above.
local function compose(cfg, tpl, options_children, default_build_id)
  local id = cfg.id
  local nodes = {
    general_section(cfg, tpl.toolchain_kind, default_build_id),
    run_options_section(id, options_children),
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

M.run = {}

-- ── simple_java ───────────────────────────────────────────────────────────────

M.run.simple_java = {
  id             = "simple_java",
  label          = "Java — plain JAR",
  icon           = "Package",
  tag            = "JAR",
  tag_variant    = "accent",
  toolchain_kind = "jdk",
  config_type    = "custom",
  new_defaults   = function()
    -- The plain `java -jar` run path is self-contained; the JAR must already
    -- exist on disk. We never want to chain a build before this — users who
    -- need a build can pick it explicitly in the form.
    return { name = "Run JAR", jar_path = "", main_class = "",
             vm_args = "", debug_port = "", build_id = "__skip__" }
  end,
  schema = function(cfg)
    local id = cfg.id
    local options = {
      { type = "file", pick_mode = "file", name = fn(id, "jar_path"),
        label = "JAR path", default = cfg.jar_path or "",
        placeholder = "Absolute path or relative to working directory" },
      { type = "text", name = fn(id, "main_class"),
        label = "Main class", default = cfg.main_class or "",
        hint  = "Optional — overrides the MANIFEST Main-Class. Empty uses -jar." },
      { type = "text", name = fn(id, "vm_args"),
        label = "VM args", default = cfg.vm_args or "",
        placeholder = "-Xmx512m -Dkey=value",
        hint  = "JVM flags passed to `java`." },
      { type = "text", name = fn(id, "debug_port"),
        label = "Debug port (JDWP)", default = cfg.debug_port or "",
        placeholder = "5005 (leave empty to disable)" },
    }
    return compose(cfg, M.run.simple_java, options, "__skip__")
  end,
  build_command = function(cfg)
    local parts = { "java" }
    if cfg.vm_args and cfg.vm_args ~= "" then parts[#parts+1] = cfg.vm_args end
    local jdwp = jdwp_flag(cfg.debug_port)
    if jdwp ~= "" then parts[#parts+1] = jdwp end
    if cfg.main_class and cfg.main_class ~= "" then
      if cfg.jar_path and cfg.jar_path ~= "" then
        parts[#parts+1] = "-cp \"" .. cfg.jar_path .. "\""
      end
      parts[#parts+1] = cfg.main_class
    else
      parts[#parts+1] = "-jar \"" .. (cfg.jar_path or "app.jar") .. "\""
    end
    return table.concat(parts, " ")
  end,
  build_env = function(_cfg) return {} end,
}

-- ── spring ────────────────────────────────────────────────────────────────────

M.run.spring = {
  id             = "spring",
  label          = "Spring Boot",
  icon           = "Leaf",
  tag            = "Spring",
  tag_variant    = "ok",
  toolchain_kind = "jdk",
  config_type    = "spring",
  new_defaults   = function()
    -- `mvn spring-boot:run` / `gradlew bootRun` already compile sources on
    -- the fly — running a separate build first is wasted work.
    return { name = "Spring Boot run", tool = "maven",
             active_profile = "", extra_args = "",
             vm_args = "", debug_port = "", build_id = "__skip__" }
  end,
  schema = function(cfg)
    local id = cfg.id
    local options = {
      { id = "rspring_row1_" .. id, type = "container", columns = 2, gap = 12,
        children = {
          { type = "select", name = fn(id, "tool"),
            label = "Build tool", default = cfg.tool or "maven",
            options = {
              { value = "maven",  label = "Maven (mvn spring-boot:run)" },
              { value = "gradle", label = "Gradle (gradlew bootRun)"     },
            }},
          { type = "text", name = fn(id, "active_profile"),
            label = "Spring profile", default = cfg.active_profile or "",
            placeholder = "dev / prod / dev,prod" },
        }},
      { type = "text", name = fn(id, "extra_args"),
        label = "Extra arguments", default = cfg.extra_args or "",
        hint  = "Passed verbatim to the build tool." },
      { type = "text", name = fn(id, "vm_args"),
        label = "VM args", default = cfg.vm_args or "",
        placeholder = "-Xmx1g -Dproperty=value",
        hint  = "Wrapped into -Dspring-boot.run.jvmArguments (Maven) or "
             .. "exposed via JAVA_OPTS (Gradle)." },
      { type = "text", name = fn(id, "debug_port"),
        label = "Debug port (JDWP)", default = cfg.debug_port or "",
        placeholder = "5005 (leave empty to disable)" },
    }
    return compose(cfg, M.run.spring, options, "__skip__")
  end,
  build_command = function(cfg)
    local tool   = cfg.tool or "maven"
    local prof   = cfg.active_profile or ""
    local jdwp   = jdwp_flag(cfg.debug_port)
    local jvm    = cfg.vm_args or ""
    if jdwp ~= "" then jvm = (jvm ~= "" and (jvm .. " ") or "") .. jdwp end

    if tool == "gradle" then
      local parts = { "gradlew", "bootRun" }
      local args = {}
      if prof ~= "" then args[#args+1] = "--spring.profiles.active=" .. prof end
      if #args > 0 then
        parts[#parts+1] = "--args='" .. table.concat(args, " ") .. "'"
      end
      if cfg.extra_args and cfg.extra_args ~= "" then
        parts[#parts+1] = cfg.extra_args
      end
      return table.concat(parts, " ")
    end

    -- maven (default)
    local parts = { "mvn", "spring-boot:run" }
    if prof ~= "" then parts[#parts+1] = "-Dspring-boot.run.profiles=" .. prof end
    if jvm  ~= "" then
      parts[#parts+1] = '-Dspring-boot.run.jvmArguments="' .. jvm .. '"'
    end
    if cfg.extra_args and cfg.extra_args ~= "" then
      parts[#parts+1] = cfg.extra_args
    end
    return table.concat(parts, " ")
  end,
  build_env = function(cfg)
    -- Gradle bootRun doesn't support jvmArguments inline; use JAVA_OPTS instead.
    if (cfg.tool or "maven") ~= "gradle" then return {} end
    local env = {}
    local jvm = cfg.vm_args or ""
    local jdwp = jdwp_flag(cfg.debug_port)
    if jdwp ~= "" then jvm = (jvm ~= "" and (jvm .. " ") or "") .. jdwp end
    if jvm ~= "" then env.JAVA_OPTS = jvm end
    return env
  end,
}

-- ── tomcat ────────────────────────────────────────────────────────────────────

M.run.tomcat = {
  id             = "tomcat",
  label          = "Tomcat",
  icon           = "Server",
  tag            = "Tomcat",
  tag_variant    = "test",
  toolchain_kind = "jdk",
  config_type    = "tomcat",
  new_defaults   = function()
    return { name = "Tomcat run", tomcat_home = "", war_relative_path = "",
             vm_args = "", debug_port = "" }
  end,
  schema = function(cfg)
    local id = cfg.id
    local options = {
      { type = "file", pick_mode = "folder", name = fn(id, "tomcat_home"),
        label = "Tomcat Home (CATALINA_HOME)",
        default = cfg.tomcat_home or "",
        placeholder = "/opt/tomcat or C:\\apache-tomcat-10" },
      { type = "text", name = fn(id, "war_relative_path"),
        label = "WAR output directory",
        default = cfg.war_relative_path or "",
        placeholder = "target (default)",
        hint  = "Relative to the build working dir; or absolute. Empty = "
             .. "<build-cwd>/target (Maven default)." },
      { type = "text", name = fn(id, "vm_args"),
        label = "VM args (CATALINA_OPTS)",
        default = cfg.vm_args or "",
        placeholder = "-Xmx2g -Dproperty=value",
        hint  = "Injected as CATALINA_OPTS." },
      { type = "text", name = fn(id, "debug_port"),
        label = "JPDA Debug Port",
        default = cfg.debug_port or "",
        placeholder = "5005 (leave empty to disable)" },
    }
    return compose(cfg, M.run.tomcat, options, "")
  end,
  build_command = function(cfg)
    local tomcat_home = cfg.tomcat_home or ""
    if tomcat_home == "" then return "(set Tomcat Home first)" end
    local is_win = arbor.meta.os() == "windows"
    local script = is_win and "catalina.bat" or "catalina.sh"
    local bin    = arbor.fs.join(tomcat_home, "bin", script)
    local jpda   = (cfg.debug_port or "") ~= ""
    return '"' .. bin .. '" ' .. (jpda and "jpda run" or "run")
  end,
  build_env = function(cfg)
    local env = {}
    if cfg.vm_args and cfg.vm_args ~= "" then env.CATALINA_OPTS = cfg.vm_args end
    if cfg.debug_port and cfg.debug_port ~= "" then
      env.JPDA_ADDRESS   = "*:" .. cfg.debug_port
      env.JPDA_TRANSPORT = "dt_socket"
    end
    return env
  end,
}

-- ── cargo ─────────────────────────────────────────────────────────────────────

M.run.cargo = {
  id             = "cargo",
  label          = "Cargo",
  icon           = "Package",
  tag            = "Cargo",
  tag_variant    = "accent",
  toolchain_kind = "rust",
  config_type    = "rust",
  new_defaults   = function()
    -- `cargo run` already compiles before launching the binary — chaining a
    -- separate `cargo build` step would just compile twice.
    return { name = "Cargo run", bin = "", example = "",
             features = "", release = false, all_features = false,
             no_default_features = false, args = "",
             rustflags = "", build_id = "__skip__" }
  end,
  schema = function(cfg)
    local id = cfg.id
    local options = {
      { id = "rcargo_row1_" .. id, type = "container", columns = 2, gap = 12,
        children = {
          { type = "text", name = fn(id, "bin"),
            label = "Binary (--bin)", default = cfg.bin or "",
            placeholder = "Optional — workspace bin name" },
          { type = "text", name = fn(id, "example"),
            label = "Example (--example)", default = cfg.example or "",
            placeholder = "Optional — example name" },
        }},
      { type = "text", name = fn(id, "features"),
        label = "Features", default = cfg.features or "",
        placeholder = "Comma-separated, e.g. feat_a,feat_b",
        hint  = "Ignored when 'all features' is on." },
      { id = "rcargo_row2_" .. id, type = "container", columns = 3, gap = 12,
        children = {
          { type = "checkbox", name = fn(id, "release"),
            label = "Release (--release)", default = cfg.release or false },
          { type = "checkbox", name = fn(id, "all_features"),
            label = "All features", default = cfg.all_features or false },
          { type = "checkbox", name = fn(id, "no_default_features"),
            label = "No default features",
            default = cfg.no_default_features or false },
        }},
      { type = "text", name = fn(id, "args"),
        label = "Program arguments", default = cfg.args or "",
        hint  = "Passed after `--` to the compiled binary." },
      { type = "text", name = fn(id, "rustflags"),
        label = "RUSTFLAGS", default = cfg.rustflags or "",
        placeholder = "-C target-cpu=native",
        hint  = "Injected as RUSTFLAGS into the run env." },
    }
    return compose(cfg, M.run.cargo, options, "__skip__")
  end,
  build_command = function(cfg)
    local parts = { "cargo", "run" }
    if cfg.release             then parts[#parts+1] = "--release" end
    if cfg.no_default_features then parts[#parts+1] = "--no-default-features" end
    if cfg.bin and cfg.bin ~= ""           then parts[#parts+1] = "--bin "     .. cfg.bin     end
    if cfg.example and cfg.example ~= ""   then parts[#parts+1] = "--example " .. cfg.example end
    if cfg.all_features then
      parts[#parts+1] = "--all-features"
    elseif cfg.features and cfg.features ~= "" then
      parts[#parts+1] = "--features " .. cfg.features
    end
    if cfg.args and cfg.args ~= "" then
      parts[#parts+1] = "-- " .. cfg.args
    end
    return table.concat(parts, " ")
  end,
  build_env = function(cfg)
    local env = {}
    if cfg.rustflags and cfg.rustflags ~= "" then
      env.RUSTFLAGS = cfg.rustflags
    end
    return env
  end,
}

-- ── npm ───────────────────────────────────────────────────────────────────────

M.run.npm = {
  id             = "npm",
  label          = "npm / Yarn / pnpm",
  icon           = "Triangle",
  tag            = "npm",
  tag_variant    = "warn",
  toolchain_kind = "node",
  config_type    = "node",
  new_defaults   = function()
    -- `npm/yarn/pnpm <script>` is the full launch — bundlers/dev servers
    -- handle their own incremental builds, so a pre-build step is redundant.
    return { name = "npm dev", package_manager = "npm",
             script = "dev", args = "", debug_port = "",
             node_options = "", build_id = "__skip__" }
  end,
  schema = function(cfg)
    local id = cfg.id
    local options = {
      { id = "rnpm_row1_" .. id, type = "container", columns = 2, gap = 12,
        children = {
          { type = "select", name = fn(id, "package_manager"),
            label = "Package manager", default = cfg.package_manager or "npm",
            options = {
              { value = "npm",  label = "npm"  },
              { value = "yarn", label = "yarn" },
              { value = "pnpm", label = "pnpm" },
            }},
          { type = "text", name = fn(id, "script"),
            label = "Script", default = cfg.script or "dev" },
        }},
      { type = "text", name = fn(id, "args"),
        label = "Arguments", default = cfg.args or "",
        hint  = "Passed to the script (after `--` for npm/pnpm)." },
      { id = "rnpm_row2_" .. id, type = "container", columns = 2, gap = 12,
        children = {
          { type = "text", name = fn(id, "debug_port"),
            label = "Debug port (Node --inspect)",
            default = cfg.debug_port or "",
            placeholder = "9229 (leave empty to disable)" },
          { type = "text", name = fn(id, "node_options"),
            label = "Extra NODE_OPTIONS",
            default = cfg.node_options or "",
            placeholder = "--max-old-space-size=4096",
            hint  = "Appended to NODE_OPTIONS (after --inspect, if set)." },
        }},
    }
    return compose(cfg, M.run.npm, options, "__skip__")
  end,
  build_command = function(cfg)
    local pm  = cfg.package_manager or "npm"
    local scr = cfg.script or "dev"
    local args = cfg.args or ""
    if pm == "yarn" then
      if args ~= "" then return "yarn " .. scr .. " " .. args end
      return "yarn " .. scr
    else
      if args ~= "" then return pm .. " run " .. scr .. " -- " .. args end
      return pm .. " run " .. scr
    end
  end,
  build_env = function(cfg)
    local pieces = {}
    if cfg.debug_port and cfg.debug_port ~= "" then
      pieces[#pieces+1] = "--inspect=" .. cfg.debug_port
    end
    if cfg.node_options and cfg.node_options ~= "" then
      pieces[#pieces+1] = cfg.node_options
    end
    if #pieces == 0 then return {} end
    return { NODE_OPTIONS = table.concat(pieces, " ") }
  end,
}

-- ── Ordered list ──────────────────────────────────────────────────────────────

M.run_order = { "simple_java", "spring", "tomcat", "cargo", "npm" }

function M.run_get(template_id) return M.run[template_id] end

-- Resolve a config's effective env layered as:
--   base env  →  template-derived env (build_env)  →  active-profile overrides
-- Each later layer wins. `active_profile` may be nil/empty — only the first
-- two layers are applied in that case. Toolchain layering is the caller's
-- responsibility (it lives in main.lua next to the active-toolchain fallback).
function M.resolve_effective_env(cfg, active_profile)
  local out = {}
  for k, v in pairs(cfg.env or {}) do out[k] = v end

  local tpl = M.run_get(cfg.template_id)
  if tpl and tpl.build_env then
    for k, v in pairs(tpl.build_env(cfg) or {}) do out[k] = v end
  end

  if active_profile and active_profile ~= "" then
    local pe = (cfg.profile_env or {})[active_profile]
    if type(pe) == "table" then
      for k, v in pairs(pe) do out[k] = v end
    end
  end
  return out
end

-- Apply ctx values onto a run config, regenerate command + template env.
function M.apply_ctx(cfg, ctx)
  local tpl = M.run_get(cfg.template_id)
  if not tpl then return cfg end
  local id = cfg.id
  local function v(key) return ctx["rcfg_" .. id .. "__" .. key] end

  local name = v("name");      if name ~= nil and name ~= "" then cfg.name = name end
  local cwd  = v("cwd");       if cwd  ~= nil then cfg.cwd = cwd end
  local env  = v("env");       if env  ~= nil then cfg.env = env end
  local bid  = v("build_id");  if bid  ~= nil then cfg.build_id = bid end
  if tpl.toolchain_kind then
    local tcid = v("toolchain_id"); if tcid ~= nil then cfg.toolchain_id = tcid end
  end

  -- Common: description, notify_on_completion, before_launch.
  local desc = v("description"); if desc ~= nil then cfg.description = desc end
  local notify = v("notify_on_completion")
  if notify ~= nil then cfg.notify_on_completion = notify and true or false end
  local bl = v("before_launch")
  if bl ~= nil then
    local cleaned = {}
    for _, row in ipairs(bl) do
      local t = (row.target or ""):gsub("^%s+", ""):gsub("%s+$", "")
      if t ~= "" then
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

  -- Template-specific fields.
  for k, _ in pairs(tpl.new_defaults()) do
    if k ~= "name" then
      local cv = v(k)
      if cv ~= nil then cfg[k] = cv end
    end
  end

  -- Propagate config_type (used by runtime) + regenerate command.
  cfg.config_type = tpl.config_type
  cfg.command     = tpl.build_command(cfg)
  return cfg
end

-- Fresh config from a template.
function M.new_config(template_id)
  local tpl = M.run_get(template_id)
  if not tpl then return nil end
  local id = "rcfg_" .. tostring(math.floor((os.time() % 1000000) * 1000)) ..
             "_" .. tostring(math.random(1000, 9999))
  local cfg = {
    id           = id,
    template_id  = template_id,
    config_type  = tpl.config_type,
    toolchain_id = "",
    cwd          = "",
    env          = {},
    build_id     = "",
  }
  for k, v in pairs(common_defaults())  do cfg[k] = v end
  for k, v in pairs(tpl.new_defaults()) do cfg[k] = v end
  cfg.command = tpl.build_command(cfg)
  return cfg
end

return M
