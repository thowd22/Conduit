---
id: TASK-47
title: WSL ExecutionContext
status: To Do
assignee: []
created_date: '2026-10-03 21:39'
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
