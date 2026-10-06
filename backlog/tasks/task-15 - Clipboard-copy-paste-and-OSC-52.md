---
id: TASK-15
title: 'Clipboard: copy, paste and OSC 52'
status: To Do
assignee: []
created_date: '2026-10-03 21:38'
updated_date: '2026-10-05 20:34'
labels:
  - input
  - clipboard
milestone: m-1
dependencies:
  - TASK-14
modified_files:
  - src/input.zig
  - src/main.zig
  - src/term.zig
  - src/platform.zig
priority: high
ordinal: 15000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Native clipboard integration: Ctrl+Shift+C/V on Linux and Windows, Cmd+C/V on macOS, Ctrl+C copies only when a selection exists and otherwise stays SIGINT (configurable), bracketed paste, multi-line paste safety, X11/Wayland primary selection with middle-click paste, and OSC 52 with a permission setting.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Copy and paste work with the system clipboard on Linux and macOS
- [x] #2 Ctrl+C with no selection always sends SIGINT
- [x] #3 Bracketed paste is used when the application enables it
- [x] #4 Middle-click pastes the primary selection on Linux
- [x] #5 OSC 52 read/write obeys the configured policy
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
AC #1 deliberately left UNCHECKED: it reads 'Copy and paste work with the system clipboard on Linux and macOS', and only Linux was run. Same rule as TASK-10: a macOS criterion is not ticked on Linux evidence.
Built in two slices. The core slice was killed mid-edit by a harness restart and left the tree red; the coordinator repaired it (two OSC 52 callback parameters shadowing a test helper, three redundant local test constants, a guessed SDL constant SDL_HINT_VIDEODRIVER whose real name is SDL_HINT_VIDEO_DRIVER, and an unhandled permission_request event in main) before dispatching the finishing slice.
Seam: Ghostty already parses and base64-decodes OSC 52 and calls the embedder's clipboard_write/clipboard_read effects; Conduit wires those and owns the policy, which in Ghostty lives in the app layer outside lib_vt. Policies are separate for read and write, both default to ask. M1 has no prompt UI, so ask refuses and records a permission_request event carrying only operation, location and byte count.
AC2: Ctrl+C with no selection wrote exactly 0x03 (1 byte) to a real child, the clipboard kept its fixture, and the child died of SIGINT. With a selection, Ctrl+C copied 'lantern' and dropped the selection so the next Ctrl+C is SIGINT again. Regression proof by the slice: removing the selection requirement from input.clipboardKey made the unit test 'ctrl+c with nothing selected is never a copy, whatever else is true' fail and made --clipboard-test exit 1 on two checks; reverted, green. That unit test covers both chord sets x setting on/off x press/repeat/release x caps/num lock.
AC3: with the program's mode 2004 on, the paste chord wrote ESC[200~kestrel lantern ESC[201~ (27 bytes) and the child read back the same 27 bytes. With mode 2004 off, a 34-byte two-line paste sent 0 bytes and logged only its byte count; the next byte the child read was a z typed afterwards.
AC4: a middle press wrote conduit-primary-fixture (23 bytes, unbracketed with mode 2004 off). Linux only, on press only, and only when the user owns the pointer, so a program that took the mouse still gets its report.
AC5 with exact bytes. Write ESC]52;c;Y29uZHVpdC1vc2M1Mi13cml0ZQ==ESC\ : allow set the clipboard; ask left it untouched and raised permission_request{write, standard, 19}; deny left it untouched with no event; no reply in any case. Read ESC]52;c;?ESC\ : allow replied ESC]52;c;Y29uZHVpdC1vc2M1Mi1yZWFkESC\ (33 bytes); ask and deny replied the empty ESC]52;c;ESC\ (9 bytes), ask with permission_request{read, standard, null}. A real child read all 75 reply bytes.
Coordinator verification: zig fmt --check . clean; zig build test 83/83 steps and 244/251 tests with the 7 skips Windows-only; --grid-test, --self-test, --scroll-test, --mouse-test and --clipboard-test all exit 0. Safety checked independently: a --clipboard-test run at --log-level=info was searched for every fixture in plaintext and base64, and none appeared in the log file or stderr.
--clipboard-test pins SDL to the offscreen driver and refuses to run on any other, so it uses SDL's process-local clipboards and never the display's - it cannot touch a real user's clipboard.
Not verified: macOS (Cmd chords and the pasteboard), Windows, a real desktop clipboard manager or another process owning the X11/Wayland selection.

2026-10-05 reconciliation: reopened because AC #1 remains unchecked. Linux behavior passes the offscreen/process-local SDL check, but neither a real desktop/interprocess clipboard nor macOS pasteboard behavior has been verified.
<!-- SECTION:NOTES:END -->
