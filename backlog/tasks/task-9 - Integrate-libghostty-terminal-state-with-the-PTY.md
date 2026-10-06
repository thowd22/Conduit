---
id: TASK-9
title: Integrate libghostty terminal state with the PTY
status: Done
assignee:
  - '@omp'
created_date: '2026-10-03 21:38'
updated_date: '2026-10-05 01:41'
labels:
  - terminal
milestone: m-1
dependencies:
  - TASK-2
  - TASK-8
modified_files:
  - src/term.zig
  - build.zig
priority: high
ordinal: 9000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Wrap the libghostty terminal in a term module: feed PTY output into the VT parser, send terminal responses back to the PTY, handle resize, expose the screen grid, cursor, modes, title and dirty information to the renderer.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 PTY output is parsed into terminal state and device responses reach the child
- [x] #2 Resizing the terminal reflows/resizes state and the PTY together
- [x] #3 Unit tests cover feeding escape sequences and reading back grid contents
- [x] #4 Title and bell events are surfaced as app events
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Ran as two slices after the first attempt died on an upstream provider timeout (no code had been written). Slice 1 (TermCore) built the ghostty-vt wrapper; slice 2 (TermPty) closed the loop to a real child. Coordinator owns the build.zig edge that gives term its pty dependency.
Public surface after both slices: Terminal.init/deinit/feed/resize/refresh, cell/cursor/keyModes/damage/title/takeEvents, plus takeResponses(dest) usize as the device-response seam (mirror of Pty.takeBytes: copies into a caller-owned buffer, never blocks, never allocates, never drops an unhanded byte), pendingResponses, droppedResponses, resizeChild(alloc, pty, size), ownedByCallingThread, ownershipViolations, focusReportingEnabled, ResponseQueue with a fixed 4096-byte capacity.
Thread rule: one owner, the thread that called init (render/UI main thread, which also owns the PTY). Enforced, not documented - every method touching grid/parser/modes/responses goes through a claim() that refuses a foreign-thread call and counts it; no lock, with the reasoning documented (a mutex serialises two threads that both intend to mutate but does not make that program correct). Per-cell readers are deliberately unchecked because a thread-id compare per cell per frame would cost more than the read, and they are safe because only one thread mutates.
Style describer: Conduit's own, written against the Zig 0.16 (self, *std.Io.Writer) signature. Documented that because Color is a union, {f} cannot reach its format, so it must be called as Color.format(color, writer).
AC1: the proof turns echo off, which is what makes it a proof rather than a reflection - /bin/sh -s with stty -echo -icanon, the shell emits ESC[c, the TERMINAL produces the 9-byte answer ESC[?62;22c (DA1: VT220 conformance 62, ANSI colour 22), and a real cat process reads those bytes from its stdin and writes them back out. Round trip: /bin/sh -c "printf 'conduit-%s\\n' grid" with no interactive shell, so the only source of bytes is the command; those bytes are asserted as parsed grid state (row 0 reads conduit-term-grid).
AC2: resizeChild moves state then the PTY in one call. XTWINOPS reports the text area as 24 80 then 40 100, DSR cursor position reports 10;5R and 2;3R, OSC 11 answered from real palette state after the program changed it, and a real /bin/sh stty size printed 24 80 before and 40 100 after.
AC3: 31 term tests (was 3). Real escape sequences read back as grid contents: plain text, SGR 1;3;4;38;2;10;20;30;48;5;99, EL 0K, ED 2J, U+6F22 plus its tail cell, e plus combining U+0301 in one cell. Hostile-input test feeds 10 slices (bare ESC[, unterminated OSC, absurd CUP parameters, invalid UTF-8 including a lone continuation byte, half a 4-byte sequence, a DCS, an SGR mouse report, an incomplete truecolour sequence, bells) and asserts the terminal is not degraded, 3 bell events, 0 dropped, and that it still erases, styles, moves the cursor and holds a wide char plus a combining mark.
AC4: Event = union(enum){ title: []const u8, bell }, drained by takeEvents after each feed, wired through Ghostty's bell and title_changed effects, with title payloads copied into a per-feed arena so several titles in one write stay distinct; droppedEvents() exposes loss.
Coordinator verification: zig build exit 0; zig build test 83/83 steps and 150/150 tests with term-test 31 and pty-test 22 unaffected; zig fmt --check . clean.
Not verified here: macOS and Windows at runtime, remote/SSH-backed children (TASK-43), kitty graphics and images (out of scope for this milestone).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Integrated libghostty terminal state with the PTY. src/term.zig now wraps ghostty_vt.Terminal - feeding bytes that can split an escape sequence anywhere, resizing, and exposing the grid, cells, cursor, key modes, title/bell events and dirty rows to a renderer - and closes the loop to a real child through a device-response queue the owner thread drains. Verified: a real /bin/sh with echo disabled emits a device-attributes query, the terminal produces the 9-byte answer, and a real cat process reads those exact bytes back, so the response path is proven rather than reflected; a real command's output is asserted as parsed grid state; and a resize moves state and PTY together, with the child reporting stty size 24 80 then 40 100. Thread ownership is enforced rather than documented: non-owner calls are refused and counted, with no lock and the reasoning recorded. 31 term tests including a hostile-input suite (truncated sequences, invalid UTF-8, absurd parameters) that proves the parser survives; 150/150 tests green, formatting clean.
<!-- SECTION:FINAL_SUMMARY:END -->
