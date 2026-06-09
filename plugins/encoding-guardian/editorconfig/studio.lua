-- editorconfig/studio.lua — `.editorconfig` editor.
--
-- Layout cribbed from the host's TOML / JSON / YAML studio modals: a
-- segmented "View" control at the top (Tree / Raw), a tree navigator on the
-- left, and an inspector-style card stack on the right. The View switch
-- gates the body with `show_if` on the radio field, so flipping it is a
-- pure client-side re-eval — no rerender, no roundtrip.
--
-- State lives at module scope (one open modal at a time per plugin) and
-- carries the parsed cfg + the currently-selected tree node. Tree-node
-- selection drives `arbor.ui.form.replace` because the right-hand content
-- depends on the selected section.

local parser = require("editorconfig.parser")

local M = {}

-- ── Options ────────────────────────────────────────────────────────────────

local CHARSET_OPTIONS = {
  { value = "utf-8",     label = "utf-8 (no BOM)" },
  { value = "utf-8-bom", label = "utf-8 with BOM" },
  { value = "latin1",    label = "latin1" },
  { value = "utf-16le",  label = "utf-16le" },
  { value = "utf-16be",  label = "utf-16be" },
}

local EOL_OPTIONS = {
  { value = "lf",   label = "LF (Unix)" },
  { value = "crlf", label = "CRLF (Windows)" },
  { value = "cr",   label = "CR (legacy Mac)" },
}

local INDENT_STYLE_OPTIONS = {
  { value = "space", label = "Spaces" },
  { value = "tab",   label = "Tabs" },
}

local ROOT_NODE_VALUE = "__root__"

-- ── State ──────────────────────────────────────────────────────────────────

