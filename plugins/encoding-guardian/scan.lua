-- scan.lua — walk the active repo and inspect every candidate file.
--
-- The walker is a single pass over the file tree that filters in memory:
-- one `arbor.fs.list` per directory instead of one `arbor.fs.glob` per
-- pattern. Big repos with many include patterns make the difference.

local settings = require("settings")
local inspect  = require("inspect")

local M = {}

-- ── Glob match ─────────────────────────────────────────────────────────────
--
-- We don't use `arbor.fs.glob` here because the walker has already paid
-- the directory listing cost; we just need to match a single relative
-- path against a small list of patterns.

local function glob_to_lua_pattern(glob)
  return glob
    :gsub("([%(%)%.%%%+%-%[%]%^%$])", "%%%1")
    :gsub("%*", ".-")
    :gsub("%?", ".")
end

local function path_matches_any(rel_path, globs)
  if not globs or #globs == 0 then return false end
  local basename = rel_path:match("([^/\\]+)$") or rel_path
  for _, glob in ipairs(globs) do
    local pat = glob_to_lua_pattern(glob)
    if basename:match("^" .. pat .. "$") or rel_path:match("^" .. pat .. "$") then
      return true
    end
  end
  return false
end

local function is_excluded_dir(name)
  for _, d in ipairs(settings.DEFAULT_EXCLUDE_DIRS) do
    if d == name then return true end
  end
  return false
end

-- ── Walk ───────────────────────────────────────────────────────────────────

-- Recursive depth-limited walk. `out` is appended to in place; we stop as
-- soon as `cfg.max_files` is reached so a huge repo doesn't hang the UI.
local function walk(abs, rel, depth, cfg, out)
  if depth > 16            then return end
  if #out >= cfg.max_files then return end
  local entries = arbor.fs.list(abs)
  if not entries then return end
  for _, entry in ipairs(entries) do
    local sub_rel = rel == "" and entry.name or (rel .. "/" .. entry.name)
    if entry.is_dir then
      if not is_excluded_dir(entry.name) then
        walk(arbor.fs.join(abs, entry.name), sub_rel, depth + 1, cfg, out)
      end
    elseif path_matches_any(sub_rel, cfg.include_globs)
       and not path_matches_any(sub_rel, cfg.exclude_globs) then
      out[#out + 1] = { rel = sub_rel, abs = arbor.fs.join(abs, entry.name) }
      if #out >= cfg.max_files then return end
    end
  end
end

local function collect_files(repo_root, cfg)
  local out = {}
  walk(repo_root, "", 0, cfg, out)
  return out
end

-- ── Staged-files source ────────────────────────────────────────────────────
--
-- Pre-commit calls into `arbor.repo.staged_files()` instead of walking the
-- whole working tree: that's the EXACT set of files about to enter the next
-- commit. Deletions are skipped (nothing to read) and entries are filtered
-- through the same include/exclude globs as a full scan so a noisy commit
-- of vendored data doesn't blow up the veto message.

local function staged_candidates(repo_root, cfg)
  local files, err = arbor.repo.staged_files()
  if not files then return nil, err end
  local out = {}
  for _, file in ipairs(files) do
    if file.status ~= "deleted"
       and path_matches_any(file.path, cfg.include_globs)
       and not path_matches_any(file.path, cfg.exclude_globs) then
      out[#out + 1] = { rel = file.path, abs = arbor.fs.join(repo_root, file.path) }
    end
  end
  return out, nil
end

-- ── Public ─────────────────────────────────────────────────────────────────

local function inspect_each(files, cfg)
  local hits = {}
  for _, file in ipairs(files) do
    local hit = inspect.inspect_file(file.rel, file.abs, cfg)
    if hit then hits[#hits + 1] = hit end
  end
  return hits
end

-- Scan the entire working tree (manual scan / fix flow). Returns
--   `(result, nil)` on success — `result = { scanned, hits, truncated }`,
--   `(nil, err)`    when no repo is open.
function M.run()
  local repo = arbor.repo.current()
  if not repo then return nil, "no active repository" end
  local cfg   = settings.scan_config()
  local files = collect_files(repo, cfg)
  return {
    scanned   = #files,
    hits      = inspect_each(files, cfg),
    truncated = #files >= cfg.max_files,
  }, nil
end

-- Scan only the staged files (canonical pre-commit caller). Returns the
-- same shape as `run()`. `truncated` is always false — the index can't
-- realistically blow past the safety cap.
function M.run_staged()
  local repo = arbor.repo.current()
  if not repo then return nil, "no active repository" end
  local cfg          = settings.scan_config()
  local files, err   = staged_candidates(repo, cfg)
  if not files then return nil, err end
  return {
    scanned   = #files,
    hits      = inspect_each(files, cfg),
    truncated = false,
  }, nil
end

return M
