---
id: TASK-67
title: Performance and latency pass
status: In Progress
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-07 22:34'
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
- [ ] #1 Benchmarks for throughput, frame time and startup are runnable from the build
- [ ] #2 Budgets are documented and met on reference hardware
- [ ] #3 No dropped input or runaway memory under a large output flood
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. zig build bench: benchmark executables under bench/ for terminal throughput (feed N MiB through term with and without drawing), frame time with 1/4/9 panes at 1920x1080 (offscreen FBO), startup to first prompt, and per-session memory with full scrollback; deterministic inputs, JSON output, repeatable from the build.
2. Budgets documented in docs/performance.md with the reference hardware (this box: llvmpipe, so GPU numbers are indicative) and asserted in a bench check that fails when exceeded by a margin.
3. Flood test: a large output flood drops no input (typed sentinel delivered during the flood) and memory stays bounded (RSS measured before/after); tune hot paths found by the benchmarks without changing behaviour.
<!-- SECTION:PLAN:END -->
