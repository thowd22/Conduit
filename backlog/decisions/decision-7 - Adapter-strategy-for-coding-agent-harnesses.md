---
id: decision-7
title: Adapter strategy for coding-agent harnesses
date: '2026-10-07 17:27'
status: accepted
---
## Context
CONDUIT.md §7 wants agent state, notifications, structured transcripts, answerable permission
prompts and prompt viewing for Claude Code, Codex and Pi (and, by TASK-78, OpenCode), without any
harness specifics outside `agent/` (invariant 9) and without stealing terminal input (invariant 8).
TASK-51 probed what each harness exposes; the evidence, versions (Claude Code 2.1.292, Codex
0.160.1, Pi 0.73.1, omp 18.6.1; OpenCode not installed) and per-cell verdicts are in `doc-3`.

The harnesses differ more by *how they were started* than by name: the same Codex binary is fully
observable through its app-server daemon but only through hooks when run with `--no-daemon`; Claude
Code is fully controllable headless but only through hooks in its TUI; Pi exposes everything to an
extension or RPC client and nothing otherwise. Users will mostly run the interactive TUIs in
Conduit terminals, often by typing the command themselves.

## Decision
**Every agent session keeps its interactive TUI in a Conduit PTY, and each adapter adds the
harness's own structured side channel on top. PTY-level heuristics are the harness-neutral
baseline that every adapter gets for free and falls back to.**

Baseline (owned by `agent/` core, not by an adapter): detection from the PTY's foreground process
group and argv; OSC 0/2 title, BEL and OSC 9/777 notifications; DEC focus reporting so harnesses
can decide when to notify; output activity versus quiet; OSC 133 marks from the surrounding shell;
child exit. It yields working / quiet / needs attention / exited and is labelled as heuristic.

Per harness, primary mechanism then fallback:

| Harness | Primary (proven in doc-3) | Secondary | Fallback |
|---|---|---|---|
| Claude Code | Hooks (`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `PostToolUse`, `Notification`, `Stop`, `SubagentStart/Stop`, `SessionEnd`, `InstructionsLoaded`) reporting to Conduit's control endpoint (TASK-60); `PermissionRequest` replies answer prompts. Conduit-launched sessions inject them with `--settings` and pin `--session-id`. | Transcript JSONL at `transcript_path` for history and structured view; headless `claude -p --input-format/--output-format stream-json --permission-prompt-tool stdio` for agents spawned without a visible TUI. | `~/.claude/sessions/<pid>.json` status (undocumented, best effort), PTY baseline. |
| Codex | App-server JSON-RPC: Conduit-launched agents run the TUI on the shared daemon (default) and Conduit connects to the same daemon socket (WebSocket over Unix socket) for `thread/status/changed`, items and approval server requests; `codex app-server --listen stdio://` for headless agents. | Hooks (same event set as Claude, trust-gated) for `--no-daemon` sessions; rollout JSONL; `notify` program. | TUI OSC 9/BEL, PTY baseline. |
| Pi (omp as a variant) | A Conduit-supplied Pi extension (`-e` at launch; installed only with user consent for manual starts) that forwards `pi.on` events to the control endpoint and, when enabled, gates tools through `ctx.ui.confirm`. Headless agents use `pi --mode rpc`, answering `extension_ui_request`. omp: same, plus its `rpc-ui`/ACP and native approvals once verified. | Session JSONL v3 (documented format). | PTY baseline. |
| OpenCode (unverified, TASK-78) | Its HTTP server: SSE `/event` for `session.status`/`permission.asked`, `POST /session/:id/permissions/:id` to answer, launched with a Conduit-chosen `--port`. | Plugin forwarding events. | PTY baseline. |

Rules:

1. Correlation is by an environment variable Conduit sets on every agent PTY child, which hooks
   and extensions inherit (proven for Codex hooks), plus the harness session id learned from the
   first structured event. Hooks and extensions only ever *report* to the local control endpoint;
   they never receive commands from transcript or terminal text.
2. Answering a permission prompt from Conduit always requires an explicit user gesture in Conduit
   (CONDUIT.md §11); a request may be resolved in the harness TUI first, and adapters must accept
   that.
3. Conduit never edits a harness's user settings silently. Launch-time injection (`--settings`,
   `-e`, `-c`) is the default; persistent installation of hooks or extensions for manually started
   sessions is an explicit, reversible user action. Codex hook trust is never bypassed with
   `--dangerously-bypass-hook-trust` on the user's behalf.
4. Protocol shapes are pinned per harness version: adapters read the installed version, parse
   tolerantly, and degrade to the baseline on unknown versions rather than guessing (Codex can emit
   its schema with `codex app-server generate-json-schema`).
5. Transports go through the workspace `ExecutionContext`: local sockets locally; over SSH a
   second exec channel for stdio protocols, a forwarded Unix socket for the Codex daemon, or a
   remote JSONL sink tailed over an exec channel for hooks/extensions (TASK-61).

## Consequences

- TASK-52's interface makes every capability optional with an explicit `unsupported`, carries a
  status source (structured vs heuristic), models permission requests with an id, the harness's
  decision list and a "resolved elsewhere" outcome, and has a pluggable transport.
- TASK-60's control endpoint becomes a dependency of live status for Claude Code and Pi (hooks and
  the extension report through it), so TASK-53/55 need it or an interim per-session JSONL sink.
- Claude transcript and PID-registry formats are internal; parsers need fixtures per version and
  must never be the only source of a permission state.
- Codex's app-server is labelled experimental and already differs between 0.160.1 and 0.161.0;
  TASK-54 must version-gate it. Manual `--no-daemon` sessions get hooks-level fidelity only.
- Pi gains permission prompts only through Conduit's gate extension; plain `pi` has none, so
  "waiting for permission" is `unsupported` for Pi without it.
- Running the TUI keeps raw-terminal parity (TASK-57's toggle) and lets the user keep using the
  harness exactly as they would elsewhere.

## Alternatives considered

- **Headless-only (stream-json / app-server / RPC) with Conduit rendering everything.** Richest
  control, but loses the harness's own TUI, cannot cover sessions the user starts by hand, and
  makes Conduit re-implement each TUI. Kept for headless agents spawned from the manager.
- **Transcript tailing only.** Works for every harness and over SSH, but formats are internal for
  Claude and Codex, approvals are missing from Codex rollouts, and a file cannot be answered.
  Kept as a secondary source.
- **Screen scraping of TUI text for state.** Fragile across versions and locales, and violates the
  "structured events, not terminal text" requirement in TASK-78. Rejected except for the
  harness-neutral escape sequences above.
- **ACP (Agent Client Protocol) as the single protocol.** omp and OpenCode speak it, Claude Code and
  Codex do not natively; revisit if ACP coverage grows.
