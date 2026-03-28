//! shittim CLI: Developer tool for shittim-reader.
//!
//! Subcommands:
//!   capture  - Capture game window client area to PNG

const std = @import("std");

pub fn main() !void {
    std.debug.print("shittim: no subcommand specified. Use --help for usage.\n", .{});
    std.process.exit(1);
}

test "cli compiles" {
    try std.testing.expect(true);
}
