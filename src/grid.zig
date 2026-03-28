//! Grid separator detection and cell coordinate extraction.
//!
//! Detects the grid layout of the item inventory screen by scanning for
//! separator lines of a known color (#C4CFD4). Returns cell coordinates
//! as absolute pixel positions within the normalized 1600x900 image.

const std = @import("std");

// ── Constants ──

pub const BASE_WIDTH: u32 = 1600;
pub const BASE_HEIGHT: u32 = 900;

/// Separator line color: RGB(0xC4, 0xCF, 0xD4)
pub const SEPARATOR_COLOR = [3]u8{ 0xC4, 0xCF, 0xD4 };

/// Per-channel tolerance for separator color matching.
pub const COLOR_TOLERANCE: u8 = 15;

/// Minimum cell dimension in pixels; smaller gaps are treated as noise.
pub const MIN_CELL_SIZE: u32 = 20;

/// Fraction of row/column pixels that must match separator color
/// for the line to be classified as a separator.
pub const SEPARATOR_THRESHOLD: f32 = 0.70;

/// ROI constants (percentage-based, resolution-independent).
pub const roi = struct {
    pub const x_start: f32 = 0.532;
    pub const x_end: f32 = 0.980;
    pub const y_start: f32 = 0.209;
    pub const y_end: f32 = 0.845;
};

/// Quantity region constants.
pub const qty = struct {
    pub const region_start: f32 = 0.75;
    pub const trim_bottom: u32 = 6;
    pub const trim_right: u32 = 8;
};

pub const TEMPLATE_SIZE: u32 = 80;

// ── Types ──

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

// ── Internal helpers ──

/// Check whether a single pixel matches the separator color within tolerance.
fn isSeparatorPixel(r: u8, g: u8, b: u8) bool {
    const dr = absDiff(r, SEPARATOR_COLOR[0]);
    const dg = absDiff(g, SEPARATOR_COLOR[1]);
    const db = absDiff(b, SEPARATOR_COLOR[2]);
    return dr <= COLOR_TOLERANCE and dg <= COLOR_TOLERANCE and db <= COLOR_TOLERANCE;
}

fn absDiff(a: u8, b: u8) u8 {
    return if (a > b) a - b else b - a;
}

/// Compute ROI pixel bounds from image dimensions.
pub fn roiPixels(width: u32, height: u32) struct { x0: u32, x1: u32, y0: u32, y1: u32 } {
    const w: f32 = @floatFromInt(width);
    const h: f32 = @floatFromInt(height);
    return .{
        .x0 = @intFromFloat(@round(roi.x_start * w)),
        .x1 = @intFromFloat(@round(roi.x_end * w)),
        .y0 = @intFromFloat(@round(roi.y_start * h)),
        .y1 = @intFromFloat(@round(roi.y_end * h)),
    };
}

/// Scan horizontal lines in the ROI and return a boolean per row.
/// `out` must have length >= (roi_y1 - roi_y0).
fn scanHorizontalSeparators(
    pixels: []const u8,
    width: u32,
    roi_x0: u32,
    roi_x1: u32,
    roi_y0: u32,
    roi_y1: u32,
    out: []bool,
) void {
    const roi_w = roi_x1 - roi_x0;
    const threshold_count: u32 = @intFromFloat(@as(f32, @floatFromInt(roi_w)) * SEPARATOR_THRESHOLD);

    for (roi_y0..roi_y1) |y| {
        var count: u32 = 0;
        for (roi_x0..roi_x1) |x| {
            const idx = (y * width + x) * 3;
            if (idx + 2 < pixels.len) {
                if (isSeparatorPixel(pixels[idx], pixels[idx + 1], pixels[idx + 2])) {
                    count += 1;
                }
            }
        }
        out[y - roi_y0] = count >= threshold_count;
    }
}

/// Scan vertical lines in the ROI and return a boolean per column.
/// `out` must have length >= (roi_x1 - roi_x0).
fn scanVerticalSeparators(
    pixels: []const u8,
    width: u32,
    roi_x0: u32,
    roi_x1: u32,
    roi_y0: u32,
    roi_y1: u32,
    out: []bool,
) void {
    const roi_h = roi_y1 - roi_y0;
    const threshold_count: u32 = @intFromFloat(@as(f32, @floatFromInt(roi_h)) * SEPARATOR_THRESHOLD);

    for (roi_x0..roi_x1) |x| {
        var count: u32 = 0;
        for (roi_y0..roi_y1) |y| {
            const idx = (y * width + x) * 3;
            if (idx + 2 < pixels.len) {
                if (isSeparatorPixel(pixels[idx], pixels[idx + 1], pixels[idx + 2])) {
                    count += 1;
                }
            }
        }
        out[x - roi_x0] = count >= threshold_count;
    }
}

