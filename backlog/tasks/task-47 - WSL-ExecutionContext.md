---
id: TASK-47
title: WSL ExecutionContext
status: Done
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-08 06:34'
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
- [x] #1 Installed distributions appear as connection targets on Windows
- [x] #2 A WSL workspace opens tabs, panes and scratchpad inside the distribution
- [x] #3 File reference clicks translate between WSL and Windows paths
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. WSL ExecutionContext (src/wsl.zig): enumerate distributions with wsl.exe --list --quiet, spawn through wsl.exe -d <distro> --cd <path> -- <argv> under ConPTY, file/dir/stat/run/watch/writeFile through wsl.exe exec channels, path translation (wslpath) for file references.
2. Offered as workspace contexts in Remote: connect on Windows; tabs, panes and scratchpad inside the distribution; cwd tracking via OSC 7 from the WSL shell.
3. Verified on the Windows runner if a distribution can be installed there (wsl --install is restricted on hosted runners: document the limit and fall back to unit tests with a scripted wsl.exe).
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Coordinator 2026-10-08: context level landed on main (WslContext, distribution listing, link.WslPaths, remote wsl choice helpers; context test green against WSL2 Ubuntu on the hosted runner). App wiring in main.zig (palette choice, WSL workspace presentation, file-reference translation) dispatched as a follow-up slice with runner evidence required for ACs 1-3.

Coordinator 2026-10-08: app wiring merged (branch task-47-wsl, head caa06e5, rebased on 705e03f). Evidence on the hosted Windows runner: windows.yml run 37737271998 gating step windows-wsl-check.sh against real WSL2 Ubuntu: AC1 Remote: connect lists 'Ubuntu  WSL' (palette.choice.67.0) and the workspace row is named Ubuntu; AC2 first tab, split pane and scratchpad all run inside Ubuntu (uname Linux, WSL_DISTRO_NAME); AC3 ctrl-clicking C:\Windows\win.ini:3 opened vi on /mnt/c/Windows/win.ini at line 3 in workspace.2.tab.2. Screenshots inspected by the agent and the coordinator (ac3-editor.png shows vi on /mnt/c/Windows/win.ini). ci.yml 37737271989 green on all three OSes and Linux gate 37737271925 green. Open: WSL workspaces are not restored, OSC 7 from WSL shells only as localhost, non-root users and other distributions untried.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
WSL workspaces on Windows: registered distributions listed in Remote: connect, a chosen one opens a workspace over WslContext whose tabs, panes and scratchpad run the distribution's login shell, and Windows file references translate to /mnt paths for the editor tab; proven end to end on the hosted Windows runner against WSL2 Ubuntu.
<!-- SECTION:FINAL_SUMMARY:END -->
