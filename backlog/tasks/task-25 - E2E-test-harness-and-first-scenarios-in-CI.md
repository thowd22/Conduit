---
id: TASK-25
title: E2E test harness and first scenarios in CI
status: Done
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-06 22:18'
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
- [x] #3 E2E job runs on Linux CI and uploads artifacts on failure
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

2026-10-06 first push to GitHub (main a7a30d1). The initial linux-e2e.yml and release.yml runs failed validation before any job: GitHub does not allow the runner context in job-level env (runner.temp). Fixed in b5c5bb8 by exporting the private directories from a step through GITHUB_ENV; actionlint (rhysd/actionlint via Docker) is clean on all three workflows. Run 37535520822 'Linux E2E gate' is the first real execution.

2026-10-06 hosted evidence: Linux E2E gate run 37539118525 on commit 2acbd93 passed formatting, build, unit tests (zig build test), the clipboard check, all seventeen real-window headless checks under Xvfb with the X11 backend asserted from every retained log, the Sway/X11-primary/IBus platform checks and the six scripted conduit-test scenarios (zig build e2e). The two earlier failing runs (37535520822, 37537621738) each uploaded the conduit-linux-e2e failure artifact containing the per-check logs, driver artifacts, semantic trees and screenshots, which were downloaded and used to diagnose the Sway renderer and IBus mode fixes.
<!-- SECTION:NOTES:END -->

## Comments

<!-- COMMENTS:BEGIN -->
created: 2026-10-06 18:01
---
Linux E2E owns its own CI gate; cross-platform build evidence remains TASK-5.
---
<!-- COMMENTS:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
The scripted E2E harness (zig build e2e) launches a fresh isolated app per scenario through conduit-test, reports PASS/FAIL per scenario, retains runner log, semantic tree, application log and screenshots in a run-unique artifact directory, and runs on Linux CI in the reusable linux-e2e.yml gate alongside the unit tests and every built-in check; failure artifacts are uploaded, as proven by the first two hosted runs, and run 37539118525 passed end to end.
<!-- SECTION:FINAL_SUMMARY:END -->
