//! The images a preview puts in a texture slot when nobody has an asset to give it.
//!
//! ## Why not just white
//!
//! Because a texture slot is never *neutral*. A material samples a texture and then treats
//! what came back as a particular kind of fact: an albedo, a normal in tangent space, a height,
//! an ambient occlusion mask. Flat white is a correct albedo, a normal pointing along
//! `(1,1,1)`, a surface displaced to its maximum, and an unoccluded mask — three of which are
//! wrong, and wrong in a way that reads as the *shader* being broken rather than the input
//! being absent. A preview that shows a working material as broken is worse than one that
//! refuses.
//!
//! So a slot is filled by **role**, and the role comes from the variable's name — `top_normal`
//! gets a flat normal, `side_height` gets mid grey, `top_ao` gets white. The naming is already
//! there in every material anybody writes; this just reads it. `// @preview <role>` above the
//! declaration overrides the guess.
//!
//! ## Why generated and not shipped
//!
//! A viewer that shipped its own PNGs would have to decode them, which means an image decoder
//! in a wasm bundle that already travels over a network on install. These are a handful of
//! bytes each, computed once, and `checker` and `noise` are the only two that are not a single
//! pixel.

use bevy::asset::RenderAssetUsages;
use bevy::image::Image;
use bevy::render::render_resource::{
    Extent3d, TextureDimension, TextureFormat, TextureViewDescriptor, TextureViewDimension,
};

/// The side of the generated patterns, in pixels.
///
/// Small on purpose. A chequer is there to show where the UVs go and a noise field to give a
/// normal map something to bite on; neither is improved by being 512 across, and both are
/// uploaded on every rebuild.
const PATTERN: u32 = 64;

/// What the slot is for.
///
/// The names are the contract with whoever fills the slot list — Arbor's `bennu-wgsl` picks
/// one from the variable's name, and a panel offers the same words in a dropdown. An
/// unrecognised name is [`Role::Neutral`] rather than an error: a preview that refused to open
/// because of a typo in a texture role would be trading a picture for a spelling.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Role {
    White,
    Black,
    Grey,
    Normal,
    Checker,
    Noise,
    Uv,
    /// Nothing was said. White — the least surprising thing to multiply by.
    Neutral,
}

impl Role {
    pub fn named(name: &str) -> Self {
        match name.trim().to_ascii_lowercase().as_str() {
            "white" => Self::White,
            "black" => Self::Black,
            "grey" | "gray" => Self::Grey,
            "normal" => Self::Normal,
            "checker" | "checkerboard" => Self::Checker,
            "noise" => Self::Noise,
            "uv" => Self::Uv,
            _ => Self::Neutral,
        }
    }

    /// Whether the values in this image are a **colour** or a **measurement**.
    ///
    /// The distinction is the whole reason both formats exist. A GPU decodes an sRGB texture
    /// to linear on the way in, which is right for something the eye is meant to look at and
    /// wrong for everything else: a normal map decoded that way has its `0.5` turned into
    /// `0.21`, and every surface tilts. Getting this backwards is invisible in a thumbnail and
    /// obvious under a light.
    fn is_colour(self) -> bool {
        matches!(self, Self::Checker | Self::Uv)
    }
}

/// The image for one role, with `layers` array layers.
///
/// `layers` is 1 for an ordinary 2D texture, 6 for a cube, and whatever an array texture
/// wants. The pattern is identical on every layer: a preview with no assets has nothing to
/// vary between them, and six different chequers would look like meaning where there is none.
pub fn image_for(role: Role, layers: u32) -> Image {
    let format = if role.is_colour() {
        TextureFormat::Rgba8UnormSrgb
    } else {
        TextureFormat::Rgba8Unorm
    };
    let layers = layers.max(1);

    let (size, data) = match role {
        Role::Checker => (PATTERN, checker()),
        Role::Noise => (PATTERN, noise()),
        Role::Uv => (PATTERN, uv()),
        flat => (1, flat_pixel(flat).to_vec()),
    };

    // One layer's worth, repeated. `new_fill` would do this for a single pixel and not for a
    // pattern, so it is done the same way for both rather than two ways for one idea.
    let mut all = Vec::with_capacity(data.len() * layers as usize);
    for _ in 0..layers {
        all.extend_from_slice(&data);
    }

    let mut image = Image::new(
        Extent3d { width: size, height: size, depth_or_array_layers: layers },
        TextureDimension::D2,
        all,
        format,
        RenderAssetUsages::RENDER_WORLD,
    );
    // A texture with six layers is not a cube until the VIEW says so, and the layout entry
    // this fills declares `TextureViewDimension::Cube`. Without the descriptor the view comes
    // back as a 2D array and wgpu refuses the bind group — the same class of mismatch this
    // whole scheme exists to avoid, one level down.
    if layers == 6 {
        image.texture_view_descriptor = Some(TextureViewDescriptor {
            dimension: Some(TextureViewDimension::Cube),
            ..Default::default()
        });
    } else if layers > 1 {
        image.texture_view_descriptor = Some(TextureViewDescriptor {
            dimension: Some(TextureViewDimension::D2Array),
            ..Default::default()
        });
    }
    image
}

