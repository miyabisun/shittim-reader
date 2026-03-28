//! Digit OCR: recognize quantity numbers from cell footer regions.
//!
//! Uses masked NCC on the green channel to match digit templates.
//! Templates are embedded at compile time from pre-processed gray/mask files.
//! Pre-processing: scripts/preprocess_digits.mjs converts RGBA PNGs to
//! separate green-channel (.gray) and alpha-channel (.mask) files.

const std = @import("std");
const ncc_mod = @import("ncc.zig");

pub const Template = struct {
    width: u32,
    height: u32,
    gray: []const u8, // green channel values (width * height bytes)
    mask: []const u8, // alpha channel values (width * height bytes)
};

/// Pre-extracted digit templates (index 0-9 = digits, 10 = 'x').
/// Gray and mask are separate @embedFile'd files (no comptime extraction needed).
pub const templates = [11]Template{
    .{ .width = 15, .height = 21, .gray = @embedFile("digits/0.gray"), .mask = @embedFile("digits/0.mask") },
    .{ .width = 10, .height = 21, .gray = @embedFile("digits/1.gray"), .mask = @embedFile("digits/1.mask") },
    .{ .width = 17, .height = 21, .gray = @embedFile("digits/2.gray"), .mask = @embedFile("digits/2.mask") },
    .{ .width = 17, .height = 21, .gray = @embedFile("digits/3.gray"), .mask = @embedFile("digits/3.mask") },
    .{ .width = 16, .height = 22, .gray = @embedFile("digits/4.gray"), .mask = @embedFile("digits/4.mask") },
    .{ .width = 17, .height = 21, .gray = @embedFile("digits/5.gray"), .mask = @embedFile("digits/5.mask") },
    .{ .width = 17, .height = 21, .gray = @embedFile("digits/6.gray"), .mask = @embedFile("digits/6.mask") },
    .{ .width = 17, .height = 21, .gray = @embedFile("digits/7.gray"), .mask = @embedFile("digits/7.mask") },
    .{ .width = 16, .height = 21, .gray = @embedFile("digits/8.gray"), .mask = @embedFile("digits/8.mask") },
    .{ .width = 15, .height = 20, .gray = @embedFile("digits/9.gray"), .mask = @embedFile("digits/9.mask") },
    .{ .width = 18, .height = 17, .gray = @embedFile("digits/x.gray"), .mask = @embedFile("digits/x.mask") },
};

const x_template_idx: usize = 10;
const match_threshold: f32 = 0.5;

// Max template dimensions for stack-allocated patch buffer (derived from templates at comptime)
const max_tmpl_w = blk: {
    var m: u32 = 0;
    for (templates) |t| m = @max(m, t.width);
    break :blk m;
};
const max_tmpl_h = blk: {
    var m: u32 = 0;
    for (templates) |t| m = @max(m, t.height);
    break :blk m;
};

/// Extract a patch of green channel values from an RGB image into a provided buffer.
/// Returns the filled slice, or null if the patch extends beyond image bounds.
fn extractGreenPatchBuf(
    buf: []u8,
    pixels: []const u8,
    img_w: u32,
    img_h: u32,
    px: u32,
    py: u32,
    pw: u32,
    ph: u32,
) ?[]u8 {
    if (px + pw > img_w or py + ph > img_h) return null;
    const len = pw * ph;
    if (len > buf.len) return null;
    for (0..ph) |dy| {
        for (0..pw) |dx| {
            const src_idx = ((@as(usize, py) + dy) * img_w + @as(usize, px) + dx) * 3;
            buf[dy * pw + dx] = pixels[src_idx + 1]; // green channel
        }
    }
    return buf[0..len];
}

/// Evaluate NCC score for a single template at a specific position.
/// Uses a stack buffer — no heap allocation.
fn scoreAt(
    pixels: []const u8,
    img_w: u32,
    img_h: u32,
    tmpl: Template,
    px: u32,
    py: u32,
) ?f32 {
    var buf: [max_tmpl_w * max_tmpl_h]u8 = undefined;
    const patch = extractGreenPatchBuf(
        &buf,
        pixels,
        img_w,
        img_h,
        px,
        py,
        tmpl.width,
        tmpl.height,
    ) orelse return null;
    return ncc_mod.maskedNcc(patch, tmpl.gray, tmpl.mask);
}

