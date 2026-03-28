//! Digit classification using projection profile matching.
//!
//! Classifies a character segment by comparing its normalized column/row
//! projection profiles against reference profiles (extracted from game
//! screenshots). Uses weighted Euclidean distance for nearest-neighbor
//! classification.

const std = @import("std");

pub const n_col_bins: u32 = 10;
pub const n_row_bins: u32 = 12;
pub const n_row_half_bins: u32 = 6;

/// Reference column profiles for digits 0-9.
/// Extracted from test fixtures via scripts/extract_digit_profiles.mjs.
pub const col_profiles: [10][n_col_bins]f32 = .{
    .{ 0.050618, 0.194102, 0.124328, 0.064118, 0.052799, 0.052215, 0.059252, 0.086437, 0.186432, 0.129697 }, // 0 (3 samples)
    .{ 0.019951, 0.028698, 0.037445, 0.056466, 0.098969, 0.142638, 0.187472, 0.182513, 0.142787, 0.103060 }, // 1 (11 samples)
    .{ 0.072213, 0.134625, 0.119257, 0.091902, 0.080031, 0.081858, 0.088212, 0.105856, 0.144393, 0.081653 }, // 2 (8 samples)
    .{ 0.063882, 0.091569, 0.059927, 0.061404, 0.076591, 0.082595, 0.105463, 0.160906, 0.206623, 0.091040 }, // 3 (6 samples)
    .{ 0.044666, 0.055686, 0.044364, 0.039465, 0.041285, 0.055111, 0.116271, 0.286062, 0.255008, 0.062082 }, // 4 (4 samples)
    .{ 0.069937, 0.166147, 0.110919, 0.077954, 0.075193, 0.080091, 0.088731, 0.105671, 0.145116, 0.080242 }, // 5 (7 samples)
    .{ 0.044769, 0.187040, 0.137552, 0.072404, 0.064569, 0.067194, 0.078364, 0.103885, 0.160461, 0.083761 }, // 6 (3 samples)
    .{ 0.050247, 0.080312, 0.147074, 0.154707, 0.118606, 0.100137, 0.087708, 0.093728, 0.099724, 0.067756 }, // 7 (4 samples)
    .{ 0.047232, 0.159033, 0.135148, 0.090785, 0.070050, 0.069586, 0.087381, 0.130265, 0.155432, 0.055088 }, // 8 (6 samples)
    .{ 0.090704, 0.152188, 0.103520, 0.075408, 0.066938, 0.063035, 0.067965, 0.114288, 0.176737, 0.089215 }, // 9 (10 samples)
};

/// Reference row profiles for digits 0-9.
pub const row_profiles: [10][n_row_bins]f32 = .{
    .{ 0.000000, 0.001948, 0.151234, 0.092421, 0.100529, 0.090160, 0.108399, 0.091590, 0.094618, 0.098675, 0.170426, 0.000000 }, // 0 (3 samples)
    .{ 0.005557, 0.000354, 0.071153, 0.165279, 0.191455, 0.093470, 0.102926, 0.088683, 0.099242, 0.093693, 0.088186, 0.000000 }, // 1 (11 samples)
    .{ 0.001618, 0.002044, 0.168326, 0.102501, 0.093050, 0.047524, 0.061249, 0.061444, 0.060359, 0.078268, 0.323616, 0.000000 }, // 2 (8 samples)
    .{ 0.021919, 0.009621, 0.176589, 0.101335, 0.075803, 0.045792, 0.121008, 0.053931, 0.072479, 0.110485, 0.211037, 0.000000 }, // 3 (6 samples)
    .{ 0.000085, 0.000371, 0.086399, 0.131050, 0.082147, 0.065125, 0.079196, 0.086110, 0.346990, 0.068382, 0.054145, 0.000000 }, // 4 (4 samples)
    .{ 0.000224, 0.000120, 0.177582, 0.033169, 0.037985, 0.141242, 0.168271, 0.055805, 0.054814, 0.112980, 0.217807, 0.000000 }, // 5 (7 samples)
    .{ 0.000025, 0.000984, 0.137292, 0.082765, 0.048417, 0.105619, 0.177439, 0.099345, 0.095929, 0.091146, 0.161039, 0.000000 }, // 6 (3 samples)
    .{ 0.000000, 0.000000, 0.321646, 0.120059, 0.069453, 0.064168, 0.076154, 0.075902, 0.092040, 0.088133, 0.092444, 0.000000 }, // 7 (4 samples)
    .{ 0.000440, 0.001529, 0.135821, 0.085194, 0.087895, 0.088974, 0.156307, 0.085991, 0.085208, 0.095698, 0.176944, 0.000000 }, // 8 (6 samples)
    .{ 0.008677, 0.002949, 0.147876, 0.086877, 0.091518, 0.093181, 0.166645, 0.119079, 0.039771, 0.082202, 0.161224, 0.000000 }, // 9 (10 samples)
};

