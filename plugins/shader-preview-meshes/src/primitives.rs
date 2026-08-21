//! The four meshes this package offers.
//!
//! Four, and deliberately four: a **sphere** because it shows a lighting term from every
//! angle at once, a **cube** because it shows what happens at a hard normal discontinuity, a
//! **plane** because a shader that only writes colour wants no geometry in the way, and a
//! **torus** because it is the cheapest shape with both curvature signs — a term that looks
//! right on a sphere and wrong in a saddle shows the difference here and nowhere else.
//!
//! Anything past those is somebody's own geometry, and that is what a *second* `mesh-source`
//! package is for — one built from your own engine, never published. A fifth primitive here
//! would be this package guessing which engine you write for.
//!
//! ## Layout
//!
//! Flat `f32` lists in the same layout the interface uses, so a built-in and an extension's
//! mesh are the same value by the time anything downstream sees them. Positions are centred
//! on the origin and sized to fit a unit-ish box, because the preview camera is fixed and a
//! mesh that arrives ten units wide is a mesh nobody can see.

use std::f32::consts::PI;

/// Vertices and triangles, in the layout the GPU wants.
///
/// Its own type rather than the generated `MeshData`, so the geometry and its tests compile
/// on the host: a `cargo test` that had to run inside a component is a test nobody runs.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Mesh {
    pub positions: Vec<f32>,
    pub normals:   Vec<f32>,
    pub uvs:       Vec<f32>,
    pub indices:   Vec<u32>,
}

impl Mesh {
    pub fn vertex_count(&self) -> usize {
        self.positions.len() / 3
    }
}

/// One built-in, as the picker lists it.
pub struct Primitive {
    pub id:          &'static str,
    pub label:       &'static str,
    pub description: &'static str,
    /// Whether it takes a `resolution`. A cube and a quad have nothing to subdivide, and
    /// offering the control anyway would be a knob that does nothing.
    pub tessellated: bool,
}

pub const PRIMITIVES: &[Primitive] = &[
    Primitive {
        id: "sphere",
        label: "Sphere",
        description: "Every surface normal at once — the default for a lighting term.",
        tessellated: true,
    },
    Primitive {
        id: "cube",
        label: "Cube",
        description: "Hard normal discontinuities and flat faces.",
        tessellated: false,
    },
    Primitive {
        id: "plane",
        label: "Plane",
        description: "Facing the camera. Tessellate it when the shader moves vertices.",
        tessellated: true,
    },
    Primitive {
        id: "torus",
        label: "Torus",
        description: "Both curvature signs, which a sphere cannot show.",
        tessellated: true,
    },
];

/// Build one by id, or `None` when this package does not offer it.
pub fn build(id: &str, resolution: u32) -> Option<Mesh> {
    // 1..=4 scales the segment counts. The low end is coarse enough to see the silhouette of
    // the tessellation itself, which is occasionally what you want to check.
    let k = resolution.clamp(1, 4) as usize;
    match id {
        "sphere" => Some(sphere(12 * k, 8 * k)),
        "cube"   => Some(cube()),
        "plane"  => Some(plane(16 * k)),
        "torus"  => Some(torus(12 * k, 6 * k, 0.62, 0.26)),
        _ => None,
    }
}

// ── Sphere ──────────────────────────────────────────────────────────────────────

/// UV sphere, radius 0.8.
///
/// Poles are duplicated per column rather than shared: a shared pole vertex has one uv, and
/// every column meeting there wants a different one — which is the seam you see as a pinched
/// smear in every texture-mapped sphere that got this wrong.
fn sphere(segments: usize, rings: usize) -> Mesh {
    const R: f32 = 0.8;
    let mut m = Mesh::default();

    for ring in 0..=rings {
        let v = ring as f32 / rings as f32;
        let phi = v * PI;
        let (sin_phi, cos_phi) = phi.sin_cos();
        for seg in 0..=segments {
            let u = seg as f32 / segments as f32;
            let theta = u * PI * 2.0;
            let (sin_theta, cos_theta) = theta.sin_cos();

            let nx = sin_phi * cos_theta;
            let ny = cos_phi;
            let nz = sin_phi * sin_theta;

            m.positions.extend_from_slice(&[nx * R, ny * R, nz * R]);
            m.normals.extend_from_slice(&[nx, ny, nz]);
            m.uvs.extend_from_slice(&[u, 1.0 - v]);
        }
    }

    let stride = segments + 1;
    for ring in 0..rings {
        for seg in 0..segments {
            let a = (ring * stride + seg) as u32;
            let b = a + stride as u32;
            // The degenerate triangles at the poles are left in. Removing them means a
            // special case in a loop whose whole value is not having one, and the GPU
            // discards a zero-area triangle before it shades anything.
            m.indices.extend_from_slice(&[a, b, a + 1, a + 1, b, b + 1]);
        }
    }
    m
}

