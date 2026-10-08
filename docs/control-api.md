# Conduit control API

A program running inside a Conduit terminal (a coding-agent harness, its hooks or extensions, or
a script) can ask Conduit to open a tab or split pane in its own workspace, show an agent or
backlog view, set its tab's status, raise a notification, deliver structured agent events, and
drive the workspace's VSCodium editor pane (`editor.*`, TASK-79).
The `conduit` command uses the same protocol to reuse a running Conduit: `conduit .`,
`conduit ssh <host>`, `conduit workspace open <name>` and `conduit agent <harness>`. This page is
the wire contract and the harness configuration guide. Code: `src/control.zig` (TASK-60) and the
app handler and command-line client in `src/main.zig` (TASK-60 part two, TASK-66).

Status: implemented and verified on Linux (`--control-test`, the `control-api` E2E scenario and
the socket integration tests in `src/control.zig`). The five `editor.*` methods are part of the
protocol (parsed, validated and queued like every other method), but until TASK-79's second phase
wires the editor pane into the app, Conduit answers each of them `Unavailable`. macOS uses the same POSIX code but has not
been run. Windows has no control transport yet: neither endpoint starts there, and `conduit`
commands always start a new window.

## Enabling

The endpoints run when the `control.enabled` setting resolves on: `--control` or `--no-control`
for one run, else the settings file, else the build's default, which is **on in development
(Debug) builds and off in release builds**. Built-in checks other than `--control-test` never
start them. See [config.md](config.md#keys).

## Discovery

Conduit sets three variables in the environment of every Local human and agent terminal in a
workspace, and of no other child (not the scratchpad, not an SSH workspace's connection terminal,
not a remote child, which could not reach a local socket anyway):

| Variable | Value |
|---|---|
| `CONDUIT_CONTROL_ENDPOINT` | Absolute path of this run's control socket, `<runtime dir>/conduit/r-<8 hex>.sock`. |
| `CONDUIT_CONTROL_TOKEN` | The workspace's control token: 32 lowercase hex digits (128 random bits). |
| `CONDUIT_CONTROL_SESSION` | This terminal's session id, a positive integer. Pass it back as `session` so "my tab" and "my pane" mean this terminal. |

The runtime directory is `$XDG_RUNTIME_DIR` (when absolute), else `/tmp/conduit-<uid>`; on macOS
`$TMPDIR` comes before `/tmp`. Conduit creates `<runtime dir>/conduit` with mode 0700. An
enclosing Conduit's three variables are never inherited, so a nested Conduit's children only see
their own.

Agent children also carry `CONDUIT_AGENT_TOKEN`, the agent's correlation token, which
`agent.event` names. A program that does not see `CONDUIT_CONTROL_ENDPOINT` is not inside a
Conduit workspace terminal (or the endpoint is disabled) and should do nothing.

## Security model

- **Local only.** Each endpoint is a mode-0600 Unix socket inside a mode-0700 directory owned by
  the user; Conduit refuses to listen in a directory with any group or other permission. There
  is no TCP fallback.
- **Off in release builds unless enabled** (see [Enabling](#enabling)).
- **Token-scoped.** Every request carries a token, compared in constant time. A workspace token
  reaches only its own workspace. Tokens are random per run (from the OS entropy source), are
  issued when the workspace's first terminal starts, expire when the workspace closes, and can be
  rotated; a request with a missing, malformed, unknown or expired token gets `Unauthorized`
  before its parameters are even looked at. The instance token (see
  [Single instance](#single-instance)) names no workspace and is accepted only by `ping` and the
  four `instance.*` methods.
- **The scratchpad is never addressable.** Its child gets no control variables, and a request
  whose `session` is the scratchpad's id is refused with `ScratchpadNotAddressable`, by the server
  and again by Conduit itself. No method can show, hide, restart, type into or otherwise take over
  the scratchpad.
- **Enumerated methods only.** The seventeen methods below are the whole API; anything else is
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
| `token` | yes | The workspace token (or the instance token for `instance.*`). |
| `session` | no | The caller's own session id (`CONDUIT_CONTROL_SESSION`). It must belong to the token's workspace and must not be the scratchpad. Without it, Conduit uses the workspace's active tab. |
| `params` | no | An object; omitted means `{}`. Unknown members are refused. |
| `jsonrpc` | no | If present, must be `"2.0"`. |

Success reply: `{"jsonrpc":"2.0","id":1,"result":{...}}`.
Error reply: `{"jsonrpc":"2.0","id":1,"error":{"code":-32002,"message":"ScratchpadNotAddressable"}}`.
The two editor faults add fixed guidance as `error.data.hint` (never request text).
When the request id could not be read, `id` is `null`.

### Timing

Requests are performed on Conduit's UI thread in arrival order. A request that would move focus
while the person is holding a key or the mouse, while the palette or a close confirmation is open,
or while the workspace is still starting another terminal waits for up to 4 seconds and is then
answered `Unavailable`. `tab.open`, `pane.split` and `instance.agent` reply once the new
terminal's process has started (or `InternalError` when it could not start). The server answers
`TimedOut` after 5 seconds; the action may still happen.

## Methods

String limits: UI text (`title`, status `text`, notification `title`) is UTF-8 without control
characters; a notification `body` and an agent `prompt` may also contain `\n` and `\t`. `cwd` and
`path` are 1–4096 bytes without control characters. `command` is 1–256 strings of at most 4096
bytes each, without NUL, and the first may not be empty.

### `ping`

Checks the endpoint and the token. Params: none.

```json
{"id":1,"method":"ping","token":"…"}
{"jsonrpc":"2.0","id":1,"result":{"pong":true}}
```

### `tab.open`

Opens a new tab in the caller's workspace and makes it active, exactly like the "new tab"
command: the child is spawned through the workspace's ExecutionContext. When the caller's
workspace is not the one shown, Conduit switches to it. Params:

| Param | Meaning |
|---|---|
| `cwd` | Working directory in the workspace's context. Default: the caller session's tracked cwd, else the active session's, else the workspace cwd. |
| `command` | argv to run instead of the workspace shell. |
| `title` | Tab label, 1–256 bytes. Default: `Terminal <n>`. |

```json
{"id":2,"method":"tab.open","token":"…","session":4,"params":{"cwd":"/home/me/src/app","command":["npm","test"],"title":"tests"}}
{"jsonrpc":"2.0","id":2,"result":{"tab":3,"session":9}}
```

### `pane.split`

Splits the caller's pane (its `session`, else the active tab's focused pane) and focuses the new
pane. Params: `direction` (`"right"` or `"down"`, required), `cwd`, `command` as for `tab.open`.

```json
{"id":3,"method":"pane.split","token":"…","session":4,"params":{"direction":"right","command":["tail","-f","build.log"]}}
{"jsonrpc":"2.0","id":3,"result":{"tab":3,"pane":7,"session":10}}
```

### `view.agent`

Shows the agent view (TASK-57) of an agent in the caller's workspace and brings its pane forward.
Params: `agent_id` (optional): the agent's number as the agent manager and the
`agent.view.<n>` semantic ids show it; without it, the agent running in the caller's own
session. Result: `{"session":…}`. `NotFound` when the agent is not in this workspace.

### `view.backlog`

Shows the backlog view (TASK-63) for the caller's workspace, on `<cwd>/backlog` of the caller's
tab (its tracked cwd, else the workspace's directory). Params: none. Result: `{}`, or
`Unavailable` when the view could not open.

### `tab.status`

Sets the caller's tab status. Params: `text` (0–64 bytes; shown before the tab's name, `""`
clears it) and `attention` (`true` shows the tab's attention mark `!` like a bell, `false`
clears it). Both optional. The sidebar shows `<mark> <text> <name>`, for example `! busy api`.
The attention mark clears when the person activates the tab. An agent's tab keeps its state glyph
instead. Result: `{}`.

```json
{"id":4,"method":"tab.status","token":"…","session":4,"params":{"text":"testing","attention":false}}
```

### `notify`

Raises a Conduit notification (TASK-56) attributed to the caller's tab: an entry in the
notification list, and an OS notification while the window is unfocused, both subject to the
`notifications.enabled`, `notifications.terminal` and `notifications.os` settings. Params:
`title` (1–256 bytes, required), `body` (0–4096 bytes). Result: `{}`.

### `agent.event`

Delivers one structured harness event (a hook call, an extension event) to Conduit's agent
subsystem. Params: `agent` (required, the `CONDUIT_AGENT_TOKEN` value: 32 lowercase hex digits)
and `payload` (required, a JSON object). The server checks only size and shape; Conduit appends
the payload, re-encoded as one compact line, to the event channel the agent's adapter already
reads, and never interprets it. `NotFound` when no agent of this workspace has that token;
`Unavailable` for a harness whose adapter has no line channel (Codex and OpenCode use their own
servers). Result: `{}`.

The payload is the adapter's existing event-line object, unchanged: for Claude Code,
`{"conduit":{"v":1,"event":"<Hook>","token":"<agent token>"},"payload":<hook input>}`; for Pi,
`{"v":1,"token":"<agent token>","type":…}`. A payload larger than the 64 KiB frame cannot be
sent; `conduit control agent.event --event=…` then falls back to the agent's sink file.

### `instance.open_directory`

Opens or focuses a Local workspace for a directory (`conduit .`, `conduit <dir>`). Params: `path`
(an absolute directory, required). An open workspace in that directory (including the first
workspace when it opened in this directory) is focused; otherwise a workspace named after the
directory's last component opens there with its first tab and scratchpad. Result:
`{"workspace":…}`, the workspace key as in the `workspace.<n>` semantic ids.

### `instance.open_ssh`

Opens an SSH workspace (`conduit ssh <host>`), exactly as **Remote: connect** does: named after
the host, connecting through the workspace's master connection, prompts in its connection view.
Params: `destination` (`[user@]host[:port]` or an `~/.ssh/config` alias, required; validated as
`remote.profile` destinations are). The reply comes as soon as the workspace exists, while it
connects. Result: `{"workspace":…}`.

### `instance.open_workspace`

Focuses the workspace with this name (`conduit workspace open <name>`), or opens a Local workspace
of that name in `path` when none exists. Params: `name` (1–256 bytes, required), `path` (absolute,
optional). `NotFound` without `path` when no workspace has the name. Result: `{"workspace":…}`.

### `instance.agent`

Launches a coding agent (`conduit agent <harness> [prompt...]`), exactly as **Agent: launch**
does, in a new tab of the caller's workspace (a workspace token, with the caller's cwd) or of the
active workspace (the instance token). Params: `harness` (`claude`, `claude_code`, `codex`, `pi`
or `opencode`, required) and `prompt` (0–4096 bytes, optional). `NotFound` for a harness Conduit
cannot launch. Result: `{"workspace":…,"tab":…,"session":…}`.

### `editor.open`

Opens a file in the caller workspace's VSCodium editor pane (decision-12). The first request
splits the caller's pane (its `session`, else the active tab's focused pane) and starts
VSCodium in the new pane; while that pane is open, every `editor.open` and `editor.goto` reuses it
instead of starting another, so a workspace has at most one editor pane. Params:

| Param | Meaning |
|---|---|
| `path` | Required, 1–4096 bytes. Absolute, or relative to the caller session's tracked cwd (else the workspace's directory). Resolved by Conduit through the workspace's ExecutionContext, never by the server. `~` is refused. A missing file in an existing directory opens as a new file. |
| `line`, `column` | Optional, one-based, at most 10,000,000. `column` only with `line`. |
| `split` | `"right"` (default) or `"down"`: where a new editor pane goes. Ignored when the pane is already open. |

```json
{"id":5,"method":"editor.open","token":"…","session":4,"params":{"path":"src/main.zig","line":120,"column":9}}
{"jsonrpc":"2.0","id":5,"result":{"tab":3,"pane":8}}
```

VSCodium is detected (`codium --version`, or the `editor.command` setting) through the
workspace's context and is never installed by Conduit; without it the reply is
`EditorNotInstalled`. Conduit's editor runs with its own per-workspace `--user-data-dir` under
Conduit's state directory, so it never touches your own VSCodium window or settings; your
extensions are still used. In SSH and WSL workspaces the reply is `EditorRemoteUnsupported`: open
the file with `tab.open` and `["vi", "+<line>", "--", "<path>"]` there instead.

### `editor.goto`

Moves the open editor pane to a file position, starting the pane first when none is open.
Params: `path` (required), `line`, `column`, as for `editor.open`; the file must exist. Result as
for `editor.open`.

### `editor.diff`

Shows VSCodium's diff of two existing files in the editor pane (`codium --diff`). Params: `left`
and `right` (required paths, resolved as above). Result as for `editor.open`.

### `editor.reveal`

Opens a file or folder in the editor pane and lets the explorer select it (`codium -r <path>`).
Params: `path` (required, must exist). Result as for `editor.open`.

### `editor.close`

Closes the workspace's editor pane and asks its window to close, returning the space to the
sibling pane. Params: none. Result: `{}` (also when no editor is open).

None of the editor methods can reach the scratchpad, run a command, or read editor text back:
paths are the only input, and they are handed to VSCodium as single absolute arguments.

## Errors

| Code | Message | Meaning |
|---|---|---|
| -32700 | `ParseError` | The line is not valid UTF-8 JSON. |
| -32600 | `InvalidRequest` | Not an object, missing `id` or `method`, unknown member, too deep, or over 64 KiB. |
| -32601 | `MethodNotFound` | Not one of the seventeen methods. |
| -32602 | `InvalidParams` | A parameter is missing, has the wrong type, or is out of bounds. |
| -32603 | `InternalError` | Conduit failed unexpectedly, or the new terminal's process did not start. |
| -32000 | `Unavailable` | Valid, but Conduit cannot do it now (busy for 4 s, view not available, shutting down). |
| -32001 | `Unauthorized` | Missing, malformed, unknown or expired token, or a workspace method with the instance token. |
| -32002 | `ScratchpadNotAddressable` | The request named the scratchpad session. |
| -32003 | `Busy` | Too many requests or connections in flight; retry later. |
| -32004 | `NotFound` | The session, agent, harness, workspace or editor file is not there. |
| -32005 | `EditorNotInstalled` | No VSCodium answered in this workspace. `error.data.hint` says how to install it or set `editor.command`. |
| -32006 | `EditorRemoteUnsupported` | The workspace is remote (SSH, WSL), where the editor pane does not run. `error.data.hint` names the `vi` fallback. |
| -32008 | `TimedOut` | Conduit did not answer within its deadline (5 s). The action may still happen. |

## The `conduit` command

```
conduit control <method> [<params-json>]   one request to this terminal's endpoint
conduit .  |  conduit <dir>                 instance.open_directory
conduit ssh <host>                          instance.open_ssh
conduit workspace open <name>               instance.open_workspace (path: the current directory)
conduit agent <harness> [prompt...]         instance.agent (the prompt words joined by spaces)
```

`conduit control` sends one request with `$CONDUIT_CONTROL_ENDPOINT`, `$CONDUIT_CONTROL_TOKEN`
and `$CONDUIT_CONTROL_SESSION`, prints the reply line, and exits 0 for a result, 1 for an error
reply or when nothing answers, and 2 for a malformed command line or params. `params` must be a
JSON object; it is re-encoded compactly before it is sent. For `agent.event`, stdin is the
payload object, the agent is `--agent=<token>` or `$CONDUIT_AGENT_TOKEN`, and `--event=<Hook>`
wraps stdin as a Claude Code hook line. With `--event` the command is a hook: it prints nothing,
always exits 0, and when the endpoint does not take the event (not running, too large, refused)
appends the line to `$CONDUIT_AGENT_SINK/events.jsonl` instead.

The other four commands print nothing and exit 0 when the running Conduit carried them out, or
print `conduit: <Message>` and exit 1 when it refused. A directory is resolved against the current
directory and must exist.

## Single instance

A running Conduit answers `conduit` commands on its instance endpoint,
`<runtime dir>/conduit/instance.sock`, with a token it writes (mode 0600, directory 0700) to
`<state dir>/instance.token` at startup and removes when it leaves: `$XDG_STATE_HOME/conduit`, else
`~/.local/state/conduit` (`~/Library/Application Support/conduit` on macOS). A command then:

1. inside a Conduit terminal (its control variables set), sends the method to that terminal's own
   Conduit with the workspace token and session, so `conduit agent` launches in the caller's
   workspace;
2. otherwise reads the token file and sends the method to the instance endpoint, so
   `conduit agent` launches in the active workspace;
3. when nothing answers (no endpoint, no token file, a stale socket, a refused connection),
   becomes Conduit itself: it starts a window and carries the command out once it can.

Plain `conduit` always starts a new window. When a second Conduit starts while one already
answers, the first keeps the instance endpoint. `conduit-test launch` and `--control-test` set a
private `XDG_RUNTIME_DIR` and `XDG_STATE_HOME`, so a test run never answers, or reaches, the
person's own Conduit.

## Harness configuration

`conduit` must be on `PATH` (an installed package puts it there), or use its absolute path.
Every example does nothing when it is not running inside Conduit, because `conduit control` then
exits without sending anything.

### Shell

```sh
conduit control tab.open '{"title":"logs","command":["tail","-f","/var/log/syslog"]}'
conduit control pane.split '{"direction":"down"}'
conduit control tab.status '{"text":"building","attention":false}'
conduit control notify '{"title":"Build","body":"finished"}'
```

### The editor tool

Any harness that can run a shell command can use the editor pane as its editor: a model running
inside a Conduit terminal calls `conduit control editor.open` instead of `$EDITOR`. The reply is
one JSON line; `EditorNotInstalled` and `EditorRemoteUnsupported` carry a hint the model can
relay.

```sh
conduit control editor.open '{"path":"src/main.zig","line":120,"column":9}'
conduit control editor.goto '{"path":"src/render.zig","line":42}'
conduit control editor.diff '{"left":"src/main.zig.orig","right":"src/main.zig"}'
conduit control editor.reveal '{"path":"docs"}'
conduit control editor.close
```

**Claude Code.** Claude Code runs shell commands through its Bash tool, so the editor is one
instruction away. Add to the project's `CLAUDE.md` (or `~/.claude/CLAUDE.md`):

```markdown
When you want the human to look at a file, run
`conduit control editor.open '{"path":"<file>","line":<n>}'` (it opens VSCodium in a pane
beside this terminal; later calls reuse that pane). Use `editor.diff` with `left`/`right` to
show a change and `editor.close` when done. If `CONDUIT_CONTROL_ENDPOINT` is unset, skip it.
```

To have the editor follow every file Claude Code edits, add a `PostToolUse` hook to
`.claude/settings.json`; it reads the tool input on stdin and never changes Claude Code's
behaviour:

```json
{
  "hooks": {
    "PostToolUse": [{"matcher": "Edit|Write|MultiEdit", "hooks": [{"type": "command",
      "command": "[ -n \"$CONDUIT_CONTROL_ENDPOINT\" ] && jq -c '{path: .tool_input.file_path}' | xargs -0 conduit control editor.goto >/dev/null 2>&1; true"}]}]
  }
}
```

**Codex.** Codex also runs shell commands; add the same instruction to the project's `AGENTS.md`.
Codex's sandbox must allow the command to reach the control socket (the default
`workspace-write` sandbox blocks sockets outside the workspace; approve the command or run with
network-capable settings).

