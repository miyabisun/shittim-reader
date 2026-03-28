//! Color analysis: RGB→HSV conversion and rarity classification.
//!
//! Used to disambiguate same-shape items by their rarity color:
//! N (gray), R (blue), SR (gold), SSR (purple).

const std = @import("std");

pub const Hsv = struct {
    h: f32, // 0-360 degrees
    s: f32, // 0-1
    v: f32, // 0-1
};

pub const Rarity = enum {
    N, // gray/silver — low saturation
    R, // blue — hue ~190-250°
    SR, // gold/yellow — hue ~30-70°
    SSR, // purple — hue ~260-310°
};

/// Convert RGB (0-255 each) to HSV.
pub fn rgbToHsv(r: u8, g: u8, b: u8) Hsv {
    const rf: f32 = @as(f32, @floatFromInt(r)) / 255.0;
    const gf: f32 = @as(f32, @floatFromInt(g)) / 255.0;
    const bf: f32 = @as(f32, @floatFromInt(b)) / 255.0;

    const max_val = @max(rf, @max(gf, bf));
    const min_val = @min(rf, @min(gf, bf));
    const delta = max_val - min_val;

    // Value
    const v = max_val;

    // Saturation
    const s: f32 = if (max_val < 1e-6) 0 else delta / max_val;

    // Hue
    var h: f32 = 0;
    if (delta > 1e-6) {
        if (max_val == rf) {
            h = 60.0 * (gf - bf) / delta;
        } else if (max_val == gf) {
            h = 120.0 + 60.0 * (bf - rf) / delta;
        } else {
            h = 240.0 + 60.0 * (rf - gf) / delta;
        }
        if (h < 0) h += 360.0;
    }

    return .{ .h = h, .s = s, .v = v };
}

/// Classify rarity from HSV values.
pub fn classifyRarity(hsv: Hsv) Rarity {
    // Low saturation = gray (Normal)
    if (hsv.s < 0.25) return .N;

    // Hue-based classification
    if (hsv.h >= 30 and hsv.h <= 70) return .SR; // gold
    if (hsv.h >= 190 and hsv.h <= 250) return .R; // blue
    if (hsv.h >= 260 and hsv.h <= 310) return .SSR; // purple

    return .N;
}

/// Compute average color of an RGB pixel region and classify rarity.
/// pixels: row-major RGB buffer (3 bytes per pixel).
pub fn regionRarity(pixels: []const u8, w: u32, h: u32) Rarity {
    const count: u64 = @as(u64, w) * h;
    if (count == 0) return .N;
    std.debug.assert(pixels.len == count * 3);

    var sum_r: u64 = 0;
    var sum_g: u64 = 0;
    var sum_b: u64 = 0;

    var i: usize = 0;
    while (i + 2 < pixels.len) : (i += 3) {
        sum_r += pixels[i];
        sum_g += pixels[i + 1];
        sum_b += pixels[i + 2];
    }

    const avg_r: u8 = @intCast(sum_r / count);
    const avg_g: u8 = @intCast(sum_g / count);
    const avg_b: u8 = @intCast(sum_b / count);

    return classifyRarity(rgbToHsv(avg_r, avg_g, avg_b));
}

// ── Tests ──

test "pure red → H=0, S=1, V=1" {
    const hsv = rgbToHsv(255, 0, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0), hsv.h, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 1), hsv.s, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 1), hsv.v, 1e-3);
}

test "pure green → H=120" {
    const hsv = rgbToHsv(0, 255, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 120), hsv.h, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 1), hsv.s, 1e-3);
}

test "pure blue → H=240" {
    const hsv = rgbToHsv(0, 0, 255);
    try std.testing.expectApproxEqAbs(@as(f32, 240), hsv.h, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 1), hsv.s, 1e-3);
}

test "white → S=0, V=1" {
    const hsv = rgbToHsv(255, 255, 255);
    try std.testing.expectApproxEqAbs(@as(f32, 0), hsv.s, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 1), hsv.v, 1e-3);
}

test "black → S=0, V=0" {
    const hsv = rgbToHsv(0, 0, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0), hsv.s, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0), hsv.v, 1e-3);
}

test "gray → Rarity.N" {
    const hsv = rgbToHsv(128, 128, 128);
    try std.testing.expectEqual(Rarity.N, classifyRarity(hsv));
}

test "blue → Rarity.R" {
    const hsv = rgbToHsv(50, 100, 200);
    try std.testing.expectEqual(Rarity.R, classifyRarity(hsv));
}

test "gold → Rarity.SR" {
    const hsv = rgbToHsv(200, 180, 50);
    try std.testing.expectEqual(Rarity.SR, classifyRarity(hsv));
}

test "purple → Rarity.SSR" {
    const hsv = rgbToHsv(150, 50, 200);
    try std.testing.expectEqual(Rarity.SSR, classifyRarity(hsv));
}

test "regionRarity: 2x2 blue region" {
    // 4 blue-ish pixels
    const pixels = [_]u8{
        50, 100, 200, 60, 110, 210,
        40, 90,  190, 70, 120, 220,
    };
    const rarity = regionRarity(&pixels, 2, 2);
    try std.testing.expectEqual(Rarity.R, rarity);
}
