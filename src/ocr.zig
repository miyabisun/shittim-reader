//! Digit OCR: recognize quantity numbers from cell footer regions.
//!
//! Uses blue gradient weight mapping and projection profile analysis
//! to segment and classify digits. The game font uses a distinctive
//! #2D4663 → #FFFFFF gradient that enables color-based segmentation.

const std = @import("std");
const blue_weight = @import("blue_weight.zig");
const proj = @import("projection.zig");
const digit_mod = @import("digit.zig");

// NOTE: skew_factor is also used in scripts/extract_digit_profiles.mjs
// and scripts/skew_test.mjs — keep in sync.
const skew_factor: f32 = 0.25;

// Max deskewed image dimensions for stack buffer.
// Number regions: ~49x24 (16:9) or ~122x32 (4:3).
// After shear the width grows by ceil(0.25 * height).
const max_deskew_src_w: u32 = 140;
const max_deskew_src_h: u32 = 50;
const max_deskew_dst_w: u32 = max_deskew_src_w + max_deskew_src_h;
const max_deskew_buf_size: u32 = max_deskew_dst_w * max_deskew_src_h * 3;

/// Threshold for 'x' detection: segments with peak below this at the
/// left edge are considered the 'x' prefix character.
const x_peak_threshold: f32 = 4.0;

/// Minimum peak to keep a segment (noise filter).
const noise_peak_threshold: f32 = 3.0;

/// Maximum start column for a segment to be considered the 'x' prefix.
const x_max_start_col: u32 = 8;

/// Minimum segment width to keep (noise filter).
const noise_min_width: u32 = 5;

/// Apply horizontal shear to correct italic (right-leaning) text.
///
/// Each output pixel (ox, oy) samples from input at (ox + skew * oy, oy)
/// using bilinear interpolation. The output is wider by ceil(skew * height).
/// Pixels outside the input bounds are filled with black (0).
fn deskew(
    buf: []u8,
    pixels: []const u8,
    w: u32,
    h: u32,
) struct { pixels: []u8, w: u32 } {
    const extra: u32 = @intFromFloat(@ceil(skew_factor * @as(f32, @floatFromInt(h))));
    const dst_w = w + extra;
    const dst_len = dst_w * h * 3;

    std.debug.assert(dst_len <= buf.len);

    for (0..h) |oy| {
        const shift = skew_factor * @as(f32, @floatFromInt(oy));
        for (0..dst_w) |ox| {
            const dst_idx = (oy * dst_w + ox) * 3;
            const src_xf = @as(f32, @floatFromInt(ox)) - shift;

            if (src_xf < 0 or src_xf >= @as(f32, @floatFromInt(w)) - 1) {
                if (src_xf >= 0 and src_xf < @as(f32, @floatFromInt(w))) {
                    const sx: u32 = @intFromFloat(src_xf);
                    const src_idx = (oy * w + sx) * 3;
                    buf[dst_idx] = pixels[src_idx];
                    buf[dst_idx + 1] = pixels[src_idx + 1];
                    buf[dst_idx + 2] = pixels[src_idx + 2];
                } else {
                    buf[dst_idx] = 0;
                    buf[dst_idx + 1] = 0;
                    buf[dst_idx + 2] = 0;
                }
                continue;
            }

            const sx0: u32 = @intFromFloat(@floor(src_xf));
            const frac = src_xf - @floor(src_xf);
            const sx1 = sx0 + 1;
            const idx0 = (oy * w + sx0) * 3;
            const idx1 = (oy * w + sx1) * 3;

            for (0..3) |ch| {
                const v0: f32 = @floatFromInt(pixels[idx0 + ch]);
                const v1: f32 = @floatFromInt(pixels[idx1 + ch]);
                const blended = v0 * (1.0 - frac) + v1 * frac;
                buf[dst_idx + ch] = @intFromFloat(@round(blended));
            }
        }
    }

    return .{ .pixels = buf[0..dst_len], .w = dst_w };
}

