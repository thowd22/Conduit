---
id: TASK-50
title: Linux platform polish
status: In Progress
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-06 21:19'
labels:
  - platform
  - linux
milestone: m-5
dependencies:
  - TASK-7
modified_files:
  - src/platform.zig
  - .github/workflows/linux-e2e.yml
  - .github/scripts/check-sway-fractional.sh
  - .github/scripts/check-ibus-hangul.sh
  - .github/scripts/check-x11-primary.sh
  - .github/scripts/validate-linux-desktop.sh
priority: medium
ordinal: 50000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Verify and polish Wayland and X11: fractional scaling, primary selection, IME (ibus/fcitx), client- or server-side decorations that fit the terminal look, desktop entry and icon.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Conduit runs natively on Wayland and on X11
- [ ] #2 Fractional scaling renders crisply
- [ ] #3 IME input works under at least one of ibus or fcitx
- [x] #4 Desktop entry and icon are installed by the package
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Add SDL application metadata, high-pixel-density window creation, and runtime backend/pixel-density inspection behind the platform seam.
2. Add deterministic native X11 and Wayland headless checks plus fractional-scale captures, without conflating forced scale with compositor protocol evidence.
3. Stage a stable Linux desktop entry and icon through the install prefix, keeping identifiers consistent.
4. Add real IBus or fcitx CI evidence and native primary-selection coverage; document any external-run evidence separately.
5. Run formatting/build/unit/Linux platform and full headless gates, inspect visual captures, then finalize only the criteria actually evidenced.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Coordinator verification with current runtime logging: X11 `--links-test` and `--search-test` explicitly reported `window backend x11, high-pixel-density enabled` and passed through real SDL/OpenGL. A Weston 14 headless run forced `SDL_VIDEODRIVER=wayland`; current Conduit explicitly reported `window backend wayland, high-pixel-density enabled`, completed `--self-test` with 0 grid failures, processed native resize/scale/close events, and wrote a visually inspected PNG. A fresh isolated `zig build --prefix` completed 74/74 steps; exact desktop-entry and SVG copies were staged at the standard share/applications and hicolor paths together with the binary, fallback font, shell integration and third-party notices.

A supporting forced 1.25 renderer run produced an 800x450 surface from 640x360 logical geometry, rerasterized the fallback face to 11x25px cells, and its original-resolution screenshot was visually crisp; this does not substitute for compositor-reported fractional Wayland scale, so AC2 remains open. AC3 remains open because synthetic SDL IME tests do not prove a real IBus/fcitx daemon path and neither daemon is installed locally.

Approved CI evidence is now checked in: the Linux workflow explicitly installs its X11, Sway, IBus Hangul, desktop-validation and X11 primary-selection tools; Conduit declares composition/candidate UI with SDL override priority before video initialization; native Sway runs without --scale and asserts compositor IPC scale 1.25 plus SDL 1.25 geometry and PNG dimensions; real IBus uses XTest, asserts live ime.preedit, exact one-time Hangul delivery and a second sentinel; a separate xclip middle-click round trip proves the X11 PRIMARY selection against an external client. Failure paths retain driver artifacts and Sway shutdown is bounded. Local bash syntax and platform formatting checks pass, and independent audit found the checked-in contracts clean after race/priority repairs. AC2/AC3 remain unchecked until the ubuntu-24.04 GitHub Actions run supplies actual Sway/IBus evidence.

2026-10-06 handover from Codex: the audit's blocking race in check-x11-primary.sh (Enter posted before the pasted PRIMARY text arrived) is fixed with a driver wait-for between the XTest middle click and Enter. Remaining AC2/AC3 evidence is CI-only.
<!-- SECTION:NOTES:END -->

## Comments

<!-- COMMENTS:BEGIN -->
created: 2026-10-06 19:53
---
User approved CI-only Linux packages needed for real IBus and compositor fractional-scaling evidence, following modern Linux distro defaults; desktop-managed decorations remain the v0.1 choice.
---
<!-- COMMENTS:END -->
