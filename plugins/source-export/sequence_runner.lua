-- sequence_runner.lua — execute a Sequence: fan out N profiles across M repos,
-- share a single output root, inject matrix variables, respect fail-fast.
--
-- Execution model:
--   · Items run SEQUENTIALLY (one pipeline at a time) — simpler failure
--     semantics and no lock-key contention between items.
--   · Each item compiles and runs the referenced profile via compile.run(),
--     passing:
--       · source_path   = item.repo_path
--       · output_folder = <seq.output_root> / <safe_profile_name>_<item_index>
--       · extra_vars    = seq.variables + item.variables (item wins on collision)
--   · When fail_fast = true the first failure marks the SequenceRun as
--     `failed` and the remaining items go to `skipped` without executing.
--   · When fail_fast = false we execute every enabled item and tag the run
--     as `success` if all passed, `partial` if some failed, `failed` if all
--     failed.
--
-- The runner listens for `panel:sequence_run_advance:<sr_id>` action posted
-- by PIPELINE_DONE (see main.lua) to decide whether to move on. We do NOT
-- poll: the hook fires exactly once per pipeline completion and tells us
-- the outcome via the run's `status`.

local schema     = require("sequence_schema")
local gcfg       = require("config.global")
local seq_store  = require("config.sequences")
local compile    = require("compile")
local remote     = require("remote_profiles")

local M = {}

local IS_WIN = arbor.meta.os() == "windows"
local PSEP   = IS_WIN and "\\" or "/"

-- ── In-memory controller state ──────────────────────────────────────────────
-- One controller per active SequenceRun, keyed by sr_id. A controller owns
-- the cursor (next item to execute), the cached sequence / items, and a
-- "resolved output_root" so every item gets a consistent subfolder.
--
-- Keeping state purely in memory is acceptable: if the app restarts mid-run
-- the sequence is marked `failed` on next startup (main.lua does the sweep).
--
-- NOTE: we keep controllers keyed on the sequence RUN id (sr_id), not the
-- sequence def id — the user can start the same sequence twice back-to-back
-- and each run is tracked independently.
local controllers = {}

local function safe_name(s)
  return (s or ""):gsub("[^%w%-_.]+", "_"):sub(1, 64)
end

local function default_output_root(sequence)
  local base = gcfg.get_output_folder()
  local safe = safe_name(sequence.name or sequence.id)
  local ts   = schema.now_ms()
  return base .. PSEP .. "sequence_" .. safe .. "_" .. tostring(ts)
end

local function resolve_output_root(sequence)
  local cfg = sequence.output_root or ""
  if cfg == "" then return default_output_root(sequence) end
  -- If the user supplied a custom root, still append a timestamp so repeated
  -- runs don't clobber previous outputs.
  local ts = schema.now_ms()
  return cfg .. PSEP .. "run_" .. tostring(ts)
end

