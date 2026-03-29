//! Debug tool: analyze weight distribution of 'x' character images.
//!
//! Usage: zig build x-debug -- <footer.png>

const std = @import("std");
const zigimg = @import("zigimg");
const shittim = @import("shittim_reader");

const blue_weight = shittim.blue_weight;
const proj = shittim.projection;

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: x-debug <footer.png>\n", .{});
        std.process.exit(1);
    }

    var read_buf: [8192]u8 = undefined;
    var img = try zigimg.Image.fromFilePath(allocator, args[1], &read_buf);
    defer img.deinit(allocator);
    if (img.pixelFormat() != .rgb24) try img.convert(allocator, .rgb24);

    const w: u32 = @intCast(img.width);
    const h: u32 = @intCast(img.height);
    const rgb = img.rawBytes();

    std.debug.print("image: {d}x{d}\n", .{ w, h });

    // Compute weight map
    var wmap_buf: [blue_weight.max_weight_map_size]f32 = undefined;
    const wmap = blue_weight.computeWeightMap(&wmap_buf, rgb, w, h);

    // Column projection
    var col_buf: [proj.max_profile_w]f32 = undefined;
    const col_prof = proj.columnProjection(wmap, w, h, &col_buf);

    // Segment
    var seg_buf: [proj.max_segments]proj.Segment = undefined;
    const segs = proj.segmentCharacters(col_prof, &seg_buf);

    std.debug.print("segments: {d}\n\n", .{segs.len});

    const margin_rows: u32 = @intFromFloat(@as(f32, @floatFromInt(h)) * 0.15);
    std.debug.print("margin_rows (15% of {d}): {d}\n\n", .{ h, margin_rows });

    for (segs, 0..) |seg, si| {
        std.debug.print("seg[{d}]: col {d}..{d} (w={d})\n", .{ si, seg.start, seg.end, seg.width() });

        // Col peak
        var peak: f32 = 0;
        for (seg.start..seg.end) |c| peak = @max(peak, col_prof[c]);
        std.debug.print("  col peak: {d:.3}\n", .{peak});

        // Row projection for this segment
        var row_buf: [proj.max_profile_h]f32 = undefined;
        const row_prof = proj.rowProjection(wmap, w, h, seg.start, seg.end, &row_buf);

        var margin_weight: f32 = 0;
        var total_weight: f32 = 0;
        for (0..h) |ry| {
            total_weight += row_prof[ry];
            if (ry < margin_rows or ry >= h - margin_rows) {
                margin_weight += row_prof[ry];
            }
        }

        const ratio = if (total_weight > 0) margin_weight / total_weight else 0;
        std.debug.print("  margin_weight: {d:.4}, total: {d:.4}, ratio: {d:.4}\n", .{
            margin_weight, total_weight, ratio,
        });

        // Print full row profile
        std.debug.print("  row profile:\n", .{});
        for (0..h) |ry| {
            const marker: []const u8 = if (ry < margin_rows or ry >= h - margin_rows) " [margin]" else "";
            std.debug.print("    row {d:>2}: {d:.4}{s}\n", .{ ry, row_prof[ry], marker });
        }
        std.debug.print("\n", .{});
    }
}
