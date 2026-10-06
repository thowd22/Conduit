---
id: TASK-35
title: Minimal terminal-style context menu
status: Done
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-06 21:37'
labels:
  - ui
  - mouse
milestone: m-3
dependencies:
  - TASK-19
  - TASK-34
  - TASK-36
priority: low
ordinal: 35000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Configurable right-click behavior defaulting to a small text-styled menu (copy, paste, split, open link, search) rendered with the UI primitives, not a native GUI menu. Alternative setting: right-click pastes.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Right click shows the menu at the pointer with context-appropriate items
- [x] #2 Right-click behavior is configurable
- [x] #3 Menu items are keyboard navigable
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Compose the menu from a Surface panel and InteractiveText rows registered once in the semantic tree with stable context-menu.* ids, items chosen by selection and hovered terminal_link presence.
2. Route a right press on the focused pane: program-owned DEC mouse reporting keeps the report, Shift overrides; menu rows dispatch the existing clipboard, pane.split, terminal.open-link and search.open actions; modal key/pointer ownership like the palette; Shift+F10 named action opens at the cursor.
3. Add the mouse.right_click setting (config.RightClick, built-in menu) with the v0.1 session layer from --right-click=paste.
4. Add right_click to the test driver, conduit-test CLI and MCP tools.
5. Cover with unit tests, the deterministic --menu-test and a scripted context-menu E2E scenario; document and run the full Linux gate.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-10-06 implemented by an Opus subagent in main.zig, input.zig, config.zig, testdriver.zig, conduit_test.zig, e2e/scenarios.zig and e2e/runner.zig. Also repaired a stale --ui-test action-count assertion (40) that TASK-34/36 had already invalidated, so --ui-test is green again. Agent evidence: --menu-test 38 ok / 0 failures with inspected 640x360 frame (bordered panel with copy, paste, open link, split right, split down, search over the link cell); e2e 6/6; zig build test 520/527 with 7 platform skips; --links-test, --search-test, --palette-test, --ui-test green.

2026-10-06 coordinator gate after landing: zig fmt --check clean; zig build test 100/100 steps, 520/527 passed (7 Windows-only skips); all seventeen Linux headless checks green under Xvfb including --menu-test; scripted e2e 6/6 PASS with the context-menu scenario's 640x360 frame inspected (bordered panel at the pane with paste highlighted, split right, split down, search; no copy/open-link rows without selection or link). --menu-test added to linux-e2e.yml; docs updated.
<!-- SECTION:NOTES:END -->

## Comments

<!-- COMMENTS:BEGIN -->
created: 2026-10-06 18:05
---
Open link and Search menu rows must dispatch completed actions rather than inert placeholders, so TASK-35 follows TASK-34 and TASK-36.
---
<!-- COMMENTS:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Right click on a terminal pane opens a minimal terminal-style context menu built from Surface and InteractiveText rows (copy, paste, open link, split right, split down, search) whose rows dispatch the existing named actions; it is modal with Up/Down/Tab/Enter/Escape and outside-click close, Shift+F10 opens it at the cursor, program-captured mouse keeps plain right clicks with Shift overriding, and mouse.right_click (built-in menu, session --right-click=paste) makes the behaviour configurable. The test driver, CLI and MCP gained right_click. Verified by unit tests, the deterministic real-SDL --menu-test (38 checks) with an inspected frame, the context-menu scripted scenario and the full Linux gate.
<!-- SECTION:FINAL_SUMMARY:END -->
