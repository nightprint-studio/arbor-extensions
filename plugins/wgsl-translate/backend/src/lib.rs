//! WGSL shader preview, as an Arbor extension.
//!
//! Implements `arbor:extensions/shader-preview@1` — given a `.wgsl` file and the modules it
//! imports, produce GLSL ES 3.00 a canvas can compile, plus a list of what has to be fed into
//! it.
//!
//! ## No GPU here
//!
//! A wasm guest cannot rasterize, and this does not try. It does the CPU half — preprocess,
//! parse, validate, translate — and hands back source. The drawing happens in the host's
//! canvas, which is the only place a GPU is.
//!
//! That split is the reason this is a package. Translating a shading language wants `naga`;
//! Arbor carrying `naga` for everybody, to serve the people who write shaders, is the trade
//! that installing this avoids.
//!
//! ## Bevy
//!
//! A material shader written for Bevy imports its frame — `pbr_input_from_standard_material`
//! in, `apply_pbr_lighting` out — and that frame is a renderer. It is replaced here by
//! `bevy_shim.wgsl`, a small stand-in, and **the result carries a warning saying so**. The
//! lighting is not Bevy's. What it shows is everything between the first line and the last
//! three, which in a material shader is all of the author's own work.
//!
//! A shader that is already self-contained imports nothing and gets no shim and no warning.

wit_bindgen::generate!({
    path: "../../../wit",
    world: "shader-preview-world",
});

use exports::arbor::extensions::shader_preview::{BackendInfo, Guest};
#[cfg(target_arch = "wasm32")]
use arbor::extensions::log::Level;
use arbor::extensions::preview_types::{
    AttributeRole, AttributeSlot, BindingRole, Dialect, Error, Prepared, SourceFile, UniformSlot,
    ValueKind,
};

/// The Bevy frame, as something translatable. See the file for what it does and does not do.
const BEVY_SHIM: &str = include_str!("bevy_shim.wgsl");

/// Log through the host, when there is one.
///
/// The generated import is `unreachable!()` on any target that is not wasm, so calling it
/// straight would mean the translation could only ever be tested inside a component — which
/// is the one place a failure is hardest to read.
fn log(message: &str) {
    #[cfg(target_arch = "wasm32")]
    arbor::extensions::log::write(Level::Debug, message);
    #[cfg(not(target_arch = "wasm32"))]
    let _ = message;
}

/// Entry point names the shim supplies.
const SHIM_VERTEX: &str = "preview_vertex";

struct Component;

// ── Preprocessing ───────────────────────────────────────────────────────────────

/// What the preprocessor learned on its way through.
struct Preprocessed {
    source:   String,
    warnings: Vec<String>,
    /// Whether the shim was spliced in — which is also whether the lighting is a stand-in.
    shimmed:  bool,
}

/// Is this an import of Bevy's own shader library?
fn is_bevy(path: &str) -> bool {
    path.starts_with("bevy_")
}

