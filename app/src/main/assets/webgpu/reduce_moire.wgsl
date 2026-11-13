// Reduce moiré: a built-in tile filter for the high-quality renderer.
//
// Manga screentone is a dot or line grid finer than a phone can show once a page is shrunk to fit
// (Kaiju No. 8's main tone repeats every ~2.5 source pixels; at 0.72x the screen resolves ~2.8).
// The renderer's area-average resize then beats it into moiré. This filter, run only while a tile
// is being shrunk, replaces screentone by the flat grey it stands for and leaves line art alone:
//
//   1. SCALE   a 1-pixel-high texture whose width is 1000 x the tile's page scale: the passes'
//              only way to learn the scale, since header expressions are all that see OUTPUT
//   2-3. BH/L  separable Gaussian in linear light, sigma 0.97 / scale source pixels: removes
//              every detail finer than an output pixel, screentone included
//   4. EDGE    where L still has a gradient, there is a line (screentone is flat in L, a thin
//              line is not)
//   5-6. M     that edge mask spread by a Gaussian of 1 / scale, so a line keeps its surroundings;
//              M = 1 where the page is screentone, 0 at and near lines
//   7.         mix(lightly smoothed page, L, M), back to sRGB
//
// Below 0.3x the blur is held at its 0.3x size, so the halo stays bounded.
//
// HALO: BH/BV reach 10 pixels, EDGE 1, EH/EV 10 more, so a tile needs 21 pixels of surrounding page.

//!HALO 22

//!DESC reduce moiré: scale
//!HOOK MAIN
//!BIND HOOKED
//!SAVE SCALE
//!WIDTH OUTPUT.w 1000 * HOOKED.w /
//!HEIGHT 1
//!WHEN OUTPUT.w HOOKED.w / 0.95 <
//!COMPUTE 8 8
@group(0) @binding(0) var tex: texture_2d<f32>;
@group(0) @binding(1) var outputTexture: texture_storage_2d<rgba16float, write>;

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3<u32>) {
    if (any(id.xy >= textureDimensions(outputTexture))) {
        return;
    }
    // Only this texture's size carries information; the read keeps HOOKED bound.
    textureStore(outputTexture, id.xy, textureLoad(tex, vec2<i32>(0, 0), 0) * 0.0);
}

//!DESC reduce moiré: blur across
//!HOOK MAIN
//!BIND HOOKED
//!BIND SCALE
//!SAVE BH
//!WHEN OUTPUT.w HOOKED.w / 0.95 <
//!COMPUTE 8 8
@group(0) @binding(0) var tex: texture_2d<f32>;
@group(0) @binding(1) var scaleTex: texture_2d<f32>;
@group(0) @binding(2) var outputTexture: texture_storage_2d<rgba16float, write>;

fn to_linear(c: vec3<f32>) -> vec3<f32> {
    let s = clamp(c, vec3<f32>(0.0), vec3<f32>(1.0));
    return select(pow((s + 0.055) / 1.055, vec3<f32>(2.4)), s / 12.92, s <= vec3<f32>(0.04045));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3<u32>) {
    let size = vec2<i32>(textureDimensions(tex));
    if (any(vec2<i32>(id.xy) >= size)) {
        return;
    }
    let scale = clamp(f32(textureDimensions(scaleTex).x) / 1000.0, 0.3, 1.0);
    let sigma = 0.97 / scale;
    let radius = min(10, i32(ceil(3.0 * sigma)));
    let k = -0.5 / (sigma * sigma);
    let p = vec2<i32>(id.xy);
    var sum = vec3<f32>(0.0);
    var weights = 0.0;
    for (var i = -radius; i <= radius; i++) {
        let w = exp(f32(i * i) * k);
        let q = vec2<i32>(clamp(p.x + i, 0, size.x - 1), p.y);
        sum += to_linear(textureLoad(tex, q, 0).rgb) * w;
        weights += w;
    }
    textureStore(outputTexture, id.xy, vec4<f32>(sum / weights, 1.0));
}

