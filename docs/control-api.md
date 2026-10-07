# Conduit control API

A program running inside a Conduit terminal (a coding-agent harness, its hooks or extensions, or
a script) can ask Conduit to open a tab or split pane in its own workspace, show an agent or
backlog view, set its tab's status, raise a notification, and deliver structured agent events.
This page is the wire contract and the harness configuration guide. Code: `src/control.zig`
(TASK-60).

Status: part one (protocol, server, unit and socket integration tests) is implemented. The app
wiring, the `control.enabled` setting, the `conduit` CLI subcommands and the MCP tools are part
two; until then no Conduit build starts the endpoint, and the examples below use the raw socket
protocol. Linux and macOS only: Windows has no control transport yet.

## Discovery

Conduit sets three variables in the environment of every terminal child in a workspace, except
the scratchpad's:

| Variable | Value |
|---|---|
| `CONDUIT_CONTROL_ENDPOINT` | Absolute path of the control socket, inside the run's private directory (`…/control.sock`). |
| `CONDUIT_CONTROL_TOKEN` | The workspace's control token: 32 lowercase hex digits (128 random bits). |
| `CONDUIT_CONTROL_SESSION` | This terminal's session id, a positive integer. Pass it back as `session` so "my tab" and "my pane" mean this terminal. |

Agent children also carry `CONDUIT_AGENT_TOKEN`, the agent's correlation token, which
`agent.event` names. A program that does not see `CONDUIT_CONTROL_ENDPOINT` is not inside a
Conduit workspace terminal (or the endpoint is disabled) and should do nothing.

## Security model

- **Local only.** The endpoint is a mode-0600 Unix socket inside a mode-0700 directory owned by
  the user; Conduit refuses to listen in a directory with any group or other permission. There
  is no TCP fallback.
- **Off in release builds unless enabled.** The endpoint starts in development (Debug) builds,
  and in release builds only when the `control.enabled` setting is on (part two adds it).
- **Token-scoped.** Every request carries a workspace token, compared in constant time. A token
  reaches only its own workspace. Tokens are random per run, expire when the workspace closes,
  and can be rotated; a request with a missing, malformed, unknown or expired token gets
  `Unauthorized` before its parameters are even looked at.
- **The scratchpad is never addressable.** Its child gets no control variables, and a request
  whose `session` is the scratchpad's id is refused with `ScratchpadNotAddressable`. No method
  can show, hide, restart, type into or otherwise take over the scratchpad.
- **Enumerated methods only.** The eight methods below are the whole API; anything else is
  `MethodNotFound`. Nothing in a request is executed by a shell: `command` is an argv. A `cwd` is
  handed to the workspace's ExecutionContext (local, SSH or WSL) and never resolved by the
  server. Request text is never logged above debug level, and replies never echo it.
- **Bounded.** Frames are at most 64 KiB; every string has a limit (below); at most 32 requests
  are in flight across all clients and 32 clients may be connected at once (`Busy` beyond).

These methods act without a human gesture by design: a harness opening its own tab or pane, or
reporting its own status, is the purpose of the API. Nothing here can answer a permission prompt,
type into a terminal, or run a command outside a new tab or pane the request itself creates.

## Framing

One request per line: a JSON object with no raw newline, terminated by `\n`. The server answers
each request with exactly one line, in order. A connection may carry any number of requests, one
at a time. A line over 64 KiB is answered with `InvalidRequest` and the connection is closed.

Request:

```json
{"id": 1, "method": "tab.open", "token": "<CONDUIT_CONTROL_TOKEN>", "session": 4, "params": {"command": ["htop"]}}
```

| Member | Required | Meaning |
|---|---|---|
| `id` | yes | An integer, or a string of at most 128 bytes. Echoed in the reply. |
| `method` | yes | One of the method names below, exactly. |
| `token` | yes | The workspace token. |
| `session` | no | The caller's own session id (`CONDUIT_CONTROL_SESSION`). It must belong to the token's workspace and must not be the scratchpad. Without it, Conduit uses the workspace's active tab. |
| `params` | no | An object; omitted means `{}`. Unknown members are refused. |
| `jsonrpc` | no | If present, must be `"2.0"`. |

Success reply: `{"jsonrpc":"2.0","id":1,"result":{...}}`.
Error reply: `{"jsonrpc":"2.0","id":1,"error":{"code":-32002,"message":"ScratchpadNotAddressable"}}`.
When the request id could not be read, `id` is `null`.

## Methods

String limits: UI text (`title`, status `text`, notification `title`) is UTF-8 without control
characters; a notification `body` may also contain `\n` and `\t`. `cwd` is 1–4096 bytes without
control characters. `command` is 1–256 strings of at most 4096 bytes each, without NUL, and the
first may not be empty.

### `ping`

Checks the endpoint and the token. Params: none.

```json
{"id":1,"method":"ping","token":"…"}
{"jsonrpc":"2.0","id":1,"result":{"pong":true}}
```

### `tab.open`

Opens a new tab in the caller's workspace and makes it active, exactly like the "new tab"
command: the child is spawned through the workspace's ExecutionContext. Params:

