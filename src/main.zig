//! shittim CLI: Developer tool for shittim-reader.
//!
//! Subcommands:
//!   scan  - Capture game window and output item quantities as CSV
//!
//! Usage:
//!   zig build run -- scan                         # auto-detect game window
//!   zig build run -- scan --title "BlueArchive"   # specify window title
//!   zig build run -- scan --wgc                   # use WGC background capture
//!   zig build run -- scan --list-windows          # list visible windows

const std = @import("std");
const shittim = @import("shittim_reader");
const capture = @import("capture.zig");
const wgc = @import("wgc.zig");

const grid = shittim.grid;
const image = shittim.image;
const ocr = shittim.ocr;
const screen_mod = shittim.screen;

/// Maximum footer region size for stack buffer (pixels x 3 channels).
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
        \\  --wgc             Use Windows Graphics Capture (background capture)
        \\  --list-windows    List all visible windows and exit
        \\  --dump [path]     Save captured image as PPM (default: capture.ppm)
        \\
    , .{});
}

fn scan(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var window_title: ?[]const u8 = null;
    var dump_path: ?[]const u8 = null;
    var use_wgc = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--list-windows")) {
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
        } else if (std.mem.eql(u8, args[i], "--wgc")) {
            use_wgc = true;
        }
    }

    // ── Capture ──
    const hwnd = if (window_title) |title|
        capture.findWindowByTitle(title) catch {
            std.debug.print("error: window not found: \"{s}\"\n", .{title});
            return error.WindowNotFound;
        }
    else
        capture.findWindowBySubstring("BlueArchive") catch
            capture.findWindowBySubstring("\xE3\x83\x96\xE3\x83\xAB\xE3\x83\xBC\xE3\x82\xA2\xE3\x83\xBC\xE3\x82\xAB\xE3\x82\xA4\xE3\x83\x96") catch {
                std.debug.print("error: game window not found\n", .{});
                std.debug.print("hint: use --list-windows to see available windows\n", .{});
                return error.WindowNotFound;
            };

    // Choose capture method: WGC (background) or BitBlt (foreground)
    var pixels: []u8 = undefined;
    var cap_width: u32 = undefined;
    var cap_height: u32 = undefined;

    if (use_wgc) {
        const wgc_result = wgc.captureWindow(allocator, hwnd) catch |err| {
            std.debug.print("error: WGC capture failed: {s}\n", .{@errorName(err)});
            return error.CaptureFailed;
        };
        pixels = wgc_result.pixels;
        cap_width = wgc_result.width;
        cap_height = wgc_result.height;
    } else {
        const cap = try capture.captureWindow(allocator, hwnd);
        pixels = cap.pixels;
        cap_width = cap.width;
        cap_height = cap.height;
    }
    defer allocator.free(pixels);

    std.debug.print("captured: {d}x{d} (mode={s})\n", .{
        cap_width, cap_height, if (use_wgc) "wgc" else "bitblt",
    });

    if (dump_path) |path| {
        savePpm(path, pixels, cap_width, cap_height) catch |err| {
            std.debug.print("warning: failed to save dump: {s}\n", .{@errorName(err)});
        };
    }

    // ── Normalize ──
    const norm = try image.normalizePreservingAspect(
        allocator, pixels, cap_width, cap_height, 3,
    );
    defer norm.deinit(allocator);

    // ── Detect grid ���─
    const grid_result = try grid.detectGrid(allocator, norm.pixels, norm.width, norm.height);
    defer grid_result.deinit(allocator);

    const screen_type = screen_mod.classify(norm.pixels, norm.width, norm.height, grid_result.roi);
    std.debug.print("screen: {s}, grid: {d}x{d}\n", .{
        @tagName(screen_type), grid_result.cols, grid_result.rows,
    });

    if (grid_result.cells.len == 0) {
        std.debug.print("error: no grid cells detected\n", .{});
        return;
    }

    // ── OCR -> CSV ──
    const n_rows = grid.activeRows(grid_result);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_w = std.fs.File.stdout().writerStreaming(&stdout_buf);
    const out = &stdout_w.interface;

    try out.print("row,col,quantity\n", .{});

    for (0..n_rows) |r| {
        for (0..grid_result.cols) |c| {
            const cell = grid_result.cells[r * grid_result.cols + c];
            const footer = grid.footerRegion(cell) orelse {
                try out.print("{d},{d},\n", .{ r, c });
                continue;
            };

            var footer_buf: [max_footer_buf]u8 = undefined;
            const footer_pixels = grid.extractRegion(
                norm.pixels, norm.width, footer, &footer_buf,
            ) orelse {
                try out.print("{d},{d},\n", .{ r, c });
                continue;
            };

            if (ocr.parseQuantity(footer_pixels, footer.w, footer.h)) |q| {
                try out.print("{d},{d},{d}\n", .{ r, c, q });
            } else {
                try out.print("{d},{d},\n", .{ r, c });
            }
        }
    }

    try out.flush();
}

/// Save RGB pixels as PPM (Portable Pixmap).
fn savePpm(path: []const u8, pixels: []const u8, w: u32, h: u32) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    var buf: [4096]u8 = undefined;
    var writer = file.writerStreaming(&buf);

    try writer.interface.print("P6\n{d} {d}\n255\n", .{ w, h });
    try writer.interface.flush();

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

test "parseArgs: --wgc sets flag" {
    const args = [_][]const u8{ "--wgc", "--title", "Test" };
    var use_wgc = false;
    var window_title: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--wgc")) {
            use_wgc = true;
        } else if (std.mem.eql(u8, args[i], "--title")) {
            i += 1;
            if (i < args.len) window_title = args[i];
        }
    }
    try std.testing.expect(use_wgc);
    try std.testing.expectEqualStrings("Test", window_title.?);
}

test "wgc module compiles" {
    _ = wgc;
}
