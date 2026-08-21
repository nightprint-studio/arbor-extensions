// The shapes the harness can send, and the parameters each one declares.
//
// ## The point of the declaration
//
// A mesh is not always "pick a name". A sphere has a segment count that decides whether a
// normal map reads or shimmers; a torus has two radii that change what the silhouette even
// is. Those are the knobs you reach for when judging a material, and a picker that only names
// shapes cannot offer them.
//
// So a shape declares its own parameters and the form is built from that declaration. The
// alternative — a hand-written form per shape — is how the picker and the panel drift apart
// the day somebody adds a shape.
//
// This is the shape of the contract the real plugin needs too. `arbor.ext.call` already
// returns a catalogue from the `mesh-source` extension and takes a JSON params string on
// `build`; what is missing is the *parameter declaration* in the catalogue entry, so the
// panel can render the fields without knowing the generator. That is the change this fixture
// is arguing for.

const P = (path, label, value, min, max, step) => ({ path, label, value, min, max, step, kind: 'range' });

export const SHAPES = [
  // Primitives the runtime builds itself: no parameters, because the runtime's own builders
  // take none. Listing them anyway is what makes "does the mesh change at all" a one-click
  // question, separate from "does the generator work".
  { id: 'Primitive:Sphere',   label: 'Sphere (built-in)' },
  { id: 'Primitive:Cube',     label: 'Cube (built-in)' },
  { id: 'Primitive:Plane',    label: 'Plane (built-in)' },
  { id: 'Primitive:Torus',    label: 'Torus (built-in)' },
  { id: 'Primitive:Capsule',  label: 'Capsule (built-in)' },
  { id: 'Primitive:Cylinder', label: 'Cylinder (built-in)' },

  // Generated here, through the same `Raw` path the real plugin uses for the extension's
  // output — so a parameter that changes the geometry proves the whole vertex route, not just
  // the enum name.
  {
    id: 'raw:sphere',
    label: 'Sphere (generated)',
    params: [
      P('radius', 'Radius', 1, 0.2, 3, 0.05),
      // Segments matter more than they look: too few and a smooth normal reads as facets,
      // which is easy to mistake for the shader being wrong.
      P('segments', 'Segments', 32, 6, 128, 1),
      P('rings', 'Rings', 24, 4, 96, 1),
    ],
  },
  {
    id: 'raw:torus',
    label: 'Torus (generated)',
    params: [
      P('radius', 'Radius', 1, 0.3, 3, 0.05),
      P('tube', 'Tube', 0.35, 0.05, 1.5, 0.01),
      P('segments', 'Segments', 48, 8, 160, 1),
      P('rings', 'Rings', 24, 4, 96, 1),
    ],
  },
  {
    id: 'raw:plane',
    label: 'Plane (generated)',
    params: [
      P('size', 'Size', 2, 0.2, 8, 0.05),
      // A subdivided plane is the honest way to look at a displacement or a parallax term: on
      // two triangles there is nothing for it to act on.
      P('subdivisions', 'Subdivisions', 8, 1, 128, 1),
    ],
  },
];

/** `{ Primitive: "Sphere" }` or `{ Raw: {...} }` — externally tagged, like the Rust enum. */
export function buildMesh(shape, params) {
  if (shape.id.startsWith('Primitive:')) {
    return { Primitive: shape.id.slice('Primitive:'.length) };
  }
  switch (shape.id) {
    case 'raw:sphere': return { Raw: sphere(params) };
    case 'raw:torus':  return { Raw: torus(params) };
    case 'raw:plane':  return { Raw: plane(params) };
    default:           return { Primitive: 'Sphere' };
  }
}

// ── Generators ────────────────────────────────────────────────────────────────
//
// FLAT arrays of floats, not arrays of triples: `MeshSpec::Raw` is `positions: Vec<f32>`, the
// shape a GPU buffer actually has. Getting it wrong says "invalid type: sequence, expected
// f32" — which is how this harness earned its keep on its first run.

function sphere({ radius = 1, segments = 32, rings = 24 }) {
  const positions = [], normals = [], uvs = [], indices = [];
  const seg = Math.round(segments), rng = Math.round(rings);
  for (let y = 0; y <= rng; y++) {
    const v = y / rng, phi = v * Math.PI;
    for (let x = 0; x <= seg; x++) {
      const u = x / seg, theta = u * Math.PI * 2;
      const nx = Math.sin(phi) * Math.cos(theta);
      const ny = Math.cos(phi);
      const nz = Math.sin(phi) * Math.sin(theta);
      positions.push(nx * radius, ny * radius, nz * radius);
      normals.push(nx, ny, nz);
      uvs.push(u, v);
    }
  }
  for (let y = 0; y < rng; y++) {
    for (let x = 0; x < seg; x++) {
      const a = y * (seg + 1) + x, b = a + seg + 1;
      indices.push(a, b, a + 1, b, b + 1, a + 1);
    }
  }
  return { positions, normals, uvs, indices };
}

function torus({ radius = 1, tube = 0.35, segments = 48, rings = 24 }) {
  const positions = [], normals = [], uvs = [], indices = [];
  const seg = Math.round(segments), rng = Math.round(rings);
  for (let j = 0; j <= rng; j++) {
    const v = (j / rng) * Math.PI * 2;
    for (let i = 0; i <= seg; i++) {
      const u = (i / seg) * Math.PI * 2;
      const cx = Math.cos(u) * radius, cz = Math.sin(u) * radius;
      const nx = Math.cos(u) * Math.cos(v), ny = Math.sin(v), nz = Math.sin(u) * Math.cos(v);
      positions.push(cx + nx * tube, ny * tube, cz + nz * tube);
      normals.push(nx, ny, nz);
      uvs.push(i / seg, j / rng);
    }
  }
  for (let j = 0; j < rng; j++) {
    for (let i = 0; i < seg; i++) {
      const a = j * (seg + 1) + i, b = a + seg + 1;
      indices.push(a, b, a + 1, b, b + 1, a + 1);
    }
  }
  return { positions, normals, uvs, indices };
}

function plane({ size = 2, subdivisions = 8 }) {
  const positions = [], normals = [], uvs = [], indices = [];
  const n = Math.round(subdivisions);
  const half = size / 2;
  for (let y = 0; y <= n; y++) {
    for (let x = 0; x <= n; x++) {
      const u = x / n, v = y / n;
      positions.push(-half + u * size, 0, -half + v * size);
      normals.push(0, 1, 0);
      uvs.push(u, v);
    }
  }
  for (let y = 0; y < n; y++) {
    for (let x = 0; x < n; x++) {
      const a = y * (n + 1) + x, b = a + n + 1;
      indices.push(a, b, a + 1, b, b + 1, a + 1);
    }
  }
  return { positions, normals, uvs, indices };
}
