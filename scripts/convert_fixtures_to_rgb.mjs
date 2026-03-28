#!/usr/bin/env node
/**
 * Convert test fixture PNGs to raw RGB binary files.
 *
 * Outputs .rgb files that can be embedded in Zig tests via @embedFile.
 * Each file is width * height * 3 bytes of raw RGB data (no header).
 *
 * Usage:
 *   node scripts/convert_fixtures_to_rgb.mjs
 */

import sharp from "sharp";
import { mkdir, readdir, writeFile } from "node:fs/promises";
import { join, dirname, basename } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = join(__dirname, "..");

async function convertDir(srcDir, outDir, label) {
  await mkdir(outDir, { recursive: true });
  const files = (await readdir(srcDir)).filter((f) => f.endsWith(".png"));

  for (const file of files) {
    const { data, info } = await sharp(join(srcDir, file))
      .removeAlpha()
      .raw()
      .toBuffer({ resolveWithObject: true });

    const outName = basename(file, ".png") + ".rgb";
    await writeFile(join(outDir, outName), data);
    console.log(`  ${outName}  (${info.width}x${info.height})`);
  }

  console.log(`${label}: ${files.length} files -> ${outDir}\n`);
  return files.length;
}

console.log("Converting skew_number PNGs to RGB...");
const n1 = await convertDir(
  join(PROJECT_ROOT, "test_fixtures", "skew_number"),
  join(PROJECT_ROOT, "test_fixtures", "skew_number_rgb"),
  "skew_number",
);

console.log("Converting cells_number PNGs to RGB...");
const n2 = await convertDir(
  join(PROJECT_ROOT, "test_fixtures", "cells_number"),
  join(PROJECT_ROOT, "test_fixtures", "cells_number_rgb"),
  "cells_number",
);

console.log("Converting cells_footer PNGs to RGB...");
const n3 = await convertDir(
  join(PROJECT_ROOT, "test_fixtures", "cells_footer"),
  join(PROJECT_ROOT, "test_fixtures", "cells_footer_rgb"),
  "cells_footer",
);

console.log(`Done. ${n1 + n2 + n3} files converted total.`);
