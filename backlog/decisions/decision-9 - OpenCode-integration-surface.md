---
id: decision-9
title: OpenCode integration surface
date: '2026-10-07 20:39'
status: accepted
---
## Context



## Decision



## Consequences

## Context
TASK-78 adds OpenCode as a fourth coding-agent harness beside Claude Code, Codex and Pi.
decision-7 fixes the shape: the TUI runs in a Conduit PTY and each adapter adds the harness's own
structured side channel, with PTY heuristics as the harness-neutral fallback. OpenCode was not
installed on the dev box, so its surface was read from the official docs and the `anomalyco/opencode`
source (release v1.18.35, read 2026-10-07), not probed live.

## Decision
The OpenCode adapter uses the HTTP server that OpenCode's TUI starts when launched with `--port`
(or `opencode serve` for headless agents), bound to `127.0.0.1` and protected with
`OPENCODE_SERVER_PASSWORD` set to the agent's correlation token:

- **Events:** `GET /event` (SSE, envelope `{id, type, properties}`): `session.status`,
  `session.idle`, `session.error`, `permission.asked`/`permission.replied`, `question.asked`/
  `question.replied`/`question.rejected`, `message.updated`, `message.part.updated`, child sessions.
- **Permissions:** `POST /permission/:id/reply` with `{"reply": "once|always|reject"}`; the
  deprecated `POST /session/:sid/permissions/:id` is the fallback on 404.
- **Transcript:** `GET /session/:id/message` replays history on attach; message parts stream live.
- **Input and stop:** `POST /session/:id/prompt_async`, `POST /session/:id/abort`.
- **Prompt files:** instructions are files, so `read_prompt`/`update_prompt` are unsupported.
- Structured capabilities are reported only while the SSE stream is live; when the server is
  unreachable the agent stays on the PTY baseline and the adapter retries with backoff.

## Consequences
- Session files are not read: the server API is the only surface, so a server version change is the
  compatibility risk; fixtures are hand-written from the documented shapes until a live run records
  real ones.
- The registry's "structured beats heuristic" latch needs a way to fall back when the structured
  channel is lost (TASK-56 wiring).
- Over SSH the port must be forwarded through the ExecutionContext (TASK-61).
- Live acceptance (TASK-78 #1–#3) waits for an installed `opencode`; the integration check skips
  with a clear message until then.

## Alternatives considered
- **Plugin forwarding events to a sink file** (like the Claude Code hooks and the Pi extension):
  possible, but the server already exposes everything over one authenticated local port, and the
  plugin would need installing into the user's OpenCode config.
- **Parsing the TUI's terminal output:** rejected by TASK-78 itself (structured events, not text).
