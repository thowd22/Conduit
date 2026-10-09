---
id: TASK-83
title: 'Windows: a second Ctrl+C does not end Claude Code under ConPTY'
status: Done
assignee:
  - '@claude'
created_date: '2026-10-08 22:04'
updated_date: '2026-10-09 02:49'
labels:
  - windows
  - input
  - agents
milestone: m-6
dependencies:
  - TASK-81
priority: medium
ordinal: 84000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
On the hosted Windows runner (TASK-81's windows-claude-observe.sh), Claude Code started as 'claude' in a PowerShell tab answers the first Ctrl+C with 'Press Ctrl-C again to exit', but a second Ctrl+C sent through the test driver after that text appears never ends it, so the check has to end it with taskkill. On Linux the same sequence ends Claude Code. Unverified hypothesis from the TASK-81 agent: Conduit encodes Ctrl+C in the kitty keyboard protocol form when the program has enabled it, and ConPTY's input parser may not translate that back to a console Ctrl+C event; or the second press is coalesced. Diagnose on the runner with a ConPTY unit test that sends two Ctrl+C presses to a program that reads console key events (e.g. a small PowerShell script using [Console]::ReadKey or Claude Code itself), compare the bytes Conduit writes with what a real Windows Terminal sends, and fix the encoder or the ConPTY input path so both presses arrive.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 On the hosted Windows runner both Ctrl+C presses sent through the driver reach Claude Code (the first shows its 'Press Ctrl-C again to exit' hint, the second starts its exit), proven by the windows-claude-observe.sh step; its taskkill fallback and warning stay because Claude Code 2.1.295's own shutdown hangs on that image with or without Conduit
- [x] #2 A ConPTY unit test proves two consecutive Ctrl+C presses reach a console program as two events, in both the legacy and kitty keyboard encodings Conduit can emit
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Diagnose on the hosted Windows runner before changing behaviour: temporary ConPTY probe tests in src/pty.zig (a [Console]::ReadKey reader and a VT-input byte reader receiving legacy 0x03, kitty CSI 99;5u (with and without releases) and win32-input-mode Ctrl+C; whether ConPTY forwards a program's CSI > 1 u / CSI ? u to Conduit), plus probes in windows-claude-observe.sh: a raw-mode Node and Bun program exiting on the second Ctrl+C typed through the driver, Claude Code's state after one press (does the hint clear) and after the double press (process, threads, children), and a claude --debug run's log.
2. Let the runner evidence pick the fix: the encoder (input/term) if a kitty form is emitted that ConPTY cannot parse, the ConPTY input path in pty.zig if bytes are lost, or the process side if Claude Code receives both presses but does not exit.
3. Turn the probe into the AC2 unit test (two Ctrl+C presses reach a console program as two key events in the legacy and kitty encodings), remove the temporary diagnostics, make the observe script gate on Ctrl+C ending Claude Code (no taskkill fallback).
4. Update AGENTS.md (TASK-81 paragraph) and docs, finalise with run ids.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Run 37865506186 (diagnostics): ReadKey reader under ConPTY gets 2 Ctrl+C events for legacy 0x03 x2 and for win32-input-mode, but 0 for Kitty CSI 99;5u (with or without releases); a VT-input reader gets the Kitty bytes raw. ConPTY forwards a program's CSI > 1 u and CSI ? u to the terminal, so Conduit would switch to Kitty encoding. Claude Code 2.1.295 reports kittyKeyboard=no (its CSI ? u query gets no reply through ConPTY), so it receives 0x03. A raw-mode Node probe receives both presses as byte 3 and exits. Claude Code: one press shows the hint and clears it after ~1 s (alive); the double press starts its exit and then it stays with CPU flat and a new thread in an Executive wait, never redrawing, for 15 s (main JS thread blocked in a synchronous call; its shutdown failsafe timer never fires). Its exit path calls drainStdin, which opens /dev/tty and reads it synchronously. Fix 1: the ConPTY backend writes a Kitty Ctrl+C report as 0x03 (release as nothing).

Run 37867442891: the new ConPTY test 'two Ctrl+C presses reach a Windows console program as two key events, legacy and Kitty' passes on windows-latest (the VT reader now gets bytes 3,3 for the Kitty pair). Node 22 and Bun 1.4.2 raw-mode probes typed through Conduit both get two byte-3 presses and exit; opening /dev/tty fails ENOENT in both, so Claude's drainStdin does not block there. Claude Code 2.1.295 still does not exit on the double press inside Conduit, and also not under a bare pseudoconsole with no terminal behind it (the pty probe: hint after one press, still running 30 s after the second and after 80 more keys). The SendKeys classic-console comparison failed to focus the window.

Run 37869071981 (third and last diagnostic iteration): Claude Code 2.1.295 under a bare pseudoconsole (no terminal) writes its terminal-mode resets (CSI > 4m, ?2031l, ?2004l, mouse off, cursor show) after the second Ctrl+C and then never exits; Enter and a third Ctrl+C change nothing. In a classic console window (Start-Process, no ConPTY) two Ctrl+C key events written with WriteConsoleInputW also leave it running 15 s later. Inside Conduit: hint shown and cleared after one press, double press leaves it with flat CPU and an Executive-wait thread; Enter and a third press do nothing. Conclusion: both presses reach Claude Code; its own shutdown hangs on this Windows runner independent of Conduit and of ConPTY. Per the stop rule the taskkill fallback and warning stay in windows-claude-observe.sh (comment and warning text now say why). AC2 is met: the ConPTY test 'two Ctrl+C presses reach a Windows console program as two key events, legacy and Kitty' passed on windows-latest in runs 37867442891 and 37869071981; Linux: 'every Ctrl+C the encoder can produce reaches a pseudoconsole as Ctrl+C' (term) and 'a Kitty Ctrl+C report is found for the pseudoconsole, and nothing else is' (pty) pass. AC1 is not met and cannot be met from Conduit; it needs a Claude Code fix or a decision to drop or reword it.

Cleaned branch, run 37870374778 (success): both new pty tests OK on windows-latest; the observe step still gates idle/done and ends Claude Code with taskkill plus the reworded warning.

2026-10-09 (coordinator): the user chose to reword criterion 1 rather than wait for an upstream Claude Code fix. The original wording (the observe step ends Claude Code with two Ctrl+C presses, no taskkill, no warning) cannot be met from Conduit: runs 37867442891 and 37869071981 show both presses arriving and Claude Code 2.1.295 hanging in its own exit under a bare pseudoconsole and in a classic console with no Conduit involved. Criterion 1 now records what was proven; the taskkill fallback stays until Claude Code exits cleanly on Windows. Pasted text cannot trigger the Kitty rewrite: term.preparePaste rejects every control byte, including ESC, before the PTY sees it.
<!-- SECTION:NOTES:END -->

## Comments

<!-- COMMENTS:BEGIN -->
author: @claude
created: 2026-10-09 01:33
---
AC1 blocked: Claude Code's exit hangs after the second Ctrl+C on the Windows runner even outside Conduit (bare ConPTY, classic console). Needs a decision: wait for an upstream fix, reword AC1, or close.
---
<!-- COMMENTS:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
ConPTY drops Kitty-encoded key reports, so a Kitty Ctrl+C never reached a console program; the ConPTY backend now writes a Kitty Ctrl+C press or repeat as 0x03 (pty.conPtyInput) and every other key as encoded. Verified by the Windows ConPTY test (two presses, legacy and Kitty, runs 37867442891, 37869071981, 37870374778), a term test over all 32 Kitty flag sets, and the gated observe step. Both presses reach Claude Code on the runner; its exit hang is upstream (reproduced without Conduit), so the observe step keeps taskkill with a warning.
<!-- SECTION:FINAL_SUMMARY:END -->
