---
id: TASK-38
title: Theme engine and popular color schemes
status: In Progress
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-07 17:43'
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
- [ ] #1 At least ten popular schemes are bundled and selectable
- [ ] #2 Themes in the Ghostty theme file format can be dropped into a user directory and used
- [ ] #3 Palette theme picker previews the highlighted theme live and reverts on cancel
- [ ] #4 UI chrome colors derive from the active theme
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
