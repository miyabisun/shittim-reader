#!/usr/bin/env node
/**
 * Extract digit reference profiles from test fixtures.
 *
 * Replicates the blue_weight + projection pipeline in JavaScript,
 * segments characters from each skew_number image, and computes
 * normalized profiles per digit. Outputs Zig const arrays.
 *
 * Usage:
 *   node scripts/extract_digit_profiles.mjs
 */

import sharp from "sharp";
import { readFile } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = join(__dirname, "..");

const N_COL_BINS = 10;
const N_ROW_BINS = 12;
const N_ROW_HALF_BINS = 6;

// ── Blue weight (mirrors src/blue_weight.zig — keep in sync) ──

const CORE = [45, 70, 99];
const GRAD = [210, 185, 156];
const GRAD_DOT = GRAD[0] ** 2 + GRAD[1] ** 2 + GRAD[2] ** 2;
const MAX_PERP = 45;
const MAX_PERP_SQ = MAX_PERP ** 2;
const T_MAX = 0.55;

function blueWeight(r, g, b) {
  const vr = r - CORE[0],
    vg = g - CORE[1],
    vb = b - CORE[2];
  const t = (vr * GRAD[0] + vg * GRAD[1] + vb * GRAD[2]) / GRAD_DOT;
  if (t < -0.1 || t > T_MAX) return 0;
  const pr = vr - t * GRAD[0],
    pg = vg - t * GRAD[1],
    pb = vb - t * GRAD[2];
  const perpSq = pr * pr + pg * pg + pb * pb;
  if (perpSq > MAX_PERP_SQ) return 0;
  const tc = Math.max(0, Math.min(T_MAX, t));
  const tn = tc / T_MAX;
  const tWeight = (1 - tn) * (1 - tn);
  return Math.max(tWeight * (1 - Math.sqrt(perpSq) / MAX_PERP), 0);
}

function computeWeightMap(data, w, h) {
  const map = new Float32Array(w * h);
  for (let i = 0; i < w * h; i++) {
    map[i] = blueWeight(data[i * 3], data[i * 3 + 1], data[i * 3 + 2]);
  }
  return map;
}

// ── Projection (mirrors src/projection.zig — keep in sync) ──

// Segment threshold: fraction of peak column projection value.
// Must match projection.zig segmentCharacters threshold.
const SEGMENT_THRESHOLD = 0.08;

function columnProjection(wmap, w, h) {
  const prof = new Float32Array(w);
  for (let col = 0; col < w; col++) {
    let sum = 0;
    for (let row = 0; row < h; row++) sum += wmap[row * w + col];
    prof[col] = sum;
  }
  return prof;
}

function rowProjection(wmap, w, h, colStart, colEnd) {
  const prof = new Float32Array(h);
  for (let row = 0; row < h; row++) {
    let sum = 0;
    for (let col = colStart; col < colEnd; col++) sum += wmap[row * w + col];
    prof[row] = sum;
  }
  return prof;
}

function segmentCharacters(colProf) {
  let maxVal = 0;
  for (const v of colProf) maxVal = Math.max(maxVal, v);
  if (maxVal < 0.01) return [];

  const threshold = maxVal * SEGMENT_THRESHOLD;
  const segs = [];
  let inSeg = false,
    start = 0;

  for (let i = 0; i < colProf.length; i++) {
    if (!inSeg && colProf[i] > threshold) {
      inSeg = true;
      start = i;
    } else if (inSeg && colProf[i] <= threshold) {
      inSeg = false;
      segs.push({ start, end: i });
    }
  }
  if (inSeg) segs.push({ start, end: colProf.length });
  return segs;
}

function normalizeProfile(src, nBins) {
  if (src.length === 0) return new Float32Array(nBins);
  let sum = 0;
  for (const v of src) sum += v;
  if (sum < 1e-6) return new Float32Array(nBins);

  const dest = new Float32Array(nBins);
  if (nBins === 1) {
    dest[0] = 1.0;
    return dest;
  }
  for (let i = 0; i < nBins; i++) {
    const pos = (i * (src.length - 1)) / (nBins - 1);
    const idx0 = Math.floor(pos);
    const frac = pos - idx0;
    const idx1 = Math.min(idx0 + 1, src.length - 1);
    dest[i] = (src[idx0] * (1 - frac) + src[idx1] * frac) / sum;
  }
  // Re-normalize: discrete sampling doesn't preserve unit sum
  let destSum = 0;
  for (let i = 0; i < nBins; i++) destSum += dest[i];
  if (destSum > 1e-6) {
    for (let i = 0; i < nBins; i++) dest[i] /= destSum;
  }
  return dest;
}

// ── Ground truth ──

const gt = JSON.parse(
  await readFile(join(PROJECT_ROOT, "test_fixtures", "ground_truth.json"), "utf8"),
);
const items = gt["screen.png"].items;

// Map filename -> quantity digits (after 'x')
function getDigits(row, col) {
  const item = items.find((it) => it.row === row && it.col === col);
  return item ? String(item.quantity).split("").map(Number) : null;
}

// ── Process all images ──

// Collect profiles per digit (0-9)
const digitProfiles = Array.from({ length: 10 }, () => ({
  col: [],
  row: [],
  rowUpper: [],
  rowLower: [],
}));

