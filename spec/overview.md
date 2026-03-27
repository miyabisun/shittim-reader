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
|                            |        (JSON/struct)   |  - Quantity OCR    |
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
  (fetched from SchaleDB via `scripts/fetch_icons.mjs`, preprocessed during Zig build)
- Exported as a Windows DLL with C ABI

## Open Questions

See [scope.md](./scope.md) for detailed scope discussion.
