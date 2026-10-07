---
id: TASK-75
title: >-
  PTY reader can lose its wakeup on the shared wake pipe and stall a session
  forever
status: Done
assignee:
  - Claude
created_date: '2026-10-07 14:28'
updated_date: '2026-10-07 14:48'
labels: []
dependencies: []
type: bug
ordinal: 76000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Hosted gate run 37635552480 (commit bc7bbea) failed the workspace unit test "a real 4 MiB PTY flood is fully consumed within the per-wake budget in bounded time": the owner consumed 1,202,944 of 4,194,304 bytes and then saw nothing for the rest of the 10 s deadline while every other test binary finished in milliseconds, and the same test ran green on the five previous gates and in 0.38 s locally. Root cause in src/pty.zig PosixPty: the read thread and the owner thread share one nonblocking wake pipe (wake[0]/wake[1]) for both directions. When the byte ring is full the reader checks for room, then blocks in pollOne(wake[0], -1) waiting for takeBytes to notify. If, between that check and the poll, the owner takes every byte, notifies, empties the ring, and then (needsPump false) enters waitUntilPending whose drainWake consumes that very byte, the reader blocks with no byte pending and no one left to write one: takeBytes notifies only when it took something, publishEnd runs on the stalled reader thread, and the child blocks writing to the slave. The session freezes until destroy. The Windows backend already separates the directions (space, owner_wake, stop events). A second, smaller race sits in session.drainChildOutput: a zero take followed by state()==exited marks the child quiescent, but bytes enqueued and the end published between those two calls (up to the 64 KiB ring) are stranded.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 PosixPty wakes each direction on its own channel: the owner-to-reader signal (room made, stop requested) can only be consumed by the read thread and the reader-to-owner signal (bytes queued, child ended) only by the owner thread, so no wakeup can be consumed by the thread it was not meant for
- [x] #2 A unit test in pty.zig reproduces the lost-wakeup shape deterministically or statistically (full ring, owner takes all and drains its own wake channel before the reader re-checks) and fails against the single-pipe design
- [x] #3 session.drainChildOutput observes the child state before the take so a zero take marks quiescence only when the end was already published before the ring was seen empty, with a unit test using a fake backend that publishes bytes and the end between the two observations
- [x] #4 zig build test passes; the 4 MiB real-flood workspace test still completes in bounded time; the full Linux gate (built-in checks and zig build e2e) passes locally and on the hosted runner
- [x] #5 docs/architecture.md and AGENTS.md describe the two-channel wake design
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. pty.zig PosixPty: split the shared wake pipe into owner_wake (reader->owner, drained only in waitUntilPending) and reader_wake (owner->reader, drained only by the read thread), route takeBytes/destroy notifies to reader_wake and enqueue/publishEnd notifies to owner_wake; fix the doc comment.
2. session.zig drainChildOutput: observe state() before takeBytes so a zero take marks quiescence only when the end was already published.
3. Tests: deterministic/statistical lost-wakeup reproduction in pty.zig (fails on single pipe), fake-backend ordering test in session.zig (fails before the reorder).
4. Coordinator: full local gate, docs (architecture.md, AGENTS.md), commit, push, hosted gate green.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Opus subagent fix in pty.zig/session.zig; coordinator applied the tmux test config change in term.zig. Root cause confirmed by a deterministic test: a test-only ReaderPark gate parks the reader between its failed append and its wait for room; the owner takes everything and runs waitReadable (its drain path); on the single pipe the reader never wakes (pty-test 24 pass, 1 fail), with per-direction pipes it does (25 pass). Session fake-backend test fails before the state-before-take reorder, passes after. Side effect: faster owner wakeups made the tmux integration test type F1 within tmux's default 1 ms assume-paste-time (bindings skipped as paste), so the test config sets assume-paste-time 0. Local gate: fmt clean, build ok, zig build test all steps green, 17 headless checks ok, e2e 9/9. Stability: term-test 10/10, pty-test 20/20, workspace-test (4 MiB flood) 10/10 runs green.

Hosted Linux E2E gate run 37639111197 on 1c30282: success (unit tests including the 4 MiB flood, 17 headless checks, 9/9 scenarios).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
PosixPty now signals each direction on its own nonblocking pipe (owner_wake drained only by the owner, reader_wake drained only by the read thread), so the owner's drain can no longer eat the wakeup a blocked reader is waiting for; session.drainChildOutput observes the child end before taking bytes so a late end cannot strand the final queue. Verified by a deterministic ReaderPark test that fails on the single-pipe design, a fake-backend ordering test that fails before the reorder, the full local gate, repeated stability loops, and hosted gate run 37639111197. The tmux integration test config disables assume-paste-time because the faster wakeups typed F1 inside tmux's 1 ms paste window.
<!-- SECTION:FINAL_SUMMARY:END -->