local function merge_vars(global_vars, item_vars)
  local out = {}
  for _, v in ipairs(global_vars or {}) do
    if v and v.key and v.key ~= "" then
      out[#out+1] = { key = v.key, value = v.value or "" }
    end
  end
  for _, v in ipairs(item_vars or {}) do
    if v and v.key and v.key ~= "" then
      local found = false
      for _, existing in ipairs(out) do
        if existing.key == v.key then
          existing.value = v.value or ""
          found = true
          break
        end
      end
      if not found then
        out[#out+1] = { key = v.key, value = v.value or "" }
      end
    end
  end
  return out
end

-- ── Status transitions ──────────────────────────────────────────────────────

local function mark_remaining_skipped(sr)
  for _, it in ipairs(sr.items or {}) do
    if it.status == "pending" then it.status = "skipped" end
  end
end

local function finalize(sr)
  local success, failed, total = 0, 0, 0
  for _, it in ipairs(sr.items or {}) do
    total = total + 1
    if it.status == "success" then success = success + 1
    elseif it.status == "failed" or it.status == "cancelled" then failed = failed + 1
    end
  end
  if failed == 0 then
    sr.status = "success"
  elseif success == 0 then
    sr.status = "failed"
  else
    sr.status = "partial"
  end
  sr.finished_at = schema.now_ms()
  seq_store.upsert_run(sr)
end

-- ── Public entry points ─────────────────────────────────────────────────────

--- Start a sequence run. Returns (true, sr_id) on success, (false, err) on
--- a fatal issue (empty sequence / unresolved output root). Per-item errors
--- do NOT abort this function — they're captured on the SequenceRun.
function M.start(sequence)
  if not sequence or not sequence.items or #sequence.items == 0 then
    return false, "Sequence is empty: add at least one item before running."
  end

  local output_root = resolve_output_root(sequence)
  local sr          = seq_store.new_run(sequence, output_root)
  seq_store.upsert_run(sr)

  -- Snapshot the items into the controller. We resolve profiles (reading
  -- from disk NOW so the run uses the latest profile definition) and cache
  -- the data needed per step — if the sequence def is edited mid-run we
  -- still finish what we started.
  local ctrl = {
    sr_id       = sr.id,
    sequence_id = sequence.id,
    output_root = output_root,
    fail_fast   = sequence.fail_fast and true or false,
    cursor      = 0,
    items       = {},
  }
  for idx, it in ipairs(sequence.items or {}) do
    ctrl.items[#ctrl.items+1] = {
      index         = idx,
      item_id       = it.id,
      repo_path     = it.repo_path or "",
      repo_label    = it.repo_label or it.repo_path or "?",
      profile_id    = it.profile_id or "",
      profile_name  = it.profile_name or "(unknown profile)",
      enabled       = (it.enabled ~= false),
      allow_failure = it.allow_failure and true or false,
      merged_vars   = merge_vars(sequence.variables, it.variables),
    }
  end
  controllers[sr.id] = ctrl

  arbor.notify{ title = "Sequence started", message = (sequence.name or "sequence") .. "  ·  " .. tostring(#ctrl.items) .. " items", level = "info" }

  -- Drive the first item.
  M.advance(sr.id)
  return true, sr.id
end

--- Run the next pending item. Called on start and after each PIPELINE_DONE
--- for a pipeline_run_id that belongs to this SequenceRun.
function M.advance(sr_id)
  local ctrl = controllers[sr_id]
  if not ctrl then return end
  local sr = seq_store.find_run(sr_id)
  if not sr then controllers[sr_id] = nil; return end

  -- If we're in fail_fast mode and the last item failed, abort.
  if ctrl.fail_fast then
    for _, it in ipairs(sr.items or {}) do
      if it.status == "failed" or it.status == "cancelled" then
        mark_remaining_skipped(sr)
        finalize(sr)
        controllers[sr_id] = nil
        arbor.notify{ title = "Sequence halted", message = "fail-fast enabled — stopping after first failure", level = "warning" }
        return
      end
    end
  end

  -- Find the next pending / non-skipped item.
  ctrl.cursor = ctrl.cursor + 1
  while ctrl.cursor <= #ctrl.items and not ctrl.items[ctrl.cursor].enabled do
    -- Disabled items are pre-marked "skipped" on the SequenceRun.
    for _, it in ipairs(sr.items or {}) do
      if it.item_id == ctrl.items[ctrl.cursor].item_id then it.status = "skipped" end
    end
    ctrl.cursor = ctrl.cursor + 1
  end

  if ctrl.cursor > #ctrl.items then
    -- All done.
    seq_store.upsert_run(sr)
    finalize(sr)
    controllers[sr_id] = nil
    local label = sr.status == "success" and "completed"
               or sr.status == "partial" and "finished with failures"
               or "failed"
    arbor.notify{ title = "Sequence " .. label, message = sr.sequence_name or sr.sequence_id, level = sr.status == "success" and "success"
        or sr.status == "partial" and "warning"
        or "error" }
    return
  end

  local cur = ctrl.items[ctrl.cursor]

  -- Resolve the profile from the referenced repo (live read: picks up any
  -- edits since the sequence was defined).
  local profile = remote.find_profile(cur.repo_path, cur.profile_id)
  if not profile then
    local err_msg = "profile not found: " .. cur.profile_name ..
                    "  (repo: " .. cur.repo_label .. ")"
    for _, it in ipairs(sr.items or {}) do
      if it.item_id == cur.item_id then
        it.status      = "failed"
        it.started_at  = schema.now_ms()
        it.finished_at = it.started_at
      end
    end
    seq_store.upsert_run(sr)
    arbor.log.error("[sequence] " .. err_msg)
    return M.advance(sr_id)   -- keep going (or halt next tick if fail-fast)
  end

  -- Compute output folder = <sequence_output_root>/<NN_profile>
  -- Prefix with the item index so items keep their logical order on disk
  -- even when profile names collide.
  local item_folder = string.format("%02d_%s",
    cur.index, safe_name(cur.profile_name or cur.profile_id))
  local item_output_path = ctrl.output_root .. PSEP .. item_folder

  -- Mark running BEFORE launching so the sidebar reflects progress even if
  -- the pipeline defines + runs atomically.
  for _, it in ipairs(sr.items or {}) do
    if it.item_id == cur.item_id then
      it.status     = "running"
      it.started_at = schema.now_ms()
    end
  end
  seq_store.upsert_run(sr)

  local ok, run_id_or_err = compile.run(profile, {
    source_path          = cur.repo_path,
    -- Per-item OUTPUT_PATH = <output_root>/<NN_profile>. variables.lua
    -- treats an explicit output_folder as the final path (no nested
    -- <safe>_<timestamp> layer): the per-run timestamp already lives in
    -- <output_root>, the per-item index already disambiguates within the
    -- run, and the extra layer would push us past Windows MAX_PATH inside
    -- the cloned repo's .git tree.
    output_folder        = item_output_path,
    extra_vars           = cur.merged_vars,
    pipeline_name_suffix = string.format(" · seq %d/%d", cur.index, #ctrl.items),
  })

  if not ok then
    for _, it in ipairs(sr.items or {}) do
      if it.item_id == cur.item_id then
        it.status      = "failed"
        it.finished_at = schema.now_ms()
      end
    end
    seq_store.upsert_run(sr)
    arbor.log.error("[sequence] item failed: " .. tostring(run_id_or_err))
    return M.advance(sr_id)
  end

  -- Success → attach the pipeline_run_id so PIPELINE_DONE can correlate.
  for _, it in ipairs(sr.items or {}) do
    if it.item_id == cur.item_id then
      it.pipeline_run_id = run_id_or_err
    end
  end
  seq_store.upsert_run(sr)
  -- Don't advance yet — wait for PIPELINE_DONE to fire for this run_id.
end

--- Called by main.lua's PIPELINE_DONE hook. `status` is the pipeline run's
--- final status ("success" / "failed" / "cancelled").
function M.on_pipeline_done(pipeline_run_id, status)
  local sr, it = seq_store.find_run_by_pipeline_run(pipeline_run_id)
  if not sr or not it then return end
  it.status      = status or "success"
  it.finished_at = schema.now_ms()
  seq_store.upsert_run(sr)
  -- Continue the run (if we own it).
  M.advance(sr.id)
end

--- Cancel an in-flight sequence run: best-effort cancel of the currently
--- executing pipeline plus immediate finalize.
function M.cancel(sr_id)
  local ctrl = controllers[sr_id]
  local sr   = seq_store.find_run(sr_id)
  if not sr then return end
  for _, it in ipairs(sr.items or {}) do
    if it.status == "running" and it.pipeline_run_id ~= "" then
      pcall(function() arbor.pipeline.cancel(it.pipeline_run_id) end)
      it.status      = "cancelled"
      it.finished_at = schema.now_ms()
    elseif it.status == "pending" then
      it.status = "skipped"
    end
  end
  sr.status      = "cancelled"
  sr.finished_at = schema.now_ms()
  seq_store.upsert_run(sr)
  if ctrl then controllers[sr_id] = nil end
end

--- Recover orphaned "running" runs at plugin load (app restart during a run).
--- We mark them as failed since we've lost the controller state.
function M.sweep_on_load()
  local runs = seq_store.load_runs()
  local dirty = false
  for _, r in ipairs(runs) do
    if r.status == "running" then
      r.status      = "failed"
      r.finished_at = schema.now_ms()
      for _, it in ipairs(r.items or {}) do
        if it.status == "running" or it.status == "pending" then
          it.status      = "failed"
          it.finished_at = r.finished_at
        end
      end
      dirty = true
    end
  end
  if dirty then seq_store.save_runs(runs) end
end

return M
