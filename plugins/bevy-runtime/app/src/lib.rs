//! One Bevy app, driven by RON scenes, for any Arbor plugin that needs a viewport.
//!
//! ## Why one and not one per plugin
//!
//! A Bevy web bundle is tens of megabytes and takes minutes to build, and the hard part —
//! wasm-bindgen glue, canvas setup, resize and device pixel ratio, context loss, a render loop
//! — is identical whatever is being shown. One runtime, loaded once and cached, serves every
//! plugin that wants to draw something.
//!
//! ## Why it is still extensible
//!
//! Because a **scene is a document**, not a function. Nothing here knows what a shader preview
//! is; it knows how to read a [`scene::SceneDoc`] and build what it describes. Adding a kind of
//! viewport is adding a `.ron`, which is the same rule the rest of Arbor's extension surface
//! follows: if the runtime has to learn something, it is not extensible.
//!
//! A scene declares its holes as `Param("name")`, and whoever opens it fills them. That is what
//! lets `shader_preview.ron` be opened by a plugin that supplies WGSL and a mesh, without the
//! scene or the runtime knowing where either came from.
//!
//! ## The bridge
//!
//! The page talks to this over `postMessage`, in JSON:
//!
//! | in | |
//! |---|---|
//! | `{ "type": "open", "scene": "<ron>", "params": {…} }` | build a scene |
//! | `{ "type": "update", "params": {…} }` | change params without rebuilding |
//! | `{ "type": "camera", "yaw": f, "pitch": f, "zoom": f }` | move the camera, relative |
//! | `{ "type": "camera", "reset": true }` | back to the scene's own framing |
//! | `{ "type": "camera", "spin": true }` | let the turntable resume, keeping the angle |
//! | `{ "type": "camera", "absolute_distance": f }` | set the distance, for a slider |
//! | `{ "type": "time", "paused": b, "set": f, "step": f }` | pin, scrub or nudge the clock |
//!
//! | out | |
//! |---|---|
//! | `{ "type": "ready" }` | the canvas is live |
//! | `{ "type": "opened", "controls": […] }` | what the scene offers |
//! | `{ "type": "error", "message": "…" }` | it did not build |
//!
//! Commands land in a queue rather than being applied on the JS thread: Bevy owns the world,
//! and mutating it from outside a system is how a frame ends up half-built.

pub mod scene;
pub mod textures;

use std::collections::HashMap;
use std::sync::Mutex;

use bevy::asset::{RenderAssetUsages, uuid_handle};
use bevy::pbr::{ExtendedMaterial, MaterialExtension};
use bevy::prelude::*;
use bevy::mesh::{Indices, PrimitiveTopology};
use bevy::render::render_resource::{AsBindGroup, ShaderType};
use bevy::shader::ShaderRef;

use bevy::mesh::VertexAttributeValues;
use bevy::render::render_resource::RenderPipelineDescriptor;

use scene::{
    CameraRig, MaterialSpec, MeshSpec, Primitive, SceneDoc, SceneLight,
};
use textures::Role;

/// The handle the preview material's fragment shader always lives at.
///
/// Fixed, because `MaterialExtension::fragment_shader` is a static method — it cannot look at
/// an instance to find out which shader this one wants. So the shader is swapped *at* the
/// handle instead: writing a new `Shader` here respecialises the pipeline, which is exactly
/// what "the user edited the file" should do.
const PREVIEW_SHADER: Handle<Shader> = uuid_handle!("6a1f0b4e-6a5c-4d2f-9a3e-1b7c5d8e2f40");

/// How many `vec4`s each extension slot holds — 512 bytes.
///
/// Not one. A uniform buffer **larger** than the type a shader reads it as is legal; one
/// smaller is not — wgpu checks the declaration against `min_binding_size` and refuses the
/// pipeline, which in a wasm viewport is a panic and a dead canvas rather than a message. A
/// material binding `array<vec4<f32>, 32>` at 102 — a list of light sources, an ordinary thing
/// to want — needs 512 bytes there, and a slot holding a single `vec4` gave it sixteen.
///
/// So every slot is sized for the largest such binding and a shader reads however much of it
/// it declared. The cost is 4 KB of uniform per material, which is nothing, and it is the same
/// argument [`RAW_SLOTS`] already makes for a material that owns its bind group.
pub const EXT_SLOT_VECS: usize = 32;

/// The same slot measured in floats, which is the unit a caller packs values in.
pub const EXT_SLOT_FLOATS: usize = EXT_SLOT_VECS * 4;

/// One extension slot: a fixed block a shader reads as whatever it declared.
///
/// `Reflect` because `PreviewExt` derives it, and a derive is only as reflectable as its
/// fields.
#[derive(ShaderType, Reflect, Clone, Debug)]
pub struct ExtSlot {
    data: [Vec4; EXT_SLOT_VECS],
}

impl Default for ExtSlot {
    fn default() -> Self {
        Self { data: [Vec4::ZERO; EXT_SLOT_VECS] }
    }
}

impl ExtSlot {
    /// Fill from a flat float list, ignoring anything past the end.
    pub fn from_floats(values: &[f32]) -> Self {
        let mut out = Self::default();
        for (i, chunk) in values.chunks(4).take(EXT_SLOT_VECS).enumerate() {
            let mut v = Vec4::ZERO;
            for (k, f) in chunk.iter().enumerate() {
                v[k] = *f;
            }
            out.data[i] = v;
        }
        out
    }
}

// ── The texture half of the layout ──────────────────────────────────────────────
//
// A shader is RENUMBERED onto these before it is compiled — see `preview_layout` in Arbor's
// `bennu-wgsl`, which owns the same numbers and does the rewriting. That is what makes one
// fixed layout serve every material: widening a layout answers "the binding is missing" and
// "the binding is too small", and cannot answer "the binding is the wrong kind", because
// binding 101 is a buffer in one material and a sampler in the next.
//
// The counts are set by what the TARGET allows, not by what looks generous:
//
// · **Samplers: three.** Metal allows 16 per fragment stage across every bind group and
//   `StandardMaterial` already spends six. It is the reason `tile.wgsl` shares one sampler
//   between ten textures rather than declaring ten, and the reason this does not offer twelve.
// · **Textures: twelve natively, four in the browser.** On WebGL2 a fragment stage gets 16
//   texture units in TOTAL, across every bind group, and Bevy has spent most of them before a
//   material is reached — the view's environment map, its shadow maps, `StandardMaterial`'s own
//   six. Declaring twelve there does not give the browser more units; it makes
//   `create_pipeline_layout` refuse for EVERY shader, including ones with no textures at all.
//   So the extra slots are behind `native-render`, the feature only the headless binary
//   enables, and `PreviewCaps` on the other side renumbers for whichever previewer is meant.
//
// Change a number here and `preview_layout`'s constants move with it, or every shader is
// renumbered onto slots that are not there.

/// Textures of each kind, and the samplers beside them.
pub const TEX_2D_SLOTS: usize = 12;
pub const SAMPLER_SLOTS: usize = 3;
pub const TEX_2D_ARRAY_SLOTS: usize = 2;
pub const TEX_CUBE_SLOTS: usize = 2;

/// What goes in the texture slots, resolved from a scene's role names.
///
/// One list, ordered the way `preview_layout` hands out slots: the 2D textures, then the array
/// textures, then the cubes. A material picks its own out of it by index rather than the scene
/// carrying three lists that could disagree about which is which.
#[derive(Clone, Default)]
pub struct TextureSet {
    pub tex_2d: Vec<Handle<Image>>,
    pub tex_2d_array: Vec<Handle<Image>>,
    pub tex_cube: Vec<Handle<Image>>,
}

impl TextureSet {
    fn at(v: &[Handle<Image>], i: usize) -> Option<Handle<Image>> {
        v.get(i).cloned()
    }
}

