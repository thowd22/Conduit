---
id: TASK-47
title: WSL ExecutionContext
status: In Progress
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-08 02:42'
labels:
  - windows
  - wsl
milestone: m-5
dependencies:
  - TASK-27
  - TASK-46
priority: low
ordinal: 47000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Enumerate installed WSL distributions and offer them as workspace contexts on Windows. Tabs, panes and scratchpad run inside the distribution, with cwd tracking and path translation for file references.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Installed distributions appear as connection targets on Windows
- [ ] #2 A WSL workspace opens tabs, panes and scratchpad inside the distribution
- [ ] #3 File reference clicks translate between WSL and Windows paths
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. WSL ExecutionContext (src/wsl.zig): enumerate distributions with wsl.exe --list --quiet, spawn through wsl.exe -d <distro> --cd <path> -- <argv> under ConPTY, file/dir/stat/run/watch/writeFile through wsl.exe exec channels, path translation (wslpath) for file references.
2. Offered as workspace contexts in Remote: connect on Windows; tabs, panes and scratchpad inside the distribution; cwd tracking via OSC 7 from the WSL shell.
3. Verified on the Windows runner if a distribution can be installed there (wsl --install is restricted on hosted runners: document the limit and fall back to unit tests with a scripted wsl.exe).
<!-- SECTION:PLAN:END -->
