-- config/jdk.lua — JDK toolchain management + per-project JDK selector
--
-- JDK toolchains are stored via arbor.toolchain API (~/.config/arbor/toolchains/jdk.json).
-- Each entry: { id, label, path, active }.
-- The active entry is the "default" used when no per-project JDK is assigned.
-- Per-project selection: id stored in arbor.settings.project under "project_jdk".
-- At run time JAVA_HOME is injected; explicit env vars in the config always win.

local M = {}

-- ── Toolchain access ──────────────────────────────────────────────────────────

function M.load_jdks()
  return arbor.toolchain.list("jdk") or {}
end

function M.find_jdk(id)
  if not id or id == "" then return nil end
  for _, j in ipairs(M.load_jdks()) do
    if j.id == id then return j end
  end
  return nil
end

function M.load_default_jdk()
  local active = arbor.toolchain.active("jdk")
  return active and active.id or ""
end

-- ── Per-project JDK ───────────────────────────────────────────────────────────

function M.load_project_jdk()
  return arbor.settings.project.get("project_jdk") or ""
end

function M.save_project_jdk(id)
  arbor.settings.project.set("project_jdk", id or "")
end

-- ── Env injection ─────────────────────────────────────────────────────────────

--- Returns an env table with JAVA_HOME injected.
--- Priority:  project JDK  >  default JDK  >  nothing (env passed through).
--- Explicit vars in `existing_env` always win over any injected value.
function M.get_java_env(existing_env)
  local jdk_id = ""
  pcall(function() jdk_id = M.load_project_jdk() end)
  if jdk_id == "" then jdk_id = M.load_default_jdk() end
  if jdk_id == "" then return existing_env end

  local tc_env = arbor.toolchain.env{ kind = "jdk", id = jdk_id } or {}
  local env = {}
  for k, v in pairs(tc_env) do env[k] = v end
  for k, v in pairs(existing_env or {}) do env[k] = v end
  return env
end

-- ── Settings form nodes ───────────────────────────────────────────────────────

function M.build_settings_nodes()
  local jdks       = M.load_jdks()
  local default_id = M.load_default_jdk()
  local nodes      = {}

  nodes[#nodes+1] = {
    type    = "paragraph",
    content = "Define JDK installations available across all repositories. "
            .. "The ✦ default is used automatically when no per-project JDK is assigned. "
            .. "Assign a JDK to a specific repository via ⚙ Project settings in the combo dropdown.",
    variant = "muted",
  }

  if #jdks == 0 then
    nodes[#nodes+1] = {
      type    = "paragraph",
      content = "No JDK installations defined yet. Add one below.",
      variant = "muted",
    }
  else
    local radio_opts = {}
    for _, j in ipairs(jdks) do
      local suffix = (j.id == default_id) and "  ✦ default" or ""
      radio_opts[#radio_opts+1] = {
        value = j.id,
        label = j.label .. "  ·  " .. j.path .. suffix,
      }
    end
    nodes[#nodes+1] = {
      type    = "radio",
      name    = "sel_jdk",
      label   = "Installed JDKs",
      options = radio_opts,
    }
    nodes[#nodes+1] = {
      type    = "row", gap = 8, align = "center",
      show_if = { field = "sel_jdk", neq = "" },
      children = {
        { type = "button", label = "Edit",           action = "compile:jdk_edit",        variant = "default" },
        { type = "button", label = "Set as Default", action = "compile:jdk_set_default", variant = "default" },
        { type = "button", label = "Delete",         action = "compile:jdk_delete",      variant = "danger"  },
      },
    }
  end

  nodes[#nodes+1] = {
    type        = "section",
    title       = "Add new JDK installation",
    collapsible = true,
    collapsed   = true,
    children    = {
      { type = "container", columns = 2, gap = 12, children = {
        { type = "text", name = "new_jdk_id",    label = "ID *",
          placeholder = "jdk21",
          hint = "Short identifier, e.g. jdk21, temurin17" },
        { type = "text", name = "new_jdk_label", label = "Display Name *",
          placeholder = "JDK 21 (Eclipse Temurin)" },
      }},
      { type = "text", name = "new_jdk_path", label = "JAVA_HOME path *",
        placeholder = "/usr/lib/jvm/java-21-openjdk",
        hint = "Root directory of the JDK installation (must contain bin/java)" },
      { type = "row", gap = 8, children = {
        { type = "button", label = "Add JDK", action = "compile:jdk_add", variant = "primary" },
      }},
    },
  }

  return nodes
