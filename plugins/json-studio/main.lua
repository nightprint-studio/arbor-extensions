-- json-studio / main.lua
--
-- Two entry points to the JSON Studio modal (rendered host-side, backed
-- by simd-json):
--
--   · "Open JSON file in Studio…"   → arbor.ui.pick_file → arbor.json_studio.open{ path = … }
--   · "Paste JSON in Studio…"        → small form with a textarea → arbor.json_studio.open{ text = … }
--
-- Everything else (parse, lazy tree, JSONPath query, pretty/text view,
-- copy buttons) lives on the host side. This plugin is essentially a
-- launcher — by design, so when the planned WASM plugin runtime lands we
-- can move the parser into the plugin's own module and shrink the host
-- API surface back to nothing JSON-specific. See
-- memory/project_json_studio_plugin.md.

local function open_file_picker()
  arbor.ui.pick_file({
    mode         = "file",
    title        = "Open JSON / JSONC file in Studio",
    -- Phase 3.d: `.jsonc` joins the picker. The host backend detects
    -- the extension at parse time and picks lenient vs strict — same
    -- single plugin handles both kinds (FROZEN F14).
    extensions   = { "json", "jsonc", "jsonl", "ndjson", "geojson", "har" },
    action       = "json-studio:on_file_picked",
  })
end

arbor.events.on("json-studio:on_file_picked", function(ctx)
  local path = ctx and ctx.path or ""
  if path == "" then return end -- user cancelled
  arbor.json_studio.open({ path = path })
end)

local function open_paste_form()
  arbor.ui.form({
    title         = "Paste JSON in Studio",
    width         = "640px",
    height        = "520px",
    submit_label  = "Open in Studio",
    submit_action = "json-studio:on_pasted",
    nodes = {
      { type = "label", text = "Paste a JSON document below. Anything goes — small dictionaries, multi-megabyte API responses, the lot." },
      { type = "textarea", name = "text",
        label    = "JSON",
        rows     = 18,
        placeholder = '{ "hello": "world" }',
        required = true,
      },
      { type = "input", name = "title",
        label = "Title",
        placeholder = "scratch",
        hint  = "Shown in the modal header. Optional — defaults to 'JSON Studio'.",
      },
    },
  })
end

arbor.events.on("json-studio:on_pasted", function(ctx)
  local v = ctx and ctx.values or {}
  local text  = (v.text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local title = v.title
  if title == "" then title = nil end
  if text == "" then
    arbor.notify{ message = "No JSON pasted.", level = "warning" }
    return
  end
  arbor.json_studio.open({ text = text, title = title })
end)

arbor.events.on("on_plugin_load", function(_ctx)
  arbor.command.register({
    id          = "open-file",
    title       = "Open JSON / JSONC file in Studio…",
    description = "Pick a .json or .jsonc file and explore it as a lazy tree (or pretty-printed text) with JSONPath query. Files larger than 1 MB open in stream mode (navigation-only).",
    icon        = "FileJson",
    group       = "JSON Studio",
  })
  arbor.command.register({
    id          = "paste",
    title       = "Paste JSON in Studio…",
    description = "Paste a JSON document and open it in the Studio modal.",
    icon        = "ClipboardPaste",
    group       = "JSON Studio",
  })
  arbor.log.info("json-studio ready")
end)

arbor.events.on("command:open-file", function(_) open_file_picker() end)
arbor.events.on("command:paste",     function(_) open_paste_form() end)
