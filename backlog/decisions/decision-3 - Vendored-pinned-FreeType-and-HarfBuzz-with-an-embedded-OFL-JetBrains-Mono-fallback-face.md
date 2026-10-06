---
id: decision-3
title: >-
  Vendored pinned FreeType and HarfBuzz, with an embedded OFL JetBrains Mono
  fallback face
date: '2026-10-05 00:16'
status: accepted
---
## Context
Conduit owns its entire font stack — Ghostty's terminal state carries no font code at all — so
TASK-10 had to choose a discovery backend, a rasteriser and a shaper for Linux, macOS and Windows.
Two constraints decided most of it: `.github/workflows/ci.yml` installs no system packages, and
Zig 0.16's standard library ships no font stack, so every capability has to come from a
translate-c seam Conduit owns, wired the way the SDL3 seam is already wired.

## Decision
**Vendored, pinned FreeType 2.13.2 and HarfBuzz 11.0.0**, taken from `deps.files.ghostty.org` — the
exact tarballs the pinned Ghostty tree builds, so Conduit and the terminal engine rasterise through
one FreeType. Built from source with no libpng and no system zlib.

**One translate-c seam (`font-c`) for both libraries**, not two: `hb-ft.h` takes an `FT_Face`, and
two seams would produce two unrelated Zig types for the same C struct.

**The fallback face is embedded, not opened from disk.** `assets/fonts/JetBrainsMono-Regular.ttf`
(JetBrains Mono 2.304, OFL 1.1) is compiled into the binary via `@embedFile`; a missing asset fails
the build rather than producing an app with no glyphs.

**Discovery is a directory scan plus a FreeType name-table read, not fontconfig.** CI has no
fontconfig installed, and the same code resolves the macOS system and user font directories.

Licences recorded in the repo: the OFL 1.1 text for JetBrains Mono, FreeType's FTL plus its
LICENSE.TXT, and HarfBuzz's COPYING, under `assets/`.

## Consequences

- **CI pays the vendored build cost** on every cold cache. That is the price of a runner that
  installs nothing; it is paid once per cache generation, not per build.
- The four faces (regular, bold, italic, bold-italic) resolve through the same scan and name-table
  match; a missing family falls back to the bundled face and says so in a warning.
- `ghostty-vt`'s `unicode.codepointWidth` / `graphemeWidth` are **not** used here: `lib_vt.zig` does
  not re-export `unicode`, and its tables need the generated options module Ghostty's own build
  produces. Width and grapheme handling belong to `term` and the grid wiring (TASK-11). Recorded so
  the next agent does not try to import it from `font`.
- v1 does **not** do fallback chains across families, colour emoji, block/symbol/Nerd Font
  coverage, ligature toggling or DPI re-rasterisation. That is TASK-39. A glyph v1 cannot resolve
  renders as a placeholder in v0.1 — `CONDUIT.md` §5 states that gap explicitly.
- macOS CoreText resolution and Windows discovery are written but **not exercised on Linux**;
  Windows discovery belongs to TASK-49.

