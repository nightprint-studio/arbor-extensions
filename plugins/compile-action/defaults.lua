-- defaults.lua — seed default build configs per detected project type.
-- Emits configs in the NEW templated format (see config/templates.lua).

local detect    = require("detect")
local templates = require("config.templates")

local M = {}

-- Create a new config from a template id and override specific fields.
local function make(template_id, overrides)
  local cfg = templates.new_config(template_id)
  if not cfg then return nil end
  for k, v in pairs(overrides or {}) do cfg[k] = v end
  cfg.command = templates.full_command(cfg)
  return cfg
end

local function push(list, cfg) if cfg then list[#list+1] = cfg end end

function M.for_type(proj_type, repo_path)
  local out = {}

  if proj_type == "maven" then
    push(out, make("maven", { name = "compile",          goals = "compile" }))
    push(out, make("maven", { name = "test",             goals = "test"    }))
    push(out, make("maven", { name = "package",          goals = "clean package" }))
    push(out, make("maven", { name = "package (prod)",   goals = "clean package", profiles = "prod" }))
    push(out, make("maven", { name = "package (no tests)", goals = "clean package", skip_tests = true }))

  elseif proj_type == "gradle" then
    push(out, make("gradle", { name = "build",       tasks = "build" }))
    push(out, make("gradle", { name = "test",        tasks = "test"  }))
    push(out, make("gradle", { name = "clean build", tasks = "clean build" }))

  elseif proj_type == "rust" or proj_type == "tauri" then
    push(out, make("cargo", { name = "build",           subcommand = "build"  }))
    push(out, make("cargo", { name = "build (release)", subcommand = "build",  release = true }))
    push(out, make("cargo", { name = "check",           subcommand = "check"  }))
    push(out, make("cargo", { name = "test",            subcommand = "test"   }))
    push(out, make("cargo", { name = "clippy",          subcommand = "clippy" }))
    -- Tauri frontend side (if applicable): use npm template for run dev/build.
    if proj_type == "tauri" then
      local pm = detect.detect_npm_pm(repo_path)
      push(out, make("npm", { name = "frontend dev",   package_manager = pm, script = "dev"   }))
      push(out, make("npm", { name = "frontend build", package_manager = pm, script = "build" }))
    end

  elseif proj_type == "npm" then
    local pm = detect.detect_npm_pm(repo_path)
    push(out, make("npm", { name = "build",   package_manager = pm, script = "build" }))
    push(out, make("npm", { name = "test",    package_manager = pm, script = "test"  }))
    push(out, make("npm", { name = "dev",     package_manager = pm, script = "dev"   }))

  elseif proj_type == "make" then
    push(out, make("make", { name = "all",   target = "all"   }))
    push(out, make("make", { name = "clean", target = "clean" }))
    push(out, make("make", { name = "test",  target = "test"  }))

  elseif proj_type == "go" then
    -- No dedicated Go template yet → fall through to Make-style raw command
    -- placeholder. Users can add custom Makefile entries as needed.
    push(out, make("make", { name = "go build", target = "build" }))
  end

  -- Apply default cwd for all entries.
  for _, c in ipairs(out) do
    if (c.cwd or "") == "" then c.cwd = repo_path or "" end
  end
  return out
end

return M
