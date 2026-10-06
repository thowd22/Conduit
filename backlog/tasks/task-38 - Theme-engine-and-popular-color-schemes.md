---
id: TASK-38
title: Theme engine and popular color schemes
status: To Do
assignee: []
created_date: '2026-10-03 21:39'
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
