//! Normalized Cross-Correlation (NCC) for template matching.
//!
//! NCC = Σ((I - Ī)(T - T̄)) / sqrt(Σ(I - Ī)² × Σ(T - T̄)²)
//! Returns f32 in [-1.0, 1.0]: 1.0 = perfect match, -1.0 = inverted, 0.0 = uncorrelated.
//!
//! Uses single-pass computation via the identity:
//!   Σ(x - x̄)² = Σx² - n*x̄²
//!   Σ(x - x̄)(y - ȳ) = Σxy - n*x̄*ȳ

const std = @import("std");

/// Compute NCC between two same-sized grayscale buffers.
/// Returns 0.0 if either buffer has zero variance (flat region).
pub fn ncc(image: []const u8, template: []const u8) f32 {
    std.debug.assert(image.len == template.len);
    if (image.len == 0) return 0;

    var sum_i: f64 = 0;
    var sum_t: f64 = 0;
    var sum_ii: f64 = 0;
    var sum_tt: f64 = 0;
    var sum_it: f64 = 0;

    for (0..image.len) |idx| {
        const vi: f64 = @floatFromInt(image[idx]);
        const vt: f64 = @floatFromInt(template[idx]);
        sum_i += vi;
        sum_t += vt;
        sum_ii += vi * vi;
        sum_tt += vt * vt;
        sum_it += vi * vt;
    }

    const n: f64 = @floatFromInt(image.len);
    const var_i = sum_ii - sum_i * sum_i / n;
    const var_t = sum_tt - sum_t * sum_t / n;
    const cov = sum_it - sum_i * sum_t / n;

    const denom = @sqrt(var_i * var_t);
    if (denom < 1e-10) return 0;
    return @floatCast(cov / denom);
}

/// Compute masked NCC. Only pixels where mask[i] != 0 contribute.
/// Returns 0.0 if no masked pixels or zero variance.
pub fn maskedNcc(image: []const u8, template: []const u8, mask: []const u8) f32 {
    std.debug.assert(image.len == template.len);
    std.debug.assert(image.len == mask.len);

    var count: u64 = 0;
    var sum_i: f64 = 0;
    var sum_t: f64 = 0;
    var sum_ii: f64 = 0;
    var sum_tt: f64 = 0;
    var sum_it: f64 = 0;

    for (0..image.len) |idx| {
        if (mask[idx] != 0) {
            const vi: f64 = @floatFromInt(image[idx]);
            const vt: f64 = @floatFromInt(template[idx]);
            sum_i += vi;
            sum_t += vt;
            sum_ii += vi * vi;
            sum_tt += vt * vt;
            sum_it += vi * vt;
            count += 1;
        }
    }
    if (count == 0) return 0;

    const n: f64 = @floatFromInt(count);
    const var_i = sum_ii - sum_i * sum_i / n;
    const var_t = sum_tt - sum_t * sum_t / n;
    const cov = sum_it - sum_i * sum_t / n;

    const denom = @sqrt(var_i * var_t);
    if (denom < 1e-10) return 0;
    return @floatCast(cov / denom);
}

// ── Tests ──

test "perfect match → 1.0" {
    const data = [_]u8{ 10, 50, 100, 200, 255 };
    const score = ncc(&data, &data);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), score, 1e-5);
}

test "inverted → -1.0" {
    const a = [_]u8{ 0, 50, 100, 200, 255 };
    const b = [_]u8{ 255, 205, 155, 55, 0 };
    const score = ncc(&a, &b);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), score, 1e-5);
}

test "flat region → 0.0" {
    const flat = [_]u8{ 100, 100, 100, 100 };
    const varied = [_]u8{ 10, 50, 200, 255 };
    const score = ncc(&flat, &varied);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), score, 1e-5);
}

test "known correlation" {
    const a = [_]u8{ 10, 20, 30, 40 };
    const b = [_]u8{ 20, 40, 60, 80 };
    const score = ncc(&a, &b);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), score, 1e-5);
}

test "masked NCC — partial mask" {
    const image = [_]u8{ 10, 50, 100, 200 };
    const template = [_]u8{ 10, 50, 100, 200 };
    const mask = [_]u8{ 255, 255, 0, 0 };
    const score = maskedNcc(&image, &template, &mask);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), score, 1e-5);
}

test "masked NCC — all masked out → 0.0" {
    const image = [_]u8{ 10, 50, 100, 200 };
    const template = [_]u8{ 10, 50, 100, 200 };
    const mask = [_]u8{ 0, 0, 0, 0 };
    const score = maskedNcc(&image, &template, &mask);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), score, 1e-5);
}

test "single pixel → 0.0 (zero variance)" {
    const a = [_]u8{42};
    const b = [_]u8{42};
    const score = ncc(&a, &b);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), score, 1e-5);
}

test "empty buffers → 0.0" {
    const empty: []const u8 = &.{};
    const score = ncc(empty, empty);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), score, 1e-5);
}
