---
id: TASK-56
title: Agent notifications
status: In Progress
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-07 21:01'
labels:
  - agents
  - notifications
milestone: m-6
dependencies:
  - TASK-28
  - TASK-52
priority: high
ordinal: 56000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Notify when an agent needs attention (permission, input, finished, errored): status glyphs on sidebar tabs and workspaces, an in-app terminal-styled notification list reachable from the palette, and native OS notifications when the window is unfocused. Clicking a notification focuses the agent. Also honor terminal notification sequences (OSC 9/777, bell). Per-harness and per-event settings.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Sidebar shows per-agent state glyphs that update live
- [ ] #2 OS notification is raised when an agent needs attention and the window is unfocused
- [ ] #3 Activating a notification focuses the relevant workspace and agent
- [ ] #4 Notification types can be enabled or disabled in config
- [ ] #5 E2E scenario with the fake adapter covers the notification flow
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. term: surface OSC 9 and OSC 777 notifications (title/body, bounded) as terminal events beside BEL.
2. app agent runtime: own agent.Registry and adapters; palette action agent.launch (choose harness, optional prompt) that spawns the adapter's LaunchSpec through the workspace ExecutionContext into an agent_terminal session in a new tab, writes sink files/extension, and polls adapter events on the loop into the registry; heuristics from terminal events for every session; observed-agent detection on demand.
3. Sidebar: per-agent state glyphs on tabs and workspaces updated live from the registry.
4. Notifications: a bounded in-app list (palette action notifications.open, clickable rows focus the workspace/tab/agent), OS notification via platform when the window is unfocused (Linux: notify-send through the context when present; best effort), config keys notifications.* per harness/event.
5. --agent-test with the FakeAdapter and a fifteenth e2e scenario driving a fake agent through permission -> notification -> focus; docs.
<!-- SECTION:PLAN:END -->
