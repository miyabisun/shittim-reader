//! Dev tool: split a cropped grid image into individual cell PNGs.
//!
//! Usage: zig build split-cells -- <input.png> [output_dir]
//!
//! Reads a cropped grid image, detects parallelogram cell boundaries
//! using #C4CFD4 separator color, and saves each cell as r{row}c{col}.png.

const std = @import("std");
const zigimg = @import("zigimg");
const grid = @import("shittim_reader").grid;

/// Minimum run length to count as a vertical separator (internal v-sep).
const min_vsep_run: u32 = 3;
/// Maximum run length for internal v-seps (longer runs are borders, not seps).
const max_vsep_run: u32 = 20;
/// Minimum thickness for a horizontal separator band.
const min_hsep_band: u32 = 30;

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: split-cells <input.png> [output_dir]\n", .{});
        std.process.exit(1);
    }

    const input_path = args[1];
    const output_dir = if (args.len >= 3) args[2] else "test_fixtures/cells";

    std.fs.cwd().makePath(output_dir) catch {};

    // Load input image and convert to RGB24
    var read_buf: [8192]u8 = undefined;
    var img = try zigimg.Image.fromFilePath(allocator, input_path, &read_buf);
    defer img.deinit(allocator);

    if (img.pixelFormat() != .rgb24) {
        try img.convert(allocator, .rgb24);
    }

    const w: u32 = @intCast(img.width);
    const h: u32 = @intCast(img.height);
    std.debug.print("input: {d}x{d}\n", .{ w, h });

    const rgb = img.rawBytes();

    // ── Step 0: Find internal vertical separators via horizontal scan at y=h/2 ──
    const mid_y = h / 2;
    var v_sep_runs: [64]grid.Run = undefined;
    var n_v_seps: usize = 0;
    {
        var run_start: ?u32 = null;
        for (0..w) |xi| {
            const x: u32 = @intCast(xi);
            const idx = (@as(usize, mid_y) * w + x) * 3;
            if (grid.isSeparatorRgb(rgb[idx], rgb[idx + 1], rgb[idx + 2])) {
                if (run_start == null) run_start = x;
            } else {
                if (run_start) |rs| {
                    const len = x - rs;
                    if (len >= min_vsep_run and len <= max_vsep_run and n_v_seps < v_sep_runs.len) {
                        v_sep_runs[n_v_seps] = .{ .start = rs, .end = x - 1 };
                        n_v_seps += 1;
                    }
                    run_start = null;
                }
            }
        }
    }

    if (n_v_seps < 2) {
        std.debug.print("error: need at least 2 internal v-seps, found {d}\n", .{n_v_seps});
        std.process.exit(1);
    }

    const scan_x = (v_sep_runs[1].start + v_sep_runs[1].end) / 2;
    std.debug.print("scan x={d}\n", .{scan_x});

    // ── Step 1: Vertical scan at scan_x to find row boundaries ──
    const SepBand = struct { start: u32, end: u32 };
    var bands_buf: [20]SepBand = undefined;
    var n_bands: usize = 0;
    {
        var run_start: ?u32 = null;
        for (0..h) |yi| {
            const y: u32 = @intCast(yi);
            const idx = (@as(usize, y) * w + scan_x) * 3;
            const is_sep = grid.isSeparatorRgb(rgb[idx], rgb[idx + 1], rgb[idx + 2]);
            if (is_sep) {
                if (run_start == null) run_start = y;
            } else {
                if (run_start) |rs| {
                    if (y - rs >= min_hsep_band and n_bands < bands_buf.len) {
                        bands_buf[n_bands] = .{ .start = rs, .end = y - 1 };
                        n_bands += 1;
                    }
                    run_start = null;
                }
            }
        }
        if (run_start) |rs| {
            if (h - rs >= min_hsep_band and n_bands < bands_buf.len) {
                bands_buf[n_bands] = .{ .start = rs, .end = h - 1 };
                n_bands += 1;
            }
        }
    }
    const bands = bands_buf[0..n_bands];

    std.debug.print("sep bands ({d}):\n", .{n_bands});
    for (bands, 0..) |b, i| {
        std.debug.print("  [{d}] y={d}..{d} ({d}px)\n", .{ i, b.start, b.end, b.end - b.start + 1 });
    }

    if (n_bands < 2) {
        std.debug.print("error: need at least 2 separator bands\n", .{});
        std.process.exit(1);
    }

    const n_rows = n_bands - 1;
    std.debug.print("\nrows ({d}):\n", .{n_rows});
    for (0..n_rows) |i| {
        const top = bands[i].end + 1;
        const bottom = bands[i + 1].start -| 1;
        std.debug.print("  row {d}: y={d}..{d} (h={d})\n", .{ i, top, bottom, bottom - top + 1 });
    }

    // ── Steps 2-4: Scan top/bottom edges per row, extract cells ──
    var cell_count: u32 = 0;

    for (0..n_rows) |ri| {
        const top_y = bands[ri].end + 1;
        const bot_y = bands[ri + 1].start -| 1;

        var top_runs_buf: [64]grid.Run = undefined;
        const top_runs = grid.scanHLine(rgb, w, top_y, 0, w, &top_runs_buf);

        var bot_runs_buf: [64]grid.Run = undefined;
        const bot_runs = grid.scanHLine(rgb, w, bot_y, 0, w, &bot_runs_buf);

        var top_cells_buf: [10]grid.CellSpan = undefined;
        const top_cells = grid.cellSpansFromRuns(top_runs, &top_cells_buf);

        var bot_cells_buf: [10]grid.CellSpan = undefined;
        const bot_cells = grid.cellSpansFromRuns(bot_runs, &bot_cells_buf);

        const n_cols = @min(top_cells.len, bot_cells.len);

        for (0..n_cols) |ci| {
            const x0 = top_cells[ci].left;
            const x1 = bot_cells[ci].right;
            const cw = x1 - x0 + 1;
            const ch = bot_y - top_y + 1;

            if (cw == 0 or ch == 0) continue;

            if (ri == 0 and ci == 0) {
                std.debug.print("\ncell[0,0]: x=[{d}..{d}] y=[{d}..{d}] ({d}x{d})\n", .{
                    x0, x1, top_y, bot_y, cw, ch,
                });
            }

            try saveCellPng(allocator, rgb, w, x0, top_y, cw, ch, output_dir, @intCast(ri), @intCast(ci));
            cell_count += 1;
        }
    }

    std.debug.print("\nsaved {d} cells to {s}/\n", .{ cell_count, output_dir });
}

