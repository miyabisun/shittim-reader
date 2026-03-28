//! Grid detection for the item inventory screen.
//!
//! Detects the grid region by scanning for #C4CFD4 background color,
//! then finds separator lines within it to compute cell coordinates.
//! Supports any aspect ratio (16:9, 4:3, etc.) and column count.

const std = @import("std");

/// Key constants from spec.
pub const separator_color = .{ .r = 0xC4, .g = 0xCF, .b = 0xD4 };
pub const color_tolerance: u8 = 15;
pub const template_size: u32 = 80;
pub const qty_region_start: f32 = 0.75; // 75% of cell height
pub const qty_trim_bottom: u32 = 6;
pub const qty_trim_right: u32 = 8;

/// Minimum consecutive #C4CFD4 pixels to count as a separator run.
const min_run_len: u32 = 2;

/// Percentage of row/column pixels that must match separator color
/// for the line to be classified as a separator (70%).
const separator_line_ratio: u32 = 7; // numerator for N/10 threshold

/// Minimum thickness (px) for a horizontal separator band to be kept.
const min_sep_band_thickness: u32 = 10;

/// Minimum cell width (px) in edge scan to filter noise gaps.
const min_cell_gap: u32 = 50;

/// Max supported columns/bands for stack buffers.
const max_cols_per_row: u32 = 10;
const max_bands: u32 = 20;
const max_runs_per_scan: u32 = 64;

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
    roi: ?RoiBounds = null,

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

pub const RoiBounds = struct { x0: u32, x1: u32, y0: u32, y1: u32 };

/// Find the grid region using scanline sampling.
///
/// 1. Horizontal scanline at y = height/2, right half only:
///    find runs of ≥2 consecutive #C4CFD4 pixels → x0 (first run start), x1 (last run end).
/// 2. Vertical scanline at x = x0 + 9 (left border center):
///    find the longest run of #C4CFD4 → y0 (run start), y1 (run end).
///    The left border is a solid vertical strip ~15px wide, so x0+9 sits
///    in the middle and gives a single continuous run for the full grid height.
pub fn findGridRegion(pixels: []const u8, width: u32, height: u32) ?RoiBounds {
    if (pixels.len < @as(usize, width) * height * 3) return null;

    // Step 1: horizontal scanline at vertical center, right half only
    const cy = height / 2;
    const half_x = width / 2;

    var h_first_start: ?u32 = null;
    var h_last_end: u32 = 0;
    {
        var run_start: ?u32 = null;
        for (half_x..width) |xi| {
            const x: u32 = @intCast(xi);
            const idx = (@as(usize, cy) * width + x) * 3;
            if (isSeparatorColor(pixels, idx)) {
                if (run_start == null) run_start = x;
            } else {
                if (run_start) |rs| {
                    if (x - rs >= min_run_len) {
                        if (h_first_start == null) h_first_start = rs;
                        h_last_end = x - 1;
                    }
                    run_start = null;
                }
            }
        }
        if (run_start) |rs| {
            if (width - rs >= min_run_len) {
                if (h_first_start == null) h_first_start = rs;
                h_last_end = width - 1;
            }
        }
    }

    const x0 = h_first_start orelse return null;
    const x1 = h_last_end;
    if (x1 <= x0) return null;

    // Step 2: vertical scanline at x0 + 9 (center of the left border strip).
    // Find all runs, then use the longest one as the grid extent.
    const cx = x0 + 9;

    var best_start: u32 = 0;
    var best_len: u32 = 0;
    {
        var run_start: ?u32 = null;
        for (0..height) |yi| {
            const y: u32 = @intCast(yi);
            const idx = (@as(usize, y) * width + cx) * 3;
            if (isSeparatorColor(pixels, idx)) {
                if (run_start == null) run_start = y;
            } else {
                if (run_start) |rs| {
                    const run_len = y - rs;
                    if (run_len >= min_run_len and run_len > best_len) {
                        best_start = rs;
                        best_len = run_len;
                    }
                    run_start = null;
                }
            }
        }
        if (run_start) |rs| {
            const run_len = height - rs;
            if (run_len >= min_run_len and run_len > best_len) {
                best_start = rs;
                best_len = run_len;
            }
        }
    }

    if (best_len == 0) return null;

    const y0 = best_start;
    const y1 = best_start + best_len - 1;

    return .{ .x0 = x0, .x1 = x1 + 1, .y0 = y0, .y1 = y1 + 1 };
}

