---
id: TASK-37
title: Configuration system with hot reload
status: To Do
assignee: []
created_date: '2026-10-03 21:39'
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
