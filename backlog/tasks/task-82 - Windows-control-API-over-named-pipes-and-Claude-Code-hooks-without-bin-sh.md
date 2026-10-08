---
id: TASK-82
title: 'Windows: control API over named pipes and Claude Code hooks without /bin/sh'
status: Done
assignee: []
created_date: '2026-10-08 19:16'
updated_date: '2026-10-08 21:11'
labels:
  - agents
  - windows
  - control
milestone: m-6
dependencies:
  - TASK-60
  - TASK-49
  - TASK-78
priority: high
ordinal: 83000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
On Windows a launched agent gets no structured events: the control endpoint does not start there (control.runtimeDirectory returns null on Windows; docs/control-api.md: 'Windows has no control transport'), so conduit control agent.event is unavailable, and the Claude Code adapter registers every hook as '/bin/sh <sink>/hook.sh <Hook>' (writeHookCommand), which Windows cannot run, so even the sink relay fails; the agent then shows only PTY heuristics. The test driver already has a protected Windows named-pipe transport in platform (TASK-21: 'protected Windows named pipes', DriverTransport/DriverClient with Windows security descriptors). Port the control server and the conduit control / conduit instance clients to that transport on Windows: endpoint names like \\.\pipe\conduit-<uid>-r-<hex> for the run endpoint and \\.\pipe\conduit-<uid>-instance for the instance endpoint, rejecting remote clients and other users exactly like the driver pipe, with the same token scoping; CONDUIT_CONTROL_ENDPOINT then carries the pipe name. Then make the Claude Code adapter's hooks Windows-safe: on Windows every hook command (including PermissionRequest) runs the conduit executable directly ('<conduit.exe>' control agent.event --event=<Hook>, and for PermissionRequest a blocking 'control agent.permission --wait' variant that returns Claude Code's allow/deny JSON once the human answers in the agent view, mirroring what hook.sh does through decisions/), so no /bin/sh is involved; keep the POSIX relay elsewhere. Codex, Pi and OpenCode keep their current Windows status (document it). Record the design as a Backlog decision.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 On the hosted Windows runner the control endpoint starts in a plain run, local tab shells get CONDUIT_CONTROL_ENDPOINT/TOKEN/SESSION, and --control-test (ported: tab.open, pane.split, tab.status, notify, agent.event from a pwsh tab, the scratchpad exclusion, a stolen token refused, instance.ping from a separate process) passes and gates in windows.yml; a connection from another user or a remote client is refused
- [x] #2 On Windows the Claude Code launch spec registers hooks that invoke conduit.exe control agent.event for every hook and the blocking permission variant for PermissionRequest, with unit tests on every platform asserting the generated settings.json; the Linux relay path is unchanged and its tests still pass
- [x] #3 A deterministic check (extend --agent-test or --control-test on Windows) proves a launched fake agent on the runner delivers structured events through conduit control agent.event into the agent view, and a permission request answered in the view returns the allow decision to the waiting hook process
- [x] #4 A Backlog decision records the named-pipe control transport and the Windows hook strategy; docs/control-api.md, docs/agents.md and AGENTS.md drop the 'no Windows transport' statements
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Merged to main (fb38675). Evidence: windows.yml 37843312128 (15/15 required checks incl. --control-test; both endpoints as per-user named pipes; stand-in Claude Code's hooks via conduit.exe; permission answered in the agent view returned allow to the waiting hook; screenshots inspected by the agent), ci.yml 37843312002 green on three OSes, Linux gate 37843312098 green; decision-13 recorded; docs updated. Unverified: real Claude Code on Windows and its hook shell, Codex/Pi/OpenCode on Windows, Windows PowerShell 5.1.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Windows control transport over protected named pipes reusing the driver's pipe seam, Claude Code hooks that call conduit.exe directly with a blocking permission variant, --control-test gating on the Windows runner with a stand-in Claude Code whose permission round-trips through the agent view; decision-13.
<!-- SECTION:FINAL_SUMMARY:END -->
