---
id: TASK-48
title: macOS platform polish
status: Done
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-08 02:42'
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
- [x] #1 Default keybindings follow macOS conventions
- [x] #2 App runs as a proper .app bundle with correct Retina rendering
- [x] #3 Option key behavior is configurable
- [x] #4 A configured family installed in macOS system or per-user font locations is discovered and loaded, verified on a macOS runner
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. macOS CI job (macos-e2e.yml, separate from ci.yml) that builds, stages an .app bundle (Info.plist, icon, binary, resources) with a build.zig step, runs the headless checks that do not need Xvfb on the macOS runner (SDL on the runner's window server; offscreen where needed) and verifies the bundle launches and renders at Retina scale (screenshot at scale 2 inspected via artifact).
2. Cmd-based defaults already exist; option-as-alt setting (macos.option_as_alt) in config and input; secure keyboard entry and fullscreen documented or implemented where SDL exposes them.
3. Font discovery: verify the directory-scan path finds a family under /Library/Fonts and ~/Library/Fonts on the runner (TASK-48 AC4), plus TASK-15 AC1 (system clipboard copy/paste on macOS through the clipboard check on the runner).
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Landed (9 commits rebased onto main as ..4830744; duplicate Darwin accept-wake dropped in favour of the TASK-5 close-out's): macos.yml, zig build bundle (Conduit.app with Info.plist, icns, resources), Launch Services start, codesign ad hoc, 1280x720 frame at scale 2 (runner display is 1x), Command+W freed from SDL's Close menu item, macos.option_as_alt setting proven with real keystrokes, .ttc/.otc collection faces, DejaVu (~/Library/Fonts) and Menlo loaded, release.yml macos/publish-macos jobs with an unsigned dmg until MACOS_* secrets exist. Runner runs 37710508109 and 37717765398 green on every gating step; 7 built-in checks still fail on macOS (reported, not gating). Coordinator 2026-10-08: merged; 952/965 unit tests; local gate run recorded below.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
macOS platform polish: Command-based defaults pinned to the documented table, an app bundle built by zig build bundle that launches through Launch Services and renders a crisp 2x frame, a configurable Option-as-Alt setting proven with real keystrokes on the runner, and font discovery over system and per-user font locations verified on a macOS runner; seven built-in checks still fail on macOS and are tracked, and signing waits for Apple credentials.
<!-- SECTION:FINAL_SUMMARY:END -->
