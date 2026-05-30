-- settings.lua — typed accessors over arbor.settings.global / .project.
--
-- The plugin reads the same keys from many places; centralising the
-- defaults + coercions here keeps the call sites short and prevents
-- "is it a string or a number?" surprises from the JSON-backed store.

local M = {}

M.DEFAULT_MAX_FILES = 5000

M.DEFAULT_INCLUDE_GLOBS = {
  "*.svelte", "*.ts", "*.tsx", "*.js", "*.jsx", "*.css", "*.scss",
  "*.rs", "*.lua", "*.toml", "*.json", "*.md", "*.html", "*.svg",
  "*.txt", "*.yaml", "*.yml", "*.go", "*.py", "*.java", "*.cs", "*.cpp", "*.h",
}

-- Directories the scan never descends into. Build / dependency caches
-- never carry source files the developer authored — including them just
-- inflates scan time and false positives from vendored minified code.
M.DEFAULT_EXCLUDE_DIRS = {
  ".git", "node_modules", "target", "dist", "build", ".next",
  ".svelte-kit", "out", ".gradle", ".idea", ".vscode",
}

-- ── Project scope ──────────────────────────────────────────────────────────

function M.project_get(key, fallback)
  local v = arbor.settings.project.get(key)
  if v == nil then return fallback end
  return v
end

function M.project_set(key, value)
  arbor.settings.project.set(key, value)
end

function M.project_bool(key, default)
  local v = arbor.settings.project.get(key)
  if v == nil then return default end
  return v and true or false
end

function M.project_number(key, default)
  local v = arbor.settings.project.get(key)
  if type(v) == "number" then return v end
  if type(v) == "string" then return tonumber(v) or default end
  return default
end

function M.project_list(key, default)
  local v = arbor.settings.project.get(key)
  if type(v) == "table" then return v end
  return default
end

-- ── Global scope ───────────────────────────────────────────────────────────

function M.global_get(key, fallback)
  local v = arbor.settings.global.get(key)
  if v == nil then return fallback end
  return v
end

function M.global_set(key, value)
  arbor.settings.global.set(key, value)
end

function M.global_bool(key, default)
  local v = arbor.settings.global.get(key)
  if v == nil then return default end
  return v and true or false
end

-- ── Composite ──────────────────────────────────────────────────────────────

-- Build the effective scan config from per-project settings, falling back
-- to global defaults. Returned table is plain data — pass it around and
-- treat it as immutable.
function M.scan_config()
  return {
    default_charset = M.project_get("default_charset", "utf-8"),
    default_eol     = M.project_get("default_eol",     "any"),
    include_globs   = M.project_list("include_globs",  M.DEFAULT_INCLUDE_GLOBS),
    exclude_globs   = M.project_list("exclude_globs",  {}),
    block_mojibake  = M.project_bool("block_mojibake", true),
    block_charset   = M.project_bool("block_charset",  true),
    block_bom       = M.project_bool("block_bom",      false),
    block_eol       = M.project_bool("block_eol",      false),
    max_files       = M.project_number("max_files",
                          M.global_get("max_files", M.DEFAULT_MAX_FILES)),
  }
end

function M.precommit_enabled_for_project()
  if M.global_bool("enabled", true) == false then return false end
  return M.project_bool("enabled", false)
end

return M
