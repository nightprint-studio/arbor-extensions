-- ui/connections_modal.lua — IntelliJ-style "Manage cloud connections" modal.
--
-- Replaces the trio of toolbar buttons (new / edit / delete) with a single
-- entry point that mirrors "Edit Run Configurations" from IDEs: left rail
-- groups every saved connection by provider, right pane edits the selected
-- one in place. State transitions (select / add / delete) use
-- arbor.ui.form.replace so the modal never closes/reopens — the nav and the
-- body update in-place with no flicker.

local state    = require("state")
local cf       = require("ui.config_form")

local M = {}

local AUTH_OPTIONS = {
  { value = "sa_file",    label = "Service account · JSON file path" },
  { value = "sa_inline",  label = "Service account · paste JSON" },
  { value = "adc",        label = "Application Default Credentials (ADC)" },
  { value = "gcloud_cli", label = "gcloud CLI · print-access-token" },
  { value = "oauth",      label = "OAuth user (browser)" },
}

-- Per-provider metadata for the left rail grouping.  Icons are bundled
-- Iconify simple-icons glyphs (build-time imports, no runtime network) —
-- see PluginIcon.svelte and brand-icons.ts.
local PROVIDERS = {
  { id = "gcs",    label = "Google Cloud Storage", icon = "brand:google_cloud",    enabled = true },
  { id = "s3",     label = "Amazon S3",            icon = "brand:amazon_s3",       enabled = true },
  { id = "azblob", label = "Azure Blob Storage",   icon = "brand:microsoft_azure", enabled = true },
}

local DRAFT_PREFIX = "draft:"

-- ── Helpers ────────────────────────────────────────────────────────────────

