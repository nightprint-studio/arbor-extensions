-- auth.lua — getting an access token, by whichever route this connection uses.
--
-- The wasm component authenticates one way: it reads an access token out of this package's
-- `oauth` slot and sends it as a bearer. Everything that produces such a token lives here, in
-- Lua, because the routes differ in what they need and only one of them is a network call:
--
--   · **oauth**  — the sign-in this package ran. `arbor.oauth.refresh` renews it.
--   · **adc**    — the file `gcloud auth application-default login` writes. When it holds an
--                  authorized-user grant it is a refresh token with a client beside it, which
--                  is the same shape our own slot uses — so it is adopted and refreshed
--                  through the same engine, with no Google-specific code anywhere.
--   · **sa**     — a service-account key. The one route that needs cryptography: the key
--                  signs a JWT and the JWT buys a token. The signing happens inside the wasm
--                  component (Lua has no RSA), and what comes back is stored like any other
--                  token — so from the request's point of view all three routes end the same.
--
-- ## Why not `gcloud auth print-access-token`
--
-- It would mean running a process, which is a capability a storage provider has no business
-- holding — and the token it prints expires in an hour with nothing to renew it from. The ADC
-- file that `gcloud` itself writes carries a refresh token, so the same user gets a better
-- answer from a file read.

local M = {}

local SLOT      = "oauth"
--- The slot the service-account KEY lives in — separate from the token slot beside it.
---
--- Two slots because they are two different secrets with two different lifetimes: the key is
--- what the user gave us and is good until they revoke it, the token is derived and lasts an
--- hour. Keeping the key out of the token slot also means a refresh can overwrite one without
--- touching the other.
local KEY_SLOT  = "service-account"
local TOKEN_URL = "https://oauth2.googleapis.com/token"
local SCOPE     = "https://www.googleapis.com/auth/devstorage.read_write"

--- Seconds of life left in the stored access token, or 0.
local function token_remaining()
  local ok, raw = pcall(function() return arbor.credentials.get(SLOT) end)
  if not ok or not raw or raw == "" then return 0 end
  local parsed_ok, tokens = pcall(arbor.json.decode, raw)
  if not parsed_ok or type(tokens) ~= "table" then return 0 end
  if not tokens.access_token or not tokens.expires_at then return 0 end
  local left = tonumber(tokens.expires_at) - os.time()
  return left > 0 and left or 0
end

--- Mint a fresh access token from the stored service-account key.
---
--- The signing happens inside the wasm component — Lua has no RSA, and the key never leaves
--- the slot for anywhere but there. What comes back is stored in the token slot, which is
--- where the very same component reads its bearer from on the next request.
local function mint_from_key()
  local key = nil
  local ok = pcall(function() key = arbor.credentials.get(KEY_SLOT) end)
  if not ok or not key or key == "" then
    return false, "no service-account key is stored for this package. Paste one in the "
               .. "connection form, or sign in with a Google account instead."
  end

  local called, result = pcall(function()
    return arbor.ext.call{
      interface = "cloud-provider", id = "gcs", method = "mint-token",
      args      = { key, SCOPE, os.time() },
    }
  end)
  if not called then return false, tostring(result) end

  local tokens = {
    -- No refresh token: a service-account key IS the renewable credential, and minting again
    -- is the renewal. Recorded as empty rather than absent so the shape stays the one the
    -- OAuth path writes.
    refresh_token = "",
    access_token  = result.access_token or result["access-token"],
    expires_at    = os.time() + math.max(0, (result.expires_in or result["expires-in"] or 3600) - 30),
  }
  local saved = pcall(function() arbor.credentials.set(SLOT, arbor.json.encode(tokens)) end)
  if not saved then return false, "could not store the minted token" end
  return true, nil
end

--- Store a service-account key file's contents. Called by the panel through the service below.
function M.set_key(json)
  if type(json) ~= "string" or json == "" then
    return false, "no key given"
  end
  local parsed_ok, parsed = pcall(arbor.json.decode, json)
  if not parsed_ok or type(parsed) ~= "table" or not parsed.private_key then
    return false, "that does not look like a service-account key file (no private_key)"
  end
  local ok = pcall(function() arbor.credentials.set(KEY_SLOT, json) end)
  if not ok then return false, "could not store the key" end
  -- Mint immediately: the user has just pasted a key and is entitled to find out now whether
  -- it works, rather than at the first listing.
  return mint_from_key()
end

