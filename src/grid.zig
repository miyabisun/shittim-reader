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
/// At 1600px normalized width, 4:3 aspect produces ~6px bands, 16:9 ~15px.
const min_sep_band_thickness: u32 = 5;

/// Minimum cell width (px) in edge scan to filter noise gaps.
const min_cell_gap: u32 = 50;

/// Pixels to trim from top and bottom of each row gap before cell extraction.
const cell_trim_px: u32 = 2;

/// Max supported columns/bands for stack buffers.
const max_cols_per_row: u32 = 10;
const max_bands: u32 = 20;

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

/// Return the number of usable rows, excluding a truncated last row
/// (height < 90% of the first row).
pub fn activeRows(result: GridResult) u32 {
    if (result.rows < 2) return result.rows;
    const first_h = result.cells[0].h;
    const last_h = result.cells[(result.rows - 1) * result.cols].h;
    return if (last_h < first_h * 9 / 10) result.rows - 1 else result.rows;
}

pub const FooterRegion = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
};

/// Compute the footer (quantity label) region within a cell.
/// Returns null if the region is degenerate (zero width/height).
pub fn footerRegion(cell: Cell) ?FooterRegion {
    const footer_y = cell.y + @as(u32, @intFromFloat(
        @as(f32, @floatFromInt(cell.h)) * qty_region_start,
    ));
    const footer_h = cell.y + cell.h -| qty_trim_bottom -| footer_y;
    const footer_w = cell.w -| qty_trim_right;
    if (footer_w == 0 or footer_h == 0) return null;
    return .{ .x = cell.x, .y = footer_y, .w = footer_w, .h = footer_h };
}

