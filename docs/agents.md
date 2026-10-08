# Coding agents and Conduit

There are two separate topics here:

1. **Running a coding agent inside Conduit**: Claude Code, Codex, Pi or OpenCode in a Conduit tab.
   This works with no setup, because they are ordinary terminal programs. Launched with **Agent:
   launch**, Conduit also follows the agent: sidebar status, notifications, permission prompts,
   the agent view, the agent manager and the prompts view, locally and in SSH workspaces (see the
   [user guide](user-guide.md#agent-view)).
2. **Letting an agent drive Conduit**: the `conduit-test` CLI and MCP server, which an agent uses
   to launch an isolated Conduit, operate it through real input and take screenshots. This is the
   development and test loop for Conduit itself.

Everything below is verified on Linux only, with Claude Code 2.1.292, Codex 0.160.1, Pi 0.73.1 and
omp 18.6.1 installed. OpenCode 1.18.35 is not installed on the host; it was verified in a throwaway
ubuntu:24.04 container with a fixed local model (`scripts/opencode-container-check.sh`).

## Running agents inside Conduit (works today)

Start the harness in any tab, pane or the scratchpad exactly as in another terminal:

```sh
claude          # Claude Code
codex           # Codex
pi              # Pi (omp, the oh-my-pi fork, likewise)
opencode        # OpenCode
```

What Conduit provides for them now:

- **Your environment.** A shell started by Conduit inherits Conduit's whole environment
  (TASK-73): `PATH`, `HOME`, your API keys and exports, `SSH_AUTH_SOCK`, `DISPLAY` or
  `WAYLAND_DISPLAY`, `DBUS_SESSION_BUS_ADDRESS` and the locale. Harnesses therefore find their
  logins, config directories and credentials as usual. On top of it Conduit sets
  `TERM=xterm-256color`, `COLORTERM=truecolor` and `TERM_PROGRAM=conduit`. Started from a desktop
  launcher, Conduit has the desktop session's environment; your shell's startup files add the
  rest as usual.
- **Glyphs.** The harness UIs use box drawing, block elements, braille spinners, Powerline
  separators, Nerd Font icons and symbols such as `✻` and `❯`. Conduit draws box drawing, blocks,
  braille and Powerline at the exact cell size and bundles Symbols Nerd Font Mono for icons
  (TASK-39), so none of that needs a patched font. Emoji and CJK use installed fonts (for example
  `fonts-noto-color-emoji`, `fonts-noto-cjk`).
- **Throughput.** Large bursts of output (a harness redrawing or dumping a diff) are drained in
  bounded slices with frame coalescing, so the window stays responsive (TASK-72, TASK-75).
- **Links.** Ctrl+click (Cmd+click) opens URLs the harness prints and opens `path:line`
  references in `vi` in a new tab.
- **Keys.** Conduit never takes a key it has not bound: Ctrl+C reaches the harness as an
  interrupt, and Escape reaches it unless the scratchpad is shown (where Escape hides the
  scratchpad). Rebind any
  Conduit chord that collides with a harness shortcut in the [settings file](config.md#keybindings).

Current limits:

- **No clipboard writes from the program (OSC 52).** Conduit's OSC 52 policy is "ask" and the
  prompt does not exist yet, so a harness's own copy command (for example one that copies the last
  answer) is refused and logged. Select the text and use Ctrl+Shift+C (Cmd+C) instead.
- **Hand-started agents are observed, with less than a launch gives** (see
  [Observed agents](#observed-agents)); agents launched with **Agent: launch** get the full
  integration below.
- **WSL is not built.** Agents run locally or, in an SSH workspace, on the remote host
  ([user guide](user-guide.md#agents-in-ssh-workspaces)); there Codex and OpenCode keep the
  terminal-level status only.

### Agent integration

The adapter strategy is decided in `backlog/decisions/decision-7` and the evidence per harness is
in `backlog/docs/doc-3`. In short:

- Every agent keeps its own TUI in a Conduit pane. A harness-neutral baseline reads the PTY
  (process, window title, bell and OSC 9/777 notifications, output activity, prompt marks, exit)
  to show working / quiet / needs attention / exited.
- Each harness adds its own structured channel on top, injected at launch rather than written
  into your settings: Claude Code hooks reporting to a local Conduit control endpoint; Codex's
  app-server JSON-RPC (hooks for `--no-daemon` sessions); a Conduit-supplied Pi extension loaded
  with `-e`; OpenCode's HTTP/SSE server.
- Permission prompts can be answered from Conduit only with an explicit user gesture, and the
  harness's own dialog keeps working.
- Backlog.md tasks are linkable to agent sessions (an agent started from a task shows on its
  card).
- In an SSH workspace the agent runs on the remote host, and its hooks, extension and transcript
  are read and answered through the workspace's connection (TASK-61).
- The prompts view lists an agent's instruction files, prompts and subagent definitions with what
  may be edited, opens editable files in `vi`, and for Claude Code restarts the agent to apply an
  edit (TASK-59).

### Agents on Windows (TASK-82)

The control endpoint is a per-user named pipe on Windows (`\\.\pipe\conduit-<your SID>-r-…`,
open only to your logon session and never to remote clients; see
[control-api.md](control-api.md#security-model)), so `conduit control` works from PowerShell and
`cmd.exe` tabs as it does from a POSIX shell. A Claude Code launched with **Agent: launch** gets
hooks that need no `/bin/sh`: every hook runs `"<conduit.exe>" control agent.event
--event=<Hook>`, and the permission hook runs `"<conduit.exe>" control agent.permission --wait`,
which shows the request in the agent view, waits for your answer there and hands Claude Code the
allow or deny reply; Claude Code's own dialog keeps working beside it. This holds whether or not
the control endpoint is enabled: without it the hooks write to the agent's private directory under
`%LOCALAPPDATA%\conduit\agents`. Codex and OpenCode keep their own servers as on Linux (Codex's
daemon socket and OpenCode's loopback port), Pi's extension writes its sink file directly, and
none of the three has been run on Windows. Verified on the hosted Windows runner with a stand-in
Claude Code that runs the generated hook commands through `cmd.exe` (`--control-test`); a real
Claude Code on Windows has not been run.

### The editor tool (TASK-79)

A harness running in a Conduit terminal can use VSCodium as its editor through the control API:
`conduit control editor.open '{"path":"src/main.zig","line":120}'` opens the file in a VSCodium
pane split beside the terminal, later `editor.open`/`editor.goto` calls reuse that pane, and
`editor.diff`, `editor.reveal` and `editor.close` cover the rest. Conduit never installs VSCodium:
it detects `codium` (or the `editor.command` setting) in the workspace's context, runs it with a
per-workspace `--user-data-dir` under Conduit's state directory so your own VSCodium is never
touched, and answers `EditorNotInstalled` with an install hint when it is missing. Remote (SSH)
workspaces answer `EditorRemoteUnsupported` and use `vi` instead. On X11 the VSCodium window is
hosted inside the pane; on Wayland, macOS and Windows it stays a separate window
(`backlog/decisions/decision-12`).

Per-harness setup (a `CLAUDE.md`/`AGENTS.md` instruction, a Claude Code `PostToolUse` hook that
makes the editor follow every edit, a Pi tool and an OpenCode custom tool) is in
[control-api.md](control-api.md#the-editor-tool). The person gets the same pane from the palette
(`Editor: open file…`, typed as `path[:line[:col]]`) and from the terminal context menu
(`open in editor` over a file reference); both appear only where VSCodium was found. The pane
behaves like any pane for focus, resize, zoom and close, and Escape or its `× close` gives the
space back. Keyboard focus stays on the harness's terminal when a harness opens the editor.
Verified on Linux/X11 against a stand-in `codium` (`--editor-test`, the `editor-pane` scenario);
a real VSCodium, Wayland's separate-window fallback and macOS/Windows are unverified.

### Observed agents

A harness you start yourself in an ordinary tab or pane is noticed and followed on that tab
(TASK-56, TASK-78, TASK-81). When a terminal produces output, a prompt mark or input, Conduit
looks at the terminal's foreground job (at most once every 2 seconds per terminal, never per
frame). On Linux that is the PTY's foreground process group leader, its command line and working
directory read from `/proc`. Windows has no process groups and a pseudoconsole has no foreground,
so the ConPTY backend walks the terminal child's process tree instead: from one Toolhelp process
snapshot (taken at most every 250 ms and shared by every terminal) it steps from the shell to its
most recently started child while the process reached is itself a shell (`cmd`, PowerShell, Git
for Windows' `sh`/`bash`), and the first program that is not a shell is the job. A harness's own
helpers (`git`, a tool's `bash`) therefore never take its place. The job's command line comes
from `NtQueryInformationProcess` and its working directory from its PEB; a process that will not
say gives an empty directory. One tree it cannot follow: Git for Windows' `sh`/`bash` exec another
MSYS program by starting it and ending their own process, so an MSYS program run from Git Bash has
no live parent to be found through; native programs (`claude.exe`, `node.exe`, `cmd.exe`) are.

The program is named by the job's basename without a Windows or script extension (`claude.exe`,
`claude.cmd`, `cli.js`), in any case; for an interpreter (`node`, `bun`, `python3`, `sh` and
similar) by its script's, and a script inside `node_modules` by its npm package, so npm's
`node …/bin/codex` launcher counts as `@openai/codex` and a Windows shim's
`node.exe …\@anthropic-ai\claude-code\cli.js` as Claude Code; a shell that runs a command
(`cmd /c`, `pwsh -Command`/`-File`, `sh -c`) by that command's program. Each adapter owns its
spellings (`claude` and `@anthropic-ai/claude-code`, `codex` and `@openai/codex`, `pi`/`omp` and
`@mariozechner/pi-coding-agent`, `opencode` and `opencode-ai`). A recognized program
becomes an **observed** agent bound to that human terminal: its glyph leads the tab row,
notifications and the agent manager list it, and **Agent: stop** only stops observing it (the
process is the human's and is never signalled). What it gets beyond the PTY baseline depends on
the harness:

| Harness | How an observed agent attaches |
|---|---|
| Claude Code | Its own session registry: the record of the foreground pid, else the newest session in the process's cwd; then its transcript and registry status |
| Codex | The shared app-server daemon's newest thread in the process's cwd |
| Pi / omp | PTY baseline only (no extension is loaded in a hand-started Pi; its session JSONL is not followed live) |
| OpenCode | PTY baseline only: without `--port` the TUI starts no server Conduit can reach |

When the program leaves the foreground (it exits and the shell is back, or another program
replaces it) the observed agent ends as `done`; Conduit did not start it and cannot read its exit
status. Starting it again makes a new observed agent in place of the ended one. The scratchpad,
an agent's own terminal and an SSH connection terminal are never observed, and neither is a
terminal in an SSH workspace (there the local foreground is the SSH client). Foreground lookup
is implemented for Linux and Windows; the macOS PTY backend reports nothing yet, so a harness
started by hand there is not observed. On Windows it is proved on the hosted runner by
`--agent-test` (a scripted fake started by hand through `cmd /c` in a tab) and by an npm-installed, unauthenticated
Claude Code started as `claude` in a PowerShell tab, observed as `· claude idle` and marked
`✓ claude done` once it leaves (`windows-claude-observe.sh`). On the runner Claude Code answers
the first Ctrl+C with "Press Ctrl-C again to exit" but has not yet exited on the second one under
ConPTY, so the check ends it with `taskkill` and reports that with a warning.

The work is tracked as TASK-52 (adapter interface), TASK-53 to TASK-55 (Claude Code, Codex and Pi
adapters), TASK-56 (notifications), TASK-57 (agent view), TASK-58 (agent manager), TASK-59 (prompt viewer and editor), TASK-60
(control API), TASK-61 (agents over SSH), TASK-62 to TASK-64 (Backlog.md) and TASK-78 (OpenCode).
Live authenticated harness runs (a real Claude Code permission answered from the view, a real
remote Claude Code) have not been checked; the deterministic checks use a scripted fake agent.
OpenCode is the exception: `scripts/opencode-container-check.sh` runs a real OpenCode 1.18.35 in a
container, launches it with **Agent: launch**, answers its bash permission from the agent view and
sees the turn finish, and observes an `opencode` started by hand in a plain tab.

## Letting an agent drive Conduit

`conduit-test` is built by `zig build` into `zig-out/bin/` and is not part of the release
packages. It starts Conduit with a private, local-only driver endpoint (a Unix socket with owner-only
permissions; a protected named pipe on Windows, unverified) and an isolated `HOME`, `XDG_*` and
`TMPDIR` under its `--root`, so a test run never reads or writes your real configuration. Input
goes through the real SDL event queue.

### The CLI

```sh
zig build
root=/tmp/ct      # keep it short: the socket path must fit in 108 bytes
run="$(./zig-out/bin/conduit-test --root="$root" launch --width=960 --height=540 --scale=1 \
  --command='printf "READY\n"; exec /bin/sh -i')"
./zig-out/bin/conduit-test --root="$root" --run="$run" wait-for terminal-text READY 5000
./zig-out/bin/conduit-test --root="$root" --run="$run" inspect        # semantic tree (JSON)
./zig-out/bin/conduit-test --root="$root" --run="$run" key CTRL+SHIFT+p
./zig-out/bin/conduit-test --root="$root" --run="$run" type "new tab"
./zig-out/bin/conduit-test --root="$root" --run="$run" key ENTER
./zig-out/bin/conduit-test --root="$root" --run="$run" wait-for element workspace.1.tab.2 exists true 5000
./zig-out/bin/conduit-test --root="$root" --run="$run" screenshot     # prints the PNG path
./zig-out/bin/conduit-test --root="$root" --run="$run" quit
```

Commands: `launch`, `inspect`, `click`, `ctrl-click`, `double-click`, `right-click`, `drag`,
`key`, `type`, `scroll`, `terminal-text`, `wait-for element|terminal-text`, `logs`, `screenshot`,
`quit`; `--json` prints raw JSON-RPC. `CONDUIT_TEST_ROOT` and `CONDUIT_TEST_RUN` can stand in for
`--root` and `--run`. Elements are addressed by their stable semantic ids from `inspect`
(`sidebar.palette`, `workspace.1.tab.2`, `palette.query`, ...), never by pixel position. A
display is still needed: run under `xvfb-run -a` on a headless machine, or set `DISPLAY`.
`launch --visible` shows the window.

`AGENTS.md` ("Development loop") is the full procedure Conduit's own contributors follow, and
`docs/architecture.md` documents the driver protocol.

To try a harness inside an isolated run, note that `launch` gives the app a private `HOME`, which
logs the harness out. Pass your real home to that one command, and run it in a throwaway
directory:

```sh
./zig-out/bin/conduit-test --root=/tmp/ct launch --width=1280 --height=800 --scale=1 \
  --command='cd /tmp/sandbox && exec env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME -u XDG_CACHE_HOME HOME="$REAL_HOME" claude'
```

(`REAL_HOME` must be set in the environment you run `conduit-test` from; it is inherited.)

### The MCP server

`conduit-test mcp` serves the same commands as MCP tools over stdio: `launch`, `inspect`,
`click`, `ctrl_click`, `double_click`, `right_click`, `drag`, `key`, `type`, `scroll`,
`terminal_text`, `wait_for`, `get_logs`, `screenshot` (returned as an image plus the file path),
`quit`, and `editor_open` / `editor_goto` (the CLI's `editor-open <path> [line] [column]
[--split right|down]` and `editor-goto`), which drive the active workspace's VSCodium editor pane
like the `editor.open` and `editor.goto` control methods for the presented terminal (replying
`{}` once the pane exists, `Unsupported` with the install hint when VSCodium is missing). It opens no network listener. Run `zig build` first, and restart the client after
rebuilding.

**Claude Code.** The repository's `.mcp.json` registers it:

```json
{
  "mcpServers": {
    "conduit-test": {
      "type": "stdio",
      "command": "${CLAUDE_PROJECT_DIR:-.}/zig-out/bin/conduit-test",
      "args": ["mcp"]
    }
  }
}
```

Start `claude` in the repository and approve the project server when asked; `claude mcp list`
shows its status.

**Codex.** Codex does not read `.mcp.json`. Register the server once; this writes
`[mcp_servers.conduit_test]` to `~/.codex/config.toml` (or `$CODEX_HOME/config.toml`), so give it
an absolute path:

```sh
codex mcp add conduit_test -- "$PWD/zig-out/bin/conduit-test" mcp   # from the repository root
codex mcp list
```

`codex mcp remove conduit_test` undoes it. Registration was checked; a Codex session calling the
tools was not (the test account was rate-limited).

**Pi.** Pi has no built-in MCP client. Either load an MCP extension of your choice, or (simpler)
let Pi call the `conduit-test` CLI through its shell tool; the CLI and MCP surfaces are the same.

**Other MCP clients** need a local stdio entry with command `<repo>/zig-out/bin/conduit-test` and
argument `mcp`.
