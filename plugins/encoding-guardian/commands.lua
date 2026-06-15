-- commands.lua — Command Palette entries + scan-result modal + bulk fix.
--
-- Three commands live here:
--
--   * `command:scan` — runs a scan and opens the result modal.
--   * `command:fix`  — re-runs a scan and rewrites every file containing
--                       a known mojibake sequence. No confirmation: the
--                       repair is idempotent, only known patterns are
--                       touched, and the user can git-diff the result.
--   * `command:editorconfig` — handled by editorconfig.studio; this file
--                       just wires the palette entry to that module.
--
-- The fix flow is shared between the palette entry and the scan modal's
-- primary action so both paths take the same route.

local mojibake = require("mojibake")
local scan     = require("scan")

local M = {}

-- ── Scan-result modal ──────────────────────────────────────────────────────

-- Surfaces the *effective* per-project contract the scan ran with, so it's
-- obvious which charset / EOL produced the verdict (and that the per-project
-- settings were actually picked up).
local function config_banner(result)
  return {
    type    = "alert",
    variant = "info",
    text    = string.format(
      "Charset: %s · EOL: %s",
      result.charset or "utf-8", result.eol or "any"
    ),
  }
end

local function summary_counters(result)
  local issues = #result.hits
  return {
    type = "counter_grid",
    items = {
      { key = "scanned", label = "Files scanned", value = result.scanned },
      { key = "issues",  label = "With issues",   value = issues,
        color = issues > 0 and "var(--error)" or "var(--success)",
        empty = issues == 0 },
      { key = "clean",   label = "Clean",         value = result.scanned - issues,
        color = "var(--success)" },
    },
  }
end

local function clean_modal_nodes(result)
  return {
    config_banner(result),
    summary_counters(result),
    { type = "paragraph",
      text = "No mojibake, charset or EOL issues found." },
  }
end

-- Split a relative path into (basename, folder). The filename is what the
-- user scans for, so it gets its own leading column; the folder is secondary
-- context. Forward and back slashes both count as separators.
local function split_path(rel)
  local dir, name = rel:match("^(.*)[/\\]([^/\\]+)$")
  if not name then return rel, "" end
  return name, dir
end

local function offender_rows(result)
  local rows = {}
  for _, hit in ipairs(result.hits) do
    local name, folder = split_path(hit.path)
    rows[#rows + 1] = {
      file   = name,
      folder = folder,
      issues = table.concat(hit.problems, " · "),
    }
  end
  return rows
end

local function offender_modal_nodes(result)
  return {
    config_banner(result),
    summary_counters(result),
    -- No `height`: let the table grow and the modal own the single scroll.
    -- Filename leads (what you scan for); folder is secondary context.
    { type = "data_table",
      columns = {
        { key = "file",   label = "File",   width = "minmax(160px, 1.4fr)", kind = "code", sortable = true },
        { key = "folder", label = "Folder", width = "minmax(140px, 1.6fr)", kind = "text", sortable = true },
        { key = "issues", label = "Issues", width = "minmax(180px, 2fr)",   kind = "text" },
      },
      rows     = offender_rows(result),
      row_key  = "file",
      empty    = "No offenders.",
    },
    { type = "paragraph",
      text = (result.truncated and "Scan hit the file cap (truncated). " or "")
          .. "Click \"Fix mojibake\" to auto-repair the known sequences. "
          .. "EOL / BOM / charset issues need a manual fix or an "
          .. "`.editorconfig` rule." },
  }
end