/// Strip `#import` lines, splice in what they referred to, and substitute `#{…}`.
///
/// Textual rather than a real module system on purpose: naga_oil is what Bevy uses and it is
/// a large dependency that resolves against a shader library this does not have. What is
/// needed here is narrower — pull in the modules the host already read, and stand in for
/// Bevy's — and doing that textually keeps the failure modes visible.
fn preprocess(entry: &SourceFile, modules: &[SourceFile], defines: &[String]) -> Preprocessed {
    let mut warnings = Vec::new();
    let mut prelude = String::new();
    let mut body = String::new();
    let mut shimmed = false;
    let mut missing: Vec<String> = Vec::new();

    // `#import a::{b, c}` can span several lines. Rather than parse the grammar, the scan
    // tracks brace depth from the `#import` until it closes — which is all the shape a WGSL
    // import can take.
    let mut depth = 0usize;
    let mut in_import = false;
    let mut import_head = String::new();

    for line in entry.text.lines() {
        let trimmed = line.trim_start();

        if !in_import && trimmed.starts_with("#import") {
            in_import = true;
            import_head.clear();
            import_head.push_str(trimmed);
            depth = braces(trimmed);
            if depth == 0 {
                finish_import(&import_head, modules, &mut prelude, &mut shimmed, &mut missing);
                in_import = false;
            }
            continue;
        }
        if in_import {
            import_head.push(' ');
            import_head.push_str(trimmed);
            depth = depth.saturating_add(braces_open(trimmed)) - braces_close(trimmed).min(depth);
            if depth == 0 {
                finish_import(&import_head, modules, &mut prelude, &mut shimmed, &mut missing);
                in_import = false;
            }
            continue;
        }

        // `#{MATERIAL_BIND_GROUP}` and friends: naga_oil substitutions Bevy resolves at load
        // time. The value does not matter for a preview — every uniform ends up in one block
        // — but leaving the token in place is a parse error four lines later that blames the
        // wrong thing.
        body.push_str(&substitute(line));
        body.push('\n');
    }

    for name in &missing {
        warnings.push(format!(
            "`{name}` was imported but not supplied — anything it declared is missing"
        ));
    }
    if shimmed {
        warnings.push(
            "Bevy's lighting is a stand-in: one directional light, Blinn-Phong specular and \
             Reinhard tonemapping. Shape, bump and colour read correctly; the exact shading \
             does not match a Bevy frame."
                .to_string(),
        );
    }
    for d in defines {
        // `#ifdef` handling is not implemented; saying so beats quietly previewing the wrong
        // branch of a shader the author is actively toggling.
        warnings.push(format!("`{d}` was requested but #ifdef is not resolved by this backend"));
    }

    let mut source = String::new();
    if shimmed {
        source.push_str(BEVY_SHIM);
        source.push('\n');
    }
    source.push_str(&prelude);
    source.push_str(&body);
    Preprocessed { source, warnings, shimmed }
}

fn braces(s: &str) -> usize {
    braces_open(s).saturating_sub(braces_close(s))
}
fn braces_open(s: &str) -> usize {
    s.matches('{').count()
}
fn braces_close(s: &str) -> usize {
    s.matches('}').count()
}

/// Act on one complete `#import …` statement.
fn finish_import(
    stmt: &str,
    modules: &[SourceFile],
    prelude: &mut String,
    shimmed: &mut bool,
    missing: &mut Vec<String>,
) {
    // `#import bevy_pbr::{a::b, c}` → the root is what identifies the module.
    let rest = stmt.trim_start_matches("#import").trim();
    let root = rest
        .split("::")
        .next()
        .unwrap_or(rest)
        .split(|c: char| c.is_whitespace() || c == '{' || c == ',')
        .next()
        .unwrap_or("")
        .trim();
    if root.is_empty() {
        return;
    }
    if is_bevy(root) {
        *shimmed = true;
        return;
    }
    // A project's own module: spliced in whole, once, in the order the imports appeared.
    match modules.iter().find(|m| m.path == root || m.path.starts_with(&format!("{root}::"))) {
        Some(m) => {
            if !prelude.contains(&m.text) {
                prelude.push_str(&substitute(&m.text));
                prelude.push('\n');
            }
        }
        None => {
            if !missing.iter().any(|s| s == root) {
                missing.push(root.to_string());
            }
        }
    }
}

/// Replace naga_oil's `#{NAME}` substitutions.
///
/// Every one becomes `2`, which is a legal bind-group index and is never read: the translated
/// output has one uniform block regardless. Getting the number "right" would mean modelling a
/// binding layout the target does not have.
fn substitute(line: &str) -> String {
    let mut out = String::with_capacity(line.len());
    let mut rest = line;
    while let Some(start) = rest.find("#{") {
        out.push_str(&rest[..start]);
        match rest[start..].find('}') {
            Some(end) => {
                out.push('2');
                rest = &rest[start + end + 1..];
            }
            None => {
                out.push_str(&rest[start..]);
                return out;
            }
        }
    }
    out.push_str(rest);
    out
}

// ── Roles ───────────────────────────────────────────────────────────────────────

