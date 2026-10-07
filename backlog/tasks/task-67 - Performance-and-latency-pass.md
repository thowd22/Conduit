---
id: TASK-67
title: Performance and latency pass
status: Done
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-07 23:38'
labels:
  - performance
milestone: m-8
dependencies:
  - TASK-11
priority: medium
ordinal: 67000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Measure and tune input latency, throughput on large output, frame time with many panes, memory per session with full scrollback, and startup time. Add repeatable benchmarks and budgets.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Benchmarks for throughput, frame time and startup are runnable from the build
- [x] #2 Budgets are documented and met on reference hardware
- [x] #3 No dropped input or runaway memory under a large output flood
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. zig build bench: benchmark executables under bench/ for terminal throughput (feed N MiB through term with and without drawing), frame time with 1/4/9 panes at 1920x1080 (offscreen FBO), startup to first prompt, and per-session memory with full scrollback; deterministic inputs, JSON output, repeatable from the build.
2. Budgets documented in docs/performance.md with the reference hardware (this box: llvmpipe, so GPU numbers are indicative) and asserted in a bench check that fails when exceeded by a margin.
3. Flood test: a large output flood drops no input (typed sentinel delivered during the flood) and memory stays bounded (RSS measured before/after); tune hot paths found by the benchmarks without changing behaviour.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Agent: bench/ (common, gpu, throughput, frame, memory, startup, runner, budgets) with zig build bench / bench-check; docs/performance.md with reference numbers (Ryzen 7 5700G, llvmpipe) and 25%-headroom budgets; atlas key index + shorter-leftover split (CJK full frame 7.6 -> 5.0 ms, 1024² atlas failed insertions 738 -> 1); workspace flood test (64 MiB, 20 sentinels in order, allocator peak 116 KiB, RSS +8.4 MiB); output-flood scenario types during the flood. Coordinator 2026-10-07: merged as 50e2e1e; full gate green (862/873 unit tests, 26 checks, 17 scenarios) and bench-check PASS with 0 breaches on this box. Follow-ups for app: 2048² atlas at scale >= 1.5, driver wake on Load completion, region-only atlas uploads; bench-check not in CI (runner-specific budgets needed first).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Performance pass: repeatable throughput, frame-time, memory and startup benchmarks runnable from the build with documented, enforced budgets, a glyph-atlas fix that removed CJK evictions and failed insertions at scale 2, and a flood test proving no dropped input and bounded memory under 64 MiB of output; verified by zig build bench-check and the full local gate.
<!-- SECTION:FINAL_SUMMARY:END -->
