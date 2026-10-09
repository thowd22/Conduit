---
id: TASK-86
title: 'Agent rows say what the agent is doing, and a click shows its terminal'
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
- [x] #1 The agent row reads <icon> <harness>  <detail>; detail is the stripped terminal title when set, else the backlog task id of a task-launched agent, else the state word; the title is sanitised and cut with an ellipsis to the row width; unit tests cover the stripping (braille frames, each Claude glyph, whitespace, a title that is only a glyph) and the fallback order
- [x] #2 The row's semantic label carries the harness, the state word and the detail, the agent-row and <row>.agent.<state> ids are unchanged, and sidebar.agents = false still hides the rows
- [x] #3 Click or Enter on a row shows the agent's workspace, tab and pane with its terminal visible even when an agent view covered it; activating the row again while that terminal is presented toggles the agent view; keyboard parity through the sidebar rows is unchanged
- [x] #4 The deterministic --agent-test and the agent-notifications scenario prove the row text (the fake sets a title through OSC 2 with a leading spinner frame, and the row shows it stripped), the terminal-first activation and the second-activation toggle, by mouse and by keyboard; the row frame was inspected
- [x] #5 A real hand-started Claude Code (against the local Messages API stand-in, no account) shows its own title in its row and a click on the row shows its TUI; the evidence is in the task notes
- [x] #6 docs/user-guide.md, docs/agents.md and AGENTS.md describe the row and the click
- [x] #7 The agent manager rows, the Agent: stop and Agent: focus choice lists, the agent prompts heading and the backlog card badges use the configured status icon too, so one state looks the same everywhere
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. app_agents: pure title helpers (sanitizeTitle: drop C0/C1/DEL and malformed UTF-8, bounded copy; strippedTitle: herdr's leading braille/Claude activity glyph strip; rowDetail fallback title > TASK-N > null=state word) and formatAgentRow returning a semantic label '<icon> <harness> <state>[: <detail>]' (existing labels unchanged when there is no detail) plus painted '<icon> <harness>  <detail>' ellipsized to the row; unit tests.
2. ui.InteractiveText: optional painted text (semantic label stays canonical, like Text rows whose runs differ from the label) and a muted tail run; ui unit test.
3. main sidebar: read the agent session's terminal title, taskId, build the row; invalidate the UI on an agent session's title event.
4. agentRowAction: terminal first (close a covering view), toggle the view only when the terminal was already presented.
5. statusIcon everywhere stateGlyph was used (manager rows, stop/focus choices, prompts heading, backlog badge); remove stateGlyph; update test expectations.
6. --agent-test: observed fake 'title' step sets OSC 2 with a braille frame; assert label and painted overlay text; rework row activation checks (terminal first, second toggles) by click and Enter. agent-notifications scenario: same flow; screenshots inspected.
7. Real Claude Code against the Messages API stand-in; record the row label and screenshot.
8. docs/user-guide.md, docs/agents.md sections; AGENTS.md paragraph in notes.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implementation (branch worktree-agent-abd4252c0b5b8cfdc):
- app_agents: sanitizeTitle (C0/C1/DEL -> space, malformed UTF-8 dropped, bounded copy), strippedTitle (herdr's rule: one leading braille U+2800..U+28FF or one of · ✢ ✳ ✶ ✻ ✽ ◐ ◓ ◑ ◒ when followed by whitespace or alone; trimmed; empty -> none), rowDetail (title > task id > none), formatAgentRow now returns AgentRow{label, painted, icon_bytes, detail_from}: label `<icon> <harness> <state>[: <detail>]` (unchanged when there is no detail, so existing label checks hold), painted `<icon> <harness>  <detail or state word>` cut to the row with `…`. Titles keep at most 192 bytes (agent_row_detail_bytes). stateGlyph removed; unit tests cover braille frames, every Claude glyph, whitespace/tab, glyph-only and blank titles, glued glyphs, sanitising, the cap and the fallback order.
- ui.InteractiveText: optional `painted` text (paint only; the label stays the one semantic representation, as a Text's runs may cut its label) and `tail_foreground`/`tail_from` for a dim tail (not when focused). addInteractiveText refuses non-UTF-8 painted text. ui unit test added. (ui.zig was not on the owner list; the change is additive.)
- main: the sidebar reads the agent session's terminal title (term.Terminal.title, existing accessor) and the runner's taskId; the row paints icon in statusRole, harness in foreground, detail muted. A title event on an agent session invalidates the UI. agentRowAction: shows workspace/tab/pane with the terminal; a runner's view that was active is closed; the view opens only when the activation found that terminal already presented. Agent manager rows, Agent: stop/focus choices (rebuilt on config reload too), prompts heading and backlog badges use statusIcon(sidebar.status_icons).
- No new logging of titles. Note: the pre-existing noteTerminalEvent already logs titles at debug level ("program set the title to ..."); unchanged.

Checks (all under xvfb-run -a, Linux):
- zig build test: only the two known platform EndpointTooLong worktree-path failures (1048/1072 passed, 22 skipped).
- --agent-test 0 failures: hand-started fake sets `\033]2;⠋ Fixing the tests\007`; label `× fake input: Fixing the tests`, painted (read back from the overlay) `× fake  Fixing the …` (20-cell row at 640 px), detail cell muted, name foreground; after exit `✓ fake done: Fixing the tests`. Terminal-first by click (no view), second click opens the view, a click from another tab closes a covering view, sidebar Enter opens the view over the presented terminal and closes it again, Down+Enter from another tab shows the terminal, observed row: first click terminal, second click view. Rows frame inspected (✓ fake  Fixing the …, × fake  input, ○ fake  idle beside the agent view).
- --agent-manager-test 0 failures (new: row leads with `● Fake agent`); --agent-prompts-test 0 failures (new: heading `● Fake agent #1 ...`); --backlog-test 0 failures (badges now `○ Fake agent idle` / `● Fake agent working`, were `·`/`▸`); --agent-view-test 0 failures.
- zig build e2e -- --artifact-dir=/tmp/claude-1000/c86e2e: 22 passed. agent-notifications now: click row -> FAKE-STEP 3 terminal and no view; second click -> view; first tab then click -> terminal, view gone; keys Enter -> view; keys Enter -> closed; observed fake `title` step; screenshots 3, 4 and 7 inspected (terminal after first click, view after second, `● fake  Fixing the …` row in red input). The driver has no label wait, so the scenario proves the title through the screenshot and the retained semantic tree (`✓ fake done: Fixing the tests`).

Real Claude Code 2.1.292 (hand-started, isolated HOME seeded past onboarding, local Messages API stand-in on 127.0.0.1, fake key, no account), in a conduit-test run at 800x400 on DISPLAY=:99:
- right after start the driver reported `● claude input: Claude Code` (its default `✳ Claude Code` title, glyph stripped);
- after the prompt `please fix the login bug` Claude Code asked the stand-in for a title and set it; the driver reported `● claude input: Fix login bug`;
- from a new Terminal 2, a click on workspace.1.tab.1.agent-row.1 showed tab 1 with Claude Code's own TUI (prompt, `Ran 1 shell command`, `Done.`), no agent.view element; screenshot inspected, row painted `● claude  Fix login…`;
- a second click opened agent.view.1 (sparse: waiting for input / working rows; screenshot inspected), a third closed it;
- after /exit the row read `● claude done` (Claude Code cleared its title on exit).
- ~/.local/bin/claude still points at /home/admin2/.local/share/claude/versions/2.1.292, which exists.

Proposed AGENTS.md paragraph:
TASK-86 is complete on Linux. A sidebar agent row reads `<icon> <harness>  <detail>`: the agent terminal's OSC 0/2 title with one leading activity glyph stripped as herdr does (a braille frame U+2800..U+28FF or one of `· ✢ ✳ ✶ ✻ ✽ ◐ ◓ ◑ ◒` followed by whitespace or alone; `app_agents.strippedTitle`), else the backlog task id of a task-launched agent, else the state word. The title is sanitised (`sanitizeTitle`: controls become spaces, malformed UTF-8 is dropped, at most 192 bytes), cut with `…` at the row, painted muted after the harness name and never logged or acted on. The semantic label is `<icon> <harness> <state>` plus `: <detail>` when there is one, so labels without a title are unchanged; `ui.InteractiveText` gained paint-only `painted` text and a `tail_foreground`/`tail_from` dim tail for this. Activating a row shows the agent's workspace, tab and pane with its terminal, closing a view that covered it; only an activation while that terminal is already presented toggles the agent view (Ctrl+Shift+A, the palette, the manager and the backlog detail are unchanged). The agent manager rows, the Agent: stop/focus choices, the prompts heading and the backlog badges use `statusIcon` in the configured style, and `stateGlyph` is gone. `--agent-test` and the agent-notifications scenario cover the title (the hand-started fake sets `⠋ Fixing the tests` through OSC 2), terminal-first activation and the second-activation toggle by mouse and keys; a real hand-started Claude Code 2.1.292 against a local Messages API stand-in showed `● claude input: Fix login bug` and a click on its row showed its TUI. The e2e driver has no label wait, so the scenario's title evidence is its screenshot and retained semantic tree. macOS and Windows are unverified.

Coordinator: merged at 9782505 after a rebase onto TASK-87 (docs/agents.md sections kept in row-then-view order); the full local gate passed on main except one font-picker e2e flake that passed 22/22 on two reruns and 5/5 by hand (tracked as TASK-89).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Agent rows read <icon> <harness>  <detail> with the stripped terminal title, the backlog task id or the state word; activating a row shows the terminal first and only a second activation toggles the agent view; the manager, choice lists, prompts heading and backlog badges use the configured icon. Verified by unit tests (stripping, sanitising, fallback order), --agent-test, --agent-manager-test, --agent-prompts-test, --backlog-test, the agent-notifications scenario, inspected frames, a real hand-started Claude Code 2.1.292 showing '● claude input: Fix login bug' and its TUI on click, and the full local gate.
<!-- SECTION:FINAL_SUMMARY:END -->
