//! shittim-reader: Screen analysis library for Blue Archive.
//!
//! Provides image analysis pipeline exported as a C ABI shared library (.dll).
//! See spec/overview.md for architecture and spec/scope.md for detailed design.

const std = @import("std");

// ── Core modules ──
pub const area_average = @import("area_average.zig");
pub const ncc = @import("ncc.zig");
pub const color = @import("color.zig");
pub const grid = @import("grid.zig");
pub const image = @import("image.zig");
pub const screen = @import("screen.zig");
pub const ocr = @import("ocr.zig");
pub const blue_weight = @import("blue_weight.zig");
pub const projection = @import("projection.zig");
pub const digit = @import("digit.zig");

test {
    // Pull in all module tests
    std.testing.refAllDecls(@This());
}
