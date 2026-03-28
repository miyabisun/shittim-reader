//! OCR test fixture data — raw RGB images embedded at compile time.
//!
//! This module lives under test_fixtures/ so that @embedFile can access
//! the .rgb files without pulling test data into the src/ package.

pub const Fixture = struct {
    data: []const u8,
    w: u32,
    h: u32,
    expected: u32,
};

/// Pre-deskewed number region images (for recognizeDigits tests).
pub const fixtures = [_]Fixture{
    .{ .data = @embedFile("skew_number_rgb/number_r0_c0.rgb"), .w = 55, .h = 24, .expected = 924 },
    .{ .data = @embedFile("skew_number_rgb/number_r0_c1.rgb"), .w = 54, .h = 24, .expected = 381 },
    .{ .data = @embedFile("skew_number_rgb/number_r0_c2.rgb"), .w = 39, .h = 24, .expected = 95 },
    .{ .data = @embedFile("skew_number_rgb/number_r0_c3.rgb"), .w = 69, .h = 24, .expected = 1892 },
    .{ .data = @embedFile("skew_number_rgb/number_r0_c4.rgb"), .w = 54, .h = 24, .expected = 330 },
    .{ .data = @embedFile("skew_number_rgb/number_r1_c0.rgb"), .w = 54, .h = 24, .expected = 155 },
    .{ .data = @embedFile("skew_number_rgb/number_r1_c1.rgb"), .w = 54, .h = 24, .expected = 137 },
    .{ .data = @embedFile("skew_number_rgb/number_r1_c2.rgb"), .w = 69, .h = 24, .expected = 1917 },
    .{ .data = @embedFile("skew_number_rgb/number_r1_c3.rgb"), .w = 54, .h = 24, .expected = 849 },
    .{ .data = @embedFile("skew_number_rgb/number_r1_c4.rgb"), .w = 54, .h = 24, .expected = 396 },
    .{ .data = @embedFile("skew_number_rgb/number_r2_c0.rgb"), .w = 55, .h = 24, .expected = 206 },
    .{ .data = @embedFile("skew_number_rgb/number_r2_c1.rgb"), .w = 69, .h = 24, .expected = 1121 },
    .{ .data = @embedFile("skew_number_rgb/number_r2_c2.rgb"), .w = 54, .h = 24, .expected = 952 },
    .{ .data = @embedFile("skew_number_rgb/number_r2_c3.rgb"), .w = 54, .h = 24, .expected = 398 },
    .{ .data = @embedFile("skew_number_rgb/number_r2_c4.rgb"), .w = 39, .h = 24, .expected = 95 },
    .{ .data = @embedFile("skew_number_rgb/number_r3_c0.rgb"), .w = 69, .h = 24, .expected = 1452 },
    .{ .data = @embedFile("skew_number_rgb/number_r3_c1.rgb"), .w = 54, .h = 24, .expected = 607 },
    .{ .data = @embedFile("skew_number_rgb/number_r3_c2.rgb"), .w = 54, .h = 24, .expected = 282 },
    .{ .data = @embedFile("skew_number_rgb/number_r3_c3.rgb"), .w = 40, .h = 24, .expected = 89 },
    .{ .data = @embedFile("skew_number_rgb/number_r3_c4.rgb"), .w = 68, .h = 24, .expected = 1475 },
};

/// Raw number region images (non-deskewed, for parseQuantity tests).
/// These are the italic number regions before horizontal shear correction.
pub const number_fixtures = [_]Fixture{
    .{ .data = @embedFile("cells_number_rgb/number_r0_c0.rgb"), .w = 49, .h = 24, .expected = 924 },
    .{ .data = @embedFile("cells_number_rgb/number_r0_c1.rgb"), .w = 48, .h = 24, .expected = 381 },
    .{ .data = @embedFile("cells_number_rgb/number_r0_c2.rgb"), .w = 33, .h = 24, .expected = 95 },
    .{ .data = @embedFile("cells_number_rgb/number_r0_c3.rgb"), .w = 63, .h = 24, .expected = 1892 },
    .{ .data = @embedFile("cells_number_rgb/number_r0_c4.rgb"), .w = 48, .h = 24, .expected = 330 },
    .{ .data = @embedFile("cells_number_rgb/number_r1_c0.rgb"), .w = 48, .h = 24, .expected = 155 },
    .{ .data = @embedFile("cells_number_rgb/number_r1_c1.rgb"), .w = 48, .h = 24, .expected = 137 },
    .{ .data = @embedFile("cells_number_rgb/number_r1_c2.rgb"), .w = 63, .h = 24, .expected = 1917 },
    .{ .data = @embedFile("cells_number_rgb/number_r1_c3.rgb"), .w = 48, .h = 24, .expected = 849 },
    .{ .data = @embedFile("cells_number_rgb/number_r1_c4.rgb"), .w = 48, .h = 24, .expected = 396 },
    .{ .data = @embedFile("cells_number_rgb/number_r2_c0.rgb"), .w = 49, .h = 24, .expected = 206 },
    .{ .data = @embedFile("cells_number_rgb/number_r2_c1.rgb"), .w = 63, .h = 24, .expected = 1121 },
    .{ .data = @embedFile("cells_number_rgb/number_r2_c2.rgb"), .w = 48, .h = 24, .expected = 952 },
    .{ .data = @embedFile("cells_number_rgb/number_r2_c3.rgb"), .w = 48, .h = 24, .expected = 398 },
    .{ .data = @embedFile("cells_number_rgb/number_r2_c4.rgb"), .w = 33, .h = 24, .expected = 95 },
    .{ .data = @embedFile("cells_number_rgb/number_r3_c0.rgb"), .w = 63, .h = 24, .expected = 1452 },
    .{ .data = @embedFile("cells_number_rgb/number_r3_c1.rgb"), .w = 48, .h = 24, .expected = 607 },
    .{ .data = @embedFile("cells_number_rgb/number_r3_c2.rgb"), .w = 48, .h = 24, .expected = 282 },
    .{ .data = @embedFile("cells_number_rgb/number_r3_c3.rgb"), .w = 34, .h = 24, .expected = 89 },
    .{ .data = @embedFile("cells_number_rgb/number_r3_c4.rgb"), .w = 62, .h = 24, .expected = 1475 },
};
