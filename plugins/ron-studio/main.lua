-- ron-studio / main.lua
--
-- Two entry points to the RON Studio modal (rendered host-side, backed by
-- the `ron` and `syn` Rust crates):
--
--   · "Open RON file in Studio…" → arbor.ui.pick_file → arbor.ron_studio.open{ path = … }
--   · "Paste RON in Studio…"      → small form with a textarea → arbor.ron_studio.open{ text = … }
--
-- Everything else (parse, lazy tree, schema loading, diff, save, save-as,
-- format, RON↔JSON, search) lives on the host side and inside
-- `RonStudioModal.svelte`. This plugin is purely a launcher — keeping it
-- thin is intentional so the eventual migration to a subprocess-based
-- plugin runtime is a small surgical change.

local function open_file_picker()
  arbor.ui.pick_file({
    mode       = "file",
    title      = "Open RON file in Studio",
    extensions = { "ron" },
    action     = "ron-studio:on_file_picked",
  })
end

arbor.events.on("ron-studio:on_file_picked", function(ctx)
  local path = ctx and ctx.path or ""
  if path == "" then return end
  arbor.ron_studio.open({ path = path })
end)

local function open_paste_form()
  arbor.ui.form({
    title         = "Paste RON in Studio",
    width         = "640px",
    height        = "520px",
    submit_label  = "Open in Studio",
    submit_action = "ron-studio:on_pasted",
    nodes = {
      { type = "label", text = "Paste a RON document below. Anything goes — small config files, multi-MB serialised game state, the lot." },
      { type = "textarea", name = "text",
        label       = "RON",
        rows        = 18,
        placeholder = '(\n  name: "my-config",\n  port: 8080,\n  enabled: true,\n)',
        required    = true,
      },
      { type = "input", name = "title",
        label       = "Title",
        placeholder = "scratch",
        hint        = "Shown in the modal header. Optional — defaults to 'RON Studio'.",
      },
    },
  })
end

arbor.events.on("ron-studio:on_pasted", function(ctx)
  local v = ctx and ctx.values or {}
  local text  = (v.text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local title = v.title
  if title == "" then title = nil end
  if text == "" then
    arbor.notify{ message = "No RON pasted.", level = "warning" }
    return
  end
  arbor.ron_studio.open({ text = text, title = title })
end)

arbor.events.on("on_plugin_load", function(_ctx)
  arbor.command.register({
    id          = "open-file",
    title       = "Open RON file in Studio…",
    description = "Pick a .ron file and explore it as a tree, edit text directly, diff against the original, save in place, or convert to JSON.",
    icon        = "FileCode",
    group       = "RON Studio",
  })
  arbor.command.register({
    id          = "paste",
    title       = "Paste RON in Studio…",
    description = "Paste a RON document and open it in the Studio modal.",
    icon        = "ClipboardPaste",
    group       = "RON Studio",
  })
  arbor.log.info("ron-studio ready")
end)

arbor.events.on("command:open-file", function(_) open_file_picker() end)
arbor.events.on("command:paste",     function(_) open_paste_form() end)