local state = {
  cfg      = { root = false, sections = {} },
  selected = ROOT_NODE_VALUE,
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

local function section_key_count(section)
  local n = 0
  for _ in pairs(section.keys) do n = n + 1 end
  return n
end

-- ── Navigator (left pane) ──────────────────────────────────────────────────
--
-- Tree nodes use `icon` (Lucide) + `tag` (right-aligned pill with a tone)
-- to match the dense look of the TOML / JSON studios. We pick a tone per
-- section that hints at its content — empty sections are dimmed, populated
-- ones get a neutral pill.

local function nav_tree_nodes()
  local nodes = {
    { value       = ROOT_NODE_VALUE,
      label       = "Root marker",
      icon        = "Anchor",
      tag         = state.cfg.root and "ON" or "OFF",
      tag_variant = state.cfg.root and "ok" or "neutral" },
  }
  for i, section in ipairs(state.cfg.sections) do
    local keys = section_key_count(section)
    nodes[#nodes + 1] = {
      value       = "sec:" .. i,
      label       = "[" .. section.pattern .. "]",
      icon        = "Braces",
      tag         = keys > 0 and (keys .. " keys") or "empty",
      tag_variant = "neutral",
    }
  end
  return nodes
end

local function nav_children()
  return {
    { type      = "tree",
      name      = "selected",
      nodes     = nav_tree_nodes(),
      default   = state.selected,
      on_select = "egd:section_select",
      height    = "460px" },
    { type    = "button",
      label   = "+ Add section",
      icon    = "Plus",
      action  = "egd:section_add",
      variant = "ghost" },
  }
end

-- ── Content (right pane) — Root marker ─────────────────────────────────────
--
-- Two cards on this page: the actual root toggle, plus a tiny overview
-- card that turns the otherwise-empty right column into something
-- useful (sections count, root state) — matches the inspector feel of
-- the TOML studio when nothing complex is selected.

local function root_cards()
  local sections = #state.cfg.sections
  local patterns = {}
  for i = 1, math.min(sections, 4) do
    patterns[#patterns + 1] = "[" .. state.cfg.sections[i].pattern .. "]"
  end
  if sections > 4 then patterns[#patterns + 1] = "+" .. (sections - 4) .. " more" end

  return {
    { type    = "section",
      card    = true,
      title   = "Root marker",
      children = {
        { type    = "paragraph",
          content = "When ON, EditorConfig stops looking for parent "
                 .. "`.editorconfig` files above this one. Turn this on "
                 .. "for the file at the project root.",
          variant = "muted" },
        { type        = "toggle",
          name        = "root",
          label       = "Topmost .editorconfig",
          description = "root = true",
          size        = "md",
          default     = state.cfg.root },
      } },

    { type      = "info_card",
      title     = ".editorconfig",
      subtitle  = "Overview",
      icon      = "FileCog",
      status    = state.cfg.root
                    and { text = "ROOT", kind = "success" }
                    or  { text = "INHERITS", kind = "muted" },
      meta      = {
        { label = "Sections", value = tostring(sections) },
        { label = "Patterns", value = #patterns > 0
                                        and table.concat(patterns, "  ")
                                        or  "(none)" },
      } },
  }
end

-- ── Content (right pane) — Section cards ───────────────────────────────────

local function section_pattern_card(idx, section)
  return { type    = "section",
           card    = true,
           variant = "component",
           title   = "[" .. section.pattern .. "]",
           subtitle = section_key_count(section) .. " keys",
           status_dot = { tone = "accent", tooltip = "Section " .. idx },
           header_actions = {
             { icon    = "Trash2",
               tooltip = "Delete this section",
               action  = "egd:section_delete",
               extra   = { idx = idx },
               variant = "danger" },
           },
           children = {
             { type    = "form_field",
               label   = "Pattern",
               hint    = "Examples: `*`, `*.rs`, `*.{yml,yaml}`, `Makefile`, `lib/**.ts`",
               children = {
                 { type        = "text",
                   name        = "pattern",
                   default     = section.pattern,
                   placeholder = "*" },
               } },
           } }
end

local function encoding_card(section)
  return { type     = "section",
           card     = true,
           title    = "Encoding & line endings",
           children = {
             { type     = "row",
               gap      = 12,
               children = {
                 { type     = "select",
                   name     = "charset",
                   label    = "Charset",
                   options  = CHARSET_OPTIONS,
                   default  = section.keys.charset,
                   clearable = true,
                   hint     = "Leave blank to inherit." },
                 { type     = "select",
                   name     = "end_of_line",
                   label    = "Line endings",
                   options  = EOL_OPTIONS,
                   default  = section.keys.end_of_line,
                   clearable = true,
                   hint     = "Leave blank to inherit." },
               } },
           } }
end

local function indentation_card(section)
  return { type     = "section",
           card     = true,
           title    = "Indentation",
           children = {
             { type     = "row",
               gap      = 12,
               children = {
                 { type     = "select",
                   name     = "indent_style",
                   label    = "Style",
                   options  = INDENT_STYLE_OPTIONS,
                   default  = section.keys.indent_style,
                   clearable = true },
                 { type    = "number",
                   name    = "indent_size",
                   label   = "Size",
                   default = tonumber(section.keys.indent_size),
                   min     = 1, max = 16, step = 1,
                   hint    = "Spaces per indent." },
                 { type    = "number",
                   name    = "tab_width",
                   label   = "Tab width",
                   default = tonumber(section.keys.tab_width),
                   min     = 1, max = 16, step = 1,
                   hint    = "Defaults to indent_size when blank." },
               } },
           } }
end

local function whitespace_card(section)
  return { type     = "section",
           card     = true,
           title    = "Whitespace & length",
           children = {
             { type        = "toggle",
               name        = "insert_final_newline",
               label       = "Insert final newline",
               description = "Ensure files end with a trailing newline.",
               size        = "sm",
               default     = section.keys.insert_final_newline == "true" },
             { type        = "toggle",
               name        = "trim_trailing_whitespace",
               label       = "Trim trailing whitespace",
               description = "Strip whitespace at the end of every line.",
               size        = "sm",
               default     = section.keys.trim_trailing_whitespace == "true" },
             { type    = "number",
               name    = "max_line_length",
               label   = "Max line length",
               hint    = "0 disables the cap.",
               default = tonumber(section.keys.max_line_length) or 0,
               min     = 0, max = 1000 },
           } }
end

local function section_cards(idx)
  local section = state.cfg.sections[idx]
  if not section then return root_cards() end
  return {
    section_pattern_card(idx, section),
    encoding_card(section),
    indentation_card(section),
    whitespace_card(section),
  }
end

local function structured_children()
  if state.selected == ROOT_NODE_VALUE then return root_cards() end
  local idx = selected_section_index()
  if idx then return section_cards(idx) end
  return root_cards()
end

-- ── Content (right pane) — Raw mode ────────────────────────────────────────

local function raw_children()
  return {
    { type    = "alert",
      variant = "info",
      text    = "Saved verbatim. Switch back to Tree to re-parse through "
             .. "the form." },
    { type        = "editor",
      name        = "raw",
      label       = ".editorconfig (raw)",
      -- `.editorconfig` is grammatically a `.properties` superset: key=value,
      -- `#` comments, line-oriented. The properties grammar gives us
      -- highlighting for free — `[section]` headers fall through as plain text.
      language    = "properties",
      height      = 500,
      default     = parser.serialise(state.cfg),
      line_numbers = true },
  }
end

-- ── Top-level nodes ────────────────────────────────────────────────────────

local function studio_nodes()
  return {
    -- View segmented control. Driven via `show_if` on the two bodies
    -- below — no actions.change needed, the swap is purely reactive.
    { type     = "row",
      align    = "center",
      gap      = 16,
      children = {
        { type    = "paragraph",
          content = "View",
          variant = "caption" },
        { type       = "radio",
          name       = "raw_mode",
          inline     = true,
          appearance = "segment",
          size       = "sm",
          default    = "tree",
          options    = {
            { value = "tree", label = "Tree" },
            { value = "raw",  label = "Raw" },
          },
        },
      },
    },
    { type = "divider" },

    -- Tree branch.
    { type    = "container",
      show_if = { field = "raw_mode", eq = "tree" },
      children = {
        { type             = "tree_layout",
          id               = "egd-layout",
          nav_width        = "260px",
          nav_collapsible  = true,
          nav_children     = nav_children(),
          content_children = structured_children(),
        },
      },
    },

    -- Raw branch.
    { type    = "container",
      show_if = { field = "raw_mode", eq = "raw" },
      children = raw_children(),
    },
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

  -- Empty file = first-time `.editorconfig`: seed with sensible UTF-8 + LF
  -- defaults so the user has something worth Save'ing on first open.
  if #state.cfg.sections == 0 then state.cfg = default_cfg_for_new_file() end

  arbor.ui.form({
    title         = ".editorconfig - Encoding Guardian",
    width         = "960px",
    height        = "680px",
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
    if ctx.raw_mode == "raw" then save_raw_mode(ctx)
    else                          save_structured_mode(ctx)
    end
    arbor.notify{ message = ".editorconfig saved.", level = "success" }
    pcall(function() arbor.ui.form.close() end)
  end)
end

return M
