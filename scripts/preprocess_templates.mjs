// Pre-process icon templates and master data for Zig @embedFile.
//
// Inputs:
//   assets/icons/{items,equipment}/*.png — icon images
//   assets/data/{items,equipment}.json  — SchaleDB master data
//
// Outputs:
//   assets/build/templates.bin — packed binary: [gray(80*80) + mask(80*80)] per template
//   assets/build/catalog.yml  — item catalog with shape_group, merge_group, etc.

import sharp from "sharp";
import { readFile, mkdir, writeFile } from "fs/promises";
import { join } from "path";
import { existsSync } from "fs";
import { parseArgs } from "node:util";

const { values: args } = parseArgs({
  options: {
    "icons-dir": { type: "string", default: "assets/icons" },
    "data-dir": { type: "string", default: "assets/data" },
    "output-dir": { type: "string", default: "assets/build" },
  },
});

const ICONS_DIR = args["icons-dir"];
const DATA_DIR = args["data-dir"];
const OUTPUT_DIR = args["output-dir"];
const TEMPLATE_SIZE = 80;

// ── Load master data ──

const itemsRaw = JSON.parse(await readFile(join(DATA_DIR, "items.json"), "utf8"));
const equipRaw = JSON.parse(await readFile(join(DATA_DIR, "equipment.json"), "utf8"));

// ── Build catalog entries ──

function computeShapeGroup(icon, subCategory) {
  // Artifacts: each tier is visually distinct, no grouping
  if (subCategory === "Artifact") return icon;
  // Strip _0/_1/_2/_3 suffix for tier grouping
  const match = icon.match(/^(.+)_([0-3])$/);
  if (match) return match[1];
  return icon;
}

const catalog = [];

// Items
for (const item of Object.values(itemsRaw)) {
  catalog.push({
    id: item.Id,
    icon: item.Icon,
    category: item.Category,
    sub_category: item.SubCategory || null,
    rarity: item.Rarity,
    shape_group: computeShapeGroup(item.Icon, item.SubCategory),
    name: item.Name,
    _source: "items",
  });
}

// Equipment
for (const equip of Object.values(equipRaw)) {
  catalog.push({
    id: equip.Id,
    icon: equip.Icon,
    category: equip.Category,
    sub_category: null,
    rarity: equip.Rarity,
    shape_group: computeShapeGroup(equip.Icon, null),
    name: equip.Name,
    _source: "equipment",
  });
}

// Sort by id ascending
catalog.sort((a, b) => a.id - b.id);

// ── Detect merge groups ──

const iconToIds = new Map();
for (const entry of catalog) {
  if (!iconToIds.has(entry.icon)) iconToIds.set(entry.icon, []);
  iconToIds.get(entry.icon).push(entry.id);
}

for (const entry of catalog) {
  const ids = iconToIds.get(entry.icon);
  if (ids.length > 1) {
    entry.merge_group = entry.icon;
  }
}

// ── Process icon images ──

await mkdir(OUTPUT_DIR, { recursive: true });

// Track unique icons (avoid processing duplicates)
const processedIcons = new Set();
const templateBuffers = []; // ordered by catalog position
const iconToTemplate = new Map(); // icon name → { gray, mask } buffers

let skipped = 0;
let processed = 0;

for (const entry of catalog) {
  if (processedIcons.has(entry.icon)) continue;
  processedIcons.add(entry.icon);

  // Find icon file
  const subdir = entry._source === "equipment" ? "equipment" : "items";
  const iconPath = join(ICONS_DIR, subdir, `${entry.icon}.png`);

  if (!existsSync(iconPath)) {
    console.warn(`WARN: icon not found: ${iconPath}`);
    skipped++;
    continue;
  }

  try {
    // Decode → resize 80×80 → raw RGBA
    const { data } = await sharp(iconPath)
      .resize(TEMPLATE_SIZE, TEMPLATE_SIZE, { fit: "fill" })
      .ensureAlpha()
      .raw()
      .toBuffer({ resolveWithObject: true });

    const pixelCount = TEMPLATE_SIZE * TEMPLATE_SIZE;
    const gray = Buffer.alloc(pixelCount);
    const mask = Buffer.alloc(pixelCount);

    for (let i = 0; i < pixelCount; i++) {
      // Convert to grayscale: standard luminance weights
      const r = data[i * 4];
      const g = data[i * 4 + 1];
      const b = data[i * 4 + 2];
      gray[i] = Math.round(0.299 * r + 0.587 * g + 0.114 * b);
      mask[i] = data[i * 4 + 3]; // alpha
    }

    iconToTemplate.set(entry.icon, { gray, mask });
    processed++;
  } catch (err) {
    console.warn(`WARN: failed to process ${iconPath}: ${err.message}`);
    skipped++;
  }
}

// ── Write templates.bin ──

// Build ordered list matching catalog (skip entries without templates)
const catalogWithTemplates = catalog.filter((e) =>
  iconToTemplate.has(e.icon)
);

// Deduplicate: only include each icon once in the binary
const uniqueIcons = [];
const seenIcons = new Set();
for (const entry of catalogWithTemplates) {
  if (!seenIcons.has(entry.icon)) {
    seenIcons.add(entry.icon);
    uniqueIcons.push(entry.icon);
  }
}

const BYTES_PER_TEMPLATE = TEMPLATE_SIZE * TEMPLATE_SIZE * 2; // gray + mask
const headerSize = 4; // uint32 LE: template count
const binSize = headerSize + uniqueIcons.length * BYTES_PER_TEMPLATE;
const bin = Buffer.alloc(binSize);

bin.writeUInt32LE(uniqueIcons.length, 0);

for (let i = 0; i < uniqueIcons.length; i++) {
  const tmpl = iconToTemplate.get(uniqueIcons[i]);
  const offset = headerSize + i * BYTES_PER_TEMPLATE;
  tmpl.gray.copy(bin, offset);
  tmpl.mask.copy(bin, offset + TEMPLATE_SIZE * TEMPLATE_SIZE);
}

await writeFile(join(OUTPUT_DIR, "templates.bin"), bin);
console.log(
  `templates.bin: ${uniqueIcons.length} templates, ${bin.length} bytes`
);

// ── Write catalog.yml ──

let yml = "";
for (const entry of catalog) {
  // Skip entries without templates
  if (!iconToTemplate.has(entry.icon)) continue;

  yml += `- id: ${entry.id}\n`;
  yml += `  icon: ${entry.icon}\n`;
  yml += `  category: ${entry.category}\n`;
  yml += `  sub_category: ${entry.sub_category || "null"}\n`;
  yml += `  rarity: ${entry.rarity}\n`;
  yml += `  shape_group: ${entry.shape_group}\n`;
  if (entry.merge_group) {
    yml += `  merge_group: ${entry.merge_group}\n`;
  }
  yml += `  name: ${entry.name}\n`;
}

await writeFile(join(OUTPUT_DIR, "catalog.yml"), yml, "utf8");
console.log(
  `catalog.yml: ${catalogWithTemplates.length} entries`
);

console.log(`\nSummary: ${processed} icons processed, ${skipped} skipped`);
