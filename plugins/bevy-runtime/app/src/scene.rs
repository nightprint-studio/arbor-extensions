//! What a scene is, as data.
//!
//! ## Why RON and not Rust
//!
//! A Bevy app compiled to wasm cannot load Rust at runtime. So if a scene were a Rust
//! function, adding one would mean rebuilding and reshipping this runtime — which is the same
//! shape as "the host has to learn something", moved one layer down. A scene is a document
//! instead, and adding one is adding a file.
//!
//! The dialect follows the convention already used across `legions-of-fate`: a top-level tuple
//! struct with named fields, enums as `Variant(…)`, `Single(x)` / `Uniform(a, b)` where a value
//! may be fixed or a range.
//!
//! ## Holes
//!
//! A scene declares what it does **not** know with [`Slot::Param`]. `mesh: Param("mesh")` means
//! "whoever opens this scene supplies the mesh"; the runtime resolves it against the params it
//! was handed. That is what makes one scene reusable across callers, and what makes an
//! `update` meaningful — a param can change without the scene being rebuilt.
//!
//! A `Param` with no value is not an error at load time and is at build time, so a scene can be
//! parsed and inspected (which params does it want?) before anything is opened.
//!
//! ## No renderer in here
//!
//! Nothing in this module imports Bevy. A scene document is data, and reading one should not
//! need a graphics stack — which is also why its tests run in a second rather than after a
//! Bevy build.

use serde::Deserialize;

/// A number that may be fixed or drawn from a range.
///
/// The same two-shaped value the VFX documents use, so an author moving between them does not
/// meet a second spelling of the same idea.
#[derive(Debug, Clone, Deserialize)]
pub enum Scalar {
    Single(f32),
    Uniform(f32, f32),
}

impl Scalar {
    /// The representative value. A range resolves to its midpoint here rather than a sample:
    /// a preview that jittered its camera distance every frame would be unusable, and the
    /// range form exists so one document can serve both this and a spawner.
    pub fn value(&self) -> f32 {
        match self {
            Scalar::Single(v) => *v,
            Scalar::Uniform(a, b) => (a + b) * 0.5,
        }
    }
}

/// Something the document either states outright or leaves to the caller.
#[derive(Debug, Clone, Deserialize)]
pub enum Slot<T> {
    /// Written in the document.
    Value(T),
    /// Supplied when the scene is opened, under this name.
    Param(String),
}

/// How the camera behaves.
#[derive(Debug, Clone, Deserialize)]
pub enum CameraRig {
    /// Fixed position, looking at a point.
    Static {
        position: (f32, f32, f32),
        target: (f32, f32, f32),
        fov: Option<f32>,
    },
    /// Orbiting the origin at a distance, optionally turning by itself.
    ///
    /// The default for anything being *looked at* rather than played: a turntable shows a
    /// silhouette and a normal-perturbing shader from every angle without anyone dragging.
    Orbit {
        distance: Scalar,
        /// Radians above the horizon.
        pitch: f32,
        /// Radians per second. `None` holds still.
        auto_spin: Option<f32>,
        fov: Option<f32>,
    },
}

#[derive(Debug, Clone, Deserialize)]
pub enum SceneLight {
    Directional {
        direction: (f32, f32, f32),
        color: (f32, f32, f32),
        illuminance: f32,
    },
    Point {
        position: (f32, f32, f32),
        color: (f32, f32, f32),
        intensity: f32,
        range: f32,
    },
}

