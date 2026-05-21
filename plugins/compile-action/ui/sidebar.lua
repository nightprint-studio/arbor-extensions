-- ui/sidebar.lua — IntelliJ-style "Build & Run" tree sidebar.
--
-- Owns:
--   · the registration of the kind="tree" sidebar in the right activity bar
--   · the contribution-point declarations consumed by run-action,
--     maven-update-deps, and any future plugin
--   · the toolbar contributions (Run last / Stop / Refresh / + / Settings) —
--     contributed *by compile-action itself* through the same API used by
--     external plugins (eats its own dog-food, validates the model)
--   · the per-toolchain tree builders (Maven, Cargo, npm, Gradle, Make)
--   · a built-in `dependency_provider` for each supported toolchain
--
-- Tree shape (rebuilt on every repo open / tab switch):
--
--   ── [section] Run configurations
--      ├─ [runnable] Build dev    (kind=runnable, default = compile:run cfg.id)
--      └─ …
--   ── [section] <toolchain>
--      ├─ [module] <project name>          (data = { template_id, repo_path })
--      │  ├─ [section] Lifecycle
--      │  │  ├─ [lifecycle_phase] clean   (data = { template_id, phase })
--      │  │  ├─ [lifecycle_phase] compile
--      │  │  └─ …
--      │  └─ [section] Profiles / Scripts / Targets / …  (toolchain-specific)
--      └─ …

local state    = require("state")
local detect   = require("detect")
local pcfg     = require("config.project")

local M = {}

local SIDEBAR_ID = "compile"
local PLUGIN     = "compile-action"
local NS         = PLUGIN .. ":" .. SIDEBAR_ID

-- ── Contribution-point names (the public API consumers extend) ───────────────
M.POINT = {
  toolbar             = NS .. ":toolbar",
  -- Top-level section injection. Each contribution payload carries `{ section
  -- = <TreeNode> }` and the frontend appends/merges them into the visible
  -- tree, ordered by `priority`. Used by run-action to inject its
  -- "Run configurations" section without compile-action knowing about run.
  tree_section        = NS .. ":tree.section",
  node_action         = NS .. ":node_action",
  node_decorator      = NS .. ":node_decorator",
  context_menu        = NS .. ":context_menu",
  dependency_provider = NS .. ":dependency_provider",
  footer              = NS .. ":footer",
}

-- ── Lifecycle phases / tasks per toolchain ───────────────────────────────────

local MAVEN_PHASES = {
  "clean", "validate", "compile", "test", "package",
  "verify", "install", "site", "deploy",
}

local GRADLE_TASKS = {
  "clean", "assemble", "build", "check", "test",
}

local CARGO_TASKS = {
  "check", "build", "test", "run", "doc", "clean", "update",
}

-- npm: scripts come from package.json; we read it on demand below.

-- ── Tree builders ────────────────────────────────────────────────────────────

local function repo_name(path)
  if not path or path == "" then return "(repo)" end
  local m = path:match("[/\\]([^/\\]+)[/\\]?$")
  return m or path
end

local function read_json_file(path)
  local content = arbor.fs.read(path)
  if not content or content == "" then return nil end
  local ok, parsed = pcall(arbor.json.decode, content)
  if not ok then return nil end
  return parsed
end

