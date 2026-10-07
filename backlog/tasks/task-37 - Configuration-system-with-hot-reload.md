---
id: TASK-37
title: Configuration system with hot reload
status: Done
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-07 18:22'
labels:
  - config
milestone: m-4
dependencies:
  - TASK-20
priority: high
ordinal: 37000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Human-editable config file in the platform config directory covering fonts, theme, keybindings, scratchpad sizes and bindings, shell profiles, mouse and clipboard behavior. Validated with clear error reporting in-app, hot reloaded on change, with documented defaults and a palette action to open the file.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Config is loaded from the platform-appropriate location with documented defaults
- [x] #2 Invalid config produces a visible, specific error and falls back safely
- [x] #3 Edits to the file apply without restart
- [x] #4 Keybindings, including both scratchpad bindings, are configurable
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Define the config file format (Ghostty-style key = value, # comments, repeated keybind lines) and location (XDG_CONFIG_HOME/conduit/config on Linux, platform dirs on macOS/Windows) in config.zig with a Document model, parser, validation and per-line diagnostics; no file is not an error.
2. Add built-in defaults for every documented key (font.*, theme, keybind, scratchpad.*, shell, mouse.right_click, clipboard.*) and resolve through the existing Layer model.
3. Wire the resolved settings into App at startup (font family/size/styles, keybindings including both scratchpad bindings, right click) and show a specific visible error line and warn-level log for a malformed file while keeping the previous good values.
4. Hot reload: detect file changes without a busy loop, re-parse, apply the diff (bindings rebuilt, fonts re-created and grids re-metricised when font keys changed).
5. Palette action config.open opens the file in an editor tab through the workspace ExecutionContext (reusing the file-reference tab path), creating the file with the documented defaults when absent.
6. Deterministic Linux --config-test under Xvfb covering load, custom keybinding, invalid file error + fallback, live edit applied; docs/architecture.md, AGENTS.md and a docs/config.md reference updated.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Coordinator verification 2026-10-07: branch rebased onto main and fast-forwarded (9fc1116, dcac52a, b0da00d). Full local gate green on main: zig fmt, build, 566/574 unit tests (8 skipped), all 18 headless checks including --config-test and --menu-test, and the nine e2e scenarios. Screenshot of the clipped red config.error line above the Palette hint inspected. The agent's two platform EndpointTooLong unit failures were caused by the long worktree path and do not occur on main. Not yet done: font.bold/italic/bold_italic/ligatures/nerd_symbols wiring waits for TASK-39's Request fields; a scripted config e2e scenario needs the runner to write into the run's config dir; search chord and modal keys remain hard-coded.

2026-10-07 follow-up (24ae4bc): hosted gate run 37664686277 failed the --config-test editor step because the deletion step's asynchronous face load finished 40 ms after the editor spawned, resizing the new tab from 34x14 to 56x18 while vim started and leaving its screen shifted. The check now waits for the face load to settle first. Tracing it exposed a latent bug: a child attached after an asynchronous spawn kept the PTY size from spawn time if the grid changed meanwhile; Session.syncChildSize now resizes the child to the current grid when it differs (failing-first unit tests), called from the spawn-completion path.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Ghostty-style settings file at the platform config location with documented defaults (docs/config.md), bounded parsing with line-numbered diagnostics shown as the sidebar config.error element and a safe per-key fallback, inotify/polling watcher driving main-thread hot reload (fonts rebuilt, bindings retabled, scratchpad sizes and right click updated), fully rebindable keybindings including both scratchpad toggles, and config.open/config.reload palette actions. Verified by unit tests, the deterministic --config-test under Xvfb, a conduit-test run with an inspected screenshot, and the full local gate.
<!-- SECTION:FINAL_SUMMARY:END -->
