---
id: TASK-85
title: >-
  Sidebar status icons in herdr's style: coloured dots for agents, tabs and
  workspaces
status: Done
assignee:
  - '@opus-5.5'
created_date: '2026-10-09 04:52'
updated_date: '2026-10-09 05:40'
labels:
  - agents
  - ui
milestone: m-6
dependencies:
  - TASK-80
  - TASK-84
priority: high
ordinal: 86000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The user compared Conduit with herdr (picture: herdr.png in the repo root, untracked; source https://github.com/herdrdev/herdr, Apache-2.0, src/client/shell.rs status_icon/status_color and src/workspace/aggregate.rs) and wants agents to look like that. Today the glyph in front of a tab, a workspace row and an agent row is one of · ▸ ? ! ✓ × drawn in the row's own foreground, so a glance at the sidebar does not say which tab needs a human. herdr marks every pane, tab and workspace with a coloured status icon in one of two styles chosen by a setting: dots (● for working, blocked and done, ○ idle, · unknown) or symbols (◐ working, × blocked, ✓ done, ○ idle, · unknown), coloured working=yellow, blocked=red, done=teal, idle=green, unknown=dim, and the tab and workspace carry their most urgent agent's icon. Conduit keeps its six states (idle, working, waiting_input, waiting_permission, done, errored): waiting_input and waiting_permission are both herdr's blocked (the row's state word still tells them apart), errored is a Conduit extra drawn as × in the danger colour in both styles, and done stays until the record is forgotten as TASK-80 decided (herdr's done-until-seen rule is deliberately not adopted). The icon is the only coloured part; row text keeps its role. The icon positions, the <row>.agent.<state> semantic elements and the roll-up to tab and workspace rows exist already (TASK-56, TASK-80); this task changes what is drawn, in which colour, and adds the style setting. Keep the glyphs in the bundled face (no emoji), keep it harness-neutral (invariant 9) and read colours from the theme roles so every bundled theme applies.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A sidebar.status_icons setting with values dots (default) and symbols exists in config, docs/config.md and the settings view's Agents group, hot-reloads, and a bad value is a config.error line that keeps the previous value
- [x] #2 In dots style working, waiting_input, waiting_permission and done draw ●, idle draws ○; in symbols style working draws ◐, waiting_input and waiting_permission draw ×, done draws ✓, idle draws ○; errored draws × in both styles; a unit test pins both tables
- [x] #3 The icon colour is yellow for working, red for waiting_input and waiting_permission, cyan for done, green for idle and danger for errored, taken from the theme roles, on agent rows, tab rows and workspace rows alike, while the row text keeps its normal role; a unit test pins the colour table
- [x] #4 Tab and workspace rows show the icon of their most urgent agent as before and the <row>.agent.<state> semantic ids and the agent-row ids are unchanged, so the driver and accessibility see the same elements
- [x] #5 The deterministic --agent-test and the agent-notifications scenario pass with the new icons in both styles (the style switched through the settings file during the check), and a 640x360 screenshot showing working, blocked, done, errored and idle icons in colour was inspected
- [x] #6 docs/user-guide.md and docs/agents.md describe the icons, the colours and the setting; AGENTS.md records the change
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. config: sidebar.status_icons = dots|symbols (config.StatusIcons, default dots), parse/checkValue/copy/defaults document, unit test.
2. app_agents: statusIcon(style, state) with herdr's two tables (errored × in both) and statusRole(state) -> theme.Role (yellow/red/cyan/green/danger); formatAgentRow takes the style; unit tests pin both tables and the colours.
3. ui: InteractiveText lead_foreground/lead_bytes so only the leading icon takes the state colour over every state style; unit test.
4. font_sprite: draw U+25D0 (◐) procedurally because the bundled JetBrains Mono lacks it (○ ● × ✓ are in the face).
5. main: sidebar workspace/tab/agent rows lead with statusIcon in statusRole; agent row text back to .foreground (agentRowRole removed); settings view Agents group cycling row; semantic ids unchanged.
6. --agent-test: new icons, overlay colour checks per state, symbols by settings file, bad value, symbols through the screen-state checks, settings-view row by keyboard. agent-notifications scenario: settings row clicked to symbols plus screenshot.
7. Docs: config.md, user-guide.md, agents.md. Verify with zig build test, --agent-test, --settings-test, --config-test, a five-state 640x360 screenshot in both styles, and zig build e2e.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented on branch worktree-agent-a7855d3c9c23f3826 (commits 18465ce, eca4209, f1b6b9c).
- config.StatusIcons (dots|symbols, built-in dots), key sidebar.status_icons: parse, checkValue (`expected \`dots\` or \`symbols\``), copy, defaults document, unit test incl. bad value keeping the previous one.
- app_agents.statusIcon(style,state) and statusRole(state); unit tests pin both icon tables and the colour table. formatAgentRow takes the style.
- ui.InteractiveText.lead_foreground/lead_bytes: the leading icon keeps its colour over normal/hovered/focused styles; unit test. Touched src/ui.zig (not in the owned list; additive only).
- font_sprite draws U+25D0 ◐ (JetBrains Mono has ○ ● × ✓ but not ◐; fc-query charset checked); unit test. Touched src/font_sprite.zig.
- main.zig: workspace/tab/agent rows lead with the icon in its role; agentRowRole removed (agent row text is .foreground); settings Agents group gets a cycling sidebar.status_icons row; ids unchanged.
- Unchanged on purpose (out of scope): stateGlyph still feeds the agent manager rows, Agent: stop/focus choices, the prompts heading and the backlog card badge, so those still show · ▸ ? ! ✓ ×.
Evidence: zig fmt --check clean; zig build ok; zig build test 1043/1067 passed, 22 skipped, 2 failed: platform driver-transport tests fail with EndpointTooLong because testing.tmpDir under this worktree's .zig-cache makes a 111-byte Unix socket path (environmental, platform.zig untouched). xvfb --agent-test exit 0 (67 ok, 0 FAIL) incl. per-state overlay colour checks in dots, symbols by settings file, bad value as config.error, the screen-state checks in symbols, and the settings-view row by keyboard. --settings-test (40 ok) and --config-test (25 ok) exit 0. zig build e2e (artifact dir /tmp/claude-1000/c85e2e, short path for the socket limit): 22 passed, 0 failed; agent-notifications now clicks the settings row to symbols and its last frame shows cyan ✓ icons. 640x360 conduit-test screenshots with five fake agents (errored, done, permission, working, idle) inspected in both styles: dots red/cyan/red/yellow ●, green ○, red ×; symbols ×, ✓, ×, ◐, ○ in the same colours, row text uncoloured.

Coordinator: merged at c7bc8f0; the full local gate (fmt, build, 1051 unit tests, every built-in check, 22/22 e2e) passed on main; the dots and symbols crops were inspected by the coordinator (coloured dots, ◐ sprite, uncoloured row text). CI 37887539231/37887539194 green on 0d98b3f.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Added sidebar.status_icons = dots|symbols (default dots, hot-reloaded, settings-view row, bad value keeps the previous style) and herdr's icon tables with theme-role colours on agent, tab and workspace rows through ui.InteractiveText.lead_foreground/lead_bytes; ◐ is a font sprite. Verified by unit tests for both tables and the colours, --agent-test (every state's icon colour on the overlay, the switch to symbols through the file and the settings view), the agent-notifications scenario, inspected 640x360 frames in both styles, the full local gate and the hosted CI.
<!-- SECTION:FINAL_SUMMARY:END -->
