---
id: TASK-39
title: 'Font manager v2: fallback, emoji, symbols, ligatures, DPI'
status: In Progress
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-07 17:11'
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
- [ ] #1 CJK text and color emoji render via fallback without tofu boxes
- [ ] #2 Powerline and box-drawing glyphs align seamlessly without a Nerd Font installed
- [ ] #3 Ligatures can be toggled on and off
- [ ] #4 Font size and DPI changes re-rasterize crisply
- [ ] #5 Screenshot-based E2E scenario covers a Starship-style prompt and emoji
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
<!-- SECTION:NOTES:END -->
