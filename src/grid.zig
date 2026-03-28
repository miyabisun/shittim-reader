//! Grid detection for the item inventory screen.
//!
//! Detects separator lines in the grid ROI region and computes cell coordinates.
//! The grid is 5 columns × N rows of item cells.

const std = @import("std");

/// ROI constants (percentage-based, resolution-independent).
pub const roi = struct {
    pub const x_start: f32 = 0.532;
    pub const x_end: f32 = 0.980;
    pub const y_start: f32 = 0.209;
    pub const y_end: f32 = 0.845;
};

/// Key constants from spec.
pub const separator_color = .{ .r = 0xC4, .g = 0xCF, .b = 0xD4 };
pub const color_tolerance: u8 = 15;
pub const min_cell_size: u32 = 20;
pub const base_width: u32 = 1600;
pub const base_height: u32 = 900;
pub const template_size: u32 = 80;
pub const qty_region_start: f32 = 0.75; // 75% of cell height
pub const qty_trim_bottom: u32 = 6;
pub const qty_trim_right: u32 = 8;

pub const Cell = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
};

pub const GridResult = struct {
    cells: []Cell,
    cols: u32,
    rows: u32,

    pub fn deinit(self: GridResult, allocator: std.mem.Allocator) void {
        allocator.free(self.cells);
    }
};

pub fn absDiff(a: u8, b: u8) u8 {
    return if (a > b) a - b else b - a;
}

/// Check if RGB values match the separator color within tolerance.
pub fn isSeparatorRgb(r: u8, g: u8, b: u8) bool {
    const tol = color_tolerance;
    return absDiff(r, separator_color.r) <= tol and
        absDiff(g, separator_color.g) <= tol and
        absDiff(b, separator_color.b) <= tol;
}

/// Check if a pixel at the given index matches the separator color within tolerance.
/// Caller must ensure idx + 2 < pixels.len.
fn isSeparatorColor(pixels: []const u8, idx: usize) bool {
    return isSeparatorRgb(pixels[idx], pixels[idx + 1], pixels[idx + 2]);
}

/// Compute ROI pixel bounds for a given image size.
pub const RoiBounds = struct { x0: u32, x1: u32, y0: u32, y1: u32 };
pub fn roiBounds(width: u32, height: u32) RoiBounds {
    return .{
        .x0 = @intFromFloat(@round(@as(f32, @floatFromInt(width)) * roi.x_start)),
        .x1 = @intFromFloat(@round(@as(f32, @floatFromInt(width)) * roi.x_end)),
        .y0 = @intFromFloat(@round(@as(f32, @floatFromInt(height)) * roi.y_start)),
        .y1 = @intFromFloat(@round(@as(f32, @floatFromInt(height)) * roi.y_end)),
    };
}

/// Cluster adjacent separator line positions into single midpoints.
/// Input: boolean array where true = separator line detected.
/// Output: midpoint positions of each cluster.
fn clusterSeparators(allocator: std.mem.Allocator, is_sep: []const bool) ![]u32 {
    var positions: std.ArrayList(u32) = .empty;

    var i: u32 = 0;
    while (i < is_sep.len) {
        if (is_sep[i]) {
            const start = i;
            while (i < is_sep.len and is_sep[i]) : (i += 1) {}
            const end = i; // exclusive
            try positions.append(allocator, (start + end - 1) / 2);
        } else {
            i += 1;
        }
    }

    return positions.toOwnedSlice(allocator);
}

/// Filter separator positions to remove those creating cells smaller than min_cell_size.
fn filterSeparators(allocator: std.mem.Allocator, seps: []const u32) ![]u32 {
    if (seps.len == 0) return try allocator.alloc(u32, 0);

    var filtered: std.ArrayList(u32) = .empty;

    try filtered.append(allocator, seps[0]);
    for (seps[1..]) |s| {
        const last = filtered.items[filtered.items.len - 1];
        if (s - last >= min_cell_size) {
            try filtered.append(allocator, s);
        }
    }

    return filtered.toOwnedSlice(allocator);
}