/// Cluster runs of `true` values into separator midpoint positions.
/// Positions are relative to the start of the boolean array (ROI-relative).
/// Filters out gaps smaller than MIN_CELL_SIZE between separators.
fn clusterSeparators(flags: []const bool, allocator: std.mem.Allocator) ![]u32 {
    var raw_positions: std.ArrayList(u32) = .empty;
    defer raw_positions.deinit(allocator);

    var in_run = false;
    var run_start: u32 = 0;

    for (flags, 0..) |is_sep, i| {
        const idx: u32 = @intCast(i);
        if (is_sep) {
            if (!in_run) {
                run_start = idx;
                in_run = true;
            }
        } else {
            if (in_run) {
                const mid = (run_start + idx) / 2;
                try raw_positions.append(allocator, mid);
                in_run = false;
            }
        }
    }
    // Close final run
    if (in_run) {
        const end: u32 = @intCast(flags.len);
        const mid = (run_start + end) / 2;
        try raw_positions.append(allocator, mid);
    }

    // Filter: remove separators that create cells smaller than MIN_CELL_SIZE
    if (raw_positions.items.len <= 1) {
        return try allocator.dupe(u32, raw_positions.items);
    }

    var filtered: std.ArrayList(u32) = .empty;
    defer filtered.deinit(allocator);
    try filtered.append(allocator, raw_positions.items[0]);

    for (raw_positions.items[1..]) |pos| {
        const last = filtered.items[filtered.items.len - 1];
        if (pos - last >= MIN_CELL_SIZE) {
            try filtered.append(allocator, pos);
        }
        // else: gap too small -> skip (merge with previous)
    }

    return try allocator.dupe(u32, filtered.items);
}

/// Detect grid cells in a normalized RGB image.
///
/// Algorithm:
/// 1. Extract ROI region
/// 2. Scan for horizontal separator lines
/// 3. Scan for vertical separator lines
/// 4. Cluster adjacent separator lines and filter noise
/// 5. Compute cell coordinates from separator positions
///
/// Returns GridResult with cell coordinates in absolute image coordinates.
pub fn detectGrid(
    allocator: std.mem.Allocator,
    pixels: []const u8,
    width: u32,
    height: u32,
) !GridResult {
    const r = roiPixels(width, height);

    const roi_w = r.x1 - r.x0;
    const roi_h = r.y1 - r.y0;

    // Scan for separators
    const h_flags = try allocator.alloc(bool, roi_h);
    defer allocator.free(h_flags);
    scanHorizontalSeparators(pixels, width, r.x0, r.x1, r.y0, r.y1, h_flags);

    const v_flags = try allocator.alloc(bool, roi_w);
    defer allocator.free(v_flags);
    scanVerticalSeparators(pixels, width, r.x0, r.x1, r.y0, r.y1, v_flags);

    // Cluster into separator positions (ROI-relative)
    const h_seps = try clusterSeparators(h_flags, allocator);
    defer allocator.free(h_seps);
    const v_seps = try clusterSeparators(v_flags, allocator);
    defer allocator.free(v_seps);

    // Need at least 2 separators in each direction to form cells
    if (h_seps.len < 2 or v_seps.len < 2) {
        const empty = try allocator.alloc(Cell, 0);
        return GridResult{
            .cells = empty,
            .cols = 0,
            .rows = 0,
        };
    }

    const num_cols = @as(u32, @intCast(v_seps.len)) - 1;
    const num_rows = @as(u32, @intCast(h_seps.len)) - 1;

    var cells = try allocator.alloc(Cell, num_rows * num_cols);
    var cell_idx: usize = 0;

    for (0..num_rows) |row_idx| {
        for (0..num_cols) |col_idx| {
            // Convert ROI-relative separator positions to absolute coordinates
            const abs_x = r.x0 + v_seps[col_idx];
            const abs_y = r.y0 + h_seps[row_idx];
            const abs_x2 = r.x0 + v_seps[col_idx + 1];
            const abs_y2 = r.y0 + h_seps[row_idx + 1];

            cells[cell_idx] = Cell{
                .x = abs_x,
                .y = abs_y,
                .w = abs_x2 - abs_x,
                .h = abs_y2 - abs_y,
            };
            cell_idx += 1;
        }
    }

    return GridResult{
        .cells = cells,
        .cols = num_cols,
        .rows = num_rows,
    };
}

