// Kaleidoscope — one wedge of noise, mirrored into a rosette.
//
// The trippy one, and the only one here that is pure construction rather than an attempt at
// something physical. It is built from two ideas:
//
// **Folding.** Convert to polar, then take the angle modulo one wedge and mirror it about the
// wedge's centre. Every pixel in the disc now reads from the same narrow slice, so whatever is
// drawn there appears `segments` times with alternating handedness — which is exactly what the
// mirrors in the toy do.
//
// **A cosine palette.** `a + b * cos(2π(c·t + d))` sweeps a smooth loop through colour space
// with four constants and no lookup table. Push different phases into r, g and b and the loop
// never repeats a hue at the same place twice.
//
// Turn `segments` down to 2 and it stops being a kaleidoscope and becomes a Rorschach blot,
// which is worth seeing once.

#import bevy_pbr::{
    forward_io::VertexOutput,
    mesh_view_bindings::globals,
}

struct KaleidoParams {
    // The palette's bias and amplitude — the `a` and `b` of `a + b * cos(…)`. Not colours you
    // see directly: `a` is the middle of the loop and `b` is how far it swings, so equal
    // channels give greys and unequal ones give a hue rotation.
    // @preview tint_a = #808080 : Middle of the colour loop.
    tint_a: vec4<f32>,
    // @preview tint_b = #808066 : How far it swings. Push channels apart for wilder hues.
    tint_b: vec4<f32>,

    // @preview segments 2..24 = 8 : Mirrors around the circle. 2 is a blot, 12 is a snowflake.
    segments: f32,
    // @preview spin -2..2 = 0.22 : How fast the whole rosette turns.
    spin: f32,
    // @preview twist -6..6 = 1.6 : Rotation that grows with radius — the shear that makes it spiral.
    twist: f32,
    // @preview rings 0..40 = 11 : Concentric bands travelling outward.
    rings: f32,
    // @preview ring_speed -4..4 = 0.9 : How fast they travel. Negative pulls them inward.
    ring_speed: f32,
    // @preview detail 0..12 = 3.5 : Noise worked into the wedge.
    detail: f32,
    // @preview cycle 0..2 = 0.35 : How fast the palette rolls.
    cycle: f32,
    // @preview falloff 0..2 = 0.7 : How hard it fades towards the rim.
    falloff: f32,
};

@group(#{MATERIAL_BIND_GROUP}) @binding(0)
var<uniform> params: KaleidoParams;

const TAU: f32 = 6.2831853;

fn hash2(p: vec2<f32>) -> f32 {
    var p3 = fract(vec3<f32>(p.xyx) * 0.1031);
    p3 = p3 + dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

fn value_noise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(hash2(i), hash2(i + vec2<f32>(1.0, 0.0)), u.x),
        mix(hash2(i + vec2<f32>(0.0, 1.0)), hash2(i + vec2<f32>(1.0, 1.0)), u.x),
        u.y,
    );
}

fn fbm(p: vec2<f32>) -> f32 {
    var sum = 0.0;
    var amp = 0.5;
    var q = p;
    for (var i = 0; i < 4; i = i + 1) {
        sum = sum + amp * value_noise(q);
        q = q * 2.03;
        amp = amp * 0.5;
    }
    return sum;
}

/// `a + b * cos(2π(c·t + d))` — a whole palette in four constants.
fn palette(t: f32, a: vec3<f32>, b: vec3<f32>) -> vec3<f32> {
    let c = vec3<f32>(1.0, 1.0, 1.0);
    let d = vec3<f32>(0.0, 0.33, 0.67);
    return a + b * cos(TAU * (c * t + d));
}

@fragment
fn fragment(mesh: VertexOutput) -> @location(0) vec4<f32> {
    let t = globals.time;
    // Centred, so the disc sits in the middle of whatever it is drawn on.
    let p = mesh.uv * 2.0 - 1.0;
    let r = length(p);

    // Polar, with two rotations: one uniform (spin) and one that grows with radius (twist).
    // The second is what turns a static rosette into something that appears to be pouring
    // outward, and it costs one multiply.
    var a = atan2(p.y, p.x) + t * params.spin + r * params.twist;

    // The fold. Wrap the angle into one wedge, then mirror about its centre: `abs(x - 0.5)`
    // over a [0,1) wrap is the whole mirror, and it is why the seams between segments meet
    // instead of butting.
    let seg = max(params.segments, 2.0);
    let wedge = TAU / seg;
    a = abs(fract(a / wedge) - 0.5) * wedge;

    // Back to a coordinate the noise can read, now that every segment shares one.
    let folded = vec2<f32>(cos(a), sin(a)) * r;

    let n = fbm(folded * params.detail + vec2<f32>(0.0, t * 0.15));
    let band = 0.5 + 0.5 * sin(r * params.rings - t * params.ring_speed + n * 3.0);

    var color = palette(band * 0.6 + n * 0.4 + t * params.cycle, params.tint_a.rgb, params.tint_b.rgb);

    // Away towards the rim, so the disc has an edge instead of being cut off by the mesh.
    color = color * (1.0 - smoothstep(1.0 - params.falloff, 1.15, r));

    return vec4<f32>(color, 1.0);
}
