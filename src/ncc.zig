//! Normalized Cross-Correlation (NCC) for template matching.
//!
//! NCC = Σ((I - Ī)(T - T̄)) / sqrt(Σ(I - Ī)² × Σ(T - T̄)²)
//! Returns f32 in [-1.0, 1.0]: 1.0 = perfect match, -1.0 = inverted, 0.0 = uncorrelated.
//!
//! Uses single-pass computation via the identity:
//!   Σ(x - x̄)² = Σx² - n*x̄²
//!   Σ(x - x̄)(y - ȳ) = Σxy - n*x̄*ȳ

const std = @import("std");

/// Compute NCC between two same-sized grayscale buffers.
/// Returns 0.0 if either buffer has zero variance (flat region).
pub fn ncc(image: []const u8, template: []const u8) f32 {
    std.debug.assert(image.len == template.len);
    if (image.len == 0) return 0;

    var sum_i: f64 = 0;
    var sum_t: f64 = 0;
    var sum_ii: f64 = 0;
    var sum_tt: f64 = 0;
    var sum_it: f64 = 0;

    for (0..image.len) |idx| {
        const vi: f64 = @floatFromInt(image[idx]);
        const vt: f64 = @floatFromInt(template[idx]);
        sum_i += vi;
        sum_t += vt;
        sum_ii += vi * vi;
        sum_tt += vt * vt;
        sum_it += vi * vt;
    }

    const n: f64 = @floatFromInt(image.len);
    const var_i = sum_ii - sum_i * sum_i / n;
    const var_t = sum_tt - sum_t * sum_t / n;
    const cov = sum_it - sum_i * sum_t / n;

    const denom = @sqrt(var_i * var_t);
    if (denom < 1e-10) return 0;
    return @floatCast(cov / denom);
}

/// Compute masked NCC. Only pixels where mask[i] != 0 contribute.
/// Returns 0.0 if no masked pixels or zero variance.
pub fn maskedNcc(image: []const u8, template: []const u8, mask: []const u8) f32 {
    std.debug.assert(image.len == template.len);
    std.debug.assert(image.len == mask.len);

    var count: u64 = 0;
    var sum_i: f64 = 0;
    var sum_t: f64 = 0;
    var sum_ii: f64 = 0;
    var sum_tt: f64 = 0;
    var sum_it: f64 = 0;

    for (0..image.len) |idx| {
        if (mask[idx] != 0) {
            const vi: f64 = @floatFromInt(image[idx]);
            const vt: f64 = @floatFromInt(template[idx]);
            sum_i += vi;
            sum_t += vt;
            sum_ii += vi * vi;
            sum_tt += vt * vt;
            sum_it += vi * vt;
            count += 1;
        }
    }
    if (count == 0) return 0;

    const n: f64 = @floatFromInt(count);
    const var_i = sum_ii - sum_i * sum_i / n;
    const var_t = sum_tt - sum_t * sum_t / n;
    const cov = sum_it - sum_i * sum_t / n;

    const denom = @sqrt(var_i * var_t);
    if (denom < 1e-10) return 0;
    return @floatCast(cov / denom);
}

pub const Bounds = struct { x: u32, y: u32, w: u32, h: u32 };

/// Find the bounding box of opaque pixels in an RGBA image.
/// Returns null if no opaque pixels exist (alpha > threshold).
pub fn opaqueBounds(rgba: []const u8, w: u32, h: u32, min_alpha: u8) ?Bounds {
    var min_x: u32 = w;
    var min_y: u32 = h;
    var max_x: u32 = 0;
    var max_y: u32 = 0;

    for (0..h) |yi| {
        const y: u32 = @intCast(yi);
        for (0..w) |xi| {
            const x: u32 = @intCast(xi);
            const a = rgba[(yi * w + xi) * 4 + 3];
            if (a > min_alpha) {
                if (x < min_x) min_x = x;
                if (x > max_x) max_x = x;
                if (y < min_y) min_y = y;
                if (y > max_y) max_y = y;
            }
        }
    }

    if (max_x < min_x) return null;
    return .{ .x = min_x, .y = min_y, .w = max_x - min_x + 1, .h = max_y - min_y + 1 };
}

