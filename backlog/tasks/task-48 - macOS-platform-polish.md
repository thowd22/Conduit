---
id: TASK-48
title: macOS platform polish
status: To Do
assignee: []
created_date: '2026-10-03 21:39'
updated_date: '2026-10-05 20:47'
labels:
  - platform
  - macos
milestone: m-5
dependencies:
  - TASK-7
  - TASK-10
priority: medium
ordinal: 48000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Cmd-based default bindings, native clipboard and Retina scaling, option-as-alt setting, app bundle with icon, native notifications entitlement, secure keyboard entry option, fullscreen behavior. Complete and verify the TASK-10 directory-scan font-discovery path on macOS, including system and per-user font locations; Windows DirectWrite discovery remains TASK-49.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Default keybindings follow macOS conventions
- [ ] #2 App runs as a proper .app bundle with correct Retina rendering
- [ ] #3 Option key behavior is configurable
- [ ] #4 A configured family installed in macOS system or per-user font locations is discovered and loaded, verified on a macOS runner
<!-- AC:END -->