/// Recognize digits from an already-deskewed number region image.
/// This is the core pipeline: weight map → projection → segment → classify.
pub fn recognizeDigits(
    pixels: []const u8,
    w: u32,
    h: u32,
) ?u32 {
    // Step 1: Compute blue gradient weight map
    var wmap_buf: [blue_weight.max_weight_map_size]f32 = undefined;
    const wmap = blue_weight.computeWeightMap(&wmap_buf, pixels, w, h);

    // Step 2: Column projection
    var col_buf: [proj.max_profile_w]f32 = undefined;
    const col_prof = proj.columnProjection(wmap, w, h, &col_buf);

    // Step 3: Segment characters
    var seg_buf: [proj.max_segments]proj.Segment = undefined;
    const raw_segs = proj.segmentCharacters(col_prof, &seg_buf);

    if (raw_segs.len == 0) return null;

    // Step 4: Post-process segments — filter noise and skip 'x'
    var digit_segs: [proj.max_segments]proj.Segment = undefined;
    var n_digit_segs: u32 = 0;
    var skipped_x = false;

    for (raw_segs) |seg| {
        // Find peak value in this segment
        var peak: f32 = 0;
        for (seg.start..seg.end) |c| {
            peak = @max(peak, col_prof[c]);
        }

        // Filter noise: narrow segments with low peak
        if (peak < noise_peak_threshold and seg.width() < noise_min_width) continue;

        // Detect 'x' prefix: first segment at left edge with low peak
        if (!skipped_x and seg.start < x_max_start_col and peak < x_peak_threshold) {
            skipped_x = true;
            continue;
        }

        if (n_digit_segs < digit_segs.len) {
            digit_segs[n_digit_segs] = seg;
            n_digit_segs += 1;
        }
    }

    if (n_digit_segs == 0) return null;

    // Step 5: Classify each digit segment
    var value: u32 = 0;
    var row_buf: [proj.max_profile_h]f32 = undefined;

    for (digit_segs[0..n_digit_segs]) |seg| {
        // Column profile for this character
        const char_col = col_prof[seg.start..seg.end];
        var norm_col: [digit_mod.n_col_bins]f32 = undefined;
        proj.normalizeProfile(char_col, &norm_col);

        // Row profile for this character
        const char_row = proj.rowProjection(wmap, w, h, seg.start, seg.end, &row_buf);
        var norm_row: [digit_mod.n_row_bins]f32 = undefined;
        proj.normalizeProfile(char_row, &norm_row);

        // Upper and lower half row profiles.
        // Note: assumes h is even. All game footer regions are 24px tall.
        const half_h = h / 2;
        var norm_upper: [digit_mod.n_row_half_bins]f32 = undefined;
        var norm_lower: [digit_mod.n_row_half_bins]f32 = undefined;
        proj.normalizeProfile(char_row[0..half_h], &norm_upper);
        proj.normalizeProfile(char_row[half_h..h], &norm_lower);

        const d = digit_mod.classifyDigit(.{
            .col = norm_col,
            .row = norm_row,
            .row_upper = norm_upper,
            .row_lower = norm_lower,
        });

        value = value * 10 + d;
    }

    return value;
}

/// Parse a quantity from a number region image.
/// The region contains italic blue text "x{number}" on an icon background.
/// A horizontal shear (deskew) is applied first to correct the italic lean.
///
/// pixels: RGB buffer of the number region
/// w, h: dimensions
/// Returns: parsed quantity, or null if OCR failed.
pub fn parseQuantity(
    pixels: []const u8,
    w: u32,
    h: u32,
) ?u32 {
    var deskew_buf: [max_deskew_buf_size]u8 = undefined;
    const deskewed = deskew(&deskew_buf, pixels, w, h);
    return recognizeDigits(deskewed.pixels, deskewed.w, h);
}

// Integration tests live in test/ocr_test.zig (separate module to keep
// test fixture data out of the src/ package path).

// ── Unit tests ──

test "deskew: output width increases by ceil(skew_factor * height)" {
    // 4x2 image, skew_factor=0.25 → extra = ceil(0.25 * 2) = 1 → dst_w = 5
    const pixels = [_]u8{
        255, 0, 0, 0, 255, 0, 0, 0, 255, 128, 128, 128, // row 0: R, G, B, gray
        64,  64, 64, 32, 32, 32, 16, 16, 16, 8, 8, 8, // row 1
    };
    var buf: [5 * 2 * 3]u8 = undefined;
    const result = deskew(&buf, &pixels, 4, 2);
    try std.testing.expectEqual(@as(u32, 5), result.w);
    try std.testing.expectEqual(@as(usize, 5 * 2 * 3), result.pixels.len);
    // Row 0 (shift=0): first pixel should be original (255, 0, 0)
    try std.testing.expectEqual(@as(u8, 255), result.pixels[0]);
    try std.testing.expectEqual(@as(u8, 0), result.pixels[1]);
    try std.testing.expectEqual(@as(u8, 0), result.pixels[2]);
}

test "deskew: 1x1 image preserves pixel" {
    const pixels = [_]u8{ 100, 150, 200 };
    // extra = ceil(0.25 * 1) = 1 → dst_w = 2
    var buf: [2 * 1 * 3]u8 = undefined;
    const result = deskew(&buf, &pixels, 1, 1);
    try std.testing.expectEqual(@as(u32, 2), result.w);
    // First pixel at (0,0): shift=0, src_xf=0.0 → copies original
    try std.testing.expectEqual(@as(u8, 100), result.pixels[0]);
    try std.testing.expectEqual(@as(u8, 150), result.pixels[1]);
    try std.testing.expectEqual(@as(u8, 200), result.pixels[2]);
}

test "recognizeDigits: all-black returns null" {
    var pixels: [30 * 10 * 3]u8 = undefined;
    @memset(&pixels, 0);
    try std.testing.expect(recognizeDigits(&pixels, 30, 10) == null);
}

test "recognizeDigits: all-white returns null" {
    var pixels: [30 * 10 * 3]u8 = undefined;
    @memset(&pixels, 255);
    try std.testing.expect(recognizeDigits(&pixels, 30, 10) == null);
}