/// Crop a rectangular region from an RGBA buffer into a new RGBA buffer.
pub fn cropRgba(
    allocator: std.mem.Allocator,
    src: []const u8,
    src_w: u32,
    bounds: Bounds,
) ![]u8 {
    const row_bytes = @as(usize, bounds.w) * 4;
    const dst = try allocator.alloc(u8, row_bytes * bounds.h);
    for (0..bounds.h) |dy| {
        const src_off = ((@as(usize, bounds.y) + dy) * src_w + bounds.x) * 4;
        const dst_off = dy * row_bytes;
        @memcpy(dst[dst_off..][0..row_bytes], src[src_off..][0..row_bytes]);
    }
    return dst;
}

/// Fraction of cell height to use for icon matching (top 80%, bottom 20% excluded).
pub const icon_region_ratio: f32 = 0.80;

/// Alpha threshold for template masking.
/// Only fully opaque pixels (alpha=255) are used for matching.
/// Semi-transparent pixels are blended with rarity-specific backgrounds
/// in-game, making their grayscale values unreliable for NCC.
pub const alpha_threshold: u8 = 254;

/// BT.601 grayscale conversion for a single pixel.
pub fn grayFromRgb(r: u8, g: u8, b: u8) u8 {
    return @intCast((@as(u16, r) * 77 + @as(u16, g) * 150 + @as(u16, b) * 29) >> 8);
}

/// Convert RGBA pixels to grayscale + binary alpha mask (in-place into provided buffers).
/// Pixels with alpha > min_alpha are marked opaque in the mask.
/// Returns the number of opaque pixels.
pub fn rgbaToGrayAndMask(rgba: []const u8, gray: []u8, mask: []u8, min_alpha: u8) u32 {
    var count: u32 = 0;
    for (0..gray.len) |i| {
        const a = rgba[i * 4 + 3];
        gray[i] = grayFromRgb(rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2]);
        mask[i] = if (a > min_alpha) 255 else 0;
        if (a > min_alpha) count += 1;
    }
    return count;
}

pub const MatchResult = struct {
    score: f32,
    x: u32,
    y: u32,
};

/// Convert RGB buffer to grayscale (BT.601 weights).
pub fn rgbToGray(rgb: []const u8, gray: []u8) void {
    for (0..gray.len) |i| {
        gray[i] = grayFromRgb(rgb[i * 3], rgb[i * 3 + 1], rgb[i * 3 + 2]);
    }
}

/// Slide a template (with alpha mask) over a grayscale image and return
/// the position and score of the best masked NCC match.
///
/// - `image_gray`: grayscale image (w * h bytes)
/// - `img_w`, `img_h`: image dimensions
/// - `tmpl_gray`: grayscale template (tw * th bytes)
/// - `tmpl_mask`: alpha mask (tw * th bytes, nonzero = opaque)
/// - `tw`, `th`: template dimensions
/// - `step`: slide step in pixels (1 = exhaustive, 2 = faster)
///
/// Returns null if the template is larger than the image or exceeds
/// the internal 256x256 stack buffer.
pub fn slidingMaskedNcc(
    image_gray: []const u8,
    img_w: u32,
    img_h: u32,
    tmpl_gray: []const u8,
    tmpl_mask: []const u8,
    tw: u32,
    th: u32,
    step: u32,
) ?MatchResult {
    if (tw > img_w or th > img_h) return null;
    const patch_size = @as(usize, tw) * th;
    if (patch_size > 256 * 256) return null;

    var best = MatchResult{ .score = -2.0, .x = 0, .y = 0 };
    var patch_buf: [256 * 256]u8 = undefined;

    var sy: u32 = 0;
    while (sy + th <= img_h) : (sy += step) {
        var sx: u32 = 0;
        while (sx + tw <= img_w) : (sx += step) {
            const patch = patch_buf[0..patch_size];

            for (0..th) |dy| {
                const src_off = (@as(usize, sy) + dy) * img_w + sx;
                const dst_off = dy * @as(usize, tw);
                @memcpy(patch[dst_off..][0..tw], image_gray[src_off..][0..tw]);
            }

            const score = maskedNcc(patch, tmpl_gray, tmpl_mask);
            if (score > best.score) {
                best = .{ .score = score, .x = sx, .y = sy };
            }
        }
    }

    return if (best.score > -2.0) best else null;
}