/// Map a uniform's name onto a role the host knows how to fill.
///
/// A convention, and this backend's own — which is why `describe` publishes it. The host is
/// told what to put where by the answer, not by knowing what a shader is.
fn role_of(name: &str) -> BindingRole {
    // The GLSL backend mangles a struct-typed global's name; matching on a suffix keeps the
    // convention working after `globals` becomes `_group_0_binding_0_fs`.
    let n = name.to_ascii_lowercase();
    if n.contains("view_projection") {
        BindingRole::Projection
    } else if n.contains("model") {
        BindingRole::Model
    } else if n.contains("camera_position") {
        BindingRole::CameraPosition
    } else if n.contains("light_direction") {
        BindingRole::LightDirection
    } else if n.contains("resolution") {
        BindingRole::Resolution
    } else if n.contains("pointer") || n.contains("mouse") {
        BindingRole::Pointer
    } else if n.contains("globals") || n == "time" {
        BindingRole::Time
    } else {
        BindingRole::Custom
    }
}

fn kind_of(inner: &naga::TypeInner) -> ValueKind {
    use naga::{ScalarKind, TypeInner, VectorSize};
    match inner {
        TypeInner::Scalar(s) => match s.kind {
            ScalarKind::Float => ValueKind::F32Scalar,
            ScalarKind::Bool => ValueKind::Boolean,
            _ => ValueKind::I32Scalar,
        },
        TypeInner::Vector { size, .. } => match size {
            VectorSize::Bi => ValueKind::Vec2,
            VectorSize::Tri => ValueKind::Vec3,
            VectorSize::Quad => ValueKind::Vec4,
        },
        TypeInner::Matrix { columns, .. } => match columns {
            VectorSize::Tri => ValueKind::Mat3,
            _ => ValueKind::Mat4,
        },
        // A struct-typed uniform block is uploaded field by field by the host, which reads the
        // role rather than the size; vec4 is the widest thing it will send for one name.
        _ => ValueKind::Vec4,
    }
}

fn default_for(kind: ValueKind) -> &'static str {
    match kind {
        ValueKind::F32Scalar => "0",
        ValueKind::I32Scalar => "0",
        ValueKind::Boolean => "false",
        ValueKind::Vec2 => "[0,0]",
        ValueKind::Vec3 => "[0,0,0]",
        ValueKind::Vec4 => "[0,0,0,1]",
        ValueKind::Mat3 => "[1,0,0, 0,1,0, 0,0,1]",
        ValueKind::Mat4 => "[1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1]",
    }
}

// ── Translation ─────────────────────────────────────────────────────────────────

/// Pick the entry point of a stage, preferring a name.
fn entry_index(module: &naga::Module, stage: naga::ShaderStage, prefer: Option<&str>) -> Option<usize> {
    if let Some(want) = prefer {
        if let Some(i) = module
            .entry_points
            .iter()
            .position(|e| e.stage == stage && e.name == want)
        {
            return Some(i);
        }
    }
    module.entry_points.iter().position(|e| e.stage == stage)
}

fn write_stage(
    module: &naga::Module,
    info: &naga::valid::ModuleInfo,
    entry: &str,
    stage: naga::ShaderStage,
) -> Result<(String, naga::back::glsl::ReflectionInfo), Error> {
    use naga::back::glsl;

    let options = glsl::Options {
        version: glsl::Version::Embedded { version: 300, is_webgl: true },
        ..Default::default()
    };
    let pipeline_options = glsl::PipelineOptions {
        shader_stage: stage,
        entry_point: entry.to_string(),
        multiview: None,
    };

    let mut buffer = String::new();
    let mut writer = glsl::Writer::new(
        &mut buffer,
        module,
        info,
        &options,
        &pipeline_options,
        naga::proc::BoundsCheckPolicies::default(),
    )
    .map_err(|e| Error::Unsupported(format!("{stage:?}: {e}")))?;
    let reflection = writer
        .write()
        .map_err(|e| Error::Unsupported(format!("{stage:?}: {e}")))?;
    Ok((buffer, reflection))
}

impl Guest for Component {
    fn describe() -> BackendInfo {
        BackendInfo {
            extensions: vec!["wgsl".to_string()],
            label: "WGSL (naga → WebGL2)".to_string(),
            dialect: Dialect::GlslEs3,
            // Not resolved, but published so a panel can offer them and this backend can say
            // in a warning that it ignored them.
            known_defines: Vec::new(),
        }
    }