/// The geometry of one entity.
#[derive(Debug, Clone, Deserialize)]
pub enum MeshSpec {
    /// One of the shapes the runtime can build itself.
    Primitive(Primitive),
    /// Vertex arrays, as something else produced them — a `mesh-source` extension, a
    /// generator in the caller's own engine. The runtime does not care which.
    Raw {
        positions: Vec<f32>,
        #[serde(default)]
        normals: Vec<f32>,
        #[serde(default)]
        uvs: Vec<f32>,
        /// The SECOND UV channel, two floats per vertex.
        ///
        /// Not decoration and not a duplicate of `uvs`. A game bakes per-vertex facts into it
        /// that the shader cannot derive — Fulcrum's water carries the depth of the pool in
        /// `uv_b.x`, because the surface is one mesh and the bottom is another and no fragment
        /// can see both. A preview whose mesh has no `UV_1` takes the shader's `#else` branch
        /// and shows the material as it was before that channel existed, which looks correct
        /// and is a different material.
        ///
        /// Supplied here when a generator knows the real values; otherwise the runtime fills
        /// one in, so `VERTEX_UVS_B` is defined either way.
        #[serde(default)]
        uvs_b: Vec<f32>,
        /// Tangents, four floats per vertex (`xyz` plus the handedness sign).
        ///
        /// Usually left out: the runtime generates them from the UVs, which is what a mesh
        /// pipeline does anyway. Present so a caller that already has the real ones — with the
        /// real handedness — does not have to hope the regeneration agrees.
        #[serde(default)]
        tangents: Vec<f32>,
        #[serde(default)]
        indices: Vec<u32>,
    },
}

#[derive(Debug, Clone, Copy, Deserialize)]
pub enum Primitive {
    Sphere,
    Cube,
    Plane,
    Torus,
    Capsule,
    Cylinder,
}

/// What an entity is painted with.
#[derive(Debug, Clone, Deserialize)]
pub enum MaterialSpec {
    /// Bevy's `StandardMaterial`, unextended.
    Standard {
        base_color: (f32, f32, f32, f32),
        perceptual_roughness: f32,
        metallic: f32,
    },
    /// A `StandardMaterial` extended by the caller's own WGSL — the shader-preview case.
    ///
    /// The source is compiled by Bevy itself, so its `#import bevy_pbr::…` resolve against the
    /// real shader library and `apply_pbr_lighting` is the real one. That is the whole reason
    /// this runtime is a Bevy app rather than a translator.
    Shader {
        /// WGSL source. Usually `Param("shader")`.
        source: Slot<String>,
        /// The slots at bindings 100.. that a Bevy material extension conventionally declares.
        /// Position in the list is the offset from 100.
        ///
        /// A flat float list per slot rather than a `vec4`, because a slot is not always one:
        /// a shader is free to bind `array<vec4<f32>, 32>` there, and a caller that can only
        /// say four numbers cannot fill it. Fewer floats than the slot holds is normal — the
        /// rest stay zero, which is what an unfilled parameter should be.
        #[serde(default)]
        params: Vec<Slot<Vec<f32>>>,
        /// What to put in each texture slot, one name per slot, in slot order.
        ///
        /// Names and not files. A previewer opened on a shader has no assets — the atlas the
        /// game feeds it lives in a project this runtime cannot reach — so the slots are filled
        /// with images it can generate: `white`, `black`, `grey`, `normal`, `checker`, `noise`,
        /// `uv`. Which one is a better default than flat white follows from what the texture is
        /// for, and the caller knows that from the variable's name.
        ///
        /// Fewer names than slots is normal: the rest fall back to the neutral image, which is
        /// what an unfilled texture should be.
        #[serde(default = "no_textures")]
        textures: Slot<Vec<String>>,
        #[serde(default = "white")]
        base_color: (f32, f32, f32, f32),
        #[serde(default = "half")]
        perceptual_roughness: f32,
        #[serde(default)]
        metallic: f32,
        /// How the fragment's alpha is treated — `opaque`, `blend`, `premultiplied`, `add`,
        /// `multiply`.
        ///
        /// Opaque by default, because a material EXTENDING `StandardMaterial` inherits its
        /// blend mode from the material and Bevy's default is opaque. A shader that computes
        /// its own alpha — water, an overlay — says so, and the difference between that and
        /// opaque is most of what it looks like.
        #[serde(default = "opaque")]
        alpha: String,
        /// Light both faces, and draw the ones facing away.
        ///
        /// On by default. Almost everything this previews is looked at on a flat quad or a
        /// primitive that gets turned around by a turntable, and a back face that vanishes
        /// reads as the shader failing rather than as a winding order.
        #[serde(default = "yes")]
        double_sided: bool,
    },
    /// A material whose parameter block the SHADER declares, uploaded as bytes.
    ///
    /// The other variant fits a shader written to Bevy's own convention — an extension of
    /// `StandardMaterial` with `vec4`s at bindings 100 and up. A material that declares its
    /// own struct at binding 0 and returns colour directly from `fragment` is not that: it
    /// owns the whole bind group, and there is no PBR underneath it.
    ///
    /// The layout is not described here on purpose. `data` is the block already packed, at the
    /// offsets its own struct implies — read by whoever knows the shader, which in Arbor is
    /// Bennu (`arbor.shader.uniform`). This runtime uploads bytes and never learns a name.
    Raw {
        /// WGSL source. Usually `Param("shader")`.
        source: Slot<String>,
        /// The parameter block, as 32-bit floats in buffer order — padding included.
        ///
        /// Required rather than defaulted: a raw material with no values is a shader reading
        /// an uninitialised buffer, and the scene is the place to notice that.
        data: Slot<Vec<f32>>,
        /// What to put in each texture slot — see the same field on `Shader`.
        #[serde(default = "no_textures")]
        textures: Slot<Vec<String>>,
        /// Blend by default, not opaque: a shader that computes its own alpha almost always
        /// means it, and a translucent overlay rendered opaque looks like a bug in the
        /// shader rather than a setting in the viewer.
        #[serde(default = "blend")]
        alpha: String,
        #[serde(default = "yes")]
        double_sided: bool,
        /// The shader brings its **own vertex stage** — a `@vertex fn vertex(…)` beside the
        /// fragment one.
        ///
        /// A flag rather than something the runtime sniffs out of the source, because
        /// `Material::vertex_shader` is a static method: a material type either always
        /// overrides the vertex stage or never does, so this picks between two of them. Whoever
        /// reads the shader decides — in Arbor that is Bennu, which already reads it for
        /// everything else.
        #[serde(default)]
        vertex: bool,
    },
}