fn flat_pixel(role: Role) -> [u8; 4] {
    match role {
        Role::Black => [0, 0, 0, 255],
        Role::Grey => [128, 128, 128, 255],
        // `(0.5, 0.5, 1.0)` — the tangent-space normal that means "no perturbation". The one
        // value that makes a normal-mapped material look like the material without the map,
        // which is exactly what an absent map should mean.
        Role::Normal => [128, 128, 255, 255],
        _ => [255, 255, 255, 255],
    }
}

fn checker() -> Vec<u8> {
    const CELL: u32 = 8;
    let mut out = Vec::with_capacity((PATTERN * PATTERN * 4) as usize);
    for y in 0..PATTERN {
        for x in 0..PATTERN {
            let odd = ((x / CELL) + (y / CELL)) % 2 == 1;
            // Two mid greys rather than black and white: a material multiplies its albedo by
            // this, and a black square would make half the surface unlit and unreadable.
            let v = if odd { 96 } else { 200 };
            out.extend_from_slice(&[v, v, v, 255]);
        }
    }
    out
}

/// Value noise, smoothed, from a hash of the coordinates.
///
/// Hashed rather than sampled from a generator so it is the same every run and the same on
/// every machine: a preview whose noise changed between two screenshots would make every
/// comparison useless, which is most of what a preview is for.
fn noise() -> Vec<u8> {
    fn hash(x: i32, y: i32) -> f32 {
        let mut h = (x as u32).wrapping_mul(0x27d4_eb2d) ^ (y as u32).wrapping_mul(0x1656_67b1);
        h ^= h >> 15;
        h = h.wrapping_mul(0x2545_f491);
        h ^= h >> 13;
        (h & 0xffff) as f32 / 65535.0
    }
    fn smooth(t: f32) -> f32 {
        t * t * (3.0 - 2.0 * t)
    }
    const CELL: f32 = 8.0;
    let mut out = Vec::with_capacity((PATTERN * PATTERN * 4) as usize);
    for y in 0..PATTERN {
        for x in 0..PATTERN {
            let (fx, fy) = (x as f32 / CELL, y as f32 / CELL);
            let (ix, iy) = (fx.floor() as i32, fy.floor() as i32);
            let (tx, ty) = (smooth(fx - fx.floor()), smooth(fy - fy.floor()));
            // Wrapped on the cell grid, so the image tiles — a noise texture that seams is a
            // seam somebody will spend an afternoon blaming on the shader.
            let w = (PATTERN as f32 / CELL) as i32;
            let m = |a: i32| a.rem_euclid(w);
            let a = hash(m(ix), m(iy));
            let b = hash(m(ix + 1), m(iy));
            let c = hash(m(ix), m(iy + 1));
            let d = hash(m(ix + 1), m(iy + 1));
            let v = (a + (b - a) * tx) + ((c + (d - c) * tx) - (a + (b - a) * tx)) * ty;
            let v = (v.clamp(0.0, 1.0) * 255.0) as u8;
            out.extend_from_slice(&[v, v, v, 255]);
        }
    }
    out
}

/// The UV coordinates themselves, as red and green.
///
/// The diagnostic image. When a material samples an atlas with the wrong rectangle — which is
/// the normal state of a preview, because the rectangles come from the game's own tile data —
/// this is the one texture that says so: you can read off which corner of the space is being
/// sampled and how it is oriented.
fn uv() -> Vec<u8> {
    let mut out = Vec::with_capacity((PATTERN * PATTERN * 4) as usize);
    for y in 0..PATTERN {
        for x in 0..PATTERN {
            let u = (x * 255 / (PATTERN - 1)) as u8;
            let v = (y * 255 / (PATTERN - 1)) as u8;
            out.extend_from_slice(&[u, v, 0, 255]);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_flat_role_is_one_pixel_per_layer() {
        assert_eq!(flat_pixel(Role::Normal), [128, 128, 255, 255]);
        assert_eq!(checker().len(), (PATTERN * PATTERN * 4) as usize);
        assert_eq!(noise().len(), (PATTERN * PATTERN * 4) as usize);
        assert_eq!(uv().len(), (PATTERN * PATTERN * 4) as usize);
    }

    #[test]
    fn only_the_roles_the_eye_reads_are_srgb() {
        assert!(Role::Checker.is_colour());
        assert!(Role::Uv.is_colour());
        assert!(!Role::Normal.is_colour(), "a normal decoded as sRGB tilts every surface");
        assert!(!Role::Grey.is_colour());
    }

    #[test]
    fn an_unknown_role_is_neutral_rather_than_a_failure() {
        assert_eq!(Role::named("banana"), Role::Neutral);
        assert_eq!(Role::named("  GREY "), Role::Grey);
        assert_eq!(Role::named("gray"), Role::Grey);
    }
}
