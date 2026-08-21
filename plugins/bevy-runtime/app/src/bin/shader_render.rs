//! Render one WGSL material to a PNG, once, without a window.
//!
//! ## Why this exists
//!
//! The viewport in Arbor's panel is for a person: it runs in a webview, it animates, and
//! looking at it means having the app open on the right file. An assistant asked to tune a
//! shader can do none of that — so it gets the same renderer as a command that answers with a
//! picture, which is what `bennu_shader_render` calls.
//!
//! ## Why it is a Bevy app and not a small wgpu program
//!
//! Because the shaders it has to render are Bevy's. `#import bevy_pbr::forward_io::VertexOutput`
//! and `mesh_view_bindings::globals` are resolved by naga_oil against the engine's own shader
//! library, with the mesh and view bind groups laid out the way Bevy lays them out. A hand-rolled
//! renderer would have to reproduce all of that and would drift from it at the first release.
//! This binary shares the scene format, the materials and the mesh builders with the viewport
//! next door, so a picture it produces is the picture the panel would show.
//!
//! ## Determinism
//!
//! Time is pinned rather than left to run: an animated material rendered "now" is a different
//! image every call, and comparing two parameter sets means the only thing that changed is the
//! parameters. `--time` is that clock, and it defaults to zero.
//!
//! ## Usage
//!
//! ```text
//! arbor-shader-render --shader m.wgsl --out /tmp/m.png \
//!     [--data 1.0,0.5,...] [--mesh sphere|cube|plane|torus] [--time 2.5] \
//!     [--size 640x640] [--alpha blend] [--checker on|off] [--extension] [--vertex] \
//!     [--distance 2.6] [--pitch 0.3] [--background r,g,b]
//! ```
//!
//! Exit code 0 with the file written, or non-zero with the reason on stderr. A shader that does
//! not compile still exits 0 with an image — wgpu reports the failure in the log rather than by
//! refusing, and the caller reads stderr for it. That is deliberate: an image of a material that
//! failed to compile is itself informative, and throwing it away would leave only the log.

use std::path::PathBuf;
use std::time::Duration;

use bevy::{
    app::{AppExit, ScheduleRunnerPlugin},
    camera::RenderTarget,
    prelude::*,
    render::{
        render_resource::TextureFormat,
        view::screenshot::{save_to_disk, Screenshot},
    },
    window::ExitCondition,
    winit::WinitPlugin,
};

use arbor_bevy_runtime::{
    build, scene::SceneDoc, CheckerMaterial, PreviewMaterial, RawMaterial, RawVertexMaterial,
    RoleImages, SceneAssets,
};

// ── What the caller asked for ───────────────────────────────────────────────────

#[derive(Resource, Clone, Debug)]
struct Job {
    doc: String,
    params: serde_json::Value,
    out: PathBuf,
    width: u32,
    height: u32,
    time: f32,
}

/// The image the camera draws into, and which the screenshot reads back.
#[derive(Resource)]
struct Target(Handle<Image>);

/// Where the run is up to.
///
/// Frames are counted rather than waited on because there is nothing to wait *for* that is
/// observable: a pipeline compiles when the render world gets to it, and an asset finishes
/// loading a frame or two later. A fixed lead-in is the honest version of "give it a moment",
/// and at 512×512 the whole run is well under a second either way.
#[derive(Resource)]
enum Phase {
    /// Frames still to render before the picture is worth capturing.
    Warmup(u32),
    /// Screenshot requested; frames left for the observer to write the file.
    Capturing(u32),
}

/// Frames rendered before the capture. Enough for pipeline specialisation and for the first
/// frame's assets to be live.
const WARMUP_FRAMES: u32 = 12;
/// Frames after the capture, so the observer that writes the PNG has run.
const DRAIN_FRAMES: u32 = 20;

// ── Arguments ───────────────────────────────────────────────────────────────────