fn blend() -> String {
    "blend".to_string()
}

fn opaque() -> String {
    "opaque".to_string()
}

/// An empty texture list, for a document written before there were any.
///
/// A concrete `Slot` and **not** `Option<Slot<…>>`. RON does not do implicit-some: an
/// `Option` field wants `Some(Param("textures"))` written out, and a document that says
/// `textures: Param("textures")` is refused — *"Expected option"* — which takes the whole
/// scene with it, textures or no textures. A defaulted value is the shape that reads the way
/// every other field in this document reads.
fn no_textures() -> Slot<Vec<String>> {
    Slot::Value(Vec::new())
}

fn yes() -> bool {
    true
}

fn white() -> (f32, f32, f32, f32) {
    (1.0, 1.0, 1.0, 1.0)
}
fn half() -> f32 {
    0.5
}

#[derive(Debug, Clone, Deserialize)]
pub struct SceneEntity {
    pub mesh: Slot<MeshSpec>,
    pub material: MaterialSpec,
    #[serde(default)]
    pub position: (f32, f32, f32),
    #[serde(default = "one")]
    pub scale: f32,
    /// Radians per second about Y. Turning the model rather than the camera keeps a fixed
    /// light, which is what shows a normal map moving.
    #[serde(default)]
    pub spin: f32,
}

fn one() -> f32 {
    1.0
}

