---
id: TASK-8
title: PTY abstraction with POSIX backend
status: Done
assignee:
  - '@omp'
created_date: '2026-10-03 21:38'
updated_date: '2026-10-04 23:30'
labels:
  - pty
milestone: m-1
dependencies:
  - TASK-4
modified_files:
  - src/pty.zig
priority: high
ordinal: 8000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Define the cross-platform Pty interface (spawn with argv/env/cwd, read, write, resize, child exit notification, kill) and implement the POSIX backend for Linux and macOS. Reads run off the render thread and deliver bytes to the owning session.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Integration test spawns a shell, writes a command and reads the expected output
- [x] #2 Resize is propagated and visible to the child (stty size)
- [x] #3 Child exit status is reported and file descriptors are not leaked
- [x] #4 Interface has no POSIX-only types so a ConPTY backend can implement it
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Interface is Pty = *anyopaque + *const VTable, so criterion 4 is structural rather than conventional: spawn (backend selector), SpawnRequest{argv, env, cwd, size}, WindowSize, Signal, ExitStatus, ChildState, a 12-value Error with no OS error union, and seven methods (write, resize, kill, takeBytes, state, waitReadable, destroy).
POSIX backend: /dev/ptmx with TIOCSPTLCK/TIOCGPTN on Linux, posix_openpt/grantpt/unlockpt/ptsname on macOS; initial TIOCSWINSZ on the slave before the fork; hand-rolled fork + dup2 x3 + setsid + TIOCSCTTY + chdir + execve (raw syscalls on Linux, libc externs on macOS); PATH resolution of argv[0] against the child's own PATH before forking; a close-on-exec status pipe so a failed execve returns error.SpawnFailed with a logged errno instead of a shell dying at 127.
Threading: one read thread per terminal owns the blocking read and the only waitpid; bytes cross through a lock-free SPSC ring allocated once at spawn (64 KiB) with monotonic counters; child end crosses as one packed u64 atomic; neither side allocates after spawn. Child-exit is published as a completion rather than a callback or a pollable fd, because the read thread is the only thread that can block on the pty, is the only one that sees the hangup and the only one that can reap, so a thread can never double-reap. The owner polls state() and is woken through a non-blocking pipe by waitReadable.
AC1: real run with /bin/sh -s, a fixed env (PATH, HOME, TERM, LANG) and cwd /; wrote a printf command and read back 58 bytes showing the line discipline echo and the shell's output.
AC2: after stty size the child reported 24 80; after resize to 40x100 it reported 40 100; after resize(0,0) it reported 1 1, clamped rather than lost. Linux ioctl numbers were settled empirically: _IO('T',20)=0x5414 works, the BSD _IOW('t',103,...) value returns ENOTTY on Linux.
AC3: /bin/sh -c 'exit 42' reported .exited = .{.code = 42}; kill(.kill) on a blocked shell reported .exited = .{.signal = .kill}; a second kill(.hangup) returned Closed rather than signalling a reaped pid. Descriptor count measured with an fcntl(F_GETFD) probe implemented outside the module: 3 before, 6 with one live terminal (+3: master and both ends of the wake pipe), 3 after destroy, 3 after five more spawn/destroy cycles. ps -eo stat showed 0 defunct processes after the suites.
AC4: a test walks the typeInfo of Pty and every VTable method and rejects any leaf type outside Conduit's own type set or any error set that is not exactly Error; a second test defines FakeTerminal, a backend written only in Zig types that records writes, resizes, signals, handed-over bytes, state and destruction, and drives all seven methods through the interface.
22 tests in the pty module; zig build test 109/109; zig fmt --check clean; cross-compiles with zig test --test-no-exec for aarch64-macos, x86_64-macos and x86_64-windows.
Coordinator verification: pty-test 22 pass in the full suite, build green, fmt clean.
Not verified here: macOS and Windows at runtime (compile-only), and no SSH or remote backend (that is TASK-43).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Implemented the cross-platform PTY interface and its POSIX backend in src/pty.zig. The interface is a vtable over Zig-owned types with no POSIX-only type anywhere on it, proven two ways: a test that walks the interface's type info and rejects foreign types, and a fully non-POSIX fake backend that implements all seven methods and is driven through the interface. The backend spawns with argv/env/cwd and size, reads, writes, resizes, kills and reports child exit, and Linux ioctl values were settled empirically rather than assumed. Reads run off the render thread on a dedicated thread that also owns the only waitpid, delivering bytes through a lock-free ring allocated once at spawn; child exit is published as a completion so no thread can double-reap. Verified: a real shell spawns, runs a written command and its output comes back; stty size reports 24 80 then 40 100 after a resize, and 1 1 after a resize to zero; exit code 42 and a killed child are reported correctly; descriptor count returns to its baseline after five spawn/destroy cycles with no defunct processes.
<!-- SECTION:FINAL_SUMMARY:END -->
