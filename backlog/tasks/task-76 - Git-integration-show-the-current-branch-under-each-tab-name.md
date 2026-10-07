---
id: TASK-76
title: 'Git integration: show the current branch under each tab name'
status: To Do
assignee: []
created_date: '2026-10-07 15:34'
labels: []
dependencies: []
priority: medium
ordinal: 77000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The sidebar lists tabs by name alone, so a user with several tabs in different checkouts (or on different branches of the same repo) has nothing in the sidebar telling them where each shell is. The user wants the current git branch shown directly under the tab name whenever the tab's tracked cwd is inside a git repository, the way the herdr app the user referenced does it: the branch text should be about half the size of the tab name text and slightly subdued (dimmer colour), so it reads as secondary information. Design notes a future agent cannot recover from the code: (1) the sidebar is laid out in terminal cells with the four UI primitives and the UI renderer draws text at the terminal cell size, so "half size" needs a decision on how the UI renderer draws smaller text (a second scaled face, or a reduced-height row) and that choice must be recorded as a Backlog decision; (2) the cwd comes from the session's OSC 7 tracking, and the repo/branch must be resolved through the workspace ExecutionContext (invariant 5) so SSH and WSL workspaces work, with no local filesystem assumption and no git process per frame (watch .git/HEAD or poll on cwd change / prompt mark); (3) a detached HEAD should show the short commit, a non-repo cwd shows nothing and reclaims the row; (4) tab rename, reorder and the sidebar inset must keep working with two-row tabs.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A tab whose tracked cwd is inside a git work tree shows the current branch name on the row beneath its name; a tab outside a repo shows no branch row and the list reclaims the space
- [ ] #2 The branch text renders at roughly half the height of the tab-name text in a subdued colour, verified by an inspected screenshot at scale 1 and at a fractional scale
- [ ] #3 The branch updates after a checkout in that tab (and after the cwd changes to another repo) without restarting Conduit, driven by the real OSC 7 cwd path, with no git subprocess started per frame
- [ ] #4 Repository and branch resolution goes through the workspace ExecutionContext, so a remote (SSH/WSL) workspace resolves them on the remote side; nothing outside the context implementations reads a local .git
- [ ] #5 A detached HEAD shows the abbreviated commit, and malformed .git contents never crash or hang the app
- [ ] #6 The branch is a semantic element with a stable id (child of the tab) so the driver can inspect and wait for it; rename, reorder, close and sidebar resize behave unchanged with two-row tabs
- [ ] #7 A deterministic Linux check or a zig build e2e scenario creates a real repo, switches branch in the tab and asserts the branch row through the real input path; the UI renderer change is recorded as a Backlog decision; AGENTS.md and docs/architecture.md are updated
<!-- AC:END -->