/// Generated images, kept so a slider does not rebuild a chequerboard sixty times a second.
///
/// Keyed by role and layer count, because those are the only two things an image here depends
/// on. A rebuild happens on every parameter change — that is what makes the preview live — and
/// uploading the same 16 KB pattern each time is the kind of cost that only shows up as the
/// panel feeling heavy.
#[derive(Resource, Default)]
pub struct RoleImages(HashMap<(Role, u32), Handle<Image>>);

impl RoleImages {
    fn get(&mut self, images: &mut Assets<Image>, role: Role, layers: u32) -> Handle<Image> {
        if let Some(h) = self.0.get(&(role, layers)) {
            return h.clone();
        }
        let handle = images.add(textures::image_for(role, layers));
        self.0.insert((role, layers), handle.clone());
        handle
    }
}

/// Resolve a scene's role names into handles, one per slot.
///
/// Short lists are normal and so are unknown names: a slot nobody named gets the neutral
/// image, which is what an unfilled texture should be, and a misspelt role gets the same
/// rather than refusing to open the scene.
fn texture_set(
    names: &[String],
    images: &mut Assets<Image>,
    roles: &mut RoleImages,
) -> TextureSet {
    // The slot list is walked with an index rather than an iterator so the three families read
    // out of one flat list in the order `preview_layout` assigns them.
    let mut out = TextureSet::default();
    let mut i = 0usize;
    let role_at = |i: usize| names.get(i).map(|n| Role::named(n)).unwrap_or(Role::Neutral);
    for _ in 0..TEX_2D_SLOTS {
        out.tex_2d.push(roles.get(images, role_at(i), 1));
        i += 1;
    }
    for _ in 0..TEX_2D_ARRAY_SLOTS {
        out.tex_2d_array.push(roles.get(images, role_at(i), 2));
        i += 1;
    }
    for _ in 0..TEX_CUBE_SLOTS {
        out.tex_cube.push(roles.get(images, role_at(i), 6));
        i += 1;
    }
    out
}

/// How many slots a material extension gets, at bindings 100 and up.
///
/// **Eight, not four.** A shader that declares a binding this material does not have is not a
/// shader that renders without it — the pipeline layout has no entry for it and wgpu refuses
/// the whole pipeline: *"Shader global ResourceBinding { group: 3, binding: 104 } is not
/// available in the pipeline layout"*, which is a validation panic and a black viewport, not a
/// missing parameter. Four covered the materials this was first pointed at and a five-uniform
/// one arrived immediately.
///
/// A slot the shader does not declare costs its 512 bytes and nothing else, so the number is
/// set by what a material plausibly asks for rather than by what the first one needed.
pub const EXT_SLOTS: usize = 8;

/// A `StandardMaterial` extended by somebody else's WGSL.
///
/// `vec4`s at bindings 100 and up, which is the convention a Bevy material extension already
/// uses — `rock_params`, `mole_params`/`mole_fur`, `water_params`/`glow_meta` all sit there.
/// A shader that declares fewer simply ignores the rest; one that declares MORE than
/// [`EXT_SLOTS`] cannot be previewed, and says so rather than failing pipeline validation.
///
/// Written out rather than as an array because `AsBindGroup` needs one attribute per binding
/// index, and an array would be a single binding holding eight vectors — a different layout
/// that no such shader declares.
#[derive(Asset, AsBindGroup, Reflect, Debug, Clone, Default)]
pub struct PreviewExt {
    #[uniform(100)]
    pub p0: ExtSlot,
    #[uniform(101)]
    pub p1: ExtSlot,
    #[uniform(102)]
    pub p2: ExtSlot,
    #[uniform(103)]
    pub p3: ExtSlot,
    #[uniform(104)]
    pub p4: ExtSlot,
    #[uniform(105)]
    pub p5: ExtSlot,
    #[uniform(106)]
    pub p6: ExtSlot,
    #[uniform(107)]
    pub p7: ExtSlot,
    /// The textures, at 108 and up, with the samplers at 120.
    ///
    /// **Two of them in the browser**, and the arithmetic is not a preference. wgpu's GL
    /// backend assigns a texture unit to every layout entry across every bind group, used or
    /// not, and WebGL2 has sixteen: the view and mesh groups spend seven, `StandardMaterial`
    /// underneath spends six, which leaves three. Two, so a Bevy release that adds one to the
    /// view group does not take the viewport with it.
    ///
    /// A shader that samples none still pays for these — the layout is static — which is why
    /// the number matters even to a material that has no textures at all.
    ///
    /// `Option` on purpose: `None` binds the engine's own fallback image, so a material is
    /// never left with an unbound entry — and the scene fills them with something better than
    /// white anyway (see [`textures`]).
    #[texture(108)]
    #[sampler(120)]
    pub t0: Option<Handle<Image>>,
    #[texture(109)]
    #[sampler(121)]
    pub t1: Option<Handle<Image>>,
    #[cfg(feature = "native-render")]
    #[texture(110)]
    #[sampler(122)]
    pub t2: Option<Handle<Image>>,
    #[cfg(feature = "native-render")]
    #[texture(111)]
    pub t3: Option<Handle<Image>>,
    #[cfg(feature = "native-render")]
    #[texture(112)]
    pub t4: Option<Handle<Image>>,
    #[cfg(feature = "native-render")]
    #[texture(113)]
    pub t5: Option<Handle<Image>>,
    #[cfg(feature = "native-render")]
    #[texture(114)]
    pub t6: Option<Handle<Image>>,
    #[cfg(feature = "native-render")]
    #[texture(115)]
    pub t7: Option<Handle<Image>>,
    #[cfg(feature = "native-render")]
    #[texture(116)]
    pub t8: Option<Handle<Image>>,
    #[cfg(feature = "native-render")]
    #[texture(117)]
    pub t9: Option<Handle<Image>>,
    #[cfg(feature = "native-render")]
    #[texture(118)]
    pub t10: Option<Handle<Image>>,
    #[cfg(feature = "native-render")]
    #[texture(119)]
    pub t11: Option<Handle<Image>>,
    /// Array textures. Two, because a material wanting one at all is rare and a material
    /// wanting three has not turned up.
    ///
    /// **No sampler of their own.** A sampler is not tied to a texture — any of the three
    /// declared above reads any of these — and on Metal a sampler is the scarcest thing in the
    /// group: sixteen per fragment stage, of which `StandardMaterial` spends six before this
    /// material is reached. Eleven here plus the engine's own put
    /// `create_pipeline_layout` over the line, and it reports that as `Out of Memory`, which
    /// sends you looking for an allocation that was never the problem.
    #[cfg(feature = "native-render")]
    #[texture(123, dimension = "2d_array")]
    pub a0: Option<Handle<Image>>,
    #[cfg(feature = "native-render")]
    #[texture(124, dimension = "2d_array")]
    pub a1: Option<Handle<Image>>,
    /// Cube maps — an environment probe, usually.
    #[cfg(feature = "native-render")]
    #[texture(126, dimension = "cube")]
    pub c0: Option<Handle<Image>>,
    #[cfg(feature = "native-render")]
    #[texture(127, dimension = "cube")]
    pub c1: Option<Handle<Image>>,
}

impl PreviewExt {
    /// Write one slot by index. Out-of-range is ignored rather than refused: the caller has
    /// already been told how many there are, and a scene is not worth failing over a slot.
    pub fn set_slot(&mut self, i: usize, v: ExtSlot) {
        match i {
            0 => self.p0 = v,
            1 => self.p1 = v,
            2 => self.p2 = v,
            3 => self.p3 = v,
            4 => self.p4 = v,
            5 => self.p5 = v,
            6 => self.p6 = v,
            7 => self.p7 = v,
            _ => {}
        }
    }

