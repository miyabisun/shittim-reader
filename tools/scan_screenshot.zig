//! Dev tool: scan a screenshot PNG and output item quantities as YAML.
//!
//! Also saves deskewed footer images to tmp_images/cells_footer/ for debugging.
//!
//! Usage: zig build scan-screenshot -- <screen.png>

const std = @import("std");
const zigimg = @import("zigimg");
const shittim = @import("shittim_reader");

const grid = shittim.grid;
const image = shittim.image;
const ocr = shittim.ocr;
const screen_mod = shittim.screen;

const max_footer_buf = 200 * 50 * 3;
const max_deskew_buf = 190 * 50 * 3;

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: scan-screenshot <screen.png>\n", .{});
        std.process.exit(1);
    }

    // ── Load PNG ──
    var read_buf: [8192]u8 = undefined;
    var img = try zigimg.Image.fromFilePath(allocator, args[1], &read_buf);
    if (img.pixelFormat() != .rgb24) try img.convert(allocator, .rgb24);

    const src_w: u32 = @intCast(img.width);
    const src_h: u32 = @intCast(img.height);
    const rgb = img.rawBytes();

    std.debug.print("input: {d}x{d}\n", .{ src_w, src_h });

    // ── Normalize ──
    const norm = try image.normalizePreservingAspect(allocator, rgb, src_w, src_h, 3);
    defer norm.deinit(allocator);
    img.deinit(allocator);

    std.debug.print("normalized: {d}x{d}\n", .{ norm.width, norm.height });

    // ── Detect grid ──
    const grid_result = try grid.detectGrid(allocator, norm.pixels, norm.width, norm.height);
    defer grid_result.deinit(allocator);

    const screen_type = screen_mod.classify(norm.pixels, norm.width, norm.height, grid_result.roi);
    std.debug.print("screen: {s}, grid: {d}x{d} ({d} cells)\n", .{
        @tagName(screen_type), grid_result.cols, grid_result.rows, grid_result.cells.len,
    });

    if (grid_result.cells.len == 0) {
        std.debug.print("error: no grid cells detected\n", .{});
        std.process.exit(1);
    }

    // ── Prepare footer output directory ──
    const footer_dir = "tmp_images/cells_footer";
    std.fs.cwd().makePath(footer_dir) catch {};

    // ── OCR → YAML to stdout ──
    const n_rows = grid.activeRows(grid_result);

    var stdout_buf: [8192]u8 = undefined;
    var stdout_w = std.fs.File.stdout().writerStreaming(&stdout_buf);
    const out = &stdout_w.interface;

    try out.print("cells:\n", .{});

    var success: u32 = 0;
    var fail: u32 = 0;
    var path_buf: [256]u8 = undefined;
    var write_buf: [65536]u8 = undefined;

    for (0..n_rows) |r| {
        for (0..grid_result.cols) |c| {
            const cell = grid_result.cells[r * grid_result.cols + c];
            const footer = grid.footerRegion(cell) orelse {
                try out.print("  - row: {d}\n    col: {d}\n    quantity: null\n", .{ r, c });
                fail += 1;
                continue;
            };

            var footer_buf: [max_footer_buf]u8 = undefined;
            const footer_pixels = grid.extractRegion(
                norm.pixels, norm.width, footer, &footer_buf,
            ) orelse {
                try out.print("  - row: {d}\n    col: {d}\n    quantity: null\n", .{ r, c });
                fail += 1;
                continue;
            };

            // Deskew
            var deskew_buf: [max_deskew_buf]u8 = undefined;
            const deskewed = ocr.deskew(&deskew_buf, footer_pixels, footer.w, footer.h);

            // Save deskewed footer as PNG
            {
                var footer_img = zigimg.Image.fromRawPixels(
                    allocator, deskewed.w, footer.h, deskewed.pixels, .rgb24,
                ) catch null;
                if (footer_img) |*fi| {
                    defer fi.deinit(allocator);
                    const path = std.fmt.bufPrint(&path_buf, "{s}/r{d}c{d}.png", .{
                        footer_dir, @as(u32, @intCast(r)), @as(u32, @intCast(c)),
                    }) catch "";
                    if (path.len > 0) {
                        fi.writeToFilePath(allocator, path, &write_buf, .{ .png = .{} }) catch {};
                    }
                }
            }

            // OCR
            const quantity = ocr.recognizeDigits(deskewed.pixels, deskewed.w, footer.h);

            if (quantity) |q| {
                try out.print("  - row: {d}\n    col: {d}\n    quantity: {d}\n", .{ r, c, q });
                success += 1;
            } else {
                try out.print("  - row: {d}\n    col: {d}\n    quantity: null\n", .{ r, c });
                fail += 1;
            }
        }
    }

    try out.flush();

    std.debug.print("OCR: {d}/{d} recognized ({d} failed)\n", .{ success, success + fail, fail });
    std.debug.print("footer images saved to {s}/\n", .{footer_dir});
}
