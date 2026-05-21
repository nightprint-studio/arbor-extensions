-- operations.lua — catalog of step kinds available in the rules editor.
--
-- Each entry declares:
--   id          unique kind identifier (used in profile JSON)
--   label       human name shown in the palette and inline
--   category    palette section (FILE | CONTENUTO | GIT | BUILD/DEP | VALIDATION | EXECUTION | FLOW)
--   icon        Lucide icon name (single-colour stroke 1.5px)
--   color       pill colour hint for the step card (accent | info | warn | danger | neutral)
--   summary     one-line description
--   form(step)  → array of form nodes for the "step details" panel (right side of
--               the Rules tab). Called with the step's current params; returns the
--               node array embedded in the right panel.
--   to_command(step, ctx)
--               Phase 2: compiles the step params into a shell command string.
--               Returns the string OR nil when not yet implemented. The runtime
--               will refuse to start a pipeline that contains unimplemented ops
--               so the user sees a clear error instead of a silent no-op.
--
-- Phase 1 intentionally ships only the schema for every op. Phase 2 fills in
-- `to_command` one op at a time.

local M = {}

-- ── Shared helpers ──────────────────────────────────────────────────────────

local function text_field(name, label, placeholder, default)
  return { type = "text", name = name, label = label,
           placeholder = placeholder or "", default = default or "" }
end

local function textarea(name, label, placeholder, default, rows)
  return { type = "textarea", name = name, label = label,
           placeholder = placeholder or "", default = default or "",
           rows = rows or 4 }
end

local function checkbox(name, label, default)
  return { type = "checkbox", name = name, label = label, default = default and true or false }
end

local function select_field(name, label, options, default)
  return { type = "select", name = name, label = label, options = options, default = default or "" }
end

local function note(text, variant)
  return { type = "paragraph", content = text, variant = variant or "muted" }
end

-- ── Categories (order matters: drives palette section order) ────────────────

M.categories = {
  { id = "file",        label = "File",       icon = "File" },
  { id = "content",     label = "Contenuto",  icon = "FileText" },
  { id = "git",         label = "Git",        icon = "GitBranch" },
  { id = "build",       label = "Build / Dep",icon = "Package" },
  { id = "validation",  label = "Validation", icon = "ShieldCheck" },
  { id = "execution",   label = "Esecuzione", icon = "Terminal" },
  { id = "flow",        label = "Flow",       icon = "Workflow" },
}

-- ── Operations ──────────────────────────────────────────────────────────────