struct Args {
    shader: Option<PathBuf>,
    out: Option<PathBuf>,
    data: Vec<f32>,
    mesh: String,
    time: f32,
    width: u32,
    height: u32,
    alpha: String,
    /// What to put in each texture slot, in slot order — see `--textures`.
    textures: Vec<String>,
    /// The shader brings its own `@vertex fn vertex(…)`.
    vertex: bool,
    checker: bool,
    /// Build the material as an **extension of `StandardMaterial`** rather than as one that
    /// owns its whole bind group.
    ///
    /// Named for what it is. It was `--legacy`, which said the opposite of the truth: a
    /// material extension is Bevy's own convention and the majority of what gets previewed —
    /// `stone`, `metal`, `water`, `tile` are all extensions. Nothing about it is legacy, and a
    /// flag whose name misleads is worse than one nobody can find.
    extension: bool,
    distance: f32,
    pitch: f32,
    background: (f32, f32, f32),
}

impl Default for Args {
    fn default() -> Self {
        Self {
            shader: None,
            out: None,
            data: Vec::new(),
            mesh: "sphere".into(),
            time: 0.0,
            width: 512,
            height: 512,
            alpha: "blend".into(),
            textures: Vec::new(),
            vertex: false,
            checker: true,
            extension: false,
            distance: 2.6,
            pitch: 0.30,
            background: (0.055, 0.062, 0.078),
        }
    }
}

fn parse_floats(text: &str) -> Vec<f32> {
    text.split(|c| c == ',' || c == ' ')
        .filter(|s| !s.trim().is_empty())
        .filter_map(|s| s.trim().parse::<f32>().ok())
        .collect()
}

/// The value that follows a flag, or a message naming the flag that wanted one.
///
/// A free function and not a closure over the iterator: a closure would hold `it` borrowed
/// across the `match` that also reads `flag`, which is a borrow-checker argument with no
/// upside in a nine-branch parser.
fn next_value(it: &mut impl Iterator<Item = String>, flag: &str) -> Result<String, String> {
    it.next().ok_or_else(|| format!("{flag} needs a value"))
}

/// Hand-rolled rather than a parser crate: nine flags, one caller, and the alternative is a
/// dependency in a package that travels over a network on install.
fn parse_args() -> Result<Args, String> {
    let mut a = Args::default();
    let mut it = std::env::args().skip(1);
    while let Some(flag) = it.next() {
        macro_rules! value {
            () => {
                next_value(&mut it, &flag)?
            };
        }
        match flag.as_str() {
            "--shader" => a.shader = Some(PathBuf::from(value!())),
            "--out" => a.out = Some(PathBuf::from(value!())),
            "--data" => a.data = parse_floats(&value!()),
            "--mesh" => a.mesh = value!().to_ascii_lowercase(),
            "--alpha" => a.alpha = value!().to_ascii_lowercase(),
            // One role per texture slot, in the order the shader's textures were renumbered:
            // `white`, `black`, `grey`, `normal`, `checker`, `noise`, `uv`. A preview has no
            // assets, so a slot is filled with an image the runtime can generate — and which
            // one is right depends on what the texture is FOR, which the caller knows.
            "--textures" => {
                // Empty entries are KEPT. The list is positional — index 12 is the first
                // array texture whatever came before it — so dropping the blanks would slide
                // every later slot one place and paint the wrong texture.
                a.textures = value!()
                    .split(',')
                    .map(|s| s.trim().to_ascii_lowercase())
                    .collect()
            }
            "--time" => a.time = value!().parse().map_err(|_| "--time is not a number")?,
            "--distance" => a.distance = value!().parse().map_err(|_| "--distance is not a number")?,
            "--pitch" => a.pitch = value!().parse().map_err(|_| "--pitch is not a number")?,
            "--extension" | "--legacy" => a.extension = true,
            // Which of the two raw material types to build. Not sniffed from the source here:
            // the caller has already read the shader — that is how it knows to pass `--data` —
            // and a second, weaker parser in the renderer would be one more thing to disagree.
            "--vertex" => a.vertex = true,
            "--checker" => {
                let v = value!().to_ascii_lowercase();
                a.checker = !matches!(v.as_str(), "off" | "false" | "0" | "no");
            }
            "--background" => {
                let v = parse_floats(&value!());
                if v.len() >= 3 {
                    a.background = (v[0], v[1], v[2]);
                }
            }
            "--size" => {
                let v = value!();
                let (w, h) = v
                    .split_once(['x', 'X'])
                    .ok_or_else(|| format!("--size wants WxH, got '{v}'"))?;
                a.width = w.trim().parse().map_err(|_| "--size width is not a number")?;
                a.height = h.trim().parse().map_err(|_| "--size height is not a number")?;
            }
            other => return Err(format!("unknown flag '{other}'")),
        }
    }
    if a.shader.is_none() {
        return Err("--shader is required".into());
    }
    if a.out.is_none() {
        return Err("--out is required".into());
    }
    // A caller asking for a 16k render is asking for a GPU allocation failure with a worse
    // error message than this one.
    if a.width == 0 || a.height == 0 || a.width > 4096 || a.height > 4096 {
        return Err("--size must be between 1x1 and 4096x4096".into());
    }
    Ok(a)
}