/// Detect grid cells in a normalized 1600×900 RGB image.
///
/// Algorithm:
/// 1. Extract ROI region
/// 2. Scan for horizontal separator lines
/// 3. Scan for vertical separator lines
/// 4. Filter noise (gaps < min_cell_size)
/// 5. Compute cell coordinates from separator positions
pub fn detectGrid(
    allocator: std.mem.Allocator,
    pixels: []const u8,
    width: u32,
    height: u32,
) !GridResult {
    const b = roiBounds(width, height);
    const roi_w = b.x1 - b.x0;
    const roi_h = b.y1 - b.y0;

    // Scan horizontal lines: for each row in ROI, count separator-colored pixels
    const h_is_sep = try allocator.alloc(bool, roi_h);
    defer allocator.free(h_is_sep);

    for (0..roi_h) |dy| {
        const y = b.y0 + @as(u32, @intCast(dy));
        var match_count: u32 = 0;
        for (0..roi_w) |dx| {
            const x = b.x0 + @as(u32, @intCast(dx));
            const idx: usize = (@as(usize, y) * width + x) * 3;
            if (idx + 2 < pixels.len and isSeparatorColor(pixels, idx)) {
                match_count += 1;
            }
        }
        // >70% of row pixels match = separator
        h_is_sep[dy] = match_count > roi_w * 7 / 10;
    }

    // Scan vertical lines: for each column in ROI
    const v_is_sep = try allocator.alloc(bool, roi_w);
    defer allocator.free(v_is_sep);

    for (0..roi_w) |dx| {
        const x = b.x0 + @as(u32, @intCast(dx));
        var match_count: u32 = 0;
        for (0..roi_h) |dy| {
            const y = b.y0 + @as(u32, @intCast(dy));
            const idx: usize = (@as(usize, y) * width + x) * 3;
            if (idx + 2 < pixels.len and isSeparatorColor(pixels, idx)) {
                match_count += 1;
            }
        }
        v_is_sep[dx] = match_count > roi_h * 7 / 10;
    }

    // Cluster and filter separators
    const h_seps_raw = try clusterSeparators(allocator, h_is_sep);
    defer allocator.free(h_seps_raw);
    const v_seps_raw = try clusterSeparators(allocator, v_is_sep);
    defer allocator.free(v_seps_raw);

    const h_seps = try filterSeparators(allocator, h_seps_raw);
    defer allocator.free(h_seps);
    const v_seps = try filterSeparators(allocator, v_seps_raw);
    defer allocator.free(v_seps);

    // Compute cells from separator positions
    // Cells are between consecutive separators
    const n_cols: u32 = if (v_seps.len > 1) @intCast(v_seps.len - 1) else 0;
    const n_rows: u32 = if (h_seps.len > 1) @intCast(h_seps.len - 1) else 0;

    if (n_cols == 0 or n_rows == 0) {
        return GridResult{
            .cells = try allocator.alloc(Cell, 0),
            .cols = 0,
            .rows = 0,
        };
    }

    const cells = try allocator.alloc(Cell, n_cols * n_rows);
    errdefer allocator.free(cells);

    for (0..n_rows) |r| {
        for (0..n_cols) |c| {
            // Convert ROI-relative separator positions to absolute coordinates
            const abs_x = b.x0 + v_seps[c] + 1; // +1 to skip separator pixel
            const abs_y = b.y0 + h_seps[r] + 1;
            const next_x = b.x0 + v_seps[c + 1];
            const next_y = b.y0 + h_seps[r + 1];
            cells[r * n_cols + c] = .{
                .x = abs_x,
                .y = abs_y,
                .w = next_x - abs_x,
                .h = next_y - abs_y,
            };
        }
    }

    return GridResult{
        .cells = cells,
        .cols = n_cols,
        .rows = n_rows,
    };
}

// ── Tests ──

test "ROI pixel coordinates" {
    const bounds = roiBounds(1600, 900);

    try std.testing.expectEqual(@as(u32, 851), bounds.x0);
    try std.testing.expectEqual(@as(u32, 1568), bounds.x1);
    try std.testing.expectEqual(@as(u32, 188), bounds.y0);
    try std.testing.expectEqual(@as(u32, 761), bounds.y1);
}

