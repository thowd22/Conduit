---
id: TASK-49
title: Windows platform port
status: To Do
assignee: []
created_date: '2026-10-03 21:39'
labels:
  - platform
  - windows
milestone: m-5
dependencies:
  - TASK-7
  - TASK-10
  - TASK-16
priority: medium
ordinal: 49000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Bring the window, renderer and input layers up on Windows: GPU backend, DirectWrite font discovery, per-monitor DPI awareness, clipboard, IME, and dark title bar. Unit and E2E suites run on Windows CI.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Conduit runs a local shell on Windows with correct rendering and input
- [ ] #2 Fonts are discovered through DirectWrite
- [ ] #3 Per-monitor DPI changes are handled
- [ ] #4 E2E smoke scenario passes on Windows CI
<!-- AC:END -->
