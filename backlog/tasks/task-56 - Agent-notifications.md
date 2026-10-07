---
id: TASK-56
title: Agent notifications
status: Done
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-07 21:43'
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
- [x] #1 Sidebar shows per-agent state glyphs that update live
- [x] #2 OS notification is raised when an agent needs attention and the window is unfocused
- [x] #3 Activating a notification focuses the relevant workspace and agent
- [x] #4 Notification types can be enabled or disabled in config
- [x] #5 E2E scenario with the fake adapter covers the notification flow
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. term: surface OSC 9 and OSC 777 notifications (title/body, bounded) as terminal events beside BEL.
2. app agent runtime: own agent.Registry and adapters; palette action agent.launch (choose harness, optional prompt) that spawns the adapter's LaunchSpec through the workspace ExecutionContext into an agent_terminal session in a new tab, writes sink files/extension, and polls adapter events on the loop into the registry; heuristics from terminal events for every session; observed-agent detection on demand.
3. Sidebar: per-agent state glyphs on tabs and workspaces updated live from the registry.
4. Notifications: a bounded in-app list (palette action notifications.open, clickable rows focus the workspace/tab/agent), OS notification via platform when the window is unfocused (Linux: notify-send through the context when present; best effort), config keys notifications.* per harness/event.
5. --agent-test with the FakeAdapter and a fifteenth e2e scenario driving a fake agent through permission -> notification -> focus; docs.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Agent: src/app_agents.zig Runtime (Registry, Runner per agent with adapter/transport/EventQueue/poll worker, Heuristics per session, NotificationList, platform.notify seam with notify-send on Linux); term surfaces OSC 9/777; LaunchSpec.files written by the spawn worker into a 0700 sink; agent.launch/launch-prompt/stop/focus, notifications.open/clear/activate; glyphs ·▸?!✓× with semantic <row>.agent.<state>; notifications.* config keys + settings Agents group; --agent-test (fake adapter) and e2e agent-notifications (15 scenarios); --ui-test registry assertion now 68 actions. Bonus: real Claude launch spawned the hooked command into its sink (stopped at onboarding). Follow-ups: pi detect must read stderr; move Ctrl+Shift+N default into input tables; pty foreground-process query for observed agents; ExecutionContext.writeFile for remote sinks (TASK-61). Coordinator 2026-10-07: merged as dc30f3f; full gate green (813/824 unit tests, 23 checks incl. --agent-test, 15 scenarios); screenshot inspected (glyphs + list).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Agent runtime in the app plus notifications: registry and per-agent runners wired to the four adapters, launch/stop/focus palette actions, live sidebar state glyphs for agents and workspaces, an in-app notification list with focus-on-activate, OS notifications when unfocused, per-kind and per-harness config switches, OSC 9/777 terminal notifications; verified by unit tests, the deterministic --agent-test with the fake adapter, the agent-notifications scenario and the full local gate.
<!-- SECTION:FINAL_SUMMARY:END -->