/// Find the best match position for a template in a horizontal scan range.
/// Returns (x_position, score) or null if no match above threshold.
fn findTemplate(
    pixels: []const u8,
    img_w: u32,
    img_h: u32,
    tmpl: Template,
    search_x_start: u32,
    search_x_end: u32,
    search_y: u32,
) ?struct { x: u32, score: f32 } {
    var best_score: f32 = -1;
    var best_x: u32 = 0;

    const end_x = if (search_x_end > tmpl.width) search_x_end - tmpl.width else 0;
    var x = search_x_start;
    while (x <= end_x) : (x += 1) {
        const score = scoreAt(pixels, img_w, img_h, tmpl, x, search_y) orelse continue;
        if (score > best_score) {
            best_score = score;
            best_x = x;
        }
    }

    if (best_score >= match_threshold) {
        return .{ .x = best_x, .score = best_score };
    }
    return null;
}

/// Parse a quantity from a number region image.
/// The region contains green text "x{number}" on a dark background.
///
/// pixels: RGB buffer of the number region
/// w, h: dimensions
/// Returns: parsed quantity, or null if OCR failed.
pub fn parseQuantity(
    pixels: []const u8,
    w: u32,
    h: u32,
) ?u32 {
    const x_tmpl = templates[x_template_idx];

    // Vertical center for template alignment
    const y_offset: u32 = if (h > x_tmpl.height) (h - x_tmpl.height) / 2 else 0;

    // Step 1: Find "x" character
    const x_result = findTemplate(
        pixels,
        w,
        h,
        x_tmpl,
        0,
        w,
        y_offset,
    ) orelse return null;

    // Step 2: Read digits after "x"
    var cursor = x_result.x + x_tmpl.width;
    var value: u32 = 0;
    var found_digit = false;

    while (cursor < w) {
        var best_digit: ?u32 = null;
        var best_score: f32 = -1;
        var best_x: u32 = 0;
        var best_width: u32 = 0;

        // Try each digit template at a small window around cursor
        for (0..10) |d| {
            const tmpl = templates[d];
            const dy: u32 = if (h > tmpl.height) (h - tmpl.height) / 2 else 0;

            const result = findTemplate(
                pixels,
                w,
                h,
                tmpl,
                cursor,
                @min(cursor + tmpl.width + 4, w),
                dy,
            ) orelse continue;

            if (result.score > best_score) {
                best_score = result.score;
                best_digit = @intCast(d);
                best_x = result.x;
                best_width = tmpl.width;
            }
        }

        if (best_digit) |digit| {
            value = value * 10 + digit;
            cursor = best_x + best_width; // advance to end of matched digit
            found_digit = true;
        } else {
            break;
        }
    }

    if (!found_digit) return null;
    return value;
}

// ── Tests ──

test "templates loaded correctly" {
    for (templates, 0..) |tmpl, i| {
        try std.testing.expect(tmpl.width > 0);
        try std.testing.expect(tmpl.height > 0);
        try std.testing.expectEqual(@as(usize, tmpl.width * tmpl.height), tmpl.gray.len);
        try std.testing.expectEqual(@as(usize, tmpl.width * tmpl.height), tmpl.mask.len);

        var has_nonzero = false;
        for (tmpl.mask) |m| {
            if (m != 0) {
                has_nonzero = true;
                break;
            }
        }
        if (!has_nonzero) {
            std.debug.print("Warning: template {d} has all-zero mask\n", .{i});
        }
    }
}

test "template dimensions match expected" {
    try std.testing.expectEqual(@as(u32, 15), templates[0].width);
    try std.testing.expectEqual(@as(u32, 21), templates[0].height);
    try std.testing.expectEqual(@as(u32, 10), templates[1].width);
    try std.testing.expectEqual(@as(u32, 21), templates[1].height);
    try std.testing.expectEqual(@as(u32, 18), templates[10].width);
    try std.testing.expectEqual(@as(u32, 17), templates[10].height);
}

test "perfect digit self-match" {
    const tmpl = templates[0];

    // Build an RGB image from the template's green channel
    var img: [max_tmpl_w * max_tmpl_h * 3]u8 = undefined;
    for (0..tmpl.width * tmpl.height) |i| {
        img[i * 3] = 0;
        img[i * 3 + 1] = tmpl.gray[i];
        img[i * 3 + 2] = 0;
    }

    const score = scoreAt(img[0 .. tmpl.width * tmpl.height * 3], tmpl.width, tmpl.height, tmpl, 0, 0) orelse unreachable;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), score, 1e-3);
}
