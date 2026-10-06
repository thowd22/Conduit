---
id: TASK-67
title: Performance and latency pass
status: To Do
assignee: []
created_date: '2026-10-03 21:39'
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
