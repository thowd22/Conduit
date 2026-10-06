---
id: TASK-12
title: Keyboard input encoding and IME
status: Done
assignee:
  - '@codex'
created_date: '2026-10-03 21:38'
updated_date: '2026-10-05 23:47'
labels:
  - input
milestone: m-1
dependencies:
  - TASK-7
  - TASK-9
modified_files:
  - src/term.zig
  - src/input.zig
  - src/platform.zig
  - src/main.zig
priority: high
ordinal: 12000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Translate platform key events into terminal input: legacy encoding, modifyOtherKeys, Kitty keyboard protocol, application cursor/keypad modes, using libghostty's key encoder where available. Support dead keys and IME composition with a preedit display.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Ctrl, Alt and function key combinations work in vim, tmux and readline
- [x] #2 Kitty keyboard protocol is honored when an application enables it
- [x] #3 IME composition text is shown inline and committed correctly
- [x] #4 Unit tests cover the key encoding table
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Keep input.Composition as the sole owner of borrowed SDL preedit/candidate/commit data and preserve the existing rule that preedit bytes never reach the PTY.
2. Add sentinel-borrowed platform test seams for SDL text-editing and committed-text events. Their payload lifetime remains with the caller until the queued event is pumped; production event translation is unchanged.
3. Give App a reusable production ui.Canvas sized with the terminal grid. Compose the live preedit at the terminal cursor with terminal font/theme styling, clipping safely at the right edge; invalidate the terminal/UI layers when composition starts, changes, cancels or commits so stale pixels are restored. Keep native candidate UI and anchor it to the composition caret.
4. Add a deterministic Linux --ime-test that drives editing and commit through SDL, proves the preedit appears on the shared framebuffer, proves its bytes never reach a real child, proves committed UTF-8 reaches the child exactly once, and covers wide text/right-edge clipping and overlay removal.
5. Coordinator formats, builds, runs the complete unit/integration and headless suites, inspects the IME screenshot, records platform limitations, and finalizes only against demonstrated evidence.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
AC #3 deliberately left unchecked: 'IME composition text is shown inline and committed correctly'. The commit half is proven - real SDL composition events flow through the real event path, the preedit is held for the renderer and is never sent to the child, offsets are clamped safely, candidates are bounded and dropped when composition ends - but drawing the preedit on screen needs the UI toolkit, which is M2 (TASK-18/19), and no real Japanese or Chinese input method exists on this headless box. Ticking it now would be claiming work that does not exist.
Seam, as decided before implementation: Conduit does not write its own encoder. ghostty-vt exports input.encodeKey and KeyEncodeOptions.fromTerminal reads all eight modes; term is the only module wired to ghostty-vt, so Terminal.encodeKey is a forwarder in term.zig and no third-party type leaks upward. IME preedit is display-only by construction, not by a Conduit-side check: with composing set the encoder emits nothing in either protocol, so a preedit cannot reach the PTY even if a caller tried.
AC1 driven against three real programs, each asserted on state the program changed itself (an echo would only prove bytes came back; all waits read parsed grid state, never raw bytes):
 - vim 9.1: 'i' -> insert mode, last row '-- INSERT --'; 'hello world' one key at a time -> row 0 exactly 'hello world'; ctrl+u -> \x1b[27;5;117~ (modifyOtherKeys=2, which vim enabled with \x1b[>4;2m) deleted the inserted text; escape -> left insert mode, '-- INSERT --' gone; F1 -> \x1bOP opened vim's help window ('*help.txt*  For Vim version 9.1...').
 - readline (bash --norc --noprofile -i, INPUTRC=/dev/null): alt+b -> \x1bb; with 'echo one two' typed, then X and Enter, the shell RAN 'echo one Xtwo' and printed 'one Xtwo' - a dropped key would give 'one twoX' and a plain b would give 'one twob'.
 - tmux 3.6 on its own socket in a per-run dir: ctrl+b then c -> window 1 created, status '[conduit] 0:probe- 1:sh*'; F1 -> window 2; alt+n -> star moved back to window 0. Honest caveat recorded by the slice: tmux 3.6 binds no function or meta key in its root table, so the test adds exactly two bindings (bind -n F1 new-window, bind -n M-n next-window); what that proves is the encoding, since a binding on any other key would not have fired. ctrl+b uses tmux's own defaults. No tmux process, socket or temp dir is left behind (verified).
 - ctrl+c: a child with nothing reading its input died of SIGINT, reported as ChildState{.exited = .{.signal = .interrupt}}.
AC2 byte-level: ctrl+c \x03 legacy vs \x1b[99;5u Kitty; ctrl+enter \x1b[27;5;13~ vs \x1b[13;5u; enter under report-all \x1b[13u; Kitty release \x1b[15;1:3~ while legacy release encodes empty. Kitty is enabled by feeding the program's own \x1b[>1u and read back through keyModes().
AC4: intent layer and encoding table both covered - every named key maps to the terminal key of the same name, character vs control keys, the modifier matrix, C0/DEL/C1 rejection at its boundaries, press/release/repeat as three different things, and the composing-press property across every Kitty flag combination.
Two real defects found in test helpers and fixed: waitForExit never drained the child, so waitReadable answered yes forever and the loop burned its 5s budget in 29ms/2400 rounds; and waitFor bounded by round count rather than a monotonic clock, which is only a deadline if every round blocks fully.
Known limitation reported, not worked around: launching the test binary as a background job of a non-interactive shell makes it inherit SIGINT=SIG_IGN, so the ctrl+c child ignores the interrupt and that one test fails. A normal foreground 'zig build test' is unaffected; nothing was weakened to cover it.
Also noted: modifier side (left/right) is not tracked, so macOS Option-as-Alt will need it later; and focus-event encoding is not wired, which is outside this task's criteria.
Coordinator verification: zig fmt --check . clean; zig build test 198/198; no tmux process, socket or temp directory left behind after a run.
Not verified here: macOS and Windows (Windows skips, no PTY backend), any real input method, and a machine without vim, bash or tmux - where pty.spawn reports SpawnFailed and the test fails loudly rather than skipping.

2026-10-05 reconciliation: reopened. The prior note that the IME commit half is proven is false in the current app: onKey always passes composing=false, text_input discards its payload, editing/candidate events are ignored, and App does not own Composition or start text input. Lower-level translation/state-machine tests exist, but the real app path is missing.

2026-10-05 progress: wired the app-side IME path. App now owns Composition, starts/stops native text input, points the OS candidate area at the terminal cursor, preserves preedit/candidates across events, passes live composing state to key translation, and commits exact UTF-8 through the existing single child-write site. Committed text uses a borrowed same-iteration slot rather than the 256-byte key buffer, with a regression test longer than that buffer. The first coordinator build exposed latent const receivers on mutating platform text-input methods; their receivers were corrected. Verification: zig build, zig build test, zig fmt --check ., and xvfb-run grid-test/self-test/scroll-test/mouse-test/clipboard-test all exited 0. AC #3 remains unchecked: inline preedit drawing and a real IME run are still absent.

2026-10-05 resumed after TASK-18 completion. Two independent audits agree the only remaining code gap is inline preedit rendering; the existing app-side composition, candidate, suppression and committed-text path is already present. TASK-12 is the next dependency-critical slice because it directly gates TASK-20.

2026-10-05 inline preedit completion evidence: App now owns a reusable grid-sized UI Canvas and renders Composition preedit inline at the real terminal cursor with accent underline and selected-range styling. The native candidate area follows the grapheme-measured preedit caret. Editing, cancellation and commit invalidate both layers; removal restores the terminal framebuffer exactly; wide CJK preedit clips only on whole graphemes at the right edge; unchanged state draws zero idle frames/GPU work. New sentinel-borrowed platform seams post real SDL text-editing and text-input events without allocation. The deterministic --ime-test proves preedit bytes write nothing to a real PTY child, committed Japanese UTF-8 is written exactly once and received byte-for-byte, and commit removes the overlay. Coordinator verification: zig build passed; zig build test passed 294 runnable tests with 7 existing platform skips; all seven Linux headless checks passed; formatting and Backlog integrity passed; final preedit screenshot was visually inspected. Limitation: no physical Japanese/Chinese input method or macOS/Windows runtime was available, so the test injects the exact SDL events those input methods produce.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Completed keyboard encoding and IME support. Conduit uses ghostty-vt terminal key encoding for legacy, modifyOtherKeys and Kitty modes; real program integration covers vim, tmux and readline. App-owned composition state now drives an allocation-free inline preedit overlay with selection styling and native caret anchoring, while preedit bytes remain structurally isolated from the PTY. A deterministic real SDL/PTY/framebuffer check proves cancellation, right-edge clipping, exact-once UTF-8 commit, overlay restoration and idle behavior.
<!-- SECTION:FINAL_SUMMARY:END -->
