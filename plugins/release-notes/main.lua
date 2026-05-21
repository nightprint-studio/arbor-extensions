-- release-notes / main.lua
--
-- Two-step wizard that turns a commit range into a Markdown release-notes
-- file. The plugin does NOT create a real release on the host (no tag, no
-- push, no provider API call) — it only authors the document and lets the
-- user save it wherever they want.
--
-- Flow (path-first, work-deferred — the wizard never freezes):
--   wizard submit  → release-notes:pick_destination
--                    snapshots ctx into `pending_opts`, opens save dialog
--   save picker    → release-notes:on_save_picked
--                    fires a transient "Generating…" toast, then schedules
--                    the heavy work via arbor.timer.after(50ms)
--   deferred work  → arbor.repo.commits + (optional) arbor.issues.search
--                    + build_notes + arbor.fs.write + success notification
--
-- Splitting the path-pick from the heavy work means:
--   · the wizard closes instantly on submit (no perceived freeze)
--   · the save dialog appears immediately with the user's choices intact
--   · the heavy phase runs without any modal mounted, with a progress
--     toast so the user knows something is happening

local pending_opts = nil

-- ─────────────────────────────────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────────────────────────────────

local CC_TYPE_LABELS = {
  feat     = "Features",
  fix      = "Bug Fixes",
  perf     = "Performance",
  refactor = "Refactoring",
  docs     = "Documentation",
  style    = "Styling",
  test     = "Tests",
  build    = "Build",
  ci       = "CI",
  chore    = "Chores",
  revert   = "Reverts",
}

-- Display order of CC sections. Anything missing falls back to a generic
-- "Other" bucket at the end so a typo in `type` doesn't drop the commit.
local CC_TYPE_ORDER = {
  "feat", "fix", "perf", "refactor",
  "docs", "style", "test", "build", "ci", "chore", "revert",
}

