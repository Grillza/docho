// Reduce moiré: Android's reduce_moire.wgsl (app/src/main/assets/webgpu on main), as Metal compute
// kernels run over a whole page before it's scaled down.
//
// Manga screentone is a dot or line grid finer than a phone can show once a page is shrunk to fit
// (Kaiju No. 8's main tone repeats every ~2.5 source pixels). Scaling it down beats it into moiré.
// This replaces screentone by the flat grey it stands for and leaves line art alone:
//
//   1-2. BH/L  separable Gaussian in linear light, sigma 0.97 / scale source pixels: removes every
//              detail finer than an output pixel, screentone included
//   3. EDGE    where L still has a gradient, there is a line (screentone is flat in L, a thin line
//              is not)
//   4-5. M     that edge mask spread by a Gaussian of 1 / scale, so a line keeps its surroundings;
//              M = 1 where the page is screentone, 0 at and near lines
//   6.         mix(lightly smoothed page, L, M), back to sRGB
//
// `scale` is output pixels per source pixel, clamped to 0.3...1 by the caller, so below 0.3x the
// blur is held at its 0.3x size.

#include <metal_stdlib>
using namespace metal;

static float3 to_linear(float3 c) {
    float3 s = clamp(c, 0.0, 1.0);
    return select(pow((s + 0.055) / 1.055, float3(2.4)), s / 12.92, s <= 0.04045);
}

static float3 to_srgb(float3 c) {
    float3 l = clamp(c, 0.0, 1.0);
    return select(1.055 * pow(l, float3(1.0 / 2.4)) - 0.055, l * 12.92, l <= 0.0031308);
}

static int radius_for(float sigma, int limit) {
    return min(limit, int(ceil(3.0 * sigma)));
}

/// BH: the page blurred across, in linear light.
kernel void moire_blur_across(texture2d<float, access::read> page [[texture(0)]],
                              texture2d<float, access::write> out [[texture(1)]],
                              constant float &scale [[buffer(0)]],
                              uint2 id [[thread_position_in_grid]]) {
    int2 size = int2(page.get_width(), page.get_height());
    if (any(int2(id) >= size)) return;
    float sigma = 0.97 / scale;
    int radius = radius_for(sigma, 10);
    float k = -0.5 / (sigma * sigma);
    int2 p = int2(id);
    float3 sum = 0.0;
    float weights = 0.0;
    for (int i = -radius; i <= radius; i++) {
        float w = exp(float(i * i) * k);
        uint2 q = uint2(clamp(p.x + i, 0, size.x - 1), p.y);
        sum += to_linear(page.read(q).rgb) * w;
        weights += w;
    }
    out.write(float4(sum / weights, 1.0), id);
}

/// L: BH blurred down.
kernel void moire_blur_down(texture2d<float, access::read> bh [[texture(0)]],
                            texture2d<float, access::write> out [[texture(1)]],
                            constant float &scale [[buffer(0)]],
                            uint2 id [[thread_position_in_grid]]) {
    int2 size = int2(bh.get_width(), bh.get_height());
    if (any(int2(id) >= size)) return;
    float sigma = 0.97 / scale;
    int radius = radius_for(sigma, 10);
    float k = -0.5 / (sigma * sigma);
    int2 p = int2(id);
    float3 sum = 0.0;
    float weights = 0.0;
    for (int i = -radius; i <= radius; i++) {
        float w = exp(float(i * i) * k);
        uint2 q = uint2(p.x, clamp(p.y + i, 0, size.y - 1));
        sum += bh.read(q).rgb * w;
        weights += w;
    }
    out.write(float4(sum / weights, 1.0), id);
}

static float luma(texture2d<float, access::read> t, int2 p, int2 size) {
    float3 c = t.read(uint2(clamp(p, int2(0), size - 1))).rgb;
    return dot(c, float3(0.2126, 0.7152, 0.0722));
}