let totalDigits = 0;
let totalImages = 0;

for (let r = 0; r < 4; r++) {
  for (let c = 0; c < 5; c++) {
    const file = join(
      PROJECT_ROOT,
      "test_fixtures",
      "skew_number",
      `number_r${r}_c${c}.png`,
    );
    const { data, info } = await sharp(file)
      .removeAlpha()
      .raw()
      .toBuffer({ resolveWithObject: true });

    const w = info.width,
      h = info.height;
    const wmap = computeWeightMap(data, w, h);
    const colProf = columnProjection(wmap, w, h);
    const rawSegs = segmentCharacters(colProf);

    const digits = getDigits(r, c);
    if (!digits) continue;

    // Post-process segments:
    // 1. Filter noise (narrow + low peak)
    // 2. Identify and skip 'x' (first seg with low peak at left edge)
    const filtered = rawSegs.filter((seg) => {
      const peak = Math.max(...colProf.slice(seg.start, seg.end));
      const width = seg.end - seg.start;
      return !(peak < 3.0 && width < 5);
    });

    // Skip 'x': first segment with low peak at left edge
    let digitSegs;
    if (filtered.length > 0 && filtered[0].start < 8) {
      const firstPeak = Math.max(
        ...colProf.slice(filtered[0].start, filtered[0].end),
      );
      if (firstPeak < 4.0) {
        digitSegs = filtered.slice(1); // skip 'x'
      } else {
        digitSegs = filtered; // first seg is a digit, 'x' was below threshold
      }
    } else {
      digitSegs = filtered;
    }

    if (digitSegs.length !== digits.length) {
      console.error(
        `WARN r${r}_c${c}: expected ${digits.length} digits, got ${digitSegs.length} segments (raw=${JSON.stringify(rawSegs)}, filtered=${JSON.stringify(digitSegs)})`,
      );
      if (digitSegs.length < digits.length) continue;
    }

    for (let d = 0; d < digits.length && d < digitSegs.length; d++) {
      const seg = digitSegs[d];
      const digit = digits[d];

      // Column profile for this character
      const charColProf = colProf.slice(seg.start, seg.end);
      const normCol = normalizeProfile(charColProf, N_COL_BINS);

      // Row profile for this character
      const charRowProf = rowProjection(wmap, w, h, seg.start, seg.end);
      const normRow = normalizeProfile(charRowProf, N_ROW_BINS);

      // Upper and lower half row profiles
      const halfH = Math.floor(h / 2);
      const upperProf = charRowProf.slice(0, halfH);
      const lowerProf = charRowProf.slice(halfH);
      const normUpper = normalizeProfile(upperProf, N_ROW_HALF_BINS);
      const normLower = normalizeProfile(lowerProf, N_ROW_HALF_BINS);

      digitProfiles[digit].col.push(normCol);
      digitProfiles[digit].row.push(normRow);
      digitProfiles[digit].rowUpper.push(normUpper);
      digitProfiles[digit].rowLower.push(normLower);
      totalDigits++;
    }

    totalImages++;
  }
}

console.log(`Processed ${totalImages} images, ${totalDigits} total digit samples\n`);

// ── Average profiles per digit ──

function averageProfiles(profiles) {
  if (profiles.length === 0) return null;
  const n = profiles[0].length;
  const avg = new Float32Array(n);
  for (const p of profiles) {
    for (let i = 0; i < n; i++) avg[i] += p[i];
  }
  for (let i = 0; i < n; i++) avg[i] /= profiles.length;
  return avg;
}

// ── Output as Zig code ──

function fmtArray(arr) {
  return (
    ".{ " +
    Array.from(arr)
      .map((v) => v.toFixed(6))
      .join(", ") +
    " }"
  );
}

console.log(`pub const n_col_bins = ${N_COL_BINS};`);
console.log(`pub const n_row_bins = ${N_ROW_BINS};`);
console.log(`pub const n_row_half_bins = ${N_ROW_HALF_BINS};\n`);

const profileTypes = ["col", "row", "rowUpper", "rowLower"];
const binCounts = {
  col: N_COL_BINS,
  row: N_ROW_BINS,
  rowUpper: N_ROW_HALF_BINS,
  rowLower: N_ROW_HALF_BINS,
};
const zigNames = {
  col: "col_profiles",
  row: "row_profiles",
  rowUpper: "row_upper_profiles",
  rowLower: "row_lower_profiles",
};

for (const type of profileTypes) {
  const bins = binCounts[type];
  console.log(
    `pub const ${zigNames[type]}: [10][${bins}]f32 = .{`,
  );
  for (let d = 0; d < 10; d++) {
    const profiles = digitProfiles[d][type];
    const avg = averageProfiles(profiles);
    if (avg) {
      console.log(
        `    ${fmtArray(avg)}, // ${d} (${profiles.length} samples)`,
      );
    } else {
      console.log(
        `    .{ ${Array(bins).fill("0.0").join(", ")} }, // ${d} (no samples)`,
      );
    }
  }
  console.log(`};\n`);
}

// Print per-digit sample counts
console.log("// Sample counts per digit:");
for (let d = 0; d < 10; d++) {
  console.log(`//   ${d}: ${digitProfiles[d].col.length} samples`);
}