| Param | Meaning |
|---|---|
| `cwd` | Working directory in the workspace's context. Default: the caller session's tracked cwd, else the workspace cwd. |
| `command` | argv to run instead of the workspace shell. |
| `title` | Tab label, 1–256 bytes. Default: Conduit's usual label. |

```json
{"id":2,"method":"tab.open","token":"…","session":4,"params":{"cwd":"/home/me/src/app","command":["npm","test"],"title":"tests"}}
{"jsonrpc":"2.0","id":2,"result":{"tab":3,"session":9}}
```

### `pane.split`

Splits the caller's pane (its `session`, else the active tab's focused pane). Params:
`direction` (`"right"` or `"down"`, required), `cwd`, `command` as for `tab.open`.

```json
{"id":3,"method":"pane.split","token":"…","session":4,"params":{"direction":"right","command":["tail","-f","build.log"]}}
{"jsonrpc":"2.0","id":3,"result":{"pane":7,"session":10}}
```

### `view.agent`

Shows the agent view (TASK-57) in the caller's workspace. Params: `agent_id` (optional,
1–256 bytes of `A–Z a–z 0–9 . _ : -`), naming an agent of this workspace; without it, the agent
attached to the caller's session. Result: `{}` or the ids of what was opened. `NotFound` when
the agent is not in this workspace; `Unavailable` while the view does not exist yet.

### `view.backlog`

Shows the backlog view (TASK-63) for the caller's workspace. Params: none. Result as for
`view.agent`, including `Unavailable` while the view does not exist yet.

### `tab.status`

Sets the caller's tab status. Params: `text` (0–64 bytes; replaces the label prefix, `""`
clears it) and `attention` (`true` raises the tab's attention mark like a BEL, `false` clears
it). Both optional. Result: `{}`.

```json
{"id":4,"method":"tab.status","token":"…","session":4,"params":{"text":"testing","attention":false}}
```

### `notify`

Raises a Conduit notification (TASK-56) attributed to the caller's tab. Params: `title` (1–256 bytes,
required), `body` (0–4096 bytes). Result: `{}`.

### `agent.event`

Delivers one structured harness event (a hook call, an extension event) to Conduit's agent
subsystem. Params: `agent` (required, the `CONDUIT_AGENT_TOKEN` value: 32 lowercase hex digits)
and `payload` (required, a JSON object). The server checks only size and shape and forwards the
payload, re-encoded as compact JSON, to the adapter that owns that agent token; it never
interprets it. `NotFound` when no agent of this workspace has that token. Result: `{}`.

