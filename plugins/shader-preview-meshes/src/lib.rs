//! The meshes a shader preview starts with, as an Arbor extension.
//!
//! Implements `arbor:extensions/mesh-source@1` — the smallest interface in the set and the
//! only one that imports no capabilities at all. A mesh source is a pure function from
//! parameters to vertices: no network, no secrets, no filesystem, nothing to weigh.
//!
//! ## Four, and why not five
//!
//! A **sphere** shows a lighting term from every angle at once. A **cube** shows what happens
//! at a hard normal discontinuity. A **plane** gets the geometry out of the way of a shader
//! that only writes colour. A **torus** is the cheapest shape with both curvature signs — a
//! term that reads right on a sphere and wrong in a saddle shows the difference here and
//! nowhere else.
//!
//! Past those, the meshes that matter are the ones in your own engine, and this package has no
//! business guessing which. That is what a second `mesh-source` package is for: build it from
//! your own crates, drop it in the plugins folder, and it appears beside these. It never has
//! to be published, because a package is a folder with a `plugin.toml` — the registry is how
//! *other people* find one, not how Arbor loads one.
//!
//! ## Parameters
//!
//! `resolution` on the sphere and the torus, because the one thing worth turning up on a
//! preview mesh is how much geometry a normal-perturbing shader has to work with. Declared as
//! a JSON Schema so the panel can draw the control without this package having a UI.

mod primitives;

wit_bindgen::generate!({
    path: "../../wit",
    world: "mesh-source-world",
});

use exports::arbor::extensions::mesh_source::Guest;
use arbor::extensions::mesh_types::{MeshData, MeshKind};

struct Component;

/// The schema for a mesh whose only knob is how finely it is tessellated.
const RESOLUTION_SCHEMA: &str = r#"{
  "type": "object",
  "properties": {
    "resolution": {
      "type": "integer", "minimum": 1, "maximum": 4, "default": 2,
      "description": "How finely to tessellate. Turn it up when a shader perturbs normals."
    }
  }
}"#;

fn convert(m: primitives::Mesh) -> MeshData {
    MeshData {
        positions: m.positions,
        normals:   m.normals,
        uvs:       m.uvs,
        indices:   m.indices,
    }
}

/// Read `resolution` out of the caller's JSON, clamped.
///
/// A missing or malformed value is 2 rather than an error: the parameter is a convenience,
/// and refusing to build a mesh because a slider had not been touched yet would be worse than
/// building the default one.
fn resolution(params: &str) -> u32 {
    serde_json::from_str::<serde_json::Value>(params)
        .ok()
        .and_then(|v| v.get("resolution").and_then(|r| r.as_u64()))
        .unwrap_or(2)
        .clamp(1, 4) as u32
}

impl Guest for Component {
    fn catalogue() -> Vec<MeshKind> {
        primitives::PRIMITIVES
            .iter()
            .map(|p| MeshKind {
                id:            p.id.to_string(),
                label:         p.label.to_string(),
                description:   p.description.to_string(),
                params_schema: if p.tessellated { RESOLUTION_SCHEMA } else { "{}" }.to_string(),
            })
            .collect()
    }

    fn build(id: String, params: String) -> Result<MeshData, String> {
        primitives::build(&id, resolution(&params))
            .map(convert)
            .ok_or_else(|| format!("no mesh called '{id}' — this package offers sphere, cube, plane, torus"))
    }
}

export!(Component);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_listed_mesh_builds_and_every_schema_is_json() {
        // The catalogue and the builder are two places that have to agree, and the failure
        // mode of disagreeing is a picker entry that does nothing.
        for k in Component::catalogue() {
            assert!(Component::build(k.id.clone(), "{}".into()).is_ok(), "{} does not build", k.id);
            serde_json::from_str::<serde_json::Value>(&k.params_schema)
                .unwrap_or_else(|e| panic!("{}: schema is not JSON: {e}", k.id));
        }
    }

    #[test]
    fn an_unknown_id_says_what_is_on_offer() {
        let e = Component::build("dodecahedron".into(), "{}".into()).unwrap_err();
        assert!(e.contains("sphere") && e.contains("torus"), "{e}");
    }

    #[test]
    fn resolution_survives_junk_and_stays_in_range() {
        // Every one of these is a real thing a form sends: an empty table, a string from a
        // text input, a slider that has not been touched.
        assert_eq!(resolution("{}"), 2);
        assert_eq!(resolution(""), 2);
        assert_eq!(resolution(r#"{"resolution":"3"}"#), 2);
        assert_eq!(resolution(r#"{"resolution":3}"#), 3);
        assert_eq!(resolution(r#"{"resolution":99}"#), 4);
        assert_eq!(resolution(r#"{"resolution":0}"#), 1);
    }

    #[test]
    fn turning_the_resolution_up_produces_more_geometry() {
        let low = Component::build("sphere".into(), r#"{"resolution":1}"#.into()).unwrap();
        let high = Component::build("sphere".into(), r#"{"resolution":4}"#.into()).unwrap();
        assert!(
            high.positions.len() > low.positions.len(),
            "resolution did not reach the generator"
        );
        // A mesh with no knob ignores it rather than failing.
        let a = Component::build("cube".into(), r#"{"resolution":4}"#.into()).unwrap();
        let b = Component::build("cube".into(), "{}".into()).unwrap();
        assert_eq!(a.positions.len(), b.positions.len());
    }
}
