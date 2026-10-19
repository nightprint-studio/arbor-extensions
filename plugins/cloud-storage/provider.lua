-- provider.lua — talking to a store, through the extension that implements it.
--
-- Every call in this file goes to a WASI provider package (`cloud-gcs`, and its siblings) via
-- `arbor.ext.call`. Arbor is not in the middle of any of it: it checks that this plugin may
-- call an extension, resolves the address, and passes JSON through. What a bucket is, and
-- what "list" means, lives entirely between this file and the provider.
--
-- ## The two shapes
--
-- Ordinary calls answer in JSON, which is right for a listing and wrong for an object. When
-- the payload IS the answer, `read_to_file` / `write_from_file` move the bytes straight
-- between the provider and a local file — never through Lua, and never as a JSON array of
-- numbers. That is the difference between a download that works and one that holds six copies
-- of a gigabyte.
--
-- ## Targets
--
-- Every provider function takes `{ bucket = …, config = … }` as its first argument, where
-- `config` is the provider's OWN json — this file does not interpret it, and neither does
-- Arbor. Credentials are not in it: the provider reads them from its own credential slot.

local state = require("state")

local M = {}

local INTERFACE = "cloud-provider"

-- ── Addressing ──────────────────────────────────────────────────────────────

--- The `[[provides]]` id of the package that serves this connection's kind.
local function provider_id(conn)
  return conn.provider or "gcs"
end

--- The `target` record every provider function opens with.
--
-- Only what the provider needs to reach the bucket. `state.envelope` has more in it — the
-- connection's name, its display settings — and sending those would be inviting a provider to
-- depend on this plugin's own storage shape.
function M.target(conn, bucket)
  local cfg = {
    project_id = conn.project_id,
    endpoint   = conn.endpoint,
    region     = conn.region,
  }
  return {
    bucket = bucket or conn.default_bucket or "",
    config = arbor.json.encode(cfg),
  }
end

--- Call one provider method. Returns `(value, nil)` or `(nil, err)`.
--
-- `pcall` because `arbor.ext.call` RAISES on failure — the extension is not installed, the
-- token is refused, the store said no — while every caller in this plugin is written against
-- the `(value, err)` pair the rest of the API uses. Converting once here is what keeps the
-- call sites from each growing their own pcall.
--- Positional arguments, holes included.
--
-- A provider's parameters are positional and several are `option<T>`, and Lua cannot hold a
-- positional `nil`: in `{ prefix, delimiter, cursor, limit }` with no cursor, `ipairs` stops
-- at the gap and four arguments become two. So callers that can pass a nil in the MIDDLE hand
-- the list over as `table.pack(...)`, whose `n` is the count the author wrote, and that count
-- travels with the values. A trailing nil needs none of this — the host pads a missing
-- optional at the end.
--- The sentence of an error, without the Lua machinery around it.
--
-- `pcall` hands back `runtime error: <message> stack traceback: [C]: in function …`, and the
-- traceback is a description of this plugin's own call stack, not of what went wrong. Shown in a
-- notification it buries the one line the user can act on ("connect an account") under ten they
-- cannot, so only the message is kept.
local function plain_error(raw)
  local text = tostring(raw)
  text = text:gsub("%s*stack traceback:.*$", "")
  text = text:gsub("^runtime error:%s*", "")
  return text
end

function M.call(conn, bucket, method, args)
  args = args or {}
  local count = args.n or #args
  local all = { M.target(conn, bucket), n = count + 1 }
  for i = 1, count do all[i + 1] = args[i] end

  local ok, result = pcall(function()
    return arbor.ext.call{
      interface = INTERFACE,
      id        = provider_id(conn),
      method    = method,
      args      = all,
    }
  end)
  if not ok then return nil, plain_error(result) end
  return result, nil
end

-- ── The whole-answer operations ─────────────────────────────────────────────

function M.test(conn, bucket)
  return M.call(conn, bucket, "test", {})
end

