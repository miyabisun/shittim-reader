//! Image normalization: scale arbitrary resolution to canonical 1600×900 RGB.

const std = @import("std");
const area_average = @import("area_average.zig");

pub const canonical_width: u32 = 1600;
pub const canonical_height: u32 = 900;

pub const NormalizeResult = struct {
    pixels: []u8, // RGB buffer (3 bytes per pixel)
    width: u32, // always 1600
    height: u32, // always 900

    pub fn deinit(self: NormalizeResult, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

/// Normalize any resolution image to 1600×900 RGB.
/// Handles RGB (3ch) and RGBA (4ch) input.
/// RGBA is downscaled directly and alpha is dropped in a single pass
/// (no intermediate full-resolution RGB buffer needed).
pub fn normalize(
    allocator: std.mem.Allocator,
    src: []const u8,
    width: u32,
    height: u32,
    channels: u32,
) !NormalizeResult {
    std.debug.assert(channels == 3 or channels == 4);

    if (channels == 4) {
        // Downscale RGBA, outputting only RGB (drop alpha in the same pass)
        const result = try area_average.areaAverageToRgb(
            allocator,
            src,
            width,
            height,
            canonical_width,
            canonical_height,
            4,
        );

        return .{
            .pixels = result,
            .width = canonical_width,
            .height = canonical_height,
        };
    }

    // RGB input: area average directly
    const result = try area_average.areaAverage(
        allocator,
        src,
        width,
        height,
        canonical_width,
        canonical_height,
        3,
    );

    return .{
        .pixels = result,
        .width = canonical_width,
        .height = canonical_height,
    };
}

/// Compute target height that preserves the source aspect ratio
/// when scaling to canonical_width.
pub fn aspectHeight(src_w: u32, src_h: u32) u32 {
    return @intFromFloat(
        @round(@as(f32, @floatFromInt(src_h)) * @as(f32, @floatFromInt(canonical_width)) / @as(f32, @floatFromInt(src_w))),
    );
}

/// Normalize any resolution image to canonical_width, preserving aspect ratio.
/// Handles RGB (3ch) and RGBA (4ch) input.
pub fn normalizePreservingAspect(
    allocator: std.mem.Allocator,
    src: []const u8,
    width: u32,
    height: u32,
    channels: u32,
) !NormalizeResult {
    const dst_h = aspectHeight(width, height);

    if (channels == 4) {
        const result = try area_average.areaAverageToRgb(
            allocator, src, width, height, canonical_width, dst_h, 4,
        );
        return .{ .pixels = result, .width = canonical_width, .height = dst_h };
    }

    const result = try area_average.areaAverage(
        allocator, src, width, height, canonical_width, dst_h, 3,
    );
    return .{ .pixels = result, .width = canonical_width, .height = dst_h };
}

// ── Tests ──

test "normalize 3200x1800 RGB → 1600x900" {
    const alloc = std.testing.allocator;
    const src_w: u32 = 3200;
    const src_h: u32 = 1800;
    const src = try alloc.alloc(u8, src_w * src_h * 3);
    defer alloc.free(src);
    @memset(src, 128);

    const result = try normalize(alloc, src, src_w, src_h, 3);
    defer result.deinit(alloc);

    try std.testing.expectEqual(canonical_width, result.width);
    try std.testing.expectEqual(canonical_height, result.height);
    try std.testing.expectEqual(@as(usize, 1600 * 900 * 3), result.pixels.len);
    try std.testing.expectEqual(@as(u8, 128), result.pixels[0]);
}

test "normalize RGBA input → RGB output" {
    const alloc = std.testing.allocator;
    const src_w: u32 = 1600;
    const src_h: u32 = 900;
    const src = try alloc.alloc(u8, src_w * src_h * 4);
    defer alloc.free(src);
    for (0..src_w * src_h) |i| {
        src[i * 4] = 100;
        src[i * 4 + 1] = 150;
        src[i * 4 + 2] = 200;
        src[i * 4 + 3] = 255;
    }

    const result = try normalize(alloc, src, src_w, src_h, 4);
    defer result.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1600 * 900 * 3), result.pixels.len);
    try std.testing.expectEqual(@as(u8, 100), result.pixels[0]);
    try std.testing.expectEqual(@as(u8, 150), result.pixels[1]);
    try std.testing.expectEqual(@as(u8, 200), result.pixels[2]);
}