    /// Fill every texture slot from a resolved set.
    ///
    /// Every slot, not the ones a shader uses: a layout entry with nothing bound is not an
    /// empty texture, it is a bind group wgpu will not create. `None` would fall back to the
    /// engine's own fallback image, which is white — the very default this scheme exists to
    /// improve on.
    pub fn set_textures(&mut self, set: &TextureSet) {
        self.t0 = TextureSet::at(&set.tex_2d, 0);
        self.t1 = TextureSet::at(&set.tex_2d, 1);
        #[cfg(feature = "native-render")]
        {
            self.t2 = TextureSet::at(&set.tex_2d, 2);
            self.t3 = TextureSet::at(&set.tex_2d, 3);
            self.t4 = TextureSet::at(&set.tex_2d, 4);
            self.t5 = TextureSet::at(&set.tex_2d, 5);
            self.t6 = TextureSet::at(&set.tex_2d, 6);
            self.t7 = TextureSet::at(&set.tex_2d, 7);
            self.t8 = TextureSet::at(&set.tex_2d, 8);
            self.t9 = TextureSet::at(&set.tex_2d, 9);
            self.t10 = TextureSet::at(&set.tex_2d, 10);
            self.t11 = TextureSet::at(&set.tex_2d, 11);
            self.a0 = TextureSet::at(&set.tex_2d_array, 0);
            self.a1 = TextureSet::at(&set.tex_2d_array, 1);
            self.c0 = TextureSet::at(&set.tex_cube, 0);
            self.c1 = TextureSet::at(&set.tex_cube, 1);
        }
    }
}

impl MaterialExtension for PreviewExt {
    fn fragment_shader() -> ShaderRef {
        ShaderRef::Handle(PREVIEW_SHADER)
    }
}

pub type PreviewMaterial = ExtendedMaterial<StandardMaterial, PreviewExt>;

/// The shader handle a raw material reads, replaced in place when a new source arrives.
const RAW_SHADER: Handle<Shader> = uuid_handle!("6a1f0b4e-6a5c-4d2f-9a3e-1b7c5d8e2f41");

/// How many `vec4` slots a raw parameter block gets — 512 bytes.
///
/// Fixed, because `AsBindGroup` decides the layout at compile time and the shader's struct is
/// only known at run time. A uniform buffer LARGER than the struct that reads it is legal, so
/// one generous block serves every material: the shader reads its first N bytes and the rest
/// is never looked at. Sized to match [`EXT_SLOT_VECS`] so the two paths cannot disagree about
/// how much a slot holds — and 512 bytes is well inside every platform's minimum guarantee for
/// a uniform binding.
const RAW_SLOTS: usize = EXT_SLOT_VECS;

/// A parameter block whose shape the shader owns.
#[derive(ShaderType, Clone, Debug)]
pub struct RawParams {
    data: [Vec4; RAW_SLOTS],
}

impl Default for RawParams {
    fn default() -> Self {
        Self { data: [Vec4::ZERO; RAW_SLOTS] }
    }
}

/// A material that is entirely the caller's shader.
///
/// Not an extension of `StandardMaterial`: a shader that declares its own struct at binding 0
/// and returns colour and alpha from `fragment` owns the whole bind group, and there is no PBR
/// underneath it to extend. Trying to preview one through the extension path collides with
/// `StandardMaterial`'s own binding 0 and never compiles.
///
/// It knows nothing about what is in the buffer. The names, types and offsets were read by
/// whoever knows the shader — in Arbor, Bennu — and arrive here already packed.
/// I due materiali "raw", generati dalla stessa definizione.
///
/// Due tipi e non uno perche' `Material::vertex_shader` e' un metodo **statico**: un materiale
/// o sostituisce sempre lo stadio vertex o non lo fa mai, e non c'e' modo di deciderlo per
/// istanza. Uno shader che porta il proprio `@vertex` e uno che si affida a quello di Bevy sono
/// quindi due pipeline diverse, e sbagliare non da' un'immagine diversa: il primo, reso senza
/// override, vede il proprio `@vertex` ignorato in silenzio; il secondo, reso con override,
/// non compila perche' la funzione non c'e'.
///
/// Una macro e non due struct scritte a mano perche' i campi sono trenta e identici — e trenta
/// attributi `#[texture(N)]` copiati sono trenta occasioni di scriverne uno diverso.
macro_rules! raw_material {
    ($name:ident, $doc:literal) => {
        #[doc = $doc]
        #[derive(Asset, AsBindGroup, TypePath, Clone, Debug, Default)]
        pub struct $name {

    #[uniform(0)]
    params: RawParams,
    /// The same texture half [`PreviewExt`] has, shifted down to base 0.
    ///
    /// Shifted rather than shared, because a material that owns its bind group starts at 0 and
    /// an extension starts at 100 — the offsets between the families are identical, which is
    /// what lets one renumbering scheme serve both.
    #[texture(8)]
    #[sampler(20)]
    pub t0: Option<Handle<Image>>,
    #[texture(9)]
    #[sampler(21)]
    pub t1: Option<Handle<Image>>,
    #[texture(10)]
    #[sampler(22)]
    pub t2: Option<Handle<Image>>,
    #[texture(11)]
    pub t3: Option<Handle<Image>>,
    #[cfg(feature = "native-render")]
    #[texture(12)]
    pub t4: Option<Handle<Image>>,
    #[cfg(feature = "native-render")]
    #[texture(13)]
    pub t5: Option<Handle<Image>>,
    #[cfg(feature = "native-render")]
    #[texture(14)]
    pub t6: Option<Handle<Image>>,
    #[cfg(feature = "native-render")]
    #[texture(15)]
    pub t7: Option<Handle<Image>>,
    #[cfg(feature = "native-render")]
    #[texture(16)]
    pub t8: Option<Handle<Image>>,
    #[cfg(feature = "native-render")]
    #[texture(17)]
    pub t9: Option<Handle<Image>>,
    #[cfg(feature = "native-render")]
    #[texture(18)]
    pub t10: Option<Handle<Image>>,
    #[cfg(feature = "native-render")]
    #[texture(19)]
    pub t11: Option<Handle<Image>>,
    #[cfg(feature = "native-render")]
    #[texture(23, dimension = "2d_array")]
    pub a0: Option<Handle<Image>>,
    #[cfg(feature = "native-render")]
    #[texture(24, dimension = "2d_array")]
    pub a1: Option<Handle<Image>>,
    #[cfg(feature = "native-render")]
    #[texture(26, dimension = "cube")]
    pub c0: Option<Handle<Image>>,
    #[cfg(feature = "native-render")]
    #[texture(27, dimension = "cube")]
    pub c1: Option<Handle<Image>>,
    alpha: AlphaMode,

        }

        impl $name {
            /// Impacchetta i float nel blocco fisso, ignorando quelli oltre la fine.
            fn from_floats(values: &[f32], alpha: AlphaMode, set: &TextureSet) -> Self {
                let mut params = RawParams::default();
                for (i, chunk) in values.chunks(4).take(RAW_SLOTS).enumerate() {
                    let mut v = Vec4::ZERO;
                    for (k, f) in chunk.iter().enumerate() {
                        v[k] = *f;
                    }
                    params.data[i] = v;
                }
                let mut out = Self { params, alpha, ..Default::default() };
                out.set_textures(set);
                out
            }

            /// Riempie ogni slot texture — il gemello di [`PreviewExt::set_textures`], a base 0.
            fn set_textures(&mut self, set: &TextureSet) {
                self.t0 = TextureSet::at(&set.tex_2d, 0);
                self.t1 = TextureSet::at(&set.tex_2d, 1);
                self.t2 = TextureSet::at(&set.tex_2d, 2);
                self.t3 = TextureSet::at(&set.tex_2d, 3);
                #[cfg(feature = "native-render")]
                {
                    self.t4 = TextureSet::at(&set.tex_2d, 4);
                    self.t5 = TextureSet::at(&set.tex_2d, 5);
                    self.t6 = TextureSet::at(&set.tex_2d, 6);
                    self.t7 = TextureSet::at(&set.tex_2d, 7);
                    self.t8 = TextureSet::at(&set.tex_2d, 8);
                    self.t9 = TextureSet::at(&set.tex_2d, 9);
                    self.t10 = TextureSet::at(&set.tex_2d, 10);
                    self.t11 = TextureSet::at(&set.tex_2d, 11);
                    self.a0 = TextureSet::at(&set.tex_2d_array, 0);
                    self.a1 = TextureSet::at(&set.tex_2d_array, 1);
                    self.c0 = TextureSet::at(&set.tex_cube, 0);
                    self.c1 = TextureSet::at(&set.tex_cube, 1);
                }
            }
        }
    };
}

