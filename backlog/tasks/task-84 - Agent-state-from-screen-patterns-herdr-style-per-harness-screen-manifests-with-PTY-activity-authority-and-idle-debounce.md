---
id: TASK-84
title: >-
  Agent state from screen patterns: herdr-style per-harness screen manifests
  with PTY-activity authority and idle debounce
status: Done
assignee:
  - '@claude'
created_date: '2026-10-09 00:26'
updated_date: '2026-10-09 01:07'
labels:
  - agents
  - heuristics
milestone: m-6
dependencies:
  - TASK-81
  - TASK-80
priority: medium
ordinal: 85000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Observed (hand-started) agents and launched agents whose structured events are missing or late get their state only from Conduit's PTY heuristics (agent.Heuristics: output, title, BEL, OSC 9/777, OSC 133, human input, quiet, child exit), so a hand-started Claude Code, Codex, Pi/omp or OpenCode shows idle or working but never 'input' or 'permission' unless its hooks or API are wired. herdr (Apache-2.0, Rust) solves this with a per-agent manifest of screen patterns: each harness ships regexes matched against the visible terminal screen (the last N rows) that classify what the TUI is showing (a permission or approval prompt, a question or input request, a spinner or 'thinking' line, an error, the idle prompt). PTY output activity is the authority for 'working' (any output within a short window means working, whatever the screen says), the screen classifies the quiet states, and idle is debounced (herdr requires 3 consecutive idle confirmations with a 700 ms cap before leaving working) so spinner frames and short pauses do not flap the sidebar glyph. Do the same for Conduit under invariant 9: the manifest lives in each adapter under src/agent/ (claude_code, codex, pi, opencode) as compile-time data, agent.Heuristics gains a screen classifier that reads a bounded snapshot of the session's visible rows through the existing term read path (never scrollback, never logged), and structured events keep precedence as today. Screen text is untrusted: it may only move the heuristic state, never answer a prompt or trigger an action. Record the pattern lists with the exact harness version they were captured from, and capture fixtures (scrubbed screen snapshots) under src/agent/<harness>/fixtures or testdata. Reference: https://github.com/herdrdev/herdr (Apache-2.0; clone it fresh into scratch, the coordinators 2026-10-08 clone was removed). Look at its per-agent manifests and the idle debounce logic before designing Conduits version.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Each adapter under src/agent/ publishes a ScreenManifest of bounded patterns for working, input, permission and errored, matched by agent.Heuristics against a bounded snapshot of the visible rows only, with structured events still taking precedence and screen text never triggering any action
- [x] #2 Output activity is the authority for working, and leaving working for idle requires a debounce (consecutive quiet confirmations with a time cap) so spinner frames do not flap the glyph; unit tests with recorded screen fixtures cover every harness and the debounce
- [x] #3 A hand-started real Claude Code on Linux shows '? claude input' at its prompt-for-input and '! claude permission' at a tool approval prompt, observed through the sidebar agent row, with the evidence recorded in the task
- [x] #4 The deterministic Linux --agent-test and the agent-notifications e2e scenario drive the fake agent's screen patterns through real PTYs and SDL input, including the debounce, and AGENTS.md and docs/agents.md describe the screen layer and its limits
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Read herdr (cloned to scratch): per-agent TOML manifests (rules of literals/regexes over bottom-row regions, priority, visible_blocker), PTY activity as the working authority, PendingIdleConfirmation (3 confirmations 100 ms apart, 700 ms cap).
2. agent/screen.zig: ScreenManifest (permission/working/errored/input lists of bounded Patterns: case-folded literals, row-start anchor, bottom-N-non-blank-rows region; comptime validate), classify with priority permission > working > errored > input.
3. term.activeScreenText: bottom rows of the active screen read from the engine (no refresh, no scrollback, no allocation, bounded buffer).
4. agent.Heuristics: tick carries an optional screen snapshot (wantsScreen/wantsFastTicks), screen names quiet states, permission outranks activity, states named by the screen survive redraws, plain idle debounced; quiet_after 1 s, working hold 3 s.
5. Manifests per adapter from real captures (Claude Code 2.1.292, Codex 0.160.1, Pi 0.73.1 against local API stand-ins; OpenCode from documented strings, unverified) with scrubbed fixtures and tests; agent.screenManifest(harness), fake manifest.
6. app_agents: Track picks the manifest from the runner's choice, ticks every 100 ms while working, reads the screen through a new SessionProbe.screen_fn the composition root implements with activeScreenText.
7. Fake agent screen phase in --agent-test and agent-notifications e2e (input, permission, spinner burst debounce, error).
8. Real hand-started Claude Code inside a driven Conduit against a local Messages API stand-in: row shows ? claude input and ! claude permission.
9. Docs: docs/agents.md and an AGENTS.md paragraph.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
From herdr (Apache-2.0, cloned to scratch; src/detect/manifests and src/pane/agent_detection.rs): per-harness manifests of conjunctive needles over bottom-row regions with a priority order and a visible blocker outranking activity; output activity as the working authority with the screen naming quiet states; the pending-idle confirmation (3 confirmations 100 ms apart, 700 ms cap). Not taken: regexes (Conduit uses case-folded literals and a row-start anchor), OSC title rules, transcript-viewer skips.

