// Magma — a cooling crust with molten cracks running under it.
//
// The whole effect is one idea: build a slow, lumpy field with FBM, **warp its own
// coordinates with a second copy of itself** (domain warping), and read the result twice — once
// as rock and once as light. The crust is where the field is high, the cracks are the thin band
// where it crosses a threshold, and light only comes out of the band.
//
// Domain warping is what makes it look like flow rather than like noise. Plain FBM gives blobs
// that sit still in shape even while they scroll; feeding the field back into its own lookup
// drags those blobs sideways in a way that reads as a viscous surface being pulled.
//
// Unlit on purpose: molten rock emits, so a light rig has nothing to add. That also makes it a
// material that owns its whole bind group, which is the simpler of the two preview paths.

#import bevy_pbr::{
    forward_io::VertexOutput,
    mesh_view_bindings::globals,
}

struct MagmaParams {
    // The two ends of the heat ramp, plus the rock. Alpha is unused — the surface is solid.
    //
    // The `= #rrggbb` is what tells the preview these are colours at all: the guess it would
    // otherwise make reads the variable's NAME, and `hot` does not look like a colour to
    // anything but a person.
    // @preview hot = #ff6b14 : The centre of a crack, where the rock is thinnest.
    hot: vec4<f32>,
    // @preview cool = #38100a : Molten rock that has begun to skin over.
    cool: vec4<f32>,
    // @preview crust = #121014 : Cold basalt.
    crust: vec4<f32>,

    // @preview flow_speed -1..1 = 0.08 : How fast the melt creeps. Negative runs it backwards.
    flow_speed: f32,
    // @preview scale 0.5..12 = 3.0 : Size of the lumps. Low is a lava lake, high is gravel.
    scale: f32,
    // @preview warp 0..2 = 0.85 : How hard the field drags its own coordinates. 0 is plain FBM.
    warp: f32,
    // @preview crust_level 0..1 = 0.52 : Where rock ends and glow begins.
    crust_level: f32,
    // Narrow, and the reason is worth knowing: five octaves of FBM land almost entirely
    // between 0.3 and 0.7, so a band of ±0.14 around the threshold covers half the surface and
    // the effect stops being rock with cracks and becomes fire.
    // @preview crack_width 0.005..0.2 = 0.035 : Thickness of the glowing band.
    crack_width: f32,
    // @preview glow 0..6 = 2.2 : Brightness inside the cracks.
    glow: f32,
    // @preview pulse 0..2 = 0.6 : How much the cracks breathe.
    pulse: f32,
    _pad: f32,
};

@group(#{MATERIAL_BIND_GROUP}) @binding(0)
var<uniform> params: MagmaParams;

// Hash without sine — integer bit-mixing rather than `fract(sin(x)*43758.5)`, which bands
// badly on some mobile GPUs because their `sin` loses precision long before the multiply does.
fn hash2(p: vec2<f32>) -> f32 {
    var p3 = fract(vec3<f32>(p.xyx) * 0.1031);
    p3 = p3 + dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

// Value noise: hash the four lattice corners and interpolate with a smoothstep curve, so the
// derivative is continuous and the field has no visible grid.
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

// Five octaves, each half the amplitude and a bit more than twice the frequency.
//
// 2.03 rather than 2.0: an exact doubling lines every octave's lattice up with the one below
// it, and the repeated alignment shows as a faint square grid in the sum.
fn fbm(p: vec2<f32>) -> f32 {
    var sum = 0.0;
    var amp = 0.5;
    var q = p;
    for (var i = 0; i < 5; i = i + 1) {
        sum = sum + amp * value_noise(q);
        q = q * 2.03;
        amp = amp * 0.5;
    }
    return sum;
}

@fragment
fn fragment(mesh: VertexOutput) -> @location(0) vec4<f32> {
    let t = globals.time * params.flow_speed;
    let uv = mesh.uv * params.scale;

    // Domain warping. Two offset lookups give a 2D displacement, and feeding that back into the
    // field is what turns "noise scrolling past" into "a surface being dragged".
    let q = vec2<f32>(fbm(uv + vec2<f32>(0.0, t)), fbm(uv + vec2<f32>(5.2, 1.3 - t)));
    let r = vec2<f32>(
        fbm(uv + params.warp * q + vec2<f32>(1.7, 9.2) + 0.15 * t),
        fbm(uv + params.warp * q + vec2<f32>(8.3, 2.8) - 0.13 * t),
    );
    let field = fbm(uv + params.warp * r);

    // The crack is the **band where the field crosses the threshold**, not everything under it.
    // The distinction is the whole look: a half-plane test lights up half the surface and reads
    // as fire, while a band lights up a seam and reads as rock with something behind it.
    let breath = 1.0 + params.pulse * 0.25 * sin(globals.time * 1.7 + field * 6.0);
    let level = params.crust_level;
    let w = params.crack_width * breath;
    let heat = 1.0 - smoothstep(0.0, w, abs(field - level));

    // Rock everywhere, shaded by the field so the crust has relief of its own — otherwise the
    // plates between the cracks are flat colour and the cracks look drawn on.
    let rock = mix(params.crust.rgb, params.cool.rgb, smoothstep(level - 0.3, level + 0.4, field));
    // `pow` on the hot end keeps the centre of a crack white while its shoulders stay orange,
    // which is the gradient molten rock actually has.
    let molten = mix(params.cool.rgb, params.hot.rgb, pow(heat, 2.0));
    var color = mix(rock, molten, smoothstep(0.05, 0.75, heat));

    // Emission, kept out of the mix above so the glow adds light instead of replacing colour.
    color = color + params.hot.rgb * params.glow * pow(heat, 3.0) * breath;

    return vec4<f32>(color, 1.0);
}
