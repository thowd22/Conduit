---
id: TASK-89
title: The font-picker e2e scenario intermittently fails at the clicked choice
status: To Do
assignee: []
created_date: '2026-10-09 05:39'
labels:
  - ui
  - tests
dependencies: []
priority: medium
ordinal: 90000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
On 2026-10-09 the local gate's zig build e2e failed the font-picker scenario twice in a row at the wait after the click on the second font choice (palette.choice.51.1, DejaVu Sans Mono): the diagnostic frame showed the dialog still open with that row highlighted and the preview still naming the bundled face, the application log showed no preview rebuild and no commit after the click, and the wait reported a driver error (the wait_for timeout). The same steps then passed five of five times by hand through conduit-test on a 24-bit display, and two further full suite runs (xvfb-run and a persistent display) passed 22/22. The gate for TASK-85 earlier that day had passed, so the failure is a timing-dependent path in the click-to-commit sequence of the font picker (TASK-40: a hover after real pointer motion previews by rebuilding the manager, and the previewed face's cell height moves the rows under the pointer), not a regression from TASK-86/87. An earlier session saw the same scenario time out while other work loaded the box. AGENTS.md says a flaky test is a bug to fix, not to retry: find the race (likely the pointer motion, the preview rebuild and the press landing on a moved or re-registered row), fix it in the app or make the scenario's steps robust without weakening what it proves, and record the cause.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The cause of the intermittent failure is identified and recorded in the task notes with evidence from logs or a reproduction
- [ ] #2 The font-picker scenario passes 20 consecutive runs under xvfb-run on the dev box after the fix
- [ ] #3 The fix does not weaken what the scenario proves (keyboard preview and revert, a clicked commit written to the settings file)
<!-- AC:END -->
