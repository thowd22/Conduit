---
id: TASK-6
title: Logging and diagnostics infrastructure
status: Done
assignee:
  - '@omp'
created_date: '2026-10-03 21:38'
updated_date: '2026-10-04 22:02'
labels:
  - infra
milestone: m-0
dependencies:
  - TASK-4
modified_files:
  - src/main.zig
priority: medium
ordinal: 6000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Scoped, leveled logging to a per-run log file and stderr, with a debug flag/env var, plus crash/panic capture that writes a report including the log tail. Agents rely on these logs in the test loop.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Log level and destination are configurable by flag and environment variable
- [x] #2 A panic writes a crash report with stack trace to a documented location
- [x] #3 Log file location is discoverable from the command line
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented inside src/main.zig (the app module) and only there. A new module was not created because docs/architecture.md fixes the module list at 15 and adding one is an architecture change for the user to agree to; the agent agreed with that call and noted the natural moment to split it (when platform/config land and a per-workspace destination is possible).
Interface: --log-level=err|warn|info|debug (also error/warning, case-insensitive), --log-file=<path>, --log-dir=<dir>, --print-log-path, --help. Env equivalents CONDUIT_LOG_LEVEL, CONDUIT_LOG_FILE, CONDUIT_LOG_DIR, plus TMPDIR/TEMP/TMP and a .zig-cache/conduit fallback. Precedence flag > env > built-in default; an empty env var counts as unset; a bad flag or level exits 2 with usage and never panics. The per-run file is named run-<timestamp>-<unique>.log so concurrent test runs never collide.
Safety: sensitive content (terminal contents, clipboard, credentials, agent prompts) goes through sensitiveLog, which takes no level argument, and emit() refuses to write the .sensitive scope at any level other than debug. The ceiling is a clamp in the single choke point every line passes through, not a convention, so no caller can promote such content by choosing --log-level. Three tests cover it.
Deliberate cost: std_options.log_level is unconditionally .debug so a runtime level can turn detail up; the alternative would make --log-level=debug a no-op on a release binary, which is exactly what the test loop needs. Release size grows as a result.
Coordinator verification on this box: zig fmt --check . clean; zig build exit 0; zig build test 76/76 steps and 72/72 tests with app-test at 24 (was 1); ./zig-out/bin/conduit --log-level=err prints nothing; --print-log-path prints the per-run path headlessly at exit 0; CONDUIT_LOG_LEVEL=info combined with --log-level=err prints nothing, proving the flag beats the environment.
Panic path proven for real, not simulated: the agent built a throwaway copy of src/main.zig in /tmp with one added out-of-bounds index, keeping the shipped panic/std_options/sink code verbatim. The binary exited 134 and wrote run-20261004T220033Z-75613a.crash.txt containing the panic message, a resolved stack trace and a --- log tail --- section with the real log lines. The in-tree test additionally drives writeCrashReport with a known tail, and a second test covers the no-log-file case.
Not verified here: macOS and Windows paths never executed on this box. The panic handler, the exclusive file create and std.process.Args.Iterator.initAllocator (the Windows-requiring form) are written cross-platform but unexercised.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Implemented logging and diagnostics in the app module: scoped leveled logging to both stderr and a per-run log file, with --log-level/--log-file/--log-dir and CONDUIT_LOG_LEVEL/CONDUIT_LOG_FILE/CONDUIT_LOG_DIR, flag-over-environment precedence, and --print-log-path so the log file is discoverable headlessly before any window exists. A panic now writes a crash report containing the message, a resolved stack trace and the tail of that run's log, then hands over to the default panic handler so a failed report never costs the original message. Sensitive content (terminal contents, clipboard, credentials, agent prompts) can only be logged at debug level, enforced by a clamp in the single choke point rather than by convention. Verified: 72/72 tests pass with 23 new tests, formatting clean, the flags and environment variables demonstrably change the output, and the panic path was proven by a real binary that wrote a real crash report with a real log tail.
<!-- SECTION:FINAL_SUMMARY:END -->