    fn prepare(
        entry: SourceFile,
        modules: Vec<SourceFile>,
        defines: Vec<String>,
    ) -> Result<Prepared, Error> {
        let pre = preprocess(&entry, &modules, &defines);
        log(&format!(
            "preparing {} ({} bytes after preprocessing)",
            entry.path,
            pre.source.len()
        ));

        let module = naga::front::wgsl::parse_str(&pre.source).map_err(|e| {
            // The message carries the location naga found, which is in the preprocessed text
            // — offset by the shim when one was spliced in. Said plainly rather than reported
            // as a line number that does not match the file on screen.
            Error::Parse((
                format!(
                    "{}{}",
                    e.emit_to_string(&pre.source),
                    if pre.shimmed {
                        "\n(line numbers include the substituted Bevy frame)"
                    } else {
                        ""
                    }
                ),
                None,
            ))
        })?;

        let info = naga::valid::Validator::new(
            naga::valid::ValidationFlags::all(),
            naga::valid::Capabilities::empty(),
        )
        .validate(&module)
        .map_err(|e| Error::Unsupported(e.emit_to_string(&pre.source)))?;

        let vertex_i = entry_index(&module, naga::ShaderStage::Vertex, Some(SHIM_VERTEX))
            .ok_or_else(|| {
                Error::Unsupported(
                    "no @vertex entry point, and no Bevy import to supply one".to_string(),
                )
            })?;
        let fragment_i = entry_index(&module, naga::ShaderStage::Fragment, None)
            .ok_or_else(|| Error::Unsupported("no @fragment entry point".to_string()))?;

        let v_name = module.entry_points[vertex_i].name.clone();
        let f_name = module.entry_points[fragment_i].name.clone();

        let (vertex, v_refl) = write_stage(&module, &info, &v_name, naga::ShaderStage::Vertex)?;
        let (fragment, f_refl) = write_stage(&module, &info, &f_name, naga::ShaderStage::Fragment)?;

        // Uniforms from both stages, deduplicated by the name the GL program will use.
        let mut uniforms: Vec<UniformSlot> = Vec::new();
        for refl in [&v_refl, &f_refl] {
            for (handle, name) in refl.uniforms.iter() {
                if uniforms.iter().any(|u| &u.name == name) {
                    continue;
                }
                let global = &module.global_variables[*handle];
                let inner = &module.types[global.ty].inner;
                let kind = kind_of(inner);
                let declared = global.name.clone().unwrap_or_default();
                uniforms.push(UniformSlot {
                    name: name.clone(),
                    kind,
                    // The role comes from the name the AUTHOR wrote, not the mangled one.
                    role: role_of(&declared),
                    default_value: default_for(kind).to_string(),
                    label: declared,
                });
            }
        }

        // The vertex stage's inputs, by the location the translated source assigned.
        let attributes = vec![
            AttributeSlot { name: "position".into(), location: 0, role: AttributeRole::Position, components: 3 },
            AttributeSlot { name: "normal".into(),   location: 1, role: AttributeRole::Normal,   components: 3 },
            AttributeSlot { name: "uv".into(),       location: 2, role: AttributeRole::Uv,       components: 2 },
        ];

        Ok(Prepared {
            dialect: Dialect::GlslEs3,
            vertex,
            fragment,
            uniforms,
            attributes,
            warnings: pre.warnings,
        })
    }
}

export!(Component);

#[cfg(test)]
mod tests {
    use super::*;

    fn file(path: &str, text: &str) -> SourceFile {
        SourceFile { path: path.into(), text: text.into() }
    }

    #[test]
    fn a_naga_oil_substitution_becomes_something_that_parses() {
        // Left in place it is a syntax error several lines later, blaming the wrong line.
        assert_eq!(
            substitute("@group(#{MATERIAL_BIND_GROUP}) @binding(100)"),
            "@group(2) @binding(100)"
        );
        assert_eq!(substitute("no substitutions here"), "no substitutions here");
        // An unterminated one is left alone rather than eating the rest of the line.
        assert_eq!(substitute("broken #{OPEN"), "broken #{OPEN");
    }

