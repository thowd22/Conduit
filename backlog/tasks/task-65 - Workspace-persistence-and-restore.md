---
id: TASK-65
title: Workspace persistence and restore
status: In Progress
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-08 00:44'
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
- [ ] #1 Relaunching restores workspaces, tabs, pane layout and cwd
- [ ] #2 SSH workspaces are restored with a reconnect prompt
- [ ] #3 State file has a version and corrupted state falls back to a clean start
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
<!-- SECTION:NOTES:END -->
