-- config/sequences.lua — global CRUD for Source Export sequences + run history.
--
-- Sequences are GLOBAL (unlike profiles which are per-repo): they reference
-- profiles across multiple repos, so they have no natural "home repo". We
-- persist them under `arbor.settings.global` as a single JSON blob per key.
--
-- Two keys:
--   "sequences"     → [Sequence]
--   "sequence_runs" → [SequenceRun]  (history of executions)
--
-- SequenceRun shape:
--   {
--     id            : "sr_<hex>"
--     sequence_id   : "seq_<hex>"
--     sequence_name : string          -- cached for UI (sequence may be deleted)
--     output_root   : string          -- resolved at run time
--     fail_fast     : boolean
--     started_at    : int ms
--     finished_at   : int ms | nil
--     status        : "running"|"success"|"failed"|"cancelled"|"partial"
--     items         : [ {
--         item_id      : string
--         profile_name : string
--         repo_label   : string
--         pipeline_run_id : string?    -- links to arbor.pipeline run_id
--         status       : "pending"|"running"|"success"|"failed"|"skipped"|"cancelled"
--         started_at   : int ms?
--         finished_at  : int ms?
--       } ]
--   }

local schema = require("sequence_schema")

local M = {}

local KEY_SEQUENCES    = "sequences"
local KEY_SEQ_RUNS     = "sequence_runs"
local MAX_RUNS_DEFAULT = 50   -- hard cap to keep the global blob from ballooning

-- ── Sequence CRUD ───────────────────────────────────────────────────────────

function M.load()
  local raw = arbor.json.decode(arbor.settings.global.get(KEY_SEQUENCES) or "[]")
  return (raw and type(raw) == "table") and raw or {}
end

function M.save(list)
  local s = arbor.json.encode(list or {})
  if s then arbor.settings.global.set(KEY_SEQUENCES, s) end
end

function M.find(id)
  if not id or id == "" then return nil end
  for _, s in ipairs(M.load()) do
    if s.id == id then return s end
  end
end

function M.upsert(sequence)
  if not sequence or not sequence.id then return end
  sequence.updated_at = schema.now_ms()
  local list  = M.load()
  local found = false
  for i, s in ipairs(list) do
    if s.id == sequence.id then list[i] = sequence; found = true; break end
  end
  if not found then list[#list+1] = sequence end
  M.save(list)
end

function M.remove(id)
  local list, out = M.load(), {}
  for _, s in ipairs(list) do
    if s.id ~= id then out[#out+1] = s end
  end
  M.save(out)
end

function M.duplicate(id)
  local src = M.find(id)
  if not src then return nil end
  local copy = schema.clone(src)
  if not copy then return nil end
  copy.id   = schema.new_id("seq")
  copy.name = (copy.name or "Sequence") .. " (copy)"
  copy.created_at = schema.now_ms()
  copy.updated_at = copy.created_at
  -- Fresh ids per item so the duplicate is independent.
  for _, it in ipairs(copy.items or {}) do
    it.id = schema.new_id("it")
  end
  local list = M.load()
  list[#list+1] = copy
  M.save(list)
  return copy
end

-- ── Run history CRUD ────────────────────────────────────────────────────────

function M.load_runs()
  local raw = arbor.json.decode(arbor.settings.global.get(KEY_SEQ_RUNS) or "[]")
  return (raw and type(raw) == "table") and raw or {}
end

function M.save_runs(list)
  local s = arbor.json.encode(list or {})
  if s then arbor.settings.global.set(KEY_SEQ_RUNS, s) end
end

function M.find_run(id)
  if not id or id == "" then return nil end
  for _, r in ipairs(M.load_runs()) do
    if r.id == id then return r end
  end
end

function M.upsert_run(run)
  if not run or not run.id then return end
  local list  = M.load_runs()
  local found = false
  for i, r in ipairs(list) do
    if r.id == run.id then list[i] = run; found = true; break end
  end
  if not found then
    -- Prepend so newest-first lists don't need sorting.
    table.insert(list, 1, run)
  end
  -- Cap the total number of persisted runs. We keep the most recent N
  -- regardless of status — users can discard individually from the sidebar.
  if #list > MAX_RUNS_DEFAULT then
    for i = #list, MAX_RUNS_DEFAULT + 1, -1 do table.remove(list, i) end
  end
  M.save_runs(list)
end

function M.remove_run(id)
  local list, out = M.load_runs(), {}
  for _, r in ipairs(list) do
    if r.id ~= id then out[#out+1] = r end
  end
  M.save_runs(out)
end

function M.clear_runs()
  M.save_runs({})
end

--- Find the sequence-run that owns a given arbor.pipeline run_id. Used by
--- PIPELINE_DONE / PIPELINE_STARTED hooks to update an item's status.
function M.find_run_by_pipeline_run(pipeline_run_id)
  if not pipeline_run_id or pipeline_run_id == "" then return nil, nil end
  for _, r in ipairs(M.load_runs()) do
    for _, it in ipairs(r.items or {}) do
      if it.pipeline_run_id == pipeline_run_id then return r, it end
    end
  end
end

-- Helper: new SequenceRun skeleton. Items start in "pending"; the runner sets
-- them to running/success/failed/skipped as it progresses.
function M.new_run(sequence, output_root)
  local items = {}
  for _, it in ipairs(sequence.items or {}) do
    items[#items+1] = {
      item_id         = it.id,
      profile_name    = it.profile_name or it.profile_id,
      repo_label      = it.repo_label or it.repo_path,
      pipeline_run_id = "",
      status          = "pending",
      started_at      = 0,
      finished_at     = 0,
    }
  end
  return {
    id            = schema.new_id("sr"),
    sequence_id   = sequence.id,
    sequence_name = sequence.name or sequence.id,
    output_root   = output_root or "",
    fail_fast     = sequence.fail_fast and true or false,
    started_at    = schema.now_ms(),
    finished_at   = 0,
    status        = "running",
    items         = items,
  }
end

return M
