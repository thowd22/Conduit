---
id: TASK-61
title: Agents in SSH workspaces
status: Done
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-08 02:10'
labels:
  - agents
  - ssh
milestone: m-6
dependencies:
  - TASK-43
  - TASK-53
priority: medium
ordinal: 61000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Run and observe harnesses on the remote host of an SSH workspace: launch remotely through the ExecutionContext and carry adapter events (hooks, transcripts) back over the connection so status, notifications and agent views work the same as locally.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 An agent launched in an SSH workspace runs on the remote host
- [x] #2 Status and notifications work for the remote agent
- [x] #3 Agent view renders the remote agent's structured events
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Part 1 (context and adapters): 1. ExecutionContext.writeFile (bounded, mode) for Local and SSH, so LaunchSpec.files (Claude settings/hook.sh, Pi conduit.js) can be written on the remote host; remote sink paths under the remote XDG state dir.
2. Adapters read sinks/transcripts/decision files through the context (readFile/watch/writeFile) instead of the local filesystem, so hooks and extensions running remotely report into a remote sink that Conduit tails over the connection; Codex daemon socket and OpenCode port forwarding documented as unsupported remotely for now (PTY baseline).
3. Integration test against the sshd container: launch the fake-shaped hook relay remotely and tail its sink through the SshContext.
Part 2 (app): Runtime uses the context for sink IO per workspace kind; --ssh-test launches a fake agent in the SSH workspace and proves status, notifications and the agent view.

Part two dispatched 2026-10-08 with TASK-59: Runner.prepare writes files through the workspace context, remote sink root from stateDir on the detection worker, Pi SinkTransport, remote cleanup on a worker, --ssh-test launches a fake-shaped agent in the SSH workspace proving status, notifications and the agent view.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Part one landed (020d922, 981032c, d1ca1e5 rebased onto main as fe7f9b8): ExecutionContext readFileAt/writeFile (atomic, 1 MiB, exact mode)/makePrivateDir/stateDir with Local and SSH (chunked stdin exec scripts) implementations, localWithStateDir and localFiles helpers, ssh.TestRemote harness; agent/sink_io.zig SinkIo (local or context-backed with 500 ms idle read throttling); Claude and Pi adapters route sinks, decisions, transcripts and the config dir through SinkIo; Codex/OpenCode remain PTY baseline remotely. Docker SSH tests ran the Claude relay remotely through run and through a PTY session over the master. Part two (app_agents/main): Runner.prepare writes files through the workspace context, remote sink root from stateDir resolved on the detection worker, Pi SinkTransport replaces PiSink, remote cleanup via rm -rf on a worker, --ssh-test launching a fake-shaped agent remotely. decision-8's remote-writes sentence needs updating.

Part two landed (921fffd, f433bb7, 250da55 rebased onto main as 5416a2c): detection worker resolves remote stateDir and Claude config dir, remote sink root <remote state>/conduit/agents/<run>/<token16>, Runner.prepare and transports through SinkIo, Cleanup worker removes remote sinks and the run root, Codex/OpenCode terminal-only remotely; --ssh-test launches the fake remotely and proves host, remote sink, glyphs, notification, agent view, remote decision file and cleanup (56 checks). Coordinator 2026-10-08: merged; gate run recorded below. No real remote Claude Code/Pi run (no credentials).

Coordinator 2026-10-08: full gate green (942/955 unit tests, 31 checks incl. --ssh-test with the remote fake agent, 20 scenarios); remote agent view screenshot inspected.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Agents in SSH workspaces: launch through the normal flow runs the harness on the remote host with its sink files written, tailed and answered through the ExecutionContext, status glyphs, notifications and the agent view consuming the same registry events, and remote cleanup on close; verified by the Docker sshd integration tests of the context and adapters and by --ssh-test launching an agent remotely through real SDL input.
<!-- SECTION:FINAL_SUMMARY:END -->
