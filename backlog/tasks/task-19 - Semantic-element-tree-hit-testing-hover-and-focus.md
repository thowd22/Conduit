---
id: TASK-19
title: 'Semantic element tree, hit testing, hover and focus'
status: Done
assignee:
  - '@codex'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-06 00:21'
labels:
  - ui
  - mouse
milestone: m-2
dependencies:
  - TASK-18
modified_files:
  - src/ui.zig
  - src/main.zig
  - AGENTS.md
priority: high
ordinal: 19000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Every UI element registers in a semantic tree (stable id, role, label, state, bounds, action). Mouse hit testing, hover underline/highlight, keyboard focus traversal and activation all resolve through this tree. It is the single representation used by the renderer, mouse system, test driver and later accessibility.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Tree can be queried by id and role and serialized to JSON
- [x] #2 Hovering an InteractiveText highlights it and clicking triggers its action
- [x] #3 Every clickable element is also reachable and activatable by keyboard
- [x] #4 Element ids are stable across frames
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Implement an allocator-owned fixed-capacity ui.Tree whose retained nodes contain stable semantic metadata (id, parent, role, label, state, clipped device-pixel bounds, optional action) and exactly one of the four primitive paint payloads. Registration order is painter order and focus order; parents precede children; duplicate ids, unknown parents, invalid UTF-8 and capacity exhaustion fail safely.
2. Make Tree.render the sole producer of Canvas cells for registered UI. Query by id/role, reverse-order hit testing, hover, pointer press/release, focus traversal and activation all read the same nodes. Focused styling wins over hovered styling. Mouse release on its pressed element and keyboard activation return the same inert Activation{id, action}; TASK-20 owns action registry dispatch.
3. Preserve interaction state by semantic id across frame rebuilds, recompute hover from the saved pointer after layout changes, clear missing ids, and serialize a deterministic escaped JSON tree without per-frame allocation. Unit tests cover queries, hierarchy, JSON, malformed input, overlap hit order, hover visuals, mouse activation, bidirectional wrapping focus, keyboard parity and stable-id rebuilds.
4. After the ui.Tree contract passes coordinator compilation, migrate production IME composition and the --ui-test fixture in main.zig from direct primitive drawing to tree registration plus Tree.render. Add only a fixture-scoped SDL mouse/Tab/Shift+Tab/Enter bridge; production routing remains TASK-20. Extend --ui-test to prove pixel hover, identical mouse/keyboard activation, focus reachability, input typing, stable ids with moved bounds and serialized inspection.
5. Coordinator formats, builds, runs all unit/integration and seven Linux headless checks, inspects the updated UI screenshot, updates documentation, and finalizes only against demonstrated evidence.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-10-05 preparation: TASK-18 and TASK-12 are Done, so TASK-19 is eligible. A read-only audit confirmed that a metadata-only parallel tree would violate P5; the tree must retain primitive paint payloads and Canvas must be derived. Borrowed role strings avoid inventing higher-layer product roles. Activation tokens form the narrow TASK-20 seam without implementing registry or keybinding policy early.

2026-10-06 completion evidence: Tree owns fixed-capacity semantic and paint-node storage; Canvas is derived exclusively by Tree.render. Unit coverage proves id/role queries, deterministic escaped JSON including hovered/focused/pressed state, reverse-paint hit testing, hover/focus visuals, matching press/release activation, bidirectional wrapping focus, keyboard/mouse activation parity, and stable-id reconciliation across reordered/moved frames. The real SDL --ui-test proves framebuffer hover, exact click/Enter activation parity, Tab/Shift+Tab reachability, focused Input typing, stable identity/focus with changed bounds and JSON, painter order, damage restoration, and idle zero work. Coordinator verification: zig fmt --check passed; zig build passed; zig build test passed 302/309 with 7 existing platform skips; all seven Linux headless checks passed; font-check passed; backlog doctor passed; the 640x360 PPM screenshot was converted to PNG and visually inspected. Independent static audit found no acceptance blockers. TASK-20 owns production input routing and HiDPI logical-to-device pointer conversion.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Implemented the fixed-capacity semantic UI tree as the single retained source for metadata and all four primitive paint payloads. Added stable ids and hierarchy, id/role queries, deterministic JSON, clipped pixel bounds, reverse painter-order hit testing, hover/press state, wrapping keyboard focus, and identical inert mouse/keyboard Activation tokens. Integrated production IME and the deterministic real-app UI fixture so Canvas is derived only through Tree.render. Verified formatting, build, 302 runnable tests, all seven Linux headless checks, and a visually inspected GPU screenshot.
<!-- SECTION:FINAL_SUMMARY:END -->