--- Forget the stored key and any token derived from it.
function M.clear_key()
  pcall(function() arbor.credentials.delete(KEY_SLOT) end)
  pcall(function() arbor.credentials.delete(SLOT) end)
end

--- Where `gcloud auth application-default login` leaves its credentials.
---
--- One path on every platform, because gcloud puts it under the OS config directory — which
--- is `%APPDATA%` on Windows and `~/.config` elsewhere, exactly what `user_dirs().config`
--- reports. `GOOGLE_APPLICATION_CREDENTIALS` would override it, but reading it would mean
--- reading environment variables, which this package cannot and should not do.
local function adc_path()
  local dirs = arbor.fs.user_dirs() or {}
  if not dirs.config then return nil end
  return arbor.fs.join(dirs.config, "gcloud", "application_default_credentials.json")
end

--- Read and parse the ADC file. `(table, raw_json, nil)` or `(nil, nil, err)`.
---
--- The raw text comes back too: a service-account ADC file is a key we adopt whole, and
--- re-encoding a parsed table would rewrite a document we are about to sign with.
local function read_adc()
  local path = adc_path()
  if not path then
    return nil, nil, "cannot locate this user's config directory"
  end
  if not arbor.fs.exists(path) then
    return nil, nil, "no application-default credentials found. Run:\n\n"
                  .. "    gcloud auth application-default login\n\n"
                  .. "then try again — that writes " .. path
  end
  local raw, err = arbor.fs.read(path)
  if not raw then return nil, nil, "reading " .. path .. ": " .. tostring(err) end
  local ok, parsed = pcall(arbor.json.decode, raw)
  if not ok or type(parsed) ~= "table" then
    return nil, nil, path .. " is not valid JSON"
  end
  return parsed, raw, nil
end

--- Adopt an authorized-user ADC grant into this package's own slot.
---
--- The two shapes are the same document — a refresh token, the client it was issued to — so
--- adopting is a copy, and from then on the ordinary refresh path keeps it alive. What this
--- deliberately does NOT do is read the file on every request: a credential that lives in the
--- keychain survives the file being deleted, and is the one place this package looks.
local function adopt_adc(adc)
  local tokens = {
    refresh_token = adc.refresh_token or "",
    client_id     = adc.client_id,
    client_secret = adc.client_secret,
  }
  if tokens.refresh_token == "" or not tokens.client_id then
    return false, "the ADC file has no usable refresh token"
  end
  local ok, err = pcall(function()
    arbor.credentials.set(SLOT, arbor.json.encode(tokens))
  end)
  if not ok then return false, tostring(err) end
  return true, nil
end

--- Make sure the slot holds a usable access token for `method`.
---
--- Returns `(true, nil)` when there is one, `(false, err)` when the user has to do something.
--- Safe to call often: the refresh is a no-op while the stored token has life left.
function M.ensure(method)
  method = method or "oauth"

  if method == "oauth" then
    local ok, res = pcall(function()
      return arbor.oauth.refresh{ slot = SLOT, token_url = TOKEN_URL, min_remaining_secs = 300 }
    end)
    if not ok then return false, tostring(res) end
    return true, nil
  end

  if method == "adc" or method == "gcloud_cli" then
    local adc, raw_adc_json, err = read_adc()
    if not adc then return false, err end

    if adc.type == "authorized_user" then
      local adopted, aerr = adopt_adc(adc)
      if not adopted then return false, aerr end
      local ok, res = pcall(function()
        return arbor.oauth.refresh{ slot = SLOT, token_url = TOKEN_URL, min_remaining_secs = 300 }
      end)
      if not ok then return false, tostring(res) end
      return true, nil
    end

    if adc.type == "service_account" then
      -- ADC pointing at a service-account key is the same key by another route: adopt it into
      -- the key slot and mint, rather than telling the user to paste what they already have.
      local stored, serr = M.set_key(raw_adc_json)
      if not stored then return false, serr end
      return true, nil
    end

    return false, "unrecognised credentials type '" .. tostring(adc.type) .. "'"
  end

  if method == "sa_file" or method == "sa_inline" then
    -- A minted token has no refresh token to renew it: minting again IS the renewal, so the
    -- check is "is the one we have still good?" and the answer to no is another exchange.
    if token_remaining() > 300 then return true, nil end
    return mint_from_key()
  end

  return false, "unknown authentication method '" .. tostring(method) .. "'"
end

--- Whether `method` can work at all today. Asked by the panel before it offers one.
function M.supports(method)
  return method == "oauth" or method == "adc" or method == "gcloud_cli"
      or method == "sa_file" or method == "sa_inline"
end

return M
