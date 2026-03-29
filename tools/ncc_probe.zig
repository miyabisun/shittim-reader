//! Probe tool: find optimal template size for NCC matching at width=1600.
//!
//! 1. Trims transparent borders from the SchaleDB icon
//! 2. Sweeps template width from 70..120px (keeping aspect ratio)
//! 3. Matches against the cell's icon region (top 80%) at original size
//! 4. Reports best NCC at each template width
//!
//! Usage: zig build ncc-probe -- <cell.png> <icon.png>

const std = @import("std");
const zigimg = @import("zigimg");
const shittim = @import("shittim_reader");

const ncc_mod = shittim.ncc;
const area_average = shittim.area_average;

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        std.debug.print("Usage: ncc-probe <cell.png> <icon.png> [alpha_threshold]\n", .{});
        std.debug.print("  alpha_threshold: 0-255 (default: {d} from ncc.alpha_threshold)\n", .{ncc_mod.alpha_threshold});
        std.process.exit(1);
    }

    const alpha_threshold: u8 = if (args.len >= 4)
        std.fmt.parseInt(u8, args[3], 10) catch ncc_mod.alpha_threshold
    else
        ncc_mod.alpha_threshold;

    // ── Load cell image (RGB) ──
    var rbuf1: [8192]u8 = undefined;
    var cell_img = try zigimg.Image.fromFilePath(allocator, args[1], &rbuf1);
    defer cell_img.deinit(allocator);
    if (cell_img.pixelFormat() != .rgb24) try cell_img.convert(allocator, .rgb24);

    const cell_w: u32 = @intCast(cell_img.width);
    const cell_h: u32 = @intCast(cell_img.height);
    const cell_rgb = cell_img.rawBytes();

    // Icon region: top 80% of cell
    const icon_h: u32 = @intFromFloat(@as(f32, @floatFromInt(cell_h)) * ncc_mod.icon_region_ratio);
    std.debug.print("cell: {d}x{d} (icon region: {d}x{d})\n", .{ cell_w, cell_h, cell_w, icon_h });

    // Convert icon region to grayscale
    const gray_n = @as(usize, cell_w) * icon_h;
    const cell_gray = try allocator.alloc(u8, gray_n);
    defer allocator.free(cell_gray);
    ncc_mod.rgbToGray(cell_rgb[0 .. gray_n * 3], cell_gray);

    // ── Load icon image (RGBA) ──
    var rbuf2: [8192]u8 = undefined;
    var icon_img = try zigimg.Image.fromFilePath(allocator, args[2], &rbuf2);
    defer icon_img.deinit(allocator);
    if (icon_img.pixelFormat() != .rgba32) try icon_img.convert(allocator, .rgba32);

    const raw_w: u32 = @intCast(icon_img.width);
    const raw_h: u32 = @intCast(icon_img.height);
    const icon_rgba = icon_img.rawBytes();

    // ── Trim transparent borders ──
    const bounds = ncc_mod.opaqueBounds(icon_rgba, raw_w, raw_h, alpha_threshold) orelse {
        std.debug.print("error: icon is fully transparent\n", .{});
        std.process.exit(1);
    };
    std.debug.print("icon: {d}x{d} → trimmed: {d}x{d} (at {d},{d})\n", .{
        raw_w, raw_h, bounds.w, bounds.h, bounds.x, bounds.y,
    });

    const trimmed_rgba = try ncc_mod.cropRgba(allocator, icon_rgba, raw_w, bounds);
    defer allocator.free(trimmed_rgba);

    const aspect = @as(f32, @floatFromInt(bounds.h)) / @as(f32, @floatFromInt(bounds.w));

    // ── Sweep template width from 70 to 120px, keeping aspect ratio ──
    std.debug.print("\n{s:>5} {s:>9} {s:>7} {s:>8} {s:>4} {s:>4}\n", .{
        "tw", "th", "opaque", "NCC", "x", "y",
    });

    var best_score: f32 = -2.0;
    var best_tw: u32 = 0;

    var tw: u32 = 70;
    while (tw <= 120) : (tw += 1) {
        const th: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(tw)) * aspect));
        if (th == 0) continue;
        if (tw > cell_w or th > icon_h) continue;

        // Resize trimmed icon to tw x th (RGBA, preserving aspect)
        const resized = try area_average.areaAverage(
            allocator, trimmed_rgba, bounds.w, bounds.h, tw, th, 4,
        );
        defer allocator.free(resized);

        // Extract grayscale + mask
        const tn = @as(usize, tw) * th;
        const tmpl_gray = try allocator.alloc(u8, tn);
        defer allocator.free(tmpl_gray);
        const tmpl_mask = try allocator.alloc(u8, tn);
        defer allocator.free(tmpl_mask);
        const opaque_n = ncc_mod.rgbaToGrayAndMask(resized, tmpl_gray, tmpl_mask, alpha_threshold);

        // Sliding NCC
        const result = ncc_mod.slidingMaskedNcc(
            cell_gray, cell_w, icon_h,
            tmpl_gray, tmpl_mask, tw, th,
            1, // exhaustive for precision
        ) orelse continue;

        const is_best = result.score > best_score;
        if (is_best) {
            best_score = result.score;
            best_tw = tw;
        }

        const marker: []const u8 = if (is_best) " <--" else "";
        std.debug.print("{d:>3}px {d:>3}x{d:<3} {d:>5}px {d:>8.4} {d:>4} {d:>4}{s}\n", .{
            tw, tw, th, opaque_n, result.score, result.x, result.y, marker,
        });
    }

    const best_th: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(best_tw)) * aspect));
    std.debug.print("\n=== Best: template {d}x{d}px, NCC={d:.4} ===\n", .{
        best_tw, best_th, best_score,
    });
}
