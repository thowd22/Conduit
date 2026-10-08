---
id: TASK-81
title: 'Windows: observe hand-started agents through the ConPTY process tree'
status: To Do
assignee: []
created_date: '2026-10-08 19:16'
labels:
  - agents
  - windows
milestone: m-6
dependencies:
  - TASK-49
  - TASK-56
  - TASK-80
priority: high
ordinal: 82000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
On Windows a hand-started claude, codex, pi/omp or opencode never appears in the sidebar: pty.Pty.foregroundProcess is implemented only by the POSIX backend (tcgetpgrp + /proc) and the ConPTY backend returns null, so app_agents.Runtime.checkForeground never sees a program. herdr (https://github.com/herdrdev/herdr, src/platform/windows.rs and src/detect/mod.rs) solves this with a CreateToolhelp32Snapshot walk from the pane's shell pid, selecting the descendant that owns the console as the 'foreground job', reading its command line with NtQueryInformationProcess(ProcessCommandLineInformation) and its cwd from the PEB's RTL_USER_PROCESS_PARAMETERS via ReadProcessMemory, with a 250 ms snapshot cache, and name mapping that strips .exe/.cmd/.bat/.ps1/.js, looks through node.exe/bun/python/sh/cmd /c/powershell -Command|-File runtimes to the script argument, and recognises npm package paths (e.g. node_modules\@anthropic-ai\claude-code\cli.js → claude). Conduit must do the equivalent behind the pty backend and agent.commandName: the ConPTY backend implements foregroundProcess by snapshotting processes, taking the descendants of its child pid and choosing the deepest most recently started leaf (ties: highest start time), filling ForegroundProcess{pid, argv0, argv1, cwd} from the command line (argv split with Windows quoting rules; cwd from the PEB when readable, else empty), cached for 250 ms; agent.commandName gains the Windows spellings (case-insensitive, extension stripped, node.exe/cmd.exe/powershell.exe/pwsh.exe runtimes resolved to their script or /c|-Command|-File argument, npm shim .cmd files and node_modules package directories such as @anthropic-ai/claude-code, @openai/codex, opencode-ai, @mariozechner/pi mapped to the harness name). Keep everything behind pty and agent; nothing in app changes.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 On the hosted Windows runner, starting the scripted conduit-fake-agent by hand in a pwsh or cmd tab adds the observed agent row and glyph (extend --agent-test's observed section to run on Windows and gate it in windows.yml)
- [ ] #2 On the hosted Windows runner an npm-installed Claude Code (npm i -g @anthropic-ai/claude-code, unauthenticated, stopping at onboarding) started by hand as 'claude' in a pwsh tab is observed as '· claude idle' within a few seconds, and leaving it (Ctrl+C) marks the row done; the step is gating in windows.yml
- [ ] #3 agent.commandName unit tests cover claude.exe, claude.cmd via node.exe with the @anthropic-ai/claude-code cli.js path, codex via node.exe and the @openai/codex bin, omp.exe, opencode.exe, cmd.exe /c claude, pwsh -Command claude, and plain shells returning no harness; all run on every platform
- [ ] #4 The ConPTY foregroundProcess is unit-tested on Windows with a real cmd.exe child running a nested program (e.g. 'cmd /c ping -n 30 127.0.0.1' or a PowerShell sleep) and returns that leaf's pid, argv0, argv1 and cwd; the snapshot is cached so --agent-test's 2 s checks cost one snapshot
- [ ] #5 AGENTS.md's TASK-56 observed-agents note and docs/agents.md say Windows now observes hand-started agents; macOS stays documented as not implemented
<!-- AC:END -->