end

-- ── Action handlers ───────────────────────────────────────────────────────────

local function reopen_settings()
  local gcfg = require("config.global")
  gcfg.open_settings_form()
end

function M.handle_set_default(ctx)
  local jdk_id = ctx.id or ctx.sel_jdk or ""
  if jdk_id == "" then
    arbor.notify{ message = "Select a JDK first", level = "warning" }
    reopen_settings(); return
  end
  local j = M.find_jdk(jdk_id)
  if not j then
    arbor.notify{ message = "JDK not found", level = "error" }
    reopen_settings(); return
  end
  arbor.toolchain.set_active("jdk", jdk_id)
  arbor.notify{ message = "Default JDK set: " .. j.label, level = "success" }
  reopen_settings()
end

function M.handle_add(ctx)
  local id    = ctx.new_jdk_id    or ""
  local label = ctx.new_jdk_label or ""
  local path  = ctx.new_jdk_path  or ""

  if id == "" or path == "" then
    arbor.notify{ message = "ID and Path are required", level = "warning" }
    reopen_settings(); return
  end

  if M.find_jdk(id) then
    arbor.notify{ message = "JDK ID '" .. id .. "' already exists", level = "warning" }
    reopen_settings(); return
  end

  arbor.toolchain.add("jdk", {
    id    = id,
    label = label ~= "" and label or id,
    path  = path,
  })
  arbor.notify{ message = "JDK '" .. (label ~= "" and label or id) .. "' added", level = "success" }
  reopen_settings()
end

function M.handle_delete(ctx)
  local jdk_id = ctx.id or ctx.sel_jdk or ""
  if jdk_id == "" then
    arbor.notify{ message = "Select a JDK first", level = "warning" }
    reopen_settings(); return
  end

  if not M.find_jdk(jdk_id) then
    arbor.notify{ message = "JDK not found", level = "error" }
    reopen_settings(); return
  end

  arbor.toolchain.remove("jdk", jdk_id)
  arbor.notify{ message = "JDK deleted", level = "success" }
  reopen_settings()
end

function M.handle_edit(ctx)
  local jdk_id = ctx.id or ctx.sel_jdk or ""
  if jdk_id == "" then
    arbor.notify{ message = "Select a JDK first", level = "warning" }
    reopen_settings(); return
  end

  local j = M.find_jdk(jdk_id)
  if not j then
    arbor.notify{ message = "JDK not found", level = "error" }
    reopen_settings(); return
  end

  arbor.ui.form({
    title         = "Edit JDK Installation",
    description   = "Editing: " .. j.label,
    submit_label  = "Save Changes",
    submit_action = "compile:jdk_edit_save",
    cancel_action = "compile:settings_noop",
    width         = "480px",
    state         = { jdk_id = jdk_id },
    nodes = {
      { type = "text", name = "jdk_id_display", label = "ID",
        default = j.id, readonly = true },
      { type = "text", name = "jdk_label", label = "Display Name *",
        default = j.label or "" },
      { type = "text", name = "jdk_path",  label = "JAVA_HOME path *",
        default = j.path or "",
        hint = "Root directory of the JDK installation (must contain bin/java)" },
    },
  })
end

function M.handle_edit_save(ctx)
  local jdk_id = (ctx.state and ctx.state.jdk_id) or ""
  local label  = ctx.jdk_label or ""
  local path   = ctx.jdk_path  or ""

  if jdk_id == "" or path == "" then
    arbor.notify{ message = "Path is required", level = "warning" }
    reopen_settings(); return
  end

  local j = M.find_jdk(jdk_id)
  if not j then
    arbor.notify{ message = "JDK not found", level = "error" }
    reopen_settings(); return
  end

  local was_active = (M.load_default_jdk() == jdk_id)
  arbor.toolchain.remove("jdk", jdk_id)
  arbor.toolchain.add("jdk", {
    id    = jdk_id,
    label = label ~= "" and label or j.label,
    path  = path,
  })
  if was_active then arbor.toolchain.set_active("jdk", jdk_id) end

  arbor.notify{ message = "JDK updated", level = "success" }
  reopen_settings()
end

return M
