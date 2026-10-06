---
id: TASK-36
title: Search in scrollback
status: Done
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-06 21:13'
labels:
  - terminal
  - ui
milestone: m-3
dependencies:
  - TASK-13
  - TASK-18
modified_files:
  - src/term.zig
  - src/main.zig
priority: medium
ordinal: 36000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Find within a terminal's scrollback: inline search bar, incremental highlight, next/previous match, case and regex toggles.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Search bar opens by keybinding and palette
- [x] #2 Matches are highlighted and navigable with the viewport following
- [x] #3 Search works across scrollback, not only the visible screen
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Expose bounded scrollback search from the terminal wrapper without copying unbounded history or blocking the UI thread.
2. Implement literal and case-sensitive/insensitive matching first, then wire the approved regex backend behind the same search contract.
3. Add the inline Input-based search bar, named actions/keybindings, next/previous navigation, highlighting and viewport following through the semantic tree.
4. Cover visible and off-screen matches, navigation, case/regex toggles, malformed patterns, and resize/output invalidation with unit and real-input E2E tests.
5. Run formatting/build/unit/full Linux checks, inspect the visual highlight screenshot, and independently audit every criterion.

6. Repair the two failing regex soft-wrap unit tests so the suite is green, then finalize.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Literal/case search is implemented end-to-end with bounded caller-owned scratch, incremental four-tick polling across full retained scrollback, generation-based invalidation, viewport reveal, inline semantic Input, clickable controls and named key/palette actions. Coordinator verification: term tests cover visible/off-screen ordering, case modes, reveal and output/resize invalidation; `--search-test` passed under real X11/SDL/PTy for shortcut and palette open, typed input, visible/off-screen matches, next/previous and mouse navigation, case toggle, output resync and Escape. The 640x360 final PNG was inspected and shows the inline bar, 4/4 count, controls and highlighted active match. Regex remains explicitly unavailable rather than silently using literal semantics; task status remains In Progress pending approval and implementation of the pinned static regex backend.

Paging audit repair: the literal engine now uses generation-bound raw cursors and two bounded 128-hit page slots, examines at most 32 candidates per app poll, crosses older/newer page boundaries without rescanning prefixes, and stops timed wakeups after completion or scratch exhaustion. Coordinator evidence on 2026-10-06: zig fmt --check passed; zig build completed 74/74 steps; zig build test passed 499/506 tests with 7 expected platform skips; real X11/SDL/PTy --search-test traversed 140 hits across the page boundary in both directions and wrote a visually inspected 640x360 capture; scripted E2E remained 4/4. Independent audit found no blocking paging correctness issue. Remaining regex and evidence refinements are active under decision-4.

2026-10-06 repair of the two red regex unit tests in term.zig: the resize test now reflows to 7 columns (6 columns put the whole match on one row, so it proved nothing) and pins the reflowed coordinates; the page-node test uses a + Z... + a with pattern a.*a because a greedy single-char repeat costs one Oniguruma backtrack entry per cell and legitimately hits the 4096 match-stack bound, while .* before a literal pushes only at that literal, and the unique leading anchor makes the backward (newest-first) search cover the whole two-node logical line. No engine limits were changed. term-test 110/110. Known contract: a greedy single-char repeat cannot consume more than about 4096 cells in one logical line and reports the bounded work-limit outcome.

2026-10-06 coordinator gate after the regex repairs: zig fmt --check clean; zig build test 100/100 steps, 511/518 passed with 7 Windows-only skips; real X11/SDL/PTY --search-test 40 ok / 0 failures after correcting two stale fixture expectations in main.zig (a case-sensitive regex 'needle' sees one match before the stream step prints 'needle OUTPUT'; the literal 'pagehit' query has 141 matches once the regexstream branch has printed pagehit-140, so the oldest candidate is 140). Scripted zig build e2e 5/5 PASS.
<!-- SECTION:NOTES:END -->

## Comments

<!-- COMMENTS:BEGIN -->
created: 2026-10-06 18:20
---
Regex implementation is intentionally pending the user decision on statically bundling pinned Oniguruma; no fallback will pretend a non-regex matcher satisfies the regex toggle.
---

created: 2026-10-06 19:53
---
User approved statically bundling the already-pinned Oniguruma backend for regex search, with its license notice shipped and no new system runtime dependency. Recorded as decision-4.
---
<!-- COMMENTS:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Scrollback search is complete: an inline semantic Input opened by Ctrl+Shift+F (Command+F on macOS), the palette and clickable controls, with next/previous navigation, case and regex toggles, viewport reveal, semantic match decorations, bounded incremental literal and Oniguruma-backed regex scanning across retained scrollback with 128-result pages and generation-based resynchronisation. Verified by term and app unit tests (zig build test 511 passed, 7 platform skips), the deterministic real-SDL --search-test (40 checks, 0 failures, visually inspected 640x360 frame) and the scripted E2E suite.
<!-- SECTION:FINAL_SUMMARY:END -->
