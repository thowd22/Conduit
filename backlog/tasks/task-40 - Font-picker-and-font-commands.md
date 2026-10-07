---
id: TASK-40
title: Font picker and font commands
status: In Progress
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-07 18:08'
labels:
  - font
  - palette
milestone: m-4
dependencies:
  - TASK-31
  - TASK-37
  - TASK-39
priority: medium
ordinal: 40000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Palette commands: Change Family (searchable list of installed monospace fonts with live preview), Increase/Decrease/Reset Size, Toggle Ligatures, Configure Fallbacks. Changes persist to config.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Font family picker lists installed monospace fonts and previews the highlighted one
- [ ] #2 Size increase, decrease and reset work by keybinding and palette
- [ ] #3 Selections are written to the config file
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Wire the settings TASK-37 already parses (font.bold/italic/bold_italic families, font.ligatures, font.nerd_symbols, plus a new font.fallbacks list) into both font.Request literals and the reload comparison in app, so the file controls font manager v2.
2. Palette commands: Font: Change Family (fixed-choice picker over installed monospace families from the font catalog with live preview and revert), Increase/Decrease/Reset Size (keybindings Ctrl+=/Ctrl+-/Ctrl+0, Cmd on macOS), Toggle Ligatures, Toggle Built-in Symbols, Configure Fallbacks (free-text comma list).
3. Each commit writes its key through config.writeDocumentValue so the file and the live state agree; hot reload picks the change up without a second rebuild.
4. Deterministic Linux --font-test covering picker preview/revert/commit, size by key and palette with cell-metric readback, ligature toggle via frame readback, file contents after each commit; plus a scripted theme-picker e2e scenario; docs updated.
<!-- SECTION:PLAN:END -->