// ── The document ────────────────────────────────────────────────────────────────

fn num(v: f32) -> String {
    // RON reads a bare integer as an integer and refuses it where an f32 is expected.
    let s = format!("{v:.4}");
    let s = s.trim_end_matches('0').to_string();
    if s.ends_with('.') { format!("{s}0") } else { s }
}

/// The scene, written here rather than read from a file.
///
/// This binary is inside the package that owns the format, so generating the document keeps
/// the two in step by construction: a field added to `SceneDoc` is added a few lines from
/// here. Reading one of the shipped `scenes/*.ron` would have meant a second copy of the
/// caller's intent, half in a file and half in flags.
fn scene_ron(a: &Args) -> String {
    let material = if a.extension {
        // A shader written to Bevy's convention: an extension of `StandardMaterial` with
        // `vec4`s at bindings 100 and up. It has PBR underneath, so it gets the rig's light.
        format!(
            r#"Shader(
                source: Param("shader"),
                params: [ Param("p0"), Param("p1"), Param("p2"), Param("p3"),
                          Param("p4"), Param("p5"), Param("p6"), Param("p7") ],
                textures: Param("textures"),
                base_color: (0.62, 0.60, 0.57, 1.0),
                perceptual_roughness: 0.85,
                metallic: 0.0,
                alpha: "{}",
            )"#,
            a.alpha
        )
    } else {
        format!(
            r#"Raw(
                source: Param("shader"),
                data: Param("data"),
                textures: Param("textures"),
                alpha: "{}",
                vertex: {},
            )"#,
            a.alpha, a.vertex
        )
    };

    format!(
        r#"// Generated by arbor-shader-render.
(
    id: "shader_render",
    name: "Shader render",
    description: "One material, one mesh, rendered once.",

    camera: Orbit(
        distance: Single({dist}),
        pitch: {pitch},
        auto_spin: None,
        fov: None,
    ),

    environment: (
        background: ({br}, {bg}, {bb}),
        ambient: 0.14,
        checker: {checker},
    ),

    lights: [
        Directional(
            direction: (-0.45, -0.72, -0.52),
            color: (1.0, 0.96, 0.90),
            illuminance: 11000.0,
        ),
        Directional(
            direction: (0.62, -0.25, 0.74),
            color: (0.55, 0.66, 0.85),
            illuminance: 2600.0,
        ),
    ],

    entities: [
        (
            mesh: Param("mesh"),
            material: {material},
            position: (0.0, 0.0, 0.0),
            scale: 1.0,
            spin: 0.0,
        ),
    ],

    controls: [],
)
"#,
        dist = num(a.distance),
        pitch = num(a.pitch),
        br = num(a.background.0),
        bg = num(a.background.1),
        bb = num(a.background.2),
        checker = a.checker,
        material = material,
    )
}

