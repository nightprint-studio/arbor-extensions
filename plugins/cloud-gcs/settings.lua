-- settings.lua — the OAuth client this package signs in with.
--
-- Two fields, and they are the user's own: Google issues an OAuth client per application, and
-- a client id shipped inside a package would be shared by everybody who installed it — one
-- quota, one consent screen, one thing to revoke.
--
-- The client SECRET is stored beside the id rather than in the keychain, deliberately: for an
-- installed application it is not a secret at all (the OAuth spec says so — a desktop client
-- cannot keep one), and putting it in the keychain would suggest otherwise. What does go in
-- the keychain is what it buys: the refresh token, in this package's `oauth` slot.

local M = {}

--- `(client_id, client_secret)`, either possibly empty.
function M.client()
  local id     = arbor.settings.global.get("client_id") or ""
  local secret = arbor.settings.global.get("client_secret") or ""
  return id, secret
end

function M.set_client(id, secret)
  arbor.settings.global.set("client_id", id or "")
  arbor.settings.global.set("client_secret", secret or "")
end

function M.register()
  arbor.ui.settings.panel({
    id           = "main",
    title        = "Google Cloud Storage · Sign-in",
    icon         = "Cloud",
    width        = "560px",
    height       = "420px",
    submit_label = "Save",
    cancel_label = "Cancel",
    on_load      = "cloud-gcs:settings-refresh",
  })
  M.contribute_sections()
end

function M.contribute_sections()
  local id, secret = M.client()
  arbor.ui.contribute("cloud-gcs:settings:section", {
    id      = "oauth",
    payload = {
      label    = "OAuth client",
      icon     = "KeyRound",
      priority = 100,
      on_save  = "cloud-gcs:settings-save",
      nodes = {
        { type = "label",
          text = "Register a Desktop OAuth client at console.cloud.google.com/apis/credentials "
              .. "and paste it here. The redirect URI to register is http://127.0.0.1:7732/." },
        { type = "text", name = "client_id", label = "Client ID", default = id },
        { type = "text", name = "client_secret", label = "Client secret", default = secret },
      },
    },
  })
end

return M
