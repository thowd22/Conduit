---
id: TASK-74
title: >-
  Sidebar footer: Palette hint and version replace the control rows; palette
  sizes to its widest row
status: Done
assignee:
  - Claude
created_date: '2026-10-07 14:09'
updated_date: '2026-10-07 14:17'
labels: []
dependencies: []
ordinal: 75000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The sidebar bottom-left currently stacks thirteen dim clickable control rows (+ workspace, rename/switch/close workspace, + new tab, rename, close, up/down, split right/down, zoom, close pane). The user wants them gone: the command palette already lists every one of those actions with its chord, so the footer should instead show a single centered clickable "Palette  <chord>" hint that opens the palette (keeping the mouse path to every action, invariant 4) with the stamped version centered on the row below it. Separately, the palette dialog is a fixed 64 columns and clips any row that does not fit (the UI never wraps); the user wants the dialog to expand so every label and chord is fully visible, never wrapped or clipped, within the window.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The sidebar no longer registers any workspace_action, tab_action or pane_action element; the ids workspaces.*, tabs.* and panes.* are gone from the semantic tree
- [x] #2 A centered InteractiveText `sidebar.palette` labelled "Palette  <chord>" (chord formatted from the live palette.open binding for the current profile, e.g. Ctrl+Shift+P on Linux/Windows, Cmd+Shift+P on macOS) sits on the second-to-last sidebar row; clicking it through the real SDL pointer path opens the command palette with the query focused
- [x] #3 A centered Text `sidebar.version` labelled with the stamped version (v<semver>, or v0.0.0-dev unstamped) sits on the last sidebar row; both footer rows clip rather than wrap when the sidebar is narrower than the text
- [x] #4 The tab list reclaims the rows the controls used (footer is now at most three rows plus the transient status line)
- [x] #5 The palette dialog width is derived from its widest row (label + chord, choice labels, prompts) plus borders, with a sensible minimum, clamped to the window; no row is clipped when the window is wide enough and nothing wraps
- [x] #6 The --tabs-test, --panes-test, --workspaces-test and --palette-test deterministic checks pass with their mouse paths re-routed through the sidebar Palette hint and palette rows (no assertion removed or weakened), and --ui-test, --sidebar-test, --menu-test still pass
- [x] #7 A zig build e2e scenario clicks sidebar.palette via conduit-test click and waits for palette.dialog and the focused palette.query, and the whole scenario suite passes under Xvfb
- [x] #8 Screenshots of the new footer and of the widened palette were visually inspected; AGENTS.md and docs/architecture.md describe the new footer and palette sizing
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. main.zig composeUi: delete the workspace/tab/pane control rows (footer_rows 13 -> 3 plus optional status line); add centered InteractiveText sidebar.palette ('Palette  <chord>' from formatActionBindings('palette.open')) dispatching palette.open and centered Text sidebar.version ('v' ++ version). Clip, never wrap.
2. main.zig paletteBounds: replace the fixed 64 with max(min, widest row + 4) computed once in openPalette over every palette-visible definition (label + chord), choice label and prompt; clamp to canvas.width - 4.
3. Drop the now-dead origin branches that only matched the removed control ids (targetTab active_control, tabMoveAction/paneSplitAction origin fallbacks) if nothing else reaches them.
4. Re-route the mouse paths in --tabs-test, --panes-test, --workspaces-test through a helper that clicks sidebar.palette, waits for palette.dialog, and clicks the palette.action/palette.choice row for the action; keep every assertion.
5. e2e/scenarios.zig: add a sidebar-palette scenario (click sidebar.palette, wait-for palette.dialog, focused palette.query, screenshot).
6. Coordinator runs the full local gate, inspects screenshots, updates AGENTS.md/docs/architecture.md, commits and pushes to main.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Opus subagent implemented main.zig/e2e; coordinator gate: zig fmt clean, zig build ok, zig build test 101/101 steps (545/553, 8 skipped), all 17 headless checks green under Xvfb including --menu-test, e2e 9/9 PASS with sidebar-palette. Screenshots inspected: 960x540 footer (hint + v0.0.0-dev, no controls), 76-column palette with the 72-cell 'Go to tab' row fully visible, 640x360 footer, 480x300 clamp, 10-column sidebar clip. Hint label is 21 cells so at the default 22-column content width it fills the row; centring is visible once the sidebar is wider. Palette is 76 columns because of 'Go to tab  Alt+1, ... Alt+9'.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Sidebar footer now shows a centred clickable 'Palette  <chord>' hint (sidebar.palette, dispatches palette.open) over a centred version line (sidebar.version); the thirteen workspace/tab/pane control rows are gone and the tab list reclaims their rows. The palette dialog sizes itself to its widest title/row/prompt/choice (min 40, clamped to the window) instead of a fixed 64 columns, so nothing is clipped or wrapped when the window is wide enough. Deterministic --tabs/--panes/--workspaces tests route their mouse paths through the hint and palette rows with no assertion weakened; ninth e2e scenario sidebar-palette added. Verified by the full local gate (unit, 17 headless checks, 9/9 e2e) and inspected screenshots; AGENTS.md, CLAUDE.md and docs/architecture.md updated.
<!-- SECTION:FINAL_SUMMARY:END -->