const SepBand = struct {
    start: u32, // inclusive, ROI-relative
    end: u32, // inclusive, ROI-relative

    fn thickness(self: SepBand) u32 {
        return self.end - self.start + 1;
    }
};

/// Find contiguous bands of true values in is_sep.
fn findBands(is_sep: []const bool, buf: []SepBand) []SepBand {
    var count: usize = 0;
    var i: u32 = 0;
    while (i < is_sep.len) {
        if (is_sep[i]) {
            const start = i;
            while (i < is_sep.len and is_sep[i]) : (i += 1) {}
            if (count < buf.len) {
                buf[count] = .{ .start = start, .end = i - 1 };
                count += 1;
            }
        } else {
            i += 1;
        }
    }
    return buf[0..count];
}

pub const Run = struct { start: u32, end: u32 };

/// Scan a horizontal line at absolute y for #C4CFD4 runs.
pub fn scanHLine(pixels: []const u8, img_w: u32, y: u32, x0: u32, x1: u32, buf: []Run) []Run {
    var count: usize = 0;
    var run_start: ?u32 = null;

    for (x0..x1) |xi| {
        const x: u32 = @intCast(xi);
        const idx = (@as(usize, y) * img_w + x) * 3;
        if (isSeparatorColor(pixels, idx)) {
            if (run_start == null) run_start = x;
        } else {
            if (run_start) |rs| {
                if (x - rs >= min_run_len and count < buf.len) {
                    buf[count] = .{ .start = rs, .end = x - 1 };
                    count += 1;
                }
                run_start = null;
            }
        }
    }
    if (run_start) |rs| {
        if (x1 - rs >= min_run_len and count < buf.len) {
            buf[count] = .{ .start = rs, .end = x1 - 1 };
            count += 1;
        }
    }
    return buf[0..count];
}

pub const CellSpan = struct { left: u32, right: u32 };

/// Extract cell spans (gaps between separator runs) with width >= min_cell_gap.
pub fn cellSpansFromRuns(runs: []const Run, buf: []CellSpan) []CellSpan {
    var count: usize = 0;
    if (runs.len < 2) return buf[0..0];

    for (0..runs.len - 1) |i| {
        const left = runs[i].end + 1;
        const right = runs[i + 1].start -| 1;
        if (right > left and right - left >= min_cell_gap and count < buf.len) {
            buf[count] = .{ .left = left, .right = right };
            count += 1;
        }
    }
    return buf[0..count];
}

