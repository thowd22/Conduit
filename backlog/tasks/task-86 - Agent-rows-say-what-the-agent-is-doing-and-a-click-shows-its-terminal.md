---
id: TASK-86
title: 'Agent rows say what the agent is doing, and a click shows its terminal'
status: To Do
assignee: []
created_date: '2026-10-09 04:52'
labels:
  - agents
  - ui
milestone: m-6
dependencies:
  - TASK-80
  - TASK-85
priority: high
ordinal: 87000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The user's words: 'It just saying claude working doesnt really show me anything. When an agent is clicked, I should see its output and reasoning, that way I can see what its doing. herdr does this really well.' Today a sidebar agent row (TASK-80) reads <glyph> <harness> <state> and activating it focuses the pane and opens the structured agent view over it; for a hand-started agent that view is empty ('no structured events yet; the terminal has the full session'), so the click hides the very output the human wanted. In herdr (https://github.com/herdrdev/herdr, Apache-2.0; src/ui/sidebar/tokens.rs, src/terminal/title.rs, src/config/sidebar.rs) the agent row is the status icon plus names and, optionally, the pane's terminal title with the harness's leading activity glyph stripped (a braille spinner U+2800..U+28FF or one of · ✢ ✳ ✶ ✻ ✽ ◐ ◓ ◑ ◒ followed by whitespace), and clicking the row shows the pane itself: the harness's own live TUI, where its output and visible reasoning already are. Do the same: the row reads <icon> <harness>  <detail>, where detail is the session's stripped terminal title when the harness set one (Claude Code titles its window with a summary of the conversation), else TASK-N when the agent was started from a backlog task (TASK-64), else the state word; the title is untrusted terminal text (sanitised, ellipsized to the row, never acted on, never logged). Activating the row shows the agent's workspace, tab and pane with the terminal visible, closing an agent view that was covering it; only an activation while that terminal is already presented toggles the structured view, which also stays on Ctrl+Shift+A, the palette, the agent manager and the backlog detail. The sidebar icons come from TASK-85; the view's reasoning rows come from TASK-87.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The agent row reads <icon> <harness>  <detail>; detail is the stripped terminal title when set, else the backlog task id of a task-launched agent, else the state word; the title is sanitised and cut with an ellipsis to the row width; unit tests cover the stripping (braille frames, each Claude glyph, whitespace, a title that is only a glyph) and the fallback order
- [ ] #2 The row's semantic label carries the harness, the state word and the detail, the agent-row and <row>.agent.<state> ids are unchanged, and sidebar.agents = false still hides the rows
- [ ] #3 Click or Enter on a row shows the agent's workspace, tab and pane with its terminal visible even when an agent view covered it; activating the row again while that terminal is presented toggles the agent view; keyboard parity through the sidebar rows is unchanged
- [ ] #4 The deterministic --agent-test and the agent-notifications scenario prove the row text (the fake sets a title through OSC 2 with a leading spinner frame, and the row shows it stripped), the terminal-first activation and the second-activation toggle, by mouse and by keyboard; the row frame was inspected
- [ ] #5 A real hand-started Claude Code (against the local Messages API stand-in, no account) shows its own title in its row and a click on the row shows its TUI; the evidence is in the task notes
- [ ] #6 docs/user-guide.md, docs/agents.md and AGENTS.md describe the row and the click
<!-- AC:END -->