Captures, no account and no credentials read or copied: Claude Code 2.1.292 (the versioned binary through a private symlink, isolated HOME, ANTHROPIC_BASE_URL at a local Messages API stand-in, --permission-mode default); Codex 0.160.1 (isolated CODEX_HOME, local Responses API stand-in, on-request approvals with a read-only sandbox, an escalated exec_command); Pi 0.73.1 (isolated PI_CODING_AGENT_DIR, a slowed copy of pi/testdata/mock_chat.py, Conduit's conduit.js with CONDUIT_AGENT_GATE=1). OpenCode is not installed: its strings come from herdr's manifest, unverified, with no error or input patterns. Aside: ~/.local/bin/claude on this box is a dangling symlink into a removed /tmp test directory; left untouched.

Validation: zig build test passes except the two known platform EndpointTooLong tests; zig build; xvfb-run -a conduit --agent-test 0 failures (row ? fake input, ! fake permission, × fake errored, ▸ fake working held through a six-frame burst over 136 samples, · fake idle 1429 ms after the burst, never sooner than the debounce allows); xvfb-run -a zig build e2e with a private artifact dir: 22 passed, 0 failed; the agent-notifications permission frame was inspected.

AC3 evidence, a real Claude Code 2.1.292 started by hand in a driven Conduit window (1100x650): observed at 01:00:13; agent-row.1 read [? claude input] about 3.1 s after Enter (screenshot inspected). Prompt sent at 01:00:20.02, working at 01:00:20.13, [! claude permission] at 01:00:23.20 on the Bash [Do you want to proceed?] dialog (screenshot inspected). Enter approved it, then working and [? claude input] at 01:00:35.45 with the probe file created; leaving the program gave [✓ claude done]. The isolated HOME had no Claude session registry, so no structured channel attached and every state came from the screen.

OpenCode 1.18.35 captured inside the existing conduit-opencode-check image (displayed by a host tmux pane over docker run -it, OpenCode only in the container, isolated HOME /tmp/home, scripts/opencode-mock-provider.py slowed by 4 s, permission.bash ask). Screens: idle home and post-turn footers end in ctrl+p commands; a turn shows esc interrupt in the footer; the bash approval is the Permission required panel with Allow once / Allow always / Reject and enter confirm; a provider HTTP 400 is drawn only as its message in a red block (text indistinguishable, reads as input, pinned as screen-errored-provider.txt); killing the mock mid-turn shows Cannot connect to API with [retrying attempt #n] in the footer, then the error in the transcript once retries end (about two minutes) - that is the errored pattern. Fixtures under src/agent/opencode/fixtures, unit test added; zig build test passes except the two known platform EndpointTooLong tests.
<!-- SECTION:NOTES:END -->

## Comments

<!-- COMMENTS:BEGIN -->
author: @claude
created: 2026-10-09 01:02
---
AC1 left unchecked: the OpenCode manifest has permission and working patterns only (OpenCode is not installed here; strings from herdr, unverified). Claude Code, Codex, Pi and the fake cover all four classes. Coordinator to decide whether to capture OpenCode in its container or accept the gap.
---

author: @claude
created: 2026-10-09 01:02
---
AC2 also left unchecked for the same reason: recorded fixtures cover Claude Code, Codex, Pi and the debounce, but OpenCode is tested only against its documented strings, not a recorded screen.
---
<!-- COMMENTS:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Agents without a working structured channel now get state from their screens. agent/screen.zig defines bounded per-harness ScreenManifests (case-folded literals, row-start anchor, bottom-row regions; permission > working > errored > input), each adapter publishes one captured from a real build (Claude Code 2.1.292, Codex 0.160.1, Pi 0.73.1, OpenCode 1.18.35) with scrubbed fixtures and tests, and agent.Heuristics matches them against term.activeScreenText (active screen only, bounded, no allocation): output stays the working authority, a visible permission prompt wins even during output, screen-named waits survive redraws, and leaving working for idle is debounced (3 confirmations 100 ms apart or 700 ms). Structured events keep precedence and screen text never triggers anything. Verified by unit tests, --agent-test (0 failures) and zig build e2e (22/22) driving the fake through input, permission, errored, a spinner burst and debounced idle, and by a real hand-started Claude Code reading ? claude input and ! claude permission in the sidebar row. Known limit: an OpenCode provider error reads as input.
<!-- SECTION:FINAL_SUMMARY:END -->