/// Copy a rectangular region from an image into a contiguous buffer.
/// Returns the filled slice, or null if the region exceeds buf capacity.
pub fn extractRegion(
    pixels: []const u8,
    img_w: u32,
    region: FooterRegion,
    buf: []u8,
) ?[]u8 {
    const row_bytes = @as(usize, region.w) * 3;
    const total = row_bytes * region.h;
    if (total > buf.len) return null;

    for (0..region.h) |dy| {
        const src_y = region.y + @as(u32, @intCast(dy));
        const src_off = (@as(usize, src_y) * img_w + region.x) * 3;
        const dst_off = dy * row_bytes;
        @memcpy(buf[dst_off..][0..row_bytes], pixels[src_off..][0..row_bytes]);
    }
    return buf[0..total];
}

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

    // Step 2: vertical scanlines at x0+9 and ±15px offsets.
    // Scan 3 lines to avoid single-line artifacts (gray icons, UI overlays).
    // Keep the longest run across all 3 scans.
    var best_start: u32 = 0;
    var best_len: u32 = 0;

    for ([_]u32{ x0 + 9, x0 +| 9 +| 15, x0 + 9 -| 15 }) |cx| {
        if (cx >= width) continue;
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

pub const CellSpan = struct { left: u32, right: u32 };

/// Scan a horizontal line for contiguous non-separator regions (cell content).
/// Returns spans of non-#C4CFD4 pixels with width >= min_cell_gap.
pub fn scanCellSpans(pixels: []const u8, img_w: u32, y: u32, x0: u32, x1: u32, buf: []CellSpan) []CellSpan {
    var count: usize = 0;
    var run_start: ?u32 = null;

    for (x0..x1) |xi| {
        const x: u32 = @intCast(xi);
        const idx = (@as(usize, y) * img_w + x) * 3;
        if (!isSeparatorColor(pixels, idx)) {
            if (run_start == null) run_start = x;
        } else {
            if (run_start) |rs| {
                if (x - rs >= min_cell_gap and count < buf.len) {
                    buf[count] = .{ .left = rs, .right = x - 1 };
                    count += 1;
                }
                run_start = null;
            }
        }
    }
    if (run_start) |rs| {
        if (x1 - rs >= min_cell_gap and count < buf.len) {
            buf[count] = .{ .left = rs, .right = x1 - 1 };
            count += 1;
        }
    }
    return buf[0..count];
}

/// Detect grid cells in an RGB image of any resolution/aspect ratio.
///
/// Square-cell algorithm:
/// 1. Find grid ROI via scanline sampling (findGridRegion)
/// 2. Within ROI, detect horizontal separator bands (contiguous rows with ≥70% #C4CFD4)
/// 3. Filter short row gaps (headers) and determine row boundaries
/// 4. Row 0: trim 2px top/bottom, ensure even height, scan center line
///    for column positions → square cells (side = trimmed height)
/// 5. Rows 1+: reuse row 0's cell size and column x-positions,
///    center vertically within each row gap
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

    // ── Step 2: Filter short row gaps (e.g. header region) ──
    // 4:3 screens have a thin header row ("リスト デフォルト ...") between the
    // top border band and the first real separator. When consecutive bands are
    // closer than min_cell_gap, replace the previous band with the current one
    // so the short gap is absorbed into the preceding separator region.
    var valid_bands_buf: [max_bands]SepBand = undefined;
    valid_bands_buf[0] = h_bands[0];
    var n_valid: usize = 1;
    for (1..h_bands.len) |i| {
        const gap = h_bands[i].start -| h_bands[n_valid - 1].end;
        if (gap >= min_cell_gap) {
            valid_bands_buf[n_valid] = h_bands[i];
            n_valid += 1;
        } else {
            valid_bands_buf[n_valid - 1] = h_bands[i];
        }
    }
    const valid_bands = valid_bands_buf[0..n_valid];

    if (valid_bands.len < 2) return empty;

    const n_rows: u32 = @intCast(valid_bands.len - 1);

    // ── Step 3: Row 0 — determine cell size and column positions ──
    // Trim 2px top/bottom. If remaining height is odd, trim 1 more from top.
    const r0_raw_top = roi.y0 + valid_bands[0].end + 1;
    const r0_raw_bot = roi.y0 + valid_bands[1].start -| 1;
    var r0_top = r0_raw_top + cell_trim_px;
    const r0_bot = r0_raw_bot -| cell_trim_px;
    var cell_side = r0_bot - r0_top + 1;
    if (cell_side % 2 != 0) {
        r0_top += 1;
        cell_side -= 1;
    }
    if (cell_side < min_cell_gap) return empty;

    // Scan 2 horizontal lines at 5% from top and bottom of row 0.
    // These positions hit cell background (not icon area), avoiding
    // gray icons that coincidentally match separator color.
    // Use the 4 x-coordinates (top-left, top-right, bot-left, bot-right)
    // to compute each column's center.
    const inset = cell_side * 5 / 100;
    const scan_top_y = r0_top + inset;
    const scan_bot_y = r0_top + cell_side - 1 - inset;

    var top_spans_buf: [max_cols_per_row]CellSpan = undefined;
    var bot_spans_buf: [max_cols_per_row]CellSpan = undefined;
    const top_spans = scanCellSpans(pixels, width, scan_top_y, roi.x0, roi.x1, &top_spans_buf);
    const bot_spans = scanCellSpans(pixels, width, scan_bot_y, roi.x0, roi.x1, &bot_spans_buf);

    const n_cols: u32 = @intCast(@min(top_spans.len, bot_spans.len));
    if (n_cols == 0) return empty;

    // Compute column x-positions: center of 4 corner points, extend side/2 left
    var col_x: [max_cols_per_row]u32 = undefined;
    const half = cell_side / 2;
    for (0..n_cols) |c| {
        const sum = @as(u32, top_spans[c].left) + top_spans[c].right +
            bot_spans[c].left + bot_spans[c].right;
        const center_x = sum / 4;
        col_x[c] = center_x -| half;
    }

    // ── Step 4: Build cell array ──
    const cells = try allocator.alloc(Cell, n_cols * n_rows);
    errdefer allocator.free(cells);

    for (0..n_rows) |r| {
        const cell_y = if (r == 0) r0_top else blk: {
            const raw_top = roi.y0 + valid_bands[r].end + 1;
            const raw_bot = roi.y0 + valid_bands[r + 1].start -| 1;
            const raw_h = raw_bot - raw_top + 1;
            if (raw_h <= cell_side) {
                break :blk raw_top;
            }
            const excess = raw_h - cell_side;
            // Extra pixel trimmed from top when excess is odd
            break :blk raw_top + (excess + 1) / 2;
        };

        for (0..n_cols) |c| {
            cells[r * n_cols + c] = .{
                .x = col_x[c],
                .y = cell_y,
                .w = cell_side,
                .h = cell_side,
            };
        }
    }

    return GridResult{
        .cells = cells,
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

test "detectGrid: square cells from center-line scan" {
    // Synthetic 400x400 image with 2 rows × 2 cols.
    // Separator bands are 15px tall. Vertical separators span full cell height
    // with a slight skew (simulating the italic skew of the game grid).
    //
    // Row gap: y=65..169 (105px). Trim 2+2=4 → 101px, odd → trim 1 more → 100px.
    // cell_side = 100, mid_y = 68 + 50 = 118.
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

    // Vertical separators (skewed, full cell height) for both rows.
    for (65..170) |yi| {
        const t = @as(f32, @floatFromInt(yi - 65)) / 105.0;
        const cx: u32 = 288 + @as(u32, @intFromFloat(@round(t * 10.0)));
        testFillRect(pixels, w, cx, @intCast(yi), cx + 5, @intCast(yi + 1));
    }
    for (185..290) |yi| {
        const t = @as(f32, @floatFromInt(yi - 185)) / 105.0;
        const cx: u32 = 290 + @as(u32, @intFromFloat(@round(t * 10.0)));
        testFillRect(pixels, w, cx, @intCast(yi), cx + 5, @intCast(yi + 1));
    }

    const result = try detectGrid(alloc, pixels, w, h);
    defer result.deinit(alloc);

    try std.testing.expectEqual(@as(u32, 2), result.cols);
    try std.testing.expectEqual(@as(u32, 2), result.rows);

    // All cells are square with side = 100 (105 - 4 trim - 1 odd adjust)
    for (result.cells) |cell| {
        try std.testing.expectEqual(@as(u32, 100), cell.w);
        try std.testing.expectEqual(@as(u32, 100), cell.h);
    }

    // Row 0 and row 1 have same x-coordinates (column positions fixed by row 0)
    try std.testing.expectEqual(result.cells[0].x, result.cells[2].x);
    try std.testing.expectEqual(result.cells[1].x, result.cells[3].x);
}

// ── activeRows tests ──

test "activeRows: 0 rows → 0" {
    const alloc = std.testing.allocator;
    const cells = try alloc.alloc(Cell, 0);
    defer alloc.free(cells);
    const r = GridResult{ .cells = cells, .cols = 0, .rows = 0, .roi = null };
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 0), activeRows(r));
}