test "output dimensions always 1600x900" {
    const alloc = std.testing.allocator;
    const src_w: u32 = 1920;
    const src_h: u32 = 1080;
    const src = try alloc.alloc(u8, src_w * src_h * 3);
    defer alloc.free(src);
    @memset(src, 64);

    const result = try normalize(alloc, src, src_w, src_h, 3);
    defer result.deinit(alloc);

    try std.testing.expectEqual(canonical_width, result.width);
    try std.testing.expectEqual(canonical_height, result.height);
}

// ── aspectHeight tests ──

test "aspectHeight: 16:9 → 900" {
    try std.testing.expectEqual(@as(u32, 900), aspectHeight(1920, 1080));
    try std.testing.expectEqual(@as(u32, 900), aspectHeight(3200, 1800));
    try std.testing.expectEqual(@as(u32, 900), aspectHeight(1600, 900));
}

test "aspectHeight: 4:3 → 1200" {
    try std.testing.expectEqual(@as(u32, 1200), aspectHeight(1744, 1308));
    try std.testing.expectEqual(@as(u32, 1200), aspectHeight(1600, 1200));
}

test "aspectHeight: non-standard ratios" {
    // 2560x1440 (16:9) → 900
    try std.testing.expectEqual(@as(u32, 900), aspectHeight(2560, 1440));
    // 800x600 (4:3) → 1200
    try std.testing.expectEqual(@as(u32, 1200), aspectHeight(800, 600));
}

// ── normalizePreservingAspect tests ──

test "normalizePreservingAspect: 4:3 preserves aspect ratio" {
    const alloc = std.testing.allocator;
    const src_w: u32 = 1744;
    const src_h: u32 = 1308;
    const src = try alloc.alloc(u8, src_w * src_h * 3);
    defer alloc.free(src);
    @memset(src, 128);

    const result = try normalizePreservingAspect(alloc, src, src_w, src_h, 3);
    defer result.deinit(alloc);

    try std.testing.expectEqual(@as(u32, 1600), result.width);
    try std.testing.expectEqual(@as(u32, 1200), result.height);
    try std.testing.expectEqual(@as(usize, 1600 * 1200 * 3), result.pixels.len);
}

test "normalizePreservingAspect: 16:9 matches normalize output" {
    const alloc = std.testing.allocator;
    const src_w: u32 = 1920;
    const src_h: u32 = 1080;
    const src = try alloc.alloc(u8, src_w * src_h * 3);
    defer alloc.free(src);
    @memset(src, 64);

    const aspect = try normalizePreservingAspect(alloc, src, src_w, src_h, 3);
    defer aspect.deinit(alloc);
    const fixed = try normalize(alloc, src, src_w, src_h, 3);
    defer fixed.deinit(alloc);

    try std.testing.expectEqual(fixed.width, aspect.width);
    try std.testing.expectEqual(fixed.height, aspect.height);
}

test "normalizePreservingAspect: RGBA input → RGB output" {
    const alloc = std.testing.allocator;
    const src_w: u32 = 800;
    const src_h: u32 = 600;
    const src = try alloc.alloc(u8, src_w * src_h * 4);
    defer alloc.free(src);
    for (0..src_w * src_h) |i| {
        src[i * 4] = 100;
        src[i * 4 + 1] = 150;
        src[i * 4 + 2] = 200;
        src[i * 4 + 3] = 255;
    }

    const result = try normalizePreservingAspect(alloc, src, src_w, src_h, 4);
    defer result.deinit(alloc);

    // Output is RGB (3ch), not RGBA
    try std.testing.expectEqual(@as(usize, 1600 * 1200 * 3), result.pixels.len);
    try std.testing.expectEqual(@as(u8, 100), result.pixels[0]);
    try std.testing.expectEqual(@as(u8, 150), result.pixels[1]);
    try std.testing.expectEqual(@as(u8, 200), result.pixels[2]);
}