    #[test]
    fn a_bevy_import_pulls_in_the_shim_and_says_so() {
        let src = "#import bevy_pbr::{ forward_io::VertexOutput }\n@fragment fn f() {}\n";
        let pre = preprocess(&file("s.wgsl", src), &[], &[]);
        assert!(pre.shimmed);
        assert!(pre.source.contains("fn apply_pbr_lighting"));
        // The warning is the whole reason a stand-in is acceptable.
        assert!(pre.warnings.iter().any(|w| w.contains("stand-in")), "{:?}", pre.warnings);
        assert!(!pre.source.contains("#import"));
    }

    #[test]
    fn a_multi_line_import_block_is_consumed_whole() {
        // The real shaders write it across five lines; stopping at the first would leave
        // `pbr_functions::…,` in the body as a syntax error.
        let src = "#import bevy_pbr::{\n  a::b,\n  c::{d, e},\n}\n\nfn keep() {}\n";
        let pre = preprocess(&file("s.wgsl", src), &[], &[]);
        assert!(!pre.source.contains("a::b"), "{}", pre.source);
        assert!(pre.source.contains("fn keep()"));
    }

    #[test]
    fn a_projects_own_module_is_spliced_in_once() {
        let src = "#import myapp::noise\n#import myapp::noise\nfn f() {}\n";
        let modules = vec![file("myapp", "fn hash() -> f32 { return 0.5; }")];
        let pre = preprocess(&file("s.wgsl", src), &modules, &[]);
        assert!(!pre.shimmed);
        assert_eq!(pre.source.matches("fn hash()").count(), 1);
    }

    #[test]
    fn an_import_nobody_supplied_is_named_in_a_warning() {
        // Silence here becomes "unknown identifier" from naga, which blames the use site.
        let pre = preprocess(&file("s.wgsl", "#import myapp::gone\nfn f() {}\n"), &[], &[]);
        assert!(pre.warnings.iter().any(|w| w.contains("myapp")), "{:?}", pre.warnings);
    }

    #[test]
    fn a_self_contained_shader_gets_no_shim_and_no_warning() {
        let pre = preprocess(&file("s.wgsl", "@fragment fn f() {}\n"), &[], &[]);
        assert!(!pre.shimmed);
        assert!(pre.warnings.is_empty());
        assert!(!pre.source.contains("apply_pbr_lighting"));
    }

    /// A Bevy material shader in miniature: the import block, a `#{}` substitution, a
    /// material parameter, and the three calls that make up the frame. Written here rather
    /// than copied from a real project — this has to be readable in the failure output.
    const BEVY_SHAPED: &str = r#"
#import bevy_pbr::{
    pbr_fragment::pbr_input_from_standard_material,
    pbr_functions::{apply_pbr_lighting, main_pass_post_lighting_processing},
    pbr_types::STANDARD_MATERIAL_FLAGS_UNLIT_BIT,
    forward_io::{VertexOutput, FragmentOutput},
}

