# Scope Discussion

## The Challenge

Blue Archive has many distinct screen states. The game window can show:

### Known Screen Types (non-exhaustive)

| Category       | Examples                                        |
|----------------|-------------------------------------------------|
| **Lobby**      | Home screen, main menu                          |
| **Inventory**  | Item list, equipment list, student list         |
| **Combat**     | Battle UI, skill selection, auto-battle overlay  |
| **Story**      | Dialogue scenes, cutscenes                      |
| **Gacha**      | Recruitment screen, results                     |
| **Shop**       | General shop, event shop, crafting               |
| **Mission**    | Stage select, campaign map                      |
| **Other**      | Loading screens, settings, notifications        |

Because shittim-reader intercepts a live game window, it must handle
**any** of these states gracefully.

## Scope Strategy: Start Narrow, Grow Incrementally

Rather than designing for all screen types upfront, we should define:

1. **Phase 0: Foundation** -- What every screen analysis needs
2. **Phase 1: First target** -- The single most valuable screen type
3. **Phase N: Extensions** -- Additional screen types added over time

---

## Phase 0: Foundation (must-have for any screen type)

These capabilities are prerequisites regardless of which screen we analyze:

- **Image input** -- Accept raw pixel buffer (RGB or RGBA) with dimensions
- **Resize/normalize** -- Scale arbitrary window size to canonical resolution
  with consistent quality (current pain point in bluearchive-aoi)
- **Screen state classifier** -- Determine which screen type is currently shown
  (even if only to say "unknown / not supported yet")

### Design Decisions (Phase 0)

#### D1: Canonical Resolution -- **1600px width, 16:9 aspect ratio (1600x900)**

Inherited from bluearchive-aoi (`BASE_WIDTH: u32 = 1600` in `items.rs`).
This resolution was chosen because SchaleDB icon templates match cleanly at this scale.

- Input images are scaled to 1600px width, preserving aspect ratio
- 16:9 (1.78:1) is the primary supported aspect ratio
- 4:3 detection exists in bluearchive-aoi but is not yet supported
- Grid ROI is detected dynamically via scanline sampling (not percentage-based)
- Template matching requires a fixed pixel scale (1600px width)

#### D2: Resize Algorithm -- **Area averaging (box filter)**

bluearchive-aoi currently uses `FilterType::Triangle` (similar to bilinear) for both
full-screen downscale and cell icon resize. This causes inconsistent results because
bilinear interpolation samples specific points, and the sampling positions shift
depending on source resolution -- leading to different pixel patterns for the same
content at different window sizes.

**Decision: Area averaging for all downscale operations.**

Area averaging computes each output pixel as the weighted mean of ALL input pixels
that overlap the output pixel's area. This makes it resolution-independent:
the same downscale ratio always produces the same result regardless of source size.
This is critical for OCR digit matching, where consistent pixel collapse patterns
directly affect template matching accuracy.

| Use case              | Algorithm       | Rationale                                |
|-----------------------|-----------------|------------------------------------------|
| Screen downscale      | Area averaging  | Consistent quality at any source size    |
| Cell icon resize      | Area averaging  | Same pixels → same template match scores |
| Alpha mask resize     | Nearest neighbor| Preserve binary edge information         |

**Why not Lanczos?** Lanczos produces sharper results but introduces ringing
artifacts (bright/dark halos at edges). For small template images (80x80) and
tiny digit glyphs (15x21), these halos corrupt the NCC correlation and reduce
matching accuracy.

#### D3: Screen Classifier -- **Key-region sampling approach**

Rather than analyzing the full image, sample specific screen regions (crops)
and check for known UI signatures:

```
+--------------------------------------------------+
|  [A]              [B]                        [C]  |
|                                                   |
|        +----------------------------------+       |
|  [D]   |                                  | [E]   |
|        |        Main content area         |       |
|        |                                  |       |
|        +----------------------------------+       |
|  [F]              [G]                        [H]  |
+--------------------------------------------------+

Sample regions [A]-[H] at known positions.
Each screen type has a unique combination of:
- Background color at specific regions
- Presence/absence of UI elements (buttons, headers, tabs)
- Color distribution patterns
```

This approach is fast (only reading small crops, not the full image) and
extensible (adding a new screen type = defining its signature regions).

---