**Pi.** Pi's bash tool runs the commands as they are. A Pi extension can also register a
dedicated tool:

```js
import { execFileSync } from "node:child_process";
export default function (pi) {
  pi.registerTool({
    name: "open_in_editor",
    description: "Open a file at a line in the VSCodium pane beside this terminal",
    parameters: { type: "object", properties: { path: { type: "string" }, line: { type: "integer" } }, required: ["path"] },
    async execute(_id, params) {
      const out = execFileSync("conduit", ["control", "editor.open", JSON.stringify(params)], { encoding: "utf8" });
      return { content: [{ type: "text", text: out }] };
    },
  });
}
```

**OpenCode.** A custom tool in `.opencode/tool/editor.ts`:

```ts
import { tool } from "@opencode-ai/plugin";
import { execFileSync } from "node:child_process";
export default tool({
  description: "Open a file at a line in the VSCodium pane beside this terminal",
  args: { path: tool.schema.string(), line: tool.schema.number().int().positive().optional() },
  async execute(args) {
    return execFileSync("conduit", ["control", "editor.open", JSON.stringify(args)], { encoding: "utf8" });
  },
});
```

The instruction, hook, extension and tool snippets follow each harness's documented interfaces
and have not been run against a live harness or a real VSCodium yet (TASK-79's deterministic
check uses a stand-in `codium`).

