---
id: TASK-17
title: 'Shell integration: cwd tracking and prompt marks'
status: Done
assignee: []
created_date: '2026-10-03 21:38'
updated_date: '2026-10-05 20:42'
labels:
  - terminal
  - shell
milestone: m-1
dependencies:
  - TASK-9
modified_files:
  - src/term.zig
  - src/main.zig
  - src/session.zig
  - build.zig
  - assets/shell-integration/bash/conduit.bash
  - assets/shell-integration/zsh/conduit.zsh
  - assets/shell-integration/fish/vendor_conf.d/conduit.fish
  - assets/shell-integration/README.md
priority: medium
ordinal: 17000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Consume OSC 7 (current working directory), OSC 133 (prompt/command marks) and title sequences, and ship optional shell integration scripts for bash, zsh, fish and PowerShell that emit them. Tracked cwd feeds new tabs, panes and the scratchpad.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Session exposes the current working directory when the shell reports it
- [x] #2 Integration scripts for bash, zsh and fish are injected or documented and can be disabled
- [x] #3 Prompt marks are recorded and available for jump-to-prompt later
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Add a concrete session.Session that owns the stable heap-allocated term.Terminal and optional PTY, exposes the reported working directory and prompt rows without copying terminal content, and destroys its resources in ownership order.
2. Replace App's separate terminal/child ownership with one session.Session while preserving the existing render, event, PTY and shell-integration paths; attach an asynchronously spawned PTY through Session.
3. Add allocator-clean session tests that feed validated OSC 7 and OSC 133 through the owned terminal and assert Session exposes cwd/reset and prompt rows.
4. Coordinator formats and runs zig build, zig build test, all five headless checks, and the real bash/zsh shell-integration tests. AC #1 may be checked only if the real App path uses Session and the shell-reported cwd is observed through it.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
User decision: bash and zsh are the shells to prove; fish is not to be tested. zsh 5.9 was installed on the dev box with the user's approval (/usr/bin/zsh) so it can be proven over a real PTY rather than skipped. The fish script and its injection may still ship, because the task names bash, zsh and fish, but fish is untested by decision and must be labelled that way in the README and the report.

Coordinator finish after ShellInject stalled (40 min, nothing on disk; killed). ShellEngine (term.zig) landed OSC 7 decoding with host/scheme validation and OSC 133 events. Coordinator wrote assets/shell-integration/ (bash, zsh, fish, README; MIT, Conduit-authored because Ghostty's bash/zsh scripts are GPLv3), the build.zig embed, injection in ChildSpec (bash --posix + ENV replay, zsh ZDOTDIR swap with restore, fish XDG_DATA_DIRS), --no-shell-integration, and Terminal.promptRows for jump-to-prompt.
Defects found along the way: relative ENV/ZDOTDIR paths named files that do not exist from the shell's cwd (now resolved absolute); zsh 'local status' aborted the precmd hook (status is read-only in zsh); the line-init re-mark was installed before user rc files and was lost to themes (now installed from the first precmd); the test harness broke right after typing exit and lost the final prompt's OSC 7, and one-line 'cd && false; echo' made the reported status the echo's.
Scope by user decision: bash and zsh proven, fish ships untested and the README says so; zsh 5.9 installed with approval. PowerShell has no script; it belongs to TASK-46, as the README states. Title sequences (OSC 0/2) were already consumed in TASK-9.
Validation: zig build test 259/266 (7 Windows-only skips); real bash and real zsh over a real PTY into Conduit's terminal report cwd /tmp, prompt starts, command ends with false's status 1, and >=2 prompt rows; --no-shell-integration reports none; break-and-revert of the injection turns both real-shell tests red. App smoke under xvfb: conduit with SHELL=bash and SHELL=zsh logs 'the shell reported its working directory: /tmp' and prompt marks at debug only; with --no-shell-integration the log has none. All five headless checks exit 0. Not verified: fish (by decision), macOS shells, Windows.

2026-10-05 reconciliation: reopened and AC #1 unchecked. OSC 7/133 parsing and shell scripts are present, but src/session.zig is still a scaffold: only Terminal exposes cwd/prompt rows, App logs the event, and cwd is not yet exposed by Session or fed to new tabs, panes or scratchpad.

2026-10-05 resumed implementation: the next unblocked audited gap is to make Session, rather than App, own the terminal/PTY and expose terminal-reported cwd. This is deliberately limited to the live-session ownership boundary already specified by architecture; workspace inheritance into future tabs/panes/scratchpad remains TASK-27/TASK-45 because those models do not yet exist.

2026-10-05 Session ownership repair: session.Session now owns a stable heap-allocated Terminal and its optional PTY, controls child attachment, coordinated resize and shutdown, and exposes validated workingDirectory, prompt state and prompt rows. App owns one Session instead of independent terminal/child handles; its cwd event path reads Session. Unit tests feed OSC 7/133 through the owned terminal and prove cwd exposure/reset and prompt rows.

Coordinator verification: zig build and zig build test exit 0; zig fmt --check . is clean; real hidden App runs under Xvfb with both bash and zsh log their shell-reported repository cwd through Session and prompt marks, then shut down cleanly; grid-test, self-test, scroll-test, mouse-test and clipboard-test all exit 0. Fish remains untested by the recorded user decision, PowerShell remains TASK-46, and cwd inheritance into tabs/panes/scratchpad remains TASK-27/TASK-45 because those models do not yet exist.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Implemented and verified the missing Session boundary for shell integration. Session now owns the terminal and optional PTY, exposes the validated OSC 7 working directory plus OSC 133 prompt state/rows, and App uses that Session through spawn, resize, rendering, input and shutdown. Tests cover cwd/reset and prompt rows; the full suite, both real bash/zsh App smokes under Xvfb, formatting, and all five Linux headless checks pass. Fish is still explicitly untested by prior user decision; PowerShell is TASK-46, and future workspace cwd inheritance remains TASK-27/TASK-45.
<!-- SECTION:FINAL_SUMMARY:END -->
