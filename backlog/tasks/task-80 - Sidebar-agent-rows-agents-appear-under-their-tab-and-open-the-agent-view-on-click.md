---
id: TASK-80
title: >-
  Sidebar agent rows: agents appear under their tab and open the agent view on
  click
status: To Do
assignee: []
created_date: '2026-10-08 17:03'
labels:
  - agents
  - ui
milestone: m-6
dependencies:
  - TASK-56
  - TASK-57
  - TASK-76
priority: high
ordinal: 81000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Today an agent (launched through Agent: launch or started by hand in a tab) only changes the glyph in front of its tab's name (· idle, ▸ working, ? input, ! permission, ✓ done, × errored), and the structured agent view is reached through Ctrl+Shift+A, the palette or the agent manager. The user expects what the product model in CONDUIT.md implies (agents are first-class children of a workspace; 'click the agent → focus it'): when an agent starts, a row appears dynamically in the sidebar nested under the tab it runs in, showing the harness and its live state, and clicking that row shows what the agent is doing (the agent view for that agent). Design: one InteractiveText row per agent record, directly under its tab's row (below the branch row when both exist), drawn with the same small secondary face as the branch row (decision-10), reading '<glyph> <harness> <state>' (e.g. '▸ claude working', '! codex permission', '✓ pi done'); the row is a semantic element 'workspace.<k>.tab.<n>.agent-row.<agent id>' (keep the existing '<row>.agent.<state>' glyph elements for compatibility). Enter or a click focuses the agent's workspace, tab and pane and opens the agent view for that agent (toggling it off on a second activation is fine); the row takes part in sidebar keyboard focus (Up/Down over tabs reach agent rows) so there is keyboard parity. Observed (hand-started) agents get a row too, with the harness name even before any structured event arrives, so starting 'claude' in a tab visibly adds a row. A finished agent's row stays until its record is forgotten (tab closed, restart, or the manager removes it), so the human sees the ✓/× outcome. The sidebar's list limit must account for the extra rows like it does for branch rows. Settings: a 'sidebar.agents' boolean (default true) in config and the settings view hides the rows for people who prefer glyphs only.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Launching an agent through Agent: launch adds a row under its tab reading '<glyph> <harness> <state>' within one frame of the agent registering, and the row's glyph and state text update live through working, waiting (input/permission), done and errored
- [ ] #2 Starting claude, codex, pi/omp or opencode by hand in a tab adds the same row (observed agent) with the harness name, and the row shows done when the program leaves the foreground
- [ ] #3 Clicking the row, or focusing it with the sidebar keys and pressing Enter, focuses the agent's workspace, tab and pane and shows the agent view for that agent; the branch row, tab reorder by drag and the sidebar list limit still behave with the extra rows present
- [ ] #4 The deterministic Linux check (extend --agent-test) and the agent-notifications or agent-view scenario cover launched and observed agents by keyboard and by mouse, and an inspected screenshot shows the nested rows beside the agent view
- [ ] #5 The config key sidebar.agents and its settings-view row hide the rows; docs/user-guide.md and docs/config.md describe them
<!-- AC:END -->
