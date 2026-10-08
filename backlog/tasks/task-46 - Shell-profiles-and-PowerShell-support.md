---
id: TASK-46
title: Shell profiles and PowerShell support
status: In Progress
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-08 02:09'
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

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Shell profiles in config (profile.<name>.command/args/env/cwd repeatable keys, shell = <profile name> picks the default) with platform defaults: the login shell on POSIX; PowerShell 7, Windows PowerShell and cmd on Windows, detected by probing the usual paths; profiles shown in the settings view.
2. Palette 'New Tab With Profile' (tab.new-with-profile fixed-choice step) and 'Split With Profile'; the chosen profile's argv/env/cwd flow through the context-neutral spawn request (local and remote).
3. PowerShell shell-integration script (OSC 7 cwd and OSC 133 prompt marks) installed beside the bash/zsh/fish ones and injected for PowerShell profiles; proven on the Windows runner by a pty/term integration test that spawns pwsh with the script and sees OSC 7 and colours after a resize (ConPTY), since no Windows window path exists yet.
4. --profiles-test on Linux (profiles from the file, palette selection, argv/env/cwd of the spawned child, settings rows); docs.
<!-- SECTION:PLAN:END -->