local function trim(s) return ((s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

local function parse_conventional(summary)
  -- type(scope)!: subject  |  type(scope): subject  |  type!: subject  |  type: subject
  local typ, scope, _, subject =
    summary:match("^(%a[%a%d%-]*)%(([^)]+)%)(!?):%s*(.+)$")
  if not typ then
    typ, _, subject = summary:match("^(%a[%a%d%-]*)(!?):%s*(.+)$")
  end
  if typ then
    return typ:lower(), scope, subject
  end
  return nil, nil, summary
end

-- Extract every ticket-like token in the summary. We allow the regex to
-- be customised in the wizard so projects with non-standard prefixes
-- (e.g. `BUG#1234`, `JIRA_42`) can still match. Default catches the most
-- common ALL-CAPS-DASH-N pattern (Jira / Linear / Shortcut).
local function extract_tickets(text, pattern)
  local out, seen = {}, {}
  local p = (pattern and pattern ~= "") and pattern or "%f[%w]([A-Z][A-Z0-9]+%-%d+)%f[%W]"
  for key in (text or ""):gmatch(p) do
    if not seen[key] then
      seen[key] = true
      out[#out + 1] = key
    end
  end
  return out
end

local function group_commits(commits, opts)
  local mode = opts.group_by or "type"
  local buckets = {}
  local order   = {}

  local function ensure(key, label)
    if not buckets[key] then
      buckets[key] = { label = label or key, commits = {} }
      order[#order + 1] = key
    end
  end

  if mode == "none" then
    ensure("__all__", "Changes")
    for _, c in ipairs(commits) do table.insert(buckets["__all__"].commits, c) end

  elseif mode == "author" then
    for _, c in ipairs(commits) do
      local key = c.author_name or "Unknown"
      ensure(key, key)
      table.insert(buckets[key].commits, c)
    end
    table.sort(order)

  else -- "type" — Conventional Commits
    for _, c in ipairs(commits) do
      local typ = parse_conventional(c.summary or "")
      local key = typ or "other"
      table.insert((buckets[key] or { label = CC_TYPE_LABELS[key] or "Other", commits = {} }).commits, c)
      ensure(key, CC_TYPE_LABELS[key] or "Other")
    end
    -- Sort: known order first, then anything else alphabetically.
    local known = {}
    for _, k in ipairs(CC_TYPE_ORDER) do known[k] = true end
    table.sort(order, function(a, b)
      local ai, bi = nil, nil
      for i, k in ipairs(CC_TYPE_ORDER) do
        if k == a then ai = i end
        if k == b then bi = i end
      end
      if ai and bi then return ai < bi end
      if ai then return true end
      if bi then return false end
      return a < b
    end)
  end

  return buckets, order
end

-- Best-effort issue lookup: we batch by provider implicit in the issue id
-- shape (Linear keys look like ABC-123 and Jira keys like PROJ-123 — same
-- shape, so we just call arbor.issues.search once per unique key and
-- accept what comes back). Failures are silent — enrichment is decoration,
-- not load-bearing.
-- State on a returned issue may be one of:
--   · a bare string (e.g. Jira basic auth: "In Progress")
--   · a nested object like { name = "In Progress", type = "started" } (Linear)
--   · entirely absent
-- Always coerce to a printable string so the markdown render can concat
-- without exploding ("attempt to concatenate a table value" was the
-- crash we hit before this helper landed).
local function coerce_state(raw)
  if raw == nil then return nil end
  if type(raw) == "string" then return raw end
  if type(raw) == "table" then
    return raw.name or raw.label or raw.type or nil
  end
  return tostring(raw)
end

local function fetch_issue_titles(keys)
  if #keys == 0 then return {} end
  local titles = {}
  for _, k in ipairs(keys) do
    -- arbor.issues.lookup routes to the tracker configured for the
    -- active repo (linear / jira), and returns the issue object whose
    -- human identifier matches `k` exactly. Returns nil on miss / no
    -- tracker / no auth — we silently skip in that case so unknown
    -- ticket keys still render as bare text in the release notes.
    local it, err = arbor.issues.lookup(k)
    if err then
      arbor.log.warn(string.format("issue lookup failed for %s — %s", k, err))
    elseif type(it) == "table" then
      titles[k] = {
        title = it.title or it.summary or it.name,
        state = coerce_state(it.status) or coerce_state(it.state),
        url   = it.url or it.web_url,
      }
    end
  end
  return titles
end

local function md_escape(s)
  -- Minimal escape: pipe + backtick break tables / inline code; angle
  -- brackets break inline HTML. Leave the rest alone — release notes
  -- are read by humans, not by an aggressive linter.
  return (s or ""):gsub("|", "\\|"):gsub("`", "\\`"):gsub("<", "\\<")
end

-- ─────────────────────────────────────────────────────────────────────────
-- Build the Markdown
-- ─────────────────────────────────────────────────────────────────────────

local function build_notes(opts, commits)
  local lines = {}
  local title = opts.title or ""
  if title == "" then
    local from = opts.from_label ~= "" and opts.from_label or "(root)"
    title = string.format("Release notes — %s → %s", from, opts.to_label)
  end
  lines[#lines + 1] = "# " .. title
  lines[#lines + 1] = ""

  if #commits == 0 then
    lines[#lines + 1] = "_No commits in the selected range._"
    return table.concat(lines, "\n")
  end

  local subtitle = string.format("**%d commit%s**", #commits, #commits == 1 and "" or "s")
  if opts.from_ref ~= "" then
    subtitle = subtitle .. string.format(" between `%s` and `%s`",
      opts.from_label, opts.to_label)
  else
    subtitle = subtitle .. string.format(" up to `%s`", opts.to_label)
  end
  lines[#lines + 1] = subtitle
  lines[#lines + 1] = ""

  -- Issue enrichment (collected up-front: one network round per ticket).
  local ticket_titles = {}
  if opts.enrich_issues then
    local all_keys, seen = {}, {}
    for _, c in ipairs(commits) do
      for _, k in ipairs(extract_tickets(c.message or c.summary or "", opts.ticket_pattern)) do
        if not seen[k] then seen[k] = true; all_keys[#all_keys + 1] = k end
      end
    end
    ticket_titles = fetch_issue_titles(all_keys)
  end

  local buckets, order = group_commits(commits, opts)

  for _, key in ipairs(order) do
    local bucket = buckets[key]
    if bucket and #bucket.commits > 0 then
      lines[#lines + 1] = "## " .. bucket.label
      lines[#lines + 1] = ""
      for _, c in ipairs(bucket.commits) do
        local _, scope, subject = parse_conventional(c.summary or "")
        local prefix = scope and ("**" .. scope .. ":** ") or ""
        local sha = "`" .. (c.short_oid or "") .. "`"
        local row = string.format("- %s%s — %s", prefix, md_escape(subject), sha)

        if opts.enrich_issues then
          local keys = extract_tickets(c.message or c.summary or "", opts.ticket_pattern)
          for _, k in ipairs(keys) do
            local meta = ticket_titles[k]
            if meta and meta.title then
              local link = meta.url and string.format("[%s](%s)", k, meta.url) or k
              row = row .. string.format("\n  - %s — %s%s", link,
                md_escape(meta.title),
                meta.state and (" _(" .. meta.state .. ")_") or "")
            end
          end
        end

        lines[#lines + 1] = row
      end
      lines[#lines + 1] = ""
    end
  end

  -- Optional contributor list (always cheap to compute).
  if opts.include_authors then
    local authors, seen = {}, {}
    for _, c in ipairs(commits) do
      local n = c.author_name or ""
      if n ~= "" and not seen[n] then
        seen[n] = true; authors[#authors + 1] = n
      end
    end
    if #authors > 0 then
      table.sort(authors)
      lines[#lines + 1] = "## Contributors"
      lines[#lines + 1] = ""
      for _, a in ipairs(authors) do
        lines[#lines + 1] = "- " .. a
      end
      lines[#lines + 1] = ""
    end
  end

  return table.concat(lines, "\n")
end

-- ─────────────────────────────────────────────────────────────────────────
-- Wizard
-- ─────────────────────────────────────────────────────────────────────────

-- Build the option list of refs to choose as `from` / `to`. Tags first
-- (the most common release-notes anchors), then local branches. We tag
-- each entry so the dropdown stays scannable when both lists are long.
local function ref_options(include_empty_for_from)
  local out = {}
  if include_empty_for_from then
    out[#out + 1] = { value = "", label = "(none — walk to root)" }
  end
  local tags = arbor.repo.tags() or {}
  if #tags > 0 then
    table.sort(tags, function(a, b) return (a.name or "") > (b.name or "") end)
    for _, t in ipairs(tags) do
      out[#out + 1] = { value = t.name, label = "tag · " .. t.name }
    end
  end
  local branches = arbor.repo.branches() or {}
  for _, b in ipairs(branches) do
    if not b.is_remote then
      out[#out + 1] = { value = b.name, label = "branch · " .. b.name }
    end
  end
  return out
end

local function default_from()
  local tags = arbor.repo.tags() or {}
  if #tags == 0 then return "" end
  -- Reuse the same descending sort as the picker so the default and the
  -- top option agree visually.
  table.sort(tags, function(a, b) return (a.name or "") > (b.name or "") end)
  return tags[1].name
end

local function default_to()
  return "HEAD"
end

local function open_wizard()
  local repo = arbor.repo.current()
  if not repo or repo == "" then
    arbor.notify{ message = "No active repository.", level = "warning" }
    return
  end

  local from_opts = ref_options(true)
  local to_opts   = ref_options(false)
  -- HEAD is always a valid `to` even when the branch list is empty
  -- (initial commit on a fresh repo). Insert it explicitly so the form
  -- has a sensible default value for the dropdown.
  table.insert(to_opts, 1, { value = "HEAD", label = "HEAD (current commit)" })

  arbor.ui.form({
    title         = "Release notes",
    width         = "640px",
    height        = "560px",
    submit_label  = "Choose destination…",
    submit_action = "release-notes:pick_destination",
    nodes = {
      {
        type       = "wizard",
        id         = "wizard",
        next_label = "Next",
        back_label = "Back",
        steps = {
          {
            id    = "range",
            label = "Range",
            description = "Pick the commit window to summarise.",
            icon  = "GitBranch",
            children = {
              { type = "select", name = "from",
                label   = "From (exclusive)",
                options = from_opts,
                default = default_from(),
                hint    = "Leave on '(none)' to walk all the way back to the first commit." },
              { type = "select", name = "to",
                label   = "To (inclusive)",
                options = to_opts,
                default = default_to() },
              { type = "checkbox", name = "include_merges",
                label   = "Include merge commits",
                default = false,
                hint    = "Off by default — merges usually duplicate work already credited to feature commits." },
            },
          },
          {
            id    = "format",
            label = "Format",
            description = "Group commits and decide how to render the body.",
            icon  = "FileText",
            children = {
              { type = "text", name = "title",
                label       = "Title",
                placeholder = "Leave empty for an auto title using the range" },
              { type = "radio", name = "group_by",
                label   = "Group by",
                options = {
                  { value = "type",   label = "Conventional Commit type (feat / fix / …)" },
                  { value = "author", label = "Author" },
                  { value = "none",   label = "Single flat list" },
                },
                default = "type" },
              { type = "checkbox", name = "include_authors",
                label   = "Append a Contributors section",
                default = true },
              { type = "separator" },
              { type = "checkbox", name = "enrich_issues",
                label   = "Enrich tickets with Linear / Jira data",
                default = false,
                hint    = "Looks up each ticket key found in the commit message." },
              { type = "text", name = "ticket_pattern",
                label        = "Ticket regex (Lua pattern)",
                default      = "%f[%w]([A-Z][A-Z0-9]+%-%d+)%f[%W]",
                placeholder  = "%f[%w]([A-Z][A-Z0-9]+%-%d+)%f[%W]",
                hint         = "Default catches ABC-123 / FOO-9 style keys." },
            },
          },
        },
      },
    },
  })
end

-- ─────────────────────────────────────────────────────────────────────────
-- Submit → compute → file picker → write
-- ─────────────────────────────────────────────────────────────────────────

-- Submit step 1: snapshot the wizard config + open the save dialog. We
-- intentionally do NO git/network work here so the wizard closes
-- instantly (no frozen form). The actual generation is deferred to
-- on_save_picked → run_generation, which can take seconds for big
-- ranges + issue enrichment.
arbor.events.on("release-notes:pick_destination", function(ctx)
  local ok, run_err = pcall(function()
    ctx = ctx or {}
    local from = trim(ctx.from)
    local to   = trim(ctx.to)
    if to == "" then to = "HEAD" end

    pending_opts = {
      from_ref         = from,
      to_ref           = to,
      from_label       = from ~= "" and from or "(root)",
      to_label         = to,
      include_merges   = ctx.include_merges and true or false,
      title            = trim(ctx.title),
      group_by         = ctx.group_by or "type",
      include_authors  = ctx.include_authors and true or false,
      enrich_issues    = ctx.enrich_issues and true or false,
      ticket_pattern   = trim(ctx.ticket_pattern),
    }

    -- Suggest a filename derived from the upper bound: tag names produce
    -- `release-v1.2.0.md`, branches / HEAD fall back to a date stamp so
    -- we don't overwrite an earlier file by accident.
    local stem = pending_opts.to_label
    if stem == "HEAD" or stem == "" then
      stem = os.date("%Y-%m-%d")
    end
    local default_name = "release-" .. stem:gsub("[^%w%.%-_]", "_") .. ".md"

    local repo = arbor.repo.current() or ""
    arbor.log.info(string.format(
      "release-notes: picking destination  from='%s'  to='%s'  enrich=%s",
      pending_opts.from_ref, pending_opts.to_label, tostring(pending_opts.enrich_issues)
    ))

    arbor.ui.pick_file({
      mode         = "save",
      title        = "Save release notes",
      extensions   = { "md" },
      initial_path = (repo ~= "" and (repo .. "/") or "") .. default_name,
      action       = "release-notes:on_save_picked",
    })
  end)

  if not ok then
    arbor.log.error("release-notes:pick_destination crashed — " .. tostring(run_err))
    arbor.notify{
      title   = "Release notes — internal error",
      message = tostring(run_err),
      level   = "error",
    }
  end
end)

-- The actual generation. Triggered as the file-picker callback, OR
-- re-entered from itself via arbor.timer.after for the deferred work.
-- We split into two phases:
--   1. Confirm path, show "Generating…" toast, schedule the heavy work
--   2. (deferred) revparse + revwalk + issue enrichment + fs.write
-- This way the file picker closes immediately, the user gets a visible
-- progress notification, and the heavy work runs without any modal
-- frozen on screen.
-- Stable per-run id used by the operations overlay. Monotonic so a
-- second run while the first card is still on screen gets its own card.
local op_counter = 0
local function next_op_id()
  op_counter = op_counter + 1
  return "run-" .. tostring(op_counter)
end

arbor.events.on("release-notes:on_save_picked", function(ctx)
  local path = ctx and ctx.path or ""
  if path == "" then
    pending_opts = nil
    return -- user cancelled
  end
  if not pending_opts then
    arbor.notify{
      title   = "Release notes",
      message = "Lost the wizard state — try again.",
      level   = "warning",
    }
    return
  end

  -- Snapshot opts + clear the module slot so a second wizard run can't
  -- clobber an in-flight generation mid-write.
  local opts = pending_opts
  pending_opts = nil

  -- Build the step list up-front. We always have commits → render →
  -- write; the "tickets" step is only inserted when the user opted into
  -- enrichment (otherwise it would sit forever as a pending dot).
  local steps = {
    { key = "commits", label = "Reading commits" },
  }
  if opts.enrich_issues then
    steps[#steps + 1] = { key = "tickets", label = "Enriching tickets" }
  end
  steps[#steps + 1] = { key = "render", label = "Building markdown" }
  steps[#steps + 1] = { key = "write",  label = "Writing file" }

  local op_id = next_op_id()
  arbor.ui.operation.start({
    id       = op_id,
    title    = "Release notes",
    subtitle = string.format("%s → %s", opts.from_label, opts.to_label),
    steps    = steps,
    current  = "commits",
  })

  arbor.timer.after(50, function()
    local ok, run_err = pcall(function()
      arbor.log.info("release-notes: generating into " .. path)

      -- Step: commits ───────────────────────────────────────────────
      local commits, err = arbor.repo.commits({
        from           = opts.from_ref,
        to             = opts.to_ref,
        include_merges = opts.include_merges,
        limit          = 5000,
      })
      if err then
        arbor.ui.operation.update_step(op_id, "commits", { status = "error", detail = err })
        arbor.ui.operation.finish(op_id, { error = err })
        arbor.notify{ title = "Release notes failed", message = err, level = "error" }
        return
      end
      commits = commits or {}
      arbor.log.info("release-notes: got " .. tostring(#commits) .. " commit(s)")
      if #commits == 0 then
        local msg = string.format("No commits between '%s' and '%s'.",
                                  opts.from_label, opts.to_label)
        arbor.ui.operation.update_step(op_id, "commits", { status = "skipped", detail = "empty range" })
        arbor.ui.operation.finish(op_id, { summary = msg })
        arbor.notify{
          title   = "Release notes — empty range",
          message = msg,
          level   = "warning",
        }
        return
      end
      arbor.ui.operation.update_step(op_id, "commits", {
        status = "completed",
        detail = string.format("%d commit(s)", #commits),
      })

      -- Step: tickets (optional) ────────────────────────────────────
      -- build_notes does the actual issue lookup internally. We split
      -- the "render" call here so the stepper can show a distinct
      -- "Enriching tickets" phase to the user — otherwise the whole
      -- thing would feel like one black-box "render" step.
      if opts.enrich_issues then
        arbor.ui.operation.set_current(op_id, "tickets",
          "Querying issue tracker(s)…")
      end

      -- Step: render ────────────────────────────────────────────────
      arbor.ui.operation.set_current(op_id, "render", "Formatting Markdown…")
      local md = build_notes(opts, commits)
      arbor.ui.operation.update_step(op_id, "render", { status = "completed" })
      if opts.enrich_issues then
        -- build_notes finished tickets along the way → close that step too.
        arbor.ui.operation.update_step(op_id, "tickets", { status = "completed" })
      end

      -- Step: write ─────────────────────────────────────────────────
      arbor.ui.operation.set_current(op_id, "write", path)
      local wrote, werr = arbor.fs.write(path, md)
      if not wrote then
        arbor.ui.operation.update_step(op_id, "write", { status = "error", detail = werr or "?" })
        arbor.ui.operation.finish(op_id, { error = werr or "fs.write failed" })
        arbor.notify{ title = "Save failed", message = werr or "?", level = "error" }
        return
      end
      arbor.ui.operation.update_step(op_id, "write", { status = "completed", detail = path })
      arbor.ui.operation.finish(op_id, {
        summary = string.format("%d commit(s) saved", #commits),
      })

      arbor.notify{
        title   = "Release notes saved",
        message = string.format("%d commit(s) → %s", #commits, path),
        level   = "success",
        action  = {
          -- open-path hands the file to the OS' default handler (markdown
          -- editor on most setups). For "reveal in Explorer" instead, set
          -- reveal = true so the parent folder is opened.
          kind  = "open-path",
          label = "Open file",
          path  = path,
        },
      }
    end)

    if not ok then
      arbor.log.error("release-notes generation crashed — " .. tostring(run_err))
      pcall(function()
        arbor.ui.operation.finish(op_id, { error = tostring(run_err) })
      end)
      arbor.notify{
        title   = "Release notes — internal error",
        message = tostring(run_err),
        level   = "error",
      }
    end
  end)
end)

-- ─────────────────────────────────────────────────────────────────────────
-- Wiring
-- ─────────────────────────────────────────────────────────────────────────

arbor.events.on("on_plugin_load", function(_ctx)
  arbor.command.register({
    id          = "open",
    title       = "Generate release notes…",
    description = "Open the wizard to build a Markdown changelog from a commit range.",
    icon        = "FileText",
    group       = "Release",
  })
  arbor.log.info("release-notes ready")
end)

arbor.events.on("command:open", function(_) open_wizard() end)
