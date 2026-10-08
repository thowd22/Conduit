---
id: TASK-16
title: Windows ConPTY backend
status: Done
assignee:
  - '@claude'
created_date: '2026-10-03 21:38'
updated_date: '2026-10-08 00:28'
labels:
  - pty
  - windows
milestone: m-1
dependencies:
  - TASK-8
modified_files:
  - src/pty.zig
priority: medium
ordinal: 16000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement the Pty interface on Windows using ConPTY (CreatePseudoConsole), including process creation with the pseudoconsole attribute, overlapped pipe IO, resize and exit detection.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Integration test spawns cmd.exe or pwsh and round-trips a command on Windows CI
- [x] #2 Resize is propagated to the pseudoconsole
- [x] #3 Child exit is detected and handles are released
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Fix the ConPTY runtime on the Windows runner: the input pipe write returns ACCESS_DENIED (open the pipe ends with the right access/overlapped flags, keep the console handle alive) and resize hangs (ResizePseudoConsole on the owner thread while the reader blocks; use overlapped reads or a dedicated reader thread with cancellation).
2. Iterate through workflow_dispatch runs of ci.yml on a pushed branch, reading the per-binary diagnostics; cross-compile locally for x86_64-windows-gnu to keep compile errors out of the loop.
3. Integration tests on Windows CI: spawn cmd.exe or pwsh, round-trip a command, propagate a resize, detect exit and release handles (handle-count test).
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
STATUS: implemented, compiled, NOT verified at runtime. All three acceptance criteria are deliberately left UNCHECKED because each one needs a real Windows runtime, and this box is Linux with no remote and no commits, so GitHub's windows-latest runner cannot be reached from here either.
Implemented in src/pty.zig only: ConPTY via CreatePseudoConsole with CreateProcessW and the PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE startup attribute (EXTENDED_STARTUP_INFO_PRESENT), overlapped pipes on both ends with GetOverlappedResult and CancelIoEx, events for completion, ResizePseudoConsole on resize, GetExitCodeProcess for exit, TerminateProcess for kill, and SetHandleInformation clearing HANDLE_FLAG_INHERIT so the console handles are not inherited. Every API is declared against the Windows SDK headers Zig bundles (any-windows-any: consoleapi.h, namedpipeapi.h, fileapi.h, ioapiset.h, synchapi.h, processthreadsapi.h, winbase.h) and each is cited to Microsoft Learn in the slice's report - nothing was written from memory of Win32.
The same thread contract as the POSIX backend is honoured: one read thread owns the overlapped read and the single exit-code observation, bytes cross through the same lock-free ring allocated once at spawn, child end is published as a completion rather than a callback, and nothing allocates after spawn.
Windows-runnable tests were written and skip on Linux with an explicit reason rather than silently passing; a handle-leak test uses GetProcessHandleCount.
Coordinator verification on this box: zig fmt --check src/pty.zig clean; zig test src/pty.zig = 23 passed, 7 skipped, 0 failed (the skips are the Windows-only cases, each stating its reason); zig test --test-no-exec -target x86_64-windows src/pty.zig exits 0, so the Windows path compiles and type-checks.
What is still needed, and by whom: a Windows runner to execute it. The CI workflow already has windows-latest in its matrix, so pushing the repository is what unblocks ACs 1-3. Until then no criterion may be ticked on Linux evidence.

2026-10-05 reconciliation: reopened because all three ACs require Windows runtime evidence and remain unchecked. The ConPTY path cross-compiles and Windows-only tests exist, but no Windows runner has executed them.

Agent: fixed swapped CreatePseudoConsole pipe arguments, reversed input pipe ends (ACCESS_DENIED), non-overlapped anonymous output pipe (resize hang) -> named overlapped pipe, closed Conduit's copies of console ends, STARTF_USESTDHANDLES with null handles, exit-watcher thread closing the pseudoconsole under an SRW lock, drain to BROKEN_PIPE before publishing exit. Evidence: CI run 37706523144 Windows pty-test 20 pass / 13 skip (cmd.exe round trip, PowerShell-observed resize, exit code 42, kill 137, handle-count release). Coordinator 2026-10-08: merged as a0ec9c3 (branch task-16-conpty); Linux 898/911 unit tests green; Windows cross-compile still fails in agent modules (std.posix.pollfd) and backlog tests on CRLF/watch: TASK-5 close-out.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Windows ConPTY backend made to work: correct pipe plumbing, overlapped named output pipe, no inherited std handles, exit-watcher closing the pseudoconsole, final output drained before exit; proven on the hosted Windows runner by the ConPTY integration tests for round trip, resize, exit and handle release.
<!-- SECTION:FINAL_SUMMARY:END -->
