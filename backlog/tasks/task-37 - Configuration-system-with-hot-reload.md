---
id: TASK-37
title: Configuration system with hot reload
status: In Progress
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-07 17:11'
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
- [ ] #1 Config is loaded from the platform-appropriate location with documented defaults
- [ ] #2 Invalid config produces a visible, specific error and falls back safely
- [ ] #3 Edits to the file apply without restart
- [ ] #4 Keybindings, including both scratchpad bindings, are configurable
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
