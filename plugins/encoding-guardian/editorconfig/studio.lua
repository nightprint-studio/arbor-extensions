-- editorconfig/studio.lua — tree-on-left + form-on-right `.editorconfig`
-- editor, with a "Raw" toggle that swaps the form for a CodeMirror buffer
-- holding the file verbatim.
--
-- The state lives at module scope (one open modal at a time per plugin).
-- Selections drive `arbor.ui.form.replace` to re-render the right panel
-- whenever the user clicks a different section in the tree.

local parser = require("editorconfig.parser")

local M = {}

-- ── Option lists ───────────────────────────────────────────────────────────

local CHARSET_OPTIONS = {
  { value = "utf-8",       label = "utf-8 (no BOM)" },
  { value = "utf-8-bom",   label = "utf-8 with BOM" },
  { value = "latin1",      label = "latin1" },
  { value = "utf-16le",    label = "utf-16le" },
  { value = "utf-16be",    label = "utf-16be" },
}

local EOL_OPTIONS = {
  { value = "lf",   label = "lf (Unix)" },
  { value = "crlf", label = "crlf (Windows)" },
  { value = "cr",   label = "cr" },
}

local INDENT_STYLE_OPTIONS = {
  { value = "space", label = "space" },
  { value = "tab",   label = "tab" },
}

local ROOT_NODE_VALUE = "__root__"

-- ── State ──────────────────────────────────────────────────────────────────

local state = {
  cfg      = { root = false, sections = {} },
  selected = ROOT_NODE_VALUE,
  raw_mode = false,
}

local function selected_section_index()
  local idx = state.selected:match("^sec:(%d+)$")
  return idx and tonumber(idx) or nil
end

local function default_cfg_for_new_file()
  return {
    root     = true,
    sections = {
      { pattern  = "*",
        comments = {},
        keys     = {
          charset                  = "utf-8",
          end_of_line              = "lf",
          insert_final_newline     = "true",
          trim_trailing_whitespace = "true",
          indent_style             = "space",
          indent_size              = "2",
        },
      },
    },
  }
end

-- ── Node builders ──────────────────────────────────────────────────────────

local function nav_nodes()
  local nodes = {
    { value = ROOT_NODE_VALUE, label = "Root (root = true)", icon = "Anchor" },
  }
  for i, section in ipairs(state.cfg.sections) do
    nodes[#nodes + 1] = {
      value = "sec:" .. i,
      label = "[" .. section.pattern .. "]",
      icon  = "FileCode",
    }
  end
  return nodes
end

local function root_form_children()
  return {
    { type = "heading",   text = "Root marker" },
    { type = "paragraph",
      text = "When `root = true`, EditorConfig stops looking for parent "
          .. "`.editorconfig` files above this one. Set it on the file at "
          .. "the project root." },
    { type = "checkbox", name = "root",
      label = "root = true",
      default = state.cfg.root },
  }
end

local function section_form_children(idx)
  local section = state.cfg.sections[idx]
  if not section then return root_form_children() end
  local keys = section.keys
  return {
    { type = "heading", text = "Section [" .. section.pattern .. "]" },
    { type = "text",     name = "pattern", label = "Glob pattern",
      default = section.pattern,
      hint    = "Examples: `*`, `*.rs`, `*.{yml,yaml}`, `Makefile`." },
    { type = "select",   name = "charset", label = "charset",
      options = CHARSET_OPTIONS,
      default = keys.charset, clearable = true,
      hint    = "Leave blank to inherit from a parent section." },
    { type = "select",   name = "end_of_line", label = "end_of_line",
      options = EOL_OPTIONS,
      default = keys.end_of_line, clearable = true },
    { type = "select",   name = "indent_style", label = "indent_style",
      options = INDENT_STYLE_OPTIONS,
      default = keys.indent_style, clearable = true },
    { type = "number",   name = "indent_size", label = "indent_size",
      default = tonumber(keys.indent_size), min = 1, max = 16, step = 1 },
    { type = "number",   name = "tab_width", label = "tab_width",
      default = tonumber(keys.tab_width), min = 1, max = 16, step = 1 },
    { type = "checkbox", name = "insert_final_newline",
      label   = "insert_final_newline",
      default = keys.insert_final_newline == "true" },
    { type = "checkbox", name = "trim_trailing_whitespace",
      label   = "trim_trailing_whitespace",
      default = keys.trim_trailing_whitespace == "true" },
    { type = "number",   name = "max_line_length",
      label   = "max_line_length (0 = off)",
      default = tonumber(keys.max_line_length) or 0,
      min     = 0, max = 1000 },
    { type = "button",   label   = "Delete section",
      action  = "egd:section_delete",
      extra   = { idx = idx },
      variant = "danger" },
  }
end

local function content_children()
  if state.raw_mode then
    return {
      { type = "editor", name = "raw",
        label        = ".editorconfig (raw)",
        -- `.editorconfig` is grammatically a `.properties` superset (key=value,
        -- `#` comments, line-oriented). The properties grammar gives us
        -- key / value / escape / comment highlighting without a dedicated INI
        -- parser; `[section]` headers fall through as plain text.
        language     = "properties",
        height       = 400,
        default      = parser.serialise(state.cfg),
        line_numbers = true,
        hint         = "Save commits this verbatim. Switch back to Structured "
                    .. "to round-trip through the form parser." },
    }
  end
  if state.selected == ROOT_NODE_VALUE then
    return root_form_children()
  end
  local idx = selected_section_index()
  if idx then return section_form_children(idx) end
  return root_form_children()