--- Run `test` and tell the user how it went — the one place both "Test connection" buttons end.
--
-- The credential is renewed first (a stale OAuth token would otherwise read as a failed
-- connection), and the verdict is notified right here: the old shape emitted an event to this
-- same plugin and a second handler decoded it, a hop that read `reply` off a payload that never
-- carried one — so a passing test showed nothing at all.
function M.test_and_notify(conn, bucket)
  local name = conn.name or conn.id or ""
  arbor.notify{ title = "Testing connection…", message = name, level = "info" }
  if not M.available(conn) then
    arbor.notify{ title = "Connection failed", message = M.missing_message(conn), level = "error" }
    return
  end
  M.ensure(conn, function(authed, auth_err)
    -- The sign-in's own answer is the useful one: "cannot read the key file" or "not signed in"
    -- says what to fix, where the store's "no token" afterwards would only say it is missing.
    if not authed then
      arbor.notify{ title = "Connection failed", message = tostring(auth_err), level = "error" }
      return
    end
    local _, err = M.test(conn, bucket)
    if err then
      arbor.notify{ title = "Connection failed", message = tostring(err), level = "error" }
    else
      arbor.notify{ title = "Connection OK", message = name, level = "success" }
    end
  end)
end

--- One page. `cursor` is the store's own continuation token; `nil` starts at the beginning.
--
-- `delimiter = "/"` gives the folder-shaped view; passing `nil` walks everything under the
-- prefix, which is what a recursive search does.
function M.list(conn, bucket, prefix, opts)
  opts = opts or {}
  -- `table.pack` and not a constructor: the first page has no cursor, and a plain list would
  -- end at that nil — dropping `limit` off the end of the call, or failing on the arity.
  return M.call(conn, bucket, "list", table.pack(
    prefix or "",
    opts.delimiter,
    opts.cursor,
    opts.limit
  ))
end