// ══════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════

test "ROI calculation matches percentage * base resolution" {
    const r = roiPixels(BASE_WIDTH, BASE_HEIGHT);

    // x: 53.2% of 1600 = 851.2 -> 851
    // x: 98.0% of 1600 = 1568
    // y: 20.9% of 900  = 188.1 -> 188
    // y: 84.5% of 900  = 760.5 -> 761 (rounded)
    try std.testing.expectEqual(@as(u32, 851), r.x0);
    try std.testing.expectEqual(@as(u32, 1568), r.x1);
    try std.testing.expectEqual(@as(u32, 188), r.y0);
    try std.testing.expectEqual(@as(u32, 761), r.y1);
}

test "isSeparatorPixel exact match" {
    try std.testing.expect(isSeparatorPixel(0xC4, 0xCF, 0xD4));
}

test "isSeparatorPixel within tolerance" {
    // +15 per channel
    try std.testing.expect(isSeparatorPixel(0xC4 + 15, 0xCF + 15, 0xD4 + 15));
    // -15 per channel
    try std.testing.expect(isSeparatorPixel(0xC4 - 15, 0xCF - 15, 0xD4 - 15));
}

test "isSeparatorPixel outside tolerance" {
    try std.testing.expect(!isSeparatorPixel(0xC4 + 16, 0xCF, 0xD4));
    try std.testing.expect(!isSeparatorPixel(0, 0, 0));
    try std.testing.expect(!isSeparatorPixel(255, 255, 255));
}

/// Helper: fill a 1600x900 RGB image with a background color.
fn createTestImage(allocator: std.mem.Allocator, bg_r: u8, bg_g: u8, bg_b: u8) ![]u8 {
    const size = BASE_WIDTH * BASE_HEIGHT * 3;
    const pixels = try allocator.alloc(u8, size);
    var i: usize = 0;
    while (i < size) : (i += 3) {
        pixels[i] = bg_r;
        pixels[i + 1] = bg_g;
        pixels[i + 2] = bg_b;
    }
    return pixels;
}

/// Helper: draw a horizontal separator line at absolute y.
fn drawHLine(pixels: []u8, width: u32, y: u32, x0: u32, x1: u32) void {
    for (x0..x1) |x| {
        const idx = (y * width + x) * 3;
        pixels[idx] = SEPARATOR_COLOR[0];
        pixels[idx + 1] = SEPARATOR_COLOR[1];
        pixels[idx + 2] = SEPARATOR_COLOR[2];
    }
}

/// Helper: draw a vertical separator line at absolute x.
fn drawVLine(pixels: []u8, width: u32, x: u32, y0: u32, y1: u32) void {
    for (y0..y1) |y| {
        const idx = (y * width + x) * 3;
        pixels[idx] = SEPARATOR_COLOR[0];
        pixels[idx + 1] = SEPARATOR_COLOR[1];
        pixels[idx + 2] = SEPARATOR_COLOR[2];
    }
}

test "synthetic grid: known separator positions produce correct cells" {
    const allocator = std.testing.allocator;

    // Create 1600x900 dark background image
    const pixels = try createTestImage(allocator, 40, 40, 60);
    defer allocator.free(pixels);

    const r = roiPixels(BASE_WIDTH, BASE_HEIGHT);

    // Draw 3 horizontal separator lines across the full ROI width (creates 2 rows)
    const h_offsets = [_]u32{ 0, 150, 300 };
    for (h_offsets) |off| {
        const base_y = r.y0 + off;
        for (0..3) |dy| {
            const y = base_y + @as(u32, @intCast(dy));
            if (y < BASE_HEIGHT) {
                drawHLine(pixels, BASE_WIDTH, y, r.x0, r.x1);
            }
        }
    }

    // Draw 4 vertical separator lines across the full ROI height (creates 3 columns)
    const v_offsets = [_]u32{ 0, 200, 400, 600 };
    for (v_offsets) |off| {
        const base_x = r.x0 + off;
        for (0..3) |dx| {
            const x = base_x + @as(u32, @intCast(dx));
            if (x < BASE_WIDTH) {
                drawVLine(pixels, BASE_WIDTH, x, r.y0, r.y1);
            }
        }
    }

    const result = try detectGrid(allocator, pixels, BASE_WIDTH, BASE_HEIGHT);
    defer result.deinit(allocator);

    // Expect 3 cols x 2 rows = 6 cells
    try std.testing.expectEqual(@as(u32, 3), result.cols);
    try std.testing.expectEqual(@as(u32, 2), result.rows);
    try std.testing.expectEqual(@as(usize, 6), result.cells.len);

    // First cell should have width ~200 and height ~150
    const cell0 = result.cells[0];
    try std.testing.expect(cell0.w > 180 and cell0.w < 220);
    try std.testing.expect(cell0.h > 130 and cell0.h < 170);
}

