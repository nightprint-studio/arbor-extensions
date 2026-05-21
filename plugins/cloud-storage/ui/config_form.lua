-- ui/config_form.lua — "New / Edit connection" form (Big Data Tools style).
--
-- One modal with conditional fields based on the chosen auth method.
-- Submit dispatches to one of two actions:
--   · cloud:save_connection    — persist + close
--   · cloud:test_connection    — fire test_connection and re-open the form
--                                with the report in a label node
--   · cloud:start_oauth        — kick off the OAuth flow, wait for the
--                                `arbor://cloud-oauth-done` event, then
--                                re-open this form so the user can save.

local state = require("state")

local M = {}

local AUTH_OPTIONS = {
  { value = "sa_file",    label = "Service account · JSON file path" },
  { value = "sa_inline",  label = "Service account · paste JSON" },
  { value = "adc",        label = "Application Default Credentials (ADC)" },
  { value = "gcloud_cli", label = "gcloud CLI · print-access-token" },
  { value = "oauth",      label = "OAuth user (browser)" },
}

local PROVIDER_OPTIONS = {
  { value = "gcs",    label = "Google Cloud Storage" },
  { value = "s3",     label = "Amazon S3 (coming soon)",     disabled = true },
  { value = "azblob", label = "Azure Blob Storage (coming soon)", disabled = true },
}

-- ── Helpers ────────────────────────────────────────────────────────────────

local function existing_or_new(conn_id)
  if conn_id and conn_id ~= "" then
    local c = state.find(conn_id)
    if c then return c end
  end
  return {
    id       = state.new_id(),
    name     = "",
    provider = "gcs",
    project_id = "",
    default_bucket = "",
    gcs = { method = "sa_file" },
  }
end

