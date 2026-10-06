---
id: TASK-26
title: Document the agent development loop
status: Done
assignee:
  - '@codex'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-06 03:19'
labels:
  - docs
  - testing
milestone: m-2
dependencies:
  - TASK-24
modified_files:
  - AGENTS.md
  - CLAUDE.md
priority: medium
ordinal: 26000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Update CLAUDE.md and AGENTS.md with the loop agents must follow: zig build test, zig build, launch through conduit-test, inspect, interact, screenshot, assert, read logs on failure. Include the rule that every user-facing feature lands with an E2E scenario.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 CLAUDE.md and AGENTS.md describe the build, test and E2E commands
- [x] #2 A worked example of testing a feature through the driver is included
- [x] #3 Rule requiring an E2E scenario per user-facing feature is stated
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Reconcile CLAUDE.md and AGENTS.md with the installed build, unit-test, conduit-test CLI and MCP surfaces.
2. Add one deterministic worked feature-validation example covering launch, inspect, interaction, wait/assert, screenshot, quit and failure log/tree capture.
3. State the per-user-facing-feature E2E rule consistently in both agent guides, then validate every documented command against the current binaries and finish the task with evidence.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Updated both agent entry points with the current development loop. AGENTS.md now gives the canonical sequence: zig fmt, zig build test, zig build, isolated conduit-test launch, semantic inspect, real input, wait-for assertion, screenshot inspection, failure logs/tree capture, quit and acceptance review. It includes a copy-pastable deterministic child protocol that waits for transformed output so PTY echo cannot false-pass, uses explicit root/run selectors and a cleanup trap, and names the equivalent MCP get_logs surface. CLAUDE.md preserves @AGENTS.md as authoritative while explicitly naming the build/test commands, installed CLI, current ui/ime/driver app checks, project MCP entry and diagnostics. Both guides state that every user-facing feature requires a deterministic E2E scenario with keyboard/mouse parity where applicable, and both accurately mark zig build e2e as planned and blocked on TASK-25.

Coordinator verification: the exact worked CLI example launched a real offscreen 640x360 Conduit, inspected the tree, typed probe plus ENTER through the real path, observed CONDUIT_ASSERTED, captured a PNG and quit cleanly. The screenshot was visually inspected and showed CONDUIT_READY, echoed probe and CONDUIT_ASSERTED. The preceding implementation wave had already passed zig build and zig build test --summary all (368 passed, 7 platform skips). git diff --check passed, and command-name review caught and corrected CLI logs versus MCP get_logs.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Documented and validated the canonical agent build/test/driver loop in AGENTS.md and the Claude Code entry point in CLAUDE.md. Added a live-tested worked example, visual screenshot requirement, failure-diagnostics sequence and mandatory per-feature E2E rule without claiming the still-blocked TASK-25 scenario runner exists.
<!-- SECTION:FINAL_SUMMARY:END -->