//!DESC reduce moiré: blur down
//!HOOK MAIN
//!BIND BH
//!BIND SCALE
//!SAVE L
//!WHEN OUTPUT.w HOOKED.w / 0.95 <
//!COMPUTE 8 8
@group(0) @binding(0) var tex: texture_2d<f32>;
@group(0) @binding(1) var scaleTex: texture_2d<f32>;
@group(0) @binding(2) var outputTexture: texture_storage_2d<rgba16float, write>;

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3<u32>) {
    let size = vec2<i32>(textureDimensions(tex));
    if (any(vec2<i32>(id.xy) >= size)) {
        return;
    }
    let scale = clamp(f32(textureDimensions(scaleTex).x) / 1000.0, 0.3, 1.0);
    let sigma = 0.97 / scale;
    let radius = min(10, i32(ceil(3.0 * sigma)));
    let k = -0.5 / (sigma * sigma);
    let p = vec2<i32>(id.xy);
    var sum = vec3<f32>(0.0);
    var weights = 0.0;
    for (var i = -radius; i <= radius; i++) {
        let w = exp(f32(i * i) * k);
        let q = vec2<i32>(p.x, clamp(p.y + i, 0, size.y - 1));
        sum += textureLoad(tex, q, 0).rgb * w;
        weights += w;
    }
    textureStore(outputTexture, id.xy, vec4<f32>(sum / weights, 1.0));
}

//!DESC reduce moiré: find lines
//!HOOK MAIN
//!BIND L
//!BIND SCALE
//!SAVE EDGE
//!WHEN OUTPUT.w HOOKED.w / 0.95 <
//!COMPUTE 8 8
@group(0) @binding(0) var tex: texture_2d<f32>;
@group(0) @binding(1) var scaleTex: texture_2d<f32>;
@group(0) @binding(2) var outputTexture: texture_storage_2d<rgba16float, write>;

fn luma(p: vec2<i32>, size: vec2<i32>) -> f32 {
    let c = textureLoad(tex, clamp(p, vec2<i32>(0), size - 1), 0).rgb;
    return dot(c, vec3<f32>(0.2126, 0.7152, 0.0722));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3<u32>) {
    let size = vec2<i32>(textureDimensions(tex));
    if (any(vec2<i32>(id.xy) >= size)) {
        return;
    }
    let scale = clamp(f32(textureDimensions(scaleTex).x) / 1000.0, 0.3, 1.0);
    let p = vec2<i32>(id.xy);
    let tl = luma(p + vec2<i32>(-1, -1), size);
    let t = luma(p + vec2<i32>(0, -1), size);
    let tr = luma(p + vec2<i32>(1, -1), size);
    let l = luma(p + vec2<i32>(-1, 0), size);
    let r = luma(p + vec2<i32>(1, 0), size);
    let bl = luma(p + vec2<i32>(-1, 1), size);
    let b = luma(p + vec2<i32>(0, 1), size);
    let br = luma(p + vec2<i32>(1, 1), size);
    // Sobel, as a gradient per source pixel, then per output pixel so the thresholds hold at any scale.
    let gx = ((tr + 2.0 * r + br) - (tl + 2.0 * l + bl)) / 8.0;
    let gy = ((bl + 2.0 * b + br) - (tl + 2.0 * t + tr)) / 8.0;
    let g = length(vec2<f32>(gx, gy)) / scale;
    let edge = smoothstep(0.011, 0.028, g);
    textureStore(outputTexture, id.xy, vec4<f32>(edge, 0.0, 0.0, 1.0));
}

//!DESC reduce moiré: spread across
//!HOOK MAIN
//!BIND EDGE
//!BIND SCALE
//!SAVE EH
//!WHEN OUTPUT.w HOOKED.w / 0.95 <
//!COMPUTE 8 8
@group(0) @binding(0) var tex: texture_2d<f32>;
@group(0) @binding(1) var scaleTex: texture_2d<f32>;
@group(0) @binding(2) var outputTexture: texture_storage_2d<rgba16float, write>;

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3<u32>) {
    let size = vec2<i32>(textureDimensions(tex));
    if (any(vec2<i32>(id.xy) >= size)) {
        return;
    }
    let scale = clamp(f32(textureDimensions(scaleTex).x) / 1000.0, 0.3, 1.0);
    let sigma = 1.0 / scale;
    let radius = min(10, i32(ceil(3.0 * sigma)));
    let k = -0.5 / (sigma * sigma);
    let p = vec2<i32>(id.xy);
    var sum = 0.0;
    var weights = 0.0;
    for (var i = -radius; i <= radius; i++) {
        let w = exp(f32(i * i) * k);
        sum += textureLoad(tex, vec2<i32>(clamp(p.x + i, 0, size.x - 1), p.y), 0).r * w;
        weights += w;
    }
    textureStore(outputTexture, id.xy, vec4<f32>(sum / weights, 0.0, 0.0, 1.0));
}