// ── Tests ──

test "perfect match → 1.0" {
    const data = [_]u8{ 10, 50, 100, 200, 255 };
    const score = ncc(&data, &data);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), score, 1e-5);
}

test "inverted → -1.0" {
    const a = [_]u8{ 0, 50, 100, 200, 255 };
    const b = [_]u8{ 255, 205, 155, 55, 0 };
    const score = ncc(&a, &b);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), score, 1e-5);
}

test "flat region → 0.0" {
    const flat = [_]u8{ 100, 100, 100, 100 };
    const varied = [_]u8{ 10, 50, 200, 255 };
    const score = ncc(&flat, &varied);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), score, 1e-5);
}

test "known correlation" {
    const a = [_]u8{ 10, 20, 30, 40 };
    const b = [_]u8{ 20, 40, 60, 80 };
    const score = ncc(&a, &b);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), score, 1e-5);
}

test "masked NCC — partial mask" {
    const image = [_]u8{ 10, 50, 100, 200 };
    const template = [_]u8{ 10, 50, 100, 200 };
    const mask = [_]u8{ 255, 255, 0, 0 };
    const score = maskedNcc(&image, &template, &mask);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), score, 1e-5);
}

test "masked NCC — all masked out → 0.0" {
    const image = [_]u8{ 10, 50, 100, 200 };
    const template = [_]u8{ 10, 50, 100, 200 };
    const mask = [_]u8{ 0, 0, 0, 0 };
    const score = maskedNcc(&image, &template, &mask);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), score, 1e-5);
}

test "single pixel → 0.0 (zero variance)" {
    const a = [_]u8{42};
    const b = [_]u8{42};
    const score = ncc(&a, &b);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), score, 1e-5);
}

test "empty buffers → 0.0" {
    const empty: []const u8 = &.{};
    const score = ncc(empty, empty);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), score, 1e-5);
}

test "rgbToGray: known conversion" {
    const rgb = [_]u8{ 255, 0, 0, 0, 255, 0, 0, 0, 255 };
    var gray: [3]u8 = undefined;
    rgbToGray(&rgb, &gray);
    // R: 255*77/256 ≈ 76, G: 255*150/256 ≈ 149, B: 255*29/256 ≈ 28
    try std.testing.expectEqual(@as(u8, 76), gray[0]);
    try std.testing.expectEqual(@as(u8, 149), gray[1]);
    try std.testing.expectEqual(@as(u8, 28), gray[2]);
}

test "slidingMaskedNcc: finds exact match location" {
    // 8x8 gray image, all 50 except a 3x3 bright patch at (3,2)
    var image: [8 * 8]u8 = undefined;
    @memset(&image, 50);
    // Place distinct pattern at (3,2)
    image[2 * 8 + 3] = 200;
    image[2 * 8 + 4] = 150;
    image[2 * 8 + 5] = 200;
    image[3 * 8 + 3] = 150;
    image[3 * 8 + 4] = 255;
    image[3 * 8 + 5] = 150;
    image[4 * 8 + 3] = 200;
    image[4 * 8 + 4] = 150;
    image[4 * 8 + 5] = 200;

    const tmpl = [_]u8{ 200, 150, 200, 150, 255, 150, 200, 150, 200 };
    const mask = [_]u8{ 255, 255, 255, 255, 255, 255, 255, 255, 255 };

    const result = slidingMaskedNcc(&image, 8, 8, &tmpl, &mask, 3, 3, 1).?;
    try std.testing.expectEqual(@as(u32, 3), result.x);
    try std.testing.expectEqual(@as(u32, 2), result.y);
    try std.testing.expect(result.score > 0.95);
}