local function is_draft(id) return id and id:sub(1, #DRAFT_PREFIX) == DRAFT_PREFIX end

local function provider_meta(id)
  for _, p in ipairs(PROVIDERS) do if p.id == id then return p end end
  return nil
end

-- Working state lives in M._working: a transient mirror of the persisted
-- list that may also contain unsaved drafts (id prefixed with "draft:").
-- We rebuild it from disk whenever the modal opens; subsequent edits stay
-- in-memory until the user clicks Save.
M._working = nil
M._active  = nil   -- id of the currently-edited connection

local function load_working()
  local saved = state.load_connections()
  M._working = {}
  for _, c in ipairs(saved) do
    -- Shallow-clone so edits in the modal don't mutate the persisted record
    -- before the user saves.
    local clone = { id = c.id, name = c.name, provider = c.provider,
                    project_id = c.project_id, default_bucket = c.default_bucket }
    if c.gcs then
      clone.gcs = {
        method     = c.gcs.method,
        path       = c.gcs.path,
        secret_ref = c.gcs.secret_ref,
        client_id  = c.gcs.client_id,
      }
    end
    if c.s3 then
      clone.s3 = {
        access_key_id    = c.s3.access_key_id,
        secret_ref       = c.s3.secret_ref,
        region           = c.s3.region,
        endpoint         = c.s3.endpoint,
        force_path_style = c.s3.force_path_style,
      }
    end
    if c.azblob then
      clone.azblob = {
        account_name = c.azblob.account_name,
        secret_ref   = c.azblob.secret_ref,
        endpoint     = c.azblob.endpoint,
      }
    end
    M._working[#M._working + 1] = clone
  end
end

local function find_working(id)
  if not id then return nil end
  for _, c in ipairs(M._working or {}) do
    if c.id == id then return c end
  end
  return nil
end

-- Apply form values (ctx) onto a working record.  Field shape depends on
-- the provider — fields belonging to a non-matching provider are ignored.
-- Secret-bearing fields (sa_json, s3_secret_key, azure_account_key,
-- oauth_client_secret) are NEVER copied into the working record — they
-- go straight to the keyring at save-time.
local function patch_from_ctx(rec, ctx)
  if not rec or not ctx then return end
  if ctx.name           ~= nil then rec.name           = ctx.name end
  if ctx.default_bucket ~= nil then rec.default_bucket = ctx.default_bucket end
  if ctx.project_id     ~= nil then rec.project_id     = ctx.project_id end

  local prov = rec.provider or "gcs"
  if prov == "gcs" then
    rec.gcs = rec.gcs or {}
    if ctx.auth_method     ~= nil then rec.gcs.method    = ctx.auth_method end
    if ctx.sa_path         ~= nil then rec.gcs.path      = ctx.sa_path end
    if ctx.oauth_client_id ~= nil then rec.gcs.client_id = ctx.oauth_client_id end
  elseif prov == "s3" then
    rec.s3 = rec.s3 or {}
    if ctx.s3_access_key_id  ~= nil then rec.s3.access_key_id    = ctx.s3_access_key_id end
    if ctx.s3_region         ~= nil then rec.s3.region           = ctx.s3_region end
    if ctx.s3_endpoint       ~= nil then rec.s3.endpoint         = ctx.s3_endpoint end
    if ctx.s3_path_style     ~= nil then rec.s3.force_path_style = ctx.s3_path_style end
  elseif prov == "azblob" then
    rec.azblob = rec.azblob or {}
    if ctx.azure_account_name ~= nil then rec.azblob.account_name = ctx.azure_account_name end
    if ctx.azure_endpoint     ~= nil then rec.azblob.endpoint     = ctx.azure_endpoint end
  end
end

-- ── Right-pane builders ────────────────────────────────────────────────────

local function build_empty_body()
  return {
    { type = "paragraph", variant = "muted",
      content = "No connection selected. Use + Add to create one, or pick an existing connection from the list." },
  }
end

local function build_gcs_auth_nodes(rec)
  local gcs    = rec.gcs or {}
  local method = gcs.method or "sa_file"
  local nodes  = {
    { type = "select", name = "auth_method", label = "Authentication",
      options = AUTH_OPTIONS, default = method, required = true },
  }
  if method == "sa_file" then
    nodes[#nodes + 1] = { type = "file", name = "sa_path",
      label = "Service account JSON",
      pick_mode = "file", extensions = { "json" },
      placeholder = "Pick the SA JSON file…",
      default = gcs.path or "", required = true,
      hint = "Path to the JSON key file downloaded from the GCP console." }
  elseif method == "sa_inline" then
    nodes[#nodes + 1] = { type = "textarea", name = "sa_json",
      label = "Service account JSON", rows = 12,
      placeholder = '{ "type": "service_account", … }',
      default = "",
      hint = "Pasted JSON is stored in your OS keychain. The textarea is "
          .. "cleared after save and never re-displays the secret." }
  elseif method == "adc" then
    nodes[#nodes + 1] = { type = "label",
      text = "Reads credentials from $GOOGLE_APPLICATION_CREDENTIALS or "
          .. "~/.config/gcloud/application_default_credentials.json." }
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
    nodes[#nodes + 1] = { type = "button", variant = "primary",
      icon = "ExternalLink", label = "Authorize with Google…",
      action = "cloud:conn_modal_oauth" }
  end
  return nodes
end

local function build_s3_auth_nodes(rec)
  local s3 = rec.s3 or {}
  local nodes = {
    { type = "text", name = "s3_access_key_id", label = "Access key id",
      placeholder = "AKIA…", default = s3.access_key_id or "", required = true },
    { type = "password", name = "s3_secret_key", label = "Secret access key",
      placeholder = "(leave empty to keep current)", default = "",
      hint = "Stored in your OS keychain. The field is cleared after save "
          .. "and never re-displays the secret." },
    { type = "text", name = "s3_region", label = "Region",
      placeholder = "us-east-1", default = s3.region or "" },
    { type = "text", name = "s3_endpoint", label = "Endpoint",
      placeholder = "(optional — for MinIO / R2 / S3-compatible services)",
      default = s3.endpoint or "" },
    { type = "checkbox", name = "s3_path_style", label = "Force virtual-host style URLs",
      default = s3.force_path_style and true or false,
      hint = "Off (default) = path-style requests. Toggle on for buckets "
          .. "whose names contain dots, or per provider requirement." },
  }
  return nodes
end

local function build_azure_auth_nodes(rec)
  local a = rec.azblob or {}
  return {
    { type = "text", name = "azure_account_name", label = "Storage account name",
      placeholder = "myaccount", default = a.account_name or "", required = true },
    { type = "password", name = "azure_account_key", label = "Account key",
      placeholder = "(leave empty to keep current)", default = "",
      hint = "Stored in your OS keychain. The field is cleared after save "
          .. "and never re-displays the secret." },
    { type = "text", name = "azure_endpoint", label = "Endpoint",
      placeholder = "(optional — for Azure Government / Stack)",
      default = a.endpoint or "" },
  }
end

local function build_edit_body(rec)
  if not rec then return build_empty_body() end
  local nodes = {}

  nodes[#nodes + 1] = { type = "text", name = "name", label = "Name",
    placeholder = "e.g. prod", default = rec.name or "", required = true }
  -- Provider is fixed once a connection exists. Read-only.
  local pmeta = provider_meta(rec.provider or "gcs")
  nodes[#nodes + 1] = { type = "text", name = "provider_label", label = "Provider",
    default = (pmeta and pmeta.label) or rec.provider or "gcs", readonly = true }
  local bucket_label = (rec.provider == "azblob") and "Default container" or "Default bucket"
  nodes[#nodes + 1] = { type = "text", name = "default_bucket", label = bucket_label,
    placeholder = "my-bucket", default = rec.default_bucket or "",
    hint = "Shown in the sidebar header. You can browse other buckets at runtime." }
  if rec.provider == "gcs" or rec.provider == nil then
    nodes[#nodes + 1] = { type = "text", name = "project_id", label = "Project id",
      placeholder = "my-gcp-project", default = rec.project_id or "",
      hint = "Optional — most object ops don't need it; some admin APIs do." }
  end
  nodes[#nodes + 1] = { type = "divider" }

  local prov = rec.provider or "gcs"
  local auth_nodes
  if prov == "s3"     then auth_nodes = build_s3_auth_nodes(rec)
  elseif prov == "azblob" then auth_nodes = build_azure_auth_nodes(rec)
  else                        auth_nodes = build_gcs_auth_nodes(rec)
  end
  for _, n in ipairs(auth_nodes) do nodes[#nodes + 1] = n end

  nodes[#nodes + 1] = { type = "divider" }
  nodes[#nodes + 1] = { type = "row", gap = 8, align = "center", children = {
    { type = "button", variant = "ghost",
      icon = "Plug", label = "Test connection",
      action = "cloud:conn_modal_test" },
  } }

  return nodes
end

-- ── Left-rail builder ──────────────────────────────────────────────────────
--
-- The rail is a real form `tree`: each provider is a collapsable group node
-- whose children are the saved + draft connections. Selecting a connection
-- fires `cloud:conn_modal_select`, which patches pending field edits onto
-- the previous active record and replaces the form to swap the right pane.

local function build_tree_nodes()
  local roots = {}
  for _, pmeta in ipairs(PROVIDERS) do
    local children = {}
    for _, c in ipairs(M._working or {}) do
      if (c.provider or "gcs") == pmeta.id then
        local name = c.name or ""
        if name == "" then name = is_draft(c.id) and "(unnamed draft)" or "(unnamed)" end
        if is_draft(c.id) then name = name .. "  •  draft" end
        children[#children + 1] = {
          value = c.id,
          label = name,
          icon  = pmeta.icon,
        }
      end
    end
    roots[#roots + 1] = {
      value    = "__group__:" .. pmeta.id,
      label    = pmeta.enabled and pmeta.label or (pmeta.label .. "  ·  coming soon"),
      group    = true,
      icon     = pmeta.icon,
      children = children,
    }
  end
  return roots
end

local function build_nav()
  -- "+ / −" toolbar lives at the TOP of the rail, above the tree.  The
  -- `pf-row:first-of-type` CSS rule in FormNodeRenderer already gives this
  -- row a bottom border + the right padding for the floating toggle, so
  -- visually it reads as a proper toolbar.
  local add_options = {}
  for _, pmeta in ipairs(PROVIDERS) do
    if pmeta.enabled then
      add_options[#add_options + 1] = {
        label  = pmeta.label,
        icon   = pmeta.icon,
        action = "cloud:conn_modal_add",
        extra  = { provider = pmeta.id },
      }
    end
  end
  return {
    {
      type = "row", gap = 6, align = "center",
      children = {
        {
          type = "menu_button", id = "conn-add-menu",
          variant = "ghost", icon = "Plus", icon_only = true,
          tooltip = "Add new connection…",
          options = add_options,
        },
        {
          type = "button", variant = "ghost", icon = "Minus",
          icon_only = true,
          tooltip = "Remove the selected connection",
          action = "cloud:conn_modal_delete_active",
        },
      },
    },
    {
      type          = "tree",
      name          = "conn_sel",
      bordered      = false,
      expanded      = true,   -- start with every provider group expanded
      default       = M._active or "",
      nodes         = build_tree_nodes(),
      change_action = "cloud:conn_modal_select",
    },
  }
end

-- ── Form open / re-render ──────────────────────────────────────────────────

local function build_root()
  return {
    {
      type             = "tree_layout",
      id               = "conn-tl",
      nav_width        = "280px",
      nav_collapsible  = false,
      nav_children     = build_nav(),
      content_children = build_edit_body(find_working(M._active)),
    },
  }
end

-- Build a complete `set_values` map for the currently-active record.  We
-- have to set every form field explicitly because `arbor.ui.form.replace`
-- ONLY re-applies `default` on a field that didn't exist before — fields
-- with the same name across rebuilds (e.g. `name`, `default_bucket`) keep
-- the old value, which is exactly the "previous connection's data leaks
-- through" bug.  Secret fields are always cleared on switch so we don't
-- echo back what the user just typed for a different connection.
local function build_set_values(rec)
  local v = {
    name                = "",
    provider_label      = "",
    default_bucket      = "",
    project_id          = "",
    auth_method         = "",
    sa_path             = "",
    sa_json             = "",
    oauth_client_id     = "",
    oauth_client_secret = "",
    s3_access_key_id    = "",
    s3_secret_key       = "",
    s3_region           = "",
    s3_endpoint         = "",
    s3_path_style       = false,
    azure_account_name  = "",
    azure_account_key   = "",
    azure_endpoint      = "",
  }
  if not rec then return v end
  v.name           = rec.name or ""
  local pmeta      = provider_meta(rec.provider or "gcs")
  v.provider_label = (pmeta and pmeta.label) or rec.provider or "gcs"
  v.default_bucket = rec.default_bucket or ""
  v.project_id     = rec.project_id or ""

  local prov = rec.provider or "gcs"
  if prov == "gcs" then
    local g = rec.gcs or {}
    v.auth_method     = g.method or "sa_file"
    v.sa_path         = g.path or ""
    v.oauth_client_id = g.client_id or ""
  elseif prov == "s3" then
    local s = rec.s3 or {}
    v.s3_access_key_id = s.access_key_id or ""
    v.s3_region        = s.region or ""
    v.s3_endpoint      = s.endpoint or ""
    v.s3_path_style    = s.force_path_style and true or false
  elseif prov == "azblob" then
    local a = rec.azblob or {}
    v.azure_account_name = a.account_name or ""
    v.azure_endpoint     = a.endpoint or ""
  end
  return v
end

local function replace_form()
  local rec = find_working(M._active)
  local ok, err = pcall(function()
    arbor.ui.form.replace({
      nodes      = build_root(),
      state      = { active_id = M._active or "" },
      set_values = build_set_values(rec),
    })
  end)
  if not ok then
    arbor.log.warn("conn_modal replace failed: " .. tostring(err))
  end
end

function M.open()
  load_working()
  -- Pick the currently-selected connection as the initial active row,
  -- otherwise the first connection (if any), otherwise nothing.
  M._active = state.selected_id() or ""
  if M._active == "" or not find_working(M._active) then
    M._active = (M._working[1] and M._working[1].id) or nil
  end

  arbor.ui.form({
    title         = "Manage cloud connections",
    width         = "920px",
    height        = "680px",
    submit_label  = "Save",
    submit_action = "cloud:conn_modal_save",
    cancel_label  = "Close",
    cancel_action = "cloud:conn_modal_close",
    -- We close ourselves from on_save() so a validation failure can
    -- replace the form (and keep it open) rather than re-mounting it.
    keep_open     = true,
    state         = { active_id = M._active or "" },
    nodes         = build_root(),
  })
end

-- ── Public action handlers ─────────────────────────────────────────────────

-- Select a row in the left rail. Fired by the tree's `change_action`, which
-- passes `ctx.value = clickedNodeValue`. Group headers carry a `__group__:`
-- prefix and are ignored (the tree widget already treats them as expand
-- toggles client-side). We patch any pending edits onto the previously-
-- active record before switching so the user doesn't lose a field they just
-- typed.
function M.on_select(ctx)
  local target = ctx.value or ""
  if target == "" or target:sub(1, 9) == "__group__" then return end
  if target == M._active then return end
  patch_from_ctx(find_working(M._active), ctx)
  M._active = target
  replace_form()
end

-- Add a fresh draft for the given provider.
function M.on_add(ctx)
  local provider = ctx.provider or "gcs"
  patch_from_ctx(find_working(M._active), ctx)
  local draft = {
    id             = DRAFT_PREFIX .. state.new_id(),
    name           = "",
    provider       = provider,
    default_bucket = "",
  }
  if provider == "gcs" then
    draft.project_id = ""
    draft.gcs        = { method = "sa_file" }
  elseif provider == "s3" then
    draft.s3 = { access_key_id = "", region = "", endpoint = "", force_path_style = false }
  elseif provider == "azblob" then
    draft.azblob = { account_name = "", endpoint = "" }
  end
  table.insert(M._working, draft)
  M._active = draft.id
  replace_form()
end

-- Drop a row.  Confirms with the user first; cancellation leaves things as
-- they were.  After deletion we pick the next available row (or empty out).
local function delete_id(id, ctx)
  if not id then return end
  local rec = find_working(id)
  if not rec then return end
  local label = (rec.name and rec.name ~= "") and rec.name or "(unnamed)"
  arbor.ui.confirm({
    title         = "Remove connection",
    message       = "Remove \"" .. label .. "\" from the list? "
                  .. "It will be deleted permanently when you click Save.",
    confirm_label = "Remove",
    confirm_kind  = "danger",
    cancel_label  = "Cancel",
    on_confirm    = function()
      for i, c in ipairs(M._working) do
        if c.id == id then table.remove(M._working, i); break end
      end
      if M._active == id then
        -- Patch pending edits from ctx — but only onto OTHER records; the
        -- deleted one's edits are gone by design.
        M._active = (M._working[1] and M._working[1].id) or nil
      end
      replace_form()
    end,
  })
end

function M.on_delete(ctx)
  delete_id(ctx.id, ctx)
end

-- Triggered by the rail footer's "−" button. Works on whichever row is
-- currently selected (M._active) — IntelliJ-style.
function M.on_delete_active(ctx)
  if not M._active then
    arbor.notify{ title = "Remove", level = "warning",
      message = "Pick a connection in the tree first." }
    return
  end
  delete_id(M._active, ctx)
end

-- Test the currently-active connection in place (no save).  Reads pending
-- edits from ctx so the user can verify a change before persisting.
--
-- Fires the test asynchronously: blocking the plugin-host thread for the
-- full network round-trip made the rest of arbor appear to freeze.  The
-- result lands on `cloud:test_connection_modal_done` (registered in
-- main.lua) which surfaces the same success / failure notifications.
function M.on_test(ctx)
  local rec = find_working(M._active)
  if not rec then return end
  patch_from_ctx(rec, ctx)
  local env = state.envelope(rec)
  arbor.notify{ title = "Testing connection…", message = rec.name or rec.id or "", level = "info" }
  arbor.cloud.test_connection_async({
    conn       = env,
    bucket     = rec.default_bucket or "",
    on_done    = "cloud:test_connection_modal_done",
    request_id = tostring(rec.id or "modal"),
  })
end

-- Kick off OAuth for the active connection.  We persist the draft first so
-- the secret_ref the keyring receives matches what we'll save later.
function M.on_oauth(ctx)
  local rec = find_working(M._active)
  if not rec or rec.provider ~= "gcs" or (rec.gcs and rec.gcs.method) ~= "oauth" then
    arbor.notify{ title = "OAuth", message = "Selected connection isn't using OAuth.",
                  level = "warning" }
    return
  end
  patch_from_ctx(rec, ctx)
  -- Strip the draft prefix on the FIRST oauth attempt so the secret_ref
  -- ends up using the final id.  If the user cancels Save afterwards we'd
  -- leak a keyring entry; the trade-off is keeping the OAuth-then-save UX
  -- working without surprises.
  if is_draft(rec.id) then
    local new_id = rec.id:sub(#DRAFT_PREFIX + 1)
    rec.id = new_id
    M._active = new_id
  end
  rec.gcs.secret_ref = "gcs/" .. rec.id .. "/oauth"
  rec.gcs.client_id  = ctx.oauth_client_id or rec.gcs.client_id or ""

  local _, err = arbor.cloud.oauth_start({
    secret_ref    = rec.gcs.secret_ref,
    client_id     = rec.gcs.client_id,
    client_secret = ctx.oauth_client_secret or "",
  })
  if err then
    arbor.notify{ title = "Authorize failed", message = tostring(err), level = "error" }
  else
    arbor.notify{ title = "Authorize with Google",
      message = "A browser window opened. Approve and come back.", level = "info" }
  end
end

-- Commit: persist M._working to settings, wipe keyring entries for removed
-- connections, then close.
function M.on_save(ctx)
  -- Pull any pending edits for the active record before snapshotting.
  patch_from_ctx(find_working(M._active), ctx)

  local before     = state.load_connections()
  local before_ids = {}
  for _, c in ipairs(before) do before_ids[c.id] = c end

  -- Validate: every kept connection must have a name.
  for _, c in ipairs(M._working) do
    if (c.name or "") == "" then
      arbor.notify{ title = "Save", level = "warning",
        message = "Each connection needs a name. Fix the highlighted rows first." }
      M._active = c.id
      replace_form()
      return
    end
  end

  -- Push any newly-supplied secrets for the active record to the keyring
  -- BEFORE we strip the draft prefix from its id (so the secret_ref ends
  -- up keyed to the final id).  Secrets for non-active drafts can't be
  -- recovered from ctx — the user has to come back to each draft and
  -- re-supply before saving the whole thing.  Same limitation across all
  -- providers, documented in the doc.html.
  do
    local rec = find_working(M._active)
    if rec then
      -- Strip draft prefix first so secret_ref uses the final id.
      if is_draft(rec.id) then
        local new_id = rec.id:sub(#DRAFT_PREFIX + 1)
        rec.id = new_id
        M._active = new_id
      end
      local function push(ref_key, value)
        local _, err = arbor.cloud.secret_set(ref_key, value)
        if err then arbor.log.warn("save secret " .. ref_key .. ": " .. tostring(err)) end
      end
      if rec.provider == "gcs"
         and (rec.gcs and rec.gcs.method) == "sa_inline"
         and ctx.sa_json and ctx.sa_json ~= "" then
        rec.gcs.secret_ref = "gcs/" .. rec.id
        push(rec.gcs.secret_ref, ctx.sa_json)
      elseif rec.provider == "s3" and ctx.s3_secret_key and ctx.s3_secret_key ~= "" then
        rec.s3 = rec.s3 or {}
        rec.s3.secret_ref = "s3/" .. rec.id
        push(rec.s3.secret_ref, ctx.s3_secret_key)
      elseif rec.provider == "azblob" and ctx.azure_account_key and ctx.azure_account_key ~= "" then
        rec.azblob = rec.azblob or {}
        rec.azblob.secret_ref = "azblob/" .. rec.id
        push(rec.azblob.secret_ref, ctx.azure_account_key)
      end
    end
  end

  -- Strip remaining draft prefixes (no special-key handling required).
  for _, c in ipairs(M._working) do
    if is_draft(c.id) then c.id = c.id:sub(#DRAFT_PREFIX + 1) end
  end

  -- Persist + wipe orphaned secrets.
  local keep_ids = {}
  for _, c in ipairs(M._working) do keep_ids[c.id] = true end
  for id, old in pairs(before_ids) do
    if not keep_ids[id] then
      state.drop_secrets_for(old)
    end
  end

  state.save_connections(M._working)

  -- If we deleted the active connection out from under the sidebar, pick
  -- the first remaining one.  Otherwise leave the selection alone.
  if state.selected_id() == "" or not state.find(state.selected_id()) then
    state.set_selected((M._working[1] and M._working[1].id) or "")
  end

  arbor.notify{ title = "Connections saved",
    message = tostring(#M._working) .. " connection(s) on file.", level = "success" }

  M._working = nil
  M._active  = nil
  arbor.ui.form.close()
end

-- Cancel: just drop the working copy.
function M.on_close(_ctx)
  M._working = nil
  M._active  = nil
end

return M
