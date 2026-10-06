---
id: TASK-27
title: 'Workspace, ExecutionContext and Session model'
status: Done
assignee:
  - '@codex'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-06 04:08'
labels:
  - workspace
  - architecture
milestone: m-3
dependencies:
  - TASK-8
  - TASK-9
modified_files:
  - src/session.zig
  - src/workspace.zig
  - src/main.zig
  - AGENTS.md
  - docs/architecture.md
priority: high
ordinal: 27000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Core domain model. Workspace owns an ExecutionContext (Local now; SSH and WSL later), a working directory, tabs with pane layouts, one Scratchpad session, agents, and state. Session owns a PTY plus terminal state and lives independently of whether it is visible. All new terminals are spawned through the workspace's ExecutionContext so every feature inherits local/remote behavior. Human sessions and agent-owned sessions are distinct kinds.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Sessions keep running and buffering output while not visible
- [x] #2 ExecutionContext is an interface with a Local implementation and no local-only assumptions in callers
- [x] #3 Session kinds distinguish human terminals, scratchpad and agent-owned terminals
- [x] #4 Unit tests cover workspace and session lifecycle including teardown
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Extend the existing Session owner with explicit human, scratchpad and agent-owned kinds while preserving PTY/terminal lifetime, buffering and teardown semantics.
2. Define the workspace-owned ExecutionContext interface and Local implementation around the existing PTY spawn boundary, with callers depending only on the interface.
3. Add an allocator-owned Workspace aggregate with working directory, session registry, exactly one scratchpad slot and lifecycle/teardown rules; keep later tab/pane/agent UI data out of this task.
4. Add unit and real-PTY lifecycle tests for hidden-view independence, local spawn routing, kind distinctions and teardown; format, build, run the full suite and reconcile architecture/current-state documentation.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented explicit human, scratchpad and agent session kinds; a workspace-owned type-erased ExecutionContext with Local as the sole production PTY spawn boundary; stable monotonic session records; one reserved scratchpad; worker-side spawning with owner-thread attachment; and ordered teardown.

Workspace service is bounded, allocation-free, two-way and independent of visibility. Session retains terminal responses across short, zero and failed writes, active user input remains ordered behind them, and exited PTYs drain final output before becoming quiescent. Pump callbacks may grow the registry or close sessions without invalidating the walk.

Evidence: zig build passed; zig build test --summary all passed 387/394 with 7 expected platform skips; session-test 14/14 and workspace-test 13/13 include fake backpressure/mutation/teardown coverage plus a real POSIX hidden-PTY lifecycle test; all eight Xvfb headless checks passed; an independent AC re-audit passed after active and hidden paths shared Session-owned draining and response preservation. Native Windows/macOS runtime behavior remains covered by their later platform tasks.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Added the nonvisual workspace/session ownership core. Every workspace owns its execution context, copied cwd, stable session registry and reserved scratchpad; Local process creation is isolated behind ExecutionContext. Visible and hidden sessions now continue PTY service independently of views, preserve protocol replies and user-input ordering under backpressure, drain final output before quiescing, and tear down safely. Updated architecture/current-state documentation and added lifecycle, mutation, response and real-PTY tests.
<!-- SECTION:FINAL_SUMMARY:END -->