fn primitive_name(mesh: &str) -> &'static str {
    match mesh {
        "cube" => "Cube",
        "plane" => "Plane",
        "torus" => "Torus",
        "capsule" => "Capsule",
        "cylinder" => "Cylinder",
        _ => "Sphere",
    }
}

/// The values the document's `Param(...)` slots read.
fn params_for(a: &Args, source: String) -> serde_json::Value {
    let mut p = serde_json::json!({
        "shader": source,
        "mesh": { "Primitive": primitive_name(&a.mesh) },
        "textures": a.textures,
    });

    if a.extension {
        // One `vec4` hole per binding from 100 up, filled from the flat list in order; a
        // shader declaring fewer simply never reads the rest. All of them are supplied whether
        // or not the shader wants them: a hole the document names and nobody fills is a scene
        // that will not build.
        // One SLOT per binding, and a slot is 512 bytes rather than a `vec4` — a material
        // extension is free to bind a struct or an `array<vec4<f32>, 32>` at 100, and reading
        // four floats per slot put everything past the first `vec4` into the next binding.
        const STRIDE: usize = arbor_bevy_runtime::EXT_SLOT_FLOATS;
        for slot in 0..arbor_bevy_runtime::EXT_SLOTS {
            let start = slot * STRIDE;
            let end = (start + STRIDE).min(a.data.len());
            let mut v: Vec<f32> =
                if start < end { a.data[start..end].to_vec() } else { Vec::new() };
            // Trailing zeros are dropped and the slot padded to a `vec4`: the runtime fills the
            // rest with zeros anyway, and a document carrying 128 numbers per binding when four
            // were meant is a command line nobody can read.
            while v.len() > 4 && v.last() == Some(&0.0) {
                v.pop();
            }
            while v.len() < 4 {
                v.push(0.0);
            }
            p[format!("p{slot}")] = serde_json::json!(v);
        }
    } else {
        p["data"] = serde_json::json!(a.data);
    }
    p
}

// ── The run ─────────────────────────────────────────────────────────────────────

fn main() {
    let args = match parse_args() {
        Ok(a) => a,
        Err(e) => {
            eprintln!("arbor-shader-render: {e}");
            std::process::exit(2);
        }
    };

    let shader_path = args.shader.clone().unwrap();
    let source = match std::fs::read_to_string(&shader_path) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("arbor-shader-render: cannot read {}: {e}", shader_path.display());
            std::process::exit(2);
        }
    };

    let job = Job {
        doc: scene_ron(&args),
        params: params_for(&args, source),
        out: args.out.clone().unwrap(),
        width: args.width,
        height: args.height,
        time: args.time,
    };

    App::new()
        .insert_resource(job)
        .insert_resource(Phase::Warmup(WARMUP_FRAMES))
        .add_plugins(
            DefaultPlugins
                .set(WindowPlugin {
                    // No window at all: the camera draws into an image instead. `DontExit`
                    // because the app would otherwise stop the moment it noticed it has no
                    // windows, which here is immediately.
                    primary_window: None,
                    exit_condition: ExitCondition::DontExit,
                    ..default()
                })
                // Panics on a machine with no display server, and there is nothing for it to
                // do here anyway.
                .disable::<WinitPlugin>(),
        )
        .init_resource::<RoleImages>()
        .add_plugins(MaterialPlugin::<PreviewMaterial>::default())
        .add_plugins(MaterialPlugin::<RawMaterial>::default())
        .add_plugins(MaterialPlugin::<RawVertexMaterial>::default())
        .add_plugins(MaterialPlugin::<CheckerMaterial>::default())
        // Replaces winit's runner, which is what makes a windowless app tick at all.
        .add_plugins(ScheduleRunnerPlugin::run_loop(Duration::from_secs_f64(1.0 / 60.0)))
        .add_systems(Startup, setup)
        .add_systems(Update, (attach_target, pin_time, drive).chain())
        .run();
}