/// Detect grid cells in an RGB image of any resolution/aspect ratio.
///
/// Parallelogram-aware algorithm:
/// 1. Find grid ROI via scanline sampling (findGridRegion)
/// 2. Within ROI, detect horizontal separator bands (contiguous rows with ≥70% #C4CFD4)
/// 3. Cell rows = gaps between adjacent separator bands
/// 4. For each cell row, scan the top edge and bottom edge horizontally
///    to find per-row cell column boundaries (handles parallelogram skew)
/// 5. Cell bounding rect = top-left x to bottom-right x
pub fn detectGrid(
    allocator: std.mem.Allocator,
    pixels: []const u8,
    width: u32,
    height: u32,
) !GridResult {
    const empty = GridResult{
        .cells = try allocator.alloc(Cell, 0),
        .cols = 0,
        .rows = 0,
    };

    const roi = findGridRegion(pixels, width, height) orelse return empty;
    const roi_w = roi.x1 - roi.x0;
    const roi_h = roi.y1 - roi.y0;

    if (roi_w < min_cell_gap or roi_h < min_cell_gap) return empty;

    // ── Step 1: Horizontal separator band detection ──
    // For each row in ROI, check if ≥70% of pixels match #C4CFD4.
    const h_is_sep = try allocator.alloc(bool, roi_h);
    defer allocator.free(h_is_sep);

    for (0..roi_h) |dy| {
        const y = roi.y0 + @as(u32, @intCast(dy));
        var match_count: u32 = 0;
        for (0..roi_w) |dx| {
            const x = roi.x0 + @as(u32, @intCast(dx));
            const idx: usize = (@as(usize, y) * width + x) * 3;
            if (idx + 2 < pixels.len and isSeparatorColor(pixels, idx)) {
                match_count += 1;
            }
        }
        h_is_sep[dy] = match_count > roi_w * separator_line_ratio / 10;
    }

    // Find contiguous separator bands and filter by minimum thickness
    var all_bands_buf: [max_bands]SepBand = undefined;
    const all_bands = findBands(h_is_sep, &all_bands_buf);

    var h_bands_buf: [max_bands]SepBand = undefined;
    var n_bands: usize = 0;
    for (all_bands) |band| {
        if (band.thickness() >= min_sep_band_thickness and n_bands < h_bands_buf.len) {
            h_bands_buf[n_bands] = band;
            n_bands += 1;
        }
    }
    const h_bands = h_bands_buf[0..n_bands];

    if (h_bands.len < 2) return empty;

    const n_rows: u32 = @intCast(h_bands.len - 1);

    // ── Step 2: Per-row parallelogram cell detection ──
    // Scan each row's top/bottom edges. First row determines column count.
    var n_cols: u32 = 0;
    var cells: ?[]Cell = null;
    errdefer if (cells) |c| allocator.free(c);

    // Temporary per-row scan results (max_cols_per_row × 2 cell spans per row)
    var per_row_top: [max_bands][max_cols_per_row]CellSpan = undefined;
    var per_row_bot: [max_bands][max_cols_per_row]CellSpan = undefined;
    var per_row_top_len: [max_bands]u32 = undefined;
    var per_row_bot_len: [max_bands]u32 = undefined;

    for (0..n_rows) |r| {
        const top_y = roi.y0 + h_bands[r].end + 1;
        const bot_y = roi.y0 + h_bands[r + 1].start -| 1;

        var tr_buf: [max_runs_per_scan]Run = undefined;
        var br_buf: [max_runs_per_scan]Run = undefined;

        const top_runs = scanHLine(pixels, width, top_y, roi.x0, roi.x1, &tr_buf);
        const bot_runs = scanHLine(pixels, width, bot_y, roi.x0, roi.x1, &br_buf);
        const top_cells = cellSpansFromRuns(top_runs, &per_row_top[r]);
        const bot_cells = cellSpansFromRuns(bot_runs, &per_row_bot[r]);

        per_row_top_len[r] = @intCast(top_cells.len);
        per_row_bot_len[r] = @intCast(bot_cells.len);

        if (r == 0) {
            n_cols = @intCast(@min(top_cells.len, bot_cells.len));
            if (n_cols == 0) return empty;
            cells = try allocator.alloc(Cell, n_cols * n_rows);
        }
    }

    // ── Step 3: Build cell array from scan results ──
    const cell_slice = cells orelse return empty;

    for (0..n_rows) |r| {
        const top_y = roi.y0 + h_bands[r].end + 1;
        const bot_y = roi.y0 + h_bands[r + 1].start -| 1;
        const top_cells = per_row_top[r][0..per_row_top_len[r]];
        const bot_cells = per_row_bot[r][0..per_row_bot_len[r]];
        const row_cols: u32 = @intCast(@min(top_cells.len, bot_cells.len));

        for (0..n_cols) |c| {
            if (c < row_cols) {
                const x = top_cells[c].left;
                const x_end = bot_cells[c].right;
                cell_slice[r * n_cols + c] = .{
                    .x = x,
                    .y = top_y,
                    .w = if (x_end > x) x_end - x + 1 else 0,
                    .h = if (bot_y > top_y) bot_y - top_y + 1 else 0,
                };
            } else {
                cell_slice[r * n_cols + c] = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
            }
        }
    }

    return GridResult{
        .cells = cell_slice,
        .cols = n_cols,
        .rows = n_rows,
        .roi = roi,
    };
}