/// EDGE: lines, found as what's left of the gradient in L.
kernel void moire_find_lines(texture2d<float, access::read> l [[texture(0)]],
                             texture2d<float, access::write> out [[texture(1)]],
                             constant float &scale [[buffer(0)]],
                             uint2 id [[thread_position_in_grid]]) {
    int2 size = int2(l.get_width(), l.get_height());
    if (any(int2(id) >= size)) return;
    int2 p = int2(id);
    float tl = luma(l, p + int2(-1, -1), size);
    float t = luma(l, p + int2(0, -1), size);
    float tr = luma(l, p + int2(1, -1), size);
    float lf = luma(l, p + int2(-1, 0), size);
    float r = luma(l, p + int2(1, 0), size);
    float bl = luma(l, p + int2(-1, 1), size);
    float b = luma(l, p + int2(0, 1), size);
    float br = luma(l, p + int2(1, 1), size);
    // Sobel, as a gradient per source pixel, then per output pixel so the thresholds hold at any scale.
    float gx = ((tr + 2.0 * r + br) - (tl + 2.0 * lf + bl)) / 8.0;
    float gy = ((bl + 2.0 * b + br) - (tl + 2.0 * t + tr)) / 8.0;
    float g = length(float2(gx, gy)) / scale;
    out.write(float4(smoothstep(0.011, 0.028, g), 0.0, 0.0, 1.0), id);
}

/// EH: EDGE spread across.
kernel void moire_spread_across(texture2d<float, access::read> edge [[texture(0)]],
                                texture2d<float, access::write> out [[texture(1)]],
                                constant float &scale [[buffer(0)]],
                                uint2 id [[thread_position_in_grid]]) {
    int2 size = int2(edge.get_width(), edge.get_height());
    if (any(int2(id) >= size)) return;
    float sigma = 1.0 / scale;
    int radius = radius_for(sigma, 10);
    float k = -0.5 / (sigma * sigma);
    int2 p = int2(id);
    float sum = 0.0;
    float weights = 0.0;
    for (int i = -radius; i <= radius; i++) {
        float w = exp(float(i * i) * k);
        sum += edge.read(uint2(clamp(p.x + i, 0, size.x - 1), p.y)).r * w;
        weights += w;
    }
    out.write(float4(sum / weights, 0.0, 0.0, 1.0), id);
}

/// M: EH spread down; 1 = screentone (use the blurred page), 0 = at or near a line (keep it).
kernel void moire_spread_down(texture2d<float, access::read> eh [[texture(0)]],
                              texture2d<float, access::write> out [[texture(1)]],
                              constant float &scale [[buffer(0)]],
                              uint2 id [[thread_position_in_grid]]) {
    int2 size = int2(eh.get_width(), eh.get_height());
    if (any(int2(id) >= size)) return;
    float sigma = 1.0 / scale;
    int radius = radius_for(sigma, 10);
    float k = -0.5 / (sigma * sigma);
    int2 p = int2(id);
    float sum = 0.0;
    float weights = 0.0;
    for (int i = -radius; i <= radius; i++) {
        float w = exp(float(i * i) * k);
        sum += eh.read(uint2(p.x, clamp(p.y + i, 0, size.y - 1))).r * w;
        weights += w;
    }
    float m = 1.0 - min(1.0, 2.0 * sum / weights);
    out.write(float4(m, 0.0, 0.0, 1.0), id);
}

/// The page: lightly smoothed near lines, L where it's screentone.
kernel void moire_combine(texture2d<float, access::read> page [[texture(0)]],
                          texture2d<float, access::read> blurred [[texture(1)]],
                          texture2d<float, access::read> mask [[texture(2)]],
                          texture2d<float, access::write> out [[texture(3)]],
                          constant float &scale [[buffer(0)]],
                          uint2 id [[thread_position_in_grid]]) {
    int2 size = int2(page.get_width(), page.get_height());
    if (any(int2(id) >= size)) return;
    int2 p = int2(id);
    float4 original = page.read(id);
    float m = mask.read(id).r;

    // Near lines: a light smoothing (sigma 0.35 / scale) that takes the edge off leftover
    // screentone without visibly softening the line.
    float sigma = 0.35 / scale;
    int radius = radius_for(sigma, 4);
    float k = -0.5 / (sigma * sigma);
    float3 keep = 0.0;
    float weights = 0.0;
    for (int y = -radius; y <= radius; y++) {
        for (int x = -radius; x <= radius; x++) {
            float w = exp(float(x * x + y * y) * k);
            keep += to_linear(page.read(uint2(clamp(p + int2(x, y), int2(0), size - 1))).rgb) * w;
            weights += w;
        }
    }
    keep /= weights;

    float3 result = mix(keep, blurred.read(id).rgb, m);
    out.write(float4(to_srgb(result), original.a), id);
}
