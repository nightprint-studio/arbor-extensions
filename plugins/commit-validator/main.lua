-- commit-validator/main.lua
--
-- Lints commit messages against Conventional Commits and a small set of
-- extra rules (ticket key, subject length, body line wrap). Runs in two
-- modes:
--
--   · STRICT  (default) → on_pre_commit returns a reason string and the
--                          host aborts the commit before it's created.
--   · LENIENT (strict=false) → on_pre_commit allows the commit through;
--                              we still surface the warning via on_commit
--                              after the fact.
--
-- Settings (global):
--   enabled                boolean  master switch (default true)
--   strict                 boolean  block on violation (default true)
--   extra_types            string   comma-separated additional CC types
--   require_scope          boolean  scope mandatory in subject
--   require_ticket         boolean  ticket key must appear in message
--   ticket_pattern         string   Lua pattern; default catches ABC-123
--   max_subject_length     number   0 = disabled, default 72
--   body_max_line_length   number   0 = disabled, default 100

local DEFAULT_TYPES = {
  "feat", "fix", "docs", "style", "refactor",
  "perf", "test", "build", "ci", "chore", "revert",
}

local DEFAULT_TICKET_PATTERN     = "%f[%w]([A-Z][A-Z0-9]+%-%d+)%f[%W]"
local DEFAULT_MAX_SUBJECT_LENGTH = 72
local DEFAULT_BODY_MAX_LINE_LEN  = 100

-- ─────────────────────────────────────────────────────────────────────────
-- Settings access (with defaults)
-- ─────────────────────────────────────────────────────────────────────────

local function get_bool(key, default)
  local v = arbor.settings.global.get(key)
  if v == nil then return default end
  return v and true or false
end

local function get_num(key, default)
  local v = arbor.settings.global.get(key)
  if v == nil or v == "" then return default end
  local n = tonumber(v)
  return n or default
end

local function get_str(key, default)
  local v = arbor.settings.global.get(key)
  if v == nil or v == "" then return default end
  return tostring(v)
end

-- ─────────────────────────────────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────────────────────────────────