@group(#{MATERIAL_BIND_GROUP}) @binding(100)
var<uniform> rock_params: vec4<f32>;

fn hash13(p: vec3<f32>) -> f32 {
    var q = fract(p * 0.1031);
    q += dot(q, q.zyx + 31.32);
    return fract((q.x + q.y) * q.z);
}

@fragment
fn fragment(in: VertexOutput, @builtin(front_facing) is_front: bool) -> FragmentOutput {
    var pbr_input = pbr_input_from_standard_material(in, is_front);
    let wp = in.world_position.xyz;
    let n = hash13(wp * rock_params.x);
    pbr_input.material.base_color = vec4<f32>(pbr_input.material.base_color.rgb * n, 1.0);
    pbr_input.material.perceptual_roughness = mix(0.4, 1.0, n);
    pbr_input.N = normalize(pbr_input.N + vec3<f32>(n * rock_params.z));
    var out: FragmentOutput;
    if ((pbr_input.material.flags & STANDARD_MATERIAL_FLAGS_UNLIT_BIT) == 0u) {
        out.color = apply_pbr_lighting(pbr_input);
    } else {
        out.color = pbr_input.material.base_color;
    }
    out.color = main_pass_post_lighting_processing(pbr_input, out.color);
    return out;
}
"#;

    #[test]
    fn a_bevy_material_shader_translates_end_to_end() {
        // The one that matters: import block consumed, substitution replaced, shim spliced,
        // parsed, validated, and both stages written as GLSL a WebGL2 context will take.
        let out = Component::prepare(file("stone.wgsl", BEVY_SHAPED), Vec::new(), Vec::new())
            .expect("a Bevy-shaped material should translate");

        assert!(matches!(out.dialect, Dialect::GlslEs3));
        assert!(out.vertex.contains("#version 300 es"), "{}", &out.vertex[..80.min(out.vertex.len())]);
        assert!(out.fragment.contains("#version 300 es"));
        // The author's own function survived the round trip — if the shim had swallowed it,
        // the preview would be showing the stand-in and nothing else.
        assert!(out.fragment.contains("hash13"), "the author's code is missing from the output");
        // And the warning that keeps the stand-in honest.
        assert!(out.warnings.iter().any(|w| w.contains("stand-in")));

        // The material's own parameter is offered as a control; the frame's uniforms are not.
        assert!(
            out.uniforms.iter().any(|u| u.label == "rock_params"
                && matches!(u.role, BindingRole::Custom)),
            "rock_params should be a custom slot, got {:?}",
            out.uniforms.iter().map(|u| (&u.label, &u.role)).collect::<Vec<_>>()
        );
        assert!(out.uniforms.iter().any(|u| matches!(u.role, BindingRole::Model)));
        assert_eq!(out.attributes.len(), 3);
    }

    #[test]
    fn a_shader_with_no_fragment_stage_is_refused_by_name() {
        let e = Component::prepare(file("s.wgsl", "@vertex fn v() -> @builtin(position) vec4<f32> { return vec4<f32>(0.0); }"), Vec::new(), Vec::new())
            .unwrap_err();
        assert!(matches!(e, Error::Unsupported(ref m) if m.contains("@fragment")), "{e:?}");
    }

    #[test]
    fn a_syntax_error_comes_back_as_a_parse_error_and_not_a_panic() {
        let e = Component::prepare(file("s.wgsl", "@fragment fn ("), Vec::new(), Vec::new()).unwrap_err();
        assert!(matches!(e, Error::Parse(_)), "{e:?}");
    }

    #[test]
    fn roles_come_from_the_name_the_author_wrote() {
        assert!(matches!(role_of("globals"), BindingRole::Time));
        assert!(matches!(role_of("view_projection"), BindingRole::Projection));
        assert!(matches!(role_of("model"), BindingRole::Model));
        assert!(matches!(role_of("camera_position"), BindingRole::CameraPosition));
        // A material's own parameters are the caller's to control.
        assert!(matches!(role_of("rock_params"), BindingRole::Custom));
    }
}

/// Translate a shader from disk, for checking this against real material shaders without
/// copying anybody's project into this repo.
///
/// ```sh
/// ARBOR_SHADER_FIXTURE=/path/to/stone.wgsl cargo test -p shader-preview-backend -- --ignored --nocapture
/// ```
#[cfg(test)]
mod real_files {
    use super::*;

    #[test]
    #[ignore = "needs ARBOR_SHADER_FIXTURE"]
    fn a_real_shader_translates() {
        let path = std::env::var("ARBOR_SHADER_FIXTURE").expect("set ARBOR_SHADER_FIXTURE");
        let text = std::fs::read_to_string(&path).expect("unreadable fixture");
        match Component::prepare(SourceFile { path: path.clone(), text }, Vec::new(), Vec::new()) {
            Ok(p) => {
                println!("--- {path}");
                println!("vertex   {} bytes", p.vertex.len());
                println!("fragment {} bytes", p.fragment.len());
                for u in &p.uniforms {
                    println!("uniform  {} ({:?}) role {:?}", u.label, u.kind, u.role);
                }
                for w in &p.warnings {
                    println!("warning  {w}");
                }
                assert!(p.fragment.contains("#version 300 es"));
            }
            Err(e) => panic!("{path} did not translate: {e:?}"),
        }
    }
}