raw_material!(
    RawMaterial,
    "Un materiale che e' interamente lo shader del chiamante, con lo stadio vertex di Bevy."
);
raw_material!(
    RawVertexMaterial,
    "Come [`RawMaterial`], ma lo shader porta anche il proprio `@vertex`."
);

/// `impl Material` per entrambi, che differiscono in una riga sola.
///
/// Tre bracci e un corpo solo: i primi due scelgono soltanto CHE COSA sia lo stadio vertex, e
/// `ShaderRef::Default` e' esattamente ciò che il tratto restituisce da se' — cioe' lo stadio
/// vertex di Bevy. Il ramo "senza vertex" non e' quindi un caso speciale, e' il default scritto
/// per esteso, il che rende visibile in una riga la differenza fra i due materiali.
macro_rules! raw_material_impl {
    ($name:ident, vertex) => {
        raw_material_impl!(@body $name, ShaderRef::Handle(RAW_SHADER));
    };
    ($name:ident) => {
        raw_material_impl!(@body $name, ShaderRef::Default);
    };
    (@body $name:ident, $vs:expr) => {
        impl Material for $name {
            fn fragment_shader() -> ShaderRef {
                ShaderRef::Handle(RAW_SHADER)
            }
            fn vertex_shader() -> ShaderRef {
                $vs
            }
            fn alpha_mode(&self) -> AlphaMode {
                self.alpha
            }

            /// Disegna entrambe le facce.
            ///
            /// `specialize` e' statico, quindi non e' un'impostazione: e' quello che ottiene
            /// ogni materiale reso cosi'. Ed e' la risposta giusta qui — si guarda un quad
            /// piatto o una primitiva su una piattaforma girevole, e una faccia che sparisce
            /// quando il giro la porta di la' si legge come lo shader che fallisce, non come un
            /// ordine di avvolgimento.
            fn specialize(
                _pipeline: &bevy::pbr::MaterialPipeline,
                descriptor: &mut RenderPipelineDescriptor,
                _layout: &bevy::mesh::MeshVertexBufferLayoutRef,
                _key: bevy::pbr::MaterialPipelineKey<Self>,
            ) -> Result<(), bevy::render::render_resource::SpecializedMeshPipelineError> {
                descriptor.primitive.cull_mode = None;
                Ok(())
            }
        }
    };
}

raw_material_impl!(RawMaterial);
raw_material_impl!(RawVertexMaterial, vertex);


// ── The backdrop ────────────────────────────────────────────────────────────────

/// The chequerboard's shader, kept at a fixed handle like the others.
const CHECKER_SHADER: Handle<Shader> = uuid_handle!("2c4d8e10-77a3-4f61-8b9d-3e5a0c1f6b28");

/// How far in front of the camera the backdrop sits, and how wide it is.
///
/// Far enough to be behind anything a preview puts at the origin and inside the default far
/// plane; wide enough to cover the frustum at that distance for any aspect ratio a panel is
/// likely to have. Both are constants rather than computed from the projection because the
/// quad is a backdrop, not a fitted plane: covering too much costs nothing, and the arithmetic
/// would have to be redone every time the panel is resized.
const BACKDROP_DIST: f32 = 100.0;
const BACKDROP_SIZE: f32 = 420.0;

/// A chequerboard in SCREEN space, not on the quad's own UVs.
///
/// Screen space is what makes the squares stay square and stay put: a quad parented to the
/// camera is at a slight angle to it as the aspect changes, and UV squares would stretch with
/// it and swim while the turntable turns. Reading `@builtin(position)` means the pattern is a
/// property of the window, which is what a backdrop should be — and it also stays crisp,
/// because a pixel of it is always a pixel.
const CHECKER_WGSL: &str = r#"
#import bevy_pbr::forward_io::VertexOutput

struct CheckerParams {
    light: vec4<f32>,
    dark:  vec4<f32>,
    // x = square edge, in pixels.
    tuning: vec4<f32>,
};

