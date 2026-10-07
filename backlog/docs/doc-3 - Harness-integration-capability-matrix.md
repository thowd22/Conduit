---
id: doc-3
title: Harness integration capability matrix
type: specification
created_date: '2026-10-07 17:25'
updated_date: '2026-10-07 17:27'
---
# TASK-51 spike: harness integration capability matrix

Probed on 2026-10-07 on the Ubuntu dev box. Legend: **[P]** proven by a live probe recorded
below; **[H]** read from the installed CLI's `--help`, its generated schema or its bundled docs;
**[D]** read from official online docs only; **[U]** unverified inference. No transcript, prompt
or credential content was copied anywhere; probes logged only event names, field names and
statuses.

## Versions probed

| Harness | Binary | Version | Live model calls possible here |
|---|---|---|---|
| Claude Code | `~/.local/bin/claude` | 2.1.292 | Yes (two tiny Haiku prompts used) |
| Codex CLI | `codex` (npm, musl binary) | codex-cli 0.160.1 (user's real daemon is 0.161.0) | Real account at usage limit until 2026-10-12; probes used an isolated `CODEX_HOME` and a local mock Responses endpoint, so no OpenAI call was made |
| Pi | `pi` (`@mariozechner/pi-coding-agent`) | 0.73.1 | No credentials; probes used an isolated `PI_CODING_AGENT_DIR` and a local mock Chat Completions endpoint |
| omp (oh-my-pi, Pi fork the user runs) | `~/.local/bin/omp` | 18.6.1 | Bedrock denied; help and on-disk layout only |
| OpenCode | not installed | n/a | Docs only (TASK-78) |

The mock endpoint (`scratchpad/mock/mock.py`, not checked in) served OpenAI Responses SSE and
Chat Completions SSE and returned either a text reply or, when the prompt said `RUNTOOL`, a shell
tool call for `touch probe_file`. That exercises the real harness event, hook, approval and
session-file machinery end to end without a vendor model.

## Capability matrix

### Status detection (idle / working / waiting for input / waiting for permission / done / errored)

| Claude Code | Codex | Pi | OpenCode |
|---|---|---|---|
| **Real.** Hooks [P]: `UserPromptSubmit` → working, `PreToolUse`/`PostToolUse` → working+tool, `PermissionRequest` → waiting for permission, `Stop` → turn done/idle, `StopFailure` [D] → errored, `SessionEnd` → done, `Notification` with `notification_type` `permission_prompt`/`idle_prompt`/`agent_needs_input` [D] → waiting. Headless: stream-json `result` message with `subtype`/`is_error` [P]. Also an undocumented per-PID registry `~/.claude/sessions/<pid>.json` with `status` `busy`/`waiting`/`idle`, `sessionId`, `cwd`, `kind`, removed on exit [P] — useful for detection, not a contract. | **Real.** App-server `thread/status/changed` [P]: `{type: idle}`, `{type: active, activeFlags: []}`, `activeFlags: ["waitingOnApproval"]` / `["waitingOnUserInput"]`, `systemError`, `notLoaded`; `turn/started`/`turn/completed` with `turn.status`. Hooks [P] (`UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `PostToolUse`, `Stop`, `SessionStart`/`SessionEnd`; `Interrupt` [H]). `codex exec --json` [P]: `thread.started`, `turn.started`, `item.*`, `turn.completed` (`turn.failed`, `error` [D]). | **Real via extension or RPC.** RPC/JSON events [P]: `agent_start`, `turn_start`, `tool_execution_start/update/end`, `turn_end`, `agent_end`; `get_state.isStreaming` [P]. In the interactive TUI the same events reach an extension (`pi.on(...)`) [P]. Pi has no built-in permission prompt, so "waiting for permission" exists only when an extension gates a tool (proven below). Errors: `auto_retry_*`, `extension_error`, assistant `stopReason` [H]. | **Real via server [D/U].** SSE `/event`: `session.status`, `session.idle`, `session.error`, `permission.asked`/`permission.replied`, `message.part.updated`. |

### Notification events

| Claude Code | Codex | Pi | OpenCode |
|---|---|---|---|
| Hooks: `Notification` (types above) [D], `Stop`, `PermissionRequest` [P]. Hook output may carry `terminalSequence` (OSC 0/1/2/9/99/777 or BEL) that Claude writes to its own PTY [D] — a PTY-only notification path. PTY probe [P]: Claude sets the title with OSC 0 (status glyph prefix), enables focus reporting (DECSET 1004), bracketed paste and synchronized output (2031); no OSC 9/777 was emitted while focused. OS-notification channel setting `preferredNotifChannel` [U]. | `notify = [argv]` program run per `agent-turn-complete` with one JSON arg (`type`, `thread-id`, `turn-id`, `cwd`, `client`, `input-messages`, `last-assistant-message`) [P]. TUI emits OSC 9 or BEL for `agent-turn-complete`/`approval-requested` per `tui.notifications`, `tui.notification_method` (`auto`/`osc9`/`bel`), `tui.notification_condition` (`unfocused`/`always`) [D]. App-server notifications above [P]. | Extension `ctx.ui.notify`, `setStatus`, `setTitle` [H]; in RPC these arrive as fire-and-forget `extension_ui_request` (`notify`, `setStatus`, `setTitle`) [H]. No built-in OSC notifications found [U]. | Plugin events (`session.idle`, `permission.asked`, `tui.toast.show`) [D]; SSE stream [D]. |

### Transcript access

| Claude Code | Codex | Pi | OpenCode |
|---|---|---|---|
| `~/.claude/projects/<cwd with / and . → ->/<sessionId>.jsonl` [P], append-only JSONL. Record `type`s seen: `user`, `assistant`, `system` (subtypes incl. `turn_duration`, `compact_boundary`, `away_summary`, `local_command`), `attachment`, `permission-mode`, `mode`, `last-prompt`, `ai-title`, `queue-operation`, `file-history-snapshot/delta`, `bridge-session`. Entries carry `uuid`/`parentUuid`, `sessionId`, `cwd`, `gitBranch`, `isSidechain`, `version`. Subagents: `<sessionId>/subagents/agent-<id>.jsonl` plus `.meta.json` (`agentType`, `description`, `toolUseId`, `spawnDepth`) [P]. Every hook input includes `transcript_path` and `session_id` [P]. Format is internal and drifts between releases (many fields appeared since 2.1.x); treat as best-effort. | `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl` [P]; first line `session_meta` (`id`, `cwd`, `cli_version`, `source`, `base_instructions`, `git`, …); then `event_msg` (`task_started`, `task_complete`, `item_completed`, `token_count`, `turn_aborted`, …), `response_item` (`message`, `reasoning`, `function_call(_output)`, `custom_tool_call(_output)`, `agent_message`), `turn_context`, `compacted`. `session_index.jsonl` (`id`, `thread_name`, `updated_at`). Approvals are **not** persisted in rollouts [P]. Hook inputs include `transcript_path` [P]. Preferred structured access is app-server `thread/read`, `thread/turns/list`, `thread/items/list` [H]. | `~/.pi/agent/sessions/--<cwd with / → ->--/<ts>_<uuid>.jsonl` (`PI_CODING_AGENT_DIR`, `--session-dir` override) [P]. Versioned tree format v3: header `{type: session, version, id, cwd, timestamp}` then `message` (`role` user/assistant/toolResult/bashExecution/custom), `model_change`, `thinking_level_change`, `compaction`, `branch_summary`, `custom`, `custom_message`, `label`, `session_info`; `id`/`parentId` tree [P/H]. Documented format, stable contract. RPC `get_state.sessionFile`, `get_messages` [P/H]. omp: `~/.omp/agent/sessions/...`, same shape plus `title`, `title_change` [P]. | Server `GET /session/:id/message`, `opencode export` [D]; on-disk JSON storage under the data dir [U]. |

### Permission prompt handling

| Claude Code | Codex | Pi | OpenCode |
|---|---|---|---|
| **Observe and answer, interactive TUI:** `PermissionRequest` hook receives `tool_name`, `tool_input`, `permission_suggestions` and may return `hookSpecificOutput.decision.behavior` `allow`/`deny` (+`updatedInput`, `updatedPermissions`, `message`, `interrupt`) [P/D]. Probe: the hook blocked until an external decision file appeared (standing in for Conduit's UI), returned `allow`, and the command ran; the TUI showed its own dialog in parallel and dismissed it when the hook decided [P]. Hook type `http` (POST to a URL) exists [D], so Conduit's control endpoint can be the hook. **Headless:** `--permission-prompt-tool stdio` with stream-json emits `control_request` `can_use_tool` (`tool_name`, `input`, `tool_use_id`, `permission_suggestions`, `blocked_path`, `description`); answering `control_response` `{behavior: allow, updatedInput}` ran the tool [P]. `--permission-mode` choices `acceptEdits`/`auto`/`bypassPermissions`/`manual`/`dontAsk`/`plan`; `--permission-prompts host|none` [H]. | **Observe and answer:** app-server server request `item/commandExecution/requestApproval` (also `item/fileChange/requestApproval`, `item/permissions/requestApproval`, `item/tool/requestUserInput`, `mcpServer/elicitation/request`) with `availableDecisions`; answering `{decision: "accept"}` ran the command, then `serverRequest/resolved` [P]. **A manually started TUI is answerable too:** the TUI runs its thread on the shared app-server daemon by default; a second client connected to the daemon socket (WebSocket over the Unix socket `$CODEX_HOME/app-server-control/app-server-control.sock`), called `thread/loaded/list` + `thread/resume`, saw `waitingOnApproval`, received the replayed approval request, answered `accept`, and the TUI's command ran and its turn completed [P]. `PermissionRequest` hook (allow/deny JSON as Claude) fires in the TUI [P]. Decisions: `accept`, `acceptForSession`, `acceptWithExecpolicyAmendment`, decline/cancel [H]. Policy: `-a on-request|never`, app-server also `untrusted`/granular [P/H]. | No built-in prompts ("No permission popups") [H]. An extension's `tool_call` handler can block and ask via `ctx.ui.confirm`; in RPC mode this becomes `extension_ui_request {method: confirm}` answered by `extension_ui_response {confirmed: true}` [P]. Conduit therefore supplies its own gate extension. omp has a real approval system (`--approval-mode always-ask|write|yolo`, `--auto-approve`) and `--mode rpc-ui` / `acp` [H]. | `permission.asked` event; answer with `POST /session/:id/permissions/:permissionID` `{response, remember?}` [D]. |

### Prompt and instruction access

| Claude Code | Codex | Pi | OpenCode |
|---|---|---|---|
| `CLAUDE.md` (user `~/.claude/CLAUDE.md`, project, `.claude/CLAUDE.md`, local, imports via `@path`), `.claude/agents/*.md`, skills, output styles [D]. `InstructionsLoaded` hook reports which files loaded [D]. Stream-json `system/init` lists `memory_paths`, `agents`, `cwd`, `model`, `mcp_servers` [P]. `--system-prompt`, `--append-system-prompt[-file]`, `--agents`, `--bare`, `--safe-mode` [H]. User prompts: `UserPromptSubmit.prompt` [P] and transcript. System prompt itself not exposed. | `AGENTS.md` / `AGENTS.override.md` (global `$CODEX_HOME`, project hierarchy) [D]; app-server `thread/start` response returns `instructionSources` [P]; `session_meta.base_instructions` in rollouts [P]; `thread/start` params `baseInstructions`, `developerInstructions` [H]; `-c developer_instructions=…` [U]. | `AGENTS.md`/`CLAUDE.md` discovery (`--no-context-files`), `--system-prompt`, `--append-system-prompt` (repeatable, text or file), prompt templates, skills [H]. Extension `ctx.getSystemPrompt()` and `before_agent_start` can read/modify the system prompt [H]. | `AGENTS.md`, `opencode.json` `instructions` [D]. |

### Subagent exposure

| Claude Code | Codex | Pi | OpenCode |
|---|---|---|---|
| `SubagentStart`/`SubagentStop` hooks with `agent_id`, `agent_type`, `agent_transcript_path` [D]; subagent transcripts on disk [P]; stream-json messages carry `parent_tool_use_id`, `--forward-subagent-text` [P/H]; `result.subagent_stats` [P]; `TaskCreated`/`TaskCompleted` hooks [D]. | Feature `multi_agent` stable/on [H]; tools `spawn_agent`, `send_message`, `wait_agent`, `list_agents` [P]; app-server item types `collabAgentToolCall`, `subAgentActivity` [H]; hooks `SubagentStart`/`SubagentStop` [H]; subagents get their own rollout files [P]. | None built in ("no sub-agents") [H]; extensions/packages may add them. omp has bundled task agents [H]. | Agents/subagents exist [D]; exposure via events [U]. |

### Headless / JSON / RPC / SDK modes

| Claude Code | Codex | Pi | OpenCode |
|---|---|---|---|
| `claude -p --input-format stream-json --output-format stream-json --verbose [--include-hook-events] [--include-partial-messages]` with the bidirectional control protocol (`control_request initialize`, `can_use_tool`) [P]; Agent SDK wraps this [D]. `--bg`/`claude agents`/`attach`/`logs` background sessions [H]. | `codex app-server` JSON-RPC over stdio, `unix://`, `ws://` [P/H]; `generate-json-schema`/`generate-ts` give the exact protocol for the installed version [P]; `codex exec --json` JSONL [P]; `codex mcp-server` [H]; `--remote unix://…` TUI client [H]. | `pi --mode rpc` (JSONL commands/events + extension UI sub-protocol, strict LF framing) [P]; `--mode json` one-shot event stream [H]; Node `AgentSession` SDK [H]. omp adds `rpc-ui` and `omp acp` (Agent Client Protocol) [H]. | `opencode serve` HTTP + SSE, OpenAPI at `/doc`, `opencode run --format json`, `opencode acp` [D]. |

### Resume

| Claude Code | Codex | Pi | OpenCode |
|---|---|---|---|
| `--session-id <uuid>` to pre-choose the id, `-r/--resume <id>`, `-c/--continue` (latest in cwd), `--fork-session` [H]. | `codex resume <id|name> [--last]`, `codex fork`, `codex exec resume`, app-server `thread/resume`/`thread/fork` [H/P]. | `--session <path|id>`, `-c`, `-r`, `--fork`; RPC `switch_session`, `fork` [H]. | `--session`, `--continue`, `--fork` [D]. |

### Launch in a workspace cwd with an initial prompt

| Claude Code | Codex | Pi | OpenCode |
|---|---|---|---|
| Spawn in cwd: `claude [--session-id <uuid>] [--settings <json>] "<prompt>"`; `--add-dir` for extra roots [H]. First run in a new folder shows a trust dialog in the TUI (accepting it writes the user's `~/.claude.json`) [P]; `-p` skips it [H]. | `codex [-C <dir>] "<prompt>"` [H/P]; app-server `thread/start {cwd}` + `turn/start {input}` [P]. Project hooks need the `.codex` layer trusted; user hooks need hash review in the TUI ("Hooks need review" dialog) unless `--dangerously-bypass-hook-trust` [P]. | `pi "<prompt>"` in cwd, `@file` attachments [H]; RPC `prompt` [P]. | `opencode [project]`, `opencode run "<prompt>"` [D]. |

## Minimal proofs

All run under `/tmp/claude-1000/.../scratchpad`, wrapped in `timeout`.

1. **Claude headless permission round-trip + hooks.** `claude -p --model haiku --input-format stream-json --output-format stream-json --verbose --include-hook-events --permission-prompt-tool stdio --setting-sources local --settings <hooks.json>` driven by a Python client. Observed: `control_response` to `initialize`; `system` `hook_started`/`hook_response` for `SessionStart`, `UserPromptSubmit`, `PreToolUse:Bash`, `PermissionRequest:Bash`, `PostToolUse:Bash`, `Stop`; `system/init`; `control_request can_use_tool` for `Bash` answered `allow`; `result success`; `probe_file` created. Command hooks logged input keys for all seven events including `SessionEnd`.
2. **Claude interactive TUI in a PTY (tmux) answered from outside.** `claude --model haiku --setting-sources local --settings <hooks2.json>` where `PermissionRequest` ran a script that waited for an external decision file. Observed hook order `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PermissionRequest` (blocked), then after the file said `allow`: `PostToolUse`, `Stop`, `SessionEnd`; `probe_file` created; `~/.claude/sessions/<pid>.json` went `waiting` → `idle` and was deleted on exit. Raw PTY bytes (tmux `pipe-pane`): OSC 0 titles, OSC 8 links, DECSET 1004/2004/2031, no OSC 9/777.
3. **Codex exec JSONL + hooks + notify (isolated `CODEX_HOME`, mock provider).** `codex exec --json --dangerously-bypass-hook-trust "say hi" </dev/null` → `thread.started`, `turn.started`, `item.completed` (`error` warnings, `agent_message`), `turn.completed`; hooks `SessionStart`, `UserPromptSubmit`, `Stop`, `SessionEnd`; `notify` program received `agent-turn-complete`. (`codex exec` waits on stdin unless it is closed.)
4. **Codex app-server approval round-trip.** `codex app-server` (stdio): `initialize` → `thread/start {approvalPolicy: untrusted, sandbox: read-only}` → `turn/start`. Observed `thread/status/changed` active → active+`waitingOnApproval` → server request `item/commandExecution/requestApproval` → answered `accept` → `serverRequest/resolved` → active → idle → `turn/completed` `completed`; file created. Hooks did not run here because user hooks were untrusted and the flag was not passed.
5. **Codex manual TUI observed and answered through the daemon.** Started an isolated `codex app-server daemon`, ran the interactive `codex -a on-request -s read-only 'RUNTOOL'` in tmux (accepted the "Hooks need review" dialog), then a separate Python WebSocket-over-Unix-socket client: `initialize`, `thread/loaded/list`, `thread/resume` → status `waitingOnApproval`, received the approval request, answered `accept`; the TUI showed the command ran and the turn completed. `PermissionRequest` and the other hooks fired in the TUI. `codex app-server proxy` with raw JSON on stdin failed (broken pipe); the socket speaks WebSocket. The socket path is a symlink to `/tmp/codex-daemon-<uid>/<hash>` because of the 108-byte limit.
6. **Codex hook environment.** With `CONDUIT_PROBE_ENV` set only on the TUI's launch environment, `SessionStart`/`Stop` hooks saw it both with the daemon and with `--no-daemon`, and their parent was `codex`. So a per-PTY variable set by Conduit reaches Codex hooks.
7. **Pi RPC + permission-gate extension (isolated `PI_CODING_AGENT_DIR`, mock provider via `models.json`).** `pi --mode rpc --offline --provider mock --model mock-model -e pi-gate.ts`: `get_state` (keys `isStreaming`, `sessionFile`, `sessionId`, …), `prompt` accepted, events `agent_start` … `tool_execution_start bash` → `extension_ui_request confirm` → answered `confirmed: true` → `tool_execution_end` … `agent_end`; file created; extension saw `session_start` … `session_shutdown`; session JSONL written with the documented v3 entry types.

Not proven live: OpenCode (not installed); omp (no model access); Claude `Notification` hook and OSC 9 output (would need an unfocused window and a 60 s idle); Codex TUI OSC 9 output; anything over SSH.

## Gaps and fallbacks

**Baseline for every harness (harness-neutral, free):** PTY-level signals Conduit already
owns — child process tree / foreground process group (`tcgetpgrp`) and its argv to detect the
harness; OSC 0/2 title changes; BEL; OSC 9/777 notifications; DEC focus reporting so harnesses can
decide when to notify; output activity versus quiet; process exit status. These give working /
quiet / attention / exited, never "waiting for permission" with certainty. OSC 133 prompt marks come
from the user's shell, not from these TUIs, so they only show that the harness exited back to a
prompt.

- **Claude Code.** Gaps: no stable public API to attach to an already running interactive session
  besides hooks; transcript JSONL and `~/.claude/sessions/<pid>.json` are undocumented and change
  between releases; hooks only run if configured before the session starts (a manually started
  `claude` sees Conduit's hooks only if they are in user/project settings or a plugin); first-run
  folder-trust dialog. Fallbacks: user-level or plugin hooks installed with consent (TASK-53),
  per-PID registry plus transcript tail as best-effort detection, PTY baseline.
- **Codex.** Gaps: hooks need trust review (hash-tracked) unless managed or bypassed; `--no-daemon`
  sessions are not reachable through the daemon socket; the app-server protocol is marked
  experimental and changes per release (0.160.1 vs the user's 0.161.0 daemon already differ);
  rollouts omit approvals. Fallbacks: hooks for manual `--no-daemon` sessions, rollout tail, `notify`
  program, TUI OSC 9/BEL, PTY baseline. Generate the JSON schema from the installed binary at
  detection time and refuse unknown majors instead of guessing.
- **Pi.** Gaps: no hooks other than extensions, no permission prompts, no subagents. Fallbacks:
  Conduit ships a small extension (loaded with `-e` when Conduit launches pi, or installed to
  `~/.pi/agent/extensions` with consent for manual starts) that forwards events to Conduit's
  control endpoint and optionally gates tools; session JSONL tail; PTY baseline. omp keeps the Pi
  shapes and adds approvals, `rpc-ui` and ACP, so it is a variant of the same adapter.
- **OpenCode (docs only).** Gap: nothing verified locally; installing it needs user approval.
  Fallbacks: plugin forwarding events, PTY baseline.

## Over SSH

Only the PTY travels for free. Everything structured is remote:

- Hooks, extensions and plugins run on the remote host, inherit the remote PTY environment and see
  remote paths; transcripts and session files are remote files.
- Conduit-launched agents can use a second SSH exec channel for the structured surface:
  `claude -p … stream-json` over the channel's stdio, `codex app-server --listen stdio://`, or
  `pi --mode rpc`. No local socket is needed.
- Manual sessions: Codex's daemon socket can be reached with SSH Unix-socket forwarding
  (`direct-streamlocal`) [U]; Claude/Codex hooks and the Pi extension need a remote sink — a
  command hook appending JSON lines to a per-session file under the remote runtime dir that Conduit
  tails over an exec channel, or a reverse-forwarded socket to Conduit's control endpoint [U].
- Claude hook `terminalSequence` lets a remote hook emit OSC 9/777 through the existing PTY, so
  attention notifications survive with zero extra channels [D/U].
- With only a PTY: the baseline above (title, BEL, OSC 9/777, activity, exit).

## Implications for TASK-52's interface

| Adapter method | Claude Code | Codex | Pi (and omp) | OpenCode |
|---|---|---|---|---|
| detect installation | real (`claude --version`) | real | real | real if installed |
| launch in workspace context | real: interactive PTY plus injected `--settings` hooks and `--session-id`; or headless stream-json | real: PTY TUI on the daemon, or app-server thread | real: PTY with `-e conduit-ext`, or `--mode rpc` | real: TUI with `--port`, or `serve` |
| attach to existing session | partial: via user-installed hooks (from the next event) + per-PID registry/transcript (best-effort) | real when the TUI uses the daemon; partial (hooks/rollout) with `--no-daemon` | partial: only if the Conduit extension is installed; else transcript tail | real via server port [U] |
| event stream | real (hooks + stream-json; transcript for history) | real (app-server; hooks) | real (extension or RPC events) | real (SSE) [D] |
| send input | headless: real (stream-json user message); PTY: type into the terminal | real (`turn/start`, `turn/steer`) | RPC real (`prompt`/`steer`/`follow_up`); PTY: type | real (`prompt_async`) [D] |
| respond to permission | real (PermissionRequest hook reply or `can_use_tool` response) | real (server request reply; PermissionRequest hook) | real only through Conduit's gate extension; `unsupported` otherwise | real [D] |
| read prompt / instructions | real for files + `memory_paths`; system prompt `unsupported` | real (`instructionSources`, `base_instructions`) | files real; system prompt via extension | files real [D] |
| update prompt / instructions | files writable; running session `unsupported` | files writable; next thread only | files writable | files writable |
| subagents | real | real | `unsupported` (pi); omp partial | [U] |
| stop | real (SIGINT/`interrupt` control/terminate) | real (`turn/interrupt`, terminate) | real (`abort`, terminate) | real (`abort`) [D] |

Interface consequences:

1. Every capability must be optional per adapter and per session, with an explicit `unsupported`
   result, because the same harness gives different surfaces depending on how it was started.
2. Status needs a `source`/confidence notion (structured vs PTY heuristic) so the UI does not claim
   "waiting for permission" from a heuristic.
3. Permission requests need a correlation id, the tool name, a display description, an input
   summary and the harness's own decision list (Claude `permission_suggestions`, Codex
   `availableDecisions`); answers are asynchronous and may race the harness's own TUI dialog, so
   the model must accept "resolved elsewhere" (Codex sends `serverRequest/resolved`).
4. Session identity is the harness session id plus transcript path, learned from the first
   `SessionStart` hook / `thread/started` / `get_state`; Conduit should pre-assign where it can
   (`claude --session-id`) and must correlate hooks to its own PTY session through an environment
   variable it sets on the child (proven to reach Codex hooks; Claude hooks are child processes of `claude` and inherit its environment [U]), carried over the TASK-60
   control endpoint.
5. Transport must be pluggable per ExecutionContext (local socket, SSH exec channel, remote file
   tail) so TASK-61 does not change adapters.
