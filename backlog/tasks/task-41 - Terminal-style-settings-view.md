---
id: TASK-41
title: Terminal-style settings view
status: Done
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-07 19:04'
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
- [x] #1 Settings opens from the palette as a tab or overlay in terminal style
- [x] #2 Each setting is editable by keyboard and mouse and persists
- [x] #3 Keybinding editor detects conflicts
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. A settings view opened by the palette-visible settings.open action as a modal terminal-styled overlay (Surface + Text/InteractiveText/Input rows) grouped by area: appearance (theme), fonts, keys, scratchpad, mouse; each row shows the setting's name, current value and source layer.
2. Rows are editable by keyboard (Up/Down/Tab, Enter edits: fixed-choice rows cycle or open a chooser, text/number rows open an inline Input, bool rows toggle) and by mouse (click row to edit, click value to toggle); every commit writes the key through config.writeDocumentValue and applies live through the existing reload path.
3. Keybinding editor: a keys group listing every action with its chords; editing captures the next chord through the real key path and refuses or warns on a conflict with another action (names the conflicting action), writes keybind lines (unbind + rebind) to the file.
4. A row jumps to the raw file (dispatches config.open); Escape closes; modal isolation like the palette.
5. Deterministic Linux --settings-test (open by palette and chord, edit a number/bool/choice row by keyboard and by mouse with file readback, keybind conflict detection, jump to raw config, modal isolation) with an inspected screenshot, plus a settings-view e2e scenario; docs updated.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Agent: settings.open (Ctrl+Shift+, / Cmd+Shift+,) opens a modal Surface dialog of the four primitives grouped Appearance/Fonts/Keys/Scratchpad/Mouse plus settings.raw; rows edit by Enter/click (bools toggle, enums cycle, theme/font.family open the existing choosers, numbers/text use inline settings.input, Left/Right step), every commit checked by config.checkValue and written through config.writeDocumentValue then reloaded at once; keybinding editor captures the next real chord before dispatch, refuses bare text keys, reports conflicts (conflict: <label>), Escape keeps, second Enter steals via config.writeActionKeybinds. --settings-test 40 checks; thirteenth e2e scenario settings-view; --palette-test updated to assert Settings now ships; action_capacity_base 58 -> 60, --ui-test expects 61 registry entries.

Coordinator verification 2026-10-07: branch fast-forwarded onto main (3054ee6..b80f5e4); full local gate green: 635/643 unit tests (8 skipped), all 21 headless checks including --settings-test, thirteen e2e scenarios. 640x360 settings dialog screenshot inspected. --settings-test added to the Linux CI gate; AGENTS.md, CLAUDE.md and docs/architecture.md updated.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Terminal-style settings view: a modal overlay opened from the palette or by chord, listing every setting in grouped clickable rows with its current value and source, editable by keyboard and mouse with validation and persistence through the settings file, a keybinding editor that captures real chords and detects conflicts, and a row that opens the raw file. Verified by unit tests, the deterministic --settings-test with file readback, the settings-view e2e scenario, an inspected screenshot and the full local gate.
<!-- SECTION:FINAL_SUMMARY:END -->
