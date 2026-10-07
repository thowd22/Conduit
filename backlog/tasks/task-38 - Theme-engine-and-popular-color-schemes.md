---
id: TASK-38
title: Theme engine and popular color schemes
status: Done
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-07 18:09'
labels:
  - theme
milestone: m-4
dependencies:
  - TASK-31
  - TASK-37
priority: high
ordinal: 38000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Theme model (16 ANSI colors, foreground, background, cursor, selection, plus UI accent roles derived from them) applied to both terminal and UI. Bundle popular schemes such as Gruvbox, Catppuccin, Dracula, Nord, Tokyo Night, Solarized, One Dark, Kanagawa, Everforest and Rose Pine, support importing Ghostty/iTerm2-Color-Schemes format files and user theme directories, light/dark auto-switch, and a palette theme picker with live preview.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 At least ten popular schemes are bundled and selectable
- [x] #2 Themes in the Ghostty theme file format can be dropped into a user directory and used
- [x] #3 Palette theme picker previews the highlighted theme live and reverts on cancel
- [x] #4 UI chrome colors derive from the active theme
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Extend theme.zig: a Scheme (16 ANSI + foreground, background, cursor, selection, plus derived UI accent roles) with a derivation rule from the four base colours; bundle at least ten popular schemes as compile-time data (Gruvbox Dark/Light, Catppuccin Mocha, Dracula, Nord, Tokyo Night, Solarized Dark/Light, One Dark, Kanagawa, Everforest, Rose Pine) with provenance.
2. Parse Ghostty theme files (palette = N=#rrggbb, background, foreground, cursor-color, selection-background/foreground) from a user themes directory next to the config file; bounded, never fatal.
3. The config theme key selects a bundled or user theme; hot reload applies it; light/dark auto-switch where the platform reports it (Linux: portal/gsettings best effort or deferred with a note).
4. Apply the theme to both renderers through the existing render.Colors and ui palette seams; UI chrome colours (sidebar, palette, modal, status, error) derive from theme roles, no hard-coded colours left in app/ui.
5. Palette action theme.pick with a live-preview chooser (highlight previews, Enter commits and writes the key to the config file, Escape reverts).
6. Deterministic Linux --theme-test (bundled selection, user theme file, preview/revert, chrome colours) with inspected screenshots; docs updated.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Agent: 14 bundled schemes from iTerm2-Color-Schemes Ghostty files (licences in assets/themes/README.md); derive() keeps WCAG contrast for chrome roles; Ghostty theme parser bounded and non-fatal; theme.pick live preview follows keyboard highlight or hover, Escape/outside click reverts, Enter/click commits via config.writeDocumentValue; --theme-test 24 checks; --ui-test registry order now expects 52 actions. Cursor-text/selection-foreground parsed but not drawn; selection toned down for schemes whose selection is near the foreground. Under Xvfb SDL reports system theme unknown, so only the dark branch of auto: ran live.

Coordinator verification 2026-10-07: rebased onto main (acbf42a..b6ae3b8), full local gate green: 614/622 unit tests (8 skipped), all 19 headless checks including --theme-test, ten e2e scenarios. Picker screenshot inspected (Catppuccin Latte previewed across terminal, sidebar and dialog). --theme-test added to the Linux CI gate. Suggested theme-picker e2e scenario handed to TASK-40.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Theme engine: Scheme model with contrast-preserving derivation of every UI role, 14 bundled schemes as compile-time data, Ghostty theme-file import from the user themes directory, theme/auto: settings with hot reload and system-theme following, palette applied to every grid and all chrome, and a Theme: choose picker with live preview, revert and persisted commit. Verified by 18 theme unit tests, the deterministic --theme-test with frame readback, an inspected screenshot and the full local gate.
<!-- SECTION:FINAL_SUMMARY:END -->