#[derive(Debug, Clone, Deserialize)]
pub struct Environment {
    #[serde(default)]
    pub background: (f32, f32, f32),
    #[serde(default = "half")]
    pub ambient: f32,
    /// Draw a chequerboard behind everything instead of a flat fill.
    ///
    /// It is not decoration. A material that computes its own alpha — which is most of what
    /// this viewer is pointed at — looks identical over any single colour: you cannot tell
    /// 60% opacity from 100% until there is something behind it with structure. The squares
    /// are that something, and they double as the reference every image editor uses for the
    /// same reason.
    ///
    /// Off by default so a scene written before this renders as it did.
    #[serde(default)]
    pub checker: bool,
}

impl Default for Environment {
    fn default() -> Self {
        Self { background: (0.06, 0.07, 0.09), ambient: 0.18, checker: false }
    }
}

/// One control the caller may offer, so a panel can draw it without knowing the scene.
#[derive(Debug, Clone, Deserialize)]
pub struct Control {
    /// The param this writes to.
    pub param: String,
    pub label: String,
    #[serde(default)]
    pub description: String,
    pub kind: ControlKind,
}

#[derive(Debug, Clone, Deserialize)]
pub enum ControlKind {
    Slider { min: f32, max: f32, default: f32 },
    Vec4 { default: (f32, f32, f32, f32) },
    Color { default: (f32, f32, f32, f32) },
    Choice { options: Vec<String>, default: String },
    Toggle { default: bool },
}

/// A scene document.
#[derive(Debug, Clone, Deserialize)]
pub struct SceneDoc {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub description: String,
    pub camera: CameraRig,
    #[serde(default)]
    pub environment: Environment,
    #[serde(default)]
    pub lights: Vec<SceneLight>,
    pub entities: Vec<SceneEntity>,
    /// What the caller may set, and how it should be presented.
    #[serde(default)]
    pub controls: Vec<Control>,
}

impl SceneDoc {
    pub fn parse(text: &str) -> Result<Self, String> {
        ron::from_str::<SceneDoc>(text).map_err(|e| format!("scene is not valid RON: {e}"))
    }
}

/// Resolve a slot against the params the caller supplied.
pub fn resolve<'a, T>(slot: &'a Slot<T>, params: &'a serde_json::Value) -> Result<T, String>
where
    T: Clone + serde::de::DeserializeOwned,
{
    match slot {
        Slot::Value(v) => Ok(v.clone()),
        Slot::Param(name) => {
            let raw = params
                .get(name)
                // Named, because the person reading this wrote the scene and has to know
                // which hole is empty.
                .ok_or_else(|| format!("this scene needs a `{name}` param and none was given"))?;
            serde_json::from_value(raw.clone())
                .map_err(|e| format!("param `{name}` does not fit what the scene expects: {e}"))
        }
    }
}

#[cfg(test)]
mod tests {

    #[test]
    fn a_material_can_own_its_whole_bind_group() {
        // The shape a shader that declares its own struct at binding 0 needs: no base colour,
        // no roughness, no PBR underneath — just the source and the block, as bytes.
        let doc = SceneDoc::parse(
            r#"(
                id: "raw",
                name: "Raw",
                camera: Orbit(distance: Single(2.0), pitch: 0.3, auto_spin: None, fov: None),
                environment: (background: (0.0, 0.0, 0.0), ambient: 0.1),
                lights: [],
                entities: [
                    (
                        mesh: Param("mesh"),
                        material: Raw(
                            source: Param("shader"),
                            data: Param("data"),
                            alpha: "blend",
                        ),
                        position: (0.0, 0.0, 0.0),
                        scale: 1.0,
                        spin: 0.0,
                    ),
                ],
                controls: [],
            )"#,
        )
        .expect("a raw material parses");