test "activeRows: 1 row → 1 (no comparison possible)" {
    const alloc = std.testing.allocator;
    const cells = try alloc.alloc(Cell, 1);
    defer alloc.free(cells);
    cells[0] = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    const r = GridResult{ .cells = cells, .cols = 1, .rows = 1, .roi = null };
    try std.testing.expectEqual(@as(u32, 1), activeRows(r));
}

test "activeRows: all rows equal height → all kept" {
    const alloc = std.testing.allocator;
    const cells = try alloc.alloc(Cell, 6);
    defer alloc.free(cells);
    for (cells) |*c| c.* = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    const r = GridResult{ .cells = cells, .cols = 3, .rows = 2, .roi = null };
    try std.testing.expectEqual(@as(u32, 2), activeRows(r));
}

test "activeRows: last row truncated → excluded" {
    const alloc = std.testing.allocator;
    const cells = try alloc.alloc(Cell, 6);
    defer alloc.free(cells);
    // Row 0: h=100
    for (cells[0..3]) |*c| c.* = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    // Row 1: h=50 (50% of first row, well below 90%)
    for (cells[3..6]) |*c| c.* = .{ .x = 0, .y = 100, .w = 100, .h = 50 };
    const r = GridResult{ .cells = cells, .cols = 3, .rows = 2, .roi = null };
    try std.testing.expectEqual(@as(u32, 1), activeRows(r));
}

test "activeRows: boundary — 89/100 excluded, 90/100 kept" {
    const alloc = std.testing.allocator;
    // first_h=100 → threshold = 100*9/10 = 90 (integer division)
    // last_h=89 < 90 → excluded
    const cells89 = try alloc.alloc(Cell, 2);
    defer alloc.free(cells89);
    cells89[0] = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    cells89[1] = .{ .x = 0, .y = 100, .w = 100, .h = 89 };
    const r89 = GridResult{ .cells = cells89, .cols = 1, .rows = 2, .roi = null };
    try std.testing.expectEqual(@as(u32, 1), activeRows(r89));

    // last_h=90 >= 90 → kept
    const cells90 = try alloc.alloc(Cell, 2);
    defer alloc.free(cells90);
    cells90[0] = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    cells90[1] = .{ .x = 0, .y = 100, .w = 100, .h = 90 };
    const r90 = GridResult{ .cells = cells90, .cols = 1, .rows = 2, .roi = null };
    try std.testing.expectEqual(@as(u32, 2), activeRows(r90));
}

test "activeRows: odd first_h boundary — 99*9/10=89" {
    const alloc = std.testing.allocator;
    // first_h=99 → threshold = 99*9/10 = 89 (integer truncation: 891/10=89)
    const cells = try alloc.alloc(Cell, 2);
    defer alloc.free(cells);
    cells[0] = .{ .x = 0, .y = 0, .w = 100, .h = 99 };
    cells[1] = .{ .x = 0, .y = 100, .w = 100, .h = 89 };
    const r = GridResult{ .cells = cells, .cols = 1, .rows = 2, .roi = null };
    try std.testing.expectEqual(@as(u32, 2), activeRows(r));

    // last_h=88 < 89 → excluded
    cells[1].h = 88;
    try std.testing.expectEqual(@as(u32, 1), activeRows(r));
}

// ── footerRegion tests ──

