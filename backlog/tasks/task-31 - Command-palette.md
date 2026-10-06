---
id: TASK-31
title: Command palette
status: Done
assignee:
  - '@codex'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-06 17:18'
labels:
  - ui
  - palette
milestone: m-3
dependencies:
  - TASK-18
  - TASK-20
documentation:
  - AGENTS.md
  - docs/architecture.md
modified_files:
  - src/input.zig
  - src/palette.zig
  - src/main.zig
  - build.zig
  - AGENTS.md
  - docs/architecture.md
priority: high
ordinal: 31000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Spotlight-style centered overlay opened by a keybinding. Fuzzy search over every registered action, showing bound keys; supports nested steps (pick, then input) so commands like New Tab, Split Pane, Remote Connect, Settings, Theme and Font can prompt for arguments. Fully keyboard driven and every row clickable. Recently used actions rank first.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Palette opens centered over the window and closes on Escape or outside click
- [x] #2 Typing fuzzy-filters actions and Enter or click runs the selection
- [x] #3 Commands for new tab and split pane are present; commands whose feature has not shipped yet (settings, theme, font, remote connect) appear when it lands
- [x] #4 Multi-step commands can collect an argument
- [x] #5 E2E scenario opens the palette, runs a command and asserts the effect
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Extend action metadata with palette exposure and optional free-text or fixed-choice arguments; add platform bindings and validation tests.
2. Add an allocation-bounded fuzzy-search/MRU palette model with deterministic selection and chord formatting.
3. Compose a centered semantic modal with keyboard, pointer, text and IME ownership plus nested argument steps.
4. Exercise it through SDL and real PTYs with --palette-test, including keyboard/mouse dispatch, outside close, MRU, argument collection and terminal-input isolation.
5. Update architecture/current-state docs, run all Linux gates, inspect the screenshot and independently audit the result.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented palette metadata and Ctrl/Cmd+Shift+P bindings in src/input.zig; a bounded fuzzy/MRU model in src/palette.zig; build wiring in build.zig; and the centered semantic overlay, nested choice/input collection, modal routing, inline preedit, stable semantic IDs and --palette-test in src/main.zig. The real-PTY fixture proves New Tab and Split Pane effects, inherited cwd, mouse and keyboard activation, text isolation and normal terminal recovery. Fixed audit findings for choice text leakage, Escape over scratchpad, gesture ownership, IME anchoring/preedit, stale selection/MRU, choice scrolling, tiny canvases, inline rename stacking and stable IDs. Updated AGENTS.md and docs/architecture.md.

Verification: zig fmt; zig build 58/58; zig build test 452/459 with 7 expected platform skips; all 13 Linux headless checks pass. Visually inspected .zig-cache/palette-test-pty-final.png at 640x360. Independent audits passed after the palette-over-scratchpad Escape ownership regression was fixed and covered in --scratchpad-test.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Shipped a centered, semantic command palette with deterministic fuzzy filtering, recent-action ranking, bound-key display, nested choice/free-text arguments and full keyboard/mouse parity. New Tab and Split Pane execute through real asynchronous PTYs. Modal input, pointer, text and IME ownership is isolated from terminals and remains correct over scratchpad and rename overlays. Unit/build gates and all 13 Linux headless checks pass; the final overlay screenshot was inspected.
<!-- SECTION:FINAL_SUMMARY:END -->