## Phase 1: Item Inventory Screen

The item inventory screen is the first target. It has the highest value
(resource planning is the app's core purpose) and existing work to reference.

### Pipeline (redesigned for shittim-reader)

```
Input: Raw pixel buffer (RGB or RGBA, arbitrary resolution)
  |
  v
[1] Downscale to 1600px width (16:9 -> 1600x900)
  |
  v
[2] Detect grid ROI + cell boundaries (grid.detectGrid)
     ROI: dynamically detected via scanline sampling for #C4CFD4
     (no fixed percentage coordinates -- adapts to any aspect ratio)
     Separator color: #C4CFD4 (tolerance ±15)
     Min cell size: 50px (noise filter)
  |
  v
[3] Identify anchor item (top-left cell) -- CRITICAL STEP
     |
     +-- [3a] Grayscale NCC against ALL templates
     |         -> Produces ranked shape-group candidates
     |         -> e.g. "技術ノート系" (score 0.95), "レポート系" (0.60), ...
     |
     +-- [3b] Color analysis on top candidates
     |         -> Extract dominant hue from icon region (in HSV/Lab space)
     |         -> Disambiguate rarity: gray=T1, blue=T2, gold=T3, purple=T4
     |         -> Result: exact item ID + internal sort order position
     |
     Anchor item established -> internal ID known
  |
  v
[4] Process remaining cells (left-to-right, top-to-bottom)
     Items are sorted by internal ID (ascending).
     Knowing the anchor ID, each subsequent cell can only be:
       - The same item (duplicate row from scrolling)
       - An item with a HIGHER internal ID
     |
     +-- [4a] Narrow template candidates using sort order
     |         Anchor ID = N -> next cell candidates = { ID >= N }
     |         After each match, further narrow: { ID >= matched_ID }
     |         Typically reduces search from ~1000 to ~5-15 templates
     |
     +-- [4b] Grayscale NCC on narrowed set
     |         Much faster due to small candidate pool
     |
     +-- [4c] Color disambiguation (only if shape-group has variants)
     |         Skip this step for items with unique shapes
     |
     +-- [4d] Quantity OCR on bottom 25% of cell (footer region)
     |         -> Horizontal deskew (shear factor 0.25) on footer
     |         -> Blue-gradient color segmentation (weight map)
     |         -> "x" character detection via weight map projection
     |         -> Digit segmentation via column projection valleys
     |         -> Digit recognition via projection profile matching
     |         -> Result: quantity number
     |
     Update cursor: matched_ID = this cell's ID
  |
  v
Output: Array of { item_id, quantity } pairs
```

### Matching Strategy: Shape-First, Color-Second

bluearchive-aoi's current approach discards color entirely (grayscale NCC only),
making it impossible to distinguish same-shape items with different rarities.

shittim-reader uses a two-stage approach:

**Stage 1: Shape matching (grayscale NCC)**
- Fast, proven technique inherited from bluearchive-aoi
- Groups items by visual shape (e.g., all "技術ノート" variants score equally)
- Sufficient for items with unique shapes (no color step needed)

**Stage 2: Color disambiguation (only when needed)**
- Applied only when Stage 1 returns multiple candidates from the same shape group
- Analyzes the icon's dominant color in a perceptually uniform color space

```
Known rarity color mapping (approximate):
  T1 (初級/Normal):  gray/silver   -- low saturation, medium lightness
  T2 (中級/Rare):    blue          -- hue ~210-240°
  T3 (上級/SR):      gold/yellow   -- hue ~40-60°
  T4 (最上級/SSR):   purple        -- hue ~270-300°
```

Items sharing the same shape template should be pre-grouped at compile time
so that the color step knows which candidates need disambiguation.

### Sort-Order Optimization

Items in the inventory are ordered by internal ID (ascending).
This is the single most powerful optimization available:

```
Example: Screen shows 20 cells (5 columns x 4 rows)

Cell[0,0] = anchor     -> full match (all templates) -> ID = 1042
Cell[0,1] = next       -> candidates: ID >= 1042     -> ~15 templates
Cell[0,2] = next       -> candidates: ID >= 1050     -> ~12 templates
...
Cell[3,4] = last       -> candidates: ID >= 1180     -> ~3 templates

Average candidates per cell: ~10 (vs ~1000 without optimization)
Speedup: ~100x
```

### Merge Groups and Cell Map Inference

#### The Problem

Some items share an identical `Icon` but have different internal IDs.
These are visually indistinguishable via template matching.

```
Example: 初級技術ノート選択ボックス (skillbook_selection_0)
  ID 150000 — 全学園用
  ID 150012 — Aグループ用
  ID 150016 — Bグループ用
  → Same icon, same shape, same rarity color. NCC cannot differentiate.
```

This pattern exists for:
- 技術ノート選択ボックス: 4 rarities × 3 sets = 12 items
- 戦術教育BD選択ボックス: 4 rarities × 3 sets = 12 items
- (Plus event items, which are filtered out of the inventory)

#### Merge Group Definition

A **merge group** is a set of items sharing the same `Icon` string.
Detected automatically from master data during catalog generation.

- Items within a merge group are summed into a single output entry
- The merge key is the `Icon` value (not the `Id`)
- Items with unique Icons (1 ID per Icon) need no merging

#### Cell Map Inference (Row Skip Optimization)

Items are displayed in internal ID ascending order, with unowned items
hidden (gaps in the sequence). When processing a row:

1. **Identify the first cell** via full template matching (grayscale NCC)
2. **Check if subsequent cells belong to the same merge group:**
   - Same merge group → skip template matching, OCR quantity only
   - Different icon → template match as normal (but candidate set is
     narrowed by sort order)
3. **Sum quantities** across all cells in the merge group

```
Example: Row contains 3 技術ノート選択ボックス (初級) at IDs 150000, 150012, 150016

Cell[r,0]: template match → skillbook_selection_0 (merge group detected)
Cell[r,1]: same icon → skip match, OCR → quantity = 5
Cell[r,2]: same icon → skip match, OCR → quantity = 12
Cell[r,3]: different icon → template match → next item
Cell[r,4]: ...

Output: skillbook_selection_0: quantity = (cell0 qty) + 5 + 12
```

This optimization is especially effective for selection boxes, which
appear as 3 consecutive cells with identical icons. For most other items,
the sort-order optimization already limits candidates to <15 templates,
so the additional speedup is smaller but still beneficial.

#### Correctness Note

Cell map inference is **not** a guarantee -- unowned items create gaps.
The system must fall back to template matching if the expected merge group
member is not found at the next cell position. The inference is a fast path,
not a hard assumption.

### Continuous Scroll Capture (Streaming Mode)

**Requirement**: The user scrolls through the item list with the mouse wheel
while shittim-reader continuously captures and reads items in real-time.
The user should not need to stop scrolling or take manual actions.

This means the library must handle:

#### Session-based accumulation

```
Frame 1 (t=0ms):    [A][B][C][D][E]    -> read all, store {A,B,C,D,E}
                     [F][G][H][I][J]
                     [K][L][M][N][O]
                     [P][Q][R][S][T]

  (user scrolls down 2 rows)

Frame 2 (t=200ms):  [K][L][M][N][O]    -> K-T already known, skip
                     [P][Q][R][S][T]    -> U-AD are new, read & append
                     [U][V][W][X][Y]
                     [Z][AA][AB][AC][AD]

  (user scrolls down 1 row)

Frame 3 (t=400ms):  [U][V][W][X][Y]    -> U-AD already known, skip
                     [Z][AA][AB][AC][AD]-> AE-AI are new, read & append
                     [AE][AF][AG][AH][AI]
                     (end of list)

Session result: {A, B, C, ... AI} with quantities -- complete inventory
```

#### Key design considerations

1. **Frame dedup (identical frame skip)** -- The session retains the previous
   frame's pixel data. Before any processing, compare against the previous frame.
   If identical, skip entirely (return 0 new items).

   ```
   Comparison strategy: sample lines from the RAW input image
   (before any resize/downscale -- avoid paying the resize cost just to compare).

   Sample 10 lines total from the 20%-80% range of the image:
   - 5 horizontal scanlines at Y = 20%, 35%, 50%, 65%, 80% of height
   - 5 vertical scanlines   at X = 20%, 35%, 50%, 65%, 80% of width

   Edges (0-20%, 80-100%) are excluded because they often contain
   static UI chrome (title bars, taskbar) that never changes and
   would give false "identical" results.

   +--------------------------------------------------+
   |                                                    |
   |    ----h1----====----====----====----====----       | 20%
   |    |         |         |         |         |       |
   |    ----h2----====----====----====----====----       | 35%
   |    |         |         |         |         |       |
   |    ----h3----====----====----====----====----       | 50%
   |    |         |         |         |         |       |
   |    ----h4----====----====----====----====----       | 65%
   |    |         |         |         |         |       |
   |    ----h5----====----====----====----====----       | 80%
   |    v1        v2        v3        v4        v5      |
   +--------------------------------------------------+
        20%       35%       50%       65%       80%

   - Any line differs -> frame changed -> proceed to pipeline
   - All lines match  -> identical frame -> skip (return 0)

   Memory: 5 horizontal lines (width * channels bytes each)
         + 5 vertical lines (height * channels bytes each)
         @ 1920x1080 RGBA: 5*1920*4 + 5*1080*4 = ~59 KB
   ```

   The session stores only these 10 sampled lines from the previous frame.
   The dedup check runs BEFORE the expensive resize step.

   ```
   session_feed(frame):
     [0] Extract 10 sample lines (5h + 5v) from raw input
     [1] memcmp against stored previous lines -> skip if identical
     [2] Downscale to 1600px                  -> only if frame changed
     [3] Grid detection, cell split
     [4] Template matching (grayscale NCC) + color analysis (RGB)
     [5] Overwrite stored sample lines with this frame's
   ```

2. **Overlap detection** -- Each frame shares some items with the previous frame.
   Use the ID ordering: if frame N's last known ID is X, any cell in frame N+1
   with ID <= X is a duplicate. Only process cells after the overlap boundary.

3. **Scroll motion tolerance** -- During fast scrolling, a frame may capture
   a mid-scroll state where rows are partially visible or blurred.
   Strategy: detect partial rows (cells cut off at top/bottom edge) and skip them.

4. **Frame rate vs. processing speed** -- The library must process faster than
   the capture rate. If capture is ~30fps (~33ms/frame) but the full pipeline
   takes longer, the library should:
   - Process the latest available frame (drop stale frames)
   - Only perform full matching on NEW cells (overlap detection first)

5. **Deduplication strategy** -- Items are identified by their internal ID.
   Once an item is seen in a session, subsequent sightings update the quantity
   only if the new reading has higher confidence (match_score).

6. **Session lifecycle**:
   - Session starts when the user opens the item inventory screen
   - Session accumulates items across multiple frames
   - Session retains previous frame data for dedup comparison
   - Session ends when the user navigates away or explicitly ends it
   - The accumulated result contains the complete item list

### Key Constants

| Constant          | Value      | Source file        |
|-------------------|------------|--------------------|
| BASE_WIDTH        | 1600       | image.zig:canonical_width |
| TEMPLATE_SIZE     | 80x80      | grid.zig:template_size    |
| Match threshold   | 0.5        | (TBD: ncc.zig)           |
| Separator color   | #C4CFD4    | grid.zig            |
| Grid ROI          | dynamic    | grid.zig:findGridRegion (scanline detection, no fixed %) |
| Qty region start  | 75% of cell| grid.zig:qty_region_start |
| Qty trim bottom   | 6px        | grid.zig:qty_trim_bottom  |
| Qty trim right    | 8px        | grid.zig:qty_trim_right   |

### Shape-Group Definition

Items with tier variants (`_0`/`_1`/`_2`/`_3` suffix) share the same icon shape
but differ by color (rarity). These must be pre-grouped at compile time so that
the matching pipeline knows when to apply color disambiguation.

**Grouping rules (applied during build-time metadata generation):**

```
For each item in items.json:

1. If SubCategory == "Artifact" (オーパーツ):
   → Do NOT group. Each tier has a completely different image
     (broken → restored progression). Treat all 4 tiers as independent templates.
   → 20 artifact families × 4 tiers = 80 independent templates.

2. If Category == "Favor" (贈り物):
   → Only upper/supreme tiers exist (SR/SSR). Shapes are distinct enough
     that grayscale NCC alone can distinguish them. Grouping is unnecessary
     in practice, but apply the standard rule if _0/_1/_2/_3 variants exist.

3. Otherwise, if Icon name has _0/_1/_2/_3 tier variants:
   → Group by base name (Icon without trailing _N suffix).
   → Use _0 (T1/Normal) as the shape representative template for grayscale NCC.
   → After shape match, apply color disambiguation (gray/blue/gold/purple).
   → This applies to: skill books, EX skill CDs, selection boxes, EXP items, etc.

4. If Icon name has no tier variants:
   → Single template, no grouping needed.
```

**Selection boxes (選択ボックス)** are a notable case: items like
`item_icon_material_selection_0` through `_3` are color-coded boxes that
follow the standard grouping rule (same shape, different rarity colors).

### OCR Quantity Recognition

~~Digit templates for quantity recognition are sourced from
`../bluearchive-aoi/output/num/` and stored in `assets/templates/digits/`.~~

**Decision: Template-free, color-segmentation + projection-profile approach.**

The template NCC approach was abandoned because bluearchive-aoi's digit
templates are rendered in a different style (upright, green channel) from
the actual game text (italic, blue-white gradient with anti-aliasing).
Even with deskew correction, the rendering mismatch limits accuracy.

#### Game Font Characteristics

The quantity text ("x924", "x1892", etc.) uses a fixed color scheme:

| Element | Color | Description |
|---------|-------|-------------|
| Core text | `#2D4663` (R:45 G:70 B:99) | Dark desaturated blue |
| Anti-alias / outline | gradient to `#F5FAFD` / `#FCFDFD` | Near-white |
| Background | varies (icon image) | Yellow, red, etc. — different hue |

All items in the inventory always display `x{number}`, even for quantity 1.

#### OCR Pipeline (applied per cell)

```
Cell (116×117 RGB at 1600×900)
  |
  v
[1] Extract footer region (bottom 25%, trim bottom 6px / right 8px)
    → 108×24 RGB
  |
  v
[2] Horizontal deskew (shear factor 0.25, bilinear interpolation)
    → 114×24 RGB (stack buffer, ~8 KB, <0.03ms per cell)
    Corrects italic lean. The "x" character becomes
    a near-upright diagonal cross after deskew.
  |
  v
[3] Blue-gradient weight map
    For each pixel, compute "text membership" score (0.0 – 1.0):
    - Core color #2D4663 → score 1.0
    - Anti-aliased pixels (blend toward white) → proportional score
    - Background pixels (different hue: yellow, red, etc.) → score 0.0
    This separates text from icon background regardless of icon content.
  |
  v
[4] Column projection profile (sum weights per column)
    Produces a 1D array of length = image width.
    Valleys (near-zero regions) indicate character boundaries.
  |
  v
[5] Character segmentation
    Split at projection valleys to isolate individual characters.
    Special cases:
    - "x" is the first character (diagonal cross shape)
    - Connected characters like "33" may have shallow valleys
      (pixels #CDD0D4, #D5D8DB indicate separation despite not
      being fully white)
    - Left edge may contain "x" remnant noise
  |
  v
[6] Digit recognition via projection profile matching
    For each segmented digit:
    - Compute column + row projection profiles
    - Compare against reference profiles for 0-9
    - Use upper/lower half split profiles for disambiguation
      (e.g., 3 vs 8, 6 vs 9)
    No external templates needed — profiles are computed from
    the digit's own geometry in the weight map.
  |
  v
Output: quantity (u32)
```

#### Noise Handling

| Noise source | Mitigation |
|---|---|
| Icon background in digit holes (8, 9, 3) | Blue-hue filter excludes non-blue pixels |
| Connected characters (33, 00) | Shallow valley detection in column projection |
| "x" remnant at left edge | x detected first; only content after x is digit-parsed |
| Anti-aliased edges | Gradient weight map captures partial coverage |

#### Performance Impact

Deskew on footer (108×24 → 114×24) vs. number region (49×24 → 55×24):
- Additional memory: +4 KB stack (8 KB total, negligible)
- Additional time: +0.03ms per cell, +0.6ms per frame (20 cells)
- Total OCR overhead per frame: <1ms (well within 33ms budget)

### Known Issues to Address

1. ~~**OCR accuracy** -- Digit recognition via template matching struggles
   with anti-aliased text and varying font rendering.~~
   Resolved: replaced with blue-gradient color segmentation +
   projection profile matching. Template matching abandoned due to
   rendering style mismatch between bluearchive-aoi templates and
   actual game font.

2. ~~**Template embedding strategy**~~ Resolved: pre-process to raw binary
   at build time (see Template Build Pipeline). Comptime PNG decode rejected
   due to compile time concerns with ~1000 icons and the 30fps runtime target.

---

## Design Decision: Template Embedding

**Decision: Pre-processed raw binary, embedded at compile time**

Templates (SchaleDB icon images) are pre-processed into raw binary format,
then embedded in the DLL via Zig's `@embedFile`.
No external template registration API is needed.

### Rationale

1. **30fps runtime target** -- At ~33ms per frame, zero runtime decode overhead
   is essential. Pre-processed raw bytes are ready to use as-is.

2. **Test reproducibility** -- With templates baked into the binary, test results
   are 100% deterministic. No possibility of template version mismatch between
   test runs. This is critical for achieving and proving 99%+ accuracy targets.

3. **Acceptable update cadence** -- Blue Archive adds new items roughly once
   every 6-12 months. A DLL rebuild at that frequency is negligible.

4. **Zero startup cost** -- No file I/O, no registration loop. Templates are
   available immediately as static memory.

5. **Simpler API** -- No `register_template` calls needed from Rust side.
   The DLL is self-contained.

### Template Build Pipeline

```
assets/icons/{items,equipment}/*.webp      (fetched by zig build fetch-icons)
assets/data/items.json, equipment.json     (raw SchaleDB master data)
(Note: digit templates no longer used — OCR uses color segmentation)
  |
  |  (TBD: Zig preprocess tool)
  |  - Decode WebP → raw RGBA pixels
  |  - Resize to 80x80 (area averaging)
  |  - Convert to grayscale + alpha mask
  |  - Generate shape-group metadata from master data
  v
assets/build/templates.bin                 (packed: gray + mask per template)
assets/build/catalog.yml                   (item catalog: id, icon, sort_order,
  |                                         shape_group, category, rarity)
  |  (@embedFile in Zig source)
  v
Available at runtime as static []const u8 slices
```

### Master Data Pipeline

SchaleDB JSON files (`items.json`, `equipment.json`) contain many fields
irrelevant to template matching. The build script extracts only what is
needed and produces a clean `catalog.yml` sorted by internal ID.

**Fields retained per item:**

| Field | Source | Purpose |
|-------|--------|---------|
| `id` | `Id` | Internal sort order, overlap detection |
| `icon` | `Icon` | Template file lookup |
| `category` | `Category` | Shape-group rule (Favor special case) |
| `sub_category` | `SubCategory` | Shape-group rule (Artifact exclusion) |
| `rarity` | `Rarity` | Color disambiguation (N/R/SR/SSR) |
| `shape_group` | computed | Base icon name (without `_0`..`_3` suffix) |
| `name` | `Name` | CLI output display only |

**Fields discarded:** `IsReleased`, `Quality`, `Tags`, `CraftQuality`,
`Craftable`, `StageDrop`, `Shop`, `Desc`, `ExpValue`, `EventId`, `EventBonus`,
`Shops`, `StatType`, `StatValue`, `LevelUpFeedExp`, and all server-specific
variants (`*Cn`, `*Global`).

The catalog is sorted by `id` (ascending), matching the in-game inventory
sort order. This enables the sort-order optimization at runtime.

### Template Filtering

Not all 1160 icons (969 items + 191 equipment) need to be embedded.
Many items never appear in the inventory grid:
- Currency icons (credits, pyroxene, etc.) -- shown in header, not grid
- Event-specific tokens that have their own UI

Filtering criteria TBD after analyzing which items actually appear in the
inventory grid. For now, assume worst case = all icons embedded.

### Binary Size Impact

~1160 templates x 80x80 x 2 (gray + mask) = ~14.2 MB (worst case, all icons)
After filtering non-inventory items, likely ~600-800 templates = ~7.5-10 MB.
This is acceptable for a Windows desktop application DLL.

---

## API Surface (C ABI)

```c
// ============================================================
// Opaque handle types (pointers to internal Zig structs)
// ============================================================
typedef void* ShittimHandle;
typedef void* ShittimSession;

// ============================================================
// Lifecycle
// ============================================================
ShittimHandle shittim_init(void);
void          shittim_destroy(ShittimHandle handle);

// ============================================================
// Screen Detection (stateless, works on any single frame)
// ============================================================
typedef enum {
    SHITTIM_SCREEN_UNKNOWN = 0,
    SHITTIM_SCREEN_ITEM_INVENTORY = 1,
    // future: EQUIPMENT, STUDENT, SHOP, ...
} ShittimScreenType;

ShittimScreenType shittim_detect_screen(
    ShittimHandle  handle,
    const uint8_t* pixels,
    uint32_t       width,
    uint32_t       height,
    uint32_t       channels      // 3=RGB, 4=RGBA
);

// ============================================================
// Scan Session (stateful, accumulates across multiple frames)
// ============================================================

// Start a new scan session for the given screen type.
// Returns a session handle. Only one session per screen type at a time.
ShittimSession shittim_session_start(
    ShittimHandle    handle,
    ShittimScreenType screen_type
);

// Feed a captured frame into the session.
// The library detects overlap with previously seen items,
// processes only new cells, and accumulates results.
// Returns the number of NEW items found in this frame (0 if all duplicates).
int32_t shittim_session_feed(
    ShittimSession session,
    const uint8_t* pixels,
    uint32_t       width,
    uint32_t       height,
    uint32_t       channels
);

// Query accumulated results so far.
uint32_t shittim_session_item_count(ShittimSession session);

typedef struct {
    const char* item_id;         // matched template ID
    float       match_score;     // best NCC score seen across all frames
    int32_t     quantity;        // parsed quantity (-1 if OCR failed)
} ShittimItem;

ShittimItem shittim_session_get_item(ShittimSession session, uint32_t index);

// End session and release resources.
void shittim_session_end(ShittimSession session);
```

---

## Test Strategy (TDD)

Development follows Test-Driven Development: Red → Green → Refactor.
Tests are organized in layers, from pure computation to full integration.

### Test Layers

| Layer | Target | Input | Assertion |
|-------|--------|-------|-----------|
| **L1: Pure math** | Area averaging, NCC, HSV conversion | Synthetic pixel arrays | Exact numeric comparison |
| **L2: Image steps** | Resize, grid detect, cell split | `test_fixtures/screen.png` | Dimensional checks, PSNR similarity |
| **L3: Matching** | Template NCC + color disambiguation | `test_fixtures/cells/*.png` | Correct item_id, score > baseline |
| **L4: OCR** | Deskew + color segmentation + digit recognition | `test_fixtures/cells_footer/*.png`, `test_fixtures/skew_number/*.png` | Exact quantity match vs ground truth (20/20 = 100%) |
| **L5: Integration** | Full pipeline + session | `test_fixtures/screen.png` | Complete item list with quantities |

### Test Fixtures

Source: `../bluearchive-aoi/output/` → copied to `test_fixtures/` in this repo.

| Fixture | Description | Size |
|---------|-------------|------|
| `screen.png` | Full game capture (2239x1246, RGB) | 1.3 MB |
| `cells/cell_r{N}_c{N}.png` | 25 extracted grid cells (116x117, RGB) | ~5 KB each |
| `cells_number/number_r{N}_c{N}.png` | 20 quantity regions (49x24, RGB) | ~1 KB each |
| `cells_footer/footer_r{N}_c{N}.png` | 20 cell footer regions (108x24, RGB) | ~1 KB each |
| `skew_number/number_r{N}_c{N}.png` | 20 deskewed quantity regions (skew 0.25) | ~1 KB each |

### Ground Truth

`test_fixtures/ground_truth.json` defines the expected results for test screenshots.
Each entry maps a cell position to its correct item_id and quantity.
This file is created once by manual inspection and maintained alongside fixtures.

```json
{
  "screen.png": {
    "grid_size": [5, 4],
    "items": [
      { "row": 0, "col": 0, "item_id": null, "quantity": 924 },
      { "row": 0, "col": 1, "item_id": null, "quantity": 381 }
    ]
  }
}
```

Quantities are verified by manual visual inspection of the game screenshot.
Item IDs must be confirmed by manual icon matching using the
Zig CLI scan tool (`zig build run -- scan --dump`).

### TDD Implementation Order

```
Phase 0:
  1. area_average_resize  ← L1: synthetic 2x2→1x1, 4x4→2x2
  2. image_normalize      ← L2: screen.png → 1600x900
  3. screen_classifier    ← L2: returns ITEM_INVENTORY for screen.png

Phase 1:
  4. grid_detect          ← L2: separator detection → 20 cells (5×4)
  5. ncc_grayscale        ← L1: synthetic correlation tests
  6. template_match       ← L3: cell → ranked candidates
  7. color_analysis       ← L1: known HSV values → rarity classification
  8. deskew               ← L1: horizontal shear (factor 0.25) on footer
  9. blue_weight_map      ← L1: #2D4663→#FFFFFF gradient → 0.0-1.0 weight
  10. column_projection   ← L1: weight map → column/row projection profiles
  11. digit_segment       ← L4: projection valleys → character boundaries
  12. digit_recognize     ← L4: projection profiles → digit classification
  13. quantity_ocr        ← L4: footer → x detection + digit parse → exact quantity
  14. cell_pipeline       ← L3: cell → (item_id, quantity)
  15. session             ← L5: full screen → 20 items
```

---

## Developer Tools

### `shittim scan` -- Capture & Analyze (Zig CLI)

The primary CLI subcommand. Captures the game window in real-time,
detects the grid, runs OCR on each cell, and outputs results as CSV.

#### Usage

```bash
zig build run -- scan [options]

Options:
  --title <string>    Window title to find (default: auto-detect "BlueArchive")
  --list-windows      List all visible windows and exit
  --dump [path]       Save captured image as PPM for debugging (default: capture.ppm)
```

#### Implementation Notes

**Window capture via Win32 API:**
Uses `FindWindow` + `PrintWindow` / `BitBlt` to capture the game window's
client area. Auto-detects "BlueArchive" or "ブルーアーカイブ" window titles.

**Pipeline:**
1. Capture game window → raw RGB pixels
2. Normalize to 1600px width (area averaging)
3. Detect grid (`grid.detectGrid`) → cell coordinates + ROI
4. Classify screen (`screen.classify`) using ROI from step 3
5. OCR each cell's footer region → quantity
6. Output CSV to stdout: `row,col,quantity`

**Platform**: Windows 11 only. Implemented using Zig's `@cImport` of
`windows.h` for direct Win32 API access.

#### Example Output

```csv
row,col,quantity
0,0,924
0,1,381
0,2,29
0,3,12
0,4,8
1,0,500
...
```

Currently outputs OCR quantities only (template matching not yet implemented).
Once template matching is added, output will include item IDs.

### `zig build fetch-icons` -- Icon Downloader (Standalone Zig Tool)

Downloads item and equipment icons from SchaleDB. Saves master data JSON
and icon images (.webp) to `assets/`.

```bash
zig build fetch-icons [-- --items-only | --equipment-only]
```

No library or zigimg dependency required (HTTP only, saves raw WebP files).

### `zig build split-cells` -- Cell Splitter (Zig Tool, requires zigimg)

Splits a cropped grid image into individual cell PNGs for test fixture generation.

```bash
zig build split-cells -- <input.png> [output_dir]
```

Requires zigimg (lazy dependency, fetched automatically on first use).

---

## Next Steps

1. ~~Review this spec and refine API surface~~ ✓
2. ~~Copy OCR digit templates to `assets/templates/digits/`~~ ✓ (abandoned: OCR uses color segmentation)
3. ~~Install Zig toolchain~~ ✓ (Zig 0.15.2 via winget)
4. ~~Create `build.zig` project scaffold~~ ✓ (lib module + CLI exe + tests)
5. ~~Build `shittim scan` subcommand (window capture + grid + OCR)~~ ✓
6. ~~Implement Phase 0 foundation (resize + screen classifier)~~ ✓
7. ~~Implement OCR pipeline (deskew + blue weight + projection + digit classify)~~ ✓
8. Populate OCR test fixtures and achieve 99%+ accuracy on 16:9 screenshots
9. Fix OCR accuracy on 4:3 aspect ratio images
10. Build template preprocess tool (WebP decode → grayscale + alpha mask → binary)
11. Implement template matching (grayscale NCC + color disambiguation)
12. Implement session management (continuous scroll capture)
13. Finalize `test_fixtures/ground_truth.json` (item_id manual labeling)
14. Integration test with ground truth data