local function split(str, sep)
  local result = {}
  for part in str:gmatch("[^" .. sep .. "]+") do
    result[#result + 1] = part:match("^%s*(.-)%s*$")
  end
  return result
end

local function get_allowed_types()
  local types = {}
  for _, t in ipairs(DEFAULT_TYPES) do types[t] = true end
  local extra = get_str("extra_types", "")
  if extra ~= "" then
    for _, t in ipairs(split(extra, ",")) do
      if t ~= "" then types[t] = true end
    end
  end
  return types
end

-- ─────────────────────────────────────────────────────────────────────────
-- Validation rules
-- ─────────────────────────────────────────────────────────────────────────

-- Returns `nil` when valid, otherwise an error string. Each rule is
-- self-contained so we can compose them and surface every failure at
-- once instead of bailing on the first.
local function check_format(msg)
  if msg:match("^Merge ")    then return nil end
  if msg:match("^Revert \"") then return nil end

  local subject = msg:match("^([^\n]*)") or msg

  local typ, scope, _, _ =
    subject:match("^(%a[%a%d%-]*)%(([^)]+)%)(!?):%s*(.+)$")
  if not typ then
    typ, _, _ = subject:match("^(%a[%a%d%-]*)(!?):%s*(.+)$")
    scope = nil
  end
  if not typ then
    return "Invalid format. Expected: <type>[(<scope>)]: <description>"
        .. " — got: " .. subject
  end

  local allowed = get_allowed_types()
  if not allowed[typ:lower()] then
    local list = {}
    for t in pairs(allowed) do list[#list + 1] = t end
    table.sort(list)
    return "Unknown type '" .. typ .. "'. Allowed: " .. table.concat(list, ", ")
  end

  if get_bool("require_scope", false) and (not scope or scope == "") then
    return "Scope is required. Use: " .. typ .. "(scope): description"
  end

  return nil
end

local function check_subject_length(msg)
  local max = get_num("max_subject_length", DEFAULT_MAX_SUBJECT_LENGTH)
  if max <= 0 then return nil end
  local subject = msg:match("^([^\n]*)") or msg
  if #subject > max then
    return string.format("Subject is %d chars long; max is %d.", #subject, max)
  end
  return nil
end

local function check_ticket(msg)
  if not get_bool("require_ticket", false) then return nil end
  local pat = get_str("ticket_pattern", DEFAULT_TICKET_PATTERN)
  if msg:match(pat) then return nil end
  return "Commit message must reference a ticket key (pattern: " .. pat .. ")."
end

local function check_body_wrap(msg)
  local max = get_num("body_max_line_length", DEFAULT_BODY_MAX_LINE_LEN)
  if max <= 0 then return nil end
  -- Skip the subject (first line) and the blank-line separator. Anything
  -- after that is body — we flag the first overlong line we see and
  -- include its 1-based body line number for context.
  local lines = {}
  for line in (msg .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  for i = 3, #lines do
    if #lines[i] > max then
      return string.format(
        "Body line %d is %d chars long; max is %d. (Wrap your message body.)",
        i - 2, #lines[i], max
      )
    end
  end
  return nil
end

-- Aggregate every rule. Returns `nil` when all pass, or a multi-line
-- string listing every failure so the user fixes them in one go.
local function validate(msg)
  if not msg or msg == "" then return "Commit message is empty." end

  local errors = {}
  local function push(e) if e then errors[#errors + 1] = "• " .. e end end

  push(check_format(msg))
  push(check_subject_length(msg))
  push(check_ticket(msg))
  push(check_body_wrap(msg))

  if #errors == 0 then return nil end
  return table.concat(errors, "\n")
end

-- ─────────────────────────────────────────────────────────────────────────
-- Lifecycle
-- ─────────────────────────────────────────────────────────────────────────

arbor.events.on("on_plugin_load", function(ctx)
  -- Register the plugin-settings panel up-front. The registration is
  -- what surfaces the gear icon next to the plugin row in the Plugin
  -- Manager — without it there is no entry point for plugin-wide
  -- settings beyond the legacy hamburger menu item. on_load fires every
  -- time the modal opens so we can re-contribute fresh defaults.
  arbor.ui.settings.panel({
    id           = "main",
    title        = "Commit Validator — Settings",
    icon         = "CheckCircle",
    width        = "640px",
    height       = "560px",
    submit_label = "Save",
    cancel_label = "Close",
    on_load      = "validator:settings_refresh",
    -- Single host-level save: receives the union of every section's
    -- fields under `ctx.sections["commit-validator"]`. Sections don't
    -- declare their own on_save (otherwise the modal would also fire
    -- per-section saves with partial slices).
    on_save      = "validator:save_config",
  })
  arbor.log.info("commit-validator ready (api_version=" .. tostring(ctx.api_version) .. ")")
end)

-- ─────────────────────────────────────────────────────────────────────────
-- Hooks
-- ─────────────────────────────────────────────────────────────────────────

-- Strict mode → return the error string from on_pre_commit so the host
-- aborts the commit (see `commit()` in stage_commands.rs which calls
-- host.collect_veto). Lenient mode → fall through to on_commit and surface
-- the failure via a warning toast after the fact.
arbor.events.on("on_pre_commit", function(ctx)
  if get_bool("enabled", true) == false then return end
  if get_bool("strict",  true)  == false then return end

  local err = validate(ctx.message or "")
  if not err then return end

  arbor.log.warn("blocked commit: " .. err:gsub("\n", " | "))
  return "commit-validator rejected the message:\n" .. err
end)

arbor.events.on("on_commit", function(ctx)
  if get_bool("enabled", true) == false then return end

  local msg = ctx.message or ""
  local err = validate(msg)

  if not err then
    arbor.notify{ message = "✓ Commit message valid.", level = "success", persist = false }
    return
  end

  -- Reaching here in strict mode would mean on_pre_commit somehow let an
  -- invalid commit through (e.g. plugin reloaded between the two hooks).
  -- We still surface the issue so the user can amend.
  local strict = get_bool("strict", true)
  arbor.notify{
    title   = strict and "Commit was created despite errors" or "Commit message issues",
    message = err,
    level   = strict and "error" or "warning",
  }
end)

-- ─────────────────────────────────────────────────────────────────────────
-- Context-menu: validate any selected commit
-- ─────────────────────────────────────────────────────────────────────────

arbor.ui.add_context_menu_item({
  target = "commit",
  label  = "✓ Validate Commit Message",
  action = "validator:check_commit",
  icon   = "CheckCircle",
})

arbor.events.on("validator:check_commit", function(ctx)
  local msg = ctx.message or ""
  if msg == "" then
    arbor.notify{ message = "Could not read commit message.", level = "warning" }
    return
  end
  local err = validate(msg)
  if not err then
    arbor.notify{ message = "✓ Commit message valid.", level = "success" }
  else
    arbor.notify{ title = "Commit message issues", message = err, level = "error" }
  end
end)

-- ─────────────────────────────────────────────────────────────────────────
-- Settings panel — gear icon next to the plugin row in Plugin Manager
-- ─────────────────────────────────────────────────────────────────────────
--
-- We contribute one category and four sections to the panel registered
-- in on_plugin_load. Sections use `card = true` so each group gets a
-- visually-grouped card with its own border — without that the panel
-- looks like an undifferentiated list of inputs and feels "flat".
-- on_save fires once for the whole panel; we read every namespaced
-- field out of `ctx` and persist it.

-- Names MUST match the contribution points the panel registers — see
-- settings_form.rs::install_panel which forces `<plugin>:settings:category`
-- and `<plugin>:settings:section` (using the plugin name verbatim, NOT
-- a short alias like "validator").
local CATEGORY_POINT = "commit-validator:settings:category"
local SECTION_POINT  = "commit-validator:settings:section"

local function settings_refresh()
  arbor.ui.contribute(CATEGORY_POINT, {
    id       = "general",
    priority = 100,
    payload  = {
      label       = "Validation",
      icon        = "CheckCircle",
      priority    = 100,
      description = "Commit Validator — message-linting rules",
    },
  })

  arbor.ui.contribute(SECTION_POINT, {
    id       = "general",
    priority = 100,
    payload  = {
      category = "general",
      label    = "General",
      card     = true,
      nodes = {
        { type = "checkbox", name = "enabled",
          label   = "Enable validation",
          default = get_bool("enabled", true) },
        { type = "checkbox", name = "strict",
          label   = "Strict mode — block invalid commits via on_pre_commit",
          default = get_bool("strict", true),
          hint    = "When off, the validator only shows a post-commit warning." },
      },
    },
  })

  arbor.ui.contribute(SECTION_POINT, {
    id       = "conventional",
    priority = 200,
    payload  = {
      category = "general",
      label    = "Conventional Commits",
      card     = true,
      nodes = {
        { type = "checkbox", name = "require_scope",
          label   = "Require scope",
          default = get_bool("require_scope", false) },
        { type = "text", name = "extra_types",
          label       = "Additional types (comma-separated)",
          placeholder = "e.g. wip, hotfix",
          default     = get_str("extra_types", "") },
      },
    },
  })

  arbor.ui.contribute(SECTION_POINT, {
    id       = "ticket",
    priority = 300,
    payload  = {
      category = "general",
      label    = "Ticket reference",
      card     = true,
      nodes = {
        { type = "checkbox", name = "require_ticket",
          label   = "Require a ticket key in the message",
          default = get_bool("require_ticket", false),
          hint    = "Searches the whole message (subject + body) for the pattern below." },
        { type = "text", name = "ticket_pattern",
          label       = "Ticket regex (Lua pattern)",
          default     = get_str("ticket_pattern", DEFAULT_TICKET_PATTERN),
          placeholder = DEFAULT_TICKET_PATTERN,
          hint        = "Default catches ABC-123 / FOO-9 (Linear, Jira, Shortcut)." },
      },
    },
  })

  arbor.ui.contribute(SECTION_POINT, {
    id       = "length",
    priority = 400,
    payload  = {
      category = "general",
      label    = "Length limits",
      card     = true,
      nodes = {
        { type = "number", name = "max_subject_length",
          label   = "Max subject length (0 disables)",
          default = get_num("max_subject_length", DEFAULT_MAX_SUBJECT_LENGTH),
          min     = 0, max = 200 },
        { type = "number", name = "body_max_line_length",
          label   = "Max body line length (0 disables)",
          default = get_num("body_max_line_length", DEFAULT_BODY_MAX_LINE_LEN),
          min     = 0, max = 500 },
      },
    },
  })
end

arbor.events.on("validator:settings_refresh", function(_ctx) settings_refresh() end)

arbor.events.on("validator:save_config", function(ctx)
  -- Panel-level on_save delivers `{ sections = { ["commit-validator"] =
  -- { ...all_field_values } } }`. Pull our own slice out (defensive
  -- fallback to a flat `ctx` keeps the handler usable from a section-
  -- level on_save too, in case we ever split the panel later).
  local fields = (ctx.sections and ctx.sections["commit-validator"]) or ctx or {}

  arbor.settings.global.set("enabled",              fields.enabled)
  arbor.settings.global.set("strict",                fields.strict)
  arbor.settings.global.set("require_scope",         fields.require_scope)
  arbor.settings.global.set("extra_types",           fields.extra_types)
  arbor.settings.global.set("require_ticket",        fields.require_ticket)
  arbor.settings.global.set("ticket_pattern",        fields.ticket_pattern)
  arbor.settings.global.set("max_subject_length",    tostring(fields.max_subject_length or ""))
  arbor.settings.global.set("body_max_line_length",  tostring(fields.body_max_line_length or ""))
  arbor.notify{ message = "Commit validator settings saved.", level = "success" }
end)
