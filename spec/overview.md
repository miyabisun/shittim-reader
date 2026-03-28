# shittim-reader

## Concept

shittim-reader is a screen analysis library for [bluearchive-aoi](../bluearchive-aoi).

The name "Shittim" comes from the in-game artifact "Shittim Box" -- an oparts tablet
owned by Sensei (the protagonist) in Blue Archive. Inside the Shittim Box resides Arona,
a high-performance AI operator who intercepts surrounding information and provides
tactical advice. This library embodies that role: intercepting and analyzing game screen
data to assist the player.

## Motivation

bluearchive-aoi is built on Rust + Tauri. While Rust excels at runtime performance,
its compile times create a painful feedback loop during image processing R&D:

- Resize quality tuning requires many iterations with visual inspection
- Template matching threshold calibration needs rapid experimentation
- OCR digit recognition accuracy improvements demand trial-and-error

By extracting the image analysis pipeline into a Zig library, we gain:

- **Fast compilation** -- seconds instead of minutes
- **C ABI compatibility** -- seamless FFI from Rust/Tauri via `.dll`
- **Single binary distribution** -- the `.dll` ships alongside the Tauri `.exe`,
  invisible to end users (target audience: Windows 11 gamers, not engineers)

## Architecture

```
+---------------------------+       FFI (.dll)       +-------------------+
|    bluearchive-aoi        | <--------------------> |  shittim-reader   |
|    (Tauri + Rust)          |                        |  (Zig library)    |
|                            |                        |                   |
|  - Window capture          |   Screen image buffer  |  - Resize/normalize|
|  - Tauri UI (Svelte)       | ---------------------->|  - Screen state    |
|  - User interaction        |                        |    detection       |
|  - Master data (SchaleDB)  |   Analysis results     |  - Grid detection  |
|                            | <----------------------|  - Template match  |
|                            |     (C struct via FFI) |  - Quantity OCR    |
+---------------------------+                        +-------------------+
```

### Boundary

**bluearchive-aoi retains:**
- Window capture (Windows Graphics Capture API)
- Tauri desktop shell + Svelte UI
- Master data management (SchaleDB JSON fetch/cache for UI display)
- User-facing features

**shittim-reader provides:**
- Image analysis pipeline (the core value)
- Icon templates embedded in DLL at build time
  (fetched from SchaleDB via `zig build fetch-icons`,
  preprocessed to raw binary (TBD: Zig tool), embedded via `@embedFile`)
- Exported as a Windows DLL with C ABI

## Design Decisions (Summary)

| ID | Decision | Choice |
|----|----------|--------|
| D1 | Canonical resolution | 1600x900 (16:9) |
| D2 | Resize algorithm | Area averaging (all downscale ops) |
| D3 | Screen classifier | Key-region sampling |
| D4 | Template embedding | All templates embedded via `@embedFile` |
| D5 | Shape-group rules | `SubCategory`-based: Artifact excluded, tier variants grouped |
| D6 | Development method | TDD (Red → Green → Refactor) |

See [scope.md](./scope.md) for detailed scope, shape-group rules, test strategy,
and developer tools.
