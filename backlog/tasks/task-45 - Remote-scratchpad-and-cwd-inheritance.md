---
id: TASK-45
title: Remote scratchpad and cwd inheritance
status: Done
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-07 22:24'
labels:
  - ssh
  - scratchpad
milestone: m-5
dependencies:
  - TASK-17
  - TASK-32
  - TASK-43
priority: high
ordinal: 45000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
In an SSH workspace the scratchpad is a remote shell started in the background over the shared connection, and new tabs, panes and the scratchpad start in the remote working directory of the originating session when shell integration reports it.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Scratchpad in an SSH workspace runs on the remote host
- [x] #2 New panes and tabs start in the originating session's remote cwd when known
- [x] #3 Scratchpad session persists across hide/show and is restored after reconnect where possible
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. In an SSH workspace the scratchpad session spawns through the SshContext once connected (remote login shell), stays hidden until shown, and is respawned in place after reconnect.
2. New tabs and panes inherit the originating session's remote OSC 7 cwd (already validated per context) through the context-neutral spawn request.
3. Covered by --ssh-test; docs.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Landed in 7c24e5e: remote scratchpad over the shared master once connected, hidden until shown, surviving hide/show and restart; tabs and panes snapshot the originating session's remote OSC 7 cwd (accepted for the remote host's own name) and the session script does the remote cd; scratchpad respawned in place after reconnect. Proven by --ssh-test (remote uname in the scratchpad, split in /home/conduit/project/sub, tab in /tmp, restore after reconnect); the remote OSC 7 in the test comes from a PROMPT_COMMAND hook in the container because remote shell integration is still off. Gate green.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Remote scratchpad and cwd inheritance for SSH workspaces: the scratchpad runs remotely over the shared connection and persists across hide/show and reconnect, and new tabs and panes start in the originating session's remote working directory; verified by --ssh-test.
<!-- SECTION:FINAL_SUMMARY:END -->
