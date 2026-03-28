//! shittim CLI: Developer tool for shittim-reader.
//!
//! Subcommands:
//!   scan  - Capture game window and output item quantities as CSV
//!
//! Usage:
//!   zig build run -- scan                         # auto-detect game window
//!   zig build run -- scan --title "BlueArchive"   # specify window title
//!   zig build run -- scan --list-windows          # list visible windows

const std = @import("std");
const shittim = @import("shittim_reader");
const capture = @import("capture.zig");

const grid = shittim.grid;
const image = shittim.image;
const ocr = shittim.ocr;
const screen_mod = shittim.screen;

/// Maximum footer region size for stack buffer (pixels × 3 channels).
/// Typical footer: ~108×24 = 2,592 pixels × 3 = 7,776 bytes.
const max_footer_buf = 200 * 50 * 3;

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        std.process.exit(1);
    }

    if (std.mem.eql(u8, args[1], "scan")) {
        scan(allocator, args[2..]) catch |err| {
            std.debug.print("error: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
    } else {
        printUsage();
        std.process.exit(1);
    }
}

fn printUsage() void {
    std.debug.print(
        \\Usage: shittim <command> [options]
        \\
        \\Commands:
        \\  scan              Capture game window and output item quantities as CSV
        \\
        \\Scan options:
        \\  --title <string>  Window title to find (default: auto-detect "BlueArchive")
        \\  --list-windows    List all visible windows and exit
        \\
    , .{});
}

fn scan(allocator: std.mem.Allocator, args: []const []const u8) !void {
    // Parse arguments
    var window_title: ?[]const u8 = null;
    var dump_path: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--list-windows")) {
            // For list-windows, write to stdout via debug print (stderr-based)
            // since this is a diagnostic command
            var stdout_buf: [4096]u8 = undefined;
            var stdout_w = std.fs.File.stdout().writerStreaming(&stdout_buf);
            try capture.listWindows(&stdout_w.interface);
            try stdout_w.interface.flush();
            return;
        } else if (std.mem.eql(u8, args[i], "--title")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --title requires a value\n", .{});
                std.process.exit(1);
            }
            window_title = args[i];
        } else if (std.mem.eql(u8, args[i], "--dump")) {
            i += 1;
            dump_path = if (i < args.len) args[i] else "capture.ppm";
        }
    }

    // ── Step 1: Find and capture game window ──
    const hwnd = if (window_title) |title|
        capture.findWindowByTitle(title) catch {
            std.debug.print("error: window not found: \"{s}\"\n", .{title});
            return error.WindowNotFound;
        }
    else
        capture.findWindowBySubstring("BlueArchive") catch
            capture.findWindowBySubstring("\xE3\x83\x96\xE3\x83\xAB\xE3\x83\xBC\xE3\x82\xA2\xE3\x83\xBC\xE3\x82\xAB\xE3\x82\xA4\xE3\x83\x96") catch {
                // "ブルーアーカイブ" in UTF-8
                std.debug.print("error: game window not found\n", .{});
                std.debug.print("hint: use --list-windows to see available windows\n", .{});
                std.debug.print("hint: use --title to specify the exact window title\n", .{});
                return error.WindowNotFound;
            };

    const cap = try capture.captureWindow(allocator, hwnd);
    defer cap.deinit(allocator);

    std.debug.print("captured: {d}x{d}\n", .{ cap.width, cap.height });

    // Dump captured image for debugging
    if (dump_path) |path| {
        savePpm(path, cap.pixels, cap.width, cap.height) catch |err| {
            std.debug.print("warning: failed to save dump: {s}\n", .{@errorName(err)});
        };
        std.debug.print("saved: {s}\n", .{path});
    }

    // ── Step 2: Detect aspect ratio ──
    const aspect: f32 = @as(f32, @floatFromInt(cap.width)) / @as(f32, @floatFromInt(cap.height));
    if (aspect > 1.6 and aspect < 1.9) {
        std.debug.print("aspect: 16:9 ({d:.2})\n", .{aspect});
    } else if (aspect > 1.2 and aspect < 1.5) {
        std.debug.print("aspect: 4:3 ({d:.2})\n", .{aspect});
    } else {
        std.debug.print("aspect: unknown ({d:.2})\n", .{aspect});
    }

    // ── Step 3: Normalize to 1600px width, preserving aspect ratio ──
    const target_w: u32 = image.canonical_width;
    const target_h: u32 = @intFromFloat(
        @round(@as(f32, @floatFromInt(cap.height)) * @as(f32, @floatFromInt(target_w)) / @as(f32, @floatFromInt(cap.width))),
    );
    const norm_pixels = try shittim.area_average.areaAverage(
        allocator, cap.pixels, cap.width, cap.height, target_w, target_h, 3,
    );
    defer allocator.free(norm_pixels);

    std.debug.print("normalized: {d}x{d}\n", .{ target_w, target_h });

    // ── Step 4: Detect grid (also provides ROI for classify and debug dump) ──
    const grid_result = try grid.detectGrid(allocator, norm_pixels, target_w, target_h);
    defer grid_result.deinit(allocator);

    // ── Step 4b: Classify screen using ROI from detectGrid ──
    const screen_type = screen_mod.classify(norm_pixels, target_w, target_h, grid_result.roi);
    std.debug.print("screen: {s}\n", .{@tagName(screen_type)});

    if (screen_type != .item_inventory) {
        std.debug.print("warning: not an item inventory screen, continuing anyway\n", .{});
    }

    // ── Step 4c: Save ROI crop for debugging ──
    if (dump_path != null) {
        if (grid_result.roi) |roi| {
            const roi_w = roi.x1 - roi.x0;
            const roi_h = roi.y1 - roi.y0;
            const roi_pixels = try allocator.alloc(u8, @as(usize, roi_w) * roi_h * 3);
            defer allocator.free(roi_pixels);
            for (0..roi_h) |dy| {
                const src_y = roi.y0 + @as(u32, @intCast(dy));
                const src_off = (@as(usize, src_y) * target_w + roi.x0) * 3;
                const dst_off = dy * @as(usize, roi_w) * 3;
                @memcpy(roi_pixels[dst_off .. dst_off + @as(usize, roi_w) * 3], norm_pixels[src_off .. src_off + @as(usize, roi_w) * 3]);
            }
            savePpm("test_fixtures/roi_crop.ppm", roi_pixels, roi_w, roi_h) catch |err| {
                std.debug.print("warning: failed to save ROI crop: {s}\n", .{@errorName(err)});
            };
            std.debug.print("saved ROI crop: {d}x{d} to test_fixtures/roi_crop.ppm\n", .{ roi_w, roi_h });
        }
    }

    std.debug.print("grid: {d} cols x {d} rows ({d} cells)\n", .{
        grid_result.cols, grid_result.rows, grid_result.cells.len,
    });

    if (grid_result.cells.len == 0) {
        std.debug.print("error: no grid cells detected\n", .{});
        return;
    }

    // ── Step 6: Filter partial cells (last row if too short) ──
    var active_rows = grid_result.rows;
    if (grid_result.rows >= 2) {
        const first_cell = grid_result.cells[0];
        const last_row_cell = grid_result.cells[(grid_result.rows - 1) * grid_result.cols];
        if (last_row_cell.h < first_cell.h * 9 / 10) {
            active_rows -= 1;
            std.debug.print("filtered: last row (height {d} vs {d}), using {d} rows\n", .{
                last_row_cell.h, first_cell.h, active_rows,
            });
        }
    }

    // ── Step 7: OCR each cell's quantity → CSV to stdout ──
    var stdout_buf: [4096]u8 = undefined;
    var stdout_w = std.fs.File.stdout().writerStreaming(&stdout_buf);
    const out = &stdout_w.interface;

    try out.print("row,col,quantity\n", .{});

    for (0..active_rows) |r| {
        for (0..grid_result.cols) |c| {
            const cell = grid_result.cells[r * grid_result.cols + c];

            // Extract footer region: bottom 25% of cell, trimmed
            const footer_y = cell.y + @as(u32, @intFromFloat(
                @as(f32, @floatFromInt(cell.h)) * grid.qty_region_start,
            ));
            const footer_h = cell.y + cell.h -| grid.qty_trim_bottom -| footer_y;
            const footer_w = cell.w -| grid.qty_trim_right;

            if (footer_w == 0 or footer_h == 0) {
                try out.print("{d},{d},\n", .{ r, c });
                continue;
            }

            // Copy footer pixels to contiguous buffer
            var footer_buf: [max_footer_buf]u8 = undefined;
            const row_bytes = @as(usize, footer_w) * 3;
            const total_bytes = row_bytes * footer_h;

            if (total_bytes > max_footer_buf) {
                try out.print("{d},{d},\n", .{ r, c });
                continue;
            }

            for (0..footer_h) |dy| {
                const src_y = footer_y + @as(u32, @intCast(dy));
                const src_off = (@as(usize, src_y) * target_w + cell.x) * 3;
                const dst_off = dy * row_bytes;
                @memcpy(
                    footer_buf[dst_off .. dst_off + row_bytes],
                    norm_pixels[src_off .. src_off + row_bytes],
                );
            }

            // Run OCR
            const quantity = ocr.parseQuantity(
                footer_buf[0..total_bytes],
                footer_w,
                footer_h,
            );

            if (quantity) |q| {
                try out.print("{d},{d},{d}\n", .{ r, c, q });
            } else {
                try out.print("{d},{d},\n", .{ r, c });
            }
        }
    }

    try out.flush();
}

/// Save RGB pixels as PPM (Portable Pixmap) for debugging.
fn savePpm(path: []const u8, pixels: []const u8, w: u32, h: u32) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    var buf: [4096]u8 = undefined;
    var writer = file.writerStreaming(&buf);

    try writer.interface.print("P6\n{d} {d}\n255\n", .{ w, h });
    try writer.interface.flush();

    // Write raw RGB data directly
    const data_len = @as(usize, w) * h * 3;
    var offset: usize = 0;
    while (offset < data_len) {
        const chunk = @min(data_len - offset, 65536);
        try writer.interface.writeAll(pixels[offset .. offset + chunk]);
        offset += chunk;
    }
    try writer.interface.flush();
}

test "parseArgs: --title sets window title" {
    // Verify the CLI module compiles and argument handling works.
    // Full integration tests require a game window (not available in CI).
    const args = [_][]const u8{ "--title", "BlueArchive" };
    var window_title: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--title")) {
            i += 1;
            if (i < args.len) window_title = args[i];
        }
    }
    try std.testing.expectEqualStrings("BlueArchive", window_title.?);
}
