---
id: TASK-49
title: Windows platform port
status: In Progress
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-08 02:42'
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

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. windows.yml (workflow_dispatch + branch pushes) on windows-latest: build, stage a portable layout (conduit.exe, fonts, shell integration, licences, themes), run the built-in checks that work with a real window on the runner's desktop session (SDL on Windows), screenshot via conduit-test at scale 1 and 1.5 (per-monitor DPI), clipboard round trip, DirectWrite-equivalent discovery through the Windows font directories.
2. platform: Windows clipboard, IME (SDL text input), dark title bar (DwmSetWindowAttribute), per-monitor DPI awareness manifest; font: discovery over %WINDIR%\Fonts and the per-user fonts dir (DirectWrite enumeration if cheap through the C seam, else directory scan with the registry font list).
3. Windows packaging for TASK-69: a portable zip (and an installer only if cheap) from release.yml, verified on the runner; e2e smoke scenario through conduit-test on Windows CI.
<!-- SECTION:PLAN:END -->