test "no separators produces 0 cells" {
    const allocator = std.testing.allocator;

    // Uniform dark image with no separator colors
    const pixels = try createTestImage(allocator, 40, 40, 60);
    defer allocator.free(pixels);

    const result = try detectGrid(allocator, pixels, BASE_WIDTH, BASE_HEIGHT);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 0), result.cols);
    try std.testing.expectEqual(@as(u32, 0), result.rows);
    try std.testing.expectEqual(@as(usize, 0), result.cells.len);
}

test "single cell: 2 h-separators x 2 v-separators produces 1 cell" {
    const allocator = std.testing.allocator;

    const pixels = try createTestImage(allocator, 40, 40, 60);
    defer allocator.free(pixels);

    const r = roiPixels(BASE_WIDTH, BASE_HEIGHT);

    // Two horizontal separators
    for ([_]u32{ 0, 200 }) |off| {
        const y = r.y0 + off;
        for (0..3) |dy| {
            drawHLine(pixels, BASE_WIDTH, y + @as(u32, @intCast(dy)), r.x0, r.x1);
        }
    }

    // Two vertical separators
    for ([_]u32{ 0, 300 }) |off| {
        const x = r.x0 + off;
        for (0..3) |dx| {
            drawVLine(pixels, BASE_WIDTH, x + @as(u32, @intCast(dx)), r.y0, r.y1);
        }
    }

    const result = try detectGrid(allocator, pixels, BASE_WIDTH, BASE_HEIGHT);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), result.cols);
    try std.testing.expectEqual(@as(u32, 1), result.rows);
    try std.testing.expectEqual(@as(usize, 1), result.cells.len);

    const cell = result.cells[0];
    try std.testing.expect(cell.w > 280 and cell.w < 320);
    try std.testing.expect(cell.h > 180 and cell.h < 220);
}

test "noise filter: gaps smaller than MIN_CELL_SIZE are merged" {
    const allocator = std.testing.allocator;

    const pixels = try createTestImage(allocator, 40, 40, 60);
    defer allocator.free(pixels);

    const r = roiPixels(BASE_WIDTH, BASE_HEIGHT);

    // Draw 3 horizontal separators: first two only 10px apart (< MIN_CELL_SIZE)
    // Should merge into effectively 2 separators -> 1 row
    for ([_]u32{ 0, 10, 200 }) |off| {
        const y = r.y0 + off;
        drawHLine(pixels, BASE_WIDTH, y, r.x0, r.x1);
    }

    // Draw 2 vertical separators with normal spacing
    for ([_]u32{ 0, 300 }) |off| {
        const x = r.x0 + off;
        drawVLine(pixels, BASE_WIDTH, x, r.y0, r.y1);
    }

    const result = try detectGrid(allocator, pixels, BASE_WIDTH, BASE_HEIGHT);
    defer result.deinit(allocator);

    // The close h-separators (0 and 10) should be merged,
    // so we get 2 effective h-separators -> 1 row
    try std.testing.expectEqual(@as(u32, 1), result.cols);
    try std.testing.expectEqual(@as(u32, 1), result.rows);
}

test "cluster separators: adjacent true flags produce single midpoint" {
    const allocator = std.testing.allocator;

    // Simulate a 5px thick separator run at positions 10..15, then another at 200..205
    var flags = [_]bool{false} ** 300;
    for (10..15) |i| {
        flags[i] = true;
    }
    for (200..205) |i| {
        flags[i] = true;
    }

    const result = try clusterSeparators(&flags, allocator);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 2), result.len);
    // Midpoint of 10..15 = 12 (integer division of (10+15)/2)
    try std.testing.expectEqual(@as(u32, 12), result[0]);
    // Midpoint of 200..205 = 202
    try std.testing.expectEqual(@as(u32, 202), result[1]);
}