The payload is the adapter's existing event-line object, unchanged: for Claude Code,
`{"conduit":{"v":1,"event":"<Hook>","token":"<agent token>"},"payload":<hook input>}`; for Pi,
`{"v":1,"token":"<agent token>","type":…}`. A payload larger than the 64 KiB frame cannot be
sent; trim large fields (for example a `Write` tool's file contents) before sending.

## Errors

| Code | Message | Meaning |
|---|---|---|
| -32700 | `ParseError` | The line is not valid UTF-8 JSON. |
| -32600 | `InvalidRequest` | Not an object, missing `id` or `method`, unknown member, too deep, or over 64 KiB. |
| -32601 | `MethodNotFound` | Not one of the eight methods. |
| -32602 | `InvalidParams` | A parameter is missing, has the wrong type, or is out of bounds. |
| -32603 | `InternalError` | Conduit failed unexpectedly. |
| -32000 | `Unavailable` | Valid, but Conduit cannot do it now (feature not present, shutting down). |
| -32001 | `Unauthorized` | Missing, malformed, unknown or expired token. |
| -32002 | `ScratchpadNotAddressable` | The request named the scratchpad session. |
| -32003 | `Busy` | Too many requests or connections in flight; retry later. |
| -32004 | `NotFound` | The session or agent is not in the token's workspace. |
| -32008 | `TimedOut` | Conduit did not answer within its deadline (5 s). The action may still happen. |

## Harness configuration

Until part two ships the `conduit` CLI (which will replace these helpers with commands such as
`conduit tab open` and `conduit agent-event`), clients speak the socket directly. `socat` and
OpenBSD `nc -U` both work; `jq` builds JSON safely. Every example exits quietly when it is not
running inside Conduit.

### Shell

```sh
# conduit-control METHOD PARAMS_JSON   e.g. conduit-control tab.open '{"command":["htop"]}'
conduit_control() {
  [ -n "$CONDUIT_CONTROL_ENDPOINT" ] || return 0
  params=$2
  [ -n "$params" ] || params='{}'
  jq -cn --arg m "$1" --argjson p "$params" --arg t "$CONDUIT_CONTROL_TOKEN" \
    --arg s "${CONDUIT_CONTROL_SESSION:-}" \
    '{id:1, method:$m, token:$t, params:$p} + (if $s == "" then {} else {session:($s|tonumber)} end)' |
    socat -t5 - "UNIX-CONNECT:$CONDUIT_CONTROL_ENDPOINT"
  # or: nc -U -N "$CONDUIT_CONTROL_ENDPOINT"
}
```

### Claude Code hooks

Save as an executable `conduit-hook.sh` somewhere on your machine:

```sh
#!/bin/sh
# conduit-hook.sh <HookEvent>: forward one Claude Code hook input to Conduit.
[ -n "$CONDUIT_CONTROL_ENDPOINT" ] && [ -n "$CONDUIT_AGENT_TOKEN" ] || exit 0
jq -c --arg e "$1" --arg a "$CONDUIT_AGENT_TOKEN" --arg t "$CONDUIT_CONTROL_TOKEN" \
  '{id:1, method:"agent.event", token:$t,
    params:{agent:$a, payload:{conduit:{v:1, event:$e, token:$a}, payload:.}}}' |
  socat -t5 - "UNIX-CONNECT:$CONDUIT_CONTROL_ENDPOINT" >/dev/null 2>&1
exit 0
```

and register it in `~/.claude/settings.json` (or the project's `.claude/settings.json`):

```json
{
  "hooks": {
    "SessionStart":     [{"hooks": [{"type": "command", "command": "/path/to/conduit-hook.sh SessionStart"}]}],
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "/path/to/conduit-hook.sh UserPromptSubmit"}]}],
    "PreToolUse":       [{"hooks": [{"type": "command", "command": "/path/to/conduit-hook.sh PreToolUse"}]}],
    "PostToolUse":      [{"hooks": [{"type": "command", "command": "/path/to/conduit-hook.sh PostToolUse"}]}],
    "Notification":     [{"hooks": [{"type": "command", "command": "/path/to/conduit-hook.sh Notification"}]}],
    "Stop":             [{"hooks": [{"type": "command", "command": "/path/to/conduit-hook.sh Stop"}]}]
  }
}
```

The hook prints nothing, so Claude Code's own behaviour is unchanged. An agent Conduit launches
itself already gets equivalent hooks through `--settings` (TASK-53); today they append to the
per-agent `events.jsonl` sink, and part two moves that relay onto `agent.event` with the same
event-line format. Permission replies keep their file channel until then.

### Pi extension

Conduit's Pi extension (`src/agent/pi/conduit.js`) currently appends each event line to
`$CONDUIT_AGENT_SINK/events.jsonl`. The migration replaces that append with one `agent.event`
request carrying the same line object as `payload`, sent when `CONDUIT_CONTROL_ENDPOINT` is set
and falling back to the sink otherwise:

```js
import { connect } from "node:net";
function send(line) {
  const endpoint = process.env.CONDUIT_CONTROL_ENDPOINT;
  if (!endpoint) return appendToSink(line); // the existing CONDUIT_AGENT_SINK path
  const frame = JSON.stringify({ id: 1, method: "agent.event", token: process.env.CONDUIT_CONTROL_TOKEN,
    params: { agent: process.env.CONDUIT_AGENT_TOKEN, payload: line } }) + "\n";
  const socket = connect(endpoint, () => socket.end(frame));
  socket.on("data", () => socket.destroy());
  socket.on("error", () => appendToSink(line));
}
```

### Codex `notify`

Codex runs the `notify` program from `~/.codex/config.toml` after each turn with one JSON
argument. Point it at a helper:

```toml
notify = ["/path/to/conduit-codex-notify.sh"]
```

```sh
#!/bin/sh
# conduit-codex-notify.sh '<json>': turn a finished Codex turn into a tab mark and a notification.
[ -n "$CONDUIT_CONTROL_ENDPOINT" ] || exit 0
printf '%s' "$1" | jq -c --arg t "$CONDUIT_CONTROL_TOKEN" --arg s "${CONDUIT_CONTROL_SESSION:-}" '
  {id:1, method:"notify", token:$t,
   params:{title:"Codex", body:((.["last-assistant-message"] // "Turn complete") | tostring | .[0:4096])}}
  + (if $s == "" then {} else {session:($s|tonumber)} end)' |
  socat -t5 - "UNIX-CONNECT:$CONDUIT_CONTROL_ENDPOINT" >/dev/null 2>&1
exit 0
```

An agent Conduit launches itself uses the Codex app-server channel (TASK-54) instead.

### OpenCode plugin

An OpenCode plugin (for example `.opencode/plugin/conduit.js`) can mark the tab when a session
goes idle:

```js
import { connect } from "node:net";
export const Conduit = async () => ({
  event: async ({ event }) => {
    const endpoint = process.env.CONDUIT_CONTROL_ENDPOINT;
    if (!endpoint || event.type !== "session.idle") return;
    const session = Number(process.env.CONDUIT_CONTROL_SESSION) || undefined;
    const frame = JSON.stringify({ id: 1, method: "tab.status", token: process.env.CONDUIT_CONTROL_TOKEN,
      session, params: { text: "idle", attention: true } }) + "\n";
    const socket = connect(endpoint, () => socket.end(frame));
    socket.on("data", () => socket.destroy());
    socket.on("error", () => {});
  },
});
```

An agent Conduit launches itself uses OpenCode's own server channel (TASK-78) instead.

The Codex and OpenCode snippets follow those harnesses' documented `notify` and plugin
interfaces and have not been run against a live harness; the protocol itself is covered by
`src/control.zig`'s socket tests.