end

local function studio_nodes()
  return {
    { type = "tree_layout", id = "egd-layout",
      nav_width    = "280px",
      nav_children = {
        { type = "tree", name = "selected",
          nodes         = nav_nodes(),
          default       = state.selected,
          change_action = "egd:section_select",
          height        = "440px" },
        { type = "button", label = "+ Add section",
          action  = "egd:section_add",
          variant = "ghost" },
      },
      content_children = {
        { type = "container", id = "egd-content", children = content_children() },
      },
    },
    { type = "divider" },
    { type = "checkbox", name = "raw_mode",
      label   = "Raw .editorconfig (CodeMirror)",
      default = state.raw_mode },
  }
end

local function rerender()
  arbor.ui.form.replace({ nodes = studio_nodes() })
end

-- ── Save ───────────────────────────────────────────────────────────────────

local function save_raw_mode(ctx)
  local text = ctx.raw or ""
  arbor.fs.write(parser.path_in_active_repo(), text)
  state.cfg = parser.parse(text)
end

-- Empty string and nil both mean "clear the key"; any other value is
-- written verbatim (stringified).
local function set_or_clear_key(section, key, value)
  if value == nil or value == "" then
    section.keys[key] = nil
  else
    section.keys[key] = tostring(value)
  end
end

local function save_structured_root(ctx)
  state.cfg.root = ctx.root and true or false
end

local function save_structured_section(ctx, section)
  if ctx.pattern and ctx.pattern ~= "" then section.pattern = ctx.pattern end
  set_or_clear_key(section, "charset",      ctx.charset)
  set_or_clear_key(section, "end_of_line",  ctx.end_of_line)
  set_or_clear_key(section, "indent_style", ctx.indent_style)
  set_or_clear_key(section, "indent_size",  ctx.indent_size)
  set_or_clear_key(section, "tab_width",    ctx.tab_width)

  section.keys.insert_final_newline     = ctx.insert_final_newline     and "true" or nil
  section.keys.trim_trailing_whitespace = ctx.trim_trailing_whitespace and "true" or nil

  local max_len = tonumber(ctx.max_line_length)
  if max_len and max_len > 0 then
    section.keys.max_line_length = tostring(math.floor(max_len))
  else
    section.keys.max_line_length = nil
  end
end

local function save_structured_mode(ctx)
  if state.selected == ROOT_NODE_VALUE then
    save_structured_root(ctx)
  else
    local idx = selected_section_index()
    local section = idx and state.cfg.sections[idx]
    if section then save_structured_section(ctx, section) end
  end
  arbor.fs.write(parser.path_in_active_repo(), parser.serialise(state.cfg))
end

-- ── Public ─────────────────────────────────────────────────────────────────

function M.open()
  local path = parser.path_in_active_repo()
  if not path then
    arbor.notify{ message = "Open a repository first.", level = "warning" }
    return
  end

  local body = arbor.fs.exists(path) and (arbor.fs.read(path) or "") or ""
  state.cfg      = parser.parse(body)
  state.selected = ROOT_NODE_VALUE
  state.raw_mode = false

  -- Empty file = first-time .editorconfig: seed with a sensible UTF-8 + LF
  -- defaults block so the user has something worth Save'ing.
  if #state.cfg.sections == 0 then state.cfg = default_cfg_for_new_file() end

  arbor.ui.form.open({
    title         = ".editorconfig - Encoding Guardian",
    width         = "880px",
    height        = "640px",
    nodes         = studio_nodes(),
    submit_label  = "Save",
    submit_action = "egd:studio_save",
    cancel_label  = "Close",
  })
end

-- Wire up handlers + Command Palette entry. Called once from main.lua.
function M.register()
  arbor.command.register({
    id          = "editorconfig",
    title       = "Encoding Guardian: Open .editorconfig studio",
    description = "Create or edit `.editorconfig` with a structured form (or raw CodeMirror).",
    icon        = "FileCog",
    group       = "Encoding Guardian",
  })
  arbor.events.on("command:editorconfig", function(_ctx) M.open() end)

  arbor.events.on("egd:section_select", function(ctx)
    local v = ctx and (ctx.selected or ctx.value)
    if not v then return end
    state.selected = v
    rerender()
  end)

  arbor.events.on("egd:section_add", function(_ctx)
    state.cfg.sections[#state.cfg.sections + 1] = {
      pattern = "*.ext", keys = {}, comments = {},
    }
    state.selected = "sec:" .. #state.cfg.sections
    rerender()
  end)

  arbor.events.on("egd:section_delete", function(ctx)
    local idx = ctx and ctx.idx
    if not idx then return end
    table.remove(state.cfg.sections, idx)
    state.selected = ROOT_NODE_VALUE
    rerender()
  end)

  arbor.events.on("egd:studio_save", function(ctx)
    state.raw_mode = ctx.raw_mode and true or false
    if state.raw_mode then save_raw_mode(ctx)
    else                   save_structured_mode(ctx)
    end
    arbor.notify{ message = ".editorconfig saved.", level = "success" }
    pcall(function() arbor.ui.form.close() end)
  end)
end

return M
