---
id: TASK-23
title: conduit-test CLI
status: Done
assignee:
  - '@codex'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-06 02:57'
labels:
  - testing
  - cli
milestone: m-2
dependencies:
  - TASK-21
documentation:
  - docs/architecture.md
modified_files:
  - build.zig
  - src/conduit_test.zig
  - AGENTS.md
  - docs/architecture.md
priority: high
ordinal: 23000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Command-line client for the test driver: launch (isolated config/state dir, returns a run id), inspect, click, key, type, screenshot, terminal-text, wait-for, logs, quit. Output is plain text or JSON suitable for agents; non-zero exit on failure.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 'conduit-test launch' starts an isolated instance and later commands address it
- [x] #2 Every driver method is reachable from the CLI
- [x] #3 --json output is machine readable and errors return non-zero exit codes
- [x] #4 Launched instances never touch the user's real config or state
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Add a dedicated conduit-test executable with strict parsing and direct subcommands for every JSON-RPC driver method, plus raw JSON output and plain result projection.
2. Implement launch as an isolated run directory (private home/config/state/cache/log/artifacts), a safe run id and endpoint, detached Conduit process, readiness handshake, and a manifest used by later --run commands.
3. Wire the executable and unit tests into build.zig, then exercise launch and commands as separate processes against a hidden real app.
4. Document the CLI contract, run build/unit/headless verification, and record platform limits without claiming unavailable native evidence.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented a separately installed conduit-test composition root with strict parsing for launch and every JSON-RPC driver method. Launch derives a private run tree, overrides HOME/XDG/temp and Windows profile variables, redirects output, selects a local endpoint, waits for an inspect readiness exchange, and atomically publishes a private manifest. Direct commands derive endpoints only from a validated root and safe run id rather than trusting manifest process data. JSON mode relays valid server responses and emits a machine-readable local error object with a nonzero exit.

Linux verification: zig build passed; zig build test --summary all passed 361/368 with seven expected platform skips; all eight Xvfb checks passed. A hidden no-display launch was addressed by separate CLI processes for inspect, click, ctrl-click, double-click, drag, key, type, scroll, terminal-text, both wait-for forms, logs, screenshot and quit. Success and expected not-found/timeout errors parsed with jq, the 640x360 PNG was structurally and visually inspected, run/manifest permissions were 0700/0600, and deliberately fake real-user HOME/XDG paths remained nonexistent. Native macOS and Windows runtime behavior is not claimed.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Added and verified the external conduit-test CLI. It can launch an isolated hidden Conduit, address that run later, expose every driver method in plain or JSON form, return nonzero machine-readable failures, and keep all mutable app state beneath a private run root. Build, unit/integration, eight Linux headless checks, live multi-process CLI driving, screenshot inspection and isolation checks all pass. Native macOS and Windows runtime execution remains for their CI runners.
<!-- SECTION:FINAL_SUMMARY:END -->