/// Reference upper-half row profiles for digits 0-9.
pub const row_upper_profiles: [10][n_row_half_bins]f32 = .{
    .{ 0.000000, 0.009882, 0.338950, 0.214068, 0.213777, 0.223323 }, // 0 (3 samples)
    .{ 0.010183, 0.001490, 0.147268, 0.372543, 0.283924, 0.184592 }, // 1 (11 samples)
    .{ 0.003886, 0.011453, 0.419443, 0.255599, 0.182717, 0.126901 }, // 2 (8 samples)
    .{ 0.042242, 0.026332, 0.417533, 0.241224, 0.140929, 0.131740 }, // 3 (6 samples)
    .{ 0.000245, 0.002202, 0.262522, 0.343421, 0.202922, 0.188688 }, // 4 (4 samples)
    .{ 0.000443, 0.000523, 0.377312, 0.064085, 0.069518, 0.488121 }, // 5 (7 samples)
    .{ 0.000062, 0.004630, 0.322433, 0.176109, 0.102672, 0.394094 }, // 6 (3 samples)
    .{ 0.000000, 0.000000, 0.636456, 0.159808, 0.096364, 0.107372 }, // 7 (4 samples)
    .{ 0.001088, 0.007377, 0.330861, 0.202728, 0.192896, 0.265049 }, // 8 (6 samples)
    .{ 0.018624, 0.011063, 0.337449, 0.198285, 0.196049, 0.238531 }, // 9 (10 samples)
};

/// Reference lower-half row profiles for digits 0-9.
pub const row_lower_profiles: [10][n_row_half_bins]f32 = .{
    .{ 0.205509, 0.157919, 0.177724, 0.165470, 0.293377, 0.000000 }, // 0 (3 samples)
    .{ 0.232828, 0.175692, 0.217005, 0.188120, 0.186355, 0.000000 }, // 1 (11 samples)
    .{ 0.107660, 0.107220, 0.108860, 0.128591, 0.547669, 0.000000 }, // 2 (8 samples)
    .{ 0.247228, 0.098575, 0.116140, 0.181068, 0.356990, 0.000000 }, // 3 (6 samples)
    .{ 0.147108, 0.120089, 0.510305, 0.130003, 0.092495, 0.000000 }, // 4 (4 samples)
    .{ 0.349694, 0.087087, 0.084851, 0.160270, 0.318098, 0.000000 }, // 5 (7 samples)
    .{ 0.328645, 0.153141, 0.150557, 0.133461, 0.234196, 0.000000 }, // 6 (3 samples)
    .{ 0.185683, 0.175894, 0.215654, 0.203445, 0.219324, 0.000000 }, // 7 (4 samples)
    .{ 0.289473, 0.141573, 0.144475, 0.147178, 0.277301, 0.000000 }, // 8 (6 samples)
    .{ 0.243218, 0.291555, 0.072784, 0.126110, 0.266333, 0.000000 }, // 9 (10 samples)
};

/// Weights for each profile type in the combined distance.
/// Row profile is weighted higher because it better discriminates
/// similar-shape digits (e.g. 3 vs 8, 6 vs 9).
const col_weight: f32 = 1.0;
const row_weight: f32 = 1.5;
const row_upper_weight: f32 = 1.0;
const row_lower_weight: f32 = 1.0;

/// Feature vector: concatenation of all normalized profiles.
pub const Features = struct {
    col: [n_col_bins]f32,
    row: [n_row_bins]f32,
    row_upper: [n_row_half_bins]f32,
    row_lower: [n_row_half_bins]f32,
};

/// Classify a digit by nearest-neighbor on combined profile distance.
/// Returns the best-matching digit (0-9).
pub fn classifyDigit(features: Features) u8 {
    var best_dist: f32 = std.math.inf(f32);
    var best_digit: u8 = 0;

    for (0..10) |d| {
        const dist = col_weight * euclideanDist(&features.col, &col_profiles[d]) +
            row_weight * euclideanDist(&features.row, &row_profiles[d]) +
            row_upper_weight * euclideanDist(&features.row_upper, &row_upper_profiles[d]) +
            row_lower_weight * euclideanDist(&features.row_lower, &row_lower_profiles[d]);

        if (dist < best_dist) {
            best_dist = dist;
            best_digit = @intCast(d);
        }
    }

    return best_digit;
}

/// Euclidean distance between two same-length slices.
fn euclideanDist(a: []const f32, b: []const f32) f32 {
    var sum: f32 = 0;
    for (a, b) |va, vb| {
        const diff = va - vb;
        sum += diff * diff;
    }
    return @sqrt(sum);
}

// ── Tests ──

test "classifyDigit returns correct digit for reference profiles" {
    // Each reference profile should classify as itself
    for (0..10) |d| {
        const features = Features{
            .col = col_profiles[d],
            .row = row_profiles[d],
            .row_upper = row_upper_profiles[d],
            .row_lower = row_lower_profiles[d],
        };
        const result = classifyDigit(features);
        try std.testing.expectEqual(@as(u8, @intCast(d)), result);
    }
}

test "euclideanDist computes correctly" {
    const a = [_]f32{ 1.0, 0.0, 0.0 };
    const b = [_]f32{ 0.0, 1.0, 0.0 };
    const dist = euclideanDist(&a, &b);
    try std.testing.expectApproxEqAbs(@as(f32, @sqrt(2.0)), dist, 1e-5);
}
