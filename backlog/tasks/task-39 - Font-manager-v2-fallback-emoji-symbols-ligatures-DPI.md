---
id: TASK-39
title: 'Font manager v2: fallback, emoji, symbols, ligatures, DPI'
status: To Do
assignee: []
created_date: '2026-10-03 21:39'
labels:
  - font
milestone: m-4
dependencies:
  - TASK-10
priority: high
ordinal: 39000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Complete the font stack: per-codepoint fallback chains (configurable plus system fallback), color emoji, built-in rendering of box drawing, block elements, Powerline and common Nerd Font symbols so they work without a patched font, optional ligatures, separate bold/italic/bold-italic families, synthetic styles when missing, and correct re-rasterization on DPI or size change.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 CJK text and color emoji render via fallback without tofu boxes
- [ ] #2 Powerline and box-drawing glyphs align seamlessly without a Nerd Font installed
- [ ] #3 Ligatures can be toggled on and off
- [ ] #4 Font size and DPI changes re-rasterize crisply
- [ ] #5 Screenshot-based E2E scenario covers a Starship-style prompt and emoji
<!-- AC:END -->
