---
id: TASK-40
title: Font picker and font commands
status: Done
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-07 18:40'
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
- [x] #1 Font family picker lists installed monospace fonts and previews the highlighted one
- [x] #2 Size increase, decrease and reset work by keybinding and palette
- [x] #3 Selections are written to the config file
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Wire the settings TASK-37 already parses (font.bold/italic/bold_italic families, font.ligatures, font.nerd_symbols, plus a new font.fallbacks list) into both font.Request literals and the reload comparison in app, so the file controls font manager v2.
2. Palette commands: Font: Change Family (fixed-choice picker over installed monospace families from the font catalog with live preview and revert), Increase/Decrease/Reset Size (keybindings Ctrl+=/Ctrl+-/Ctrl+0, Cmd on macOS), Toggle Ligatures, Toggle Built-in Symbols, Configure Fallbacks (free-text comma list).
3. Each commit writes its key through config.writeDocumentValue so the file and the live state agree; hot reload picks the change up without a second rebuild.
4. Deterministic Linux --font-test covering picker preview/revert/commit, size by key and palette with cell-metric readback, ligature toggle via frame readback, file contents after each commit; plus a scripted theme-picker e2e scenario; docs updated.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Agent: font.bold/italic/bold_italic, font.ligatures, font.nerd_symbols and the new font.fallbacks (max 8) reach font.Request; FontValues.faceKey dedups rebuilds so a command's own config write reloads nothing; ligature changes use setLigatures + grid invalidation. Seven palette commands (font.pick, font.size.increase/decrease/reset, font.ligatures.toggle, font.symbols.toggle, font.fallbacks) with Ctrl+=/Ctrl+Shift+=/Ctrl+-/Ctrl+0 defaults (Cmd on macOS). Picker lists bundled + Catalog.monospaceFamilies with live preview; fixed a hover-preview oscillation (only real pointer motion moves a hover preview); palette choice ids stored per visible row. --font-test 0 failures x4; theme-picker and font-picker e2e scenarios added (twelve total). Picker is not type-to-filter (fixed-choice step).

Coordinator verification 2026-10-07: rebased onto main and fast-forwarded; full local gate green: 628/636 unit tests (8 skipped), all 20 headless checks including --font-test, twelve e2e scenarios. Picker screenshot inspected (DejaVu Sans Mono previewed with the 'Showing DejaVu Sans Mono' line). --font-test added to the Linux CI gate; AGENTS.md, CLAUDE.md and docs/architecture.md updated.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Font commands and picker: every font setting wired into font manager v2 plus a new font.fallbacks key; palette commands for family (live-preview picker over installed monospace families), size increase/decrease/reset by chord and palette, ligature and built-in symbol toggles, and fallback configuration, each persisting through config.writeDocumentValue without a redundant rebuild. Verified by unit tests, the deterministic --font-test with cell-metric and frame readback, two new e2e scenarios with inspected frames, and the full local gate.
<!-- SECTION:FINAL_SUMMARY:END -->