@group(#{MATERIAL_BIND_GROUP}) @binding(0)
var<uniform> checker: CheckerParams;

@fragment
fn fragment(mesh: VertexOutput) -> @location(0) vec4<f32> {
    let cell = mesh.position.xy / max(checker.tuning.x, 1.0);
    let sum = floor(cell.x) + floor(cell.y);
    // `sum` mod 2, without an integer conversion that would lose precision far from origin.
    let odd = sum - 2.0 * floor(sum * 0.5);
    return mix(checker.light, checker.dark, odd);
}
"#;

#[derive(ShaderType, Clone, Debug, Default)]
pub struct CheckerParams {
    light: Vec4,
    dark: Vec4,
    tuning: Vec4,
}

/// The backdrop's material: unlit, and the only thing it knows is two colours.
#[derive(Asset, AsBindGroup, TypePath, Clone, Debug)]
pub struct CheckerMaterial {
    #[uniform(0)]
    params: CheckerParams,
}

impl Material for CheckerMaterial {
    fn fragment_shader() -> ShaderRef {
        ShaderRef::Handle(CHECKER_SHADER)
    }
}

impl CheckerMaterial {
    /// Two shades derived from the scene's own background colour.
    ///
    /// Derived rather than fixed, so the Background control keeps meaning something when the
    /// backdrop is on: it sets the ground and the squares are a step above it. Fixed editor
    /// greys would be a second, louder background that ignores the one the scene asked for.
    fn from_background(bg: (f32, f32, f32)) -> Self {
        let dark = Vec4::new(bg.0, bg.1, bg.2, 1.0);
        // A small additive step reads as a grid at any background lightness, where a
        // multiplier would vanish on a near-black one.
        const STEP: f32 = 0.05;
        let light = Vec4::new(bg.0 + STEP, bg.1 + STEP, bg.2 + STEP, 1.0);
        Self { params: CheckerParams { light, dark, tuning: Vec4::new(16.0, 0.0, 0.0, 0.0) } }
    }
}

fn alpha_mode_named(name: &str) -> AlphaMode {
    match name.trim().to_ascii_lowercase().as_str() {
        "opaque" => AlphaMode::Opaque,
        "premultiplied" => AlphaMode::Premultiplied,
        "add" => AlphaMode::Add,
        "multiply" => AlphaMode::Multiply,
        _ => AlphaMode::Blend,
    }
}

// ── The bridge ──────────────────────────────────────────────────────────────────

/// Commands waiting for a system to pick them up.
///
/// A plain mutex rather than a channel: wasm is single-threaded, the queue is drained once a
/// frame, and a channel would be three types to carry the same two messages.
static INBOX: Mutex<Vec<String>> = Mutex::new(Vec::new());

/// Hand the runtime one JSON command. Called from the page.
#[cfg(target_arch = "wasm32")]
#[wasm_bindgen::prelude::wasm_bindgen]
pub fn arbor_send(json: String) {
    if let Ok(mut q) = INBOX.lock() {
        q.push(json);
    }
}

/// Push one JSON message back to the page.
fn emit(payload: serde_json::Value) {
    #[cfg(target_arch = "wasm32")]
    {
        use wasm_bindgen::JsValue;
        if let Some(win) = web_sys::window() {
            let text = payload.to_string();
            // To the page, which relays to whoever embedded it. Posting straight to `parent`
            // from here would tie the runtime to being in an iframe.
            let _ = win.post_message(&JsValue::from_str(&text), "*");
        }
    }
    #[cfg(not(target_arch = "wasm32"))]
    {
        println!("{payload}");
    }
}

/// What the runtime is currently showing.
#[derive(Resource, Default)]
struct Current {
    doc: Option<SceneDoc>,
    params: serde_json::Value,
}

#[derive(Component)]
pub struct SceneRoot;

/// Marks the orbiting camera, with the speed it turns at.
#[derive(Component, Clone)]
pub struct Orbiting {
    distance: f32,
    pitch: f32,
    speed: f32,
    angle: f32,
    /// Where the scene asked the camera to be, kept so `reset` has something to return to.
    rest_distance: f32,
    rest_pitch: f32,
    /// True once the viewer has dragged or zoomed.
    ///
    /// The turntable exists so a material shows itself off without being touched; the moment
    /// someone takes hold of it, continuing to spin fights them for control of the same
    /// value. So the first interaction retires the automatic motion for good — a viewer who
    /// wanted to look at one specific angle should get to keep it.
    grabbed: bool,
}

/// Marks a model that turns on its own.
#[derive(Component)]
struct Spinning(f32);

// ── Entry point ─────────────────────────────────────────────────────────────────

/// Start the runtime on the canvas with the given CSS selector.
#[cfg(target_arch = "wasm32")]
#[wasm_bindgen::prelude::wasm_bindgen]
pub fn arbor_start(canvas_selector: String) {
    run(Some(canvas_selector));
}

pub fn run(canvas: Option<String>) {
    let mut app = App::new();
    app.add_plugins(DefaultPlugins.set(WindowPlugin {
        primary_window: Some(Window {
            canvas,
            // The page owns the layout; the canvas follows the element it was given.
            fit_canvas_to_parent: true,
            prevent_default_event_handling: false,
            ..default()
        }),
        ..default()
    }))
    .add_plugins(MaterialPlugin::<PreviewMaterial>::default())
    .add_plugins(MaterialPlugin::<RawMaterial>::default())
    .add_plugins(MaterialPlugin::<RawVertexMaterial>::default())
    .add_plugins(MaterialPlugin::<CheckerMaterial>::default())
    .init_resource::<Current>()
    .init_resource::<RoleImages>()
    .add_systems(Startup, announce_ready)
    .add_systems(Update, (drain_inbox, orbit_camera, spin_models).chain());
    app.run();
}

fn announce_ready() {
    emit(serde_json::json!({ "type": "ready" }));
}

// ── Command handling ────────────────────────────────────────────────────────────

fn drain_inbox(
    mut commands: Commands,
    mut cameras: Query<&mut Orbiting>,
    existing: Query<Entity, With<SceneRoot>>,
    mut current: ResMut<Current>,
    mut meshes: ResMut<Assets<Mesh>>,
    mut materials: ResMut<Assets<PreviewMaterial>>,
    mut raw_materials: ResMut<Assets<RawMaterial>>,
    mut raw_vertex_materials: ResMut<Assets<RawVertexMaterial>>,
    mut checker_materials: ResMut<Assets<CheckerMaterial>>,
    mut shaders: ResMut<Assets<Shader>>,
    mut images: ResMut<Assets<Image>>,
    mut roles: ResMut<RoleImages>,
    mut clock: ResMut<Time<Virtual>>,
) {
    let pending: Vec<String> = match INBOX.lock() {
        Ok(mut q) if !q.is_empty() => q.drain(..).collect(),
        _ => return,
    };
    let mut assets = SceneAssets {
        meshes: &mut meshes,
        materials: &mut materials,
        raw_materials: &mut raw_materials,
        raw_vertex_materials: &mut raw_vertex_materials,
        checker_materials: &mut checker_materials,
        shaders: &mut shaders,
        images: &mut images,
        roles: &mut roles,
    };

    for text in pending {
        let msg: serde_json::Value = match serde_json::from_str(&text) {
            Ok(v) => v,
            Err(e) => {
                emit(serde_json::json!({ "type": "error", "message": format!("bad command: {e}") }));
                continue;
            }
        };
        let kind = msg.get("type").and_then(|v| v.as_str()).unwrap_or("");
        // Say what arrived, always. This seam has four hops — plugin, host node, page, here —
        // and when a command goes missing the only question worth asking is which hop it got
        // to. A trace line per message answers it from the app's own log instead of from a
        // guess about which side is at fault.
        emit(serde_json::json!({
            "type": "log",
            "message": format!("runtime: received '{kind}' ({} bytes)", text.len()),
        }));
        match kind {
            "open" => {
                let ron_text = msg.get("scene").and_then(|v| v.as_str()).unwrap_or_default();
                let params = msg.get("params").cloned().unwrap_or(serde_json::json!({}));
                match SceneDoc::parse(ron_text) {
                    Ok(doc) => {
                        // Read BEFORE the despawn: the camera is a `SceneRoot` entity too,
                        // so a moment later there is nothing left to ask.
                        let keep = cameras.iter().next().cloned();
                        for e in &existing {
                            commands.entity(e).despawn();
                        }
                        match build(&mut commands, &doc, &params, &mut assets, keep) {
                            Ok(()) => {
                                emit(serde_json::json!({
                                    "type": "opened",
                                    "id": doc.id,
                                    "name": doc.name,
                                    "controls": controls_json(&doc),
                                }));
                                current.doc = Some(doc);
                                current.params = params;
                            }
                            Err(e) => emit(serde_json::json!({ "type": "error", "message": e })),
                        }
                    }
                    Err(e) => emit(serde_json::json!({ "type": "error", "message": e })),
                }
            }
            "camera" => {
                match serde_json::from_value::<CameraCmd>(msg.clone()) {
                    Ok(cmd) => {
                        for mut o in &mut cameras {
                            apply_camera(&cmd, &mut o);
                        }
                    }
                    Err(e) => emit(serde_json::json!({
                        "type": "error",
                        "message": format!("bad camera command: {e}"),
                    })),
                }
            }
            "time" => {
                match serde_json::from_value::<TimeCmd>(msg.clone()) {
                    Ok(cmd) => apply_time(&cmd, &mut clock),
                    Err(e) => emit(serde_json::json!({
                        "type": "error",
                        "message": format!("bad time command: {e}"),
                    })),
                }
            }
            "update" => {
                // Merged rather than replaced: a panel sends the control that moved, not the
                // whole set, and replacing would blank every other param each time.
                if let Some(patch) = msg.get("params").and_then(|v| v.as_object()) {
                    if let Some(obj) = current.params.as_object_mut() {
                        for (k, v) in patch {
                            obj.insert(k.clone(), v.clone());
                        }
                    }
                }
                let Some(doc) = current.doc.clone() else { continue };
                let params = current.params.clone();
                let keep = cameras.iter().next().cloned();
                for e in &existing {
                    commands.entity(e).despawn();
                }
                if let Err(e) = build(&mut commands, &doc, &params, &mut assets, keep) {
                    emit(serde_json::json!({ "type": "error", "message": e }));
                }
            }
            other => emit(serde_json::json!({
                "type": "error",
                "message": format!("unknown command '{other}'"),
            })),
        }
    }
}

fn controls_json(doc: &SceneDoc) -> serde_json::Value {
    serde_json::Value::Array(
        doc.controls
            .iter()
            .map(|c| {
                serde_json::json!({
                    "param": c.param,
                    "label": c.label,
                    "description": c.description,
                    "kind": format!("{:?}", c.kind),
                })
            })
            .collect(),
    )
}

// ── Building ────────────────────────────────────────────────────────────────────

/// Everything [`build`] writes into.
///
/// One bag rather than seven parameters, because every caller passes all of them and adding an
/// asset kind used to mean editing three signatures and three call sites for one idea.
pub struct SceneAssets<'a> {
    pub meshes: &'a mut Assets<Mesh>,
    pub materials: &'a mut Assets<PreviewMaterial>,
    pub raw_materials: &'a mut Assets<RawMaterial>,
    pub raw_vertex_materials: &'a mut Assets<RawVertexMaterial>,
    pub checker_materials: &'a mut Assets<CheckerMaterial>,
    pub shaders: &'a mut Assets<Shader>,
    pub images: &'a mut Assets<Image>,
    pub roles: &'a mut RoleImages,
}

