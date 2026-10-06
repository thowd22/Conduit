---
id: TASK-25
title: E2E test harness and first scenarios in CI
status: In Progress
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-06 21:19'
labels:
  - testing
  - ci
milestone: m-2
dependencies:
  - TASK-22
  - TASK-23
modified_files:
  - build.zig
  - e2e/runner.zig
  - e2e/scenarios.zig
  - .github/workflows/linux-e2e.yml
priority: high
ordinal: 25000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A runner for scripted E2E scenarios built on the test driver ('zig build e2e'), with per-run artifact directories (screenshots, logs, tree dumps) and the first scenarios: launch and see a prompt, type a command and assert output, select and copy text. Runs headless in Linux CI.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 'zig build e2e' runs all scenarios and reports pass/fail per scenario
- [x] #2 Failures leave screenshots, logs and the semantic tree in an artifact directory
- [ ] #3 E2E job runs on Linux CI and uploads artifacts on failure
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Add a standalone scenario runner and declarative scenarios that drive the existing conduit-test/test-driver boundary.
2. Add `zig build e2e` with isolated config/state and per-run artifact directories.
3. Cover launch/prompt, command/output, and selection/copy through real user input.
4. Persist screenshot, application log, runner log, and semantic tree on failure.
5. Add a Linux CI gate that runs unit tests and E2E and uploads failure artifacts; verify locally and retain remote-run evidence as an explicit external check.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Coordinator verification on Linux: `zig build e2e` reported PASS for launch-prompt, type-command, and select-copy after isolated run data was archived beneath the requested artifact root. A deliberate impossible terminal-text assertion produced exactly one failed scenario with a live 640x360 PNG, valid semantic-tree JSON, application log, runner log, and an artifact manifest reporting every artifact present; the screenshot was visually inspected. The scenario was restored and the full suite passed again. Unit coverage also exercises long artifact roots, bounded Unix endpoints, safe screenshot paths, and cross-device artifact retention. AC3 remains pending an actual GitHub Actions run/upload rather than being inferred from workflow YAML.
<!-- SECTION:NOTES:END -->

## Comments

<!-- COMMENTS:BEGIN -->
created: 2026-10-06 18:01
---
Linux E2E owns its own CI gate; cross-platform build evidence remains TASK-5.
---
<!-- COMMENTS:END -->
