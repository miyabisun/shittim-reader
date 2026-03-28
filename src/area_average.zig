//! Area averaging (box filter) downscale algorithm.
//!
//! Each output pixel is the weighted mean of ALL input pixels that overlap
//! the output pixel's area. This makes results resolution-independent:
//! the same downscale ratio always produces the same output regardless of source size.

const std = @import("std");

/// Generic area-average downscale.
/// Reads `src_channels` per input pixel, writes `out_channels` per output pixel
/// (always the first `out_channels` of the source).
fn areaAverageGeneric(
    allocator: std.mem.Allocator,
    src: []const u8,
    src_w: u32,
    src_h: u32,
    dst_w: u32,
    dst_h: u32,
    src_channels: u32,
    out_channels: u32,
) ![]u8 {
    const dst_len = dst_w * dst_h * out_channels;
    const dst = try allocator.alloc(u8, dst_len);
    errdefer allocator.free(dst);

    const sw: f64 = @floatFromInt(src_w);
    const sh: f64 = @floatFromInt(src_h);
    const dw: f64 = @floatFromInt(dst_w);
    const dh: f64 = @floatFromInt(dst_h);

    for (0..dst_h) |oy| {
        const oy_f: f64 = @floatFromInt(oy);
        const sy_start = oy_f * sh / dh;
        const sy_end = (oy_f + 1.0) * sh / dh;

        for (0..dst_w) |ox| {
            const ox_f: f64 = @floatFromInt(ox);
            const sx_start = ox_f * sw / dw;
            const sx_end = (ox_f + 1.0) * sw / dw;

            var sums: [4]f64 = .{ 0, 0, 0, 0 };
            var total_weight: f64 = 0;

            const iy_begin: u32 = @intFromFloat(@floor(sy_start));
            const iy_end = @min(@as(u32, @intFromFloat(@ceil(sy_end))), src_h);
            const ix_begin: u32 = @intFromFloat(@floor(sx_start));
            const ix_end = @min(@as(u32, @intFromFloat(@ceil(sx_end))), src_w);

            for (iy_begin..iy_end) |iy| {
                const iy_f: f64 = @floatFromInt(iy);
                const y_overlap = @min(iy_f + 1.0, sy_end) - @max(iy_f, sy_start);

                for (ix_begin..ix_end) |ix| {
                    const ix_f: f64 = @floatFromInt(ix);
                    const x_overlap = @min(ix_f + 1.0, sx_end) - @max(ix_f, sx_start);
                    const weight = x_overlap * y_overlap;

                    const src_idx = (iy * src_w + @as(u32, @intCast(ix))) * src_channels;
                    for (0..out_channels) |c| {
                        sums[c] += @as(f64, @floatFromInt(src[src_idx + c])) * weight;
                    }
                    total_weight += weight;
                }
            }

            const dst_idx = (@as(u32, @intCast(oy)) * dst_w + @as(u32, @intCast(ox))) * out_channels;
            for (0..out_channels) |c| {
                const val = sums[c] / total_weight;
                dst[dst_idx + c] = @intFromFloat(@round(@min(@max(val, 0), 255)));
            }
        }
    }

    return dst;
}

/// Downscale an image using area averaging (box filter).
///
/// Parameters:
///   allocator: memory allocator for output buffer
///   src: source pixel buffer (row-major, tightly packed)
///   src_w, src_h: source dimensions
///   dst_w, dst_h: target dimensions
///   channels: 3 (RGB) or 4 (RGBA)
///
/// Returns: allocated buffer of dst_w * dst_h * channels bytes.
/// Caller owns the returned memory.
pub fn areaAverage(
    allocator: std.mem.Allocator,
    src: []const u8,
    src_w: u32,
    src_h: u32,
    dst_w: u32,
    dst_h: u32,
    channels: u32,
) ![]u8 {
    return areaAverageGeneric(allocator, src, src_w, src_h, dst_w, dst_h, channels, channels);
}

/// Area average downscale with channel conversion: read `src_channels` from input,
/// output only the first 3 channels (RGB). Useful for RGBA→RGB in a single pass.
pub fn areaAverageToRgb(
    allocator: std.mem.Allocator,
    src: []const u8,
    src_w: u32,
    src_h: u32,
    dst_w: u32,
    dst_h: u32,
    src_channels: u32,
) ![]u8 {
    return areaAverageGeneric(allocator, src, src_w, src_h, dst_w, dst_h, src_channels, 3);
}

// ── Tests ──

