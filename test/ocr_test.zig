//! OCR integration tests: verify digit recognition against ground truth.
//!
//! Tests both recognizeDigits (pre-deskewed) and parseQuantity (raw footer).
//! These tests are compiled separately from the library to keep test
//! data out of the src/ package.

const std = @import("std");
const shittim = @import("shittim_reader");
const ocr_fixtures = @import("ocr_fixtures");

test "recognizeDigits matches all 20 ground truth values" {
    var correct: u32 = 0;
    var total: u32 = 0;

    for (ocr_fixtures.fixtures) |f| {
        const result = shittim.ocr.recognizeDigits(f.data, f.w, f.h);
        total += 1;

        if (result) |v| {
            if (v == f.expected) {
                correct += 1;
            } else {
                std.debug.print("MISMATCH: expected {d}, got {d} (w={d})\n", .{ f.expected, v, f.w });
            }
        } else {
            std.debug.print("FAILED: expected {d}, got null (w={d})\n", .{ f.expected, f.w });
        }
    }

    std.debug.print("\nOCR accuracy: {d}/{d}\n", .{ correct, total });
    try std.testing.expectEqual(total, correct);
}

test "parseQuantity matches all 20 ground truth values (with deskew)" {
    var correct: u32 = 0;
    var total: u32 = 0;

    for (ocr_fixtures.number_fixtures) |f| {
        const result = shittim.ocr.parseQuantity(f.data, f.w, f.h);
        total += 1;

        if (result) |v| {
            if (v == f.expected) {
                correct += 1;
            } else {
                std.debug.print("MISMATCH (footer): expected {d}, got {d} (w={d})\n", .{ f.expected, v, f.w });
            }
        } else {
            std.debug.print("FAILED (footer): expected {d}, got null (w={d})\n", .{ f.expected, f.w });
        }
    }

    std.debug.print("\nparseQuantity accuracy: {d}/{d}\n", .{ correct, total });
    try std.testing.expectEqual(total, correct);
}
