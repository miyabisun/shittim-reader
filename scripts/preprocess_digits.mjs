// Convert digit template PNGs to separate grayscale and mask files for Zig @embedFile.
// Input:  assets/templates/digits/{0-9,x}.png (RGBA)
// Output: src/digits/{0-9,x}.gray  (green channel only, w*h bytes)
//         src/digits/{0-9,x}.mask  (alpha channel only, w*h bytes)
//         src/digits/meta.txt      (dimensions per template)

import sharp from "sharp";
import { mkdir, writeFile } from "fs/promises";
import { join } from "path";

const DIGITS = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "x"];
const SRC = "assets/templates/digits";
const DST = "src/digits";

await mkdir(DST, { recursive: true });

const meta = [];

for (const d of DIGITS) {
  const { data, info } = await sharp(join(SRC, `${d}.png`))
    .ensureAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });

  const pixelCount = info.width * info.height;
  const gray = Buffer.alloc(pixelCount);
  const mask = Buffer.alloc(pixelCount);

  for (let i = 0; i < pixelCount; i++) {
    gray[i] = data[i * 4 + 1]; // green channel
    mask[i] = data[i * 4 + 3]; // alpha channel
  }

  await writeFile(join(DST, `${d}.gray`), gray);
  await writeFile(join(DST, `${d}.mask`), mask);

  meta.push({ name: d, width: info.width, height: info.height });
  console.log(
    `${d}: ${info.width}×${info.height} → ${gray.length}B gray + ${mask.length}B mask`
  );
}

console.log("\nDimensions for Zig constants:");
for (const m of meta) {
  console.log(`  ${m.name}: ${m.width}×${m.height}`);
}
console.log("Done.");