//!DESC reduce moiré: spread down
//!HOOK MAIN
//!BIND EH
//!BIND SCALE
//!SAVE M
//!WHEN OUTPUT.w HOOKED.w / 0.95 <
//!COMPUTE 8 8
@group(0) @binding(0) var tex: texture_2d<f32>;
@group(0) @binding(1) var scaleTex: texture_2d<f32>;
@group(0) @binding(2) var outputTexture: texture_storage_2d<rgba16float, write>;

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3<u32>) {
    let size = vec2<i32>(textureDimensions(tex));
    if (any(vec2<i32>(id.xy) >= size)) {
        return;
    }
    let scale = clamp(f32(textureDimensions(scaleTex).x) / 1000.0, 0.3, 1.0);
    let sigma = 1.0 / scale;
    let radius = min(10, i32(ceil(3.0 * sigma)));
    let k = -0.5 / (sigma * sigma);
    let p = vec2<i32>(id.xy);
    var sum = 0.0;
    var weights = 0.0;
    for (var i = -radius; i <= radius; i++) {
        let w = exp(f32(i * i) * k);
        sum += textureLoad(tex, vec2<i32>(p.x, clamp(p.y + i, 0, size.y - 1)), 0).r * w;
        weights += w;
    }
    // 1 = screentone (use the blurred page), 0 = at or near a line (keep it).
    let m = 1.0 - min(1.0, 2.0 * sum / weights);
    textureStore(outputTexture, id.xy, vec4<f32>(m, 0.0, 0.0, 1.0));
}

//!DESC reduce moiré: combine
//!HOOK MAIN
//!BIND HOOKED
//!BIND L
//!BIND M
//!BIND SCALE
//!WHEN OUTPUT.w HOOKED.w / 0.95 <
//!COMPUTE 8 8
@group(0) @binding(0) var tex: texture_2d<f32>;
@group(0) @binding(1) var blurred: texture_2d<f32>;
@group(0) @binding(2) var mask: texture_2d<f32>;
@group(0) @binding(3) var scaleTex: texture_2d<f32>;
@group(0) @binding(4) var outputTexture: texture_storage_2d<rgba16float, write>;

fn to_linear(c: vec3<f32>) -> vec3<f32> {
    let s = clamp(c, vec3<f32>(0.0), vec3<f32>(1.0));
    return select(pow((s + 0.055) / 1.055, vec3<f32>(2.4)), s / 12.92, s <= vec3<f32>(0.04045));
}

fn to_srgb(c: vec3<f32>) -> vec3<f32> {
    let l = clamp(c, vec3<f32>(0.0), vec3<f32>(1.0));
    return select(1.055 * pow(l, vec3<f32>(1.0 / 2.4)) - 0.055, l * 12.92, l <= vec3<f32>(0.0031308));
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3<u32>) {
    let size = vec2<i32>(textureDimensions(tex));
    if (any(vec2<i32>(id.xy) >= size)) {
        return;
    }
    let scale = clamp(f32(textureDimensions(scaleTex).x) / 1000.0, 0.3, 1.0);
    let p = vec2<i32>(id.xy);
    let original = textureLoad(tex, p, 0);
    let m = textureLoad(mask, p, 0).r;

    // Near lines: a light smoothing (sigma 0.35 / scale) that takes the edge off leftover
    // screentone without visibly softening the line.
    let sigma = 0.35 / scale;
    let radius = min(4, i32(ceil(3.0 * sigma)));
    let k = -0.5 / (sigma * sigma);
    var keep = vec3<f32>(0.0);
    var weights = 0.0;
    for (var y = -radius; y <= radius; y++) {
        for (var x = -radius; x <= radius; x++) {
            let w = exp(f32(x * x + y * y) * k);
            keep += to_linear(textureLoad(tex, clamp(p + vec2<i32>(x, y), vec2<i32>(0), size - 1), 0).rgb) * w;
            weights += w;
        }
    }
    keep /= weights;

    let result = mix(keep, textureLoad(blurred, p, 0).rgb, m);
    textureStore(outputTexture, id.xy, vec4<f32>(to_srgb(result), original.a));
}
