//! Blue gradient weight map for text segmentation.
//!
//! The game font uses a blue-to-white gradient (#2D4663 → #FFFFFF).
//! Computes per-pixel weights: high for text pixels (on or near the
//! gradient line), zero for background pixels (icons, gold, etc.).

const std = @import("std");

// NOTE: Core colour / gradient constants are duplicated in
// scripts/extract_digit_profiles.mjs — keep both in sync.

/// Core text color: #2D4663.
const core_r: f32 = 45.0;
const core_g: f32 = 70.0;
const core_b: f32 = 99.0;

/// Gradient direction: white (#FFFFFF) minus core.
const grad_r: f32 = 210.0;
const grad_g: f32 = 185.0;
const grad_b: f32 = 156.0;

/// |gradient|^2 (precomputed).
const grad_dot_grad: f32 = grad_r * grad_r + grad_g * grad_g + grad_b * grad_b;

/// Maximum perpendicular distance from gradient line to count as text.
const max_perp_dist: f32 = 45.0;
const max_perp_dist_sq: f32 = max_perp_dist * max_perp_dist;

/// Hard cutoff on gradient parameter t.
/// Pixels with t above this are considered "too white" and ignored.
/// Core text has t≈0, mid-gradient t≈0.3, near-white t≈0.85+.
const t_max: f32 = 0.55;

/// Compute weight for a single pixel.
/// Returns 0.0 for background, up to 1.0 for core text color.
pub fn blueWeight(r: u8, g: u8, b: u8) f32 {
    const vr = @as(f32, @floatFromInt(r)) - core_r;
    const vg = @as(f32, @floatFromInt(g)) - core_g;
    const vb = @as(f32, @floatFromInt(b)) - core_b;

    // Project onto gradient direction: t = dot(v, grad) / |grad|^2
    const t = (vr * grad_r + vg * grad_g + vb * grad_b) / grad_dot_grad;

    // Reject pixels outside the dark-to-mid gradient range
    if (t < -0.1 or t > t_max) return 0.0;

    // Perpendicular component
    const pr = vr - t * grad_r;
    const pg = vg - t * grad_g;
    const pb = vb - t * grad_b;
    const perp_sq = pr * pr + pg * pg + pb * pb;

    if (perp_sq > max_perp_dist_sq) return 0.0;

    // Weight: quadratic falloff from core (t=0) to cutoff (t=t_max)
    const t_clamped = std.math.clamp(t, 0.0, t_max);
    const t_norm = t_clamped / t_max; // 0..1
    const t_weight = (1.0 - t_norm) * (1.0 - t_norm);
    const dist_factor = 1.0 - @sqrt(perp_sq) / max_perp_dist;

    return @max(t_weight * dist_factor, 0.0);
}

/// Maximum weight map size (pixels) for stack allocation.
pub const max_weight_map_size: u32 = 200 * 50;

/// Compute weight map for an RGB image. Writes into `buf`.
pub fn computeWeightMap(buf: []f32, pixels: []const u8, w: u32, h: u32) []f32 {
    const n = w * h;
    std.debug.assert(buf.len >= n);
    std.debug.assert(pixels.len >= n * 3);
    for (0..n) |i| {
        buf[i] = blueWeight(pixels[i * 3], pixels[i * 3 + 1], pixels[i * 3 + 2]);
    }
    return buf[0..n];
}

/// Hysteresis thresholds for spatial refinement.
pub const strong_threshold: f32 = 0.3;
const weak_threshold: f32 = 0.05;