        let MaterialSpec::Raw { data, alpha, .. } = &doc.entities[0].material else {
            panic!("expected the raw variant");
        };
        assert_eq!(alpha, "blend");
        let params = serde_json::json!({ "data": [1.0, 2.0, 3.0, 4.0] });
        let values: Vec<f32> = resolve(data, &params).expect("the block resolves");
        assert_eq!(values, vec![1.0, 2.0, 3.0, 4.0]);
    }

    #[test]
    fn a_texture_list_is_a_plain_slot_and_not_an_option() {
        // The regression this pins: written as `Option<Slot<…>>`, RON refuses
        // `textures: Param("textures")` with *"Expected option"* — it does not do
        // implicit-some — and the refusal takes the WHOLE document with it. Every scene stops
        // parsing, including the ones with no textures at all, which is how a change about
        // textures broke a shader that has none.
        let doc = SceneDoc::parse(
            r#"(
                id: "raw", name: "Raw",
                camera: Orbit(distance: Single(2.0), pitch: 0.3, auto_spin: None, fov: None),
                environment: (background: (0.0, 0.0, 0.0), ambient: 0.1),
                lights: [],
                entities: [ ( mesh: Param("mesh"),
                    material: Raw(
                        source: Param("shader"),
                        data: Param("data"),
                        textures: Param("textures"),
                    ),
                    position: (0.0, 0.0, 0.0), scale: 1.0, spin: 0.0 ) ],
                controls: [],
            )"#,
        )
        .expect("a document naming its texture slots parses");

        let MaterialSpec::Raw { textures, .. } = &doc.entities[0].material else {
            panic!("expected the raw variant");
        };
        let params = serde_json::json!({ "textures": ["normal", "checker"] });
        let names: Vec<String> = resolve(textures, &params).expect("the list resolves");
        assert_eq!(names, vec!["normal".to_string(), "checker".to_string()]);
    }

    #[test]
    fn a_document_written_before_textures_still_parses() {
        let doc = SceneDoc::parse(
            r#"(
                id: "raw", name: "Raw",
                camera: Orbit(distance: Single(2.0), pitch: 0.3, auto_spin: None, fov: None),
                environment: (background: (0.0, 0.0, 0.0), ambient: 0.1),
                lights: [],
                entities: [ ( mesh: Param("mesh"),
                    material: Raw(source: Param("shader"), data: Param("data")),
                    position: (0.0, 0.0, 0.0), scale: 1.0, spin: 0.0 ) ],
                controls: [],
            )"#,
        )
        .expect("the shape that shipped before still parses");
        let MaterialSpec::Raw { textures, .. } = &doc.entities[0].material else {
            panic!("expected the raw variant");
        };
        let names: Vec<String> = resolve(textures, &serde_json::json!({})).expect("defaults");
        assert!(names.is_empty());
    }

    #[test]
    fn a_raw_material_defaults_to_blending() {
        // A shader that computes its own alpha almost always means it, and a translucent
        // overlay rendered opaque reads as a bug in the shader rather than a viewer setting.
        let doc = SceneDoc::parse(
            r#"(
                id: "raw", name: "Raw",
                camera: Orbit(distance: Single(2.0), pitch: 0.3, auto_spin: None, fov: None),
                environment: (background: (0.0, 0.0, 0.0), ambient: 0.1),
                lights: [],
                entities: [ ( mesh: Param("mesh"),
                    material: Raw(source: Param("shader"), data: Param("data")),
                    position: (0.0, 0.0, 0.0), scale: 1.0, spin: 0.0 ) ],
                controls: [],
            )"#,
        )
        .expect("alpha is optional");
        let MaterialSpec::Raw { alpha, .. } = &doc.entities[0].material else { panic!() };
        assert_eq!(alpha, "blend");
    }
    use super::*;

    const SHADER_PREVIEW: &str = r#"
