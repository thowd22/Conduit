---
id: TASK-48
title: macOS platform polish
status: In Progress
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-08 00:09'
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

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. macOS CI job (macos-e2e.yml, separate from ci.yml) that builds, stages an .app bundle (Info.plist, icon, binary, resources) with a build.zig step, runs the headless checks that do not need Xvfb on the macOS runner (SDL on the runner's window server; offscreen where needed) and verifies the bundle launches and renders at Retina scale (screenshot at scale 2 inspected via artifact).
2. Cmd-based defaults already exist; option-as-alt setting (macos.option_as_alt) in config and input; secure keyboard entry and fullscreen documented or implemented where SDL exposes them.
3. Font discovery: verify the directory-scan path finds a family under /Library/Fonts and ~/Library/Fonts on the runner (TASK-48 AC4), plus TASK-15 AC1 (system clipboard copy/paste on macOS through the clipboard check on the runner).
<!-- SECTION:PLAN:END -->
