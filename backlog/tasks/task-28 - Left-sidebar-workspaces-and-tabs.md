---
id: TASK-28
title: 'Left sidebar: workspaces and tabs'
status: Done
assignee:
  - '@codex'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-06 13:47'
labels:
  - ui
  - workspace
milestone: m-3
dependencies:
  - TASK-19
  - TASK-27
documentation:
  - AGENTS.md
  - docs/architecture.md
modified_files:
  - src/main.zig
  - src/input.zig
  - src/workspace.zig
  - src/ui.zig
  - src/render.zig
  - AGENTS.md
  - docs/architecture.md
priority: high
ordinal: 28000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Terminal-styled left sidebar listing workspaces and, under each, its tabs with status glyphs (activity, bell, agent state). Plain text rows, no buttons. Click or keyboard to switch; collapsible and resizable by dragging its edge; toggle with a keybinding.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Sidebar lists workspaces and their tabs and reflects the active selection
- [x] #2 Clicking a workspace or tab row switches to it
- [x] #3 Sidebar can be hidden, shown and resized by mouse and keyboard
- [x] #4 E2E scenario covers switching tabs by click and by keyboard
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Add the minimal tab-to-session and sidebar presentation state needed to enumerate existing rows and switch active selection, leaving tab lifecycle operations to TASK-29 and multi-workspace ownership to TASK-33.
2. Extend the semantic tree with structured selected state and extend grid/overlay layout so a left inset shifts and resizes the terminal without introducing another representation.
3. Register named sidebar actions and shipped keyboard routes, wire semantic rows, click/focus activation, toggle and mouse/keyboard resizing through the production App.
4. Add deterministic unit coverage and a real headless sidebar scenario covering click and keyboard switching, hide/show and resizing; inspect its screenshot, run the full suite/self-checks, and reconcile documentation.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented the first production workspace shell over the TASK-27 owner model. Workspace-owned stable tab records drive one semantic sidebar tree with explicit selected state. The sidebar is a true left inset: visibility and width update the terminal grid and renderer origin while the overlay stays full-canvas. Named actions cover row activation, toggle, focus, keyboard sizing and divider drag; terminal clicks clear retained UI focus, and unbound keys remain terminal input. Hidden sessions continue to pump, and async spawn completion remains attached to its initiating session.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Completed the terminal-styled workspace/tab sidebar with true terminal inset geometry, stable semantic selection, click and independent keyboard switching, mouse and keyboard hide/show, and mouse and keyboard resizing. Added Ctrl+Shift+Down (Super+Shift+Down on macOS) to enter sidebar focus without stealing plain Tab. Verification: zig fmt; zig build (58/58 steps); zig build test (397 passed, 7 platform skips, 86/86 steps); all nine Linux headless self-checks passed; --sidebar-test reported 0 failures; visually inspected .zig-cache/sidebar-test-focus.png at 640x360. Native macOS/Windows runtime behavior was not exercised on this Linux host.
<!-- SECTION:FINAL_SUMMARY:END -->
