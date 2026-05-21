-- detect.lua — project-type auto-detection (kept in sync with compile-action).
-- Duplicated here so run-action can pick sensible run-config defaults without
-- a cross-plugin service call (settings are per-plugin so we can't read
-- compile-action's `detected_type` directly).

local M = {}

local MARKERS = {
  { file = "pom.xml",                      type = "maven"  },
  { file = "build.gradle.kts",             type = "gradle" },
  { file = "build.gradle",                 type = "gradle" },
  { file = "src-tauri/tauri.conf.json",    type = "tauri"  },
  { file = "src-tauri/tauri.conf.json5",   type = "tauri"  },
  { file = "package.json",                 type = "npm"    },
  { file = "Cargo.toml",                   type = "rust"   },
  { file = "go.mod",                       type = "go"     },
  { file = "Makefile",                     type = "make"   },
}

function M.detect(repo_path)
  if not repo_path or repo_path == "" then return nil end
  for _, m in ipairs(MARKERS) do
    local path = arbor.fs.join(repo_path, m.file)
    if arbor.fs.is_file(path) then return m.type end
  end
  return nil
end

function M.detect_npm_pm(repo_path)
  if arbor.fs.is_file(arbor.fs.join(repo_path, "yarn.lock"))       then return "yarn"  end
  if arbor.fs.is_file(arbor.fs.join(repo_path, "pnpm-lock.yaml"))  then return "pnpm"  end
  if arbor.fs.is_file(arbor.fs.join(repo_path, "bun.lockb"))       then return "bun"   end
  return "npm"
end

return M
