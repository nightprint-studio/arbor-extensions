-- run_defaults.lua — seed default run configs per detected project type.
-- Emits configs in the NEW templated format (see config/run_templates.lua).

local detect    = require("detect")
local templates = require("config.run_templates")

local M = {}

local function make(template_id, overrides)
  local cfg = templates.new_config(template_id)
  if not cfg then return nil end
  for k, v in pairs(overrides or {}) do cfg[k] = v end
  local tpl = templates.run_get(template_id)
  if tpl then cfg.command = tpl.build_command(cfg) end
  return cfg
end

local function push(list, cfg) if cfg then list[#list+1] = cfg end end

function M.for_type(proj_type, repo_path)
  local out = {}

  if proj_type == "maven" then
    push(out, make("spring", { name = "Spring Boot · run",          tool = "maven" }))
    push(out, make("spring", { name = "Spring Boot · dev profile",  tool = "maven", active_profile = "dev"  }))
    push(out, make("spring", { name = "Spring Boot · prod profile", tool = "maven", active_profile = "prod" }))
    push(out, make("simple_java", { name = "Plain JAR" }))

  elseif proj_type == "gradle" then
    push(out, make("spring", { name = "Spring Boot · run",         tool = "gradle" }))
    push(out, make("spring", { name = "Spring Boot · dev profile", tool = "gradle", active_profile = "dev" }))

  elseif proj_type == "rust" then
    push(out, make("cargo", { name = "Cargo · run"                    }))
    push(out, make("cargo", { name = "Cargo · run (release)", release = true }))

  elseif proj_type == "tauri" then
    push(out, make("cargo", { name = "Cargo · tauri dev", args = "tauri dev" }))
    local pm = detect.detect_npm_pm(repo_path)
    push(out, make("npm",   { name = "Frontend · dev",  package_manager = pm, script = "dev"   }))

  elseif proj_type == "npm" then
    local pm = detect.detect_npm_pm(repo_path)
    push(out, make("npm", { name = pm .. " · dev",   package_manager = pm, script = "dev"   }))
    push(out, make("npm", { name = pm .. " · start", package_manager = pm, script = "start" }))
  end

  for _, c in ipairs(out) do
    if (c.cwd or "") == "" then c.cwd = repo_path or "" end
  end
  return out
end

-- Infer config_type from a cfg (legacy helper, now reads template_id first).
function M.infer_type(cfg)
  if cfg.config_type and cfg.config_type ~= "" then return cfg.config_type end
  local tpl = templates.run_get(cfg.template_id or "")
  if tpl and tpl.config_type then return tpl.config_type end
  return "custom"
end

return M
