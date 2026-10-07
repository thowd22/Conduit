---
id: TASK-73
title: Child shells inherit only a curated environment
status: In Progress
assignee:
  - '@claude'
created_date: '2026-10-07 04:41'
updated_date: '2026-10-07 04:50'
labels:
  - terminal
  - workspace
  - bug
milestone: m-3
dependencies: []
priority: high
type: bug
ordinal: 74000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Conduit builds every child's environment from scratch (COLORTERM, HOME, LANG, PATH, TERM, TERM_PROGRAM plus SHELL/USER) instead of passing the Local execution context's own environment through, citing the ExecutionContext principle. Found on 2026-10-07 while running omp inside Conduit on Wayland: a harness started directly saw no OPENROUTER_API_KEY because the key comes from the user's shell profile, and a shell inside Conduit also lacks DISPLAY, WAYLAND_DISPLAY, XDG_RUNTIME_DIR, XDG_SESSION_TYPE, DBUS_SESSION_BUS_ADDRESS, SSH_AUTH_SOCK, LC_* and the rest of the desktop session, so xdg-open, wl-copy/xclip, ssh-agent, gsettings, portals and MCP servers that need the session bus fail for programs run from Conduit. Other terminal emulators pass their environment to the Local shell; the ExecutionContext principle belongs to remote contexts (SSH/WSL), where the remote side supplies the environment.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A Local execution context starts children with the Conduit process's environment, with Conduit's own terminal identity variables (TERM, COLORTERM, TERM_PROGRAM) set on top and nothing else removed except variables that would leak the test driver or isolated-run configuration
- [ ] #2 A deterministic check proves a shell inside Conduit sees the launching session's DISPLAY or WAYLAND_DISPLAY, XDG_RUNTIME_DIR, DBUS_SESSION_BUS_ADDRESS and SSH_AUTH_SOCK when the launcher had them, and that conduit-test's isolated HOME/XDG overrides still apply to the app itself
- [ ] #3 Remote contexts remain explicit: the curated environment is kept only where a context cannot forward the local one, and the architecture guide records the rule
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Change ChildSpec construction so a Local execution context inherits the Conduit process environment, with TERM/COLORTERM/TERM_PROGRAM set on top and only test-driver/isolation variables removed.
2. Keep the curated builder for contexts that cannot forward the local environment and document the rule in docs/architecture.md.
3. Add unit tests for inheritance, overrides and removals, and a deterministic driver-path check that a child shell sees DISPLAY/WAYLAND_DISPLAY, XDG_RUNTIME_DIR, DBUS_SESSION_BUS_ADDRESS and SSH_AUTH_SOCK while the app keeps its isolated HOME/XDG.
4. Run the full Linux gate.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-10-07 implemented by an Opus agent: EnvSource can enumerate the process environment; ChildSpec.build/buildIn/buildInteractive take the workspace ExecutionContextKind and baseEnvironment switches on it with no default branch (.local inherits, .ssh/.wsl start curated); TERM/COLORTERM/TERM_PROGRAM set on top with PATH/HOME/LANG fallbacks; values held in std.process.Environ.Map so overrides replace rather than duplicate. Exclusions (ChildSpec.inherited_exclusions): CONDUIT_TEST_RUN, CONDUIT_TEST_ROOT (conduit-test addressing), CONDUIT_LOG_FILE (this run's truncated log), the four shell-integration handshake variables of an enclosing Conduit, and TERM_PROGRAM_VERSION. Driver endpoint/artifact dir travel only as flags; the launcher's isolated HOME/XDG/TMPDIR still reach children. Unit tests cover inheritance (probe, DISPLAY, WAYLAND_DISPLAY, XDG_RUNTIME_DIR, DBUS_SESSION_BUS_ADDRESS, SSH_AUTH_SOCK, LC_TIME), override uniqueness, exclusions, fallbacks, the scratchpad shell, the curated ssh/wsl path and a lookup-only source. Eighth E2E scenario child-environment (runner sets probe/agent-socket/driver variables for launch only) passes; real-driver probe showed PROBE_hello, DISP_:99, isolated HOME and DRV_unset. Agent gate: zig build test 544/552 (8 skips), e2e 8/8, self/driver/tabs/panes/scratchpad/workspaces/links/clipboard checks green.
<!-- SECTION:NOTES:END -->
