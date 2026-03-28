#!/usr/bin/env node
/**
 * Apply horizontal shear (deskew) to all number region images.
 *
 * Reads all files from test_fixtures/cells_number/ and writes
 * deskewed versions to test_fixtures/skew_number/ with the same filename.
 *
 * Usage:
 *   node scripts/skew_test.mjs
 */

import sharp from "sharp";
import { mkdir, readdir } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = join(__dirname, "..");

const SRC_DIR = join(PROJECT_ROOT, "test_fixtures", "cells_number");
const OUT_DIR = join(PROJECT_ROOT, "test_fixtures", "skew_number");
const SKEW_FACTOR = 0.25;

await mkdir(OUT_DIR, { recursive: true });

const files = (await readdir(SRC_DIR)).filter((f) => f.endsWith(".png"));

for (const file of files) {
  await sharp(join(SRC_DIR, file))
    .affine([[1, SKEW_FACTOR], [0, 1]], {
      background: { r: 0, g: 0, b: 0, alpha: 0 },
    })
    .png()
    .toFile(join(OUT_DIR, file));

  console.log(`  ${file}`);
}

console.log(`\nDone. ${files.length} files written to test_fixtures/skew_number/`);
