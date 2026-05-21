-- yaml-studio / main.lua
--
-- Two entry points to the YAML Studio modal (rendered host-side, backed
-- by serde_yml on the Rust side — read-only navigation in Phase 5.a;
-- lossless edit lands in 5.b):
--
--   · "Open YAML file in Studio…" → arbor.ui.pick_file → arbor.yaml_studio.open{ path = … }
--   · "Paste YAML in Studio…"     → small form with a textarea → arbor.yaml_studio.open{ text = … }
--
-- Everything else (parse, lazy tree, JSONPath query, pretty / text view,
-- copy buttons) lives on the host side. This plugin is essentially a
-- launcher — same design as ron-studio / json-studio / toml-studio.

local function open_file_picker()
  arbor.ui.pick_file({
    mode         = "file",
    title        = "Open YAML file in Studio",
    extensions   = { "yaml", "yml" },
    action       = "yaml-studio:on_file_picked",
  })
end

arbor.events.on("yaml-studio:on_file_picked", function(ctx)
  local path = ctx and ctx.path or ""
  if path == "" then return end -- user cancelled
  arbor.yaml_studio.open({ path = path })
end)

local function open_paste_form()
  arbor.ui.form({
    title         = "Paste YAML in Studio",
    width         = "640px",
    height        = "520px",
    submit_label  = "Open in Studio",
    submit_action = "yaml-studio:on_pasted",
    nodes = {
      { type = "label", text = "Paste a YAML document below. Phase 5.a is read-only — save / edit affordances arrive in a later build." },
      { type = "textarea", name = "text",
        label    = "YAML",
        rows     = 18,
        placeholder = "# comment\nkey: value\n\nsection:\n  nested: 42\n",
        required = true,
      },
      { type = "input", name = "title",
        label = "Title",
        placeholder = "scratch",
        hint  = "Shown in the modal header. Optional — defaults to 'YAML Studio'.",
      },
    },
  })
end

arbor.events.on("yaml-studio:on_pasted", function(ctx)
  local v = ctx and ctx.values or {}
  local text  = (v.text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local title = v.title
  if title == "" then title = nil end
  if text == "" then
    arbor.notify{ message = "No YAML pasted.", level = "warning" }
    return
  end
  arbor.yaml_studio.open({ text = text, title = title })
end)

arbor.events.on("on_plugin_load", function(_ctx)
  arbor.command.register({
    id          = "open-file",
    title       = "Open YAML file in Studio…",
    description = "Pick a .yaml / .yml file and explore it as a lazy tree with JSONPath query. Read-only in Phase 5.a.",
    icon        = "FileText",
    group       = "YAML Studio",
  })
  arbor.command.register({
    id          = "paste",
    title       = "Paste YAML in Studio…",
    description = "Paste a YAML document and open it in the Studio modal.",
    icon        = "ClipboardPaste",
    group       = "YAML Studio",
  })
  arbor.log.info("yaml-studio ready (read-only Phase 5.a)")
end)

arbor.events.on("command:open-file", function(_) open_file_picker() end)
arbor.events.on("command:paste",     function(_) open_paste_form() end)
