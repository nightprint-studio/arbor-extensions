// The scene, as fields instead of a RON document.
//
// Writing RON by hand to try a light angle is the wrong shape of work: the document is a
// *format*, and what a person is actually doing is turning a knob. So the knobs are the
// interface and the document is generated — which also means an invalid scene is not
// reachable by typing, only by a value being out of range.
//
// ## What this is for
//
// The harness uses it to make the whole scene tunable. The panel in Bennu should expose the
// same groups, because tuning a material IS mostly tuning the light on it: a normal
// perturbation that reads beautifully under one key light disappears under another, and
// judging that with a fixed rig means judging it once.
//
// The spec below is therefore a design proposal as much as a fixture: each group maps to a
// `section` form node, each field to a `number` / `range` / `color` / `vec_field`.

/** One tunable. `path` addresses the model, `kind` decides the widget. */
const F = (path, label, kind, extra = {}) => ({ path, label, kind, ...extra });

/**
 * The groups, in the order they should appear. Camera first because it is what you reach for
 * before anything else; lights last because that is where you end up staying.
 */
export const GROUPS = [
  {
    id: 'camera',
    title: 'Camera',
    fields: [
      F('camera.distance', 'Distance', 'range', { min: 0.6, max: 12, step: 0.05 }),
      F('camera.pitch', 'Pitch', 'range', { min: -1.4, max: 1.4, step: 0.01 }),
      F('camera.auto_spin', 'Turntable', 'range', { min: 0, max: 2, step: 0.05 }),
    ],
  },
  {
    id: 'environment',
    title: 'Environment',
    fields: [
      F('environment.background', 'Background', 'color'),
      // Low by default and worth keeping low: raise ambient and every micro-normal washes
      // out, which is the one thing a shader preview exists to show.
      F('environment.ambient', 'Ambient', 'range', { min: 0, max: 1, step: 0.01 }),
    ],
  },
  {
    id: 'material',
    title: 'Material',
    fields: [
      F('material.base_color', 'Base colour', 'color'),
      F('material.perceptual_roughness', 'Roughness', 'range', { min: 0, max: 1, step: 0.01 }),
      F('material.metallic', 'Metallic', 'range', { min: 0, max: 1, step: 0.01 }),
    ],
  },
  {
    id: 'key',
    title: 'Key light',
    fields: [
      F('lights.0.direction', 'Direction', 'vec3'),
      F('lights.0.color', 'Colour', 'color'),
      F('lights.0.illuminance', 'Illuminance', 'range', { min: 0, max: 30000, step: 100 }),
    ],
  },
  {
    id: 'fill',
    title: 'Fill light',
    fields: [
      F('lights.1.direction', 'Direction', 'vec3'),
      F('lights.1.color', 'Colour', 'color'),
      F('lights.1.illuminance', 'Illuminance', 'range', { min: 0, max: 30000, step: 100 }),
    ],
  },
];

/** The shipped rig's values, so the form opens on the scene the package actually ships. */
export const DEFAULTS = () => ({
  camera: { distance: 2.6, pitch: 0.30, auto_spin: 0.35 },
  environment: { background: [0.055, 0.062, 0.078], ambient: 0.14 },
  material: { base_color: [0.62, 0.60, 0.57], perceptual_roughness: 0.85, metallic: 0.0 },
  lights: [
    { direction: [-0.45, -0.72, -0.52], color: [1.0, 0.96, 0.90], illuminance: 11000 },
    { direction: [0.62, -0.25, 0.74], color: [0.55, 0.66, 0.85], illuminance: 2600 },
  ],
});

// ── Model access ──────────────────────────────────────────────────────────────

export const get = (model, path) =>
  path.split('.').reduce((o, k) => (o == null ? o : o[k]), model);

export function set(model, path, value) {
  const keys = path.split('.');
  const last = keys.pop();
  const target = keys.reduce((o, k) => o[k], model);
  target[last] = value;
}

// ── Colour, between a hex input and linear floats ────────────────────────────
//
// Bevy's colours are linear, an `<input type=color>` is sRGB hex. Skipping the conversion is
// the classic way to get a preview that is subtly, unaccountably darker than the game.

const toLinear = (c) => (c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4));
const toSrgb = (c) => (c <= 0.0031308 ? c * 12.92 : 1.055 * Math.pow(c, 1 / 2.4) - 0.055);

export const linearToHex = (rgb) =>
  '#' + rgb.slice(0, 3).map((c) => {
    const v = Math.round(Math.min(1, Math.max(0, toSrgb(c))) * 255);
    return v.toString(16).padStart(2, '0');
  }).join('');

export const hexToLinear = (hex) => {
  const n = parseInt(hex.slice(1), 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255].map((v) => toLinear(v / 255));
};

// ── RON ───────────────────────────────────────────────────────────────────────

const n = (v) => (Number.isInteger(v) ? v.toFixed(1) : String(v));
const tuple = (a) => '(' + a.map(n).join(', ') + ')';

/**
 * The material a shader written to BEVY's convention gets: an extension of `StandardMaterial`
 * with `vec4`s at bindings 100 and up, lit by the rig above.
 */
const shaderMaterial = (m) => `Shader(
                source: Param("shader"),
                params: [ Param("p0"), Param("p1"), Param("p2"), Param("p3") ],
                base_color: ${tuple([...m.material.base_color, 1.0])},
                perceptual_roughness: ${n(m.material.perceptual_roughness)},
                metallic: ${n(m.material.metallic)},
            )`;

/**
 * The material a shader that declares its OWN struct gets.
 *
 * No `base_color`, no roughness, no light: a shader that binds its own block at binding 0 and
 * returns colour from `fragment` owns the whole bind group, and there is no `StandardMaterial`
 * underneath it to configure. The block arrives as bytes under `data` — the runtime uploads it
 * without ever learning a field name.
 */
const rawMaterial = () => `Raw(
                source: Param("shader"),
                data: Param("data"),
                alpha: "blend",
            )`;

/**
 * Serialise the model into the document the runtime parses.
 *
 * Written out rather than patched into the shipped file: a generated document is the same
 * every time for the same values, so what you are looking at is exactly what the fields say
 * — no drift between a template and the knobs that were supposed to fill it.
 */
export function toRon(m, { raw = false } = {}) {
  const light = (l) => `        Directional(
            direction: ${tuple(l.direction)},
            color: ${tuple(l.color)},
            illuminance: ${n(l.illuminance)},
        ),`;

  return `// Generated by the harness from the scene form — edit the fields, not this.
(
    id: "shader_preview",
    name: "Shader preview",
    description: "One material, one mesh, a turntable and a two-light rig.",

    camera: Orbit(
        distance: Single(${n(m.camera.distance)}),
        pitch: ${n(m.camera.pitch)},
        auto_spin: ${m.camera.auto_spin > 0 ? `Some(${n(m.camera.auto_spin)})` : 'None'},
        fov: None,
    ),

    environment: (
        background: ${tuple(m.environment.background)},
        ambient: ${n(m.environment.ambient)},
    ),

    lights: [
${m.lights.map(light).join('\n')}
    ],

    entities: [
        (
            mesh: Param("mesh"),
            material: ${raw ? rawMaterial() : shaderMaterial(m)},
            position: (0.0, 0.0, 0.0),
            scale: 1.0,
            spin: 0.0,
        ),
    ],

    controls: [],
)
`;
}