M.ops = {

  -- =========================================================================
  -- FILE
  -- =========================================================================

  delete_pattern = {
    label = "Delete by pattern", category = "file", icon = "Trash2", color = "danger",
    summary = "Cancella file che corrispondono a uno o più glob pattern.",
    form = function(step)
      return {
        textarea("patterns", "Glob patterns (uno per riga)",
          "es. **/*.internal.*\n.internal/\nscripts/internal-*.sh",
          step.params and step.params.patterns or "", 5),
        checkbox("recursive", "Ricorsivo (segue le directory)",
          step.params and step.params.recursive ~= false),
        note("I pattern sono relativi a $SOURCE_PATH. Usa `**` per match ricorsivo."),
      }
    end,
  },

  delete_file = {
    label = "Delete file", category = "file", icon = "Trash", color = "danger",
    summary = "Cancella file specifici per path esatto.",
    form = function(step)
      return {
        textarea("paths", "Path (uno per riga, relativo a $SOURCE_PATH)",
          "es. deploy-keys/prod.pem\ndocs/internal-arch.pdf",
          step.params and step.params.paths or "", 5),
      }
    end,
  },

  copy_file = {
    label = "Copy file", category = "file", icon = "FileCopy2", color = "info",
    summary = "Copia un file o directory da sorgente a destinazione.",
    form = function(step)
      return {
        text_field("src",  "Sorgente", "path relativo",
          step.params and step.params.src or ""),
        text_field("dest", "Destinazione", "path relativo",
          step.params and step.params.dest or ""),
        checkbox("overwrite", "Sovrascrivi se esistente",
          step.params and step.params.overwrite or false),
      }
    end,
  },

  move_file = {
    label = "Move / Rename", category = "file", icon = "FileOutput", color = "info",
    summary = "Sposta o rinomina un file/directory.",
    form = function(step)
      return {
        text_field("src",  "Sorgente",     "", step.params and step.params.src  or ""),
        text_field("dest", "Destinazione", "", step.params and step.params.dest or ""),
      }
    end,
  },

  create_file = {
    label = "Create file", category = "file", icon = "FilePlus2", color = "accent",
    summary = "Crea un nuovo file con contenuto letterale.",
    form = function(step)
      return {
        text_field("path", "Path", "relativo a $SOURCE_PATH",
          step.params and step.params.path or ""),
        textarea("content", "Contenuto", "",
          step.params and step.params.content or "", 8),
        checkbox("overwrite", "Sovrascrivi se esistente",
          step.params and step.params.overwrite or false),
      }
    end,
  },

  append_file = {
    label = "Append to file", category = "file", icon = "FileDown", color = "info",
    summary = "Aggiunge righe in coda a un file esistente.",
    form = function(step)
      return {
        text_field("path", "Path", "", step.params and step.params.path or ""),
        textarea("content", "Testo da appendere", "",
          step.params and step.params.content or "", 6),
      }
    end,
  },

  prepend_file = {
    label = "Prepend to file", category = "file", icon = "FileUp", color = "info",
    summary = "Aggiunge righe in testa a un file (es. license header).",
    form = function(step)
      return {
        text_field("path", "Path", "", step.params and step.params.path or ""),
        textarea("content", "Testo da anteporre", "",
          step.params and step.params.content or "", 6),
      }
    end,
  },

  touch_file = {
    label = "Touch (create empty)", category = "file", icon = "FileSymlink", color = "neutral",
    summary = "Crea un file vuoto (no-op se già esiste).",
    form = function(step)
      return { text_field("path", "Path", "es. docs/.keep", step.params and step.params.path or "") }
    end,
  },

  chmod_file = {
    label = "Set permissions (chmod)", category = "file", icon = "KeyRound", color = "warn",
    summary = "Imposta permessi POSIX (no-op su Windows).",
    form = function(step)
      return {
        text_field("path", "Path", "", step.params and step.params.path or ""),
        text_field("mode", "Mode (ottale, es. 755)", "755",
          step.params and step.params.mode or "755"),
      }
    end,
  },

  normalize_eol = {
    label = "Normalize EOL", category = "file", icon = "AlignJustify", color = "neutral",
    summary = "Converte line ending fra CRLF e LF.",
    form = function(step)
      return {
        text_field("glob", "Glob (uno o più, separati da virgola)", "**/*.{sh,md,txt}",
          step.params and step.params.glob or ""),
        select_field("mode", "Modo", {
          { value = "lf",   label = "LF (Unix)" },
          { value = "crlf", label = "CRLF (Windows)" },
        }, step.params and step.params.mode or "lf"),
      }
    end,
  },

  strip_bom = {
    label = "Strip BOM", category = "file", icon = "Scissors", color = "neutral",
    summary = "Rimuove il BOM da file UTF-8.",
    form = function(step)
      return {
        text_field("glob", "Glob", "**/*.{java,xml,properties}",
          step.params and step.params.glob or ""),
      }
    end,
  },

  -- =========================================================================
  -- CONTENUTO
  -- =========================================================================

  replace_in_file = {
    label = "Replace in file", category = "content", icon = "Replace", color = "accent",
    summary = "Find & replace su un singolo file (supporta pattern Lua).",
    form = function(step)
      return {
        text_field("path", "Path", "", step.params and step.params.path or ""),
        textarea("find", "Cerca (pattern Lua)", "",
          step.params and step.params.find or "", 3),
        textarea("replace", "Sostituisci con", "",
          step.params and step.params.replace or "", 3),
        checkbox("plain", "Match letterale (no pattern)",
          step.params and step.params.plain or false),
      }
    end,
  },

  replace_on_glob = {
    label = "Replace on glob", category = "content", icon = "ListFilter", color = "accent",
    summary = "Find & replace su tutti i file che matchano un glob.",
    form = function(step)
      return {
        text_field("glob", "Glob", "src/**/*.java",
          step.params and step.params.glob or ""),
        textarea("find", "Cerca",     "", step.params and step.params.find    or "", 3),
        textarea("replace", "Sostituisci con", "", step.params and step.params.replace or "", 3),
        checkbox("plain", "Match letterale (no pattern)",
          step.params and step.params.plain or false),
      }
    end,
  },

  insert_at_anchor = {
    label = "Insert at anchor", category = "content", icon = "AlignEndHorizontal", color = "accent",
    summary = "Inserisce un blocco prima/dopo la prima riga che matcha un pattern.",
    form = function(step)
      return {
        text_field("path", "Path", "", step.params and step.params.path or ""),
        text_field("anchor", "Pattern ancora (Lua)", "",
          step.params and step.params.anchor or ""),
        select_field("position", "Posizione", {
          { value = "after",  label = "Dopo la riga anchor" },
          { value = "before", label = "Prima della riga anchor" },
        }, step.params and step.params.position or "after"),
        textarea("content", "Blocco da inserire", "",
          step.params and step.params.content or "", 5),
      }
    end,
  },

  json_edit = {
    label = "JSON edit", category = "content", icon = "Braces", color = "accent",
    summary = "Modifica un file JSON via path jq-style (es. $.database.host).",
    form = function(step)
      return {
        text_field("path", "Path", "config.json",
          step.params and step.params.path or ""),
        text_field("jpath", "JSON path", "$.database.host",
          step.params and step.params.jpath or ""),
        text_field("value", "Nuovo valore (stringa o JSON literale)", "",
          step.params and step.params.value or ""),
      }
    end,
  },

  yaml_edit = {
    label = "YAML edit", category = "content", icon = "FileCog", color = "accent",
    summary = "Modifica un file YAML via path (es. spring.datasource.url).",
    form = function(step)
      return {
        text_field("path",  "Path YAML", "application.yml",
          step.params and step.params.path or ""),
        text_field("ypath", "Dotted path", "spring.datasource.url",
          step.params and step.params.ypath or ""),
        text_field("value", "Nuovo valore", "",
          step.params and step.params.value or ""),
      }
    end,
  },

  toml_edit = {
    label = "TOML edit", category = "content", icon = "FileCog", color = "accent",
    summary = "Modifica un file TOML (es. package.version).",
    form = function(step)
      return {
        text_field("path",  "Path TOML", "Cargo.toml",
          step.params and step.params.path or ""),
        text_field("tpath", "Dotted path", "package.version",
          step.params and step.params.tpath or ""),
        text_field("value", "Nuovo valore", "",
          step.params and step.params.value or ""),
      }
    end,
  },

  xml_edit = {
    label = "XML edit", category = "content", icon = "Code", color = "accent",
    summary = "Modifica un valore XML via XPath.",
    form = function(step)
      return {
        text_field("path",  "Path", "pom.xml",
          step.params and step.params.path or ""),
        text_field("xpath", "XPath", "/project/version",
          step.params and step.params.xpath or ""),
        text_field("value", "Nuovo valore", "",
          step.params and step.params.value or ""),
      }
    end,
  },

  properties_edit = {
    label = "Properties edit", category = "content", icon = "Settings2", color = "accent",
    summary = "Upsert di chiavi in un file Java .properties.",
    form = function(step)
      return {
        text_field("path", "Path", "application.properties",
          step.params and step.params.path or ""),
        textarea("entries", "Entries (key=value, una per riga)",
          "host=prod\npassword=${DB_PASSWORD}",
          step.params and step.params.entries or "", 5),
      }
    end,
  },

  env_merge = {
    label = ".env merge", category = "content", icon = "KeySquare", color = "accent",
    summary = "Upsert di chiavi in un file .env.",
    form = function(step)
      return {
        text_field("path", "Path", ".env",
          step.params and step.params.path or ""),
        textarea("entries", "Entries (key=value, una per riga)",
          "",
          step.params and step.params.entries or "", 5),
      }
    end,
  },

  strip_comments = {
    label = "Strip comments", category = "content", icon = "MessageSquareOff", color = "warn",
    summary = "Rimuove i commenti dai file che matchano il glob.",
    form = function(step)
      return {
        text_field("glob", "Glob", "src/**/*.sql",
          step.params and step.params.glob or ""),
        select_field("syntax", "Sintassi commenti", {
          { value = "sql",  label = "SQL (-- e /* */)" },
          { value = "c",    label = "C / C++ / Java / JS (// e /* */)" },
          { value = "xml",  label = "XML (<!-- -->)" },
          { value = "hash", label = "Hash (#)" },
        }, step.params and step.params.syntax or "c"),
      }
    end,
  },

  template_render = {
    label = "Template render", category = "content", icon = "FileType", color = "accent",
    summary = "Renderizza un file .tmpl espandendo {{ variabili }}.",
    form = function(step)
      return {
        text_field("src",  "Template",     "config/app.tmpl",
          step.params and step.params.src  or ""),
        text_field("dest", "Destinazione", "config/app.yml",
          step.params and step.params.dest or ""),
        note("Le variabili `{{ VAR }}` sono risolte dal profilo + builtins ($SOURCE_PATH, …)."),
      }
    end,
  },

  -- =========================================================================
  -- GIT
  -- =========================================================================

  git_init = {
    label = "Init repo", category = "git", icon = "GitFork", color = "info",
    summary = "Inizializza un repo git (git init) nella working dir.",
    form = function(step)
      return {
        text_field("cwd", "Path (vuoto = $OUTPUT_PATH)", "",
          step.params and step.params.cwd or ""),
        text_field("default_branch", "Branch iniziale", "main",
          step.params and step.params.default_branch or "main"),
      }
    end,
  },

  git_clone = {
    label = "Clone", category = "git", icon = "Download", color = "info",
    summary = "Clona un repository remoto (usa arbor.repo.clone nativo).",
    form = function(step)
      return {
        text_field("url",  "URL remoto", "git@host:org/repo.git",
          step.params and step.params.url  or ""),
        text_field("dest", "Destinazione (vuoto = $OUTPUT_PATH)", "",
          step.params and step.params.dest or ""),
        text_field("branch", "Branch (vuoto = default)", "",
          step.params and step.params.branch or ""),
        checkbox("shallow", "Shallow (--depth 1)",
          step.params and step.params.shallow or false),
        checkbox("submodules", "Recurse submodules",
          step.params and step.params.submodules or false),
      }
    end,
  },

  git_commit = {
    label = "Commit", category = "git", icon = "GitCommit", color = "accent",
    summary = "git add + commit con messaggio (supporta placeholder).",
    form = function(step)
      return {
        text_field("cwd",    "Repo path (vuoto = $OUTPUT_PATH)", "",
          step.params and step.params.cwd or ""),
        textarea("message", "Messaggio", "Export $PROFILE $SHA_SRC",
          step.params and step.params.message or "", 3),
        text_field("author", "Author override (vuoto = git config)", "",
          step.params and step.params.author or ""),
        checkbox("all", "git add -A prima di commit",
          step.params and step.params.all ~= false),
        checkbox("allow_empty", "Consenti commit vuoto",
          step.params and step.params.allow_empty or false),
      }
    end,
  },

  git_tag = {
    label = "Tag", category = "git", icon = "Tag", color = "accent",
    summary = "Crea un tag git (leggero o annotato).",
    form = function(step)
      return {
        text_field("cwd",  "Repo path", "", step.params and step.params.cwd or ""),
        text_field("name", "Tag name",  "v$VERSION",
          step.params and step.params.name or ""),
        textarea("message", "Messaggio (vuoto = tag leggero)", "",
          step.params and step.params.message or "", 2),
        checkbox("force", "Sovrascrivi se esistente",
          step.params and step.params.force or false),
      }
    end,
  },

  git_push = {
    label = "Push", category = "git", icon = "Upload", color = "warn",
    summary = "Pusha un branch/tag su remote.",
    form = function(step)
      return {
        text_field("cwd",    "Repo path", "", step.params and step.params.cwd or ""),
        text_field("remote", "Remote",    "origin",
          step.params and step.params.remote or "origin"),
        text_field("ref",    "Branch/tag", "$BRANCH_DEST",
          step.params and step.params.ref or ""),
        checkbox("force_with_lease", "--force-with-lease",
          step.params and step.params.force_with_lease or false),
        checkbox("tags", "Push tags",
          step.params and step.params.tags or false),
      }
    end,
  },

  git_checkout = {
    label = "Checkout", category = "git", icon = "GitBranchPlus", color = "info",
    summary = "Crea/switch branch.",
    form = function(step)
      return {
        text_field("cwd",    "Repo path", "", step.params and step.params.cwd or ""),
        text_field("branch", "Branch",    "",  step.params and step.params.branch or ""),
        checkbox("create", "Crea se non esiste",
          step.params and step.params.create ~= false),
      }
    end,
  },

  git_cherry_pick = {
    label = "Cherry-pick", category = "git", icon = "GitCommitHorizontal", color = "accent",
    summary = "Cherry-pick di uno o più commit (separa con spazio).",
    form = function(step)
      return {
        text_field("cwd",  "Repo path", "", step.params and step.params.cwd or ""),
        text_field("shas", "Commit sha(s)", "",
          step.params and step.params.shas or ""),
      }
    end,
  },

  git_merge = {
    label = "Merge", category = "git", icon = "GitMerge", color = "accent",
    summary = "Merge di un branch nel branch corrente.",
    form = function(step)
      return {
        text_field("cwd",    "Repo path", "", step.params and step.params.cwd or ""),
        text_field("branch", "Branch da mergere", "",
          step.params and step.params.branch or ""),
        select_field("strategy", "Strategia", {
          { value = "default",  label = "Default" },
          { value = "ff_only",  label = "Fast-forward only (--ff-only)" },
          { value = "no_ff",    label = "No fast-forward (--no-ff)" },
        }, step.params and step.params.strategy or "default"),
      }
    end,
  },

  git_submodule_update = {
    label = "Submodule init/update", category = "git", icon = "Link", color = "info",
    summary = "git submodule update --init --recursive.",
    form = function(step)
      return {
        text_field("cwd", "Repo path", "", step.params and step.params.cwd or ""),
      }
    end,
  },

  -- =========================================================================
  -- BUILD / DEP
  -- =========================================================================

  mvn_set_version = {
    label = "Maven set version", category = "build", icon = "Package", color = "accent",
    summary = "Aggiorna le <version> nei pom (mvn versions:set).",
    form = function(step)
      return {
        text_field("cwd",     "Project path", "",
          step.params and step.params.cwd or ""),
        text_field("version", "Nuova versione", "1.2.3",
          step.params and step.params.version or ""),
      }
    end,
  },

  mvn_deploy = {
    label = "Maven deploy", category = "build", icon = "Upload", color = "warn",
    summary = "mvn deploy su repository Nexus/Artifactory interno.",
    form = function(step)
      return {
        text_field("cwd",     "Project path", "",
          step.params and step.params.cwd or ""),
        text_field("profile", "Maven profile (vuoto = nessuno)", "",
          step.params and step.params.profile or ""),
        text_field("extra",   "Extra args", "-DskipTests",
          step.params and step.params.extra or ""),
      }
    end,
  },

  gradle_task = {
    label = "Gradle task", category = "build", icon = "Package", color = "accent",
    summary = "Esegue uno o più task gradle.",
    form = function(step)
      return {
        text_field("cwd",   "Project path", "",
          step.params and step.params.cwd or ""),
        text_field("tasks", "Tasks (separati da spazio)", "clean build",
          step.params and step.params.tasks or ""),
      }
    end,
  },

  gradle_offline = {
    label = "Gradle offline cache", category = "build", icon = "PackageCheck", color = "accent",
    summary = "Popola la cache gradle offline per la distribuzione.",
    form = function(step)
      return {
        text_field("cwd",  "Project path", "", step.params and step.params.cwd or ""),
        text_field("dest", "Destinazione cache", "$OUTPUT_PATH/gradle-cache",
          step.params and step.params.dest or ""),
      }
    end,
  },

  npm_install = {
    label = "npm install (frozen)", category = "build", icon = "PackageSearch", color = "accent",
    summary = "npm ci (lockfile frozen).",
    form = function(step)
      return {
        text_field("cwd", "Project path", "", step.params and step.params.cwd or ""),
      }
    end,
  },

  pnpm_install = {
    label = "pnpm install", category = "build", icon = "PackageSearch", color = "accent",
    summary = "pnpm install --frozen-lockfile.",
    form = function(step)
      return {
        text_field("cwd", "Project path", "", step.params and step.params.cwd or ""),
      }
    end,
  },

  npm_pack = {
    label = "npm pack", category = "build", icon = "Archive", color = "accent",
    summary = "Genera un tarball npm del package.",
    form = function(step)
      return {
        text_field("cwd", "Project path", "", step.params and step.params.cwd or ""),
      }
    end,
  },

  m2_offline_ju = {
    label = "Offline M2 (ju)", category = "build", icon = "PackagePlus", color = "warn",
    summary = "Estrae dipendenze Maven non pubbliche via il tool esterno `ju`.",
    form = function(step)
      return {
        text_field("source_path", "Project path (--path)", "$SOURCE_PATH",
          step.params and step.params.source_path or "$SOURCE_PATH"),
        text_field("jdk", "JDK (--jdk=...)", "Jdk1_8",
          step.params and step.params.jdk or "Jdk1_8"),
        text_field("dest_m2", "Destinazione M2 (-dp)", "$OUTPUT_PATH",
          step.params and step.params.dest_m2 or "$OUTPUT_PATH"),
        text_field("ju_bin", "Eseguibile ju (vuoto = da PATH)", "",
          step.params and step.params.ju_bin or ""),
        note("Il tool è esterno: il path può essere configurato nei settings globali del plugin."),
      }
    end,
  },

  -- =========================================================================
  -- VALIDATION
  -- =========================================================================

  -- Note: every assert_* op has a `negate` checkbox that inverts its logic —
  -- "assert X" becomes "assert NOT X" — so the catalog doesn't need two
  -- separate entries. The step name can be renamed by the user (e.g. "Assert
  -- README is missing") once negate is checked.

  assert_file_exists = {
    label = "Assert file exists", category = "validation", icon = "FileCheck2", color = "info",
    summary = "Fallisce se il file non esiste (inverti con NOT).",
    form = function(step)
      return {
        text_field("path", "Path", "", step.params and step.params.path or ""),
        checkbox("negate", "NOT — fallisci se il file ESISTE",
          step.params and step.params.negate or false),
      }
    end,
  },

  assert_glob_matches = {
    label = "Assert glob matches N files", category = "validation", icon = "ScanSearch", color = "info",
    summary = "Fallisce se il glob matcha fuori dal range.",
    form = function(step)
      return {
        text_field("glob", "Glob", "", step.params and step.params.glob or ""),
        text_field("min",  "Minimo",  "1", tostring(step.params and step.params.min or 1)),
        text_field("max",  "Massimo (vuoto = ∞)", "",
          tostring(step.params and step.params.max or "")),
      }
    end,
  },

  assert_file_not_contains = {
    label = "Assert file NOT contains", category = "validation", icon = "SearchX", color = "warn",
    summary = "Fallisce se il pattern matcha (es. controllo TODO residui).",
    form = function(step)
      return {
        text_field("path",    "Path",    "", step.params and step.params.path or ""),
        text_field("pattern", "Pattern (Lua)", "",
          step.params and step.params.pattern or ""),
        checkbox("negate", "NOT — fallisci se il pattern NON è presente",
          step.params and step.params.negate or false),
      }
    end,
  },

  assert_cmd_exit_zero = {
    label = "Assert cmd exit 0", category = "validation", icon = "CheckCircle2", color = "info",
    summary = "Esegue un comando e fallisce se exit != 0 (inverti con NOT).",
    form = function(step)
      return {
        text_field("cwd",     "cwd", "",       step.params and step.params.cwd     or ""),
        text_field("command", "Comando", "",   step.params and step.params.command or ""),
        checkbox("negate", "NOT — fallisci se exit == 0",
          step.params and step.params.negate or false),
      }
    end,
  },

  assert_env_set = {
    label = "Assert env set", category = "validation", icon = "KeyRound", color = "info",
    summary = "Fallisce se una variabile d'ambiente non è definita (inverti con NOT).",
    form = function(step)
      return {
        text_field("var", "Nome variabile", "",
          step.params and step.params.var or ""),
        checkbox("negate", "NOT — fallisci se la variabile È definita",
          step.params and step.params.negate or false),
      }
    end,
  },

  assert_branch_clean = {
    label = "Assert branch clean", category = "validation", icon = "Fingerprint", color = "info",
    summary = "Fallisce se la working copy ha modifiche non committate (inverti con NOT).",
    form = function(step)
      return {
        text_field("cwd", "Repo path", "", step.params and step.params.cwd or ""),
        checkbox("negate", "NOT — fallisci se la working copy è PULITA",
          step.params and step.params.negate or false),
      }
    end,
  },

  assert_version_bump = {
    label = "Assert version bump", category = "validation", icon = "TrendingUp", color = "info",
    summary = "Fallisce se la nuova versione è ≤ alla precedente.",
    form = function(step)
      return {
        text_field("file",         "File (pom.xml | package.json | Cargo.toml)", "",
          step.params and step.params.file or ""),
        text_field("new_version",  "Nuova versione", "",
          step.params and step.params.new_version or ""),
      }
    end,
  },

  -- =========================================================================
  -- EXECUTION
  -- =========================================================================

  shell_command = {
    label = "Shell command", category = "execution", icon = "Terminal", color = "neutral",
    summary = "Esegue un comando shell arbitrario.",
    form = function(step)
      return {
        text_field("cwd",     "cwd (vuoto = $SOURCE_PATH)", "",
          step.params and step.params.cwd or ""),
        textarea("command", "Comando", "", step.params and step.params.command or "", 4),
      }
    end,
  },

  lua_inline = {
    label = "Lua inline", category = "execution", icon = "FileCode", color = "accent",
    summary = "Blocco Lua custom con accesso al contesto della run.",
    form = function(step)
      return {
        textarea("code", "Lua code", "-- ctx.vars, ctx.env, ctx.source_path\nreturn true",
          step.params and step.params.code or "", 10),
      }
    end,
  },

  docker_build = {
    label = "Docker build", category = "execution", icon = "Container", color = "info",
    summary = "docker build -t <tag> <context>.",
    form = function(step)
      return {
        text_field("context",  "Contesto build", ".", step.params and step.params.context  or "."),
        text_field("dockerfile","Dockerfile",     "Dockerfile",
          step.params and step.params.dockerfile or "Dockerfile"),
        text_field("tag",      "Tag", "$PROFILE:$TIMESTAMP",
          step.params and step.params.tag or ""),
      }
    end,
  },

  docker_push = {
    label = "Docker push", category = "execution", icon = "Ship", color = "warn",
    summary = "docker push <tag>.",
    form = function(step)
      return {
        text_field("tag", "Tag", "", step.params and step.params.tag or ""),
      }
    end,
  },

  -- =========================================================================
  -- FLOW
  -- =========================================================================

  set_variable = {
    label = "Set variable", category = "flow", icon = "Variable", color = "neutral",
    summary = "Salva un valore in ctx.vars per gli step successivi.",
    form = function(step)
      return {
        text_field("name",  "Nome",   "", step.params and step.params.name  or ""),
        text_field("value", "Valore", "",  step.params and step.params.value or ""),
      }
    end,
  },

  log_message = {
    label = "Log message", category = "flow", icon = "ScrollText", color = "neutral",
    summary = "Registra un messaggio nel log della run.",
    form = function(step)
      return {
        select_field("level", "Livello", {
          { value = "debug", label = "DEBUG" },
          { value = "info",  label = "INFO" },
          { value = "warn",  label = "WARN" },
          { value = "error", label = "ERROR" },
        }, step.params and step.params.level or "info"),
        text_field("message", "Messaggio", "",
          step.params and step.params.message or ""),
      }
    end,
  },

  notify_toast = {
    label = "Notify (toast)", category = "flow", icon = "Bell", color = "info",
    summary = "Mostra una notifica (toast) all'utente.",
    form = function(step)
      return {
        text_field("title",   "Titolo",    "", step.params and step.params.title   or ""),
        text_field("message", "Messaggio", "", step.params and step.params.message or ""),
        select_field("level", "Livello", {
          { value = "info",    label = "Info" },
          { value = "success", label = "Success" },
          { value = "warning", label = "Warning" },
          { value = "error",   label = "Error" },
        }, step.params and step.params.level or "info"),
      }
    end,
  },

  try_on_error = {
    label = "Try / on_error", category = "flow", icon = "AlertOctagon", color = "warn",
    summary = "Se lo step precedente fallisce, esegue un recovery.",
    form = function(step)
      return {
        select_field("recovery", "Recovery", {
          { value = "continue", label = "Continua (ignora il fallimento)" },
          { value = "notify",   label = "Notifica e continua" },
          { value = "abort",    label = "Interrompi la pipeline (default)" },
        }, step.params and step.params.recovery or "abort"),
        text_field("message", "Messaggio recovery", "",
          step.params and step.params.message or ""),
      }
    end,
  },

  -- =========================================================================
  -- Native runtime control + variables (compiled directly to StepDef.if_block /
  -- StepDef.builtin / StepDef.capture by compile.lua — no shell, no Lua VM).
  -- These ops are intentionally hand-author-friendly: complex structures
  -- (branches, transforms) live in textareas as JSON until the editor grows
  -- a dedicated visual builder.
  -- =========================================================================

  if_block = {
    label   = "If / elif / else",
    category = "flow", icon = "GitBranch", color = "accent",
    summary = "Branch su condizioni: esegue solo gli step del primo ramo vero (o l'else).",
    form    = function(_step)
      return {
        note("Modifica i rami direttamente nell'editor — espandi un ramo cliccando sulla sua intestazione, scrivi la condizione nell'input inline e clicca un'op nella palette per aggiungere uno step nel ramo selezionato.", "info"),
        note("Sintassi condizione: ${var} && ${var2}, ${count} > 10, ${os} == \"windows\" || ${os} == \"darwin\", (${a} && ${b}) || ${force}, defined(maven_version), ${ver} =~ \"^3\\.\".", "muted"),
      }
    end,
  },

  capture_var = {
    label   = "Capture variable (shell)",
    category = "flow", icon = "Pipette", color = "accent",
    summary = "Esegue un comando shell e salva l'output (o l'exit code) in una variabile della run.",
    form    = function(step)
      local p = step.params or {}
      local transforms_json = type(p.transforms) == "string" and p.transforms
                              or arbor.json.encode(p.transforms or {}) or "[]"
      return {
        text_field("var", "Variable name", "es. maven_version",
          p.var or ""),
        textarea("command", "Shell command", "es. mvn -v",
          p.command or "", 3),
        select_field("source", "Capture source", {
          { value = "stdout",       label = "Stdout (default)"        },
          { value = "stderr",       label = "Stderr"                  },
          { value = "exit_code",    label = "Exit code (number)"      },
          { value = "success",      label = "Success (bool: exit==0)" },
          { value = "return_value", label = "Return value (Lua/builtin)" },
        }, p.source or "stdout"),
        textarea("transforms", "Transforms (JSON array, opzionale)",
          '[ { "kind": "trim" }, { "kind": "regex", "pattern": "v(\\\\d+)", "group": 1 } ]',
          transforms_json, 5),
      }
    end,
  },

  -- ── Built-in ops ────────────────────────────────────────────────────────────
  -- Ognuno è un "passo nativo": il runtime li esegue senza shell/Lua e mette
  -- il risultato tipato in `return_value` per la capture.

  builtin_file_exists = {
    label   = "Builtin: file_exists",
    category = "flow", icon = "FileSearch", color = "info",
    summary = "True/false su esistenza di un path. Tipico abbinamento: capture su return_value.",
    form    = function(step)
      local p = step.params or {}
      return {
        text_field("path", "Path (relativo a $OUTPUT_PATH)", "es. pom.xml",
          p.path or ""),
        text_field("var",  "Variable name (capture return_value)", "es. has_pom",
          p.var or ""),
      }
    end,
  },

  builtin_env = {
    label   = "Builtin: env var",
    category = "flow", icon = "Variable", color = "info",
    summary = "Legge una variabile d'ambiente di processo. Empty → fallback se impostato.",
    form    = function(step)
      local p = step.params or {}
      return {
        text_field("name",     "Env var name", "es. OS",
          p.name or ""),
        text_field("default",  "Default (opzionale, se unset)", "",
          p.default or ""),
        text_field("var",      "Variable name", "es. target_os",
          p.var or ""),
      }
    end,
  },

  builtin_set_var = {
    label   = "Builtin: set_var (literal)",
    category = "flow", icon = "BookmarkPlus", color = "info",
    summary = "Imposta una variabile run-context con un valore JSON literal (string/bool/number/array/object).",
    form    = function(step)
      local p = step.params or {}
      local value_str
      if type(p.value) == "string" then
        value_str = p.value
      else
        value_str = arbor.json.encode(p.value) or '""'
      end
      return {
        text_field("var",   "Variable name", "es. mode",
          p.var or ""),
        textarea("value",   "Value (JSON literal)", '"production"  oppure  42  oppure  true  oppure  ["a","b"]',
          value_str, 3),
      }
    end,
  },

  builtin_echo = {
    label   = "Builtin: echo (run log)",
    category = "flow", icon = "MessageSquareText", color = "neutral",
    summary = "Scrive un messaggio nel log della run e lo restituisce come return_value (debug).",
    form    = function(step)
      local p = step.params or {}
      return {
        text_field("message", "Messaggio (supporta ${var})", "es. Branch chosen: ${target_os}",
          p.message or ""),
        text_field("var",     "Variable name (opzionale)", "",
          p.var or ""),
      }
    end,
  },

  builtin_match = {
    label   = "Builtin: match (substring/regex)",
    category = "flow", icon = "Regex", color = "info",
    summary = "True quando target contiene `pattern` (literal) o matcha `regex`.",
    form    = function(step)
      local p = step.params or {}
      return {
        text_field("target",  "Target (può usare ${var})", "es. ${captured_line}",
          p.target or ""),
        text_field("pattern", "Substring (opzionale)", "es. ERROR",
          p.pattern or ""),
        text_field("regex",   "Regex (opzionale, prevale su pattern)", "es. ^Error: ",
          p.regex or ""),
        text_field("var",     "Variable name", "es. has_error",
          p.var or ""),
      }
    end,
  },
}

-- ── Lookups ─────────────────────────────────────────────────────────────────

function M.get(kind)
  return M.ops[kind]
end

function M.list_by_category()
  local by_cat = {}
  for _, c in ipairs(M.categories) do by_cat[c.id] = { cat = c, ops = {} } end
  -- Sort ops alphabetically within category for a stable palette.
  local names = {}
  for k, _ in pairs(M.ops) do names[#names+1] = k end
  table.sort(names)
  for _, k in ipairs(names) do
    local op = M.ops[k]
    local bucket = by_cat[op.category]
    if bucket then
      bucket.ops[#bucket.ops+1] = { kind = k, op = op }
    end
  end
  return by_cat
end

function M.filter(query)
  query = (query or ""):lower():gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1")
  if query == "" then return M.list_by_category() end
  local out = {}
  for _, c in ipairs(M.categories) do out[c.id] = { cat = c, ops = {} } end
  for kind, op in pairs(M.ops) do
    local hay = (op.label .. " " .. (op.summary or "") .. " " .. kind):lower()
    if hay:find(query, 1, true) then
      local bucket = out[op.category]
      if bucket then bucket.ops[#bucket.ops+1] = { kind = kind, op = op } end
    end
  end
  return out
end

return M