test "footerRegion: typical 116x116 cell" {
    const cell = Cell{ .x = 900, .y = 200, .w = 116, .h = 116 };
    const footer = footerRegion(cell).?;
    // qty_region_start=0.75 → footer_y = 200 + floor(116*0.75) = 200+87 = 287
    try std.testing.expectEqual(@as(u32, 287), footer.y);
    // footer_h = (200+116) - 6 - 287 = 316 - 6 - 287 = 23
    try std.testing.expectEqual(@as(u32, 23), footer.h);
    // footer_w = 116 - 8 = 108
    try std.testing.expectEqual(@as(u32, 108), footer.w);
    // x unchanged
    try std.testing.expectEqual(@as(u32, 900), footer.x);
}

test "footerRegion: cell too small for footer → null" {
    // h=8: footer_y = 0 + floor(8*0.75) = 6, footer_h = (0+8) - 6 - 6 = -4 → saturate to 0
    const cell = Cell{ .x = 0, .y = 0, .w = 20, .h = 8 };
    try std.testing.expect(footerRegion(cell) == null);
}

test "footerRegion: w <= qty_trim_right → null" {
    // w=8: footer_w = 8 -| 8 = 0 → null
    const cell = Cell{ .x = 0, .y = 0, .w = 8, .h = 116 };
    try std.testing.expect(footerRegion(cell) == null);
}

// ── extractRegion tests ──

test "extractRegion: copies correct pixels" {
    // 4x4 RGB image with each pixel = (row, col, 0)
    const img_w: u32 = 4;
    var pixels: [4 * 4 * 3]u8 = undefined;
    for (0..4) |y| {
        for (0..4) |x| {
            const i = (y * 4 + x) * 3;
            pixels[i] = @intCast(y);
            pixels[i + 1] = @intCast(x);
            pixels[i + 2] = 0;
        }
    }

    // Extract 2x2 region at (1,1)
    const region = FooterRegion{ .x = 1, .y = 1, .w = 2, .h = 2 };
    var buf: [2 * 2 * 3]u8 = undefined;
    const result = extractRegion(&pixels, img_w, region, &buf).?;

    try std.testing.expectEqual(@as(usize, 12), result.len);
    // Row 0 of region = image row 1, cols 1..2
    try std.testing.expectEqual(@as(u8, 1), result[0]); // y=1
    try std.testing.expectEqual(@as(u8, 1), result[1]); // x=1
    try std.testing.expectEqual(@as(u8, 1), result[3]); // y=1
    try std.testing.expectEqual(@as(u8, 2), result[4]); // x=2
    // Row 1 of region = image row 2, cols 1..2
    try std.testing.expectEqual(@as(u8, 2), result[6]); // y=2
    try std.testing.expectEqual(@as(u8, 1), result[7]); // x=1
}

test "extractRegion: buffer too small → null" {
    var pixels: [100 * 3]u8 = undefined;
    const region = FooterRegion{ .x = 0, .y = 0, .w = 10, .h = 10 };
    var small_buf: [10]u8 = undefined;
    try std.testing.expect(extractRegion(&pixels, 10, region, &small_buf) == null);
}

// ── scanCellSpans tests ──

test "scanCellSpans: all separator → 0 spans" {
    const w: u32 = 100;
    var pixels: [100 * 3]u8 = undefined;
    // Fill with separator color (#C4CFD4)
    for (0..100) |i| {
        pixels[i * 3] = 196;
        pixels[i * 3 + 1] = 207;
        pixels[i * 3 + 2] = 212;
    }
    var buf: [10]CellSpan = undefined;
    const spans = scanCellSpans(&pixels, w, 0, 0, 100, &buf);
    try std.testing.expectEqual(@as(usize, 0), spans.len);
}

test "scanCellSpans: all non-separator → 1 span" {
    const w: u32 = 100;
    var pixels: [100 * 3]u8 = undefined;
    @memset(&pixels, 0); // black = not separator
    var buf: [10]CellSpan = undefined;
    const spans = scanCellSpans(&pixels, w, 0, 0, 100, &buf);
    try std.testing.expectEqual(@as(usize, 1), spans.len);
    try std.testing.expectEqual(@as(u32, 0), spans[0].left);
    try std.testing.expectEqual(@as(u32, 99), spans[0].right);
}

test "scanCellSpans: narrow gap below min_cell_gap → filtered" {
    const w: u32 = 100;
    var pixels: [100 * 3]u8 = undefined;
    // Fill separator
    for (0..100) |i| {
        pixels[i * 3] = 196;
        pixels[i * 3 + 1] = 207;
        pixels[i * 3 + 2] = 212;
    }
    // Small non-separator gap at x=40..49 (10px < min_cell_gap=50)
    for (40..50) |i| {
        pixels[i * 3] = 0;
        pixels[i * 3 + 1] = 0;
        pixels[i * 3 + 2] = 0;
    }
    var buf: [10]CellSpan = undefined;
    const spans = scanCellSpans(&pixels, w, 0, 0, 100, &buf);
    try std.testing.expectEqual(@as(usize, 0), spans.len);
}
