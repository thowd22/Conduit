---
id: TASK-13
title: Scrollback and viewport scrolling
status: Done
assignee:
  - '@omp'
created_date: '2026-10-03 21:38'
updated_date: '2026-10-06 23:21'
labels:
  - terminal
milestone: m-1
dependencies:
  - TASK-11
modified_files:
  - src/term.zig
  - src/platform.zig
  - src/main.zig
priority: medium
ordinal: 13000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Scrollback history with configurable limit, wheel/trackpad scrolling with smooth pixel deltas mapped to lines, keyboard page scrolling, scroll-to-bottom on input, and correct behavior on the alternate screen.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Wheel and trackpad scroll through history in the primary screen
- [x] #2 Typing or new output policy returns the viewport to the bottom as configured
- [x] #3 Alternate screen applications receive wheel events as arrow keys or mouse reports as appropriate
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Built by an agent slice, then the missing end-to-end proof written by the coordinator because the deliverable was small and self-contained. Four defects were found along the way and fixed.
term.zig: ScrollConfig with a bounded() that clamps limits and refuses non-finite ratios; ReturnPolicy (on_typing default, on_typing_or_output, explicit_only) with the reason the default is on_typing; Viewport read back from Ghostty's scrollbar rather than cached, because a cached offset would be a second answer to a question asked every frame; ScrollAccumulator carrying sub-row travel and refusing NaN/Inf; MouseTracking read from the DEC modes. Alternate screen: no mouse tracking means cursor keys encoded through the terminal's own encoder (so DECCKM gives SS3, not CSI), mouse tracking means a mouse report through Ghostty's encoder.
platform.zig: SDL_EVENT_MOUSE_WHEEL translated into Event.wheel, plus Window.postWheel which pushes a real SDL event through SDL_PushEvent so a headless run exercises the real translation path.
Coordinator-written: --scroll-test, shaped like --grid-test and --self-test, printing what it measured and exiting non-zero when a check fails.
AC1 proven at pixel level: the check feeds 400 numbered lines, posts a real wheel through SDL, and reports offset 18 of 769 history rows, 2187 pixels differing between the bottom and the scrolled view, and the top row reading conduit-scroll-376. The screenshot was inspected: rows 376-391 in order, consecutive, real history rather than blanks. Trackpad half-deltas move nothing and do not run the view away, which is the safe property; the unit caveat is recorded below.
AC2 proven by a real-PTY test: a shell printing seq 1 400 and then late: lines on demand, scrolled to the top - the top row is byte-identical before and after while the offset grows, and a key encoded and written to the child returns the view to the bottom.
AC3 proven against a real program: less over a real file on a real pty. Alternate screen active, history_rows == 0, the wheel became nine SS3 cursor keys (27 bytes) written to less, less repainted to a later numbered line, and the viewport never moved. less put the terminal in application cursor mode, so the bytes were ESC O A / ESC O B rather than ESC [ A - which is the proof that routing the wheel through the terminal's own encoder was right, because hand-written bytes would have been ignored. Leaving the alternate screen restored the primary's offset exactly.
Defects found and fixed: (1) --scroll-test's first capture compared the app's reused readback buffer with itself, so it always reported zero differing pixels - the first capture is now copied before anything reads it again; (2) the check measured the viewport before SDL delivered the wheel, because a posted event is delivered when the queue is pumped - it now waits for the wheel event (Awaited gained a wheel case); (3) postWheel used @intFromEnum on an SDL constant that is not an enum, which had never compiled because nothing called it before; (4) two of the coordinator's own test expectations were wrong and were corrected, not weakened - a truncated-capture case that expected a difference in a pixel that was identical, and a trackpad assumption that treated 0.25 as a quarter notch when it is a quarter pixel.
Unit caveat, open for a decision before v0.1: SDL reports wheel travel with no unit, so platform calls a delta precise when it is fractional and term divides a precise delta by pixels_per_row (default 40). A device reporting whole numbers gets notch semantics (multiplied by lines_per_notch, 3), which is what a mouse wheel and a macOS trackpad produce; a device reporting fractional pixel counts gets pixel semantics, which is what a Windows precision touchpad produces. The pathological middle - small fractional values - barely moves the view. The check asserts the safe property (no runaway) and prints the real numbers rather than claiming more.
Also recorded: Ghostty enforces its line limit at whole-page granularity and never below one page, so a small limit is unenforceable; lib_vt exports MouseEncodeOptions but not the renderer Size its field holds, so term rebuilds it by field name and an upstream rename becomes a compile error in exactly one function.
Not verified here: macOS and Windows, real trackpad hardware, real GPU.

2026-10-06 flaky on a hosted runner (release run 37545204453): 'a real shell's output is scrolled back through with a wheel' waited for >5 history rows and then scrolled 18, so a slow first read of seq's output clamped the offset at 17. Fixed by waiting for >18 rows before turning the wheel.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Implemented scrollback history and viewport scrolling. Scrollback comes from Ghostty's own history; what Conduit adds is the viewport policy: a configurable, bounded scroll limit, wheel and trackpad deltas mapped to lines with sub-row travel carried rather than dropped, a return policy where typing returns to the bottom but a background program printing does not, and the alternate-screen rule where the wheel belongs to the program - as cursor keys through the terminal's own encoder when there is no mouse tracking, or as a mouse report when there is. Verified with real programs and real pixels: the new --scroll-test drives a real wheel through SDL, scrolls to offset 18 of 769 history rows, shows 2187 pixels changed and a top row of conduit-scroll-376, and the screenshot was inspected and shows rows 376-391 in order. A real shell proves the stick-and-return policy, and less proves the alternate-screen path by receiving nine SS3 cursor keys and repainting. 212/219 tests pass with 7 Windows-only skips, --grid-test and --self-test exit 0, formatting is clean.
<!-- SECTION:FINAL_SUMMARY:END -->
