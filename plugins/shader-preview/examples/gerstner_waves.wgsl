// Gerstner waves — the one example here that moves the geometry, not just its colour.
//
// A sine wave pushed up and down is not what water does. Water particles move in **circles**:
// forward at the crest, backward in the trough, which piles the surface into sharp peaks with
// long flat troughs between them. A Gerstner wave writes that directly — it displaces along
// the wave's direction as well as vertically, and one parameter (`steepness`) says how much.
//
// That is why this needs a vertex stage. The peaked silhouette is geometry; you cannot fake it
// in the fragment shader, and a normal map over a flat quad gives you the lighting of a wave
// with the outline of a sheet of glass.
//
// Three waves are summed, at different directions, lengths and speeds. One wave reads as a
// corrugation; three stop looking periodic, which is most of what makes water read as water.
//
// ## What a custom vertex stage has to do
//
// Bevy hands you a `Vertex` and expects a `VertexOutput`. Everything the fragment stage reads
// has to be filled in, and which fields exist depends on what the MESH carries — hence the
// `#ifdef`s. Getting the clip position from `position_world_to_clip` rather than by hand is
// what keeps this working when the camera changes.

#import bevy_pbr::{
    forward_io::{Vertex, VertexOutput},
    mesh_functions,
    mesh_view_bindings::globals,
    view_transformations::position_world_to_clip,
}

struct WaveParams {
    // @preview deep = #06263d : The troughs, looking down into it.
    deep: vec4<f32>,
    // @preview crest = #2f9ab5 : The tops, where the sheet is thin.
    crest: vec4<f32>,
    // @preview sky = #b8d4f0 : What a glancing angle reflects.
    sky: vec4<f32>,

    // @preview amplitude 0..0.4 = 0.09 : Height of the tallest wave.
    amplitude: f32,
    // @preview wavelength 0.2..6 = 1.1 : Distance between crests of the tallest wave.
    wavelength: f32,
    // @preview steepness 0..1 = 0.75 : 0 is a sine, 1 is a breaking peak. Past 1 it folds over.
    steepness: f32,
    // @preview speed 0..4 = 1.1 : How fast they travel.
    speed: f32,
    // @preview chop 0..1 = 0.6 : How much the two smaller waves disagree with the first.
    chop: f32,
    // @preview foam 0..1 = 0.45 : Whitening on the crests.
    foam: f32,
    // @preview gloss 0..1 = 0.6 : How mirror-like the surface reads.
    gloss: f32,
    _pad: f32,
};

