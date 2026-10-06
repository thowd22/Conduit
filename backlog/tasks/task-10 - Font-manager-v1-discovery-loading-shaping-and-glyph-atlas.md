---
id: TASK-10
title: 'Font manager v1: discovery, loading, shaping and glyph atlas'
status: Done
assignee: []
created_date: '2026-10-03 21:38'
updated_date: '2026-10-05 20:48'
labels:
  - font
milestone: m-1
dependencies:
  - TASK-7
modified_files:
  - src/font.zig
  - build.zig
  - build.zig.zon
  - assets/fonts/JetBrainsMono-Regular.ttf
  - assets/fonts/LICENSE-JetBrainsMono-OFL-1.1.txt
priority: high
ordinal: 10000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
First cut of FontManager: discover installed fonts using the directory-scan and FreeType name-table design accepted in decision-3, with Linux discovery accepted here, macOS discovery and verification in TASK-48, and Windows DirectWrite discovery in TASK-49. Load regular/bold/italic/bold-italic faces, rasterize, shape runs, and maintain a GPU glyph atlas with cache eviction. Ship a bundled fallback monospace font so the app never renders without glyphs.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A configured family is resolved from installed fonts on Linux using the discovery design accepted in decision-3
- [x] #2 Bundled fallback font is used when the configured family is missing
- [x] #3 Glyph atlas caches glyphs and grows or evicts without visual corruption
- [x] #4 Cell metrics (width, height, baseline) are computed from the primary face
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Extend Catalog entries with FreeType style flags and deterministically resolve regular, bold, italic and bold-italic files for a matched family, retaining decision-3 directory scanning.
2. Make Manager own a regular face plus any distinct style faces and their HarfBuzz fonts; missing style variants fall back to the regular face without duplicate ownership. Keep metrics based on regular and preserve current regular-face APIs.
3. Add style-aware glyph-index, shaping and rasterization APIs. Include the resolved face slot in shaped glyphs and atlas keys so equal glyph indices from different faces cannot alias.
4. Add allocator-clean unit tests for style classification/resolution, regular fallback and face-sensitive atlas behavior. Renderer consumption remains TASK-11.
5. Coordinator formats and verifies build, tests, installed-font resolution and Linux headless checks. macOS system/per-user discovery is accepted separately by TASK-48 on a macOS runner; Windows DirectWrite remains TASK-49.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Recorded as decision-3 (vendored pinned FreeType/HarfBuzz + embedded OFL fallback). AGENTS.md requires a new dependency to be recorded in the build docs; licences are in assets/ (OFL 1.1 for JetBrains Mono, FreeType FTL + LICENSE.TXT, HarfBuzz COPYING).
Implementation: src/font.zig rewritten, keeping Size, CellSize and their 5 tests and adding Metrics, Catalog/FontFile, systemFontDirectories, Atlas, Entry, Manager, ShapedGlyph, Request and 13 new tests (18 total). build.zig gained wireFontSeams/freetypeLib/harfbuzzLib/fontSeam plus a font-check step; build is now !void so the wiring fails loudly. build.zig.zon pins .freetype and .harfbuzz and adds assets to .paths.
Coordinator verification on this box: zig build exit 0; zig build test 83/83 steps and 122/122 tests with font-test at 18; zig fmt --check . clean; 'zig build font-check' resolves the real system family 'JetBrains Mono' to /usr/share/fonts/truetype/jetbrains-mono/JetBrainsMono-Regular.ttf after scanning 177 files across 4 directories, and fc-match independently reports the same file as monospace. A missing family logs a warning and uses the bundled face, with real metrics (cell 8x20px, baseline 15px, ascent 15, descent 5). Atlas: a second request for the same glyph reports hits=1 misses=1 insertions=1 evictions=0, then after filling the atlas live=false evictions=3, and the re-rasterised glyph is byte-identical (digest 0xc7044b4b540ad1ee both times) - which is the 'no visual corruption' criterion proven on real pixels rather than on a size.
Deliberately not done, belongs to TASK-39: fallback chains across families, colour emoji, block/symbol/Nerd Font coverage, ligature toggling, DPI re-rasterisation. ghostty-vt's unicode helpers are not imported because lib_vt.zig does not re-export them; width/grapheme handling belongs to term and TASK-11. Recorded in decision-3 so the next agent does not try.
Not verified here: macOS CoreText/system-directory resolution and Windows discovery (Windows is TASK-49 by the task's own wording); only Linux system-font resolution ran.

Correction, coordinator: AC #1 was checked and is now unchecked. It reads 'resolved from system fonts on Linux and macOS' and only the Linux half is proven - this machine is headless Ubuntu and no macOS runner has ever executed this code. The Linux evidence stands (real family resolved across 177 files, cross-checked with fc-match), and the macOS system/user font directory scan is written but unexercised. The criterion should be re-checked when a macOS runner exists (the CI matrix has one configured; the workflow has never been pushed). Same rule applies to any future macOS or Windows criterion: do not check it on Linux evidence.

2026-10-05 reconciliation: reopened. In addition to the already-unchecked macOS half of AC #1, src/font.zig currently loads one regular face and discovers by directory scanning, while the task description calls for regular/bold/italic/bold-italic faces and platform discovery. The old note that DPI rerasterization remains TASK-39 is stale: main.zig already reloads the face on scale changes.

2026-10-05 resumed implementation: decision-3 explicitly says the four faces resolve through the same scan. This slice keeps its accepted no-fontconfig directory-scan choice and repairs the current one-face divergence; renderer consumption remains TASK-11.

2026-10-05 implementation repair: FontManager now resolves and owns regular, bold, italic and bold-italic faces, with one HarfBuzz font per loaded face. Shaped glyphs carry the resolved face slot and atlas keys include that slot, so equal glyph indexes from different faces cannot collide. Missing styles fall back to the primary face without duplicate ownership.

Coordinator review caught two defects before acceptance: catalog paths passed to FT_New_Face were not guaranteed NUL-terminated, and FreeType style flags classified weights such as ExtraBold as regular, allowing a lexicographic ExtraBold primary. Paths are now sentinel-owned and canonical style names (Regular/Bold/Italic/Bold Italic) outrank other weights before deterministic path tie-breaking. Regression tests reopen retained catalog paths, distinguish canonical faces from ExtraBold variants, verify missing-style fallback, and conditionally shape/rasterize installed style slots 1/2/3.

Verification after repair: zig build exit 0; zig build test exit 0; zig fmt --check . clean; zig build font-check scans 177 files and resolves JetBrains Mono to JetBrainsMono-Regular.ttf with no style-open warning; all five Linux headless checks pass. AC #1 remains unchecked and the task returns to To Do because macOS discovery has still not run on a macOS runner.

2026-10-05 platform-scope reconciliation: the unrun macOS half of discovery acceptance moved to existing macOS platform task TASK-48, which now depends on TASK-10 and requires real macOS-runner proof for system and per-user fonts. TASK-10 retains the Linux discovery behavior that is implemented and objectively verified; Windows DirectWrite remains TASK-49. This preserves the platform requirement without making Linux renderer work depend on an unavailable runner.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Implemented and verified FontManager v1 on Linux: deterministic installed-font discovery under decision-3, canonical regular/bold/italic/bold-italic face selection, HarfBuzz shaping, face-sensitive glyph atlas caching/eviction, metrics, and bundled fallback. Coordinator verification passed zig build, zig build test, zig fmt --check, font-check against installed JetBrains Mono, and all five headless app checks. macOS discovery acceptance remains explicit in TASK-48 on a real macOS runner; Windows DirectWrite remains TASK-49.
<!-- SECTION:FINAL_SUMMARY:END -->
