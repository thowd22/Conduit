---
id: TASK-44
title: Remote connection manager
status: In Progress
assignee:
  - '@claude'
created_date: '2026-10-03 21:39'
updated_date: '2026-10-07 21:43'
labels:
  - ssh
  - palette
milestone: m-5
dependencies:
  - TASK-31
  - TASK-43
priority: medium
ordinal: 44000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Palette commands for Remote: Connect (hosts from ~/.ssh/config, saved hosts and ad hoc user@host), saved connection profiles, recent connections, and opening a remote workspace at a chosen directory.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Palette lists hosts from ssh config and saved profiles with fuzzy search
- [ ] #2 Ad hoc user@host connections can be entered and optionally saved
- [ ] #3 Connecting creates an SSH workspace visible in the sidebar
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Palette action remote.connect: fixed-choice list of hosts from ~/.ssh/config (Host aliases parsed through the Local context, bounded), saved profiles and recent connections from the settings file (remote.profile/remote.recent keys), plus a free-text user@host[:port] step with an optional 'save' choice.
2. Connecting creates an SSH workspace (SshContext) in the registry, opens its connection session for OpenSSH's prompts, and shows it in the sidebar with its state.
3. --ssh-test against the sshd container (skipped without docker) and docs.
<!-- SECTION:PLAN:END -->