-- Build the runnable nodes for the saved BUILD configurations. (Run
-- configurations live in run-action and arrive through the `tree.section`
-- contribution slot, so they're injected separately.)
local function build_buildconfig_nodes(repo_path)
  local children = {}
  local ok, cfgs = pcall(pcfg.load)
  if not ok or type(cfgs) ~= "table" then cfgs = {} end
  local sel = ""
  pcall(function() sel = pcfg.load_selected() or "" end)
  -- Pick an icon per template so the row visually conveys what gets built.
  local TPL_ICON = {
    maven = "Hammer", gradle = "Hammer", cargo = "Box",
    npm   = "Package", make = "Wrench",
  }
  for _, c in ipairs(cfgs) do
    local id   = "buildcfg:" .. (c.id or "?")
    local icon = TPL_ICON[c.template_id or ""] or "Hammer"
    children[#children+1] = {
      id            = id,
      label         = c.name or c.label or c.id or "(unnamed)",
      icon          = icon,
      kind          = "build_config",
      selectable    = true,
      default_action = "compile:run",
      badge         = (c.id == sel) and "default" or nil,
      badge_kind    = (c.id == sel) and "accent" or nil,
      data          = {
        template_id = c.template_id or "",
        cfg_id      = c.id or "",
        repo_path   = repo_path,
      },
      children      = {},
    }
  end
  if #children == 0 then return nil end
  return {
    id        = "section:buildconfigs",
    label     = "Build configurations",
    icon      = "Hammer",
    kind      = "section",
    expanded  = true,
    selectable = false,
    data      = {},
    children  = children,
  }
end

local function lifecycle_section(template_id, mod_dir, phases, label)
  -- Per-module ids — without `mod_dir` in the suffix, multiple modules' tree
  -- nodes would collide and the Tree widget's `expandOverride` would drive
  -- every "Lifecycle" header at once when the user expands one of them.
  local children = {}
  for _, phase in ipairs(phases) do
    children[#children+1] = {
      id            = "phase:" .. template_id .. ":" .. mod_dir .. ":" .. phase,
      label         = phase,
      icon          = "CircleDashed",
      kind          = "lifecycle_phase",
      selectable    = true,
      default_action = "compile:run_phase",
      data = {
        template_id = template_id,
        phase       = phase,
        repo_path   = mod_dir,
      },
      children = {},
    }
  end
  return {
    id        = "section:lifecycle:" .. template_id .. ":" .. mod_dir,
    label     = label or "Lifecycle",
    icon      = "List",
    kind      = "section",
    expanded  = false,
    selectable = false,
    data      = {},
    children  = children,
  }
end

-- Regex-parse `<modules>…<module>NAME</module>…</modules>` from a pom file.
-- Returns an array of module names (folder names relative to the pom dir).
-- Multi-line and namespaced poms work because we only care about the inner
-- text; XML comments are stripped first so commented-out modules don't slip
-- in. Falls back to {} on read failure or malformed XML.
local function maven_modules(pom_path)
  local content = arbor.fs.read(pom_path)
  if not content or content == "" then return {} end
  -- Strip comments; cheap and good enough for vanilla poms.
  content = content:gsub("<!%-%-.-%-%->", "")
  local block = content:match("<modules>(.-)</modules>")
  if not block then return {} end
  local out = {}
  for raw in block:gmatch("<module>([^<]+)</module>") do
    local trimmed = raw:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed ~= "" then out[#out+1] = trimmed end
  end
  return out
end

-- Read `<artifactId>` from a pom (top-level only — child poms inherit). Used
-- as the display label when present; falls back to the folder name.
local function maven_artifact_id(pom_path)
  local content = arbor.fs.read(pom_path)
  if not content or content == "" then return nil end
  content = content:gsub("<!%-%-.-%-%->", "")
  -- The first <artifactId> outside <parent>/<dependency>/<plugin> is the
  -- project's own. We approximate by skipping the first occurrence inside a
  -- <parent> block.
  local without_parent = content:gsub("<parent>.-</parent>", "")
  return (without_parent:match("<artifactId>%s*([^<%s]+)%s*</artifactId>"))
end

local function build_maven_module_node(pom_path, repo_path, role, depth)
  -- Recursive: each pom may itself declare <modules>. Depth limit avoids
  -- cycles on hand-rolled poms (Maven enforces a DAG but we don't trust the
  -- input).
  if depth > 8 then return nil end
  local mod_dir   = pom_path:match("(.+)[/\\]pom%.xml$") or repo_path
  local label     = maven_artifact_id(pom_path) or repo_name(mod_dir)
  local children  = { lifecycle_section("maven", mod_dir, MAVEN_PHASES, "Lifecycle") }

  for _, sub in ipairs(maven_modules(pom_path)) do
    local sub_pom = arbor.fs.join(mod_dir, arbor.fs.join(sub, "pom.xml"))
    if arbor.fs.is_file(sub_pom) then
      local child_node = build_maven_module_node(sub_pom, repo_path, "child", depth + 1)
      if child_node then children[#children+1] = child_node end
    end
  end

  return {
    id        = "module:maven:" .. mod_dir,
    label     = label,
    icon      = (role == "parent") and "Package" or "Box",
    kind      = "module",
    expanded  = (role == "parent"),
    selectable = true,
    data      = {
      template_id = "maven",
      role        = role,
      pom_path    = pom_path,
      module_dir  = mod_dir,
      repo_path   = repo_path,
    },
    children  = children,
  }
end

local function build_maven_section(repo_path)
  local pom = arbor.fs.join(repo_path, "pom.xml")
  local root = build_maven_module_node(pom, repo_path, "parent", 0)
  return {
    id        = "section:toolchain:maven",
    label     = "Maven",
    icon      = "Hammer",
    kind      = "section",
    expanded  = true,
    selectable = false,
    data      = {},
    children  = root and { root } or {},
  }
end

local function build_gradle_section(repo_path)
  local module_node = {
    id        = "module:gradle:root",
    label     = repo_name(repo_path),
    icon      = "Package",
    kind      = "module",
    expanded  = true,
    selectable = true,
    data      = { template_id = "gradle", repo_path = repo_path },
    children  = {
      lifecycle_section("gradle", repo_path, GRADLE_TASKS, "Tasks"),
    },
  }
  return {
    id        = "section:toolchain:gradle",
    label     = "Gradle",
    icon      = "Hammer",
    kind      = "section",
    expanded  = true,
    selectable = false,
    data      = {},
    children  = { module_node },
  }
end

-- Expand a single workspace member entry into one or more concrete subdir
-- paths, relative to the workspace root. Handles three cases:
--   "crates/foo"     → { "crates/foo" }                      (literal)
--   "crates/*"       → { "crates/a", "crates/b", … }         (last-segment glob)
--   "crates/**/foo"  → falls back to literal — we don't support deep globs
-- Only directories that contain a Cargo.toml are kept, so non-crate folders
-- under `crates/` (like `target` or `.cache`) don't pollute the tree.
local function expand_member(repo_dir, entry)
  -- Fast path: no glob char anywhere → keep as-is.
  if not entry:find("[%*%?%[]") then return { entry } end

  -- Only support globs of the form "<prefix>/*" (a single `*` as the last
  -- segment). That covers the vast majority of real-world cases — globs
  -- like "crates/**" or "**/foo" need a recursive walker we don't ship yet.
  local prefix = entry:match("^(.-)/%*$")
  if not prefix then return {} end

  local base    = arbor.fs.join(repo_dir, prefix)
  local entries = nil
  pcall(function() entries = arbor.fs.list(base) end)
  if type(entries) ~= "table" then return {} end

  local out = {}
  for _, e in ipairs(entries) do
    if e.is_dir and arbor.fs.is_file(arbor.fs.join(base, arbor.fs.join(e.name, "Cargo.toml"))) then
      out[#out + 1] = prefix .. "/" .. e.name
    end
  end
  table.sort(out)
  return out
end

-- Carve out the body of a top-level TOML section, given the section's
-- header name (e.g. "workspace"). The body runs from just after the header
-- line to the start of the next top-level section header (a newline + `[`
-- followed by an identifier char) or end-of-file. Returns nil if the
-- section isn't present.
--
-- The earlier implementation used `[^%[]*` to bound the section, which
-- truncated at the FIRST `[` it found — including the one inside
-- `members = [...]`. As a result `members` was never visible to the
-- subsequent regex and Cargo workspaces showed only their root crate.
local function toml_section_body(content, name)
  local pat = "%[" .. name .. "%]"
  local s = content:find("\n" .. pat) or content:find("^" .. pat)
  if not s then return nil end
  -- Skip past the header line itself.
  local body_start = content:find("\n", s + 1) or (s + #name + 2)
  -- Next top-level section header: `\n[<identifier>` (letter, _, dot).
  -- Array literals on their own line look like `\n["…"` — the char after
  -- `[` is `"`, not an identifier — so they don't match. Inline-table
  -- literals `\n{…}` also don't match.
  local body_end = content:find("\n%[[%a_]", body_start) or (#content + 1)
  return content:sub(body_start, body_end - 1)
end

-- Extract `members = ["a", "b"]` entries from a Cargo.toml's
-- `[workspace]` section, expanding any "<prefix>/*" globs to concrete
-- subdirs that contain a Cargo.toml.
local function cargo_workspace_members(cargo_path)
  local content = arbor.fs.read(cargo_path)
  if not content or content == "" then return {} end
  local ws_body = toml_section_body(content, "workspace")
  if not ws_body then return {} end
  local list_block = ws_body:match("members%s*=%s*%[(.-)%]")
  if not list_block then return {} end
  local repo_dir = cargo_path:match("(.+)[/\\]Cargo%.toml$") or ""
  local out = {}
  for entry in list_block:gmatch("\"([^\"]+)\"") do
    for _, expanded in ipairs(expand_member(repo_dir, entry)) do
      out[#out + 1] = expanded
    end
  end
  return out
end

-- Read the package name from a Cargo.toml's `[package]` section. Uses the
-- same TOML section extractor as `cargo_workspace_members` so a `keywords =
-- ["a", "b"]` or any other array-valued key in `[package]` doesn't hide
-- the `name` field from the regex.
local function cargo_package_name(cargo_path)
  local content = arbor.fs.read(cargo_path)
  if not content or content == "" then return nil end
  local body = toml_section_body(content, "package")
  if not body then return nil end
  return body:match("name%s*=%s*\"([^\"]+)\"")
end

local function build_cargo_module_node(cargo_path, repo_path, depth)
  if depth > 8 then return nil end
  local mod_dir = cargo_path:match("(.+)[/\\]Cargo%.toml$") or repo_path
  local label   = cargo_package_name(cargo_path) or repo_name(mod_dir)
  local children = { lifecycle_section("cargo", mod_dir, CARGO_TASKS, "Tasks") }
  for _, member in ipairs(cargo_workspace_members(cargo_path)) do
    local sub = arbor.fs.join(mod_dir, arbor.fs.join(member, "Cargo.toml"))
    if arbor.fs.is_file(sub) then
      local child = build_cargo_module_node(sub, repo_path, depth + 1)
      if child then children[#children+1] = child end
    end
  end
  return {
    id        = "module:cargo:" .. mod_dir,
    label     = label,
    icon      = (depth == 0) and "Package" or "Box",
    kind      = "module",
    expanded  = (depth == 0),
    selectable = true,
    data      = {
      template_id = "cargo",
      cargo_path  = cargo_path,
      module_dir  = mod_dir,
      repo_path   = repo_path,
    },
    children  = children,
  }
end

local function build_cargo_section(repo_path)
  local cargo_path = arbor.fs.join(repo_path, "Cargo.toml")
  local root = build_cargo_module_node(cargo_path, repo_path, 0)
  return {
    id        = "section:toolchain:cargo",
    label     = "Cargo",
    icon      = "Box",
    kind      = "section",
    expanded  = true,
    selectable = false,
    data      = {},
    children  = root and { root } or {},
  }
end

-- Build a "Scripts" section listing the package.json scripts in alphabetical
-- order. Returns nil when the package.json has no scripts so callers can
-- skip it cleanly.
local function npm_scripts_section(scripts, mod_dir, pm)
  if type(scripts) ~= "table" then return nil end
  local children = {}
  for name, _cmd in pairs(scripts) do
    children[#children+1] = {
      id            = "phase:npm:" .. mod_dir .. ":" .. name,
      label         = name,
      icon          = "Play",
      kind          = "lifecycle_phase",
      selectable    = true,
      default_action = "compile:run_phase",
      data = { template_id = "npm", phase = name, repo_path = mod_dir, pm = pm },
      children = {},
    }
  end
  if #children == 0 then return nil end
  table.sort(children, function(a, b) return a.label < b.label end)
  return {
    id        = "section:npm:scripts:" .. mod_dir,
    label     = "Scripts",
    icon      = "List",
    kind      = "section",
    expanded  = (mod_dir == arbor.fs.join(mod_dir, "")), -- root: collapsed otherwise
    selectable = false,
    data      = {},
    children  = children,
  }
end

-- Read `workspaces` from a package.json. Accepts both the array shorthand
-- and the `{ packages: […] }` long form. Glob entries skipped for v1.
local function npm_workspaces(pkg)
  if not pkg or type(pkg) ~= "table" then return {} end
  local ws = pkg.workspaces
  if not ws then return {} end
  local list = (type(ws) == "table" and ws.packages) or ws
  if type(list) ~= "table" then return {} end
  local out = {}
  for _, entry in ipairs(list) do
    if type(entry) == "string" and not entry:find("[%*%?%[]") then
      out[#out+1] = entry
    end
  end
  return out
end

local function build_npm_module_node(pkg_path, mod_dir, repo_path, pm, depth)
  if depth > 6 then return nil end
  local pkg = read_json_file(pkg_path)
  local children = {}
  local scripts_section = npm_scripts_section(pkg and pkg.scripts, mod_dir, pm)
  if scripts_section then children[#children+1] = scripts_section end
  for _, ws in ipairs(npm_workspaces(pkg)) do
    local sub_dir = arbor.fs.join(mod_dir, ws)
    local sub_pkg = arbor.fs.join(sub_dir, "package.json")
    if arbor.fs.is_file(sub_pkg) then
      local child = build_npm_module_node(sub_pkg, sub_dir, repo_path, pm, depth + 1)
      if child then children[#children+1] = child end
    end
  end
  return {
    id        = "module:npm:" .. mod_dir,
    label     = (pkg and pkg.name) or repo_name(mod_dir),
    icon      = (depth == 0) and "Package" or "Box",
    kind      = "module",
    expanded  = (depth == 0),
    selectable = true,
    data      = { template_id = "npm", repo_path = repo_path, module_dir = mod_dir, pm = pm },
    children  = children,
  }
end

local function build_npm_section(repo_path)
  local pm = detect.detect_npm_pm(repo_path)
  local pkg_path = arbor.fs.join(repo_path, "package.json")
  local root = build_npm_module_node(pkg_path, repo_path, repo_path, pm, 0)
  return {
    id        = "section:toolchain:npm",
    label     = "npm (" .. pm .. ")",
    icon      = "Package",
    kind      = "section",
    expanded  = true,
    selectable = false,
    data      = {},
    children  = root and { root } or {},
  }
end

local function build_make_section(repo_path)
  return {
    id        = "section:toolchain:make",
    label     = "Make",
    icon      = "Wrench",
    kind      = "section",
    expanded  = true,
    selectable = false,
    data      = {},
    children  = {
      {
        id        = "module:make:root",
        label     = repo_name(repo_path),
        icon      = "Wrench",
        kind      = "module",
        expanded  = true,
        selectable = true,
        data      = { template_id = "make", repo_path = repo_path },
        children  = {},
      },
    },
  }
end

local TOOLCHAIN_BUILDER = {
  maven  = build_maven_section,
  gradle = build_gradle_section,
  rust   = build_cargo_section,
  npm    = build_npm_section,
  tauri  = build_npm_section,   -- Tauri projects share the npm scripts surface.
  make   = build_make_section,
}

-- ── Manual modules ───────────────────────────────────────────────────────────
-- Some sub-projects aren't picked up by the auto-detection (e.g. nested poms
-- whose parent doesn't list them in <modules>, or a Cargo crate sitting next
-- to the root that isn't a workspace member). The user can register them by
-- hand from the toolbar — entries are stored per-repo and rendered in their
-- own dedicated section so they don't intermix with the detection output.

local TEMPLATE_PHASES = {
  maven  = { phases = MAVEN_PHASES, label = "Lifecycle" },
  gradle = { phases = GRADLE_TASKS, label = "Tasks"     },
  cargo  = { phases = CARGO_TASKS,  label = "Tasks"     },
  make   = { phases = nil,          label = nil         }, -- bare module, no lifecycle children
}

local TEMPLATE_ICON = {
  maven = "Hammer", gradle = "Hammer", cargo = "Box",
  npm   = "Package", make = "Wrench",
}

local function load_manual()
  local raw = arbor.settings.project.get("manual_modules") or "[]"
  local ok, decoded = pcall(arbor.json.decode, raw)
  return (ok and type(decoded) == "table") and decoded or {}
end

local function save_manual(list)
  local s = arbor.json.encode(list or {})
  if s then arbor.settings.project.set("manual_modules", s) end
end

-- Resolve a stored `dir` (absolute OR relative to the repo) to an absolute
-- path. We accept both because absolute is what users typically paste from
-- the OS file browser, while relative is friendlier when sharing a repo
-- across machines.
local function resolve_manual_dir(repo_path, dir)
  if not dir or dir == "" then return repo_path end
  -- Windows absolute (`C:\…`) or POSIX absolute (`/…`).
  if dir:match("^[A-Za-z]:[/\\]") or dir:sub(1, 1) == "/" or dir:sub(1, 1) == "\\" then
    return dir
  end
  return arbor.fs.join(repo_path, dir)
end

local function build_manual_module_node(entry, repo_path)
  local tpl = entry.template_id or "make"
  local mod_dir = resolve_manual_dir(repo_path, entry.dir or "")
  local meta = TEMPLATE_PHASES[tpl] or { phases = nil, label = nil }
  local children = {}
  if meta.phases then
    children[#children + 1] = lifecycle_section(tpl, mod_dir, meta.phases, meta.label)
  end

  local pm = nil
  if tpl == "npm" then
    pm = detect.detect_npm_pm(mod_dir)
    -- Surface package.json scripts as a Scripts section, mirroring the
    -- auto-detection path so manual npm modules feel native.
    local pkg_path = arbor.fs.join(mod_dir, "package.json")
    if arbor.fs.is_file(pkg_path) then
      local pkg = read_json_file(pkg_path)
      local sec = npm_scripts_section(pkg and pkg.scripts, mod_dir, pm)
      if sec then children[#children + 1] = sec end
    end
  end

  return {
    id        = "module:manual:" .. (entry.id or mod_dir),
    label     = entry.name or repo_name(mod_dir),
    icon      = TEMPLATE_ICON[tpl] or "Box",
    kind      = "module",
    expanded  = false,
    selectable = true,
    data      = {
      template_id = tpl,
      module_dir  = mod_dir,
      repo_path   = repo_path,
      manual      = true,
      manual_id   = entry.id,
      pm          = pm,
    },
    children  = children,
  }
end

local function build_manual_section(repo_path)
  local entries = load_manual()
  if #entries == 0 then return nil end
  local children = {}
  for _, e in ipairs(entries) do
    children[#children + 1] = build_manual_module_node(e, repo_path)
  end
  return {
    id        = "section:manual",
    label     = "Manual Projects",
    icon      = "FolderPlus",
    kind      = "section",
    expanded  = true,
    selectable = false,
    data      = {},
    children  = children,
  }
end

M.load_manual = load_manual
M.save_manual = save_manual

-- ── Public: rebuild the snapshot for the given repo ──────────────────────────

function M.refresh(repo_path)
  repo_path = repo_path or state.current_repo or ""
  local nodes = {}
  if repo_path ~= "" then
    -- Build configurations (compile-action's own) always come first — the
    -- user spends most of their time clicking these. Run configurations are
    -- injected separately via the `tree.section` contribution slot, so they
    -- automatically appear when run-action is loaded.
    local bc = build_buildconfig_nodes(repo_path)
    if bc then nodes[#nodes+1] = bc end

    local proj_type = detect.detect(repo_path)
    local builder = proj_type and TOOLCHAIN_BUILDER[proj_type] or nil
    if builder then nodes[#nodes+1] = builder(repo_path) end

    local manual = build_manual_section(repo_path)
    if manual then nodes[#nodes+1] = manual end
  end

  local title = "Build & Run"
  if repo_path ~= "" then
    title = "Build & Run — " .. repo_name(repo_path)
  end

  arbor.ui.tree.set(SIDEBAR_ID, { title = title, nodes = nodes })
end

-- ── Toolbar contributions (compile-action's own buttons) ─────────────────────

local function contribute_toolbar()
  -- The "Run last build" button used to live here as a Play icon, but it
  -- was visually indistinguishable from run-action's "Run application"
  -- button right next to it. They do different things (build vs run) so we
  -- removed the redundant entry — users trigger a build by clicking a
  -- build_config row, and run-action owns the green Play in the toolbar.
  local items = {
    -- TEMP: Stop button hidden until the cross-plugin cancel path is
    -- reliable post-reload. The handler `compile:stop` + run-action's
    -- `stop_services` service stay wired so we only need to put this back
    -- once it works end-to-end.
    -- {
    --   id              = "stop",
    --   icon            = "Square",
    --   tooltip         = "Stop running build / services in this repo",
    --   action          = "compile:stop",
    --   danger          = true,
    --   priority        = 20,
    -- },
    {
      id       = "refresh",
      icon     = "RotateCw",
      tooltip  = "Refresh project tree",
      action   = "compile:refresh_tree",
      priority = 30,
    },
    {
      id       = "new-config",
      icon     = "Plus",
      tooltip  = "New run configuration…",
      action   = "compile:new_runconfig",
      priority = 40,
    },
    {
      id       = "add-manual",
      icon     = "FolderPlus",
      tooltip  = "Add project to sidebar manually",
      action   = "compile:manual_add_open",
      priority = 45,
    },
    {
      id       = "settings",
      icon     = "Settings",
      tooltip  = "Build & Run settings",
      action   = "compile:open_settings",
      priority = 50,
      divider_before = true,
    },
  }
  for _, it in ipairs(items) do
    arbor.ui.contribute(M.POINT.toolbar, {
      id       = it.id,
      payload  = {
        icon            = it.icon,
        tooltip         = it.tooltip,
        action          = it.action,
        accent          = it.accent or false,
        divider_before  = it.divider_before or false,
      },
      priority = it.priority,
    })
  end
end

-- ── Context menu (Remove on manual modules) ─────────────────────────────────

local function contribute_context_menu()
  -- Only manual entries can be removed — auto-detected ones are derived from
  -- on-disk files, so the only way to "remove" them is to delete the file.
  arbor.ui.contribute(M.POINT.context_menu, {
    id       = "manual-remove",
    priority = 90,
    when     = { kind = "module", data_field = { key = "manual", value = true } },
    payload  = {
      label  = "Remove from sidebar",
      action = "compile:manual_remove",
      danger = true,
    },
  })
end

-- ── Contribution point declarations (informational) ──────────────────────────

local function declare_contribution_points()
  local points = {
    { name = M.POINT.toolbar,             description = "Buttons rendered in the Build & Run sidebar header." },
    { name = M.POINT.tree_section,        description = "Top-level section nodes injected into the tree (e.g. run-action's 'Run configurations'). Payload: { section = <TreeNode> }." },
    { name = M.POINT.node_action,         description = "Hover-revealed buttons on each tree row." },
    { name = M.POINT.node_decorator,      description = "Always-visible badge / icon decorators per row." },
    { name = M.POINT.context_menu,        description = "Right-click menu items per row." },
    { name = M.POINT.dependency_provider, description = "Provides a dependency tree for matching nodes (opens DependencyTreeModal)." },
    { name = M.POINT.footer,              description = "Items rendered in the sidebar footer." },
  }
  for _, p in ipairs(points) do
    arbor.ui.contribution_point(p)
  end
end

-- ── Public: register everything (called from main.lua at PLUGIN_LOAD) ────────

function M.register()
  arbor.ui.add_sidebar({
    id          = SIDEBAR_ID,
    label       = "Build & Run",
    icon        = "Hammer",
    side        = "right",
    position    = "top",
    kind        = "tree",
    tooltip     = "Build & Run",
    collapsable = false,
  })
  declare_contribution_points()
  contribute_toolbar()
  contribute_context_menu()
end

return M
