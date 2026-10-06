---
id: TASK-46
title: Shell profiles and PowerShell support
status: To Do
assignee: []
created_date: '2026-10-03 21:39'
labels:
  - windows
  - shell
milestone: m-5
dependencies:
  - TASK-16
  - TASK-37
priority: medium
ordinal: 46000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Shell profile system (name, command, args, env, cwd) with platform defaults: login shell on POSIX; PowerShell 7, Windows PowerShell and cmd on Windows. New Tab With Profile in the palette. PowerShell shell-integration script for cwd tracking.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Profiles are configurable and selectable from the palette
- [ ] #2 PowerShell runs correctly under ConPTY including colors and resize
- [ ] #3 Default profile is detected sensibly per platform
<!-- AC:END -->
