---
id: TASK-49
title: Windows platform port
status: Done
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-08 05:28'
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
- [x] #1 Conduit runs a local shell on Windows with correct rendering and input
- [x] #2 Fonts are discovered through DirectWrite
- [x] #3 Per-monitor DPI changes are handled
- [x] #4 E2E smoke scenario passes on Windows CI
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. windows.yml (workflow_dispatch + branch pushes) on windows-latest: build, stage a portable layout (conduit.exe, fonts, shell integration, licences, themes), run the built-in checks that work with a real window on the runner's desktop session (SDL on Windows), screenshot via conduit-test at scale 1 and 1.5 (per-monitor DPI), clipboard round trip, DirectWrite-equivalent discovery through the Windows font directories.
2. platform: Windows clipboard, IME (SDL text input), dark title bar (DwmSetWindowAttribute), per-monitor DPI awareness manifest; font: discovery over %WINDIR%\Fonts and the per-user fonts dir (DirectWrite enumeration if cheap through the C seam, else directory scan with the registry font list).
3. Windows packaging for TASK-69: a portable zip (and an installer only if cheap) from release.yml, verified on the runner; e2e smoke scenario through conduit-test on Windows CI.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Coordinator 2026-10-08: merged the Windows slice (branch task-49-windows, 11 commits rebased onto main). Evidence: windows.yml run 37731052008 (success) on windows-latest build 26100: cmd.exe and pwsh under ConPTY drawn and typed through conduit-test at scale 1 and 1.5 (screenshots inspected: crisp text, correct sidebar), Unicode input delivered once, Windows clipboard both ways, DirectWrite listing 151 font files with Consolas/Cascadia Mono/per-user DejaVu resolved, live 100->125% DPI change re-rendering at 800x450, 14 gating built-in checks and the windows-smoke.sh E2E step. Not gating: clipboard/ime/links/panes/search built-ins (reasons in AGENTS.md). Unverified: real GPU driver, multi-monitor, real IME.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Windows platform port proven on the hosted runner: manifest with per-monitor-v2 DPI, DirectWrite font discovery, ConPTY shells with correct rendering and input, Windows clipboard, live DPI change, and a gating Windows E2E smoke plus 14 built-in checks in windows.yml.
<!-- SECTION:FINAL_SUMMARY:END -->