// ── Cube ────────────────────────────────────────────────────────────────────────

/// Unit-ish cube, 1.2 across, with per-face normals.
///
/// Twenty-four vertices and not eight: a cube's corner has three different normals, and
/// sharing the position would average them into something round.
fn cube() -> Mesh {
    const H: f32 = 0.6;
    // (normal, tangent-u, tangent-v) per face — the two tangents span the face, so one loop
    // emits all six without six copies of the winding.
    let faces: [([f32; 3], [f32; 3], [f32; 3]); 6] = [
        ([ 0.0,  0.0,  1.0], [ 1.0, 0.0,  0.0], [0.0,  1.0, 0.0]),
        ([ 0.0,  0.0, -1.0], [-1.0, 0.0,  0.0], [0.0,  1.0, 0.0]),
        ([ 1.0,  0.0,  0.0], [ 0.0, 0.0, -1.0], [0.0,  1.0, 0.0]),
        ([-1.0,  0.0,  0.0], [ 0.0, 0.0,  1.0], [0.0,  1.0, 0.0]),
        ([ 0.0,  1.0,  0.0], [ 1.0, 0.0,  0.0], [0.0, 0.0, -1.0]),
        ([ 0.0, -1.0,  0.0], [ 1.0, 0.0,  0.0], [0.0, 0.0,  1.0]),
    ];

    let mut m = Mesh::default();
    for (n, tu, tv) in faces {
        let base = m.vertex_count() as u32;
        for (su, sv) in [(-1.0_f32, -1.0_f32), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)] {
            m.positions.extend_from_slice(&[
                (n[0] + tu[0] * su + tv[0] * sv) * H,
                (n[1] + tu[1] * su + tv[1] * sv) * H,
                (n[2] + tu[2] * su + tv[2] * sv) * H,
            ]);
            m.normals.extend_from_slice(&n);
            m.uvs.extend_from_slice(&[(su + 1.0) * 0.5, (sv + 1.0) * 0.5]);
        }
        m.indices.extend_from_slice(&[base, base + 1, base + 2, base, base + 2, base + 3]);
    }
    m
}

// ── Plane ───────────────────────────────────────────────────────────────────────

/// A grid facing +Z, 1.6 across, `cells` quads on a side.
///
/// Subdivided, and it did not used to be: four corners is all a fragment shader needs, and a
/// quad is what this was. But a **vertex** shader has nothing to move on four corners — a water
/// surface displaced at its corners is a tilted sheet of glass — and the plane is exactly the
/// mesh anyone reaches for to try one. The tessellation control the sphere and the torus
/// already had covers it; at the low end this is still very nearly the old quad.
fn plane(cells: usize) -> Mesh {
    const H: f32 = 0.8;
    let n = cells.max(1);
    let mut m = Mesh::default();

    for y in 0..=n {
        for x in 0..=n {
            let u = x as f32 / n as f32;
            let v = y as f32 / n as f32;
            m.positions.extend_from_slice(&[-H + 2.0 * H * u, -H + 2.0 * H * v, 0.0]);
            m.normals.extend_from_slice(&[0.0, 0.0, 1.0]);
            // `v` flipped, so the top of the quad is uv.y = 0 — the convention the rest of
            // this package uses and the one a texture is authored against.
            m.uvs.extend_from_slice(&[u, 1.0 - v]);
        }
    }

    let stride = (n + 1) as u32;
    for y in 0..n as u32 {
        for x in 0..n as u32 {
            let i = y * stride + x;
            m.indices.extend_from_slice(&[i, i + 1, i + stride + 1, i, i + stride + 1, i + stride]);
        }
    }
    m
}

