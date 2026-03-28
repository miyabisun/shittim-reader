//! Screen classifier: identifies the current game screen type.
//!
//! Uses grid region detection and sidebar sampling to classify screens.
//! Currently supports: ITEM_INVENTORY detection.

const std = @import("std");
const grid_mod = @import("grid.zig");

pub const ScreenType = enum {
    item_inventory,
    unknown,
};

/// Classify the screen type from an RGB image.
///
/// For item_inventory detection:
/// - Check that the right half contains a #C4CFD4 grid region (via roi parameter)
/// - Verify the left side has sidebar-like chrome (non-extreme, low saturation)
///
/// Pass `roi` from `grid.detectGrid().roi` or `grid.findGridRegion()` to avoid
/// redundant grid region detection.
pub fn classify(pixels: []const u8, width: u32, height: u32, roi: ?grid_mod.RoiBounds) ScreenType {
    if (pixels.len < @as(usize, width) * height * 3) return .unknown;

    const has_grid = roi != null;

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
        const min_ch = @min(r, @min(g, b));
        const max_ch = @max(r, @max(g, b));
        has_sidebar = min_ch > 30 and max_ch < 240 and (max_ch - min_ch) < 80;
    }

    if (has_grid and has_sidebar) return .item_inventory;

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

    const roi = grid_mod.findGridRegion(pixels, w, h);
    try std.testing.expectEqual(ScreenType.unknown, classify(pixels, w, h, roi));
}

test "synthetic inventory screen → item_inventory" {
    const alloc = std.testing.allocator;
    const w: u32 = 1600;
    const h: u32 = 900;
    const pixels = try alloc.alloc(u8, w * h * 3);
    defer alloc.free(pixels);

    // Fill with mid-gray background (simulates sidebar)
    @memset(pixels, 128);

    // Draw separator lines that the scanline algorithm will detect:
    // - Horizontal scanline at y=450 must hit #C4CFD4 runs in right half
    // - Vertical scanline at x0+9 must hit a continuous #C4CFD4 strip
    const grid_x0: u32 = 845;
    const grid_x1: u32 = 1568;
    const grid_y0: u32 = 187;
    const grid_y1: u32 = 760;

    // Left border: 20px wide strip (x0+9 falls inside this)
    for (grid_y0..grid_y1) |y| {
        for (grid_x0..grid_x0 + 20) |x| {
            const idx = (@as(usize, y) * w + x) * 3;
            pixels[idx] = 0xC4;
            pixels[idx + 1] = 0xCF;
            pixels[idx + 2] = 0xD4;
        }
    }
    // Horizontal separator lines (3px tall) — one must cross y=450
    for ([_]u32{ grid_y0, 330, 448, grid_y1 - 3 }) |y| {
        for (grid_x0..grid_x1) |x| {
            for (0..3) |dy| {
                const idx = ((@as(usize, y) + dy) * w + x) * 3;
                pixels[idx] = 0xC4;
                pixels[idx + 1] = 0xCF;
                pixels[idx + 2] = 0xD4;
            }
        }
    }
    // Internal vertical separators + right border
    for ([_]u32{ 990, 1130, 1270, 1410, grid_x1 - 3 }) |x| {
        for (grid_y0..grid_y1) |y| {
            for (0..3) |dx| {
                const idx = (@as(usize, y) * w + x + dx) * 3;
                pixels[idx] = 0xC4;
                pixels[idx + 1] = 0xCF;
                pixels[idx + 2] = 0xD4;
            }
        }
    }

    const roi = grid_mod.findGridRegion(pixels, w, h);
    try std.testing.expect(roi != null);
    try std.testing.expectEqual(ScreenType.item_inventory, classify(pixels, w, h, roi));
}

test "grid present but no sidebar → unknown" {
    const alloc = std.testing.allocator;
    const w: u32 = 1600;
    const h: u32 = 900;
    const pixels = try alloc.alloc(u8, w * h * 3);
    defer alloc.free(pixels);

    // Pure black background (fails sidebar check: min_ch <= 30)
    @memset(pixels, 0);

    // Draw grid separator structures (same as inventory test)
    const grid_x0: u32 = 845;
    const grid_x1: u32 = 1568;
    const grid_y0: u32 = 187;
    const grid_y1: u32 = 760;

    for (grid_y0..grid_y1) |y| {
        for (grid_x0..grid_x0 + 20) |x| {
            const idx = (@as(usize, y) * w + x) * 3;
            pixels[idx] = 0xC4;
            pixels[idx + 1] = 0xCF;
            pixels[idx + 2] = 0xD4;
        }
    }
    for ([_]u32{ grid_y0, 330, 448, grid_y1 - 3 }) |y| {
        for (grid_x0..grid_x1) |x| {
            for (0..3) |dy| {
                const idx = ((@as(usize, y) + dy) * w + x) * 3;
                pixels[idx] = 0xC4;
                pixels[idx + 1] = 0xCF;
                pixels[idx + 2] = 0xD4;
            }
        }
    }

    const roi = grid_mod.findGridRegion(pixels, w, h);
    try std.testing.expect(roi != null); // grid IS detected
    try std.testing.expectEqual(ScreenType.unknown, classify(pixels, w, h, roi)); // but no sidebar
}
