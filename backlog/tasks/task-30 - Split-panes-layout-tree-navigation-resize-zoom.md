---
id: TASK-30
title: 'Split panes: layout tree, navigation, resize, zoom'
status: Done
assignee:
  - '@codex'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-06 15:48'
labels:
  - ui
  - workspace
milestone: m-3
dependencies:
  - TASK-20
  - TASK-27
documentation:
  - docs/architecture.md
modified_files:
  - src/workspace.zig
  - src/input.zig
  - src/render.zig
  - src/main.zig
  - AGENTS.md
  - docs/architecture.md
priority: high
ordinal: 30000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Binary layout tree per tab: split right/down, directional focus movement, click to focus, drag dividers to resize, keyboard resize, zoom a pane to fill the tab, close and rebalance. Unfocused panes are subtly dimmed.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Panes split horizontally and vertically to arbitrary depth
- [x] #2 Dividers can be dragged and panes resized by keyboard
- [x] #3 Zoom toggles a pane to full tab size and back without restarting sessions
- [x] #4 E2E scenario covers split, focus by click, resize and close
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Add a workspace-owned binary pane tree per tab with stable pane ids, focused and zoomed pane state, arbitrary-depth right/down split, directional focus, ratio resize, close/rebalance and allocation/error-atomic unit coverage.
2. Generalize retained terminal rendering to independent pane viewports with clipping, origins, damage and subtle unfocused dimming, without coupling render to workspace types.
3. Add named pane actions and approved platform bindings with near-miss and terminal-fallback tests.
4. Integrate per-pane sessions, asynchronous cwd-inheriting spawn, input routing, semantic pane/divider elements, click focus, divider drag, keyboard resize, zoom and conservative close confirmation.
5. Add a deterministic real PTY/SDL panes scenario covering nested right/down split, cwd, click/key focus, drag/key resize, zoom without restart, close and rebalance; inspect screenshots and run the full verification gate.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Approved product contract: dividers are one cell; each visible pane is at least 2x2 terminal cells and impossible splits/resizes clamp or refuse without changing state. New panes inherit the focused pane tracked cwd, falling back to workspace cwd, and spawn through ExecutionContext. Closing a busy pane reuses TASK-29 conservative confirmation. Closing the final pane closes its tab; closing the final tab requests orderly shutdown. Clickable split-right, split-down, zoom and close-pane text live in the sidebar; panes focus by click and dividers resize by drag. Linux/Windows defaults: Ctrl+Shift+E/O split right/down, Alt+Arrow focus, Ctrl+Alt+Arrow resize, Ctrl+Shift+Enter zoom, Ctrl+Shift+X close. macOS defaults: Command+D and Command+Shift+D split right/down, Command+Alt+Arrow focus, Command+Ctrl+Arrow resize, Command+Shift+Enter zoom, Command+Shift+X close.

Final validation: `zig fmt --check src` passed; `zig build --summary all` passed 58/58; `zig build test --summary all` passed 429/436 tests with 7 expected platform skips. All eleven Linux/Xvfb headless checks pass, including `--panes-test` with 0 failures. The inspected 640x360 v3 capture shows a true inset sidebar, three clipped panes, crisp one-cell dividers and no stale pixels.

Independent acceptance audit initially found and drove fixes for cross-pane input debt, non-atomic refused splits and deferred pointer-gesture leakage. The final re-audit passed. Pane/session creation is allocation/error atomic; active-session transitions defer until staged input and terminal responses flush; UI-owned gestures retain ownership through release. Native macOS and Windows input/render paths remain runtime-unverified; their binding tables have unit coverage.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Implemented TASK-30 split panes end to end: recursive binary pane trees, right/down splits with inherited cwd, click and directional focus, mouse/keyboard resize, session-preserving zoom, conservative close/rebalance, per-pane clipped retained rendering and clickable sidebar actions. Added transactional pane-session creation and strict input/gesture ownership at session transitions. Verified with 429 passing tests, a 58/58 build, all eleven Linux headless checks, a zero-failure real-PTY/SDL pane scenario, visual screenshot inspection and an independent acceptance re-audit.
<!-- SECTION:FINAL_SUMMARY:END -->
