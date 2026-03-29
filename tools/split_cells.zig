//! Dev tool: split a full-screen screenshot into individual cell PNGs.
//!
//! Usage: zig build split-cells -- <screen.png> [output_dir]
//!
//! Pipeline (same as main.zig scan):
//!   1. Load full-screen PNG via zigimg
//!   2. Normalize to 1600px width using area_average
//!   3. detectGrid → consistent Cell coordinates
//!   4. Extract each cell and save as r{row}c{col}.png

const std = @import("std");
const zigimg = @import("zigimg");
const shittim = @import("shittim_reader");

const grid = shittim.grid;
const image = shittim.image;

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: split-cells <screen.png> [output_dir]\n", .{});
        std.process.exit(1);
    }

    const input_path = args[1];
    const output_dir = if (args.len >= 3) args[2] else "tmp_images/cells";

    std.fs.cwd().makePath(output_dir) catch {};

    // ── Step 1: Load full-screen PNG ──
    var read_buf: [8192]u8 = undefined;
    var img = try zigimg.Image.fromFilePath(allocator, input_path, &read_buf);

    if (img.pixelFormat() != .rgb24) {
        try img.convert(allocator, .rgb24);
    }

    const src_w: u32 = @intCast(img.width);
    const src_h: u32 = @intCast(img.height);
    const rgb = img.rawBytes();

    std.debug.print("input: {d}x{d}\n", .{ src_w, src_h });

    // ── Step 2: Normalize to 1600px width ──
    const norm = try image.normalizePreservingAspect(allocator, rgb, src_w, src_h, 3);
    defer norm.deinit(allocator);

    // Release source image now that normalization is complete
    img.deinit(allocator);

    std.debug.print("normalized: {d}x{d}\n", .{ norm.width, norm.height });

    // ── Step 3: detectGrid ──
    const grid_result = try grid.detectGrid(allocator, norm.pixels, norm.width, norm.height);
    defer grid_result.deinit(allocator);

    std.debug.print("grid: {d} cols x {d} rows ({d} cells)\n", .{
        grid_result.cols, grid_result.rows, grid_result.cells.len,
    });

    if (grid_result.cells.len == 0) {
        std.debug.print("error: no grid cells detected\n", .{});
        std.process.exit(1);
    }

    // ── Step 4: Extract and save each cell ──
    // All cells share the same dimensions, so allocate one reusable buffer.
    const first = grid_result.cells[0];
    const cell_bytes = @as(usize, first.w) * first.h * 3;
    const cell_rgb = try allocator.alloc(u8, cell_bytes);
    defer allocator.free(cell_rgb);

    var cell_count: u32 = 0;
    var path_buf: [256]u8 = undefined;
    var write_buf: [65536]u8 = undefined;

    for (0..grid_result.rows) |r| {
        for (0..grid_result.cols) |c| {
            const cell = grid_result.cells[r * grid_result.cols + c];
            const row_bytes = @as(usize, cell.w) * 3;

            for (0..cell.h) |dy| {
                const src_off = ((@as(usize, cell.y) + dy) * norm.width + cell.x) * 3;
                const dst_off = dy * row_bytes;
                @memcpy(cell_rgb[dst_off..][0..row_bytes], norm.pixels[src_off..][0..row_bytes]);
            }

            var out_img = try zigimg.Image.fromRawPixels(allocator, cell.w, cell.h, cell_rgb, .rgb24);
            defer out_img.deinit(allocator);

            const path = std.fmt.bufPrint(&path_buf, "{s}/r{d}c{d}.png", .{
                output_dir, @as(u32, @intCast(r)), @as(u32, @intCast(c)),
            }) catch continue;

            out_img.writeToFilePath(allocator, path, &write_buf, .{ .png = .{} }) catch |err| {
                std.debug.print("warning: failed to save {s}: {s}\n", .{ path, @errorName(err) });
                continue;
            };
            cell_count += 1;
        }
    }

    std.debug.print("saved {d} cells to {s}/\n", .{ cell_count, output_dir });
}
