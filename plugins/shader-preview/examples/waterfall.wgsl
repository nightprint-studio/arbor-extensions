// Waterfall — sheets of water falling, breaking into foam at the bottom.
//
// Water in freefall has almost no shading and a great deal of *structure*: long vertical
// filaments that stretch as they accelerate, and white where the sheet tears. So the whole
// effect is built out of anisotropy — the same noise, squashed hard along one axis.
//
// The trick worth stealing is the **stretch**: sampling noise at `vec2(x * 40, y * 2)` makes
// features forty times narrower than they are tall, which is what a filament is. Scrolling that
// downward faster than the eye can follow does the rest.
//
// Unlit, and this one has good reason beyond convenience: falling water is lit by what is
// behind it far more than by what is in front, and a key light on a sheet of it looks like wet
// plastic.

#import bevy_pbr::{
    forward_io::VertexOutput,
    mesh_view_bindings::globals,
}

struct WaterfallParams {
    // @preview deep = #072430 : Water thick enough to hide what is behind it.
    deep: vec4<f32>,
    // @preview shallow = #5c9fb4 : A thin sheet with light coming through.
    shallow: vec4<f32>,
    // @preview foam = #eff8ff : Where the sheet tears.
    foam: vec4<f32>,

    // @preview fall_speed 0..4 = 1.35 : How fast the sheet falls.
    fall_speed: f32,
    // @preview streaks 4..80 = 34 : Filaments across the width. High is a fine spray.
    streaks: f32,
    // @preview stretch 1..24 = 9 : How far each filament is drawn out along the fall.
    stretch: f32,
    // @preview turbulence 0..1 = 0.45 : How much the sheet wanders sideways as it drops.
    turbulence: f32,
    // @preview foam_start 0..1 = 0.62 : Where down the fall the water starts tearing.
    foam_start: f32,
    // @preview foam_bite 0..1 = 0.55 : How readily it tears once it does.
    foam_bite: f32,
    // @preview mist 0..1 = 0.35 : Haze lifting off the bottom.
    mist: f32,
    _pad: f32,
};

@group(#{MATERIAL_BIND_GROUP}) @binding(0)
var<uniform> params: WaterfallParams;

fn hash2(p: vec2<f32>) -> f32 {
    var p3 = fract(vec3<f32>(p.xyx) * 0.1031);
    p3 = p3 + dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

fn value_noise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = hash2(i);
    let b = hash2(i + vec2<f32>(1.0, 0.0));
    let c = hash2(i + vec2<f32>(0.0, 1.0));
    let d = hash2(i + vec2<f32>(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
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

@fragment
fn fragment(mesh: VertexOutput) -> @location(0) vec4<f32> {
    // `v` counts DOWN the fall, so 0 is the lip and 1 is the plunge pool. Flipping it here
    // rather than in every expression below keeps "further down" and "larger number" the same
    // thing, which is the sort of confusion that survives for months.
    let u = mesh.uv.x;
    let v = 1.0 - mesh.uv.y;
    let t = globals.time;

    // Water accelerates. `v * v` in the scroll term is what stops the sheet reading as a
    // conveyor belt: the filaments visibly lengthen as they go, which is the one cue that says
    // falling rather than sliding.
    let fall = t * params.fall_speed * (0.55 + 0.85 * v * v);

    // Sideways wander, itself noise, so the sheet is not a set of parallel lines.
    let wander = params.turbulence * 0.12 * (fbm(vec2<f32>(u * 3.0, v * 1.5 - t * 0.25)) - 0.5);

    // The filaments: many across, few along, scrolling down.
    let s = vec2<f32>((u + wander) * params.streaks, v * params.stretch - fall);
    let filament = fbm(s);

    // A second, coarser sheet behind the first, drifting at a different rate. Two layers at
    // different speeds is what gives depth to something with no parallax to offer.
    let back = fbm(vec2<f32>((u - wander * 0.5) * params.streaks * 0.35, v * params.stretch * 0.5 - fall * 0.6));

    let body = mix(back, filament, 0.65);
    var color = mix(params.deep.rgb, params.shallow.rgb, smoothstep(0.35, 0.75, body));

    // Tearing. It starts partway down and takes hold where the filaments are already brightest,
    // because that is where the sheet is thinnest.
    let depth = smoothstep(params.foam_start, 1.0, v);
    let tear = smoothstep(1.0 - params.foam_bite, 1.0, body * (0.45 + 0.9 * depth));
    color = mix(color, params.foam.rgb, tear);

    // Spray at the very bottom, where it hits. High-frequency, short-lived, and lifted with a
    // slow ramp so there is no line where the mist begins.
    let spray = fbm(vec2<f32>(u * 26.0, v * 26.0 - t * 2.2));
    let haze = params.mist * smoothstep(0.72, 1.0, v) * smoothstep(0.45, 0.9, spray);
    color = mix(color, params.foam.rgb, haze);

    return vec4<f32>(color, 1.0);
}
