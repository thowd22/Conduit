---
id: TASK-83
title: 'Windows: a second Ctrl+C does not end Claude Code under ConPTY'
status: In Progress
assignee:
  - '@claude'
created_date: '2026-10-08 22:04'
updated_date: '2026-10-09 00:34'
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
- [ ] #1 On the hosted Windows runner the windows-claude-observe.sh step ends Claude Code with two Ctrl+C presses through the driver, with no taskkill fallback and no warning
- [ ] #2 A ConPTY unit test proves two consecutive Ctrl+C presses reach a console program as two events, in both the legacy and kitty keyboard encodings Conduit can emit
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Diagnose on the hosted Windows runner before changing behaviour: temporary ConPTY probe tests in src/pty.zig (a [Console]::ReadKey reader and a VT-input byte reader receiving legacy 0x03, kitty CSI 99;5u (with and without releases) and win32-input-mode Ctrl+C; whether ConPTY forwards a program's CSI > 1 u / CSI ? u to Conduit), plus probes in windows-claude-observe.sh: a raw-mode Node and Bun program exiting on the second Ctrl+C typed through the driver, Claude Code's state after one press (does the hint clear) and after the double press (process, threads, children), and a claude --debug run's log.
2. Let the runner evidence pick the fix: the encoder (input/term) if a kitty form is emitted that ConPTY cannot parse, the ConPTY input path in pty.zig if bytes are lost, or the process side if Claude Code receives both presses but does not exit.
3. Turn the probe into the AC2 unit test (two Ctrl+C presses reach a console program as two key events in the legacy and kitty encodings), remove the temporary diagnostics, make the observe script gate on Ctrl+C ending Claude Code (no taskkill fallback).
4. Update AGENTS.md (TASK-81 paragraph) and docs, finalise with run ids.
<!-- SECTION:PLAN:END -->
