---
id: TASK-71
title: Real keystrokes deliver printable characters twice
status: Done
assignee:
  - '@claude'
created_date: '2026-10-06 22:48'
updated_date: '2026-10-06 23:18'
labels:
  - keyboard
  - terminal
  - bug
milestone: m-1
dependencies: []
priority: high
type: bug
ordinal: 72000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Typing on a real X11 keyboard writes every printable character to the child twice ('hello' arrives as 'hheelllloo'), seen first on the GitHub ubuntu-24.04 runner in the IBus Hangul check and reproduced in an ubuntu:24.04 container with Xvfb and xdotool, with no input method involved. SDL emits a key-down event and then a text-input event for one physical keystroke; the key encoder derives the character's text from the SDL keycode and writes it, and the text-input handler commits the same character again. Every existing test injects synthetic SDL events (conduit-test type posts only text input, key posts only key events), so no test ever produced the real pair. The dev box is headless, so the real-key path must be covered by a check driven with XTest (xdotool) under Xvfb.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A unit test reproduces the duplicate (key press followed by an identical text-input event) and fails before the fix, and the fix delivers the character once while unrelated text input (IME commits, dead-key results) is still committed exactly once
- [x] #2 Alt-modified printable keys still encode as the terminal expects and are not delivered a second time by the text-input event; control chords are unaffected
- [x] #3 A deterministic Linux check types through real X11 key events (xdotool under Xvfb) into a conduit-test launched app and asserts the child received the typed line exactly once; it runs in the Linux CI gate
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Add a pure pending-key-text helper: record the UTF-8 of the character a terminal-routed key press encoded, clear it on the next key event or text_editing, and drop a text_input equal to it.
2. Wire the helper into the app's text-input commit path; keep the key path authoritative.
3. Add .github/scripts/check-x11-keyboard.sh driven by xdotool under Xvfb and run it in linux-e2e.yml.
4. Reproduce before/after in an ubuntu:24.04 container and keep every synthetic-event check green.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-10-06 slice 1 (Opus agent): input.KeyTextEcho records the UTF-8 of the character a terminal-routed press/repeat encoded (not for Ctrl/Super chords, not while composing, 1-4 bytes), any key or text_editing event clears it, and a text_input equal to it is dropped; wired into App.handle before routing and App.onKey after staging. Seven unit tests cover drop-once, mismatch commit (한), no-pending commit, clearing, Alt records x, Ctrl/Super/control record nothing, 4-byte codepoints, composing records nothing. New .github/scripts/check-x11-keyboard.sh types 'Hello World' and Alt+x through xdotool and asserts od hex of the child's input. Container before: KEYS_GOT1:hHeelllloo  wWoorrlldd; after: hHello wWorld, which exposed bug 2: SDL 3.4 key events carry the unmodified keycode, so platform.KeyEvent.codepoint is unshifted and Shift+h writes h while the TEXT_INPUT H echo is committed. A prototype applying Shift/Caps/Mode/Level5 via SDL_GetKeyFromScancode(..., false) passed the X11 check 3/3 but broke three --ui-test ownership checks keyed on codepoint; slice 2 fixes both together. Synthetic-event checks and zig build test (527/534, 7 skips) stayed green with slice 1.

2026-10-06 slice 2 (Opus agent): platform.layoutCodepoint asks SDL_GetKeyFromScancode(scancode, mods & (Shift|Caps|Mode|Level5), false) so KeyEvent.codepoint is the layout character with level modifiers applied while unshifted_codepoint stays plain; postCharacterKey adds the level modifiers a posted character needs and sets the unmodified keycode SDL 3.4 reports. The UI key-ownership identity already used the named key or unshifted_codepoint; the three --ui-test checks had encoded the bug (expected 'one twoy' for Shift+y) and now expect 'Y'. A second duplicate path in focused UI Inputs (search, palette, rename) is fixed by recording the inserted text for the echo filter. Unit tests: layout codepoints (Shift+h→H, RShift+w→W, Shift+1→!, Caps+a→A, Ctrl/Alt/Super not applied, Ctrl+Shift+a→A/a), Input echo dropped once, shift/caps encode once, Shift+Y press matches y release identity. check-x11-keyboard.sh also opens search with real ctrl+shift+f and types a shifted query, asserting status 1/1 (negative control fails with 'no matches'). Container: 3/3 runs KEYS_GOT1:Hello World, KEYS_HEX1:48656c6c6f20576f726c64, KEYS_HEX2:1b78, search-status 1/1; screenshot inspected. All synthetic checks, e2e 6/6 and zig build test green on the agent's prefix.

2026-10-06 hosted evidence: Linux E2E gate run 37545203159 on commit c04e67e passed with the new 'Real X11 keyboard check' step; its retained terminal.txt shows KEYS_GOT1:Hello World, KEYS_HEX1:48656c6c6f20576f726c64 and KEYS_HEX2:1b78 exactly once, and search-status 1/1 for the shifted query typed into the search Input. The same run's IBus step committed 한글 once with the hardened settings. Local gate on the same tree: zig build test 530/537 (7 skips), all seventeen headless checks, e2e 6/6 and check-x11-keyboard.sh under host Xvfb all green.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Real keystrokes are now delivered once: platform derives the key's codepoint from the layout with Shift, Caps Lock, AltGr and Level 5 applied (SDL 3.4 key events carry the unmodified keycode), input.KeyTextEcho drops SDL's identical text-input echo after a key that already wrote text to the terminal or a focused UI Input, UI key ownership keys on the named key or unshifted codepoint, and synthetic character keys carry the layout's level modifiers. Verified by failing-first unit tests in platform/input/main, every synthetic check and scenario, and the new real-XTest check-x11-keyboard.sh in Docker, on the host and on the hosted Linux gate (run 37545203159). macOS and Windows AltGr/Option behaviour remains unverified.
<!-- SECTION:FINAL_SUMMARY:END -->
