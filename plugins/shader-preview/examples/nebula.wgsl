// Nebula — dust lit from inside, with stars behind it.
//
// The semi-realistic one. A real emission nebula is a cloud that is *transparent* and *emits*,
// so the eye reads depth from accumulated brightness rather than from shading. That is why
// nothing here is lit: every value added along the way is light the cloud made.
//
// Two techniques carry it:
//
// **Ridged noise.** `1 - |2n - 1|` turns the smooth hills of FBM into sharp crests. Ordinary
// FBM gives cotton wool; ridged gives filaments, which is what dust lanes look like.
//
// **Density-mapped colour.** The palette is indexed by how much dust the ray passed through,
// not by position — so the thin outskirts come out cold and the dense core comes out hot, for
// the same reason they do in a photograph.

#import bevy_pbr::{
    forward_io::VertexOutput,
    mesh_view_bindings::globals,
}

struct NebulaParams {
    // Cold outskirts, warm core, and the void behind. Alpha unused.
    // @preview cold = #4b62c4 : Dust thin enough to scatter rather than glow.
    cold: vec4<f32>,
    // @preview warm = #ff8fa0 : The core, where it emits.
    warm: vec4<f32>,
    // @preview void_color = #05050d : The sky between.
    void_color: vec4<f32>,

    // @preview drift -0.5..0.5 = 0.035 : How fast the cloud turns over.
    drift: f32,
    // @preview scale 0.5..8 = 2.4 : Size of the structure.
    scale: f32,
    // @preview warp 0..3 = 1.1 : Domain warping — the difference between clouds and filaments.
    warp: f32,
    // @preview density 0..3 = 1.0 : How much dust there is.
    density: f32,
    // @preview core 0..1 = 0.38 : Where the cloud starts glowing rather than merely being lit.
    core: f32,
    // @preview stars 0..1 = 0.45 : How many get through.
    stars: f32,
    // @preview twinkle 0..4 = 1.3 : How fast they flicker.
    twinkle: f32,
    _pad: f32,
};

@group(#{MATERIAL_BIND_GROUP}) @binding(0)
var<uniform> params: NebulaParams;

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

/// Ridged FBM: fold each octave about its midpoint before summing.
///
/// The fold is the whole difference. `1 - |2n - 1|` puts a crease where the smooth noise
/// crossed 0.5, and summing octaves of creases gives branching filaments instead of hills.
fn ridged(p: vec2<f32>) -> f32 {
    var sum = 0.0;
    var amp = 0.5;
    var q = p;
    for (var i = 0; i < 5; i = i + 1) {
        let n = value_noise(q);
        sum = sum + amp * (1.0 - abs(2.0 * n - 1.0));
        q = q * 2.07;
        amp = amp * 0.55;
    }
    return sum;
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
    let t = globals.time * params.drift;
    let uv = mesh.uv * params.scale;

    // Warp first, so the filaments bend around each other rather than lying in parallel.
    let q = vec2<f32>(fbm(uv + vec2<f32>(0.0, t)), fbm(uv + vec2<f32>(3.1, -t)));
    // Cubed before scaling, and that is not a taste decision. Ridged noise spends most of its
    // range NEAR THE TOP — every octave folds towards 1 — so used directly it saturates the
    // whole frame and there is no empty sky for the cloud to be a cloud against. The power
    // curve opens the void back up while leaving the crests where they were.
    let dust = pow(clamp(ridged(uv + params.warp * q), 0.0, 1.0), 6.0) * params.density;

    // Stars, drawn BEFORE the dust so the cloud occludes them. A star is a lattice cell whose
    // hash clears a threshold; the offset inside the cell keeps them off the grid, which is the
    // one thing that gives a procedural starfield away.
    let cell = floor(mesh.uv * 220.0);
    let inner = fract(mesh.uv * 220.0);
    let h = hash2(cell);
    let here = step(1.0 - params.stars * 0.06, h);
    let spot = vec2<f32>(hash2(cell + 11.0), hash2(cell + 27.0));
    let star = here
        * smoothstep(0.34, 0.0, length(inner - spot))
        * (0.55 + 0.45 * sin(globals.time * params.twinkle + h * 40.0));

    // The cloud. Colour comes from DENSITY, not position — thin edges cold, dense core warm,
    // which is the whole reason a nebula photograph looks like one.
    let thin = smoothstep(0.02, 0.22, dust);
    let hot = smoothstep(params.core, params.core + 0.30, dust);
    var color = mix(params.void_color.rgb, params.cold.rgb, thin);
    color = mix(color, params.warm.rgb, hot);

    // Stars survive only where the dust is thin.
    color = color + vec3<f32>(star * (1.0 - thin * 0.85));

    // A last bloom out of the densest part, so the core reads as a source rather than a patch.
    color = color + params.warm.rgb * pow(hot, 3.0) * 0.6;

    return vec4<f32>(color, 1.0);
}