fn saveCellPng(
    allocator: std.mem.Allocator,
    rgb: []const u8,
    src_w: u32,
    x0: u32,
    y0: u32,
    cw: u32,
    ch: u32,
    output_dir: []const u8,
    row: u32,
    col: u32,
) !void {
    const row_bytes = @as(usize, cw) * 3;
    const cell_rgb = try allocator.alloc(u8, row_bytes * ch);
    defer allocator.free(cell_rgb);

    for (0..ch) |dy| {
        const src_off = ((@as(usize, y0) + dy) * src_w + x0) * 3;
        const dst_off = dy * row_bytes;
        @memcpy(cell_rgb[dst_off..][0..row_bytes], rgb[src_off..][0..row_bytes]);
    }

    // Create image from raw pixels
    var out_img = try zigimg.Image.fromRawPixels(allocator, cw, ch, cell_rgb, .rgb24);
    defer out_img.deinit(allocator);

    // Build output path
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/r{d}c{d}.png", .{ output_dir, row, col }) catch return;

    // Save as PNG
    var write_buf: [65536]u8 = undefined;
    out_img.writeToFilePath(allocator, path, &write_buf, .{ .png = .{} }) catch |err| {
        std.debug.print("warning: failed to save {s}: {s}\n", .{ path, @errorName(err) });
    };
}