--- Every page under a prefix, walked. `on_page(entries, done)` is called per page, so a
--- caller can render as it goes instead of waiting for a bucket with 40 000 objects.
--
-- `hard_cap` stops a walk that would never end — a prefix matching a million keys is a
-- mistake, not a request, and the caller is told it was truncated rather than left to wonder.
function M.list_all(conn, bucket, prefix, opts)
  opts = opts or {}
  local cap       = opts.hard_cap or 10000
  local delimiter = opts.delimiter
  local out, cursor, truncated = {}, nil, false

  repeat
    local page, err = M.list(conn, bucket, prefix, {
      delimiter = delimiter,
      cursor    = cursor,
      limit     = opts.page_size or 1000,
    })
    if err then return nil, err end
    if type(page) ~= "table" then
      return nil, "the provider answered a listing that is not a record"
    end

    -- The continuation, and this loop's only exit. `cursor` is an `option<string>` on the
    -- interface, so a completed listing crosses as JSON `null` — and anything that is not a
    -- non-empty string has to read as "no more pages" here. A null the host lowered to
    -- something truthy would otherwise ask for page one again with `pageToken` unset, every
    -- time: a walk that never advances and never ends, which on screen is indistinguishable
    -- from a slow bucket.
    local next_cursor = nil
    if type(page.cursor) == "string" and page.cursor ~= "" then next_cursor = page.cursor end

    for _, entry in ipairs(page.entries or {}) do
      out[#out + 1] = entry
      if #out >= cap then truncated = true break end
    end
    if opts.on_page then opts.on_page(page.entries or {}, next_cursor == nil) end
    if opts.cancelled and opts.cancelled() then break end

    cursor = next_cursor
  until cursor == nil or truncated

  return { entries = out, truncated = truncated }, nil
end

function M.stat(conn, bucket, key)
  return M.call(conn, bucket, "stat", { key })
end

function M.delete(conn, bucket, key)
  return M.call(conn, bucket, "delete", { key })
end

function M.copy(conn, bucket, source, destination)
  return M.call(conn, bucket, "copy", { source, destination })
end

-- ── The payload operations ──────────────────────────────────────────────────

--- Read one range of an object straight into a local file. Returns bytes written.
--
-- `append` is what makes a chunked download possible: the first range replaces the file, every
-- one after it adds to the end. The bytes go from the provider to the file — this function
-- never sees them.
function M.read_to_file(conn, bucket, key, path, range, append)
  local ok, written = pcall(function()
    return arbor.ext.call_to_file{
      interface = INTERFACE,
      id        = provider_id(conn),
      method    = "read",
      args      = { M.target(conn, bucket), key, range },
      path      = path,
      append    = append and true or false,
    }
  end)
  if not ok then return nil, tostring(written) end
  return written, nil
end

--- Write a slice of a local file as an object.
--
-- `file_arg = 3` is the `body` parameter of the provider's `write` — the target is 1 and the
-- key is 2. The `false` in its place is a placeholder the host ignores; `nil` cannot be used
-- because it would end the argument list.
function M.write_from_file(conn, bucket, key, path, opts)
  opts = opts or {}
  local ok, result = pcall(function()
    return arbor.ext.call_from_file{
      interface = INTERFACE,
      id        = provider_id(conn),
      method    = "write",
      args      = { M.target(conn, bucket), key, false, opts.content_type },
      file_arg  = 3,
      path      = path,
      offset    = opts.offset or 0,
      length    = opts.length or 0,
    }
  end)
  if not ok then return nil, tostring(result) end
  return result, nil
end

--- Ask the provider package to make this connection's credentials usable.
--
-- Every provider exports `ensure`, and what it does — renew a token, adopt a credentials
-- file, nothing at all — is its business; the panel only says when it would be a good moment.
-- Asynchronous because `arbor.service.call` is, and because the alternative would be blocking
-- every browse on a network call that is usually unnecessary.
--
-- `done(ok, err)` is for the caller that cannot proceed without the answer — the retry after
-- a listing was refused. Left out, this is fire-and-forget, which is what the speculative
-- renewal at the top of a browse wants.
--
-- It does NOT notify. It used to, and on a connection nobody had signed into yet that meant a
-- warning toast on every single refresh of the panel, saying what the row under it already
-- said — with the difference that the row can be clicked and the toast could not. A failure
-- here is reported by whatever operation follows it, where the user is already looking.
function M.ensure(conn, done)
  if not conn or not M.available(conn) then
    if done then done(false, conn and M.missing_message(conn) or "no connection") end
    return
  end
  local args = { method = (conn.gcs and conn.gcs.method) or "oauth" }
  if args.method == "sa_file" then
    local text, err = M.read_key_file(conn)
    if not text then
      if done then done(false, err) end
      return
    end
    args.key_json = text
  end
  local service = "cloud-" .. provider_id(conn) .. ".ensure"
  arbor.service.call(service, args,
    function(ok, res)
      local renewed = (ok and res and res.ok) and true or false
      if not done then return end
      if renewed then
        done(true, nil)
      else
        done(false, (res and res.error) or "the provider could not authenticate")
      end
    end)
end

--- The text of the service-account key FILE a connection points at. `(text, nil)` or `(nil, err)`.
---
--- The form keeps only the file's path, in plain, and the key stays where the user put it: it is
--- read here, for the length of one `ensure`, and handed to the provider as an argument of that
--- call — never written to the credential store, and not kept in this package either. A package
--- may touch only its own credential slots and has no disk access of its own, which is why it is
--- this package, holding the filesystem permission, that reads it. Re-read on every call rather
--- than cached: the file is small, and an edited or replaced key is then used the next time.
function M.read_key_file(conn)
  local path = conn.gcs and conn.gcs.path
  if not path or path == "" then
    return nil, "this connection has no service-account key file set."
  end
  local raw, err = arbor.fs.read(path)
  if not raw then
    return nil, "cannot read the service-account file " .. path .. ": " .. tostring(err)
  end
  return raw, nil
end

--- Whether a provider for this connection's kind is installed at all.
--
-- Asked before an operation rather than discovered as a failure three calls in: "install the
-- GCS package" is a different sentence from "the store refused", and a user who sees the
-- second when the first is true goes looking at their credentials.
function M.available(conn)
  local id = provider_id(conn)
  for _, e in ipairs(arbor.ext.list() or {}) do
    if e.interface == INTERFACE and e.id == id then return true end
  end
  return false
end

--- The message to show when it is not.
function M.missing_message(conn)
  local id = provider_id(conn)
  return "No provider package for '" .. id .. "' is installed and enabled. "
      .. "Install it from the Marketplace — the panel cannot reach a store without one."
end

return M
