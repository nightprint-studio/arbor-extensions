// The Bevy frame a material shader is written against, replaced by something a browser can
// run.
//
// ## What this is for
//
// A Bevy material shader is not self-contained. `stone.wgsl` opens with
//
//     (an import of) bevy_pbr::{ pbr_fragment::pbr_input_from_standard_material, … }
//
// and everything it computes is handed to `apply_pbr_lighting` at the end. Those functions
// are hundreds of lines of Bevy's own shader library, resolved by naga_oil against bindings
// that describe a clustered-forward renderer: view uniforms, light arrays, shadow atlases,
// probe volumes. None of that exists in a canvas, and pulling it in would mean shipping a
// renderer, not a preview.
//
// So this stands in for the frame. `pbr_input_from_standard_material` produces a plausible
// input, `apply_pbr_lighting` does Lambert plus a GGX-ish specular from one light, and
// post-processing tonemaps. **The lighting you see is not Bevy's**, and the backend says so
// in a warning rather than letting it be mistaken for the real thing.
//
// ## Why it is still worth looking at
//
// Because the frame is not what you are iterating on. In `stone.wgsl` the Bevy calls are the
// first line and the last three; everything between — the value noise, the fBm, the moss
// threshold, the sediment banding, the normal perturbation — is yours, and it is exactly what
// a preview has to show you. A stand-in light is enough to see whether the bump reads, whether
// the bands are too regular, whether the moss threshold catches what you meant.
//
// ## What is deliberately missing
//
// Shadows, ambient occlusion, image-based lighting, fog, bloom, clustered lights, and
// anything that needs more than one light. A shader that reads those will fail to translate
// and say which name it wanted, which is more use than a silent black frame.

// ── Preview uniforms ────────────────────────────────────────────────────────────
//
// One block, because a WebGL2 target has no bind groups to spread them across. The names are
// the convention this backend publishes: the host fills them by role.

struct PreviewGlobals {
    time: f32,
    delta_time: f32,
    _pad0: f32,
    _pad1: f32,
}

@group(0) @binding(0) var<uniform> globals: PreviewGlobals;
@group(0) @binding(1) var<uniform> view_projection: mat4x4<f32>;
@group(0) @binding(2) var<uniform> model: mat4x4<f32>;
@group(0) @binding(3) var<uniform> camera_position: vec4<f32>;
@group(0) @binding(4) var<uniform> light_direction: vec4<f32>;
@group(0) @binding(5) var<uniform> base_color: vec4<f32>;
@group(0) @binding(6) var<uniform> surface: vec4<f32>;   // x: roughness, y: metallic, z: reflectance

// ── The shapes an imported name refers to ───────────────────────────────────────

const STANDARD_MATERIAL_FLAGS_UNLIT_BIT: u32 = 32u;

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) world_position: vec4<f32>,
    @location(1) world_normal: vec3<f32>,
    @location(2) uv: vec2<f32>,
    @location(3) color: vec4<f32>,
}

struct FragmentOutput {
    @location(0) color: vec4<f32>,
}

struct StandardMaterial {
    base_color: vec4<f32>,
    emissive: vec4<f32>,
    perceptual_roughness: f32,
    metallic: f32,
    reflectance: f32,
    flags: u32,
}

struct PbrInput {
    material: StandardMaterial,
    world_position: vec4<f32>,
    world_normal: vec3<f32>,
    N: vec3<f32>,
    V: vec3<f32>,
    is_orthographic: bool,
}

// ── The frame ───────────────────────────────────────────────────────────────────

fn pbr_input_from_standard_material(in: VertexOutput, is_front: bool) -> PbrInput {
    var m: StandardMaterial;
    // Vertex colour multiplies the base colour, which is what a Bevy mesh with per-vertex
    // colours does — `stone.wgsl` reads the result to find where a biome painted moss.
    m.base_color = base_color * in.color;
    m.emissive = vec4<f32>(0.0, 0.0, 0.0, 1.0);
    m.perceptual_roughness = surface.x;
    m.metallic = surface.y;
    m.reflectance = surface.z;
    m.flags = 0u;

    var out: PbrInput;
    out.material = m;
    out.world_position = in.world_position;
    // Flipped for a back face, as the real one does: a shader that perturbs N relies on it
    // pointing outward.
    let n = normalize(in.world_normal);
    out.world_normal = select(-n, n, is_front);
    out.N = out.world_normal;
    out.V = normalize(camera_position.xyz - in.world_position.xyz);
    out.is_orthographic = false;
    return out;
}

fn apply_pbr_lighting(pbr: PbrInput) -> vec4<f32> {
    let n = normalize(pbr.N);
    let v = normalize(pbr.V);
    let l = normalize(-light_direction.xyz);
    let h = normalize(l + v);

    let n_dot_l = max(dot(n, l), 0.0);
    let n_dot_h = max(dot(n, h), 0.0);

    let rough = clamp(pbr.material.perceptual_roughness, 0.04, 1.0);
    // Blinn-Phong standing in for GGX: the lobe is the wrong shape, but roughness still moves
    // it in the direction the author expects, which is what an iteration loop needs.
    let shininess = 2.0 / (rough * rough * rough * rough + 1e-4) - 2.0;
    let spec = pow(n_dot_h, max(shininess, 1.0)) * (1.0 - rough);

    let albedo = pbr.material.base_color.rgb;
    // A little sky-vs-ground ambient rather than a flat term, so an unlit face is still
    // readable instead of pure black.
    let ambient = mix(vec3<f32>(0.05, 0.06, 0.09), vec3<f32>(0.16, 0.17, 0.20), n.y * 0.5 + 0.5);
    let metallic = clamp(pbr.material.metallic, 0.0, 1.0);
    let diffuse = albedo * (1.0 - metallic) * n_dot_l;
    let spec_col = mix(vec3<f32>(0.04), albedo, metallic) * spec;

    return vec4<f32>(diffuse + spec_col + albedo * ambient, pbr.material.base_color.a);
}

fn main_pass_post_lighting_processing(pbr: PbrInput, color: vec4<f32>) -> vec4<f32> {
    // Reinhard plus gamma. Bevy's default is closer to AgX/TonyMcMapface, so highlights roll
    // off differently — near enough to judge shape by, not near enough to grade colour on.
    let mapped = color.rgb / (color.rgb + vec3<f32>(1.0));
    return vec4<f32>(pow(mapped, vec3<f32>(1.0 / 2.2)), color.a);
}

// ── The vertex half ─────────────────────────────────────────────────────────────
//
// A material shader usually declares no `@vertex` — Bevy supplies one. This is that one,
// reduced to what the stand-in `VertexOutput` carries.

struct PreviewVertex {
    @location(0) position: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) uv: vec2<f32>,
}

@vertex
fn preview_vertex(v: PreviewVertex) -> VertexOutput {
    var out: VertexOutput;
    let world = model * vec4<f32>(v.position, 1.0);
    out.world_position = world;
    // The mesh is not scaled non-uniformly in the preview, so the model matrix's upper 3×3
    // rotates the normal correctly without an inverse-transpose.
    out.world_normal = normalize((model * vec4<f32>(v.normal, 0.0)).xyz);
    out.uv = v.uv;
    // White: a shader that multiplies by the vertex colour is unaffected, and one that reads
    // it to find a painted region (moss) sees "nothing painted" rather than a random tint.
    out.color = vec4<f32>(1.0, 1.0, 1.0, 1.0);
    out.position = view_projection * world;
    return out;
}
