---
id: TASK-50
title: Linux platform polish
status: Done
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-06 23:05'
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
- [x] #2 Fractional scaling renders crisply
- [x] #3 IME input works under at least one of ibus or fcitx
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

2026-10-06 first hosted run (37535520822) passed formatting, build, unit tests, desktop validation and all seventeen headless checks, then failed the Sway check: wlroots GLES2 needs a DRM render node and ubuntu-24.04 runners have no /dev/dri. check-sway-fractional.sh now selects pixman when no render node exists (46104ee). Reproduced in an ubuntu:24.04 container without DRM: Sway get_outputs reported scale 1.25 / mode 1280 / rect 1024 and the ReleaseSafe conduit --self-test ran as a Wayland client logging 'window backend wayland', 'scale 1.25, surface 1200x800'; exit 0.

2026-10-06 run 37537621738 passed the Sway fractional-scale check on pixman (renderer.txt retained, final.png captured) and the X11 primary-selection check, then failed the IBus step waiting for ime.preedit. Reproduced in an ubuntu:24.04 container with ibus-hangul: initial-input-mode defaults to 'latin' so the Dubeolsik keys passed through as ASCII, and the launcher's private HOME/XDG_CONFIG_HOME hid the daemon socket file from SDL. Fixed in 2acbd93 (initial-input-mode hangul, IBUS_ADDRESS exported, terminal text retained on failure); the container run then passed every step: 한글 committed once, IBUS_SECOND:exact. The preedit cell renders as a missing-glyph box because the bundled fallback face has no Hangul coverage (TASK-39), while the semantic preedit element and committed bytes prove the IME path.

2026-10-06 hosted evidence from GitHub Actions run 37539118525 (ubuntu-24.04, commit 2acbd93), retained in the conduit-linux-platform artifact: Sway 1.9 headless on wlroots pixman reported one active output at scale 1.25 (mode 1280x720, logical 1024x576) and Conduit logged 'window backend wayland', 'window reports 1.25 physical pixels per logical pixel', 'window geometry 640x360 logical, 800x450 pixels' with a crisp inspected frame; the real ibus-daemon with ibus-hangul composed the Dubeolsik keys sent by XTest into a semantic ime.preedit element, committed 한글 exactly once (IBUS_ASSERT:exact) and the second sentinel matched (IBUS_SECOND:exact); xclip middle-click paste proved PRIMARY_ASSERT:conduit-primary-external against an external X11 client; desktop-file validation passed on the installed payload.

2026-10-06 IBus check hardening after a flaky hosted rerun (3 of 4 runs passed; the failing run's child received ggkkssrrmmff): strace in an ubuntu:24.04 container showed the app never connects to the IBus socket on X11 because SDL 3.4.16's X11 backend reaches input methods only through XIM (SDL_IME_Init is called only by the Wayland backend), so the XIM bridge (ibus-daemon --xim, XMODIFIERS=@im=ibus) is required and keeps being used. The doubled ASCII was TASK-71's key/text duplication on keys the engine forwarded back unhandled. check-ibus-hangul.sh now writes use-global-engine, preload-engines ['hangul'], engines-order and initial-input-mode hangul BEFORE starting the daemon (changing them afterwards raced the first context), waits until 'ibus engine' reports hangul for the focused context, retains terminal text on failure and strips Unix sockets from the uploaded driver root. Container: 5/5 passes, 한글 committed once each run.
<!-- SECTION:NOTES:END -->

## Comments

<!-- COMMENTS:BEGIN -->
created: 2026-10-06 19:53
---
User approved CI-only Linux packages needed for real IBus and compositor fractional-scaling evidence, following modern Linux distro defaults; desktop-managed decorations remain the v0.1 choice.
---
<!-- COMMENTS:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Linux platform polish verified on native X11 and Wayland with hosted CI evidence: the SDL application metadata and high-pixel-density window run under X11 and a Weston/Sway Wayland session; a Sway headless compositor at fractional scale 1.25 produced a crisp 800x450 surface from 640x360 logical geometry; a real IBus daemon with the Hangul engine composed and committed through SDL's IME path; the X11 PRIMARY selection interoperates with an external client; and the install prefix stages the validated desktop entry and icon. Evidence: GitHub Actions run 37539118525 artifacts plus local Xvfb, Weston and Docker reproductions.
<!-- SECTION:FINAL_SUMMARY:END -->
