---
id: TASK-65
title: Workspace persistence and restore
status: To Do
assignee: []
created_date: '2026-10-03 21:39'
labels:
  - workspace
  - persistence
milestone: m-8
dependencies:
  - TASK-30
  - TASK-33
priority: medium
ordinal: 65000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Persist workspaces, tabs, pane layouts, working directories, connection contexts, theme and window geometry, and restore them on launch (re-spawning shells in their directories and offering to reconnect SSH workspaces). State is versioned for forward migration.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Relaunching restores workspaces, tabs, pane layout and cwd
- [ ] #2 SSH workspaces are restored with a reconnect prompt
- [ ] #3 State file has a version and corrupted state falls back to a clean start
<!-- AC:END -->