pub fn build(
    commands: &mut Commands,
    doc: &SceneDoc,
    params: &serde_json::Value,
    a: &mut SceneAssets<'_>,
    // Where the camera was before this rebuild, when there was one.
    keep: Option<Orbiting>,
) -> Result<(), String> {
    let env = &doc.environment;
    commands.insert_resource(ClearColor(Color::linear_rgb(
        env.background.0, env.background.1, env.background.2,
    )));
    // `AmbientLight` became a per-camera component in 0.18; the world-wide one is
    // `GlobalAmbientLight`, which is what a scene's `ambient` means.
    commands.insert_resource(GlobalAmbientLight {
        color: Color::WHITE,
        brightness: env.ambient * 1000.0,
        ..default()
    });

    // Camera. The entity comes back because the backdrop hangs off it.
    let camera = match &doc.camera {
        CameraRig::Static { position, target, fov } => {
            commands.spawn((
                SceneRoot,
                Camera3d::default(),
                projection_for(*fov),
                Transform::from_xyz(position.0, position.1, position.2)
                    .looking_at(Vec3::new(target.0, target.1, target.2), Vec3::Y),
            ))
            .id()
        }
        CameraRig::Orbit { distance, pitch, auto_spin, fov } => {
            let d = distance.value();
            commands.spawn((
                SceneRoot,
                Camera3d::default(),
                projection_for(*fov),
                Transform::from_xyz(0.0, d * pitch.sin(), d * pitch.cos())
                    .looking_at(Vec3::ZERO, Vec3::Y),
                // Carried over when there was a camera before.
                //
                // A rebuild happens because the MATERIAL changed — a slider moved, the source
                // was edited, a different mesh was picked. None of those is a reason to throw
                // away the angle somebody chose and start the turntable spinning again: the
                // whole point of looking at a parameter is watching that view change while
                // everything else holds still. Putting the camera back is what `reset` is for,
                // and it is a button because it should be asked for.
                keep.clone().unwrap_or(Orbiting {
                    distance: d,
                    pitch: *pitch,
                    speed: auto_spin.unwrap_or(0.0),
                    angle: 0.0,
                    rest_distance: d,
                    rest_pitch: *pitch,
                    grabbed: false,
                }),
            ))
            .id()
        }
    };

    // The backdrop, as a CHILD of the camera.
    //
    // Parented rather than placed in the world so it is always behind whatever is being
    // previewed and always facing the viewer, at every angle the turntable reaches — a
    // world-space wall would be a wall, and the orbit would go round the back of it. It is not
    // tagged `SceneRoot`: it dies with its parent, and tagging it would mean the despawn loop
    // reaching an entity that is already gone.
    if doc.environment.checker {
        // Inserted once and not on every rebuild: replacing a shader asset makes Bevy
        // respecialise every pipeline that uses it, and this source never changes. The raw
        // material's does, which is why that one is written each time.
        if a.shaders.get(&CHECKER_SHADER).is_none() {
            let _ = a.shaders.insert(
                &CHECKER_SHADER,
                Shader::from_wgsl(CHECKER_WGSL, "arbor://checker.wgsl"),
            );
        }
        let quad = a.meshes.add(Rectangle::new(BACKDROP_SIZE, BACKDROP_SIZE));
        let mat = a.checker_materials.add(CheckerMaterial::from_background(env.background));
        commands.entity(camera).with_children(|parent| {
            parent.spawn((
                Mesh3d(quad),
                MeshMaterial3d(mat),
                Transform::from_xyz(0.0, 0.0, -BACKDROP_DIST),
            ));
        });
    }

    // Lights
    for light in &doc.lights {
        match light {
            SceneLight::Directional { direction, color, illuminance } => {
                commands.spawn((
                    SceneRoot,
                    DirectionalLight {
                        color: Color::linear_rgb(color.0, color.1, color.2),
                        illuminance: *illuminance,
                        shadows_enabled: false,
                        ..default()
                    },
                    Transform::from_translation(Vec3::ZERO).looking_to(
                        Vec3::new(direction.0, direction.1, direction.2).normalize_or_zero(),
                        Vec3::Y,
                    ),
                ));
            }
            SceneLight::Point { position, color, intensity, range } => {
                commands.spawn((
                    SceneRoot,
                    PointLight {
                        color: Color::linear_rgb(color.0, color.1, color.2),
                        intensity: *intensity,
                        range: *range,
                        shadows_enabled: false,
                        ..default()
                    },
                    Transform::from_xyz(position.0, position.1, position.2),
                ));
            }
        }
    }

    // Entities
    for e in &doc.entities {
        let mesh_spec: MeshSpec = scene::resolve(&e.mesh, params)?;
        let mesh = a.meshes.add(to_mesh(&mesh_spec)?);

        match &e.material {
            MaterialSpec::Standard { .. } => {
                // Handled through the extended material with an all-zero extension, so there
                // is one material type in the app rather than two pipelines to keep in step.
                let mat = a.materials.add(ExtendedMaterial {
                    base: standard_from(&e.material),
                    extension: PreviewExt::default(),
                });
                spawn_entity(commands, e, mesh, mat);
            }
            MaterialSpec::Shader { source, params: slots, textures, .. } => {
                let src: String = scene::resolve(source, params)?;
                // Replacing the asset at the fixed handle is what makes an edit show up:
                // Bevy notices the change and respecialises every pipeline using it.
                let _ = a.shaders.insert(
                    &PREVIEW_SHADER,
                    Shader::from_wgsl(src, "arbor://preview_material.wgsl"),
                );
                let mut ext = PreviewExt::default();
                for (i, slot) in slots.iter().take(EXT_SLOTS).enumerate() {
                    let v: Vec<f32> = scene::resolve(slot, params)?;
                    ext.set_slot(i, ExtSlot::from_floats(&v));
                }
                ext.set_textures(&roles_for(textures, params, a)?);
                let mat = a.materials.add(ExtendedMaterial {
                    base: standard_from(&e.material),
                    extension: ext,
                });
                spawn_entity(commands, e, mesh, mat);
            }
            MaterialSpec::Raw { source, data, textures, alpha, vertex, .. } => {
                let src: String = scene::resolve(source, params)?;
                let _ = a.shaders.insert(
                    &RAW_SHADER,
                    Shader::from_wgsl(src, "arbor://raw_material.wgsl"),
                );
                let values: Vec<f32> = scene::resolve(data, params)?;
                let set = roles_for(textures, params, a)?;
                let alpha = alpha_mode_named(alpha);
                // Two material types, one shader asset. Which one is not a preference — a
                // shader with a `@vertex` rendered without the override has it silently
                // ignored, and one without, rendered with it, does not compile.
                if *vertex {
                    let mat = a
                        .raw_vertex_materials
                        .add(RawVertexMaterial::from_floats(&values, alpha, &set));
                    spawn_entity(commands, e, mesh, mat);
                } else {
                    let mat = a.raw_materials.add(RawMaterial::from_floats(&values, alpha, &set));
                    spawn_entity(commands, e, mesh, mat);
                }
            }
        }
    }
    Ok(())
}

/// The images for a material's texture slots, from the scene's role names.
///
/// A document with no `textures:` defaults to an empty list rather than being an error: a
/// shader with no textures is the common case, and every slot still gets an image because a
/// layout entry with nothing bound is a bind group wgpu refuses to create.
fn roles_for(
    slot: &scene::Slot<Vec<String>>,
    params: &serde_json::Value,
    a: &mut SceneAssets<'_>,
) -> Result<TextureSet, String> {
    let names: Vec<String> = scene::resolve(slot, params)?;
    Ok(texture_set(&names, a.images, a.roles))
}

fn projection_for(fov: Option<f32>) -> Projection {
    Projection::Perspective(PerspectiveProjection {
        fov: fov.unwrap_or(0.9),
        ..default()
    })
}

