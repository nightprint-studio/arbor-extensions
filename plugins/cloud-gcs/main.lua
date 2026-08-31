-- main.lua — the Google half of a GCS connection: signing in, and keeping the token fresh.
--
-- The wasm component beside this file talks to the bucket. It cannot run an OAuth flow —
-- a guest has no sockets, and the browser has to come back to a loopback port somebody is
-- listening on — so the flow lives here, in the package that OWNS the credential slot.
--
-- ## Why not in the panel
--
-- Because the panel would then know what Google is. `cloud-storage` draws the browser and
-- orchestrates transfers for every store; the moment it carries one provider's endpoints,
-- scopes and consent quirks, adding a second provider means editing it. So the panel asks
-- this package to connect, by name, and never learns how:
--
--   arbor.service.call("cloud-gcs.connect", {}, function(ok, res) … end)
--
-- The credential rule makes the same point structurally: a package can only reach the slots
-- its own manifest declares, so the token can only be written by the package that reads it.
--
-- ## What Arbor supplies
--
-- `arbor.oauth` — the loopback listener and the keychain, and nothing else. Every Google
-- specific here (the two endpoints, the scope, `access_type=offline` + `prompt=consent`) is
-- an argument, which is why Arbor contains no mention of Google.

local settings = require("settings")
local auth     = require("auth")

-- The endpoints and scope this provider needs. Constants HERE, arguments to Arbor.
local AUTH_URL      = "https://accounts.google.com/o/oauth2/v2/auth"
local TOKEN_URL     = "https://oauth2.googleapis.com/token"
local SCOPE         = "https://www.googleapis.com/auth/devstorage.read_write"
-- Registered with the OAuth client as its redirect URI, so it cannot be ephemeral.
local CALLBACK_PORT = 7732
local SLOT          = "oauth"

-- ── Signing in ──────────────────────────────────────────────────────────────

--- Start the flow. Returns the URL the caller should open.
local function connect()
  local client_id, client_secret = settings.client()
  if client_id == "" then
    return nil, "Set a Google OAuth client id in this package's settings first. "
             .. "Register a Desktop client at https://console.cloud.google.com/apis/credentials."
  end

  local ok, url = pcall(function()
    return arbor.oauth.start{
      slot          = SLOT,
      auth_url      = AUTH_URL,
      token_url     = TOKEN_URL,
      client_id     = client_id,
      client_secret = client_secret ~= "" and client_secret or nil,
      scope         = SCOPE,
      redirect_port = CALLBACK_PORT,
      -- `access_type=offline` is what makes Google return a refresh token the first time;
      -- `prompt=consent` forces the consent screen on later grants, so a re-authorisation
      -- after a revoked token yields a fresh one instead of silently failing.
      extra_params  = { access_type = "offline", prompt = "consent" },
      label         = "Google Cloud Storage",
      on_done       = "cloud-gcs:oauth-done",
    }
  end)
  if not ok then return nil, tostring(url) end
  return url, nil
end

--- Renew the access token if it is close to expiring.
---
--- Called before an operation rather than after a 401: a refused request has already cost a
--- round trip and, in a transfer, has already failed a chunk.
local function refresh(min_remaining)
  local ok, res = pcall(function()
    return arbor.oauth.refresh{
      slot               = SLOT,
      token_url          = TOKEN_URL,
      min_remaining_secs = min_remaining or 120,
    }
  end)
  if not ok then return nil, tostring(res) end
  return res, nil
end

-- ── The service surface the panel calls ─────────────────────────────────────

arbor.events.on("arbor:plugin_load", function()
  settings.register()

  -- `arbor.oauth.start` opens the browser itself and hands the URL back, so a caller that
  -- wants to show it ("didn't open? use this link") has it. A package cannot open a URL on
  -- its own, and giving it a way to would be a way to open any URL.
  arbor.service.export("connect", function()
    local url, err = connect()
    if err then return { ok = false, error = err } end
    return { ok = true, auth_url = url }
  end)

  arbor.service.export("refresh", function(args)
    local res, err = refresh(args and args.min_remaining_secs)
    if err then return { ok = false, error = err } end
    return { ok = true, refreshed = res.refreshed, expires_in = res.expires_in }
  end)

  -- The call the panel makes before it uses this provider: "whatever route this connection
  -- authenticates by, make it usable now". Every provider package is expected to export it,
  -- so the panel can prepare a connection without knowing what preparing means.
  arbor.service.export("ensure", function(args)
    local ok, err = auth.ensure(args and args.method)
    if not ok then return { ok = false, error = err } end
    return { ok = true }
  end)

  -- What this provider can actually do today, so the connection form offers the routes that
  -- work rather than the ones that will fail an hour later.
  -- The panel takes the key from the user and hands it here: a package can only write its
  -- own credential slots, so a key that belongs to this provider has to arrive by a call
  -- rather than be written into a shared place.
  arbor.service.export("set-service-account", function(args)
    local ok, err = auth.set_key(args and args.json)
    if not ok then return { ok = false, error = err } end
    return { ok = true }
  end)

  arbor.service.export("clear-service-account", function()
    auth.clear_key()
    return { ok = true }
  end)

  arbor.service.export("methods", function()
    return {
      supported = { "oauth", "adc", "sa_file", "sa_inline" },
      unsupported = {},
    }
  end)

  -- Keep the token ahead of its expiry rather than discovering it is stale mid-transfer. Five
  -- minutes is well inside Google's hour, and a refresh with life left is a no-op.
  arbor.timer.every(5 * 60 * 1000, function()
    pcall(function() auth.ensure("oauth") end)
  end)

  -- "Is this connected?" answered without moving a secret: the slot's presence is the whole
  -- of what a settings panel needs to know.
  arbor.service.export("status", function()
    local filled = false
    for _, slot in ipairs(arbor.credentials.list() or {}) do
      if slot.key == SLOT then filled = slot.filled and true or false end
    end
    return { connected = filled, client_configured = settings.client() ~= "" }
  end)

  arbor.service.export("disconnect", function()
    local ok, err = pcall(function() arbor.credentials.delete(SLOT) end)
    if not ok then return { ok = false, error = tostring(err) } end
    return { ok = true }
  end)

  arbor.log.info("cloud-gcs ready")
end)

arbor.events.on("cloud-gcs:settings-refresh", function()
  settings.contribute_sections()
end)

arbor.events.on("cloud-gcs:settings-save", function(ctx)
  settings.set_client(ctx.client_id, ctx.client_secret)
end)

-- The flow's own outcome. Re-broadcast under a name the panel can subscribe to without
-- knowing which provider ran: the panel shows "connected" the same way for every store.
arbor.events.on("cloud-gcs:oauth-done", function(ctx)
  if ctx.ok then
    arbor.notify{
      title   = "Google Cloud Storage",
      message = "Signed in. The bucket list is available now.",
      level   = "success",
    }
  else
    arbor.notify{
      title   = "Google sign-in failed",
      message = tostring(ctx.error or "unknown error"),
      level   = "error",
    }
  end
  arbor.events.emit("cloud:provider-connected", {
    provider = "gcs",
    ok       = ctx.ok and true or false,
    error    = ctx.error,
  })
end)
