-- toml-studio / main.lua
--
-- Two entry points to the TOML Studio modal (rendered host-side, backed
-- by toml_edit on the Rust side — preserves comments and formatting
-- losslessly):
--
--   · "Open TOML file in Studio…" → arbor.ui.pick_file → arbor.toml_studio.open{ path = … }
--   · "Paste TOML in Studio…"      → small form with a textarea → arbor.toml_studio.open{ text = … }
--
-- Everything else (parse, lazy tree, JSONPath query, pretty / text view,
-- copy buttons, save) lives on the host side. This plugin is essentially a
-- launcher — same design as ron-studio / json-studio.

local function open_file_picker()
  arbor.ui.pick_file({
    mode         = "file",
    title        = "Open TOML file in Studio",
    extensions   = { "toml" },
    action       = "toml-studio:on_file_picked",
  })
end

arbor.events.on("toml-studio:on_file_picked", function(ctx)
  local path = ctx and ctx.path or ""
  if path == "" then return end -- user cancelled
  arbor.toml_studio.open({ path = path })
end)

local function open_paste_form()
  arbor.ui.form({
    title         = "Paste TOML in Studio",
    width         = "640px",
    height        = "520px",
    submit_label  = "Open in Studio",
    submit_action = "toml-studio:on_pasted",
    nodes = {
      { type = "label", text = "Paste a TOML document below. Comments and inline formatting will be preserved when you save." },
      { type = "textarea", name = "text",
        label    = "TOML",
        rows     = 18,
        placeholder = '# comment\nkey = "value"\n\n[section]\nnested = 42\n',
        required = true,
      },
      { type = "input", name = "title",
        label = "Title",
        placeholder = "scratch",
        hint  = "Shown in the modal header. Optional — defaults to 'TOML Studio'.",
      },
    },
  })
end

arbor.events.on("toml-studio:on_pasted", function(ctx)
  local v = ctx and ctx.values or {}
  local text  = (v.text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local title = v.title
  if title == "" then title = nil end
  if text == "" then
    arbor.notify{ message = "No TOML pasted.", level = "warning" }
    return
  end
  arbor.toml_studio.open({ text = text, title = title })
end)

arbor.events.on("on_plugin_load", function(_ctx)
  arbor.command.register({
    id          = "open-file",
    title       = "Open TOML file in Studio…",
    description = "Pick a .toml file and explore it as a lazy tree with JSONPath query. Edits are lossless — comments and formatting survive a round-trip.",
    icon        = "FileText",
    group       = "TOML Studio",
  })
  arbor.command.register({
    id          = "paste",
    title       = "Paste TOML in Studio…",
    description = "Paste a TOML document and open it in the Studio modal.",
    icon        = "ClipboardPaste",
    group       = "TOML Studio",
  })
  arbor.log.info("toml-studio ready")
end)

arbor.events.on("command:open-file", function(_) open_file_picker() end)
arbor.events.on("command:paste",     function(_) open_paste_form() end)
