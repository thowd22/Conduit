---
id: TASK-18
title: 'UI primitives: Text, InteractiveText, Surface, Input'
status: Done
assignee:
  - '@codex'
created_date: '2026-10-03 21:38'
updated_date: '2026-10-05 23:48'
labels:
  - ui
milestone: m-2
dependencies:
  - TASK-11
modified_files:
  - src/ui.zig
  - src/term.zig
  - src/render.zig
  - src/main.zig
  - AGENTS.md
priority: high
ordinal: 18000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The deliberately tiny terminal-styled UI toolkit drawn on the cell grid with the same fonts as the terminal: Text (styled runs), InteractiveText (id, role, label, action, hover style), Surface (rectangular region, layering, overlays, borders drawn with box characters) and Input (single-line text entry with cursor and selection). Includes a simple cell-based layout system.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Each primitive renders on the shared GPU surface using the terminal font and theme colors
- [x] #2 Surfaces can be layered as overlays above terminal content
- [x] #3 Input supports typing, cursor movement, selection and paste
- [x] #4 Unit tests cover layout calculations
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Freeze the downward contracts: term.zig exposes Conduit-owned codepoint/grapheme width wrappers over pinned ghostty-vt; render.zig owns a flattened OverlayCell/OverlayView API, overlay GPU pass and Grid.invalidate. UI/theme types never cross into render, and transparent cells remain absent/optional.
2. Implement ui.zig with cell Rect/split layout, reusable painter-ordered Canvas, and exactly Text, InteractiveText, Surface and Input. UI resolves theme roles to render colors, validates UTF-8 atomically, preserves wide-grapheme head/tail integrity, and keeps semantic registration/routing out of scope for TASK-19/TASK-20.
3. Input is an allocator-owned single-line UTF-8 state machine with grapheme-boundary cursor/selection, insertion, deletion, movement, selection and paste. Paste normalizes each contiguous CR/LF/tab/U+2028/U+2029 separator run to one ASCII space and atomically rejects invalid UTF-8 or other control bytes.
4. Integrate in main.zig with a deterministic --ui-test: render all four primitives over a real terminal on the shared surface, prove layering/transparent cells/invalidation/removal/idle behavior, and route a narrow posted text/key fixture to the test Input without creating general production routing.
5. Coordinator formats, builds, runs all tests and Linux headless checks, inspects the UI screenshot, and evaluates each acceptance criterion against measured evidence.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
PAUSED by user before any code was written (2026-10-05). No files changed for this task; the plan above is a proposal, not landed work. Research done, for whoever picks it up:
- src/ui.zig today is the TASK-4 scaffold: Primitive enum, Id.parse, pixel Point/Bounds algebra with tests. build.zig gives ui deps font, render, term, theme (not input; input imports ui).
- render.Grid (src/render.zig) owns the solid and glyph pipelines, the atlas texture and cell metrics. Grid.draw paints only damaged rows and skips frames with no damage, so an overlay painted after it must force a full repaint (redraw_all) when it appears, changes or leaves, or the stale overlay pixels stay on the surface. Grid.addCell/pushSolid/addGlyph are the reusable pieces; SolidInstance/GlyphInstance are the instance layouts.
- Colours: theme.Palette has roles incl. background, foreground, selection, accent. theme.Color -> render.Rgba is bridged only in main.zig (surfaceColor/gridColors); render and theme may not import each other.
- Display width for UI text: ghostty-vt exports unicode.codepointWidth/graphemeWidth; only term may import ghostty-vt, so expose a width helper from term.
- App frame path: App.drawFrame in main.zig (pumpChild, terminal.refresh, grid.draw, present if frames changed or needs_present). Headless checks follow the --scroll-test/--mouse-test pattern (flag in Run, dispatch in runApp, events posted through platform.Window.post* so the real SDL path runs).
- Font has a single regular face (no bold face), so bold in UI Text is colour/emphasis only until font v2 (TASK-39).
- AC #3 (Input typing, cursor, selection, paste) needs keys routed to the focused Input; TASK-20 owns routing, so TASK-18 can prove Input as a state machine plus one real-key path in a headless check.

Resumed by user on 2026-10-05. Coordinator baseline before implementation: backlog doctor clean; zig build, zig build test, and zig fmt --check . exited 0; xvfb-run headless grid-test, self-test, scroll-test, mouse-test, and clipboard-test all passed. Existing implementation plan is being revalidated against the current renderer/UI module boundary before dispatch.

2026-10-05 reconciliation after resume: returned to To Do because its direct dependency TASK-11 was reopened for missing text attributes. No TASK-18 code has landed. When resumed, keep rendering dependency downward (render must not import ui) and leave production focus/key routing to TASK-20.

2026-10-05 font correction: the single-regular-face note above is now stale. TASK-10 has landed style-aware regular/bold/italic/bold-italic shaping and rasterization APIs (with primary-face fallback for missing styles). TASK-18 should consume those APIs for UI text after TASK-11 establishes the renderer-side style mapping; separate configurable style families and synthetic styles remain TASK-39.

2026-10-05 resumed after TASK-11 completion. The dependency is now satisfied. Before code ownership is dispatched, two read-only agent slices will fix the shared Canvas-to-render overlay contract so render remains independent of ui and production input routing remains reserved for TASK-20.

2026-10-05 implementation evidence: added cell layout and the four primitives in src/ui.zig; Conduit-owned grapheme widths in src/term.zig; a flattened UI overlay pass and invalidation contract in src/render.zig; and a deterministic real SDL/OpenGL --ui-test in src/main.zig. Coordinator verification: zig build passed; zig build test passed 285 runnable tests with 7 existing platform skips; all six Linux headless checks passed under xvfb-run; the --ui-test screenshot was visually inspected; idle overlay rendering performs zero GPU work. AC #1, #2 and #4 are demonstrated. AC #3 remains open solely because Input has typing, grapheme cursor movement and selection but no paste API until the user chooses the unspecified multiline/control paste policy.

2026-10-05 product decision: the user requires copy/paste and chose normalization for single-line Input. CR/LF/tab separator runs become one ASCII space; unsafe controls and malformed UTF-8 remain atomic errors. The remaining TASK-18 slice is now unblocked.

2026-10-05 paste completion evidence: Input.paste is allocation-free and atomic; normalizes contiguous CR/LF/tab/U+2028/U+2029 separators to one ASCII space; preserves valid non-control Unicode; replaces selections; leaves the cursor after normalized text; rejects malformed UTF-8, other C0/C1 controls and capacity overflow without changing text, cursor, anchor or viewport. Six focused tests cover plain paste, mixed normalization, selection replacement, grapheme movement, invalid/control rejection and normalized capacity. Coordinator verification after integration: zig build passed; zig build test passed 291 runnable tests with 7 existing platform skips; --ui-test passed and its final screenshot was inspected.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Implemented the four terminal-styled UI primitives and cell layout system. Text supports styled runs; InteractiveText carries inert action metadata and state-dependent visuals; Surface provides painter-ordered fills, overlays, titles and box-character borders; Input provides allocation-free single-line UTF-8 editing, grapheme cursor/selection behavior and safe normalized paste. Added Conduit-owned grapheme width wrappers, a renderer overlay contract with correct invalidation/restoration and zero idle GPU work, and a deterministic real SDL/OpenGL --ui-test. Verified zig build, 291 runnable tests, all six Linux headless checks, formatting, Backlog integrity and an inspected framebuffer screenshot.
<!-- SECTION:FINAL_SUMMARY:END -->
