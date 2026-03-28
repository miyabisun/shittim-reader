//! shittim-reader: Screen analysis library for Blue Archive.
//!
//! Provides image analysis pipeline exported as a C ABI shared library (.dll).
//! See spec/overview.md for architecture and spec/scope.md for detailed design.

const std = @import("std");

pub const grid = @import("grid.zig");

test "library loads" {
    // Placeholder: confirms the build and test pipeline works.
    try std.testing.expect(true);
}

test {
    // Pull in all module tests.
    std.testing.refAllDecls(@This());
}
