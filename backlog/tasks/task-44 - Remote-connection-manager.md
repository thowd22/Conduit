---
id: TASK-44
title: Remote connection manager
status: To Do
assignee: []
created_date: '2026-10-03 21:39'
labels:
  - ssh
  - palette
milestone: m-5
dependencies:
  - TASK-31
  - TASK-43
priority: medium
ordinal: 44000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Palette commands for Remote: Connect (hosts from ~/.ssh/config, saved hosts and ad hoc user@host), saved connection profiles, recent connections, and opening a remote workspace at a chosen directory.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Palette lists hosts from ssh config and saved profiles with fuzzy search
- [ ] #2 Ad hoc user@host connections can be entered and optionally saved
- [ ] #3 Connecting creates an SSH workspace visible in the sidebar
<!-- AC:END -->
