// Saved parameter sets, remembered per material and restored when it is opened again.
//
// ## Why this earns its place
//
// Finding the values that make a material read well is the work. Ten sliders reach a look
// after a few minutes of pushing them around, and every one of those minutes is thrown away
// by closing the panel — silently, with the next session starting from the same neutral
// defaults as the first.
//
// ## Where they belong: beside the shaders, one file per folder
//
// A look is not a preference like a font size. It is **work about a file**: these numbers mean
// something only next to `stone.wgsl`, they are worth showing someone else, and they are worth
// committing. So they live in the project, not in `~/.config` and certainly not in
// `localStorage`, which the working agreement rules out for anything persistent.
//
// Which leaves the real question: beside the shaders, or in `.arbor/`?
//
// `.arbor/` is the per-repo location the working agreement defines, and it is the wrong one
// here for a decisive reason: **it is gitignored**. Everything in it is machine-local state by
// construction. Putting looks there means a look found on one machine stays on that machine —
// which is the one outcome this whole file exists to prevent.
//
// So they sit beside the shaders, and the cost of that is worth naming honestly rather than
// inflated. In a Bevy project shaders live under `assets/`, and `assets/` is shipped with the
// game — so a few kilobytes of editor state ship too. It is not a load error: the AssetServer
// loads on demand by path and never asks for a file nobody references. Clutter and a few KB,
// against a feature that otherwise does not work at all.
//
// **One file per folder**, not one per shader. Twenty shaders should not become forty entries
// in a directory somebody has to read, and a single file is what you diff when a look changes.

// ## The store is pluggable, and that is the whole point of this file
//
// Reading and writing is one small interface. Arbor's plugin passes an `arbor.fs`-backed one
// writing `shader-previews.json` in the folder the shader came from; this harness has no
// backend, so it passes `localStorage` — an honest fixture compromise, not the design. Everything else — how a
// material is identified, what happens when its fields change, which template opens by
// default — is shared, so the two cannot drift on the parts that are actually decided.

/** The shape a store has to have. Two calls, both synchronous, both allowed to fail. */
export const localStorageStore = {
  read() {
    try {
      return JSON.parse(localStorage.getItem('arbor.bevy-runtime.templates') ?? '{}') ?? {};
    } catch {
      // A corrupt store is not worth an error message: the next save overwrites it, and
      // losing saved looks costs less than a panel that refuses to open.
      return {};
    }
  },
  write(data) {
    try {
      localStorage.setItem('arbor.bevy-runtime.templates', JSON.stringify(data));
    } catch {
      /* quota, private mode — saving is a convenience, not a promise */
    }
  },
};

/**
 * Templates over a store.
 *
 * ## Keyed by the struct, not by the file path
 *
 * A material is identified by the struct it declares — `SpiralHoverParams` — rather than by
 * where the file happens to sit. A shader that is moved or renamed keeps its looks, and two
 * files declaring the same block share them, which is usually what somebody who copied one
 * meant.
 *
 * Field NAMES are stored with each value, and that is the load-bearing part: a template
 * restored into a material whose fields have changed would otherwise write numbers at offsets
 * that no longer mean the same thing. What no longer exists is dropped instead.
 */
export function createTemplates(store = localStorageStore) {
  const all = () => store.read() ?? {};

  return {
    /** The names saved for a material, alphabetically. */
    namesFor(struct) {
      return Object.keys(all()[struct] ?? {}).sort();
    },

    save(struct, name, values) {
      const data = all();
      data[struct] = { ...(data[struct] ?? {}), [name]: values };
      store.write(data);
    },

    remove(struct, name) {
      const data = all();
      if (!data[struct]) return;
      delete data[struct][name];
      if (Object.keys(data[struct]).length === 0) delete data[struct];
      store.write(data);
    },

    /**
     * The values saved under a name, restricted to fields the material still has.
     *
     * Dropping the rest rather than restoring it: a field removed from the shader has no
     * offset any more, and one whose type changed would take a value shaped for the old one.
     * What survives is what still means what it meant.
     */
    load(struct, name, fields) {
      const saved = all()[struct]?.[name];
      if (!saved) return null;
      const out = {};
      for (const f of fields) {
        if (f.name in saved) out[f.name] = saved[f.name];
      }
      return out;
    },

    /**
     * The name a material opens with, if one was marked.
     *
     * One per material, because "the one I want by default" is a single answer. Marked
     * implicitly: the last template loaded or saved becomes the one that opens next time, so
     * the common case — settle on a look, carry on working with it — needs no extra gesture.
     */
    preferred(struct) {
      return all().__default?.[struct] ?? null;
    },

    setPreferred(struct, name) {
      const data = all();
      data.__default = { ...(data.__default ?? {}), [struct]: name };
      store.write(data);
    },
  };
}
