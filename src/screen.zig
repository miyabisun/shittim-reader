//! Screen classifier: identifies the current game screen type.
//!
//! Uses key-region sampling to classify screens without analyzing the full image.
//! Currently supports: ITEM_INVENTORY detection.

const std = @import("std");
const grid_mod = @import("grid.zig");

pub const ScreenType = enum {
    item_inventory,
    unknown,
};

/// Classify the screen type from a normalized 1600×900 RGB image.
///
/// For item_inventory detection:
/// - Check that the right side (~53-98% x) contains separator-colored pixels
/// - Sample multiple probe points in the grid ROI area
pub fn classify(pixels: []const u8, width: u32, height: u32) ScreenType {
    if (pixels.len < @as(usize, width) * height * 3) return .unknown;

    const bounds = grid_mod.roiBounds(width, height);
    const roi_h = bounds.y1 - bounds.y0;

    // Check for separator color at several horizontal scan lines across the ROI
    var sep_hits: u32 = 0;
    const n_probes: u32 = 10;
    for (0..n_probes) |i| {
        const y = bounds.y0 + @as(u32, @intCast(i)) * roi_h / n_probes;
        var line_hits: u32 = 0;
        const scan_count: u32 = 20;
        for (0..scan_count) |j| {
            const x = bounds.x0 + @as(u32, @intCast(j)) * (bounds.x1 - bounds.x0) / scan_count;
            const idx = (@as(usize, y) * width + x) * 3;
            if (idx + 2 < pixels.len) {
                if (grid_mod.isSeparatorRgb(pixels[idx], pixels[idx + 1], pixels[idx + 2])) {
                    line_hits += 1;
                }
            }
        }
        // A scan line with >50% separator pixels counts as a separator hit
        if (line_hits > scan_count / 2) {
            sep_hits += 1;
        }
    }

    // Check left sidebar: item inventory has a non-extreme background
    // at x ~15%, y ~50% (not pure black/white, and has low-to-mid saturation)
    const sidebar_x: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(width)) * 0.15));
    const sidebar_y: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(height)) * 0.50));
    const sidebar_idx = (@as(usize, sidebar_y) * width + sidebar_x) * 3;
    var has_sidebar = false;
    if (sidebar_idx + 2 < pixels.len) {
        const r = pixels[sidebar_idx];
        const g = pixels[sidebar_idx + 1];
        const b = pixels[sidebar_idx + 2];
        // Sidebar should be non-extreme: all channels in a moderate range
        // AND not a saturated primary color (which would indicate game content, not sidebar chrome)
        const min_ch = @min(r, @min(g, b));
        const max_ch = @max(r, @max(g, b));
        has_sidebar = min_ch > 30 and max_ch < 240 and (max_ch - min_ch) < 80;
    }

    // Need at least 2 separator line hits and sidebar presence
    if (sep_hits >= 2 and has_sidebar) return .item_inventory;

    return .unknown;
}

// ── Tests ──

test "all black → unknown" {
    const alloc = std.testing.allocator;
    const w: u32 = 1600;
    const h: u32 = 900;
    const pixels = try alloc.alloc(u8, w * h * 3);
    defer alloc.free(pixels);
    @memset(pixels, 0);

    try std.testing.expectEqual(ScreenType.unknown, classify(pixels, w, h));
}

test "synthetic inventory screen → item_inventory" {
    const alloc = std.testing.allocator;
    const w: u32 = 1600;
    const h: u32 = 900;
    const pixels = try alloc.alloc(u8, w * h * 3);
    defer alloc.free(pixels);

    // Fill with mid-gray background (simulates sidebar)
    @memset(pixels, 128);

    // Draw separator lines across the grid ROI
    const bounds = grid_mod.roiBounds(1600, 900);
    const roi_h = bounds.y1 - bounds.y0;

    // Draw 5 horizontal separator lines evenly spaced
    for (0..5) |i| {
        const y = bounds.y0 + @as(u32, @intCast(i)) * roi_h / 5;
        for (bounds.x0..bounds.x1) |x| {
            const idx = (@as(usize, y) * w + x) * 3;
            pixels[idx] = 0xC4;
            pixels[idx + 1] = 0xCF;
            pixels[idx + 2] = 0xD4;
        }
    }

    try std.testing.expectEqual(ScreenType.item_inventory, classify(pixels, w, h));
}