/// Generic over the material, because there are two kinds now and the placement is the same.
fn spawn_entity<M: Material>(
    commands: &mut Commands,
    e: &scene::SceneEntity,
    mesh: Handle<Mesh>,
    material: Handle<M>,
) {
    let mut entity = commands.spawn((
        SceneRoot,
        Mesh3d(mesh),
        MeshMaterial3d(material),
        Transform::from_xyz(e.position.0, e.position.1, e.position.2)
            .with_scale(Vec3::splat(e.scale)),
    ));
    if e.spin != 0.0 {
        entity.insert(Spinning(e.spin));
    }
}

fn standard_from(spec: &MaterialSpec) -> StandardMaterial {
    let (base_color, roughness, metallic, alpha, double_sided) = match spec {
        MaterialSpec::Standard { base_color, perceptual_roughness, metallic } => {
            (*base_color, *perceptual_roughness, *metallic, AlphaMode::Opaque, true)
        }
        MaterialSpec::Shader {
            base_color, perceptual_roughness, metallic, alpha, double_sided, ..
        } => (
            *base_color,
            *perceptual_roughness,
            *metallic,
            alpha_mode_named(alpha),
            *double_sided,
        ),
        // Never reached: a raw material has no `StandardMaterial` underneath it. The arm
        // exists so adding a variant is a compile error somewhere useful rather than here.
        MaterialSpec::Raw { .. } => ((1.0, 1.0, 1.0, 1.0), 0.5, 0.0, AlphaMode::Blend, true),
    };
    StandardMaterial {
        base_color: Color::linear_rgba(base_color.0, base_color.1, base_color.2, base_color.3),
        perceptual_roughness: roughness,
        metallic,
        // The blend mode a shader that computes its own alpha depends on. An extension
        // inherits it from the `StandardMaterial` underneath, so leaving it at the default
        // renders water as a sheet of opaque paint and looks like the shader failing.
        alpha_mode: alpha,
        double_sided,
        // `double_sided` lights the back face; the cull mode is what lets it be drawn at all,
        // and Bevy keeps them separate. Both, or neither is any use.
        cull_mode: if double_sided { None } else { Some(bevy::render::render_resource::Face::Back) },
        ..default()
    }
}

// ── Mesh finishing ──────────────────────────────────────────────────────────────
//
// What a preview mesh carries decides which BRANCH of a shader runs. Bevy defines
// `VERTEX_UVS_B` and `VERTEX_TANGENTS` from the attributes the mesh actually has, and a
// material written to use them takes its `#else` path on a mesh that does not — silently, and
// looking entirely correct. Fulcrum's water is the case that taught this: `uv_b.x` carries the
// depth of the pool, baked per-vertex because the surface is one mesh and the bottom is
// another, and without it the preview shows the material as it was before depth existed.
//
// So every mesh this builds gets both, unless the caller supplied better.

/// Give the mesh a second UV channel and tangents, so a shader's real branch runs.
fn finish_mesh(mut mesh: Mesh) -> Mesh {
    ensure_uv1(&mut mesh);
    // Needs UV_0, normals and indices; a raw mesh without indices simply does not get them,
    // and the shader falls back to its geometric TBN — which is what it would do in the game
    // on the same mesh.
    let _ = mesh.generate_tangents();
    mesh
}

/// A plausible second UV channel, derived from the geometry.
///
/// `x` is **depth**: 1 at the middle of the shape, falling to 0 at its rim, measured across
/// the ground plane. That is the shape of the quantity games actually bake there — how far you
/// are from the shore — and on the flat quad this previews water on, it is a pond. `y` is
/// height, normalised, which is the other thing a second channel usually carries.
///
/// A guess, and unavoidably so: the real values come from a world this runtime cannot see. It
/// is a guess in the right RANGE and with the right shape, which is the difference between
/// exercising the branch and not.
fn ensure_uv1(mesh: &mut Mesh) {
    if mesh.attribute(Mesh::ATTRIBUTE_UV_1).is_some() {
        return;
    }
    let Some(VertexAttributeValues::Float32x3(positions)) =
        mesh.attribute(Mesh::ATTRIBUTE_POSITION)
    else {
        return;
    };
    let mut radius = 0.0f32;
    let (mut lo, mut hi) = (f32::MAX, f32::MIN);
    for p in positions {
        radius = radius.max((p[0] * p[0] + p[2] * p[2]).sqrt());
        lo = lo.min(p[1]);
        hi = hi.max(p[1]);
    }
    let span = (hi - lo).max(1e-6);
    let radius = radius.max(1e-6);
    let uv1: Vec<[f32; 2]> = positions
        .iter()
        .map(|p| {
            let r = (p[0] * p[0] + p[2] * p[2]).sqrt() / radius;
            [(1.0 - r).clamp(0.0, 1.0), ((p[1] - lo) / span).clamp(0.0, 1.0)]
        })
        .collect();
    mesh.insert_attribute(Mesh::ATTRIBUTE_UV_1, uv1);
}

fn to_mesh(spec: &MeshSpec) -> Result<Mesh, String> {
    Ok(finish_mesh(match spec {
        MeshSpec::Primitive(p) => match p {
            Primitive::Sphere => Sphere::new(0.8).mesh().uv(48, 32).into(),
            Primitive::Cube => Cuboid::new(1.2, 1.2, 1.2).mesh().into(),
            // Subdivided, not a quad. A fragment shader is happy with four corners; a
            // VERTEX shader has nothing to move on them — a water surface displaced at its
            // corners is a tilted sheet of glass — and the plane is the mesh anyone reaches
            // for to try one. `Plane3d::new` takes the normal, so this still faces +Z the way
            // the `Rectangle` it replaces did.
            Primitive::Plane => Plane3d::new(Vec3::Z, Vec2::splat(0.8))
                .mesh()
                .subdivisions(48)
                .into(),
            Primitive::Torus => Torus::new(0.36, 0.88).mesh().into(),
            Primitive::Capsule => Capsule3d::new(0.4, 0.8).mesh().into(),
            Primitive::Cylinder => Cylinder::new(0.6, 1.2).mesh().into(),
        },
        MeshSpec::Raw { positions, normals, uvs, uvs_b, tangents, indices } => {
            if positions.is_empty() || positions.len() % 3 != 0 {
                return Err("raw mesh positions must be a non-empty multiple of 3".into());
            }
            let count = positions.len() / 3;
            let mut mesh = Mesh::new(PrimitiveTopology::TriangleList, RenderAssetUsages::default());
            mesh.insert_attribute(
                Mesh::ATTRIBUTE_POSITION,
                positions.chunks_exact(3).map(|c| [c[0], c[1], c[2]]).collect::<Vec<_>>(),
            );
            // A missing attribute is filled rather than left out: a Bevy PBR pipeline expects
            // all three, and a mesh without normals renders black in a way that looks like the
            // shader's fault.
            let n: Vec<[f32; 3]> = if normals.len() == positions.len() {
                normals.chunks_exact(3).map(|c| [c[0], c[1], c[2]]).collect()
            } else {
                vec![[0.0, 1.0, 0.0]; count]
            };
            mesh.insert_attribute(Mesh::ATTRIBUTE_NORMAL, n);
            let uv: Vec<[f32; 2]> = if uvs.len() == count * 2 {
                uvs.chunks_exact(2).map(|c| [c[0], c[1]]).collect()
            } else {
                vec![[0.0, 0.0]; count]
            };
            mesh.insert_attribute(Mesh::ATTRIBUTE_UV_0, uv);
            // The real second channel, when the generator had one. Anything else is filled in
            // by `finish_mesh` — a wrong-length list is ignored rather than half-applied,
            // because half a channel is worse than a derived one.
            if uvs_b.len() == count * 2 {
                mesh.insert_attribute(
                    Mesh::ATTRIBUTE_UV_1,
                    uvs_b.chunks_exact(2).map(|c| [c[0], c[1]]).collect::<Vec<_>>(),
                );
            }
            if tangents.len() == count * 4 {
                mesh.insert_attribute(
                    Mesh::ATTRIBUTE_TANGENT,
                    tangents.chunks_exact(4).map(|c| [c[0], c[1], c[2], c[3]]).collect::<Vec<_>>(),
                );
            }
            if !indices.is_empty() {
                if let Some(bad) = indices.iter().find(|i| **i as usize >= count) {
                    return Err(format!("index {bad} is past the end of a {count}-vertex mesh"));
                }
                mesh.insert_indices(Indices::U32(indices.clone()));
            }
            if normals.len() != positions.len() {
                mesh.compute_normals();
            }
            mesh
        }
    }))
}

