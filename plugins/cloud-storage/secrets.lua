-- secrets.lua — the panel's own secrets, in the one slot it is allowed to have.
--
-- A package declares its credential slots in its manifest, statically, and can name no others
-- — that is what makes "this plugin cannot read your git tokens" a property of the namespace
-- rather than a promise. It also means a slot per connection is impossible: connections are
-- created at runtime and a manifest is not.
--
-- So there is ONE slot, holding a JSON object keyed by the connection's secret ref. Reading or
-- writing one value rewrites the document, which for a handful of connections costs nothing
-- and keeps the whole thing in the keychain where it belongs.
--
-- ## What is NOT in here
--
-- A provider's OAuth token. That lives in the PROVIDER package's slot, because the provider is
-- what reads it — the wasm component fetches it through `arbor:host/secrets` when it makes a
-- request. The panel never sees it, and could not name it if it tried.

local SLOT = "connection-secrets"

local M = {}

local function load()
  local ok, raw = pcall(function() return arbor.credentials.get(SLOT) end)
  if not ok or not raw or raw == "" then return {} end
  local parsed_ok, parsed = pcall(arbor.json.decode, raw)
  if not parsed_ok or type(parsed) ~= "table" then return {} end
  return parsed
end

local function save(all)
  local ok, err = pcall(function() arbor.credentials.set(SLOT, arbor.json.encode(all)) end)
  if not ok then arbor.log.warn("cloud-storage: saving secrets: " .. tostring(err)) end
  return ok
end

--- Read one value, or `nil`.
function M.get(ref)
  if not ref or ref == "" then return nil end
  local v = load()[ref]
  if type(v) == "string" and v ~= "" then return v end
  return nil
end

--- Whether a value is stored under `ref`. Answered without moving the secret, which is the
--- question a settings form actually asks ("is this filled in?").
function M.exists(ref)
  return M.get(ref) ~= nil
end

--- Store one value.
function M.set(ref, value)
  if not ref or ref == "" then return false end
  local all = load()
  all[ref] = value
  return save(all)
end

--- Remove one value. Removing something absent succeeds — the caller asked for it to be gone.
function M.delete(ref)
  if not ref or ref == "" then return true end
  local all = load()
  if all[ref] == nil then return true end
  all[ref] = nil
  return save(all)
end

return M