local function open_scan_modal(result)
  local clean = #result.hits == 0
  arbor.ui.form({
    title         = clean
                       and string.format("Encoding scan - clean (%d files scanned)",
                                          result.scanned)
                       or  string.format("Encoding scan - %d issue(s) in %d file(s)",
                                          #result.hits, #result.hits),
    width         = "920px",
    height        = "720px",
    nodes         = clean and clean_modal_nodes(result) or offender_modal_nodes(result),
    hide_submit   = clean,
    submit_label  = "Fix mojibake",
    submit_action = "egd:fix_now",
    cancel_label  = "Close",
  })
end

-- ── Progress feedback ───────────────────────────────────────────────────────
--
-- The walk + inspection are synchronous host calls; without a visible
-- operation card the command looks like a frozen no-op. The card's id is
-- plugin-scoped by the host, so a fixed key per flow is safe.

local SCAN_STEPS = {
  { key = "walk",    label = "Walking working tree" },
  { key = "inspect", label = "Checking encoding"    },
}

local function repo_label()
  local repo = arbor.repo.current()
  return repo and (repo:match("([^/\\]+)[/\\]?$")) or "repository"
end

-- Run a scan behind an operation card. Returns `(result, err)`.
local function scan_with_feedback(op_id, title)
  arbor.ui.operation.start{
    id       = op_id,
    title    = title,
    subtitle = repo_label(),
    steps    = SCAN_STEPS,
    current  = "walk",
  }
  local result, err = scan.run({
    on_step = function(key) arbor.ui.operation.set_current(op_id, key) end,
  })
  if not result then
    arbor.ui.operation.finish(op_id, { error = tostring(err) })
    return nil, err
  end
  arbor.ui.operation.update_step(op_id, "inspect", { status = "done" })
  arbor.ui.operation.finish(op_id, {
    summary = string.format("%d scanned - %d issue(s)", result.scanned, #result.hits),
  })
  return result, nil
end

-- ── Bulk fix ───────────────────────────────────────────────────────────────

local function fix_one_file(repo, hit)
  local abs    = arbor.fs.join(repo, hit.path)
  local body   = arbor.fs.read_bytes(abs)
  if not body then return 0 end
  local new_body, fixed = mojibake.fix(body)
  if fixed == 0 then return 0 end
  -- write_bytes (not write): the body was read as raw bytes and may carry
  -- non-UTF-8 sequences outside the repaired clusters; `write` would reject
  -- those. Writing verbatim preserves the file's encoding.
  arbor.fs.write_bytes(abs, new_body)
  return fixed
end

local function run_fix()
  local repo = arbor.repo.current()
  if not repo then
    arbor.notify{ message = "No active repository.", level = "warning" }
    return
  end
  local result, err = scan_with_feedback("fix", "Fix mojibake")
  if not result then
    arbor.notify{ message = "Scan failed: " .. tostring(err), level = "error" }
    return
  end

  local files_touched, sequences_fixed = 0, 0
  for _, hit in ipairs(result.hits) do
    local fixed = fix_one_file(repo, hit)
    if fixed > 0 then
      files_touched   = files_touched + 1
      sequences_fixed = sequences_fixed + fixed
    end
  end

  pcall(function() arbor.ui.form.close() end)
  arbor.notify{
    title   = "Encoding Guardian",
    message = string.format(
      "Fixed %d mojibake sequence(s) in %d file(s).",
      sequences_fixed, files_touched
    ),
    level   = sequences_fixed > 0 and "success" or "info",
  }
end

-- ── Registration ───────────────────────────────────────────────────────────

local function register_scan_command()
  arbor.command.register({
    id          = "scan",
    title       = "Encoding Guardian: Scan project",
    description = "Look for mojibake, BOM / EOL / charset mismatches across the active repo.",
    icon        = "ShieldCheck",
    group       = "Encoding Guardian",
  })
  arbor.events.on("command:scan", function(_ctx)
    if not arbor.repo.current() then
      arbor.notify{ message = "Open a repository first.", level = "warning" }
      return
    end
    local result, err = scan_with_feedback("scan", "Encoding scan")
    if not result then
      arbor.notify{ message = "Scan failed: " .. tostring(err), level = "error" }
      return
    end
    open_scan_modal(result)
  end)
end

local function register_fix_command()
  arbor.command.register({
    id          = "fix",
    title       = "Encoding Guardian: Fix mojibake",
    description = "Auto-repair every known mojibake sequence across the active repo.",
    icon        = "Wand2",
    group       = "Encoding Guardian",
  })
  arbor.events.on("command:fix",     function(_ctx) run_fix() end)
  arbor.events.on("egd:fix_now",     function(_ctx) run_fix() end)
end

function M.register()
  register_scan_command()
  register_fix_command()
end

return M
