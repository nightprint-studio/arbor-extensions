// Turns a material's declared parameters into controls, and the controls back into bytes.
//
// Takes the description Bennu produces — `bennu_shader_uniform`, or `arbor.shader.uniform`
// from a plugin — and does the two things that are genuinely presentation:
//
//   · decide what widget a field gets;
//   · pack the values into the buffer, at the offsets the description gives.
//
// It does **not** read WGSL. That was tried here and got the same two things wrong twice —
// nested block comments, and `@group(0)` being the view's bind group rather than the
// material's. Bennu already reads WGSL for highlighting and for checking a material's Rust
// half against its shader half, so the description comes from there and this file consumes it.
//
// The description's shape (one field):
//   { name, ty, offset, size, columns, rows, column_stride }

/**
 * What control a field should get, guessed from its name.
 *
 * Guessing is the right call and not a shortcut: WGSL has no way to say "this vec4 is a
 * colour" or "this scalar runs 0 to 1", and the alternative is four lanes of raw float for a
 * colour the author obviously meant to pick. A wrong guess costs a slider with an odd range;
 * no guess costs the panel its readability.
 *
 * The vocabulary is the one shader authors actually use — each of these names means the same
 * thing in every shader that has one.
 */
export function widgetFor(field) {
  // A matrix gets no widget. Deciding what a mat3x3 editor looks like is a real design
  // question, and a wrong answer to it is worse than an honest "not editable here".
  if (field.columns > 1) return { widget: 'readonly' };

  const n = field.name.toLowerCase();
  if (field.rows >= 3 && /colou?r|tint|albedo|emissive/.test(n)) {
    return { widget: 'color', alpha: field.rows === 4 };
  }
  if (field.rows > 1) return { widget: 'vec' };

  if (/softness|strength|amount|mix|blend|alpha|opacity|roughness|metallic|intensity/.test(n)) {
    return { widget: 'range', min: 0, max: 1, step: 0.01 };
  }
  if (/radius|width|height|size|thickness|offset/.test(n)) {
    return { widget: 'range', min: 0, max: 1, step: 0.005 };
  }
  if (/speed|rate/.test(n))         return { widget: 'range', min: -4, max: 4, step: 0.01 };
  if (/scale|density|freq/.test(n)) return { widget: 'range', min: 0, max: 64, step: 0.1 };
  if (/count|arms|steps|octaves|segments/.test(n)) return { widget: 'range', min: 1, max: 16, step: 1 };
  if (/sharp|power|exp|contrast|gamma/.test(n))    return { widget: 'range', min: 0.1, max: 12, step: 0.05 };
  return { widget: 'range', min: -4, max: 4, step: 0.01 };
}

/** Every field with its widget decided, in declaration order. */
export const withWidgets = (desc) =>
  (desc.fields ?? []).map((f) => ({ ...f, ...widgetFor(f) }));

/** A starting value per field — mid-range for a scalar, a neutral grey for a colour. */
export function defaultsFor(fields) {
  const out = {};
  for (const f of fields) {
    if (f.widget === 'color') out[f.name] = f.alpha ? [0.6, 0.6, 0.6, 1] : [0.6, 0.6, 0.6];
    else if (f.columns > 1) out[f.name] = new Array(f.columns * f.rows).fill(0);
    else if (f.rows > 1) out[f.name] = new Array(f.rows).fill(0);
    else out[f.name] = f.min < 0 ? 0 : (f.min + f.max) / 4;
  }
  return out;
}

/** Random values inside each field's own range — a colour stays a colour. */
export function randomise(fields) {
  const out = {};
  const r = (min, max) => min + Math.random() * (max - min);
  for (const f of fields) {
    if (f.widget === 'color') {
      const rgb = [Math.random(), Math.random(), Math.random()];
      out[f.name] = f.alpha ? [...rgb, 1] : rgb;
    } else if (f.columns > 1) {
      // Left alone: a random matrix is a mangled transform, not an interesting one.
      out[f.name] = new Array(f.columns * f.rows).fill(0);
    } else if (f.rows > 1) {
      out[f.name] = Array.from({ length: f.rows }, () => r(-1, 1));
    } else {
      const v = r(f.min, f.max);
      out[f.name] = f.step >= 1 ? Math.round(v) : Math.round(v * 1000) / 1000;
    }
  }
  return out;
}

/**
 * Pack the values into the flat float buffer the uniform expects.
 *
 * Offsets come from the description, so the padding a `vec4` forces after three scalars is
 * real padding here too — and a matrix is written column by column at its own stride, which
 * is the rule that makes a `mat3x3<f32>` 48 bytes and not 36.
 */
export function pack(desc, fields, values) {
  const floats = new Array((desc.size ?? 0) / 4).fill(0);
  for (const f of fields) {
    const v = values[f.name];
    if (v == null) continue;
    if (f.columns > 1) {
      for (let c = 0; c < f.columns; c++) {
        const at = (f.offset + c * f.column_stride) / 4;
        for (let r = 0; r < f.rows; r++) floats[at + r] = Number(v[c * f.rows + r]) || 0;
      }
      continue;
    }
    const at = f.offset / 4;
    if (f.rows === 1) floats[at] = Number(v) || 0;
    else for (let i = 0; i < f.rows; i++) floats[at + i] = Number(v[i]) || 0;
  }
  return floats;
}
