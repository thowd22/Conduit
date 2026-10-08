---
id: TASK-65
title: Workspace persistence and restore
status: Done
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-08 01:36'
labels:
  - workspace
  - persistence
milestone: m-8
dependencies:
  - TASK-30
  - TASK-33
priority: medium
ordinal: 65000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Persist workspaces, tabs, pane layouts, working directories, connection contexts, theme and window geometry, and restore them on launch (re-spawning shells in their directories and offering to reconnect SSH workspaces). State is versioned for forward migration.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Relaunching restores workspaces, tabs, pane layout and cwd
- [x] #2 SSH workspaces are restored with a reconnect prompt
- [x] #3 State file has a version and corrupted state falls back to a clean start
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Part 1 (state model and file, no app wiring): 1. src/state.zig: a versioned snapshot (version, workspaces with name/kind/context target, tabs with names and pane trees with per-leaf cwd, active selections, theme name, window geometry) with a bounded, tolerant JSON codec; corrupted or unknown-version input yields a diagnostic and a clean default, never a crash.
2. workspace.zig: snapshot() of a live Workspace/WorkspaceRegistry into the model and a restore plan (what to spawn where) that the app executes; SSH workspaces restore as a reconnect prompt rather than auto-connecting.
3. Atomic write (temp + rename) to the platform state dir (XDG_STATE_HOME/conduit/state.json), bounded size, unit tests for round trip, migration from a lower version, corruption fallback, and pane-tree fidelity.
Part 2 (after main.zig frees): save on change/exit, restore on launch, reconnect prompt, --restore-test and an e2e scenario.

Part 2 dispatched 2026-10-08 together with the TASK-68 app wiring and TASK-67's app follow-ups.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Part one landed (2859e98, fbd7f8e rebased onto main as 2dff7b1; build.zig module-list conflict with control resolved): src/state.zig versioned Snapshot model with bounded tolerant JSON codec (limits: 1 MiB, 64 workspaces, 256 tabs, depth 16), migrate on the JSON tree, statePath per OS, atomic save, load, quarantine to state.json.corrupt-<unix>, restoreFromDisk, planRestore steps; WorkspaceRegistry.snapshot/captureState, setPaneSplitRatio, Tab.userNamed. 13 state tests, 60 workspace tests, fuzz/truncation/alloc-failure corruption tests. Part two (app): save on change/exit, restore on launch executing the plan, SSH reconnect prompt, --restore-test and an e2e scenario.

Part two landed (a0db949, fd83562, 7807a39, bd96f38, b289711 rebased onto main as 33db900; f4b6a41 tightens the restored-label assertion): Persistence saves two seconds after the layout fingerprint changes and in deinit, restoreAtLaunch/executeRestore/driveRestoreQueues replay the plan, SSH workspaces come back as saved sessions with a reconnect control, corrupt or newer files are quarantined with a status line; restore.enabled and --no-restore. --restore-test runs two apps on one window. Coordinator 2026-10-08: full gate green (930/943 unit tests, 30 checks incl. --restore-test and --a11y-test, 19 scenarios); restored frame inspected (my first look used an older frame from before the check's own rename-field fix; the final frame shows the tab named build and a gap before reconnect). Position/maximized not applied (platform has no placement calls); no e2e scenario (one launch per scenario).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Workspace persistence and restore: versioned atomic state file written on change and exit, restored on launch with pane layouts, ratios, focus, zoom, selections, cwds (with fallback), theme and window size, SSH workspaces restored as saved sessions behind a reconnect prompt, and corrupt or newer state quarantined for a clean start; verified by unit tests, the deterministic --restore-test relaunching within one check and the full gate.
<!-- SECTION:FINAL_SUMMARY:END -->