// ── Tests ──

/// Test helper: fill a rectangular region with separator color.
fn testFillRect(buf: []u8, bw: u32, x0: u32, y0: u32, x1: u32, y1: u32) void {
    for (y0..y1) |y| {
        for (x0..x1) |x| {
            const idx = (y * @as(usize, bw) + x) * 3;
            buf[idx] = 0xC4;
            buf[idx + 1] = 0xCF;
            buf[idx + 2] = 0xD4;
        }
    }
}

test "findGridRegion: scanline detects grid in right half" {
    const alloc = std.testing.allocator;
    const w: u32 = 1600;
    const h: u32 = 900;
    const pixels = try alloc.alloc(u8, w * h * 3);
    defer alloc.free(pixels);
    @memset(pixels, 128);

    const gx0: u32 = 845;
    const gx1: u32 = 1568;
    const gy0: u32 = 187;
    const gy1: u32 = 760;

    // Left border strip (20px wide, full grid height)
    testFillRect(pixels, w, gx0, gy0, gx0 + 20, gy1);
    // Right border strip (5px wide, full grid height)
    testFillRect(pixels, w, gx1 - 5, gy0, gx1, gy1);
    // Horizontal separator bands (15px tall each)
    for ([_]u32{ gy0, 330, 470, gy1 - 15 }) |y| {
        testFillRect(pixels, w, gx0, y, gx1, y + 15);
    }

    const region = findGridRegion(pixels, w, h);
    try std.testing.expect(region != null);
    const r = region.?;
    try std.testing.expect(r.x0 <= gx0 + 3);
    try std.testing.expect(r.x1 >= gx1 - 3);
    try std.testing.expect(r.y0 <= gy0 + 3);
    try std.testing.expect(r.y1 >= gy1 - 3);
}

test "findGridRegion: null when no #C4CFD4" {
    const alloc = std.testing.allocator;
    const w: u32 = 800;
    const h: u32 = 600;
    const pixels = try alloc.alloc(u8, w * h * 3);
    defer alloc.free(pixels);
    @memset(pixels, 255);

    try std.testing.expect(findGridRegion(pixels, w, h) == null);
}

test "no separators → 0 cells" {
    const alloc = std.testing.allocator;
    const w: u32 = 1600;
    const h: u32 = 900;
    const pixels = try alloc.alloc(u8, w * h * 3);
    defer alloc.free(pixels);
    @memset(pixels, 255);

    const result = try detectGrid(alloc, pixels, w, h);
    defer result.deinit(alloc);

    try std.testing.expectEqual(@as(u32, 0), result.cols);
    try std.testing.expectEqual(@as(u32, 0), result.rows);
    try std.testing.expectEqual(@as(usize, 0), result.cells.len);
}

test "findBands groups contiguous true values" {
    var is_sep = [_]bool{false} ** 100;
    // Band 1: positions 10-24 (15px)
    for (10..25) |i| is_sep[i] = true;
    // Band 2: positions 50-69 (20px)
    for (50..70) |i| is_sep[i] = true;
    // Noise: positions 80-82 (3px, below min_sep_band_thickness)
    for (80..83) |i| is_sep[i] = true;

    var buf: [max_bands]SepBand = undefined;
    const bands = findBands(&is_sep, &buf);

    try std.testing.expectEqual(@as(usize, 3), bands.len);
    try std.testing.expectEqual(@as(u32, 10), bands[0].start);
    try std.testing.expectEqual(@as(u32, 24), bands[0].end);
    try std.testing.expectEqual(@as(u32, 15), bands[0].thickness());
    try std.testing.expectEqual(@as(u32, 50), bands[1].start);
    try std.testing.expectEqual(@as(u32, 69), bands[1].end);
    try std.testing.expectEqual(@as(u32, 20), bands[1].thickness());
    // Third band is 3px — would be filtered by min_sep_band_thickness
    try std.testing.expectEqual(@as(u32, 3), bands[2].thickness());
}

