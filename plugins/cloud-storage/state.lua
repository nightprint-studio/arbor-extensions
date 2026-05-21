-- state.lua — connection list + UI state for the cloud-storage plugin.
--
-- All persistent state lives in plugin settings (arbor.settings.global) so
-- it survives plugin reloads but never leaks into git. Secrets that can't
-- be persisted in cleartext (SA JSON inline, OAuth refresh tokens) live in
-- the OS keyring via `arbor.cloud.secret_*` — those calls are made from
-- the config form, not here.

local M = {}

-- ── Persistent: connections list ────────────────────────────────────────────
-- Stored as a JSON-encoded array under the plugin's `connections` global
-- setting. Each entry has the shape:
--   {
--     id              = "cfg_abc",           -- stable, generated on create
--     name            = "prod-gcs",
--     provider        = "gcs",                -- "gcs" | "s3" | "azblob"
--     project_id      = "my-project",
--     default_bucket  = "my-bucket",
--     gcs = {                                 -- nil for non-gcs
--       method      = "sa_file" | "sa_inline" | "adc" | "gcloud_cli" | "oauth",
--       path        = "..."                   -- when sa_file
--       secret_ref  = "gcs/cfg_abc"           -- when sa_inline / oauth
--       client_id   = "..."                   -- when oauth (stored in keyring too;
--                                                kept here for display)
--     }
--   }

function M.load_connections()
  local raw = arbor.settings.global.get("connections") or "[]"
  local ok, parsed = pcall(arbor.json.decode, raw)
  if not ok or type(parsed) ~= "table" then return {} end
  return parsed
end

function M.save_connections(list)
  local s = arbor.json.encode(list or {})
  arbor.settings.global.set("connections", s)
end

function M.find(id)
  if not id or id == "" then return nil end
  for _, c in ipairs(M.load_connections()) do
    if c.id == id then return c end
  end
  return nil
end

function M.upsert(conn)
  local list = M.load_connections()
  for i, c in ipairs(list) do
    if c.id == conn.id then
      list[i] = conn
      M.save_connections(list)
      return
    end
  end
  list[#list + 1] = conn
  M.save_connections(list)
end

function M.delete(id)
  local list = M.load_connections()
  local out = {}
  for _, c in ipairs(list) do
    if c.id ~= id then out[#out + 1] = c end
  end
  M.save_connections(out)
end

-- ── Selected connection ────────────────────────────────────────────────────

function M.selected_id()
  return arbor.settings.global.get("selected_connection") or ""
end

function M.set_selected(id)
  arbor.settings.global.set("selected_connection", id or "")
end

-- ── Per-connection UI state (active bucket / prefix) ───────────────────────

function M.active_bucket(id)
  if not id or id == "" then return "" end
  return arbor.settings.global.get("ui:bucket:" .. id) or ""
end

function M.set_active_bucket(id, bucket)
  if not id or id == "" then return end
  arbor.settings.global.set("ui:bucket:" .. id, bucket or "")
end

function M.active_prefix(id)
  if not id or id == "" then return "" end
  return arbor.settings.global.get("ui:prefix:" .. id) or ""
end

function M.set_active_prefix(id, prefix)
  if not id or id == "" then return end
  arbor.settings.global.set("ui:prefix:" .. id, prefix or "")
end

-- ── Helpers ────────────────────────────────────────────────────────────────

function M.new_id()
  -- Plain Lua RNG — collisions are statistically negligible at the scale of
  -- "how many cloud connections does a single user have". A UUID lib would
  -- be overkill for an id that exists only inside this plugin's settings.
  math.randomseed(os.time() + math.floor((os.clock() * 1000000) % 1000000))
  local a = string.format("%06x", math.random(0, 0xffffff))
  local b = string.format("%06x", math.random(0, 0xffffff))
  return "cfg_" .. a .. b
end

-- Strip secret refs (inline SA, OAuth refresh) when a connection is being
-- deleted. Returns the list of keyring refs removed, so the caller can log
-- / surface them in the UI.
function M.drop_secrets_for(conn)
  if not conn then return {} end
  local removed = {}
  local refs = {}
  if conn.gcs    and conn.gcs.secret_ref    and conn.gcs.secret_ref    ~= "" then refs[#refs+1] = conn.gcs.secret_ref end
  if conn.s3     and conn.s3.secret_ref     and conn.s3.secret_ref     ~= "" then refs[#refs+1] = conn.s3.secret_ref end
  if conn.azblob and conn.azblob.secret_ref and conn.azblob.secret_ref ~= "" then refs[#refs+1] = conn.azblob.secret_ref end
  for _, r in ipairs(refs) do
    pcall(function() arbor.cloud.secret_delete(r) end)
    removed[#removed + 1] = r
  end
  return removed
end

-- ── Connection envelope (for arbor.cloud.* calls) ──────────────────────────
-- Builds the `CloudConnection` shape the Rust side expects from a stored
-- record. Drops UI-only fields (`name`, `default_bucket`, etc.) and leaves
-- a serialisable, host-ready table.

function M.envelope(conn)
  if not conn then return nil end
  local env = {
    provider   = conn.provider or "gcs",
    config_id  = conn.id or "",
    project_id = conn.project_id,
  }
  if conn.provider == "gcs" and conn.gcs then
    -- The Rust enum is tag = "method" (snake_case variants).
    local g = conn.gcs
    if g.method == "sa_file" then
      env.gcs = { method = "sa_file", path = g.path or "" }
    elseif g.method == "sa_inline" then
      env.gcs = { method = "sa_inline", secret_ref = g.secret_ref or "" }
    elseif g.method == "adc" then
      env.gcs = { method = "adc" }
    elseif g.method == "gcloud_cli" then
      env.gcs = { method = "gcloud_cli" }
    elseif g.method == "oauth" then
      env.gcs = { method = "oauth", secret_ref = g.secret_ref or "" }
    end
  elseif conn.provider == "s3" and conn.s3 then
    -- access_key_id is plain settings; the secret access key lives in the
    -- keyring under `s3/<config-id>` and is fetched by the Rust builder.
    env.s3 = {
      access_key_id    = conn.s3.access_key_id or "",
      secret_ref       = conn.s3.secret_ref or "",
      region           = conn.s3.region,
      endpoint         = conn.s3.endpoint,
      force_path_style = conn.s3.force_path_style,
    }
  elseif conn.provider == "azblob" and conn.azblob then
    env.azblob = {
      account_name = conn.azblob.account_name or "",
      secret_ref   = conn.azblob.secret_ref or "",
      endpoint     = conn.azblob.endpoint,
    }
  end
  return env
end

-- ── Ephemeral: pending-job metadata for completion notifications ───────────
-- Per-job hints captured at kickoff time so the `cloud-storage:job-done`
-- listener can show a "Done — Open folder" notification with the actual
-- local destination. Keyed by job_id. Entries are consumed exactly once
-- (`take_pending_job`), so a stray re-fire doesn't double-notify.
--
-- Shape of `info`:
--   { kind = "download"  | "bulk_download" | "merge",
--     local_path = "/path/to/file_or_folder",
--     -- optional:
--     label      = "human-readable summary line",
--     reveal     = boolean   -- whether to reveal-in-parent vs open-as-folder
--   }
M._pending_jobs = M._pending_jobs or {}

function M.remember_job(job_id, info)
  if not job_id or job_id == "" then return end
  M._pending_jobs[job_id] = info
end

function M.take_pending_job(job_id)
  if not job_id or job_id == "" then return nil end
  local v = M._pending_jobs[job_id]
  M._pending_jobs[job_id] = nil
  return v
end

return M
