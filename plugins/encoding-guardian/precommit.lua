-- precommit.lua — `on_pre_commit` veto handler.
--
-- The hook is OPT-IN per project: nothing happens unless the user has
-- ticked "Enable pre-commit encoding check" for the active repo. When it
-- does fire, a non-empty return string aborts the commit (the host shows
-- it to the user verbatim).

local settings = require("settings")
local scan     = require("scan")

local M = {}

local MAX_FILES_IN_MESSAGE = 5

local function format_veto(result)
  local lines = {
    string.format("encoding-guardian: %d file(s) failed checks.", #result.hits),
  }
  for i = 1, math.min(MAX_FILES_IN_MESSAGE, #result.hits) do
    local hit = result.hits[i]
    lines[#lines + 1] = "  - " .. hit.path .. " - " .. table.concat(hit.problems, "; ")
  end
  if #result.hits > MAX_FILES_IN_MESSAGE then
    lines[#lines + 1] = string.format(
      "  ...and %d more.", #result.hits - MAX_FILES_IN_MESSAGE
    )
  end
  lines[#lines + 1] = "Run `Encoding Guardian: Scan project` to inspect, then "
                  .. "`Encoding Guardian: Fix mojibake` to repair."
  return table.concat(lines, "\n")
end

-- Register the veto handler. Called once from main.lua.
function M.register()
  arbor.events.on("on_pre_commit", function(_ctx)
    if not settings.precommit_enabled_for_project() then return end

    -- Scope the check to the staged set — that's the actual content the
    -- commit will carry. Avoids vetoing on garbage left over in the
    -- working tree that the user hasn't `git add`-ed.
    local result, err = scan.run_staged()
    if not result then
      arbor.log.warn("encoding-guardian scan failed: " .. tostring(err))
      return
    end
    if #result.hits == 0 then return end
    return format_veto(result)
  end)
end

return M
