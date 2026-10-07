---
id: TASK-54
title: Codex CLI adapter
status: Done
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-07 23:39'
labels:
  - agents
  - codex
milestone: m-6
dependencies:
  - TASK-52
priority: high
ordinal: 54000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Adapter for Codex CLI per the spike: launch and attach, map its notification and session events into the agent event stream, surface status and approval requests, and read prompts/instructions where supported.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Codex launched from Conduit appears in the agent registry with live status
- [x] #2 Approval requests and turn completion produce agent events
- [x] #3 A manually started codex process in a Conduit terminal is detected
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Implement agent.Adapter for Codex in src/agent/codex.zig per decision-7: detect (codex --version, version-gated), launch argv for the TUI on the shared daemon plus hooks/notify fallback, poll via the app-server JSON-RPC over the daemon socket (thread/status/changed, items, approval server requests) with a tolerant parser, respondPermission answers approval requests, rollout JSONL for history.
2. Unit tests from recorded app-server/exec --json fixtures; integration test against a fake app-server speaking the protocol over a local socket (no OpenAI call).
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Adapter landed (f7aed76, 8bf58da rebased onto main as 531b4f5): CodexAdapter over a pluggable Transport (RFC 6455 WebSocket client to the daemon's app-server-control.sock, or newline JSON over an owner-spawned codex app-server --listen stdio://); attach initialize/initialized then resume/start/find a hand-started TUI thread by cwd; status/turn/item/serverRequest mapping with legal transitions; approval server requests -> permission_request with availableDecisions, respondPermission sends the chosen decision byte-exact; turn/start/steer/interrupt; version gate 0.160.0 <= v < 0.162.0; RolloutReader. 23 unit tests incl. recorded 0.160.1 exchange and a fake WebSocket daemon on a real Unix socket; opt-in real runs answered a real stdio approval and a real hand-started TUI approval on an isolated daemon with a mock provider (no model account). 735/746 unit tests pass on main. Pending: detect via run (agent resumed), piped/socketpair spawn for headless stdio agents, FdStream to platform (invariant 10), app wiring (TASK-56/60), SSH streamlocal forwarding (TASK-61). pty ReaderPark test flaked again under load (third sighting): fix queued.

Coordinator 2026-10-07: app wiring (TASK-56/57) connects the Codex adapter in daemon mode for TUI launches; approvals reach the agent view's decision controls and respondPermission sends the chosen decision. Evidence: a recorded 0.160.1 stdio approval round trip replayed in unit tests, a fake WebSocket daemon over a real Unix socket, and opt-in real runs that answered a real stdio approval and a hand-started TUI's approval on an isolated daemon with a mock provider; detect via codex --version with version gating. Not run: a real OpenAI model account (usage limit).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Codex adapter over the app-server JSON-RPC protocol (daemon WebSocket or stdio) with live status and approval prompts, rollout transcript access and answerable approvals, version-gated; verified against the real 0.160.1 binary with a mock provider and recorded fixtures.
<!-- SECTION:FINAL_SUMMARY:END -->