test "detectGrid: parallelogram cells with skewed separators" {
    // Synthetic 400x400 image with 2 rows × 2 cols of parallelogram cells.
    // Separator bands are 15px tall. Vertical separators shift right as y
    // increases (simulating the italic skew of the game grid).
    //
    // Layout (x axis):
    //   [left border 20px] [cell col0 ~68px] [v-sep 5px] [cell col1 ~80px] [right border 5px]
    //
    // The v-sep x position differs between top and bottom edges of each row,
    // creating parallelogram-shaped cells.
    const alloc = std.testing.allocator;
    const w: u32 = 400;
    const h: u32 = 400;
    const pixels = try alloc.alloc(u8, w * h * 3);
    defer alloc.free(pixels);
    @memset(pixels, 128);

    const gx0: u32 = 200;
    const gx1: u32 = 390;

    // Left border strip (20px wide, full height y=50..305)
    testFillRect(pixels, w, gx0, 50, gx0 + 20, 305);
    // Right border strip (5px wide, full height y=50..305)
    testFillRect(pixels, w, gx1 - 5, 50, gx1, 305);

    // 3 horizontal separator bands (15px each)
    testFillRect(pixels, w, gx0, 50, gx1, 65); // band 0
    testFillRect(pixels, w, gx0, 170, gx1, 185); // band 1
    testFillRect(pixels, w, gx0, 290, gx1, 305); // band 2

    // Row 0 vertical separators (skewed):
    // Top edge (y=65, first row after band 0): v-sep at x=288..292
    testFillRect(pixels, w, 288, 65, 293, 66);
    // Bottom edge (y=169, last row before band 1): v-sep shifted right to x=298..302
    testFillRect(pixels, w, 298, 169, 303, 170);

    // Row 1 vertical separators (skewed):
    // Top edge (y=185): v-sep at x=290..294
    testFillRect(pixels, w, 290, 185, 295, 186);
    // Bottom edge (y=289): v-sep shifted right to x=300..304
    testFillRect(pixels, w, 300, 289, 305, 290);

    const result = try detectGrid(alloc, pixels, w, h);
    defer result.deinit(alloc);

    try std.testing.expectEqual(@as(u32, 2), result.cols);
    try std.testing.expectEqual(@as(u32, 2), result.rows);

    const c00 = result.cells[0]; // Row 0, Col 0
    const c01 = result.cells[1]; // Row 0, Col 1
    const c10 = result.cells[2]; // Row 1, Col 0
    const c11 = result.cells[3]; // Row 1, Col 1

    // ── Structural invariants ──
    // All cells must have non-zero dimensions
    for (result.cells) |cell| {
        try std.testing.expect(cell.w > 0);
        try std.testing.expect(cell.h > 0);
    }

    // Col 0 x must be after left border end (x=220)
    try std.testing.expectEqual(@as(u32, 220), c00.x);
    try std.testing.expectEqual(@as(u32, 220), c10.x);

    // Col 1 x comes from top-edge v-sep end+1:
    //   Row 0 top v-sep painted at x=[288..292] → cell starts at 293
    //   Row 1 top v-sep painted at x=[290..294] → cell starts at 295
    try std.testing.expectEqual(@as(u32, 293), c01.x);
    try std.testing.expectEqual(@as(u32, 295), c11.x);

    // Heights: row 0 = y65..y169 = 105px, row 1 = y185..y289 = 105px
    try std.testing.expectEqual(@as(u32, 105), c00.h);
    try std.testing.expectEqual(@as(u32, 105), c10.h);

    // Parallelogram property: col 0 width uses top-left x (220) to
    // bottom-right x (297 from bot v-sep start-1), so w = 297-220+1 = 78
    try std.testing.expectEqual(@as(u32, 78), c00.w);

    // Col 1 right edge from bottom-edge right border start-1:
    //   Row 0 bot: right border=[385..389], cell right = 384
    //   w = 384 - 293 + 1 = 92
    try std.testing.expectEqual(@as(u32, 92), c01.w);
}