test "2x2 → 1x1 RGB" {
    const alloc = std.testing.allocator;
    // 4 pixels: [100,0,0], [200,0,0], [0,100,0], [0,200,0]
    const src = [_]u8{ 100, 0, 0, 200, 0, 0, 0, 100, 0, 0, 200, 0 };
    const dst = try areaAverage(alloc, &src, 2, 2, 1, 1, 3);
    defer alloc.free(dst);

    try std.testing.expectEqual(@as(usize, 3), dst.len);
    try std.testing.expectEqual(@as(u8, 75), dst[0]); // (100+200+0+0)/4
    try std.testing.expectEqual(@as(u8, 75), dst[1]); // (0+0+100+200)/4
    try std.testing.expectEqual(@as(u8, 0), dst[2]);
}

test "4x4 → 2x2 RGB" {
    const alloc = std.testing.allocator;
    // 4x4 image where each 2x2 block has a uniform color
    // Block (0,0): all 40, Block (1,0): all 80
    // Block (0,1): all 120, Block (1,1): all 200
    var src: [4 * 4 * 3]u8 = undefined;
    for (0..4) |y| {
        for (0..4) |x| {
            const val: u8 = if (y < 2)
                (if (x < 2) 40 else 80)
            else
                (if (x < 2) 120 else 200);
            const idx = (y * 4 + x) * 3;
            src[idx] = val;
            src[idx + 1] = val;
            src[idx + 2] = val;
        }
    }
    const dst = try areaAverage(alloc, &src, 4, 4, 2, 2, 3);
    defer alloc.free(dst);

    try std.testing.expectEqual(@as(usize, 12), dst.len);
    try std.testing.expectEqual(@as(u8, 40), dst[0]);
    try std.testing.expectEqual(@as(u8, 80), dst[3]);
    try std.testing.expectEqual(@as(u8, 120), dst[6]);
    try std.testing.expectEqual(@as(u8, 200), dst[9]);
}

test "RGBA 4 channels" {
    const alloc = std.testing.allocator;
    // 2x2 RGBA → 1x1
    const src = [_]u8{
        100, 50, 25, 255,
        200, 50, 25, 128,
        0,   50, 25, 0,
        100, 50, 25, 64,
    };
    const dst = try areaAverage(alloc, &src, 2, 2, 1, 1, 4);
    defer alloc.free(dst);

    try std.testing.expectEqual(@as(usize, 4), dst.len);
    try std.testing.expectEqual(@as(u8, 100), dst[0]); // (100+200+0+100)/4
    try std.testing.expectEqual(@as(u8, 50), dst[1]);
    try std.testing.expectEqual(@as(u8, 25), dst[2]);
    try std.testing.expectEqual(@as(u8, 112), dst[3]); // (255+128+0+64)/4 = 111.75 → 112
}

test "non-integer scale 3x3 → 2x2" {
    const alloc = std.testing.allocator;
    // 3x3 uniform 100 → 2x2 should still be 100
    var src: [3 * 3 * 3]u8 = undefined;
    @memset(&src, 100);
    const dst = try areaAverage(alloc, &src, 3, 3, 2, 2, 3);
    defer alloc.free(dst);

    for (dst) |v| {
        try std.testing.expectEqual(@as(u8, 100), v);
    }
}

test "1x1 identity" {
    const alloc = std.testing.allocator;
    const src = [_]u8{ 42, 128, 255 };
    const dst = try areaAverage(alloc, &src, 1, 1, 1, 1, 3);
    defer alloc.free(dst);

    try std.testing.expectEqual(@as(u8, 42), dst[0]);
    try std.testing.expectEqual(@as(u8, 128), dst[1]);
    try std.testing.expectEqual(@as(u8, 255), dst[2]);
}

test "same size identity" {
    const alloc = std.testing.allocator;
    const src = [_]u8{ 10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120 };
    const dst = try areaAverage(alloc, &src, 2, 2, 2, 2, 3);
    defer alloc.free(dst);

    try std.testing.expectEqualSlices(u8, &src, dst);
}

test "areaAverageToRgb RGBA→RGB 2x2→1x1" {
    const alloc = std.testing.allocator;
    const src = [_]u8{
        100, 50, 25, 255,
        200, 50, 25, 128,
        0,   50, 25, 0,
        100, 50, 25, 64,
    };
    const dst = try areaAverageToRgb(alloc, &src, 2, 2, 1, 1, 4);
    defer alloc.free(dst);

    try std.testing.expectEqual(@as(usize, 3), dst.len);
    try std.testing.expectEqual(@as(u8, 100), dst[0]);
    try std.testing.expectEqual(@as(u8, 50), dst[1]);
    try std.testing.expectEqual(@as(u8, 25), dst[2]);
}
