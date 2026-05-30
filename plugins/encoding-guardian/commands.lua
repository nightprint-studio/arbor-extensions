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

local function clean_modal_nodes(result)
  return {
    { type = "paragraph",
      text = string.format(
        "Scanned %d files. No mojibake, charset or EOL issues found.",
        result.scanned
      ) },
  }
end

local function offender_rows(result)
  local rows = {}
  for _, hit in ipairs(result.hits) do
    rows[#rows + 1] = {
      file   = hit.path,
      issues = table.concat(hit.problems, "; "),
    }
  end
  return rows
end

local function offender_modal_nodes(result)
  return {
    { type = "paragraph",
      text = string.format(
        "%d file(s) failed checks out of %d scanned%s.",
        #result.hits, result.scanned,
        result.truncated and " (truncated)" or ""
      ) },
    { type = "table",
      name = "offenders",
      columns = {
        { key = "file",   label = "File",   width = "2fr" },
        { key = "issues", label = "Issues", width = "3fr" },
      },
      default = offender_rows(result),
    },
    { type = "paragraph",
      text = "Click \"Fix mojibake\" to auto-repair the known sequences. "
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
    width         = "720px",
    height        = "560px",
    nodes         = clean and clean_modal_nodes(result) or offender_modal_nodes(result),
    hide_submit   = clean,
    submit_label  = "Fix mojibake",
    submit_action = "egd:fix_now",
    cancel_label  = "Close",
  })
end

-- ── Bulk fix ───────────────────────────────────────────────────────────────

local function fix_one_file(repo, hit)
  local abs    = arbor.fs.join(repo, hit.path)
  local body   = arbor.fs.read(abs)
  if not body then return 0 end
  local new_body, fixed = mojibake.fix(body)
  if fixed == 0 then return 0 end
  arbor.fs.write(abs, new_body)
  return fixed
end

local function run_fix()
  local result, err = scan.run()
  if not result then
    arbor.notify{ message = "Scan failed: " .. tostring(err), level = "error" }
    return
  end
  local repo = arbor.repo.current()
  if not repo then
    arbor.notify{ message = "No active repository.", level = "warning" }
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
    local result, err = scan.run()
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
