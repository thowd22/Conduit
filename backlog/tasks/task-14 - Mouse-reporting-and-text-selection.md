---
id: TASK-14
title: Mouse reporting and text selection
status: Done
assignee:
  - '@omp'
created_date: '2026-10-03 21:38'
updated_date: '2026-10-05 16:17'
labels:
  - input
  - mouse
milestone: m-1
dependencies:
  - TASK-11
  - TASK-12
modified_files:
  - src/term.zig
  - src/platform.zig
  - src/input.zig
  - src/render.zig
  - src/main.zig
priority: high
ordinal: 14000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Terminal mouse support: X10/normal/button/any-event tracking with SGR encoding passed to applications, and when the application is not capturing the mouse (or Shift is held), native selection by drag, double-click word, triple-click line, and block selection, with selection rendering.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Mouse works in vim, htop and tmux with mouse mode enabled
- [x] #2 Drag, double-click and triple-click select characters, words and lines
- [x] #3 Shift overrides application mouse capture for selection
- [x] #4 Selection survives scrolling and is cleared appropriately on new output
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
PARTIAL as of this note. The first slice landed the implementation and it compiles, with the suite green (212/219, 7 Windows-only skips) and --grid-test, --self-test and --scroll-test all still exiting 0. It proved none of the four acceptance criteria: no real program was driven, no selection verified, no screenshot taken. The slice reported that itself rather than claiming otherwise, and the task stays open until the proof lands.
What landed: SDL pointer button/motion events with isRealCoordinate dropping SDL's FLT_MAX leave-sentinel; Conduit's own word_boundaries (Ghostty's is not re-exported); mouseFormat() preferring SGR unless the program explicitly set 1005/1006/1015/1016, on the grounds that X10 cannot express a column past 222 and would have its reports silently dropped on a modern terminal; pointerOwner() giving the user the pointer whenever Shift is held; cellAt/pinAt mirroring Ghostty's own floor(x / cell_width) clamped to the grid so a report and a selection cannot name different cells; wrappers over Ghostty's SelectionGesture rather than a second gesture machine; per-frame projection of tracked pins onto a visible-cell mask so a selection survives scrolling; selection painting that yields to a program's own SGR background; and a selection generation counter so a drag is damage.
A real bug was found and fixed by its own test during that slice: the first isRealCoordinate used isFinite, which waves FLT_MAX through because FLT_MAX is finite.
Next slice (MouseProof) is the proof: real vim/htop/tmux with the exact bytes each received, the Shift override in both directions, and a --mouse-test headless check in the shape of --scroll-test. The selection criteria (drag, double-click, triple-click, scrolling survival, rendering) are the slice after that.

Second slice (MouseProof) found a real defect that only driving a live program could expose, and fixed it. Ghostty's MouseEncodeOptions.fromTerminal reads flags.mouse_event, and upstream (stream_terminal.zig:1941-1964) CLEARS that flag on any of the three DECRSTs - including ?1003l, which tmux sends immediately after ?1002h and which in xterm terms means 'stop any-event tracking', not 'stop drag tracking'. Conduit's own mouseTracking() read the DEC modes and correctly said .drag, but the encoder was handed .none and silently dropped every report, so tmux's status bar was dead. Fixed with a new mouseEncodeEvent derived from Conduit's own MouseTracking, applied in both encodePointerReport and encodeWheelReport so a program can never get button reports in one format and wheel reports in another.
Real-program evidence, modes captured over a pty (vim ESC[?1006;1000h + ESC[?1002h; htop ESC[?1006;1000h; tmux ESC[?1000h ESC[?1002h ESC[?1006h ESC[?1003l): vim's ruler moved from '1,1All' to '3,5' when sent ESC[<0;5;3M; htop replied ESC[13;6H ESC[30m ESC[46m, repainting the clicked row black on cyan so its selection bar moved, and a wheel report ESC[<64;10;8M/ESC[<65;10;8m redrew its process list; a tmux click at status-bar column 8 switched windows while columns 2/4/6 did nothing, proving the report reached the program and named the right cell.
Landed: byte-pinned unit tests for each program's enable sequence, for the format matrix (SGR by default, 1005/1006/1015/1016 honoured when asked), and for the Shift override in both directions with a real selection; two real-PTY integration tests (vim's cursor follows a report, tmux switches window on a status-bar click - the second is the regression guard for the defect above).
Coordinator verification: zig fmt --check . clean; zig build test 217/224 with the 7 skips Windows-only; --grid-test, --self-test and --scroll-test all exit 0.
Still open, deliberately: --mouse-test is not implemented and nothing has yet driven the full SDL -> App.handle -> input -> term chain (every pointer event so far was posted at the driver level); htop has no in-suite integration test because a press and release written back to back arrive as one event through ncurses, so htop is proven by direct probe and by the byte-pinned unit test only; the Shift override is proven against vim and in the unit test but not through the full chain; and the selection criteria are entirely unproven. Next slice (MouseChain) takes the chain and the selection in that order.

Closed after five slices. Two died on provider failures (one endpoint vanished, one request rejected by the provider) but both had already written their work to disk; the coordinator verified what landed rather than redoing it. A harness restart then killed the clipboard slice mid-edit and left the tree red; the coordinator repaired it before closing anything (see TASK-15).
AC1 against real programs over real PTYs, modes captured from the programs themselves: vim's ruler moved from '1,1All' to '3,5' when sent ESC[<0;5;3M; htop replied ESC[13;6H ESC[30m ESC[46m, repainting the clicked row so its selection bar moved, and a wheel report redrew its process list; a tmux click at status-bar column 8 switched windows while columns 2/4/6 did nothing. The real defect this exposed: Ghostty's encoder reads flags.mouse_event, which upstream clears on any DECRST including the ?1003l tmux sends right after ?1002h, so every report was silently dropped and tmux's status bar was dead. Fixed by deriving the encode event from Conduit's own mode tracking, for pointer and wheel alike. In-suite guards: vim's cursor follows a report; tmux switches window on a status-bar click. htop is proven by direct probe and a byte-pinned unit test, not in-suite, because ncurses merges a back-to-back press and release into one event; that test was removed rather than landed red or weakened.
AC2 through the full real chain (SDL queue -> Window.pump -> translate -> App.handle -> input -> term) in --mouse-test: a Shift+drag selected 8 bytes 'uit-mous'; a double-click selected exactly 'bravo'; a triple-click selected exactly 'conduit-mouse-24 alpha bravo charlie'; all three click presses fell within 155us of real clock, well inside the 500ms interval. Word/line decisions documented in one block in term.zig and each asserted by a test: paths and dotted names are one word, shell/URL punctuation splits, CJK runs are words, a combining mark stays with its grapheme, a wide character is never half-selected, pointer coordinates clamp rather than wrap, drag is stream unless Alt, double/triple-click are always stream, triple-click selects the trimmed soft-wrapped line.
AC3 in both directions through the full chain: unshifted the program got ESC[<0;5;9M and ESC[<32;13;9M; shifted, the program got nothing and the user got a selection; releasing Shift handed the pointer back (ESC[<32;15;9M), so the override is not a latch.
AC4: 947 pixels carry the selection colour; after a real wheel scroll of 6 rows the selection is the same 8 bytes and still 947 lit pixels while 7066 pixels changed on the surface; two more lines of output leave it intact; pruning clears it; a click on an empty cell dismisses it.
Coordinator verification after the restart repair: zig fmt --check . clean; zig build test 83/83 steps and 233/240 tests with the 7 skips Windows-only; --grid-test, --self-test, --scroll-test and --mouse-test all exit 0. The final screenshot was inspected by the coordinator: the triple-clicked line is highlighted across its full text.
Not verified here: macOS and Windows (the modsToSdl/SDL_SetModState path and isRealCoordinate are Linux evidence only), a physical mouse or compositor (every event was posted through SDL's own queue), and htop colour schemes other than 3.4.1's default.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Implemented terminal mouse reporting and native text selection on Ghostty's own encoder and gesture state machine rather than second implementations. Proven against real vim, htop and tmux, which also exposed and fixed a real defect: tmux's ?1003l made Ghostty's encoder drop every report, so tmux's mouse was dead. The new --mouse-test drives the full SDL-to-terminal chain and proves Shift overriding application capture in both directions, drag, double-click and triple-click selecting 'uit-mous', 'bravo' and the whole line, and the selection surviving a scroll and new output while staying lit on screen. 233/240 tests pass with 7 Windows-only skips, all four headless checks exit 0, and the final screenshot was inspected.
<!-- SECTION:FINAL_SUMMARY:END -->
