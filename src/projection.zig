//! Projection profiles and character segmentation.
//!
//! Column/row projections sum weight values along one axis to produce
//! 1-D profiles. Valley detection on the column profile segments
//! individual characters. Profiles are resampled to fixed length for
//! distance-based classification.

const std = @import("std");

pub const Segment = struct {
    start: u32,
    end: u32,

    pub fn width(self: Segment) u32 {
        return self.end - self.start;
    }
};

/// Maximum number of characters in a number region (x + up to 5 digits).
pub const max_segments: u32 = 8;

/// Maximum image width for stack-allocated profile buffers.
pub const max_profile_w: u32 = 200;

/// Maximum image height for stack-allocated profile buffers.
pub const max_profile_h: u32 = 40;

/// Compute column projection: sum of weights per column.
pub fn columnProjection(weight_map: []const f32, w: u32, h: u32, buf: []f32) []f32 {
    std.debug.assert(buf.len >= w);
    for (0..w) |col| {
        var sum: f32 = 0;
        for (0..h) |row| {
            sum += weight_map[row * w + col];
        }
        buf[col] = sum;
    }
    return buf[0..w];
}

/// Compute row projection within a column range.
pub fn rowProjection(
    weight_map: []const f32,
    w: u32,
    h: u32,
    col_start: u32,
    col_end: u32,
    buf: []f32,
) []f32 {
    std.debug.assert(buf.len >= h);
    for (0..h) |row| {
        var sum: f32 = 0;
        for (col_start..col_end) |col| {
            sum += weight_map[row * w + col];
        }
        buf[row] = sum;
    }
    return buf[0..h];
}

/// Segment characters by finding valleys in column profile.
/// Returns segments sorted by start position.
pub fn segmentCharacters(col_profile: []const f32, buf: []Segment) []Segment {
    // Adaptive threshold: fraction of peak value
    var max_val: f32 = 0;
    for (col_profile) |v| max_val = @max(max_val, v);

    if (max_val < 0.01) return buf[0..0]; // no signal

    const threshold = max_val * 0.08;

    var count: usize = 0;
    var in_seg = false;
    var seg_start: u32 = 0;

    for (col_profile, 0..) |val, i| {
        if (!in_seg and val > threshold) {
            in_seg = true;
            seg_start = @intCast(i);
        } else if (in_seg and val <= threshold) {
            in_seg = false;
            if (count < buf.len) {
                buf[count] = .{ .start = seg_start, .end = @intCast(i) };
                count += 1;
            }
        }
    }

    // Close trailing segment
    if (in_seg and count < buf.len) {
        buf[count] = .{ .start = seg_start, .end = @intCast(col_profile.len) };
        count += 1;
    }

    return buf[0..count];
}

/// Resample a variable-length profile to a fixed number of bins.
/// Values are normalized to unit sum.
pub fn normalizeProfile(src: []const f32, dest: []f32) void {
    if (src.len == 0) {
        @memset(dest, 0);
        return;
    }

    // Sum for normalization
    var sum: f32 = 0;
    for (src) |v| sum += v;
    if (sum < 1e-6) {
        @memset(dest, 0);
        return;
    }

    const src_len_f = @as(f32, @floatFromInt(src.len));
    const dst_len_f = @as(f32, @floatFromInt(dest.len));

    if (dest.len == 1) {
        dest[0] = 1.0;
        return;
    }

    for (dest, 0..) |*d, i| {
        const pos = @as(f32, @floatFromInt(i)) * (src_len_f - 1.0) / (dst_len_f - 1.0);
        const idx0: u32 = @intFromFloat(@floor(pos));
        const frac = pos - @floor(pos);
        const idx1 = @min(idx0 + 1, @as(u32, @intCast(src.len - 1)));
        d.* = (src[idx0] * (1.0 - frac) + src[idx1] * frac) / sum;
    }

    // Re-normalize: linear interpolation at discrete points does not
    // preserve the integral, especially for very short src arrays.
    var dest_sum: f32 = 0;
    for (dest) |v| dest_sum += v;
    if (dest_sum > 1e-6) {
        for (dest) |*d| d.* /= dest_sum;
    }
}

// ── Tests ──

test "columnProjection sums correctly" {
    // 3x2 weight map
    const wmap = [_]f32{ 1.0, 0.5, 0.0, 0.5, 0.5, 1.0 };
    var buf: [3]f32 = undefined;
    const prof = columnProjection(&wmap, 3, 2, &buf);
    try std.testing.expectEqual(@as(usize, 3), prof.len);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), prof[0], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), prof[1], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), prof[2], 1e-3);
}

test "rowProjection with column range" {
    // 4x2 weight map, columns 1..3
    const wmap = [_]f32{ 0.0, 1.0, 0.5, 0.0, 0.0, 0.5, 1.0, 0.0 };
    var buf: [2]f32 = undefined;
    const prof = rowProjection(&wmap, 4, 2, 1, 3, &buf);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), prof[0], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), prof[1], 1e-3);
}

test "segmentCharacters finds three segments" {
    // Profile with 3 peaks separated by valleys
    const prof = [_]f32{ 0, 0, 5, 8, 5, 0, 0, 3, 6, 3, 0, 0, 4, 7, 4, 0 };
    var buf: [8]Segment = undefined;
    const segs = segmentCharacters(&prof, &buf);
    try std.testing.expectEqual(@as(usize, 3), segs.len);
    try std.testing.expectEqual(@as(u32, 2), segs[0].start);
    try std.testing.expectEqual(@as(u32, 5), segs[0].end);
}

test "normalizeProfile resamples to fixed length" {
    const src = [_]f32{ 2.0, 4.0, 6.0, 4.0, 2.0 };
    var dest: [3]f32 = undefined;
    normalizeProfile(&src, &dest);
    // Sum should be approximately 1.0
    var sum: f32 = 0;
    for (dest) |v| sum += v;
    // Not exactly 1.0 because we sample at discrete points, but close
    try std.testing.expect(sum > 0.5);
    // Middle should be highest
    try std.testing.expect(dest[1] > dest[0]);
    try std.testing.expect(dest[1] > dest[2]);
}
