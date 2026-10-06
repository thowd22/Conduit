---
id: TASK-32
title: 'Scratchpad: persistent popup terminal per workspace'
status: Done
assignee:
  - '@codex'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-06 16:42'
labels:
  - workspace
  - scratchpad
milestone: m-3
dependencies:
  - TASK-20
  - TASK-27
documentation:
  - AGENTS.md
  - docs/architecture.md
modified_files:
  - src/workspace.zig
  - src/input.zig
  - src/testdriver.zig
  - src/conduit_test.zig
  - src/main.zig
  - src/ui.zig
  - AGENTS.md
  - docs/architecture.md
priority: high
ordinal: 32000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Each workspace starts one hidden scratchpad session when it opens, through the workspace ExecutionContext. Two configurable keybindings present the same session as an overlay at about 50 percent or about 90 percent of the window; pressing again or Escape-binding hides it while the PTY keeps running. Includes a Scratchpad: Restart Session action. Agents can never be given the scratchpad.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Scratchpad PTY is started when the workspace is created and survives hide/show
- [x] #2 Separate bindings show the 50 and 90 percent presentations of the same session
- [x] #3 A program left running in the scratchpad (e.g. vim) is intact after hiding and reshowing
- [x] #4 Restart Session replaces the PTY with a fresh shell
- [x] #5 E2E scenario verifies persistence of output across hide, 50 and 90 percent modes
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Extend Workspace with an allocation/error-atomic scratchpad restart contract that keeps the permanent scratchpad id and old live session until a replacement PTY and terminal are ready; add model tests for initial start, hidden pumping, replacement identity/output, failure ownership and teardown.\n2. Add shipped 50%/90% scratchpad bindings and registered show/restart actions, then integrate asynchronous initial scratchpad spawn and restart with the app's worker lifecycle and terminal-input debt guard.\n3. Present the scratchpad as a bottom-docked semantic Surface over the pane area with its own retained grid; route keyboard, text, IME, paste and pointer input exclusively to it while visible; Escape and repeated size chords hide without terminating it.\n4. Extend the test-driver terminal target to scratchpad and add a deterministic real PTY/SDL --scratchpad-test covering startup, output/program persistence, both sizes, hide/show, restart, pointer/key isolation and screenshot evidence.\n5. Update architecture/current-state docs, format, run the full build/unit/headless gate, inspect the screenshot, independently audit all acceptance criteria, and finalize TASK-32 only on evidence.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented the permanent workspace-owned scratchpad across model, input, app composition and read-only automation. Workspace replacement is allocation/error-atomic and preserves the reserved session id; app startup and restart spawn through the workspace ExecutionContext without blocking the UI thread. The visible 50%/90% bottom dock has a retained terminal grid, semantic restart/hide controls, modal input isolation, Escape/repeated-chord hiding and transparent UI underlay masking.\n\nDriver terminal_text/wait_for accept active|scratchpad read-only targets while all input continues through the real presented session. Built-in checks use a deterministic plain scratchpad shell so user rc/integration output cannot contaminate idle measurements.\n\nVerification: zig fmt --check src; zig build --summary all (58/58); zig build test --summary all (441/448 passed, 7 expected platform skips); all twelve Linux headless checks passed together under Xvfb. --scratchpad-test proves hidden startup, 50/90 same-PTY resize, foreground read and shell-variable persistence, Escape/repeated-hide, key/pointer isolation, atomic restart, fresh-shell input, clickable controls and complete UI-underlay masking. Visually inspected .zig-cache/scratchpad-test-20261006-final.png: clean bordered 90% dock, retained fresh-shell output, no UI bleed inside rows 1..17; the uncovered row 0 is the intentional remaining 10%.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Delivered the persistent per-workspace scratchpad: independent async shell, retained hidden lifetime, 50%/90% bottom-dock presentations, modal terminal input, semantic hide/restart controls, atomic PTY replacement and safe read-only driver observation. Added model/input/protocol/UI tests plus a deterministic real-PTY/SDL scratchpad scenario and updated architecture/current-state documentation. Linux build, 441 tests and all twelve headless checks pass; native macOS/Windows runtime behavior remains unverified.
<!-- SECTION:FINAL_SUMMARY:END -->