(
    id: "shader_preview",
    name: "Shader preview",
    camera: Orbit(
        distance: Single(2.6),
        pitch: 0.28,
        auto_spin: Some(0.4),
        fov: None,
    ),
    environment: (
        background: (0.06, 0.07, 0.09),
        ambient: 0.18,
    ),
    lights: [
        Directional(
            direction: (-0.4, -0.75, -0.5),
            color: (1.0, 0.97, 0.92),
            illuminance: 9000.0,
        ),
    ],
    entities: [
        (
            mesh: Param("mesh"),
            material: Shader(
                source: Param("shader"),
                params: [ Param("p0") ],
            ),
            spin: 0.0,
        ),
    ],
    controls: [
        (
            param: "p0",
            label: "Material parameters",
            description: "The vec4 at binding 100.",
            kind: Vec4(default: (1.0, 0.5, 0.2, 0.1)),
        ),
    ],
)
"#;

    #[test]
    fn the_shader_preview_scene_parses() {
        let doc = SceneDoc::parse(SHADER_PREVIEW).expect("should parse");
        assert_eq!(doc.id, "shader_preview");
        assert_eq!(doc.entities.len(), 1);
        assert_eq!(doc.controls.len(), 1);
        assert!(matches!(doc.camera, CameraRig::Orbit { .. }));
    }

    #[test]
    fn a_hole_the_caller_did_not_fill_is_named() {
        // The message goes to whoever wrote the scene or the call, and "missing param" without
        // the name sends them reading both.
        let doc = SceneDoc::parse(SHADER_PREVIEW).unwrap();
        let params = serde_json::json!({ "shader": "…" });
        let err = resolve(&doc.entities[0].mesh, &params).unwrap_err();
        assert!(err.contains("`mesh`"), "{err}");
    }

    #[test]
    fn a_param_of_the_wrong_shape_says_so_rather_than_defaulting() {
        let doc = SceneDoc::parse(SHADER_PREVIEW).unwrap();
        let params = serde_json::json!({ "mesh": 42 });
        let err = resolve(&doc.entities[0].mesh, &params).unwrap_err();
        assert!(err.contains("does not fit"), "{err}");
    }

    #[test]
    fn a_value_written_in_the_document_needs_no_param() {
        let doc = SceneDoc::parse(
            r#"(
                id: "x", name: "X",
                camera: Static(position: (0.0,0.0,3.0), target: (0.0,0.0,0.0), fov: None),
                entities: [(
                    mesh: Value(Primitive(Sphere)),
                    material: Standard(base_color: (1.0,1.0,1.0,1.0), perceptual_roughness: 0.5, metallic: 0.0),
                )],
            )"#,
        )
        .expect("should parse");
        let mesh = resolve(&doc.entities[0].mesh, &serde_json::json!({})).expect("no param needed");
        assert!(matches!(mesh, MeshSpec::Primitive(Primitive::Sphere)));
    }

    #[test]
    fn a_range_resolves_to_its_middle_and_not_to_a_sample() {
        // A camera distance that jittered every frame would be unusable; the range form exists
        // so one document can also feed a spawner.
        assert_eq!(Scalar::Single(2.0).value(), 2.0);
        assert_eq!(Scalar::Uniform(1.0, 3.0).value(), 2.0);
    }

    #[test]
    fn every_scene_this_package_ships_parses() {
        // The one that matters: a scene that ships and does not parse fails at the moment
        // somebody opens a panel, with a RON error where a picture should be.
        for (name, text) in [(
            "shader_preview.ron",
            include_str!("../../scenes/shader_preview.ron"),
        )] {
            let doc = SceneDoc::parse(text).unwrap_or_else(|e| panic!("{name}: {e}"));
            assert!(!doc.entities.is_empty(), "{name} draws nothing");
            // Every hole the scene declares has to be offered as a control, or the caller has
            // no way to know it needs filling.
            for e in &doc.entities {
                if let MaterialSpec::Shader { params, .. } = &e.material {
                    for slot in params {
                        if let Slot::Param(p) = slot {
                            assert!(
                                doc.controls.iter().any(|c| &c.param == p),
                                "{name}: `{p}` is a hole with no control"
                            );
                        }
                    }
                }
            }
        }
    }

    #[test]
    fn a_malformed_document_fails_with_ron_s_own_message() {
        let err = SceneDoc::parse("(id: \"x\"").unwrap_err();
        assert!(err.contains("not valid RON"), "{err}");
    }
}