// ── Motion ──────────────────────────────────────────────────────────────────────

/// A camera command from the page.
///
/// The page drives the camera, not Bevy's input. On the web winit reports pointer motion
/// through `DeviceEvent::MouseMotion`, which browsers only emit under pointer lock, and the
/// window-event route did not reach this canvas either — a drag simply produced nothing, with
/// no error to say so. The page, meanwhile, has plain DOM `mousemove` and `wheel` events that
/// have always worked, and a message channel to here that is already carrying scenes.
///
/// So the seam moves: the page decides what a gesture means, this applies it. That also puts
/// the buttons (zoom in, out, reset) and the drag on the same path, so there is one way a
/// camera moves rather than two that can disagree.
#[derive(serde::Deserialize, Default)]
struct CameraCmd {
    /// Radians, added to the turntable angle.
    #[serde(default)]
    yaw: f32,
    /// Radians, added to the pitch and clamped short of the poles.
    #[serde(default)]
    pitch: f32,
    /// Multiplied into the distance. A proportion, so it feels the same close up and far out
    /// and cannot cross zero.
    #[serde(default)]
    zoom: f32,
    /// Put the camera back where the scene asked for it, and let the turntable resume.
    #[serde(default)]
    reset: bool,
    /// Set the distance outright, rather than nudging it.
    ///
    /// The gestures are relative — a drag and a wheel are both "a bit more than before" — but
    /// a slider in a panel holds an absolute value, and making it send deltas would mean the
    /// panel and the camera keeping two versions of one number that drift the first time you
    /// also use the wheel.
    #[serde(default)]
    absolute_distance: Option<f32>,
    /// Start or stop the turntable without touching the framing.
    ///
    /// Separate from `reset` because they answer different questions. "Let it spin again from
    /// where I have it" and "forget what I did to the camera" are both reasonable things to
    /// want, and folding them into one control means you cannot have the first without losing
    /// the angle you just found.
    #[serde(default)]
    spin: Option<bool>,
}

/// A clock command from the page.
///
/// ## Why a preview needs one
///
/// The gesture this whole viewer exists for is *change one number, look at the difference*.
/// On a material that animates — a spiral that turns, water that ripples — that gesture does
/// not work at all while the clock runs: between the before and the after, everything else has
/// moved too, and there is no way to tell which change you are looking at.
///
/// So the clock is a control. `paused` stops it where it is, `set` puts it at an instant, and
/// `step` nudges it by a delta — which is how you walk through a cycle a frame at a time and
/// see what a term does at each phase.
///
/// The headless renderer has had this since it was written (`--time`, pinned, so the same
/// arguments render the same image); this is the same lever, on the panel.
#[derive(serde::Deserialize, Default)]
struct TimeCmd {
    /// Stop or restart the clock. Everything else here is meaningful only while stopped.
    #[serde(default)]
    paused: Option<bool>,
    /// Jump to this instant, in seconds since the scene opened.
    #[serde(default)]
    set: Option<f32>,
    /// Move by this many seconds, forwards or backwards.
    #[serde(default)]
    step: Option<f32>,
}

fn apply_time(cmd: &TimeCmd, clock: &mut Time<Virtual>) {
    use std::time::Duration;

    if let Some(paused) = cmd.paused {
        if paused {
            clock.pause();
        } else {
            clock.unpause();
        }
    }
    // Both work by moving `elapsed` outright, which is why they are only honoured while the
    // clock is stopped: a running virtual clock is recomputed from the real one every frame,
    // and a jump written into it is overwritten before anything is drawn. Rather than refuse,
    // the pause is implied — asking to look at second 4 IS asking for it to hold still.
    let target = match (cmd.set, cmd.step) {
        (Some(at), _) => Some(at.max(0.0)),
        (None, Some(by)) => Some((clock.elapsed_secs() + by).max(0.0)),
        _ => None,
    };
    if let Some(t) = target {
        clock.pause();
        // `Time::advance_to` is **forward only** — it asserts, and the message is
        // *"tried to move time backwards to an earlier elapsed moment"*, which in a wasm
        // viewport is a panic and a dead canvas. A scrub goes backwards as readily as
        // forwards, so going back means starting the virtual clock over and walking to the
        // target from zero. Nothing observes the reset: `elapsed` is the only thing a shader
        // reads out of this, and it lands on the value that was asked for either way.
        if t < clock.elapsed_secs() {
            *clock = Time::<Virtual>::default();
            clock.pause();
        }
        clock.advance_to(Duration::from_secs_f32(t));
    }

    // What the clock actually is, back to the page — always, even for a plain pause.
    //
    // Because the panel cannot know it. Stopping the clock means stopping it *where it is*,
    // and "where it is" lives here; a panel that guessed would send its guess back on the next
    // gesture and ask the clock to jump to a moment it had already passed. That is exactly the
    // assert above, arrived at from the other side.
    emit(serde_json::json!({
        "type": "time",
        "at": clock.elapsed_secs(),
        "paused": clock.is_paused(),
    }));
}

fn apply_camera(cmd: &CameraCmd, o: &mut Orbiting) {
    // ~83°, short of the pole: at exactly ±90° the look-at up-vector is parallel to the view
    // direction and the roll is undefined, which shows as the image flipping over the top.
    const PITCH_LIMIT: f32 = 1.45;
    const NEAR: f32 = 0.6;
    const FAR: f32 = 40.0;

    if cmd.reset {
        o.angle = 0.0;
        o.pitch = o.rest_pitch;
        o.distance = o.rest_distance;
        o.grabbed = false;
        return;
    }
    if let Some(d) = cmd.absolute_distance {
        o.distance = d.clamp(NEAR, FAR);
        o.grabbed = true;
        return;
    }
    if let Some(spin) = cmd.spin {
        // `grabbed` is "a human is in charge of this camera", so resuming the turntable is
        // letting go of it — not a second flag that could disagree with the first.
        o.grabbed = !spin;
        return;
    }
    // Any deliberate move retires the turntable: it exists to show a material off untouched,
    // and once someone has taken hold of it, continuing to spin fights them for the same
    // value. Whoever found the angle they wanted gets to keep it — until they press reset.
    o.grabbed = true;
    o.angle += cmd.yaw;
    o.pitch = (o.pitch + cmd.pitch).clamp(-PITCH_LIMIT, PITCH_LIMIT);
    if cmd.zoom != 0.0 {
        o.distance = (o.distance * (1.0 + cmd.zoom)).clamp(NEAR, FAR);
    }
}

fn orbit_camera(time: Res<Time>, mut q: Query<(&mut Orbiting, &mut Transform)>) {
    for (mut o, mut t) in &mut q {
        // Advance the turntable only while nobody has taken hold of it. The transform is
        // still rewritten every frame either way — that is what applies a drag or a zoom.
        if o.speed != 0.0 && !o.grabbed {
            o.angle += o.speed * time.delta_secs();
        }
        let (s, c) = o.angle.sin_cos();
        let horizontal = o.distance * o.pitch.cos();
        *t = Transform::from_xyz(horizontal * s, o.distance * o.pitch.sin(), horizontal * c)
            .looking_at(Vec3::ZERO, Vec3::Y);
    }
}

fn spin_models(time: Res<Time>, mut q: Query<(&Spinning, &mut Transform)>) {
    for (s, mut t) in &mut q {
        t.rotate_y(s.0 * time.delta_secs());
    }
}
