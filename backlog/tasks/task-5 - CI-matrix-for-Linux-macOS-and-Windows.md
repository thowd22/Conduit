---
id: TASK-5
title: 'CI matrix for Linux, macOS and Windows'
status: In Progress
assignee:
  - '@claude'
created_date: '2026-10-03 21:38'
updated_date: '2026-10-08 00:32'
labels:
  - infra
  - ci
milestone: m-0
dependencies:
  - TASK-4
modified_files:
  - .github/workflows/ci.yml
  - .gitattributes
priority: medium
ordinal: 5000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
GitHub Actions workflow that installs the pinned Zig version and runs build and unit tests on all three operating systems, with caching of the Zig cache and dependencies.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Workflow runs 'zig build' and 'zig build test' on ubuntu, macos and windows runners
- [x] #2 Zig version in CI comes from one pinned source of truth
- [x] #3 A failing unit test fails the workflow
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Reproduce the Windows and macOS build failures locally by cross-compiling (zig build -Dtarget=x86_64-windows-gnu / -Dtarget=aarch64-macos / x86_64-macos) and from the latest ci.yml run logs.
2. Fix build.zig/dependency options and OS-conditional backend code (platform, pty ConPTY, font discovery) so zig build and the unit-test binaries compile for all three targets; tests that are Linux-only skip on other OSes rather than fail.
3. Make ci.yml cache the Zig toolchain and global cache, run zig build and zig build test on ubuntu/macos/windows, and not be cancelled by every push (concurrency per ref, matrix completes).
4. Trigger with workflow_dispatch, iterate until all three legs are green; record the run id.

Close-out (2026-10-08): fix the remaining non-PTY failures on the Windows leg (agent modules' std.posix.pollfd via a portable poll seam inside agent/; backlog fixture CRLF normalisation and the live-watch test on Windows) and the macOS leg (codex websocket test hang, tmux keys test, /private/tmp realpath comparison, backlog live watch), iterate through workflow_dispatch on a branch, and record the run id where all three legs are green.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Workflow at .github/workflows/ci.yml, matrix ubuntu/macos/windows-latest, steps: resolve pinned Zig from build.zig.zon, setup-zig, cache, zig fmt --check, zig build, zig build test --summary all.
Single source of truth: a 'Resolve the pinned Zig version' step seds .minimum_zig_version out of build.zig.zon into $GITHUB_ENV as ZIG_VERSION; every later step reads ${{ env.ZIG_VERSION }}. A matrix entry was rejected because GitHub evaluates matrix values before any step runs, so a leg cannot be derived from a file; vars.* was rejected because repository variables live in the GitHub UI, not the tree. A further step compares 'zig version' against the pin and fails on mismatch, so a wrong download fails loudly instead of testing on another toolchain. The literal 0.16.0 appears nowhere in the workflow - verified: grep -c '0\.16\.0' returns 0.
Coordinator verification: python3 yaml.safe_load parses the file; jobs=build; matrix.os=[ubuntu-latest, macos-latest, windows-latest]; the seven named steps are present.
Failure path proven by the agent in a throwaway copy of the tree under /tmp (never the shared working tree): a deliberately failing unit test made zig build test exit non-zero. The agent also verified the run/step shell and CRLF-safety choices: shell: bash set explicitly on every step, POSIX ERE sed so BSD and Git-for-Windows behave the same, and the workflow never references an artifact path so there is no path-separator risk.
Added .gitattributes (coordinator) pinning build.zig, build.zig.zon and *.zig to LF, because a CRLF checkout on the Windows runner would break 'zig build' there. The agent flagged that risk and did not own the file.
Not verifiable here: the workflow has never run on GitHub, and nothing about the macOS or Windows legs executed on this headless Ubuntu box. Only a real CI run settles action availability, whether the SDL3 source build completes on those images, and what setup-zig resolves for Apple Silicon macos-latest.

2026-10-05 reconciliation: reopened and AC #1 unchecked. The workflow is configured for ubuntu, macOS and Windows, but this repository has no commits and the workflow has never run; static YAML inspection is not runtime evidence for the three runners.

2026-10-06 first hosted runs after the initial push: ubuntu-latest passes zig fmt/build/test; windows-latest fails in 'zig build' compiling Ghostty's C++ SIMD sources (zig-pkg/ghostty/src/simd/codepoint_width.cpp via Highway) against Zig 0.16's bundled clang headers: 'argument unused during compilation: -nostdinc++ / -fno-rtlib-defaultlib' followed by 109 errors in mmintrin.h/immintrin.h ('function-style cast to a builtin type can only take one argument'). The pinned-Zig resolution and version check worked on Windows (runs 37539118625 and 37535520847). The macOS leg had not finished before the runs were superseded; see later runs on main for its result. Windows build repair belongs with TASK-49/TASK-16; AC1 stays unchecked.

2026-10-07 (merged as ead499d..a499040): build.zig defaults a Windows host to an explicit <arch>-windows-gnu target (Zig 0.16's fully native Windows target fails every C source); macOS PTY fixes (TIOCSWINSZ 0x80087467, TIOCSCTTY 0x20007461, ioctl request c_ulong, O_NONBLOCK 0x4) and DriverTransport.stop self-connect because Darwin's shutdown does not wake accept; ConPTY string/termination bugs; OS-aware test expectations (Option-as-Alt, Command rows, BASH_SILENCE_DEPRECATION_WARNING, Homebrew tmux PATH, APPDATA, path separators); ci.yml no longer cancels a started matrix, 75/40-minute timeouts, cache paths, brew tmux, per-binary diagnostics with a 240 s alarm. Evidence: ubuntu green; macOS build green and 629/643 tests with only the tmux PATH failures (fixed, unconfirmed); Windows builds and passes every module except the ConPTY runtime tests (write ACCESS_DENIED, resize hang) which are TASK-16's scope. AC1 stays open until one run is green on all three OSes.
<!-- SECTION:NOTES:END -->
