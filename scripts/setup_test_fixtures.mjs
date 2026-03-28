#!/usr/bin/env node
/**
 * Copy test fixture images from bluearchive-aoi output directory.
 *
 * Copies screen.png, cells/, and underscore-named files from
 * cells_number/ and cells_footer/ into test_fixtures/.
 * Idempotent: overwrites existing files without error.
 *
 * Usage:
 *   node scripts/setup_test_fixtures.mjs
 *   node scripts/setup_test_fixtures.mjs --source ../bluearchive-aoi/output
 */

import { copyFile, mkdir, readdir } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";

const __dirname = dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = join(__dirname, "..");

const { values } = parseArgs({
  options: {
    source: {
      type: "string",
      default: join(PROJECT_ROOT, "..", "bluearchive-aoi", "output"),
    },
  },
});

const SOURCE = values.source;
const DEST = join(PROJECT_ROOT, "test_fixtures");

/** Copy a single file, creating parent dirs as needed. */
async function cp(src, dest) {
  await mkdir(dirname(dest), { recursive: true });
  await copyFile(src, dest);
}

/** Copy files matching a pattern from a source subdir. Only underscore-named files (e.g. _c0). */
async function copyUnderscoreFiles(subdir) {
  const srcDir = join(SOURCE, subdir);
  const destDir = join(DEST, subdir);
  const files = await readdir(srcDir);
  const underscored = files.filter((f) => /_c\d+\.png$/.test(f));
  for (const file of underscored) {
    await cp(join(srcDir, file), join(destDir, file));
  }
  console.log(`  ${subdir}: ${underscored.length} files`);
}

async function main() {
  console.log(`Source: ${SOURCE}`);
  console.log(`Dest:   ${DEST}`);

  // screen.png
  await cp(join(SOURCE, "screen.png"), join(DEST, "screen.png"));
  console.log("  screen.png: copied");

  // cells/ (all files)
  const cellsDir = join(SOURCE, "cells");
  const cellFiles = await readdir(cellsDir);
  await mkdir(join(DEST, "cells"), { recursive: true });
  for (const file of cellFiles) {
    await copyFile(join(cellsDir, file), join(DEST, "cells", file));
  }
  console.log(`  cells: ${cellFiles.length} files`);

  // cells_number/ and cells_footer/ (underscore-named only)
  await copyUnderscoreFiles("cells_number");
  await copyUnderscoreFiles("cells_footer");

  console.log("\nDone.");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
