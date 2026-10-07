---
id: TASK-39
title: 'Font manager v2: fallback, emoji, symbols, ligatures, DPI'
status: Done
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-07 17:51'
labels:
  - font
milestone: m-4
dependencies:
  - TASK-10
priority: high
ordinal: 39000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Complete the font stack: per-codepoint fallback chains (configurable plus system fallback), color emoji, built-in rendering of box drawing, block elements, Powerline and common Nerd Font symbols so they work without a patched font, optional ligatures, separate bold/italic/bold-italic families, synthetic styles when missing, and correct re-rasterization on DPI or size change.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 CJK text and color emoji render via fallback without tofu boxes
- [x] #2 Powerline and box-drawing glyphs align seamlessly without a Nerd Font installed
- [x] #3 Ligatures can be toggled on and off
- [x] #4 Font size and DPI changes re-rasterize crisply
- [x] #5 Screenshot-based E2E scenario covers a Starship-style prompt and emoji
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Fallback chains in font.Manager: per-codepoint resolution across the primary family, configured fallbacks, system coverage (fontconfig-style scan of installed faces) and the bundled face; glyph keys carry a face index.
2. Colour emoji through FreeType bitmap strikes (CBDT/sbix) and a colour atlas path in render.
3. Procedural sprite glyphs for box drawing, block elements, braille and Powerline (U+2500-U+259F, U+2800-U+28FF, U+E0B0-U+E0D4) drawn to the cell, so they align without a patched font; bundle a permissively licensed Nerd Font symbols-only face if its licence allows, with licence files in assets/fonts.
4. Ligatures as a shaping option that can be toggled; synthetic bold/italic when a style face is missing.
5. Re-rasterise on size and scale changes: atlas rebuilt, metrics re-derived, grids re-metricised.
6. Unit tests for every chain step; a tenth zig build e2e scenario renders a Starship-style prompt with Powerline, box drawing, CJK and emoji and screenshots it; CI gate installs the test fonts it needs.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-10-07 glyph coverage gaps seen with real harnesses inside Conduit (bundled JetBrains Mono only): Codex's braille-art logo (U+2800 block) renders as blank cells, Claude Code's ✻ (U+273B) shows as an empty box, and omp's Nerd Font private-use icons (U+F126, U+F0068 and similar) are missing; the renderer logs 'no glyph for U+XXXX; the cell keeps its background'. Fallback chains (Noto, DejaVu, Nerd Fonts) would fix all three.

Agent notes:   - '@claude'  2026-10-07 implementation (worktree agent): src/font_sprite.zig draws box drawing, blocks, braille and Powerline E0B0-E0BF/E0D2/E0D4 at the cell size; font.Manager.resolve walks sprites -> primary style -> primary regular (synthetic bold/oblique) -> Request.fallbacks -> system faces by scan-time cmap coverage -> bundled Symbols Nerd Font Mono v3.5.1 -> bundled JetBrains Mono, fitting fallback glyphs to one or two cells; FreeType now builds with the Ghostty-pinned libpng 1.6.43 + zlib 1.3.1 so Noto Color Emoji CBDT loads into a separate RGBA atlas drawn by a colour pass in render; Request.ligatures/Manager.setLigatures toggle liga/calt/dlig and render shapes ligature runs per row. Fixed a pre-existing bug: hb-ft resized the shared FT_Face to upem/64 px on the first shape, so 2x text drew at ~15.6px in 28px cells; HarfBuzz now uses its own OpenType funcs over the same bytes. New e2e scenario font-coverage (10 scenarios).

Coordinator verification 2026-10-07: branch rebased onto main and fast-forwarded (47f495b..2f22661). Full local gate green: 590/598 unit tests (8 skipped), all 18 headless checks, ten e2e scenarios including font-coverage. Before/after 1x and after 2x screenshots inspected: before shows blank CJK, icon, braille and emoji cells; after renders every category and the 2x frame is correctly sized (hb-ft upem/64 resize bug fixed). Bundled Symbols Nerd Font Mono v3.5.1 (OFL/MIT, sha256 fe471e53...) and Ghostty-pinned zlib 1.3.1/libpng 1.6.43 with licences installed and added to the release payload lists. Config wiring of font.ligatures/nerd_symbols/style families deferred to TASK-40.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Font manager v2: per-codepoint fallback chain (sprites, primary style face with synthetic bold/oblique, configured fallbacks, system faces by cmap coverage, bundled Nerd Font symbols, bundled JetBrains Mono), procedural box/block/braille/Powerline sprites, colour emoji via a premultiplied RGBA atlas and third render pass (FreeType built with libpng/zlib), ligature toggle, crisp re-rasterisation on size/scale change, plus a fix for hb-ft resizing the face to 15.6 px at every scale. Verified by 24 new unit tests, the font-coverage e2e scenario with inspected 1x/2x screenshots, and the full local gate.
<!-- SECTION:FINAL_SUMMARY:END -->