fn setup(
    mut commands: Commands,
    job: Res<Job>,
    mut images: ResMut<Assets<Image>>,
    mut meshes: ResMut<Assets<Mesh>>,
    mut materials: ResMut<Assets<PreviewMaterial>>,
    mut raw_materials: ResMut<Assets<RawMaterial>>,
    mut raw_vertex_materials: ResMut<Assets<RawVertexMaterial>>,
    mut checker_materials: ResMut<Assets<CheckerMaterial>>,
    mut shaders: ResMut<Assets<Shader>>,
    mut roles: ResMut<RoleImages>,
) {
    // `Rgba8UnormSrgb` as the view format so what lands in the PNG is what a screen would
    // show — rendering linear and writing the bytes raw is the classic way to produce an
    // image that is uniformly too dark.
    let image = Image::new_target_texture(
        job.width,
        job.height,
        TextureFormat::Rgba8Unorm,
        Some(TextureFormat::Rgba8UnormSrgb),
    );
    let handle = images.add(image);
    commands.insert_resource(Target(handle));

    let doc = match SceneDoc::parse(&job.doc) {
        Ok(d) => d,
        Err(e) => {
            eprintln!("arbor-shader-render: the generated scene did not parse: {e}");
            std::process::exit(3);
        }
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
    if let Err(e) = build(&mut commands, &doc, &job.params, &mut assets, None) {
        eprintln!("arbor-shader-render: {e}");
        std::process::exit(3);
    }
}

/// Marks a camera that has already been pointed at the image.
///
/// Its own component rather than `Without<RenderTarget>`, which is what this used to be and is
/// the reason every render came out **black**: `Camera` lists `RenderTarget` among its required
/// components, so a camera always has one — pointed at the primary window, which here does not
/// exist. The filter therefore matched nothing, the image was never attached, and the capture
/// dutifully saved an untouched texture. Nothing failed anywhere, which is why it was silent.
#[derive(Component)]
struct Targeted;

/// Point the scene's camera at the image.
///
/// A frame later than `setup`, because `build` spawns the camera through `Commands` and the
/// entity does not exist until those are applied.
fn attach_target(
    mut commands: Commands,
    target: Option<Res<Target>>,
    cameras: Query<Entity, (With<Camera>, Without<Targeted>)>,
) {
    let Some(target) = target else { return };
    for cam in cameras.iter() {
        commands
            .entity(cam)
            .insert((RenderTarget::Image(target.0.clone().into()), Targeted));
    }
}

/// Pin the clock, so the same arguments produce the same image.
///
/// `globals.time` in a shader comes from the default clock, which follows virtual time — so
/// advancing virtual time once and pausing it is what freezes an animated material at a chosen
/// instant. Without this, "render this shader" would answer differently every call and two
/// parameter sets could never be compared.
fn pin_time(job: Res<Job>, mut virtual_time: ResMut<Time<Virtual>>) {
    if virtual_time.is_paused() {
        return;
    }
    let target = Duration::from_secs_f32(job.time.max(0.0));
    let now = virtual_time.elapsed();
    if target > now {
        virtual_time.advance_by(target - now);
    }
    virtual_time.pause();
}

/// Warm up, capture, drain, exit.
fn drive(
    mut commands: Commands,
    job: Res<Job>,
    target: Option<Res<Target>>,
    mut phase: ResMut<Phase>,
    mut exit: MessageWriter<AppExit>,
) {
    match &mut *phase {
        Phase::Warmup(left) => {
            if *left > 0 {
                *left -= 1;
                return;
            }
            let Some(target) = target else { return };
            commands
                .spawn(Screenshot::image(target.0.clone()))
                .observe(save_to_disk(job.out.clone()));
            *phase = Phase::Capturing(DRAIN_FRAMES);
        }
        Phase::Capturing(left) => {
            if *left > 0 {
                *left -= 1;
                return;
            }
            // The observer writes the file synchronously when it fires; the drain is for the
            // frames between asking and it firing. Whether the file is actually there is the
            // caller's check, not a guess made here.
            exit.write(AppExit::Success);
        }
    }
}