-- Build the form nodes from a connection record (the form is "state =
-- whole connection" — re-rendered on every step so conditional fields
-- appear / disappear without lookups).
local function build_nodes(c, banner)
  local gcs = c.gcs or {}
  local method = gcs.method or "sa_file"

  local nodes = {}

  if banner and banner ~= "" then
    nodes[#nodes + 1] = { type = "label", text = banner }
    nodes[#nodes + 1] = { type = "divider" }
  end

  nodes[#nodes + 1] = { type = "text", name = "name", label = "Name",
    placeholder = "e.g. prod-gcs", default = c.name or "", required = true }
  nodes[#nodes + 1] = { type = "select", name = "provider", label = "Provider",
    options = PROVIDER_OPTIONS, default = c.provider or "gcs", required = true }
  nodes[#nodes + 1] = { type = "text", name = "default_bucket", label = "Default bucket",
    placeholder = "my-bucket", default = c.default_bucket or "",
    hint = "Shown in the sidebar header. You can browse other buckets after connecting." }
  nodes[#nodes + 1] = { type = "text", name = "project_id", label = "Project id",
    placeholder = "my-gcp-project", default = c.project_id or "",
    hint = "Optional — most object ops don't need it; some admin APIs do." }
  nodes[#nodes + 1] = { type = "divider" }
  nodes[#nodes + 1] = { type = "select", name = "auth_method", label = "Authentication",
    options = AUTH_OPTIONS, default = method, required = true }

  -- Conditional fields per method. The form DSL doesn't have native
  -- conditional rendering — the trick is to re-render the whole form on
  -- the on_change of `auth_method`, see `cloud:auth_method_changed`.
  if method == "sa_file" then
    nodes[#nodes + 1] = { type = "file", name = "sa_path",
      label = "Service account JSON",
      pick_mode = "file",
      extensions = { "json" },
      placeholder = "Pick the SA JSON file…",
      default = gcs.path or "", required = true,
      hint = "Path to the JSON key file downloaded from the GCP console." }
  elseif method == "sa_inline" then
    nodes[#nodes + 1] = { type = "textarea", name = "sa_json",
      label = "Service account JSON",
      rows = 12,
      placeholder = '{ "type": "service_account", … }',
      default = "",  -- never shown back: it's already in the keyring
      required = true,
      hint = "Pasted JSON is stored encrypted in your OS keychain. The textarea is "
          .. "cleared after save and never re-displays the secret." }
  elseif method == "adc" then
    nodes[#nodes + 1] = { type = "label",
      text = "Reads credentials from $GOOGLE_APPLICATION_CREDENTIALS or "
          .. "~/.config/gcloud/application_default_credentials.json. "
          .. "Run `gcloud auth application-default login` to set it up." }
  elseif method == "gcloud_cli" then
    nodes[#nodes + 1] = { type = "label",
      text = "Spawns `gcloud auth print-access-token` on every connect. "
          .. "Requires the Google Cloud SDK installed and logged in." }
  elseif method == "oauth" then
    nodes[#nodes + 1] = { type = "text", name = "oauth_client_id",
      label = "OAuth client_id",
      placeholder = "xxx.apps.googleusercontent.com",
      default = gcs.client_id or "", required = true,
      hint = "Register a Desktop OAuth client at console.cloud.google.com/apis/credentials." }
    nodes[#nodes + 1] = { type = "text", name = "oauth_client_secret",
      label = "OAuth client_secret",
      placeholder = "(optional for Desktop apps)", default = "" }
    nodes[#nodes + 1] = { type = "label",
      text = "Click Authorize — Arbor opens your browser, asks Google for offline "
          .. "access, stores the refresh token in your OS keychain (never on disk)." }
    nodes[#nodes + 1] = { type = "button", variant = "primary",
      icon = "ExternalLink", label = "Authorize with Google…",
      action = "cloud:start_oauth_inline" }
  end

  -- Inline "Test connection" button — fires test_connection without saving.
  nodes[#nodes + 1] = { type = "divider" }
  nodes[#nodes + 1] = { type = "button", variant = "ghost",
    icon = "Plug", label = "Test connection",
    action = "cloud:test_connection_inline" }

  return nodes
end

-- ── Open the form ──────────────────────────────────────────────────────────

function M.open(conn_id, banner)
  local c = existing_or_new(conn_id)
  local is_new = (conn_id == nil or conn_id == "")

  -- Stash the working record on the form's `state` so subsequent
  -- submit/cancel actions can read it back even if the user changed the
  -- auth method mid-form. We rely on Lua passing the table by reference —
  -- the form orchestrator echoes `state` keys back via ctx.state.<k>.
  arbor.ui.form({
    title         = is_new and "New cloud connection" or "Edit cloud connection",
    description   = "Connect Arbor to a cloud storage bucket. The plugin handles "
                 .. "browsing, downloads, uploads and recursive directory sync.",
    submit_label  = "Save",
    submit_action = "cloud:save_connection",
    cancel_label  = "Cancel",
    cancel_action = "cloud:cancel_form",
    width         = "640px",
    height        = "720px",
    state         = { conn_id = c.id, is_new = is_new },
    nodes = build_nodes(c, banner),
  })
end

-- Re-open the form when the auth method changes — used by main.lua to
-- swap conditional fields without losing the in-flight values.
function M.reopen_with_method(prev_ctx, banner)
  local c = state.find(prev_ctx.conn_id) or existing_or_new(nil)
  c.name           = prev_ctx.name           or c.name
  c.provider       = prev_ctx.provider       or c.provider
  c.default_bucket = prev_ctx.default_bucket or c.default_bucket
  c.project_id     = prev_ctx.project_id     or c.project_id
  c.gcs            = c.gcs or {}
  c.gcs.method     = prev_ctx.auth_method    or (c.gcs.method or "sa_file")
  c.gcs.path       = prev_ctx.sa_path        or c.gcs.path
  c.gcs.client_id  = prev_ctx.oauth_client_id or c.gcs.client_id
  M.open(c.id, banner)
end

return M
