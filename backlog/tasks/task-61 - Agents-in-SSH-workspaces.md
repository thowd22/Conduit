---
id: TASK-61
title: Agents in SSH workspaces
status: In Progress
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-08 01:36'
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
- [ ] #1 An agent launched in an SSH workspace runs on the remote host
- [ ] #2 Status and notifications work for the remote agent
- [ ] #3 Agent view renders the remote agent's structured events
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
<!-- SECTION:NOTES:END -->
