-- parsers/npm_ls.lua — Walk the JSON tree from `npm ls --all --json` (and the
-- compatible shape `pnpm list --depth=Infinity --json` produces).
--
-- Schema we accept (relevant slice):
--   {
--     name, version,
--     dependencies?:   { <name>: { version, dependencies?, ... } },
--     devDependencies?: { ... },
--     peerDependencies?: { ... }
--   }
-- pnpm wraps the root in a single-element array: we unwrap it transparently.

local M = {}

-- Visit a dependencies map and return the list of TreeNode-shaped children.
-- We carry `scope` through so the modal can colour/filter dev vs prod deps.
-- The child key is the package name (which is also the resolved id under
-- node_modules); we use it as the artifact label.
--
-- "Ghost" entries (no version, no children) are skipped: these come from
-- platform-specific optional dependencies that npm lists in the json but
-- couldn't install on this OS — the classic case is esbuild's per-platform
-- binaries (@esbuild/aix-ppc64, @esbuild/win32-x64, …) where only one is
-- installed and the other 24 show up as empty objects. They were previously
-- rendered as `?` rows that polluted the modal with no useful info.
local function visit_deps(deps, scope, key_prefix, depth)
  if not deps or type(deps) ~= "table" then return {} end
  local out = {}
  -- Stable order: alphabetical by name.
  local names = {}
  for n in pairs(deps) do names[#names + 1] = n end
  table.sort(names)
  for i, name in ipairs(names) do
    local entry = deps[name]
    if type(entry) == "table" then
      local has_version  = type(entry.version) == "string" and entry.version ~= ""
      local has_children = type(entry.dependencies) == "table" and next(entry.dependencies) ~= nil
      -- Hard-skip entries npm explicitly tagged as not-installed: missing
      -- or optional deps that didn't make it into node_modules. Without
      -- this guard, npm sometimes still emits them with `dependencies: {}`
      -- or a `version` field that's the REQUIRED range (not the resolved
      -- one), and they pollute the modal — classic case is esbuild's per-
      -- platform binaries showing 25+ ghost rows on every machine.
      local skip_unresolved = entry.missing == true
                           or (entry.optional == true and not has_version)
      if not skip_unresolved and (has_version or has_children) then
        local key = key_prefix .. "/" .. i
        local children = {}
        if depth < 24 then
          for _, child in ipairs(visit_deps(entry.dependencies, scope, key, depth + 1)) do
            children[#children + 1] = child
          end
        end
        out[#out + 1] = {
          coord = {
            group    = "",
            artifact = name,
            version  = entry.version or "",
            scope    = scope or "prod",
            source   = entry.resolved or "",
            missing  = entry.missing == true,
            extraneous = entry.extraneous == true,
            peer     = entry.peer == true,
            optional = entry.optional == true,
          },
          children = children,
        }
      end
    end
  end
  return out
end

local function build_root(decoded)
  if not decoded or type(decoded) ~= "table" then return nil end
  local root = {
    coord = {
      group    = "",
      artifact = decoded.name or "(root)",
      version  = decoded.version or "",
      scope    = "root",
      source   = "",
    },
    children = {},
  }

  -- Combine prod/dev/peer at the root so the user sees everything. Each
  -- branch is tagged with its scope so the modal can group/filter.
  for _, child in ipairs(visit_deps(decoded.dependencies,     "prod", "0/p", 0)) do
    root.children[#root.children + 1] = child
  end
  for _, child in ipairs(visit_deps(decoded.devDependencies,  "dev",  "0/d", 0)) do
    root.children[#root.children + 1] = child
  end
  for _, child in ipairs(visit_deps(decoded.peerDependencies, "peer", "0/r", 0)) do
    root.children[#root.children + 1] = child
  end

  return root
end

function M.parse(json_text)
  if not json_text or json_text == "" then return nil end
  local ok, decoded = pcall(arbor.json.decode, json_text)
  if not ok then
    arbor.log.warn("[deps-explorer/npm] JSON parse failed: " .. tostring(decoded))
    return nil
  end
  -- pnpm list returns an array of root objects.
  if type(decoded) == "table" and decoded[1] and not decoded.name then
    decoded = decoded[1]
  end
  return build_root(decoded)
end

return M