test "slidingMaskedNcc: template larger than image → null" {
    var image: [4 * 4]u8 = undefined;
    @memset(&image, 100);
    var tmpl: [5 * 5]u8 = undefined;
    @memset(&tmpl, 100);
    var mask: [5 * 5]u8 = undefined;
    @memset(&mask, 255);
    try std.testing.expect(slidingMaskedNcc(&image, 4, 4, &tmpl, &mask, 5, 5, 1) == null);
}

test "opaqueBounds: finds content region" {
    // 4x4 RGBA, all transparent except center 2x2
    var rgba: [4 * 4 * 4]u8 = undefined;
    @memset(&rgba, 0); // all transparent
    // Set (1,1), (2,1), (1,2), (2,2) opaque
    for ([_]usize{ 1 * 4 + 1, 1 * 4 + 2, 2 * 4 + 1, 2 * 4 + 2 }) |idx| {
        rgba[idx * 4] = 100;
        rgba[idx * 4 + 1] = 150;
        rgba[idx * 4 + 2] = 200;
        rgba[idx * 4 + 3] = 255;
    }
    const b = opaqueBounds(&rgba, 4, 4, 128).?;
    try std.testing.expectEqual(@as(u32, 1), b.x);
    try std.testing.expectEqual(@as(u32, 1), b.y);
    try std.testing.expectEqual(@as(u32, 2), b.w);
    try std.testing.expectEqual(@as(u32, 2), b.h);
}

test "opaqueBounds: all transparent → null" {
    var rgba: [2 * 2 * 4]u8 = undefined;
    @memset(&rgba, 0);
    try std.testing.expect(opaqueBounds(&rgba, 2, 2, 128) == null);
}

test "cropRgba: extracts sub-region" {
    const alloc = std.testing.allocator;
    // 4x4 RGBA, pixel value = (x, y, 0, 255)
    var src: [4 * 4 * 4]u8 = undefined;
    for (0..4) |y| {
        for (0..4) |x| {
            const i = (y * 4 + x) * 4;
            src[i] = @intCast(x);
            src[i + 1] = @intCast(y);
            src[i + 2] = 0;
            src[i + 3] = 255;
        }
    }
    const cropped = try cropRgba(alloc, &src, 4, .{ .x = 1, .y = 1, .w = 2, .h = 2 });
    defer alloc.free(cropped);

    // (1,1) → R=1, G=1
    try std.testing.expectEqual(@as(u8, 1), cropped[0]);
    try std.testing.expectEqual(@as(u8, 1), cropped[1]);
    // (2,1) → R=2, G=1
    try std.testing.expectEqual(@as(u8, 2), cropped[4]);
    try std.testing.expectEqual(@as(u8, 1), cropped[5]);
}

test "rgbaToGrayAndMask: splits channels and counts opaque" {
    // 2 pixels: one opaque (a=255), one semi-transparent (a=100)
    const rgba = [_]u8{
        255, 0, 0, 255, // pixel 0: red, fully opaque
        0, 255, 0, 100, // pixel 1: green, semi-transparent
    };
    var gray: [2]u8 = undefined;
    var mask: [2]u8 = undefined;
    const count = rgbaToGrayAndMask(&rgba, &gray, &mask, 128);

    try std.testing.expectEqual(@as(u32, 1), count);
    try std.testing.expectEqual(@as(u8, 76), gray[0]); // red → 76
    try std.testing.expectEqual(@as(u8, 149), gray[1]); // green → 149
    try std.testing.expectEqual(@as(u8, 255), mask[0]); // opaque
    try std.testing.expectEqual(@as(u8, 0), mask[1]); // transparent
}