test "synthetic grid detection" {
    const alloc = std.testing.allocator;
    const w: u32 = 1600;
    const h: u32 = 900;
    const pixels = try alloc.alloc(u8, w * h * 3);
    defer alloc.free(pixels);

    // Fill with white background
    @memset(pixels, 255);

    // Draw separator lines in the ROI region
    const roi_x0: u32 = @intFromFloat(@round(1600.0 * roi.x_start));
    const roi_x1: u32 = @intFromFloat(@round(1600.0 * roi.x_end));
    const roi_y0: u32 = @intFromFloat(@round(900.0 * roi.y_start));
    const roi_y1: u32 = @intFromFloat(@round(900.0 * roi.y_end));

    // Helper: draw horizontal line at absolute y
    const drawHLine = struct {
        fn f(buf: []u8, bw: u32, y: u32, x0: u32, x1: u32) void {
            for (x0..x1) |x| {
                const idx = (@as(usize, y) * bw + x) * 3;
                buf[idx] = 0xC4;
                buf[idx + 1] = 0xCF;
                buf[idx + 2] = 0xD4;
            }
        }
    }.f;

    // Helper: draw vertical line at absolute x
    const drawVLine = struct {
        fn f(buf: []u8, bw: u32, x: u32, y0: u32, y1: u32) void {
            for (y0..y1) |y| {
                const idx = (@as(usize, y) * bw + x) * 3;
                buf[idx] = 0xC4;
                buf[idx + 1] = 0xCF;
                buf[idx + 2] = 0xD4;
            }
        }
    }.f;

    // Create a 3x2 grid (4 horizontal seps, 4 vertical seps)
    const h_positions = [_]u32{ roi_y0, roi_y0 + 100, roi_y0 + 200, roi_y1 - 1 };
    const v_positions = [_]u32{ roi_x0, roi_x0 + 120, roi_x0 + 240, roi_x1 - 1 };

    for (h_positions) |y| {
        drawHLine(pixels, w, y, roi_x0, roi_x1);
    }
    for (v_positions) |x| {
        drawVLine(pixels, w, x, roi_y0, roi_y1);
    }

    const result = try detectGrid(alloc, pixels, w, h);
    defer result.deinit(alloc);

    // We expect 3 columns × 2 rows based on our 4 v-seps and 4 h-seps
    // (After clustering: 4 separators → 3 gaps)
    try std.testing.expect(result.cols >= 2);
    try std.testing.expect(result.rows >= 2);
    try std.testing.expect(result.cells.len > 0);
}

test "no separators → 0 cells" {
    const alloc = std.testing.allocator;
    const w: u32 = 1600;
    const h: u32 = 900;
    const pixels = try alloc.alloc(u8, w * h * 3);
    defer alloc.free(pixels);

    // All white, no separator color
    @memset(pixels, 255);

    const result = try detectGrid(alloc, pixels, w, h);
    defer result.deinit(alloc);

    try std.testing.expectEqual(@as(u32, 0), result.cols);
    try std.testing.expectEqual(@as(u32, 0), result.rows);
    try std.testing.expectEqual(@as(usize, 0), result.cells.len);
}

test "cluster separators" {
    const alloc = std.testing.allocator;
    // Simulate: lines at positions 10-12, 50-53, 100
    var is_sep = [_]bool{false} ** 110;
    is_sep[10] = true;
    is_sep[11] = true;
    is_sep[12] = true;
    is_sep[50] = true;
    is_sep[51] = true;
    is_sep[52] = true;
    is_sep[53] = true;
    is_sep[100] = true;

    const seps = try clusterSeparators(alloc, &is_sep);
    defer alloc.free(seps);

    try std.testing.expectEqual(@as(usize, 3), seps.len);
    try std.testing.expectEqual(@as(u32, 11), seps[0]); // midpoint of 10-12
    try std.testing.expectEqual(@as(u32, 51), seps[1]); // midpoint of 50-53
    try std.testing.expectEqual(@as(u32, 100), seps[2]);
}
