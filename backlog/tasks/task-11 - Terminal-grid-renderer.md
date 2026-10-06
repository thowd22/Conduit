---
id: TASK-11
title: Terminal grid renderer
status: Done
assignee: []
created_date: '2026-10-03 21:38'
updated_date: '2026-10-05 20:56'
labels:
  - rendering
  - terminal
milestone: m-1
dependencies:
  - TASK-9
  - TASK-10
modified_files:
  - src/render.zig
  - src/main.zig
  - AGENTS.md
priority: high
ordinal: 11000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
GPU renderer for the terminal grid: cell backgrounds, glyphs, 16/256/truecolor, bold/italic/underline styles/strikethrough/inverse, wide characters, cursor styles and blink, and dirty-region updates driven by terminal state.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A local shell renders correctly including colors and text attributes
- [x] #2 Wide (CJK) characters and combining marks occupy correct cells
- [x] #3 Cursor shape and blink follow terminal modes
- [x] #4 Only dirty frames are rendered
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Map terminal bold/italic combinations to font.FaceStyle and route both simple cells and shaped graphemes through the matching face slot, preserving explicit palette/truecolor values.
2. Match pinned Ghostty semantics: conceal suppresses all foreground ink and decorations while retaining the background; SGR text blink remains unrendered because the pinned renderer ignores it and TASK-11 only requires cursor blink.
3. Add allocator-clean renderer tests for all four face mappings and conceal ordering. Extend the real terminal-path grid self-check with style/color/conceal assertions that remain deterministic with the bundled regular fallback.
4. Coordinator inspects visual evidence with installed JetBrains Mono, then runs zig fmt, zig build, zig build test, font-check and all Linux headless checks before evaluating AC #1.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implementation: src/render.zig maps the independent terminal bold/italic bits to font.FaceStyle. Simple cells use glyphIndexForStyle/glyphForStyle; shaped graphemes use shapeForStyle and rasterize the concrete ShapedGlyph.face_index through glyphForFace, so atlas entries remain face-sensitive. Foreground color resolution stays independent of face selection, and conceal now returns after painting the background but before underline, strike, overline or glyph ink. SGR text blink was deliberately not added: the pinned Ghostty renderer ignores it and this task scopes blink to cursor modes.

Evidence: renderer unit tests cover all four style mappings, ANSI red remaining slot 1 under bold, and concealed decorated cells queuing exactly one background with no glyph/decorative solids. zig build test --summary all completed 84/84 steps with 270 passing tests and 7 platform skips; render-test is 23/23. The grid-test passed at display scales 1 and 2 through the real terminal byte path. At scale 1 the installed JetBrains Mono faces produced 49 regular, 56 bold, 48 italic and 54 bold-italic ink pixels; bold red resolved exactly to palette slot 1, and the concealed underline+strike+overline sample had zero non-background pixels. Wide/combining, cursor and dirty-frame assertions remained green. zig build, zig fmt --check ., zig build font-check, and all five Linux headless checks passed.

Visual inspection: a real /bin/sh -c PTY run using installed JetBrains Mono was captured losslessly. Regular, bold, italic and bold-italic were visibly distinct; red and bold-red retained the same normal-red color; the concealed decorated run showed only its RGB background. The temporary screenshot was kept outside the repository.

Not verified here: macOS, Windows, or non-software GPU hardware. Platform ports/polish own that evidence; the Linux acceptance criteria are fully proven.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Completed and verified terminal text-attribute rendering on Linux. Bold, italic and bold-italic select their configured font faces for both simple and shaped cells without altering explicit colors; conceal retains the background while suppressing glyphs and all decorations. Deterministic unit and real terminal-path GPU checks pass at scales 1 and 2, an installed-face screenshot was inspected, and the complete build/test/font/headless suite is green.
<!-- SECTION:FINAL_SUMMARY:END -->
