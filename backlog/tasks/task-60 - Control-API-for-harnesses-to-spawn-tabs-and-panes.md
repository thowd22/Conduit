---
id: TASK-60
title: Control API for harnesses to spawn tabs and panes
status: Done
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-08 00:45'
labels:
  - agents
  - cli
milestone: m-6
dependencies:
  - TASK-30
  - TASK-52
priority: medium
ordinal: 60000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A local control endpoint and matching 'conduit' subcommands (and MCP tools) that let a harness running inside Conduit open a tab or pane, show an agent view or backlog view, set tab status and raise notifications, scoped to its own workspace. The scratchpad is not addressable through this API.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A process inside a Conduit terminal can open a tab or split pane in its workspace through the API
- [x] #2 API exposes agent view and backlog view creation
- [x] #3 Scratchpad cannot be targeted or taken over through the API
- [x] #4 API is documented for harness configuration
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Part 1 (protocol and server, no app wiring): 1. src/control.zig: a local-only control endpoint modelled on the test driver (private Unix socket / protected named pipe, JSON-RPC-style framed requests) with per-workspace capability tokens handed to children through the environment (CONDUIT_CONTROL_ENDPOINT, CONDUIT_CONTROL_TOKEN) so a request is scoped to the caller's workspace; methods tab.open, pane.split, view.agent, view.backlog, tab.status, notify, agent.event (hook/extension ingestion replacing the interim sinks), ping; the scratchpad is never addressable (no session parameter can name it; replies refuse).
2. Server runs off the render thread, hands validated requests to the owner through a bounded queue and returns replies; bounded frames, strict validation, no action derived from untrusted text beyond the enumerated methods.
3. Documentation for harness configuration (docs/control-api.md): endpoint discovery, token, method reference, hook examples for Claude Code/Codex/Pi/OpenCode.
4. Unit tests for parsing/encoding/validation/scoping; an integration test against a real socket with a client process.
Part 2 (after main.zig frees): app wiring (handlers performing the actions, status/notify), conduit CLI subcommands (with TASK-66) and MCP tools, a --control-test.

Part 2: app Handler (tab.open, pane.split, view.agent, view.backlog, tab.status, notify, agent.event into the adapters' sinks/runtime), ChildSpec injects CONDUIT_CONTROL_ENDPOINT/TOKEN/SESSION for every child except the scratchpad and the connection session, token revoke on workspace close, control.enabled setting, conduit-test MCP tools for the control methods, --control-test and an e2e scenario.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Part one landed (1bfe743, b883268 rebased onto main as 9458afe): src/control.zig token-scoped local control API (private 0700 dir, 0600 socket, per-workspace tokens with entropy from the owner, CONDUIT_CONTROL_ENDPOINT/TOKEN/SESSION env names, JSON line frames capped at 64 KiB, methods ping/tab.open/pane.split/view.agent/view.backlog/tab.status/notify/agent.event, scratchpad refused with ScratchpadNotAddressable before reaching the owner, Handler vtable with deferred replies and timeouts, listener thread + per-connection threads up to 32); platform.LocalSocketListener (additive); build.zig control module; docs/control-api.md with harness snippets. 17 control tests in Debug and ReleaseSafe. Part two: app Handler, ChildSpec env injection, token revoke on workspace close, control.enabled setting, conduit CLI subcommands/MCP tools, --control-test; Windows transport missing.

Part two landed (7d78e3e rebased as 0ac8df7 after resolving four claude_code.zig hunks against TASK-61's SinkIo seam): App implements the control Handler (tab.open, pane.split, view.agent, view.backlog, tab.status, notify, agent.event via Runtime.ingestControlEvent), endpoint at $XDG_RUNTIME_DIR/conduit/r-<hex>.sock when control.enabled (Debug on, release off; --control/--no-control), env injection for human/agent terminals only, token revoke on close, Claude hooks run 'conduit control agent.event --event=<Hook>' for local sinks with the sink fallback; --control-test (35 checks) and the nineteenth scenario control-api. Coordinator 2026-10-08: full gate green (921/934 unit tests, 28 checks, 19 scenarios); screenshot inspected. conduit-test does not forward control requests (documented).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Local token-scoped control API: a process inside a Conduit terminal can open tabs and panes, show the agent and backlog views, set tab status, raise notifications and deliver harness events in its own workspace, with the scratchpad unaddressable and everything documented for harness configuration; verified by protocol unit tests, the deterministic --control-test from real tab shells, the control-api scenario and the full gate.
<!-- SECTION:FINAL_SUMMARY:END -->
