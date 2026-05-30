-- mojibake.lua — UTF-8 / CP1252 mojibake detection and repair.
--
-- The classic mojibake we hunt is the result of a 3-step accident:
--
--   1. A file was authored UTF-8 (every non-ASCII char is 2-3 bytes).
--   2. An editor or tool opened it as Windows-1252, byte-by-byte. Each
--      UTF-8 byte became a Windows-1252 character on its own.
--   3. The editor re-saved as UTF-8. Every CP1252 char became its UTF-8
--      multibyte encoding, so the original character is now a 2-or-3
--      character cluster like `a-circumflex + euro + something`.
--
-- The PATTERNS table below lists each cluster we recognise, keyed by the
-- character it came from. Sequences are built from explicit codepoints
-- (via `utf8.char`) so this source file itself contains zero literal
-- mojibake bytes — the plugin would otherwise self-flag when run on its
-- own folder.

local M = {}

local function ch(cp) return utf8.char(cp) end

-- The "I was reinterpreted as CP1252" prefix common to almost every
-- mojibake-of-a-U+20XX-character: `a-circumflex` + `euro` in display.
M.PREFIX = ch(0x00E2) .. ch(0x20AC)

-- One row per known mojibake cluster. `label` is what we surface in scan
-- results; `to` is the original character we restore on fix.
M.PATTERNS = {
  -- U+20AC (€) family — comes from the first non-ASCII byte of any
  -- U+2000-U+20FF codepoint when read as CP1252. Covers most editorial
  -- punctuation.
  { from = ch(0x00E2) .. ch(0x20AC) .. ch(0x00A6), to = ch(0x2026), label = "ellipsis"     },
  { from = ch(0x00E2) .. ch(0x20AC) .. ch(0x201D), to = ch(0x2014), label = "em dash"      },
  { from = ch(0x00E2) .. ch(0x20AC) .. ch(0x2013), to = ch(0x2013), label = "en dash"      },
  { from = ch(0x00E2) .. ch(0x20AC) .. ch(0x2122), to = ch(0x2019), label = "rsquo"        },
  { from = ch(0x00E2) .. ch(0x20AC) .. ch(0x0153), to = ch(0x201C), label = "lquote"       },
  { from = ch(0x00E2) .. ch(0x20AC) .. ch(0x009D), to = ch(0x201D), label = "rquote"       },
  { from = ch(0x00E2) .. ch(0x20AC) .. ch(0x00A2), to = ch(0x2022), label = "bullet"       },
  -- U+2020 (dagger) family — codepoints U+2100-U+21FF.
  { from = ch(0x00E2) .. ch(0x2020) .. ch(0x2019), to = ch(0x2192), label = "right arrow"  },
  -- U+201D (right curly quote) family — codepoints U+2400-U+25FF, common
  -- for box-drawing, geometric shapes (circles, squares), arrows.
  { from = ch(0x00E2) .. ch(0x201D) .. ch(0x20AC), to = ch(0x2500), label = "box-drawing"  },
  { from = ch(0x00E2) .. ch(0x2014) .. ch(0x008F), to = ch(0x25CF), label = "black circle" },
  { from = ch(0x00E2) .. ch(0x2014) .. ch(0x2039), to = ch(0x25CB), label = "white circle" },
  { from = ch(0x00E2) .. ch(0x2014) .. ch(0x2026), to = ch(0x2605), label = "black star"   },
}

-- Secondary "I was reinterpreted" prefix: a-circumflex + em-dash, common
-- for U+2400-U+25FF codepoints (geometric shapes, arrows, box-drawing).
M.PREFIX_EMDASH = ch(0x00E2) .. ch(0x2014)

-- ── Detection ──────────────────────────────────────────────────────────────

-- Returns `{ total, breakdown[label] = n, exotic = n }` for the given
-- bytes. `total` is the sum of every known-pattern hit; `exotic` is the
-- residual count of `PREFIX` matches that no row covers — those are
-- almost certainly mojibake too, but we don't auto-fix them because the
-- third codepoint is unknown.
function M.detect(content)
  local breakdown = {}
  local total     = 0
  for _, p in ipairs(M.PATTERNS) do
    local _, hits = content:gsub(p.from, "")
    if hits > 0 then
      breakdown[p.label] = hits
      total = total + hits
    end
  end
  -- The two prefixes — `â€` (U+20AC) and `â—` (U+2014) — are the giveaway
  -- byte pairs that mark CP1252 mojibake. Sum the residual after known
  -- patterns are subtracted so the "exotic" counter only flags clusters
  -- our table doesn't repair.
  local _, prefix_euro_hits  = content:gsub(M.PREFIX,        "")
  local _, prefix_emdash_hits = content:gsub(M.PREFIX_EMDASH, "")
  local exotic = (prefix_euro_hits + prefix_emdash_hits) - total
  if exotic < 0 then exotic = 0 end
  return { total = total, breakdown = breakdown, exotic = exotic }
end

-- ── Repair ─────────────────────────────────────────────────────────────────

-- Apply every known repair to `content`. Returns `(new_content, n_fixed)`.
-- Untouched and equal to the input when no known sequence matched.
function M.fix(content)
  local total = 0
  for _, p in ipairs(M.PATTERNS) do
    local new, n = content:gsub(p.from, p.to)
    if n > 0 then total = total + n; content = new end
  end
  return content, total
end

-- ── Display helpers ────────────────────────────────────────────────────────

-- Human-readable "ellipsis x3, em dash x1" summary, sorted alphabetically
-- so the same set of hits always renders the same way.
function M.summarise(detection)
  local parts = {}
  for label, n in pairs(detection.breakdown) do
    parts[#parts + 1] = string.format("%s x%d", label, n)
  end
  table.sort(parts)
  return table.concat(parts, ", ")
end

-- A neutral display sample we can interpolate into messages without
-- baking real mojibake bytes into the source file. Looks like the
-- prefix followed by the literal letter X.
function M.sample_prefix()
  return M.PREFIX .. "X"
end

return M
