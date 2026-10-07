---
id: TASK-55
title: Pi adapter
status: Done
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-07 23:39'
labels:
  - agents
  - pi
milestone: m-6
dependencies:
  - TASK-52
priority: medium
ordinal: 55000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Adapter for the Pi coding agent CLI per the spike: launch and attach, map its events into the agent event stream, surface status and input requests, and read prompts/instructions where supported.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Pi launched from Conduit appears in the agent registry with live status
- [x] #2 Waiting-for-input and completion produce agent events
- [x] #3 A manually started pi process in a Conduit terminal is detected
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Implement agent.Adapter for Pi (omp as a variant) in src/agent/pi.zig per decision-7: detect, launch with a Conduit-supplied Pi extension (-e) that forwards pi.on events to a per-agent sink and gates tools through ctx.ui.confirm; poll tails the sink; respondPermission answers extension_ui_request; session JSONL v3 for history.
2. Unit tests from fixtures; integration test runs pi --mode rpc with the extension against a mock model endpoint.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Adapter landed (bce75d9, a232ee4 rebased onto main as 2a16011): PiAdapter with tui (Conduit extension src/agent/pi/conduit.js embedded, sink JSONL, gated confirm with decision files) and rpc modes over an owner-supplied Transport; SessionReader for session JSONL v3; 14 unit tests plus two integration tests that run the real pi --mode rpc against a loopback mock model (skip when pi/python3 absent); manual tmux TUI run showed both answer paths. 702/711 unit tests pass on main. Pending: detect via ExecutionContext.run (agent resumed), LaunchSpec.files so the owner writes the extension, registry/owner wiring (TASK-56/58), omp unverified.

Coordinator 2026-10-07: app wiring (TASK-56/57) launches pi -e conduit.js with the sink transport; detect now reads stderr so Pi is offered. Evidence: two integration tests running the real pi --mode rpc with the extension against a loopback mock model (status, gated confirm answered over RPC and through the decision file, tool run, session JSONL written), manual tmux TUI run showing both answer paths, fixtures for the sink, RPC and session v3 formats. Gaps documented (no native permission prompts without the gate extension, no subagents, omp unverified).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Pi adapter with a Conduit-shipped extension providing events and gated confirms in the TUI, RPC mode for headless agents, session JSONL v3 transcript parsing and documented gaps; verified by real pi integration tests against a mock model.
<!-- SECTION:FINAL_SUMMARY:END -->
