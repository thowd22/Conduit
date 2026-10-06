---
id: TASK-33
title: 'Multiple workspaces: create, switch, close'
status: Done
assignee:
  - '@codex'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-06 18:45'
labels:
  - workspace
milestone: m-3
dependencies:
  - TASK-28
modified_files:
  - src/workspace.zig
  - src/main.zig
  - AGENTS.md
  - docs/architecture.md
priority: high
ordinal: 33000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Workspace management: create from a directory, switch by sidebar, palette or keybinding, rename, close with confirmation (terminating its sessions and scratchpad). Each workspace keeps independent tabs, layout, scratchpad and cwd.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Workspaces can be created, renamed, switched and closed from palette and sidebar
- [x] #2 Switching workspaces preserves each workspace's layout and running sessions
- [x] #3 Closing a workspace terminates its sessions including the scratchpad
- [x] #4 E2E scenario covers two workspaces with independent scratchpads
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Add stable non-reused workspace keys and an owning multi-workspace registry with atomic create/rename/switch/remove operations and lifecycle tests.
2. Refactor App presentation and asynchronous jobs behind an active-workspace accessor while preserving the existing one-workspace behavior and test suite.
3. Compose multiple workspace rows and dynamic palette actions for create, rename, switch and close with one workspace-level close confirmation.
4. Add deterministic real-PTY --workspaces-test coverage for independent tabs, layouts, scratchpads, switching and teardown through keyboard and mouse paths.
5. Update docs, run formatting/build/unit/all Linux checks, inspect the screenshot and independently audit AC1-4.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented stable, non-reused workspace records and an owning registry; refactored App to resolve active workspace state; added dynamic sidebar and palette actions for create, rename, switch, and close; and added deterministic real-PTY coverage for independent tabs, layouts, scratchpads, switching, and teardown.

Verification: `zig fmt --check .`; `zig build test --summary all` (484 passed, 7 expected platform skips); `zig build --summary all` (74/74); and the Xvfb `--workspaces-test` scenario (0 failures, 14 frames). The generated screenshot was visually inspected. An independent acceptance audit found AC1-4 proved.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Delivered full multiple-workspace management with independent persistent session/layout state, palette and sidebar controls, close confirmation and teardown, plus a real-PTY headless scenario covering keyboard and mouse paths.
<!-- SECTION:FINAL_SUMMARY:END -->
