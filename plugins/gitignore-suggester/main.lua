-- gitignore-suggester / main.lua
--
-- On every repo open / tab switch, scan the working tree for untracked
-- files matching well-known build output / IDE / OS-junk patterns and
-- propose adding them to .gitignore. The user picks which to apply via
-- a checklist modal; the plugin appends the chosen entries to the file.
--
-- Per-repo settings keep dismissed patterns out of future scans so the
-- notification doesn't keep nagging once the user has consciously
-- decided to track those paths.

-- ─────────────────────────────────────────────────────────────────────────
-- Pattern catalog
-- ─────────────────────────────────────────────────────────────────────────
-- Each entry: { gitignore line, label, match(path) function }.
-- Order matters only for display: most-common ecosystems first.
local function starts_with(prefix)
  return function(p) return p == prefix or p:sub(1, #prefix + 1) == (prefix .. "/") end
end
local function dir_anywhere(name)
  -- Matches the directory at any depth: "foo/bar/<name>/baz" or "<name>/x".
  return function(p) return p:find("/" .. name .. "/", 1, true)
                       or p:sub(1, #name + 1) == (name .. "/") end
end
local function ext(suffix)
  return function(p) return p:sub(-#suffix) == suffix end
end
local function basename_eq(name)
  return function(p)
    local b = p:match("([^/]+)$") or p
    return b == name
  end
end
local function basename_prefix(prefix)
  return function(p)
    local b = p:match("([^/]+)$") or p
    return b:sub(1, #prefix) == prefix
  end
end

local PATTERNS = {
  -- Build outputs
  { line = "target/",        label = "Rust build output",        match = starts_with("target") },
  { line = "node_modules/",  label = "Node dependencies",        match = dir_anywhere("node_modules") },
  { line = "dist/",          label = "Generic dist output",      match = starts_with("dist") },
  { line = "build/",         label = "Generic build output",     match = starts_with("build") },
  { line = "out/",           label = "Generic output dir",       match = starts_with("out") },
  { line = ".next/",         label = "Next.js build cache",      match = starts_with(".next") },
  { line = ".nuxt/",         label = "Nuxt build cache",         match = starts_with(".nuxt") },
  { line = ".svelte-kit/",   label = "SvelteKit build cache",    match = starts_with(".svelte-kit") },
  { line = ".turbo/",        label = "Turborepo cache",          match = starts_with(".turbo") },
  { line = ".gradle/",       label = "Gradle cache",             match = starts_with(".gradle") },
  { line = ".mvn/",          label = "Maven wrapper cache",      match = starts_with(".mvn") },
  { line = "bin/",           label = ".NET / Java bin/",         match = dir_anywhere("bin") },
  { line = "obj/",           label = ".NET obj/",                match = dir_anywhere("obj") },
  { line = "__pycache__/",   label = "Python bytecode",          match = dir_anywhere("__pycache__") },
  { line = "*.pyc",          label = "Python compiled",          match = ext(".pyc") },
  { line = ".venv/",         label = "Python virtualenv",        match = starts_with(".venv") },
  { line = "venv/",          label = "Python virtualenv",        match = starts_with("venv") },

  -- IDE / editor
  { line = ".vscode/",       label = "VS Code settings",         match = starts_with(".vscode") },
  { line = ".idea/",         label = "JetBrains IDE settings",   match = starts_with(".idea") },
  { line = "*.iml",          label = "IntelliJ module files",    match = ext(".iml") },
  { line = ".vs/",           label = "Visual Studio settings",   match = starts_with(".vs") },

  -- OS junk
  { line = ".DS_Store",      label = "macOS Finder metadata",    match = basename_eq(".DS_Store") },
  { line = "Thumbs.db",      label = "Windows thumbnail cache",  match = basename_eq("Thumbs.db") },
  { line = "desktop.ini",    label = "Windows folder config",    match = basename_eq("desktop.ini") },

  -- Logs / temp
  { line = "*.log",          label = "Log files",                match = ext(".log") },
  { line = "*.swp",          label = "Vim swap files",           match = ext(".swp") },
  { line = "*.swo",          label = "Vim swap files",           match = ext(".swo") },
  { line = "*.bak",          label = "Backup files",             match = ext(".bak") },

  -- Secrets (env files — chosen, not blanket *.env to avoid noise)
  { line = ".env",           label = ".env file (likely secrets!)", match = basename_eq(".env") },
  { line = ".env.local",     label = ".env.local",                  match = basename_eq(".env.local") },
  { line = ".env.*.local",   label = ".env.{stage}.local",          match = basename_prefix(".env.") },
}

-- ─────────────────────────────────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────────────────────────────────

-- Read .gitignore lines (trimmed, ignoring blanks & comments) so we don't
-- re-suggest entries the user already has. We compare verbatim against the
-- catalog `line` field — sufficient since users typically copy-paste these
-- canonical forms; we don't try to be a full gitignore parser.
local function load_existing_lines()
  local repo = arbor.repo.current()
  if not repo or repo == "" then return {} end
  local path = repo .. "/.gitignore"
  if not arbor.fs.exists(path) then return {} end
  local text = arbor.fs.read(path) or ""
  local set = {}
  for line in text:gmatch("[^\r\n]+") do
    local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
      set[trimmed] = true
    end
  end
  return set
end

local function load_dismissed()
  local raw = arbor.settings.project.get("dismissed") or ""
  if raw == "" then return {} end
  local set = {}
  for entry in raw:gmatch("([^,]+)") do
    local trimmed = entry:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed ~= "" then set[trimmed] = true end
  end
  return set
end

local function save_dismissed(set)
  local list = {}
  for k in pairs(set) do list[#list + 1] = k end
  table.sort(list)
  arbor.settings.project.set("dismissed", table.concat(list, ","))
end

-- For each catalog entry, list up to 3 example untracked paths matching it.
-- The modal shows examples so the user understands WHY a suggestion was made.
local function scan(untracked)
  local existing  = load_existing_lines()
  local dismissed = load_dismissed()
  local results = {}
  for _, pat in ipairs(PATTERNS) do
    if not existing[pat.line] and not dismissed[pat.line] then
      local examples = {}
      for _, p in ipairs(untracked) do
        if pat.match(p) then
          examples[#examples + 1] = p
          if #examples >= 3 then break end
        end
      end
      if #examples > 0 then
        results[#results + 1] = {
          line     = pat.line,
          label    = pat.label,
          examples = examples,
        }
      end
    end
  end
  return results
end

-- ─────────────────────────────────────────────────────────────────────────
-- Background scan (silent unless suggestions are found)
-- ─────────────────────────────────────────────────────────────────────────

local function silent_scan()
  local untracked, err = arbor.repo.untracked()
  if err or not untracked or #untracked == 0 then return end
  local suggestions = scan(untracked)
  if #suggestions == 0 then return end

  arbor.notify{
    title   = "Gitignore suggestions",
    message = string.format("%d ignorable item(s) found in this repo.", #suggestions),
    level   = "info",
    persist = false, -- transient toast only; user opens the modal to act
    action  = {
      kind   = "plugin-action",
      label  = "Review",
      plugin = "gitignore-suggester",
      action = "gitignore-suggester:open_modal",
    },
  }
end

-- ─────────────────────────────────────────────────────────────────────────
-- Modal
-- ─────────────────────────────────────────────────────────────────────────

local function open_modal()
  local untracked, err = arbor.repo.untracked()
  if err then
    arbor.notify{ message = "Could not read untracked files: " .. err, level = "error" }
    return
  end
  local suggestions = scan(untracked or {})
  if #suggestions == 0 then
    arbor.notify{ message = "No new gitignore suggestions for this repo.", level = "info" }
    return
  end

  local nodes = {
    { type = "label", text = string.format(
        "Found %d entry pattern(s) matching untracked files. Pick what to add to .gitignore.",
        #suggestions) },
  }
  for _, s in ipairs(suggestions) do
    -- Field name = "p::" + line so we can recover it on submit.
    -- Two-line label keeps the canonical pattern visually distinct from
    -- the human-readable description and the example paths.
    local examples_str = table.concat(s.examples, ", ")
    if #s.examples == 3 then examples_str = examples_str .. ", …" end
    nodes[#nodes + 1] = {
      type    = "checkbox",
      name    = "p::" .. s.line,
      label   = string.format("%s   —   %s\n    e.g. %s", s.line, s.label, examples_str),
      default = true,
    }
  end

  arbor.ui.form({
    title         = "Gitignore Suggestions",
    width         = "640px",
    height        = "560px",
    submit_label  = "Append to .gitignore",
    submit_action = "gitignore-suggester:apply",
    nodes         = nodes,
  })
end

-- ─────────────────────────────────────────────────────────────────────────
-- Apply / dismiss
-- ─────────────────────────────────────────────────────────────────────────

local function append_to_gitignore(lines_to_add)
  local repo = arbor.repo.current()
  if not repo or repo == "" then return false, "no active repo" end
  local path = repo .. "/.gitignore"

  -- Compute a leading newline IFF the existing file is non-empty AND its
  -- last byte is not already \n. Without this guard a freshly-created
  -- file would start with a blank line, and a file already ending in \n
  -- would gain a spurious blank line before the comment header.
  local leading = ""
  if arbor.fs.exists(path) then
    local existing = arbor.fs.read(path) or ""
    if existing == "" then
      leading = ""
    elseif existing:sub(-1) ~= "\n" then
      leading = "\n\n"
    else
      leading = "\n"
    end
  end

  local block = leading
              .. "# Added by gitignore-suggester\n"
              .. table.concat(lines_to_add, "\n") .. "\n"

  local ok, werr = arbor.fs.append(path, block)
  if not ok then return false, werr or "fs.append failed" end
  return true, nil
end

arbor.events.on("gitignore-suggester:apply", function(ctx)
  local accepted, dismissed = {}, {}
  for k, v in pairs(ctx or {}) do
    if type(k) == "string" and k:sub(1, 3) == "p::" then
      local line = k:sub(4)
      if v then
        accepted[#accepted + 1] = line
      else
        dismissed[#dismissed + 1] = line
      end
    end
  end

  -- Persist dismissed entries so the next scan doesn't re-suggest them.
  -- We do NOT persist accepted ones — adding them to .gitignore is enough,
  -- the next scan will skip them via load_existing_lines().
  if #dismissed > 0 then
    local set = load_dismissed()
    for _, l in ipairs(dismissed) do set[l] = true end
    save_dismissed(set)
  end

  if #accepted == 0 then
    arbor.notify{ message = "No entries selected; preferences saved.", level = "info" }
    return
  end

  local ok, err = append_to_gitignore(accepted)
  if not ok then
    arbor.notify{ title = "Gitignore update failed", message = err or "?", level = "error" }
    return
  end
  arbor.notify{
    title   = "Gitignore updated",
    message = string.format("Added %d entr%s to .gitignore.",
      #accepted, #accepted == 1 and "y" or "ies"),
    level   = "success",
  }
end)

-- ─────────────────────────────────────────────────────────────────────────
-- Wiring
-- ─────────────────────────────────────────────────────────────────────────

arbor.events.on("on_plugin_load", function(_ctx)
  arbor.command.register({
    id          = "open_modal",
    title       = "Suggest .gitignore entries",
    description = "Scan untracked files and propose common ignore patterns.",
    -- EyeOff fits the semantics: .gitignore is what git "stops looking at".
    icon        = "EyeOff",
    group       = "Gitignore",
  })
  arbor.command.register({
    id          = "reset_dismissed",
    title       = "Reset dismissed gitignore suggestions",
    description = "Re-enable patterns previously skipped in this repo.",
    -- Undo2 reads as "undo my earlier dismissals" — clearer than a generic
    -- refresh arrow which usually means "re-fetch".
    icon        = "Undo2",
    group       = "Gitignore",
  })
  arbor.log.info("gitignore-suggester ready")
end)

-- Command palette dispatches `command:<id>` per plugin (see CommandPalette.svelte).
arbor.events.on("command:open_modal",       function(_) open_modal() end)
arbor.events.on("command:reset_dismissed",  function(_)
  arbor.settings.project.set("dismissed", "")
  open_modal()
end)
-- Notification action uses the explicit "<plugin>:open_modal" form (see
-- silent_scan); kept separate so the notification keeps working even if
-- the user removes the palette command in a future iteration.
arbor.events.on("gitignore-suggester:open_modal", function(_) open_modal() end)

arbor.events.on("on_repo_open",  function(_ctx) silent_scan() end)
arbor.events.on("on_tab_switch", function(_ctx) silent_scan() end)