### Claude Code hooks

An agent Conduit launches itself gets its hooks through `--settings` (TASK-53): while the control
endpoint runs, every hook except `PermissionRequest` runs
`'<conduit>' control agent.event --event=<Hook>`, which sends the hook input over the endpoint
(falling back to the agent's sink); `PermissionRequest` keeps its file-based relay, whose answer
comes back through `decisions/`. Nothing needs configuring.

A Claude Code started by hand in a Conduit terminal has no agent token, but its hooks can still
mark the tab and notify. In `~/.claude/settings.json` (or the project's `.claude/settings.json`):

```json
{
  "hooks": {
    "Notification": [{"hooks": [{"type": "command", "command": "conduit control tab.status '{\"text\":\"waiting\",\"attention\":true}' >/dev/null 2>&1; true"}]}],
    "Stop":         [{"hooks": [{"type": "command", "command": "conduit control tab.status '{\"text\":\"\",\"attention\":true}' >/dev/null 2>&1; true"}]}]
  }
}
```

The output is discarded so Claude Code's own behaviour is unchanged.

### Pi extension

Conduit's Pi extension (`src/agent/pi/conduit.js`) appends each event line to
`$CONDUIT_AGENT_SINK/events.jsonl`. An extension can send the same line object through the
endpoint instead, falling back to the sink:

```js
import { execFileSync } from "node:child_process";
function send(line) {
  if (!process.env.CONDUIT_CONTROL_ENDPOINT) return appendToSink(line); // the existing sink path
  try {
    execFileSync("conduit", ["control", "agent.event"], { input: JSON.stringify(line), stdio: ["pipe", "ignore", "ignore"] });
  } catch {
    appendToSink(line);
  }
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
# conduit-codex-notify.sh '<json>': turn a finished Codex turn into a notification.
[ -n "$CONDUIT_CONTROL_ENDPOINT" ] || exit 0
params=$(printf '%s' "$1" | jq -c '{title:"Codex", body:((.["last-assistant-message"] // "Turn complete") | tostring | .[0:4096])}')
conduit control notify "$params" >/dev/null 2>&1
exit 0
```

An agent Conduit launches itself uses the Codex app-server channel (TASK-54) instead.

### OpenCode plugin

An OpenCode plugin (for example `.opencode/plugin/conduit.js`) can mark the tab when a session
goes idle:

```js
import { execFile } from "node:child_process";
export const Conduit = async () => ({
  event: async ({ event }) => {
    if (!process.env.CONDUIT_CONTROL_ENDPOINT || event.type !== "session.idle") return;
    execFile("conduit", ["control", "tab.status", JSON.stringify({ text: "idle", attention: true })], () => {});
  },
});
```

An agent Conduit launches itself uses OpenCode's own server channel (TASK-78) instead.

The Codex, OpenCode and Pi snippets follow those harnesses' documented `notify`, plugin and
extension interfaces and have not been run against a live harness; the protocol and the
`conduit control` client are covered by `src/control.zig`'s socket tests and `--control-test`.

## MCP and `conduit-test`

`conduit-test` has no control forwarding: the workspace tokens exist only inside the app and its
terminals, so an agent driving an isolated run types `conduit control …` into a terminal through
the driver (`type`, `key`), as the `control-api` E2E scenario does. The one exception is the
editor: `conduit-test editor-open <path> [line] [column] [--split right|down]` and
`conduit-test editor-goto <path> [line] [column]` (MCP tools `editor_open` and `editor_goto`)
drive the active workspace's editor pane the way `editor.open` and `editor.goto` do, resolving a
relative path against the focused terminal's directory. Until TASK-79's second phase they answer
`Unsupported`. `conduit-test launch` puts
the run's control and instance sockets in its private run directory.
