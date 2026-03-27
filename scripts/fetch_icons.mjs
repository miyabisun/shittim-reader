#!/usr/bin/env node
/**
 * Fetch item/equipment icon images from SchaleDB.
 *
 * Downloads master data JSON files, extracts icon references,
 * and downloads PNG icon images to assets/icons/{items,equipment}/.
 * Source images are WebP on SchaleDB; converted to PNG (with alpha) locally.
 * Idempotent: only downloads missing icons, removes stale ones.
 *
 * Usage:
 *   node scripts/fetch_icons.mjs
 *   node scripts/fetch_icons.mjs --items-only
 *   node scripts/fetch_icons.mjs --equipment-only
 *   node scripts/fetch_icons.mjs --dry-run
 */

import { writeFile, mkdir, readdir, unlink } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import sharp from "sharp";

const __dirname = dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = join(__dirname, "..");

const BASE_DATA_URL = "https://schaledb.com/data/jp";
const BASE_ICON_URL = "https://schaledb.com/images";
const USER_AGENT = "shittim-reader/0.1.0";
const REQUEST_INTERVAL_MS = 100;

const CATEGORIES = {
  items: {
    jsonUrl: `${BASE_DATA_URL}/items.json`,
    iconUrl: `${BASE_ICON_URL}/item/icon`,
    outputDir: "assets/icons/items",
  },
  equipment: {
    jsonUrl: `${BASE_DATA_URL}/equipment.json`,
    iconUrl: `${BASE_ICON_URL}/equipment/icon`,
    outputDir: "assets/icons/equipment",
  },
};

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const FETCH_OPTIONS = { headers: { "User-Agent": USER_AGENT } };

async function fetchJson(url) {
  const resp = await fetch(url, FETCH_OPTIONS);
  if (!resp.ok) {
    const body = await resp.text().catch(() => "");
    throw new Error(`${url}: ${resp.status} ${resp.statusText}\n${body}`);
  }
  return resp.json();
}

async function downloadAndConvert(url, dest) {
  const resp = await fetch(url, FETCH_OPTIONS);
  if (!resp.ok) {
    console.error(`  SKIP ${url} (${resp.status})`);
    return false;
  }
  try {
    const webpBuf = Buffer.from(await resp.arrayBuffer());
    await sharp(webpBuf).png().toFile(dest);
    return true;
  } catch (err) {
    console.error(`  CONVERT FAILED ${url}: ${err.message}`);
    return false;
  }
}

async function processCategory(name, config, dryRun) {
  console.log(`\n=== ${name} ===`);

  // Fetch master data
  console.log(`Fetching ${config.jsonUrl} ...`);
  const data = await fetchJson(config.jsonUrl);

  // Save JSON for reference
  const jsonPath = join(PROJECT_ROOT, "assets", "data", `${name}.json`);
  await writeFile(jsonPath, JSON.stringify(data, null, 2), "utf-8");
  console.log(`Saved ${jsonPath} (${Object.keys(data).length} entries)`);

  // Extract unique icon names
  const icons = [
    ...new Set(
      Object.values(data)
        .map((entry) => entry.Icon)
        .filter(Boolean)
    ),
  ];
  console.log(`Found ${icons.length} unique icons`);

  if (dryRun) {
    for (const icon of icons) {
      console.log(`  [DRY RUN] ${icon}.png`);
    }
    return;
  }

  // Diff against local files
  const outputDir = join(PROJECT_ROOT, config.outputDir);
  await mkdir(outputDir, { recursive: true });

  const expectedFiles = new Set(icons.map((icon) => `${icon}.png`));
  const localFiles = new Set(await readdir(outputDir));

  const toDownload = icons.filter((icon) => !localFiles.has(`${icon}.png`));
  const toRemove = [];
  for (const f of localFiles) {
    if (f.endsWith(".webp")) toRemove.push(f);
    else if (f.endsWith(".png") && !expectedFiles.has(f)) toRemove.push(f);
  }

  // Download missing icons (WebP -> PNG conversion)
  let downloaded = 0;
  let failed = 0;

  for (const [i, icon] of toDownload.entries()) {
    if (i > 0) await sleep(REQUEST_INTERVAL_MS);
    const webpUrl = `${config.iconUrl}/${icon}.webp`;
    const pngDest = join(outputDir, `${icon}.png`);
    if (await downloadAndConvert(webpUrl, pngDest)) {
      downloaded++;
    } else {
      failed++;
    }
  }

  // Remove stale icons (parallel, no rate limiting needed)
  await Promise.all(
    toRemove.map(async (file) => {
      await unlink(join(outputDir, file));
      console.log(`  Removed stale: ${file}`);
    })
  );

  const unchanged = icons.length - toDownload.length;
  console.log(
    `Done: ${downloaded} new, ${unchanged} unchanged, ${failed} failed, ${toRemove.length} removed`
  );
}

async function main() {
  const { values } = parseArgs({
    options: {
      "items-only": { type: "boolean", default: false },
      "equipment-only": { type: "boolean", default: false },
      "dry-run": { type: "boolean", default: false },
    },
  });

  const targets = values["items-only"]
    ? ["items"]
    : values["equipment-only"]
      ? ["equipment"]
      : Object.keys(CATEGORIES);

  await mkdir(join(PROJECT_ROOT, "assets", "data"), { recursive: true });

  for (const name of targets) {
    await processCategory(name, CATEGORIES[name], values["dry-run"]);
  }

  console.log("\nAll done.");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
