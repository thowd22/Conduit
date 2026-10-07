---
id: TASK-41
title: Terminal-style settings view
status: In Progress
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-07 18:38'
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

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. A settings view opened by the palette-visible settings.open action as a modal terminal-styled overlay (Surface + Text/InteractiveText/Input rows) grouped by area: appearance (theme), fonts, keys, scratchpad, mouse; each row shows the setting's name, current value and source layer.
2. Rows are editable by keyboard (Up/Down/Tab, Enter edits: fixed-choice rows cycle or open a chooser, text/number rows open an inline Input, bool rows toggle) and by mouse (click row to edit, click value to toggle); every commit writes the key through config.writeDocumentValue and applies live through the existing reload path.
3. Keybinding editor: a keys group listing every action with its chords; editing captures the next chord through the real key path and refuses or warns on a conflict with another action (names the conflicting action), writes keybind lines (unbind + rebind) to the file.
4. A row jumps to the raw file (dispatches config.open); Escape closes; modal isolation like the palette.
5. Deterministic Linux --settings-test (open by palette and chord, edit a number/bool/choice row by keyboard and by mouse with file readback, keybind conflict detection, jump to raw config, modal isolation) with an inspected screenshot, plus a settings-view e2e scenario; docs updated.
<!-- SECTION:PLAN:END -->
