---
id: TASK-77
title: 'Sidebar: a few pixels of vertical spacing before each workspace'
status: To Do
assignee: []
created_date: '2026-10-07 15:34'
labels: []
dependencies: []
priority: low
ordinal: 78000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
In the sidebar, one workspace's tabs run straight into the next workspace's name with no visual break, so the groups blur together when more than one workspace is open. The user wants a small gap, about 5 pixels, between the last tab of a workspace and the next workspace row; the spacing between tabs within a workspace should stay as it is. Context a future agent cannot recover from the code: the sidebar is laid out in whole terminal cells by the semantic tree (TASK-28), so a gap smaller than a cell row needs either sub-cell vertical offsets for sidebar rows in the UI overlay or a decision to use a full blank row instead; which one is chosen is a product/renderer decision to confirm with the user and record as a Backlog decision. Hit testing, focus, drag-reorder targets and the list limit (rows available above the TASK-74 footer) must all account for the gap.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 When two or more workspaces are listed, a vertical gap of about 5 logical pixels (scaled with the window scale) separates the last tab of one workspace from the next workspace row; spacing between tabs within a workspace is unchanged, and the first workspace has no extra gap above it
- [ ] #2 Mouse hit testing, hover, click, tab drag-reorder and sidebar focus navigation still land on the right rows with the gap present, through the real SDL pointer path
- [ ] #3 The list limit above the footer accounts for the gaps so no row overlaps the Palette hint or version line at small window heights
- [ ] #4 The --workspaces-test or --sidebar-test (or a zig build e2e scenario) lists two workspaces with tabs and asserts the gap through semantic bounds, and a screenshot at scale 1 and at 1.25 is visually inspected
- [ ] #5 The layout approach (sub-cell offset vs blank row) is recorded as a Backlog decision; AGENTS.md and docs/architecture.md describe the sidebar spacing
<!-- AC:END -->
