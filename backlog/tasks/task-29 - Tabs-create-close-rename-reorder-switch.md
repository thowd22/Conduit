---
id: TASK-29
title: 'Tabs: create, close, rename, reorder, switch'
status: Done
assignee:
  - '@codex'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-06 14:19'
labels:
  - ui
  - workspace
milestone: m-3
dependencies:
  - TASK-28
documentation:
  - AGENTS.md
  - docs/architecture.md
modified_files:
  - src/main.zig
  - src/input.zig
  - src/workspace.zig
  - AGENTS.md
  - docs/architecture.md
priority: high
ordinal: 29000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Tab lifecycle within a workspace: new tab (inherits context and cwd), close with running-process confirmation, rename, drag to reorder in the sidebar, next/previous/goto-N bindings, activity and bell indicators for background tabs.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 New tabs open in the active session's working directory when known
- [x] #2 Closing a tab with a running foreground process asks for confirmation
- [x] #3 Tabs can be reordered by drag and by keyboard action
- [x] #4 E2E scenario covers create, rename, switch and close
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Extend Workspace with atomic tab create/rename/reorder/close operations, stable monotonic ids, attention state, selection repair, and unit coverage. Snapshot the initiating session cwd for each async spawn, falling back to the workspace cwd.
2. Add named tab lifecycle/switch/reorder actions and platform bindings. Compose terminal-style rename and close-confirmation overlays from the four UI primitives; conservatively confirm any live child not proven idle by OSC 133.
3. Wire sidebar drag reorder, background activity/bell glyphs, async child creation, selection/close behavior, and keyboard/mouse parity through the production App without blocking the render thread.
4. Add a deterministic real-app tab lifecycle scenario covering create, cwd, rename, click/key switch, drag/key reorder, close confirmation, activity/bell, and close; inspect the screenshot and run format, build, full tests and every headless check before finalization.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Preparation audit: Session already exposes validated OSC 7 cwd plus OSC 133 prompt state; term already surfaces BEL; Workspace.pumpExcept identifies each serviced background session. A new-tab worker must own a cwd snapshot because the terminal slice is borrowed. Defaults used for unspecified details: next/previous wrap; after closing the active tab select next else previous; any background bytes latch activity, BEL has precedence, activation clears both; attached running children require confirmation unless OSC 133 proves the shell is idle at a prompt. Agent state remains TASK-56.

Completed evidence: stable tab/session ownership and atomic lifecycle operations; actual async child cwd inheritance from the initiating session; inline rename; click, next, previous and goto switching; drag and keyboard reorder; allocation-free activity and BEL prefixes; conservative running-process close confirmation with a two-choice keyboard focus trap and full pointer/text/key isolation. An independent audit found the initial modal focus could escape; the defect was fixed and the real SDL scenario now proves both Tab directions wrap only between cancel and confirm. Linux verification: zig build 58/58 steps; zig build test 86/86 steps, 404/411 passed with 7 expected platform skips; all ten headless app checks exit zero. The tabs screenshot was inspected and shows the true sidebar inset plus foreground-process confirmation. Native macOS and Windows runtime behavior remains unverified.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Implemented the complete flat-tab lifecycle. New tabs spawn through the workspace ExecutionContext in the active session cwd, tabs rename/switch/reorder/close through named keyboard and mouse actions, hidden output and BEL surface attention, and running foreground children use an input-isolated confirmation dialog. Added model, input and real PTY/SDL coverage plus the dedicated tabs-test; updated architecture and agent documentation. All Linux build, test and headless checks pass, and independent acceptance audit passes.
<!-- SECTION:FINAL_SUMMARY:END -->
