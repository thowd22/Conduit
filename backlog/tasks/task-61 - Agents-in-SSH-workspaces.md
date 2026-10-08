---
id: TASK-61
title: Agents in SSH workspaces
status: In Progress
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-08 00:09'
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
<!-- SECTION:PLAN:END -->
