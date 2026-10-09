---
id: TASK-85
title: >-
  Sidebar status icons in herdr's style: coloured dots for agents, tabs and
  workspaces
status: To Do
assignee: []
created_date: '2026-10-09 04:52'
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
- [ ] #1 A sidebar.status_icons setting with values dots (default) and symbols exists in config, docs/config.md and the settings view's Agents group, hot-reloads, and a bad value is a config.error line that keeps the previous value
- [ ] #2 In dots style working, waiting_input, waiting_permission and done draw ●, idle draws ○; in symbols style working draws ◐, waiting_input and waiting_permission draw ×, done draws ✓, idle draws ○; errored draws × in both styles; a unit test pins both tables
- [ ] #3 The icon colour is yellow for working, red for waiting_input and waiting_permission, cyan for done, green for idle and danger for errored, taken from the theme roles, on agent rows, tab rows and workspace rows alike, while the row text keeps its normal role; a unit test pins the colour table
- [ ] #4 Tab and workspace rows show the icon of their most urgent agent as before and the <row>.agent.<state> semantic ids and the agent-row ids are unchanged, so the driver and accessibility see the same elements
- [ ] #5 The deterministic --agent-test and the agent-notifications scenario pass with the new icons in both styles (the style switched through the settings file during the check), and a 640x360 screenshot showing working, blocked, done, errored and idle icons in colour was inspected
- [ ] #6 docs/user-guide.md and docs/agents.md describe the icons, the colours and the setting; AGENTS.md records the change
<!-- AC:END -->
