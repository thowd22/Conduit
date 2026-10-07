---
id: TASK-72
title: 'Output floods stall the UI: one PTY read per frame'
status: In Progress
assignee:
  - '@claude'
created_date: '2026-10-07 02:11'
updated_date: '2026-10-07 03:55'
labels:
  - performance
  - terminal
  - bug
milestone: m-8
dependencies: []
priority: high
type: bug
ordinal: 73000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Inside Conduit, 'seq 1 200000' (1.3 MB) takes about 20 s with the ReleaseSafe build and 'yes | head -200000' (10 MB) runs for minutes in a Debug build, where other terminals finish both well under a second. The event loop drains one PTY read (a few KiB) per iteration and then draws a full frame (semantic tree, link scan, software render) before reading again, so a flood costs one frame per chunk and the window appears frozen; while that backlog drains the app also stops answering the test driver, which is how a user can perceive a crash. Seen while testing Claude Code, Codex and omp inside Conduit on 2026-10-07: the harnesses themselves ran fine, but their output bursts are exactly this path. Standards still apply: render on demand, no busy loop, bounded work per wake.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Draining child output is bounded by bytes and time per wake rather than by one read, and output keeps flowing while frames are coalesced to roughly display rate
- [ ] #2 A deterministic test proves a multi-megabyte flood is consumed in bounded frames or bounded time without reaching into app state
- [ ] #3 'seq 1 200000' and 'yes | head -200000' complete inside a ReleaseSafe Conduit within a few seconds on the dev box, and the driver keeps answering during the flood
- [ ] #4 Idle behaviour is unchanged: an untouched window draws no frames and the loop still blocks in SDL
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Separate draining from drawing: pump sessions in the event loop in a bounded loop (byte and time budget per wake) instead of once inside drawFrame.
2. Coalesce frames while output keeps arriving: draw when dirty but not more often than about display rate while a session still has readable output; keep the loop blocking in SDL when nothing is pending.
3. Add a deterministic unit test with a fake PTY feeding megabytes that asserts bounded frames and full consumption, plus a timed real-PTY check in the driver path.
4. Measure seq 1 200000 and yes | head -200000 in the ReleaseSafe build before and after; keep idle-frame counts and every existing check green.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-10-07 coordinator measurements before the fix: ReleaseSafe build, 1000x640 window under Xvfb, bash child: 'seq 1 200000' REAL 19.9 s; Debug build: 'yes | head -200000' still draining after 7 minutes at 99% CPU with frames 13 s apart, and the test driver stopped answering until the flood was killed. Diagnosis: drawFrame -> pumpChild -> Workspace.pump drains exactly one pty read per session and then composes and renders a full frame; Scheduler has no coalescing. Found while running Claude Code, Codex and omp inside Conduit (all three start, render and quit without crashing; Claude Code ran a prompt and two parallel subagents to completion inside Conduit).

2026-10-07 slice 1 (Opus agent, main.zig/workspace.zig/e2e): App.run now drains child output in bounded 16 KiB pump passes under workspace.DrainBudget.per_wake (4 MiB or 8 ms) before deciding to draw; a pure FramePacer coalesces frames to one per max(16 ms, last frame cost) while output keeps arriving and draws an owed frame as soon as output pauses or the loop exits; the driver is polled every iteration; idle --self-test still draws one frame. New unit tests: DrainBudget edges, 5.2 MiB fake-PTY flood in exactly 2 wakes, real-PTY 4 MiB flood under 10 s, exhaustive FramePacer decisions, an 8 MiB simulated flood with bounded frames; new scripted E2E scenario output-flood (4 MB CR flood, runtime-built marker). Results: a 40 MB CR flood fell from 12.7 s to 1.4 s (ReleaseSafe) and 18.6 s to 4.1 s (Debug), but seq 1 200000 stays at 14.6 s and yes | head -200000 at 12-13 s in ReleaseSafe because each LF costs ~75 us inside Terminal.feed (empty lines 2.6 s per 64 KiB; CR-only and soft-wrapped text are fast; scrollback limit irrelevant). Debug is also dominated by Ghostty's slow_runtime_safety PageList.verifyIntegrity on every scroll. AC3 stays open; slice 2 targets the LF cost in term.zig.

2026-10-07 slice 2 root cause (Opus agent, term.zig): Conduit adds no per-linefeed work; build.zig called b.dependency("ghostty", .{}) without target/optimize, so ghostty-vt was built in Ghostty's default Debug mode with slow_runtime_safety on inside every Conduit build, including the shipped v0.1.0-v0.1.2 binaries. Each scroll then ran Screen.assertIntegrity and the PageList/Page integrity checks: ~79 us per LF in ReleaseSafe Conduit, ~1.5 ms in Debug. Unit benchmark of a 200,000-line feed: 15.8 s -> 0.098 s (ReleaseSafe engine). Fix applied by the coordinator in build.zig: ghosttyDependencyOptions passes Conduit's target and optimize to both ghostty dependency calls, with the engine built at least ReleaseSafe even for a Debug Conduit (Debug keeps Conduit's own checks; only Ghostty's internal integrity asserts are given up). term.zig gained a comptime engine_integrity_checks probe via @FieldType(PageList, "pause_integrity_checks"), a test that fails any optimised build linking a slow-checked engine, and a 200,000-line feed test bounded at 5 s. Real app after the fix: Debug Conduit seq 1 200000 REAL 0.484 s (was >260 s), yes | head -200000 REAL 0.333 s (was >245 s); the agent measured ReleaseSafe 0.124 s and 0.106 s (were 14.6 s and 13.0 s).
<!-- SECTION:NOTES:END -->
