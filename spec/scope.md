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

- [ ] **Image input** -- Accept raw pixel buffer (RGBA/RGB) with dimensions
- [ ] **Resize/normalize** -- Scale arbitrary window size to canonical resolution
      with consistent quality (current pain point in bluearchive-aoi)
- [ ] **Screen state classifier** -- Determine which screen type is currently shown
      (even if only to say "unknown / not supported yet")

### Design Decisions (Phase 0)

#### D1: Canonical Resolution -- **1600px width, 16:9 aspect ratio (1600x900)**

Inherited from bluearchive-aoi (`BASE_WIDTH: u32 = 1600` in `items.rs`).
This resolution was chosen because SchaleDB icon templates match cleanly at this scale.

- Input images are scaled to 1600px width, preserving aspect ratio
- 16:9 (1.78:1) is the primary supported aspect ratio
- 4:3 detection exists in bluearchive-aoi but is not yet supported
- All ROI coordinates are percentage-based (resolution-independent),
  but template matching requires a fixed pixel scale

#### D2: Resize Algorithm -- **To be determined (key R&D area)**

bluearchive-aoi currently uses `FilterType::Triangle` (similar to bilinear) for both:
- Full-screen downscale (arbitrary size -> 1600px width)
- Cell icon resize (cell crop -> 80x80px for template matching)

This is a known pain point -- quality is inconsistent. Zig implementation should
experiment with multiple algorithms:

| Algorithm        | Pros                     | Cons                      | Use case        |
|------------------|--------------------------|---------------------------|-----------------|
| Bilinear         | Fast, smooth             | Blurs fine detail         | Downscale       |
| Lanczos-3        | Sharp, high quality      | Ringing artifacts, slower | Downscale       |
| Area averaging   | Natural downscale        | Not for upscale           | Downscale only  |
| Nearest neighbor | Preserves hard edges     | Aliasing                  | Mask/binary     |

**Strategy**: Implement multiple algorithms, benchmark quality + speed,
choose per use case (e.g., Lanczos for screen downscale, area averaging for
icon crop, nearest for alpha masks).

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
Input: Raw pixel buffer (RGBA, arbitrary resolution)
  |
  v
[1] Downscale to 1600px width (16:9 -> 1600x900)
  |
  v
[2] Extract grid ROI (percentage-based coordinates)
     x: 53.2% -- 98.0%    (right side of screen)
     y: 20.9% -- 84.5%    (middle vertical band)
  |
  v
[3] Detect grid cell boundaries
     Separator color: #C4CFD4
     Min cell size: 20px (noise filter)
  |
  v
[4] Identify anchor item (top-left cell) -- CRITICAL STEP
     |
     +-- [4a] Grayscale NCC against ALL templates
     |         -> Produces ranked shape-group candidates
     |         -> e.g. "技術ノート系" (score 0.95), "レポート系" (0.60), ...
     |
     +-- [4b] Color analysis on top candidates
     |         -> Extract dominant hue from icon region (in HSV/Lab space)
     |         -> Disambiguate rarity: gray=T1, blue=T2, gold=T3, purple=T4
     |         -> Result: exact item ID + internal sort order position
     |
     Anchor item established -> internal ID known
  |
  v
[5] Process remaining cells (left-to-right, top-to-bottom)
     Items are sorted by internal ID (ascending).
     Knowing the anchor ID, each subsequent cell can only be:
       - The same item (duplicate row from scrolling)
       - An item with a HIGHER internal ID
     |
     +-- [5a] Narrow template candidates using sort order
     |         Anchor ID = N -> next cell candidates = { ID >= N }
     |         After each match, further narrow: { ID >= matched_ID }
     |         Typically reduces search from ~1000 to ~5-15 templates
     |
     +-- [5b] Grayscale NCC on narrowed set
     |         Much faster due to small candidate pool
     |
     +-- [5c] Color disambiguation (only if shape-group has variants)
     |         Skip this step for items with unique shapes
     |
     +-- [5d] Quantity OCR on bottom 25% of cell
     |         -> "x" character detection (masked RGB NCC)
     |         -> Digit template matching (0-9)
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

   Memory: 5 horizontal lines (width * 4 bytes each)
         + 5 vertical lines (height * 4 bytes each)
         @ 1920x1080: 5*1920*4 + 5*1080*4 = ~59 KB
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

### Key Constants (from bluearchive-aoi)

| Constant          | Value      | Source file        |
|-------------------|------------|--------------------|
| BASE_WIDTH        | 1600       | items.rs:37        |
| TEMPLATE_SIZE     | 80x80      | icon_registry.rs:11|
| Match threshold   | 0.5        | template_match.rs  |
| Separator color   | #C4CFD4    | grid_detect.rs     |
| Grid ROI x        | 53.2%-98%  | grid_detect.rs:6-7 |
| Grid ROI y        | 20.9%-84.5%| grid_detect.rs:8-9 |
| Qty region start  | 75% of cell| grid_detect.rs:34  |
| Qty trim bottom   | 6px        | grid_detect.rs:36  |
| Qty trim right    | 8px        | grid_detect.rs:37  |

### Known Issues to Address

1. **Resize quality** -- Triangle filter causes inconsistent results
   at different source resolutions. Need better interpolation.

2. **OCR accuracy** -- Digit recognition via template matching struggles
   with anti-aliased text and varying font rendering. Consider:
   - Sub-pixel alignment
   - Multiple scale matching
   - Binarization preprocessing

3. **Shape-group definition** -- Need to pre-classify which templates share
   the same shape and differ only by color. This grouping is embedded at
   compile time alongside the templates themselves.

---

## Design Decision: Template Embedding

**Decision: A -- All templates embedded in DLL at compile time**

Templates (SchaleDB icon images) are compiled into the DLL binary using
Zig's `@embedFile`. No external template registration API is needed.

### Rationale

1. **Test reproducibility** -- With templates baked into the binary, test results
   are 100% deterministic. No possibility of template version mismatch between
   test runs. This is critical for achieving and proving 99%+ accuracy targets.

2. **Acceptable update cadence** -- Blue Archive adds new items roughly once
   every 6-12 months. A DLL rebuild at that frequency is negligible.

3. **Zero startup cost** -- No file I/O, no registration loop. Templates are
   available immediately as static memory.

4. **Simpler API** -- No `register_template` calls needed from Rust side.
   The DLL is self-contained.

5. **`comptime` preprocessing** -- Zig can perform grayscale conversion and
   resize at compile time, so templates are stored in their final matchable
   form. Zero runtime preprocessing.

### Template Build Pipeline

```
assets/icons/{items,equipment}/*.webp
  |  (build step or @embedFile + comptime decode)
  v
Embedded as preprocessed 80x80 grayscale + alpha mask arrays
  |
  v
Available at runtime as static []const u8 slices
```

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
// Call shittim_session_to_json() before this if you need the result.
void shittim_session_end(ShittimSession session);

// ============================================================
// Serialization
// ============================================================
const char* shittim_session_to_json(ShittimSession session);
void        shittim_free_string(const char* str);
```

## Next Steps

1. Review this spec and refine API surface
2. Create `build.zig` project scaffold
3. Implement Phase 0 foundation (resize + screen classifier)
4. Implement Phase 1 item inventory pipeline
5. Integration test with bluearchive-aoi screenshots from `output/`