/// Refine weight map using 4-connected spatial continuity.
///
/// Pixels with weight >= strong_threshold are always kept.
/// Pixels with weight in [weak_threshold, strong_threshold) are kept
/// only if at least one 4-neighbor has weight >= strong_threshold.
/// Pixels below weak_threshold are zeroed.
///
/// This removes isolated noise from icon backgrounds that happen to
/// fall near the blue-white gradient line, while preserving anti-aliased
/// edges of text strokes that are adjacent to strong text pixels.
pub fn refineWeightMap(wmap: []f32, w: u32, h: u32) void {
    const n = w * h;
    // Single pass: strong pixels are kept, weak pixels zeroed,
    // medium pixels kept only if a 4-neighbor is strong.
    // Strong values are never modified, so neighbor reads are stable.
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const v = wmap[i];
        if (v >= strong_threshold) continue; // keep as-is
        if (v < weak_threshold) {
            wmap[i] = 0;
            continue;
        }
        // Medium pixel: check 4-neighbors for a strong pixel
        const x = i % w;
        const y = i / w;
        const has_strong =
            (x > 0 and wmap[i - 1] >= strong_threshold) or
            (x + 1 < w and wmap[i + 1] >= strong_threshold) or
            (y > 0 and wmap[i - w] >= strong_threshold) or
            (y + 1 < h and wmap[i + w] >= strong_threshold);
        if (!has_strong) wmap[i] = 0;
    }
}

// ── Tests ──

test "core color gives maximum weight" {
    const w = blueWeight(45, 70, 99);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), w, 1e-3);
}

test "white gives zero weight" {
    const w = blueWeight(255, 255, 255);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), w, 1e-3);
}

test "anti-aliased pixel gives positive weight" {
    // Pixel near core on gradient (t≈0.09): (66, 86, 111)
    const w = blueWeight(66, 86, 111);
    try std.testing.expect(w > 0.5);

    // Further from core (t≈0.3): (108, 126, 146)
    const w2 = blueWeight(108, 126, 146);
    try std.testing.expect(w2 > 0.1);
    try std.testing.expect(w2 < w);
}

test "near-white pixel gives zero weight" {
    // Near-white in gap area (t≈0.9): gives 0 due to t_max cutoff
    const w = blueWeight(240, 241, 241);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), w, 1e-3);
}

test "yellow background gives zero weight" {
    const w = blueWeight(210, 190, 143);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), w, 1e-3);
}

test "red background gives zero weight" {
    const w = blueWeight(200, 50, 50);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), w, 1e-3);
}

test "green background gives zero weight" {
    const w = blueWeight(50, 200, 50);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), w, 1e-3);
}

test "refineWeightMap: medium pixel kept if adjacent to strong" {
    // 3x3 map:
    //   0.5  0.1  0.0
    //   0.4  0.2  0.01
    //   0.3  0.03 0.0
    var wmap = [_]f32{
        0.5, 0.1, 0.0,
        0.4, 0.2, 0.01,
        0.3, 0.03, 0.0,
    };
    refineWeightMap(&wmap, 3, 3);

    // (0,0)=0.5 ≥ 0.3: strong, kept
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), wmap[0], 1e-6);
    // (1,0)=0.1: medium, right neighbor (0,0)=0.5 is strong → kept
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), wmap[1], 1e-6);
    // (2,0)=0.0: below weak threshold → 0
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), wmap[2], 1e-6);
    // (0,1)=0.4: strong, kept
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), wmap[3], 1e-6);
    // (1,1)=0.2: medium, neighbors include (0,1)=0.4 strong → kept
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), wmap[4], 1e-6);
    // (2,1)=0.01: below weak threshold → 0
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), wmap[5], 1e-6);
    // (0,2)=0.3: strong, kept
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), wmap[6], 1e-6);
    // (1,2)=0.03: below weak threshold → 0
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), wmap[7], 1e-6);
}

test "refineWeightMap: isolated medium pixel removed" {
    // Medium pixel surrounded by weak/zero neighbors
    var wmap = [_]f32{
        0.0,  0.0, 0.0,
        0.0,  0.15, 0.0,
        0.0,  0.0, 0.0,
    };
    refineWeightMap(&wmap, 3, 3);
    // Center pixel has no strong neighbor → zeroed
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), wmap[4], 1e-6);
}

test "computeWeightMap basic" {
    // 2x1 image: core pixel + yellow pixel
    const pixels = [_]u8{ 45, 70, 99, 210, 190, 143 };
    var buf: [2]f32 = undefined;
    const wmap = computeWeightMap(&buf, &pixels, 2, 1);
    try std.testing.expectEqual(@as(usize, 2), wmap.len);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), wmap[0], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), wmap[1], 1e-3);
}