// ── Torus ───────────────────────────────────────────────────────────────────────

fn torus(major_segments: usize, minor_segments: usize, major_r: f32, minor_r: f32) -> Mesh {
    let mut m = Mesh::default();

    for i in 0..=major_segments {
        let u = i as f32 / major_segments as f32;
        let (sin_u, cos_u) = (u * PI * 2.0).sin_cos();
        for j in 0..=minor_segments {
            let v = j as f32 / minor_segments as f32;
            let (sin_v, cos_v) = (v * PI * 2.0).sin_cos();

            // The normal is the offset from the tube's centre circle, which is already unit
            // length by construction — no normalisation, and no chance of one being skipped.
            let nx = cos_v * cos_u;
            let ny = sin_v;
            let nz = cos_v * sin_u;

            m.positions.extend_from_slice(&[
                (major_r + minor_r * cos_v) * cos_u,
                minor_r * sin_v,
                (major_r + minor_r * cos_v) * sin_u,
            ]);
            m.normals.extend_from_slice(&[nx, ny, nz]);
            m.uvs.extend_from_slice(&[u, v]);
        }
    }

    let stride = minor_segments + 1;
    for i in 0..major_segments {
        for j in 0..minor_segments {
            let a = (i * stride + j) as u32;
            let b = a + stride as u32;
            m.indices.extend_from_slice(&[a, b, a + 1, a + 1, b, b + 1]);
        }
    }
    m
}

#[cfg(test)]
mod tests {
    use super::*;

    fn all() -> Vec<(&'static str, Mesh)> {
        PRIMITIVES.iter().map(|p| (p.id, build(p.id, 2).expect("listed but not buildable"))).collect()
    }

    #[test]
    fn every_listed_primitive_builds() {
        // The list and the builder are two places that have to agree, and the failure mode of
        // disagreeing is a picker entry that does nothing.
        assert_eq!(all().len(), PRIMITIVES.len());
        assert!(build("nope", 2).is_none());
    }

    #[test]
    fn the_three_attribute_lists_agree_on_the_vertex_count() {
        // A short normals list does not fail — it binds a buffer that runs out mid-draw, and
        // the shading goes wrong somewhere past the middle of the mesh.
        for (id, m) in all() {
            let n = m.vertex_count();
            assert!(n > 0, "{id} has no vertices");
            assert_eq!(m.positions.len(), n * 3, "{id} positions");
            assert_eq!(m.normals.len(),   n * 3, "{id} normals");
            assert_eq!(m.uvs.len(),       n * 2, "{id} uvs");
        }
    }

    #[test]
    fn every_index_addresses_a_vertex_that_exists() {
        // Out of range here is a GPU-side read of whatever follows the buffer.
        for (id, m) in all() {
            assert_eq!(m.indices.len() % 3, 0, "{id}: indices are not whole triangles");
            let n = m.vertex_count() as u32;
            assert!(m.indices.iter().all(|&i| i < n), "{id}: an index is past the end");
        }
    }

    #[test]
    fn normals_are_unit_length() {
        // The lighting is wrong by exactly the scale factor otherwise, which reads as "the
        // shader is too dark" and sends you looking in the shader.
        for (id, m) in all() {
            for (i, n) in m.normals.chunks(3).enumerate() {
                let len = (n[0] * n[0] + n[1] * n[1] + n[2] * n[2]).sqrt();
                assert!((len - 1.0).abs() < 1e-4, "{id}: normal {i} has length {len}");
            }
        }
    }

    #[test]
    fn nothing_escapes_the_camera_box() {
        // The preview camera is fixed, so a mesh that does not fit is a mesh nobody sees.
        for (id, m) in all() {
            for c in m.positions.chunks(3) {
                assert!(
                    c.iter().all(|v| v.abs() <= 1.0 + 1e-4),
                    "{id}: a vertex at {c:?} is outside the unit box"
                );
            }
        }
    }

    #[test]
    fn a_cube_corner_is_not_smoothed_away() {
        // Twenty-four vertices, not eight: the whole point of the cube is the discontinuity.
        let c = build("cube", 2).unwrap();
        assert_eq!(c.vertex_count(), 24);
        assert_eq!(c.indices.len(), 36);
    }
}