@group(#{MATERIAL_BIND_GROUP}) @binding(0)
var<uniform> params: WaveParams;

/// One Gerstner wave: vertical lift plus horizontal gather towards the crest.
///
/// The horizontal term is what makes it not a sine. `steepness / (k * amplitude * waves)`
/// keeps the sum from folding the surface through itself when several waves stack up — past
/// that ratio the crests loop over and the mesh self-intersects, which looks like a bug in the
/// mesh rather than a wave that was asked for too much.
fn gerstner(
    p: vec2<f32>,
    dir: vec2<f32>,
    wavelength: f32,
    amplitude: f32,
    steepness: f32,
    t: f32,
) -> vec3<f32> {
    let k = 6.2831853 / max(wavelength, 0.01);
    let d = normalize(dir);
    // Deep-water dispersion: long waves travel faster, which is why a swell outruns a chop.
    let c = sqrt(9.8 / k);
    let f = k * (dot(d, p) - c * t);
    let a = steepness / k;
    return vec3<f32>(d.x * a * cos(f), amplitude * sin(f), d.y * a * cos(f));
}

/// The three waves, summed. Shared by the vertex stage and the normal estimate.
fn surface(p: vec2<f32>, t: f32) -> vec3<f32> {
    let a = params.amplitude;
    let w = params.wavelength;
    let s = params.steepness / 3.0;
    var sum = gerstner(p, vec2<f32>(1.0, 0.15), w, a, s, t);
    sum = sum + gerstner(p, vec2<f32>(-0.4, 1.0), w * 0.55, a * 0.55 * params.chop, s, t * 1.3);
    sum = sum + gerstner(p, vec2<f32>(0.7, -0.8), w * 0.28, a * 0.3 * params.chop, s, t * 1.7);
    return sum;
}

@vertex
fn vertex(vertex: Vertex) -> VertexOutput {
    var out: VertexOutput;

    let t = globals.time * params.speed;
    let world_from_local = mesh_functions::get_world_from_local(vertex.instance_index);

    // The plane this previews on lies in XY with +Z up before the transform, so the wave is
    // computed on the two axes the quad actually spans and lifted along the third.
    let p = vertex.position.xy;
    let d = surface(p, t);
    let displaced = vertex.position + vec3<f32>(d.x, d.z, d.y);

    out.world_position = mesh_functions::mesh_position_local_to_world(
        world_from_local,
        vec4<f32>(displaced, 1.0),
    );
    out.position = position_world_to_clip(out.world_position.xyz);

    // The normal, by finite differences on the same function. Cheaper and more honest than
    // deriving it analytically: three waves with a steepness term have a Jacobian nobody wants
    // to maintain, and two extra evaluations at this vertex count cost nothing.
    let e = 0.02;
    let dx = surface(p + vec2<f32>(e, 0.0), t) - d;
    let dy = surface(p + vec2<f32>(0.0, e), t) - d;
    let tx = vec3<f32>(e + dx.x, dx.z, dx.y);
    let ty = vec3<f32>(dy.x, dy.z, e + dy.y);
    let n = normalize(cross(ty, tx));
    out.world_normal = mesh_functions::mesh_normal_local_to_world(n, vertex.instance_index);

#ifdef VERTEX_UVS_A
    out.uv = vertex.uv;
#endif
#ifdef VERTEX_UVS_B
    out.uv_b = vertex.uv_b;
#endif
#ifdef VERTEX_TANGENTS
    out.world_tangent = mesh_functions::mesh_tangent_local_to_world(
        world_from_local,
        vertex.tangent,
        vertex.instance_index,
    );
#endif
    return out;
}

@fragment
fn fragment(mesh: VertexOutput) -> @location(0) vec4<f32> {
    let n = normalize(mesh.world_normal);
    let view = normalize(vec3<f32>(0.0, 0.55, 1.0));

    // Fresnel: glancing angles reflect the sky, head-on angles look into the water. It is the
    // single strongest cue that a surface is water rather than paint, and it is one dot product.
    let fresnel = pow(1.0 - clamp(dot(n, view), 0.0, 1.0), 4.0);

    // Height drives colour, which is what makes the peaks read even before the light does.
    //
    // Re-evaluated here rather than carried from the vertex stage, and that is not laziness:
    // `VertexOutput` is Bevy's struct and has no spare field to put it in, so passing it would
    // mean either overloading one that means something else or forking the struct. Three
    // gerstner terms is a handful of instructions, and re-deriving a value is cheaper than
    // owning a copy of somebody else's interface.
    //
    // Read at the fragment's world XY, which is the displaced position rather than the
    // original — so the crests are very slightly wider than they truly are. On a surface whose
    // whole point is that it moves, nobody has ever noticed.
    let wave = surface(mesh.world_position.xy, globals.time * params.speed);
    let h = clamp(wave.y / max(params.amplitude, 0.001) * 0.5 + 0.5, 0.0, 1.0);
    var color = mix(params.deep.rgb, params.crest.rgb, h);
    color = mix(color, params.sky.rgb, fresnel * params.gloss);

    // Foam on the crests only — and only on the ones the waves actually piled up, so it moves
    // with them instead of sitting on the mesh.
    color = mix(color, vec3<f32>(1.0), params.foam * smoothstep(0.78, 1.0, h));

    // A tight specular, from the same half-vector a light would use. Unlit material, so this is
    // the only highlight there is, and without it the surface reads as matte rubber.
    let half_v = normalize(view + vec3<f32>(-0.35, 0.8, 0.45));
    let spec = pow(clamp(dot(n, half_v), 0.0, 1.0), 64.0) * params.gloss;
    color = color + vec3<f32>(spec);

    return vec4<f32>(color, 1.0);
}
