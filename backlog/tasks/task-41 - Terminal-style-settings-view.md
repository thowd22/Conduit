---
id: TASK-41
title: Terminal-style settings view
status: To Do
assignee: []
created_date: '2026-10-03 21:39'
labels:
  - ui
  - config
milestone: m-4
dependencies:
  - TASK-31
  - TASK-37
priority: medium
ordinal: 41000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A Settings view opened from the palette, rendered as text with clickable rows grouped by area (appearance, fonts, keys, scratchpad, shells, agents, notifications). Editing a value writes to the config file; a row can jump to the raw config.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Settings opens from the palette as a tab or overlay in terminal style
- [ ] #2 Each setting is editable by keyboard and mouse and persists
- [ ] #3 Keybinding editor detects conflicts
<!-- AC:END -->
