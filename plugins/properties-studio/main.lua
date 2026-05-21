-- properties-studio / main.lua
--
-- Two entry points to the .properties Studio modal (rendered host-side,
-- backed by a custom line parser on the Rust side — lossless edit, every
-- byte of the original source survives a round-trip):
--
--   · "Open .properties file in Studio…" → arbor.ui.pick_file → arbor.properties_studio.open{ path = … }
--   · "Paste .properties in Studio…"     → small form with a textarea → arbor.properties_studio.open{ text = … }
--
-- Everything else (parse, lazy tree, JSONPath query, lossless save, F12
-- rename, F13 bulk edit, JSON Schema sidecar) lives on the host side.
-- This plugin is a launcher — same design as ron / json / toml / yaml
-- studio.

local function open_file_picker()
  arbor.ui.pick_file({
    mode         = "file",
    title        = "Open .properties file in Studio",
    extensions   = { "properties" },
    action       = "properties-studio:on_file_picked",
  })
end

arbor.events.on("properties-studio:on_file_picked", function(ctx)
  local path = ctx and ctx.path or ""
  if path == "" then return end -- user cancelled
  arbor.properties_studio.open({ path = path })
end)

local function open_paste_form()
  arbor.ui.form({
    title         = "Paste .properties in Studio",
    width         = "640px",
    height        = "520px",
    submit_label  = "Open in Studio",
    submit_action = "properties-studio:on_pasted",
    nodes = {
      { type = "label", text = "Paste a .properties document below. Comments (# / !), continuation backslashes and Unicode escapes are preserved on save." },
      { type = "textarea", name = "text",
        label    = ".properties",
        rows     = 18,
        placeholder = "# comment\nserver.port=8080\nserver.host=localhost\n\nservice.db=db.url\n",
        required = true,
      },
      { type = "input", name = "title",
        label = "Title",
        placeholder = "scratch",
        hint  = "Shown in the modal header. Optional — defaults to 'Properties Studio'.",
      },
    },
  })
end

arbor.events.on("properties-studio:on_pasted", function(ctx)
  local v = ctx and ctx.values or {}
  local text  = (v.text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local title = v.title
  if title == "" then title = nil end
  if text == "" then
    arbor.notify{ message = "No .properties pasted.", level = "warning" }
    return
  end
  arbor.properties_studio.open({ text = text, title = title })
end)

arbor.events.on("on_plugin_load", function(_ctx)
  arbor.command.register({
    id          = "open-file",
    title       = "Open .properties file in Studio…",
    description = "Pick a .properties file and explore it as a lazy dotted-key tree with JSONPath query, lossless edit and cross-refs.",
    icon        = "FileText",
    group       = ".properties Studio",
  })
  arbor.command.register({
    id          = "paste",
    title       = "Paste .properties in Studio…",
    description = "Paste a .properties document and open it in the Studio modal.",
    icon        = "ClipboardPaste",
    group       = ".properties Studio",
  })
  arbor.log.info("properties-studio ready (Phase 6)")
end)

arbor.events.on("command:open-file", function(_) open_file_picker() end)
arbor.events.on("command:paste",     function(_) open_paste_form() end)
