-- config/global.lua — global run-config CRUD and settings form
-- Global configs are shared across all repos.
-- Stored via arbor.settings.global under key "global_configs" (JSON array).

local M = {}

local jdk = require("config.jdk")

local LANGUAGES = {
  { value="maven",  label="Maven",             icon="Package"  },
  { value="gradle", label="Gradle",            icon="Package"  },
  { value="npm",    label="npm / Yarn / pnpm", icon="Package"  },
  { value="rust",   label="Rust (Cargo)",      icon="Package"  },
  { value="go",     label="Go",                icon="Package"  },
  { value="make",   label="Makefile",          icon="Wrench"   },
}

local function lang_label(lang)
  for _, l in ipairs(LANGUAGES) do
    if l.value == lang then return l.label end
  end
  return lang
end

-- ── Storage ───────────────────────────────────────────────────────────────────

function M.load()
  local raw, err = arbor.json.decode(arbor.settings.global.get("global_configs") or "[]")
  return (raw and type(raw) == "table") and raw or {}
end

function M.save(cfgs)
  local s, err = arbor.json.encode(cfgs)
  if s then arbor.settings.global.set("global_configs", s) end
end

function M.load_for_lang(lang)
  local all, out = M.load(), {}
  for _, c in ipairs(all) do
    if (c.lang or "") == lang then out[#out+1] = c end
  end
  return out
end

function M.find(id)
  for _, c in ipairs(M.load()) do
    if c.id == id then return c end
  end
  return nil
end

function M.load_default_profile(lang)
  return arbor.settings.global.get("default_profile:" .. lang) or ""
end

function M.save_default_profile(lang, id)
  arbor.settings.global.set("default_profile:" .. lang, id)
end

-- ── Settings panel ────────────────────────────────────────────────────────────
-- Settings flow through the contribution-based panel registered with
-- `arbor.ui.settings.panel`. We contribute:
--
--   * One CATEGORY per toolchain language (Java, Node.js, Rust) — appears
--     as a sidebar entry on the left of the modal.
--   * One SECTION per card visible in the right pane (Installed, Detection,
--     Add manually) — `category` field on the payload pins it to the right
--     sidebar entry.
--
-- External plugins can extend either layer:
--   * Add a new sidebar entry: contribute to
--     `compile-action:settings:category` with their own id.
--   * Add a card to an existing sidebar entry: contribute to
--     `compile-action:settings:section` with `category = "java" | "node" | "rust"`.
--
-- Re-contributed each time `open_settings_form()` (or `compile:settings_refresh`)
-- runs so toolchain mutations are visible on the next open.

local CATEGORY_POINT = "compile-action:settings:category"
local SECTION_POINT  = "compile-action:settings:section"

local function register_panel()
  arbor.ui.settings.panel({
    id           = "main",
    title        = "Compile · Build & Toolchains",
    icon         = "Settings",
    width        = "960px",
    submit_label = "Close",
    -- No on_save: each action persists its own changes immediately
    -- (toolchain.add / set_active / etc. write through to disk on call).
  })
end

local function contribute_category(id, label, icon, priority, description)
  arbor.ui.contribute(CATEGORY_POINT, {
    id       = id,
    priority = priority or 100,
    payload  = {
      label       = label,
      icon        = icon,
      priority    = priority or 100,
      description = description,
    },
  })
end

local function contribute_section(id, category, label, nodes, opts)
  opts = opts or {}
  arbor.ui.contribute(SECTION_POINT, {
    id       = id,
    priority = opts.priority or 100,
    payload  = {
      category   = category,
      label      = label,
      nodes      = nodes,
      count      = opts.count,
      add_action = opts.add_action,
    },
  })
end

-- Re-contribute the JDK / Node / Rust sections with the current toolchain
-- state. Called by:
--   • `compile:settings_refresh` (the panel's on_load — fires when the
--     orchestrator opens the modal)
--   • `M.open_settings_form()` (legacy entry point; some action handlers
--     still call it after a mutation to "reopen" the modal)
function M.contribute_sections()
  local jdks  = arbor.toolchain.list("jdk")  or {}
  local nodes = arbor.toolchain.list("node") or {}
  local rusts = arbor.toolchain.list("rust") or {}

  -- ── JDK tab ────────────────────────────────────────────────────────────────
  local jdk_rows = {}
  for _, j in ipairs(jdks) do
    jdk_rows[#jdk_rows+1] = {
      type        = "card_row",
      label       = j.label,
      description = j.version or "",
      children    = {
        { type = "text", name = "jdk_path_" .. j.id, default = j.path, readonly = true },
        { type = "row", gap = 6, align = "center", children = {
          j.active
            and { type = "paragraph", content = "✓ active", variant = "muted" }
            or  { type = "button", label = "Set active", action = "compile:jdk_set_default",
                  variant = "default", extra = { id = j.id } },
          { type = "button", label = "Edit",   action = "compile:jdk_edit",   variant = "default", extra = { id = j.id } },
          { type = "button", label = "Delete", action = "compile:jdk_delete", variant = "danger",  extra = { id = j.id } },
        }},
      },
    }
  end
  if #jdks == 0 then
    jdk_rows[#jdk_rows+1] = { type = "card_row", children = {
      { type = "paragraph", content = "No JDK installations defined. Click + to auto-detect.", variant = "muted" },
    }}
  end

  -- ─ Java cards (3 sections under the "java" category) ────────────────────
  local jdk_installed_nodes  = jdk_rows
  local jdk_detection_nodes  = {
    { type = "card_row", label = "Auto-detect", description = "Scan JAVA_HOME and common install paths", children = {
      { type = "button", label = "Detect JDKs", action = "compile:jdk_detect", variant = "default" },
    }},
  }
  local jdk_add_nodes = {
    { type = "card_row", label = "ID *", children = {
      { type = "text", name = "new_jdk_id", placeholder = "jdk21",
        hint = "Short identifier, e.g. temurin21, oracle17" },
    }},
    { type = "card_row", label = "Display name *", children = {
      { type = "text", name = "new_jdk_label", placeholder = "JDK 21 (Eclipse Temurin)" },
    }},
    { type = "card_row", label = "JAVA_HOME path *", children = {
      { type = "text", name = "new_jdk_path", placeholder = "/usr/lib/jvm/java-21-openjdk" },
      { type = "button", label = "Add JDK", action = "compile:jdk_add", variant = "primary" },
    }},
  }

  -- ── Node.js tab ────────────────────────────────────────────────────────────
  local node_rows = {}
  for _, n in ipairs(nodes) do
    node_rows[#node_rows+1] = {
      type        = "card_row",
      label       = n.label,
      description = n.version or "",
      children    = {
        { type = "text", name = "node_path_" .. n.id, default = n.path, readonly = true },
        n.active
          and { type = "paragraph", content = "✓ active", variant = "muted" }
          or  { type = "button", label = "Set active", action = "compile:toolchain_set_active",
                variant = "default", extra = { kind = "node", id = n.id } },
      },
    }
  end
  if #nodes == 0 then
    node_rows[#node_rows+1] = { type = "card_row", children = {
      { type = "paragraph", content = "No Node.js installations detected.", variant = "muted" },
    }}
  end

  -- ─ Node.js cards (3 sections under the "node" category) ─────────────────
  local node_installed_nodes = node_rows
  local node_detection_nodes = {
    { type = "card_row", label = "Auto-detect", description = "Scan PATH for node executable", children = {
      { type = "button", label = "Detect Node.js", action = "compile:node_detect", variant = "default" },
    }},
  }
  local node_add_nodes = {
    { type = "card_row", label = "ID *", children = {
      { type = "text", name = "new_node_id", placeholder = "node20",
        hint = "Short identifier, e.g. node20, node-lts" },
    }},
    { type = "card_row", label = "Display name *", children = {
      { type = "text", name = "new_node_label", placeholder = "Node.js 20 LTS" },
    }},
    { type = "card_row", label = "Path to node *", children = {
      { type = "text", name = "new_node_path", placeholder = "/usr/local/bin/node" },
      { type = "button", label = "Add Node", action = "compile:node_add", variant = "primary" },
    }},
  }

  -- ── Rust / Cargo tab ───────────────────────────────────────────────────────
  local rust_rows = {}
  for _, r in ipairs(rusts) do
    rust_rows[#rust_rows+1] = {
      type        = "card_row",
      label       = r.label,
      description = r.version or "",
      children    = {
        { type = "text", name = "rust_path_" .. r.id, default = r.path, readonly = true },
        r.active
          and { type = "paragraph", content = "✓ active", variant = "muted" }
          or  { type = "button", label = "Set active", action = "compile:toolchain_set_active",
                variant = "default", extra = { kind = "rust", id = r.id } },
      },
    }
  end
  if #rusts == 0 then
    rust_rows[#rust_rows+1] = { type = "card_row", children = {
      { type = "paragraph", content = "No Rust toolchains detected.", variant = "muted" },
    }}
  end

  -- ─ Rust cards (3 sections under the "rust" category) ────────────────────
  local rust_installed_nodes = rust_rows
  local rust_detection_nodes = {
    { type = "card_row", label = "Auto-detect", description = "Scan ~/.cargo/bin for cargo", children = {
      { type = "button", label = "Detect Rust", action = "compile:rust_detect", variant = "default" },
    }},
  }
  local rust_add_nodes = {
    { type = "card_row", label = "ID *", children = {
      { type = "text", name = "new_rust_id", placeholder = "rust-stable",
        hint = "Short identifier, e.g. rust-stable, rust-nightly" },
    }},
    { type = "card_row", label = "Display name *", children = {
      { type = "text", name = "new_rust_label", placeholder = "Rust 1.78 (stable)" },
    }},
    { type = "card_row", label = "Path to cargo *", children = {
      { type = "text", name = "new_rust_path", placeholder = "/home/user/.cargo/bin/cargo" },
      { type = "button", label = "Add Rust", action = "compile:rust_add", variant = "primary" },
    }},
  }

  -- Re-register the panel + categories + per-card sections idempotently.
  register_panel()

  contribute_category("java", "Java", "Coffee",   10,
    "Global JDK installations. The active entry is used as JAVA_HOME unless overridden per repository.")
  contribute_category("node", "Node.js", "Triangle", 20,
    "Global Node.js installations. Used when npm / Yarn / pnpm projects are built.")
  contribute_category("rust", "Rust / Cargo", "Package", 30,
    "Global Rust / Cargo toolchains. Used when Cargo or Tauri projects are built.")
  contribute_category("maintenance", "Maintenance", "Wrench", 90,
    "Reset auto-detection and clear plugin caches for this and other build/run plugins.")

  -- Java sections
  contribute_section("java-installed", "java", "Installed JDKs", jdk_installed_nodes,
    { priority = 10, count = #jdks, add_action = "compile:jdk_detect" })
  contribute_section("java-detection", "java", "Detection", jdk_detection_nodes,
    { priority = 20 })
  contribute_section("java-add",       "java", "Add JDK manually", jdk_add_nodes,
    { priority = 30 })

  -- Node sections
  contribute_section("node-installed", "node", "Installations", node_installed_nodes,
    { priority = 10, count = #nodes, add_action = "compile:node_detect" })
  contribute_section("node-detection", "node", "Detection", node_detection_nodes,
    { priority = 20 })
  contribute_section("node-add",       "node", "Add Node.js manually", node_add_nodes,
    { priority = 30 })

  -- Rust sections
  contribute_section("rust-installed", "rust", "Toolchains", rust_installed_nodes,
    { priority = 10, count = #rusts, add_action = "compile:rust_detect" })
  contribute_section("rust-detection", "rust", "Detection", rust_detection_nodes,
    { priority = 20 })
  contribute_section("rust-add",       "rust", "Add Rust manually", rust_add_nodes,
    { priority = 30 })

  -- Maintenance: per-repo state reset. Cross-plugin caches (deps-explorer
  -- registries, etc.) contribute their own sections to the same category
  -- through `compile-action:settings:on_open`.
  local detected = arbor.settings.project.get("detected_type") or ""
  local manual_count = 0
  do
    local raw = arbor.settings.project.get("manual_modules") or "[]"
    local ok, decoded = pcall(arbor.json.decode, raw)
    if ok and type(decoded) == "table" then manual_count = #decoded end
  end

  local detection_nodes = {
    { type = "paragraph", variant = "muted",
      content = "These actions affect ONLY the active repository. The auto-detected "
             .. "project type and any auto-generated build configurations are recreated "
             .. "from scratch the next time the repository is opened." },
    { type = "card_row",
      label = "Detected project type",
      description = (detected ~= "") and ("Currently: " .. detected) or "Not detected yet",
      children = {
        { type = "button", label = "Reset detection",
          action = "compile:reset_detection", variant = "default",
          tooltip = "Clear the cached project type for this repo so the next open re-runs detection." },
      },
    },
    { type = "card_row",
      label = "Auto-generated build configurations",
      description = "Removes the project_configs created by detection. Manual edits are deleted too — keep a copy if you customised them.",
      children = {
        { type = "button", label = "Reset configurations",
          action = "compile:reset_configs", variant = "danger" },
      },
    },
    { type = "card_row",
      label = "Manual sidebar projects",
      description = (manual_count > 0)
                  and (tostring(manual_count) .. " manual entr" .. (manual_count == 1 and "y" or "ies") .. " for this repo.")
                  or "No manual projects added.",
      children = {
        { type = "button", label = "Clear manual projects",
          action = "compile:reset_manual", variant = "danger",
          disabled = manual_count == 0 },
      },
    },
  }
  contribute_section("compile-detection", "maintenance", "Project detection (this repo)",
    detection_nodes, { priority = 10 })
end

-- Legacy entry point — kept for the existing action handlers that "reopen"
-- the modal after a mutation. Now just delegates to the orchestrator.
function M.open_settings_form()
  M.contribute_sections()
  arbor.ui.settings.open("compile-action", "main")
end

-- ── Action handlers (registered in main.lua) ──────────────────────────────────

function M.handle_add(ctx)
  local lang = ctx.lang or "maven"
  local id   = ctx["new_" .. lang .. "_id"]   or ""
  local cmd  = ctx["new_" .. lang .. "_cmd"]  or ""

  if id == "" or cmd == "" then
    arbor.notify{ message = "Config ID and Command are required", level = "warning" }
    reopen(); return
  end

  local nm  = ctx["new_" .. lang .. "_name"]  or ""
  local lbl = ctx["new_" .. lang .. "_label"] or ""
  local cwd = ctx["new_" .. lang .. "_cwd"]   or ""
  local env = ctx["new_" .. lang .. "_env"]   or {}

  local cfgs = M.load()
  for _, c in ipairs(cfgs) do
    if c.id == id then
      arbor.notify{ message = "Config ID '" .. id .. "' already exists", level = "warning" }
      reopen(); return
    end
  end

  cfgs[#cfgs+1] = {
    id      = id,
    name    = nm ~= "" and nm or id,
    label   = lbl ~= "" and lbl or (nm ~= "" and nm or id),
    command = cmd,
    cwd     = cwd,
    env     = env,
    lang    = lang,
  }
  M.save(cfgs)
  arbor.notify{ message = "Global config '" .. id .. "' added", level = "success" }
  reopen()
end

function M.handle_set_default(ctx)
  local lang   = ctx.lang or "maven"
  local cfg_id = ctx["sel_" .. lang] or ""
  if cfg_id == "" then
    arbor.notify{ message = "Select a configuration first", level = "warning" }
    reopen(); return
  end
  M.save_default_profile(lang, cfg_id)
  arbor.notify{ message = "Default profile for " .. lang_label(lang) .. " set", level = "success" }
  reopen()
end

function M.handle_delete(ctx)
  local lang   = ctx.lang or "maven"
  local cfg_id = ctx["sel_" .. lang] or ""
  if cfg_id == "" then
    arbor.notify{ message = "Select a configuration first", level = "warning" }
    reopen(); return
  end
  local cfgs, new_cfgs, found = M.load(), {}, false
  for _, c in ipairs(cfgs) do
    if c.id == cfg_id then found = true
    else new_cfgs[#new_cfgs+1] = c end
  end
  if not found then
    arbor.notify{ message = "Configuration not found", level = "error" }
    reopen(); return
  end
  M.save(new_cfgs)
  if M.load_default_profile(lang) == cfg_id then
    M.save_default_profile(lang, "")
  end
  arbor.notify{ message = "Configuration deleted", level = "success" }
  reopen()
end

function M.handle_edit(ctx)
  local lang   = ctx.lang or "maven"
  local cfg_id = ctx["sel_" .. lang] or ""
  if cfg_id == "" then
    arbor.notify{ message = "Select a configuration first", level = "warning" }
    reopen(); return
  end
  local cfg = M.find(cfg_id)
  if not cfg then
    arbor.notify{ message = "Configuration not found", level = "error" }
    reopen(); return
  end

  arbor.settings.global.set("ui:settings_lang", lang)
  arbor.ui.form({
    title         = "Edit Global Configuration",
    description   = "Editing: " .. (cfg.label or cfg.name),
    submit_label  = "Save Changes",
    submit_action = "compile:global_edit_save",
    cancel_action = "compile:settings_noop",
    width         = "520px",
    state         = { cfg_id = cfg_id, lang = lang },
    nodes = {
      { type = "container", columns = 2, gap = 12, children = {
        { type = "text", name = "cfg_id_display", label = "Config ID", default = cfg.id,          readonly = true },
        { type = "text", name = "lang_display",   label = "Language",  default = lang_label(lang), readonly = true },
      }},
      { type = "text",     name = "name",    label = "Display Name *",   default = cfg.name    or "" },
      { type = "text",     name = "label",   label = "Dropdown Label",   default = cfg.label   or "",
        hint = "Defaults to Display Name if empty" },
      { type = "textarea", name = "command", label = "Command *",        default = cfg.command or "", rows = 2 },
      { type = "text",     name = "cwd",     label = "Working Directory",default = cfg.cwd     or "",
        hint = "Leave empty to use the active repo root at run time" },
      { type = "kv_list",  name = "env",     label = "Environment Variables",
        default = cfg.env or {},
        key_placeholder = "JAVA_HOME", value_placeholder = "/usr/lib/jvm/java-21" },
    },
  })
end

function M.handle_edit_save(ctx)
  local cfg_id = (ctx.state and ctx.state.cfg_id) or ""
  local lang   = (ctx.state and ctx.state.lang)   or ""
  local cmd    = ctx.command or ""

  if cfg_id == "" or cmd == "" then
    arbor.notify{ message = "Command is required", level = "warning" }; return
  end

  local cfgs, updated = M.load(), false
  for i, c in ipairs(cfgs) do
    if c.id == cfg_id then
      local nm = ctx.name or ""
      local lbl = ctx.label or ""
      cfgs[i] = {
        id      = c.id,
        lang    = c.lang or lang,
        name    = nm ~= "" and nm or c.id,
        label   = lbl ~= "" and lbl or (nm ~= "" and nm or c.id),
        command = cmd,
        cwd     = ctx.cwd or "",
        env     = ctx.env or {},
      }
      updated = true; break
    end
  end

  if updated then
    M.save(cfgs)
    arbor.notify{ message = "Configuration saved", level = "success" }
  else
    arbor.notify{ message = "Configuration not found", level = "error" }
  end
  reopen()
end

return M
