# Coding agents and Conduit

There are two separate topics here:

1. **Running a coding agent inside Conduit**: Claude Code, Codex, Pi or OpenCode in a Conduit tab.
   This works today with no setup, because they are ordinary terminal programs. Conduit-specific
   agent features (status, notifications, permission prompts, agent views) are planned, not
   built.
2. **Letting an agent drive Conduit**: the `conduit-test` CLI and MCP server, which an agent uses
   to launch an isolated Conduit, operate it through real input and take screenshots. This is the
   development and test loop for Conduit itself.

Everything below is verified on Linux only, with Claude Code 2.1.292, Codex 0.160.1, Pi 0.73.1 and
omp 18.6.1 installed. OpenCode has not been installed or tried.

## Running agents inside Conduit (works today)

Start the harness in any tab, pane or the scratchpad exactly as in another terminal:

```sh
claude          # Claude Code
codex           # Codex
pi              # Pi (omp, the oh-my-pi fork, likewise)
opencode        # OpenCode (untested)
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
- **No agent awareness.** Conduit does not know a pane is running an agent: no status in the
  sidebar, no "needs attention" notifications beyond a bell (`! ` on a background tab) and output
  activity (`* `), no structured transcript, no answering permission prompts from Conduit.
- **Local only.** SSH and WSL workspaces are not built, so agents run on the local machine.

### Planned agent integration

The adapter strategy is decided in `backlog/decisions/decision-7` and the evidence per harness is
in `backlog/docs/doc-3`. In short, and none of it exists yet:

- Every agent keeps its own TUI in a Conduit pane. A harness-neutral baseline reads the PTY
  (process, window title, bell and OSC 9/777 notifications, output activity, prompt marks, exit)
  to show working / quiet / needs attention / exited.
- Each harness adds its own structured channel on top, injected at launch rather than written
  into your settings: Claude Code hooks reporting to a local Conduit control endpoint; Codex's
  app-server JSON-RPC (hooks for `--no-daemon` sessions); a Conduit-supplied Pi extension loaded
  with `-e`; OpenCode's HTTP/SSE server.
- Permission prompts can be answered from Conduit only with an explicit user gesture, and the
  harness's own dialog keeps working.
- Backlog.md tasks will be linkable to agent sessions.

The work is tracked as TASK-52 (adapter interface), TASK-53 to TASK-55 (Claude Code, Codex and Pi
adapters), TASK-56 (notifications), TASK-57 (agent view), TASK-58 (agent manager), TASK-59 (prompt viewer and editor), TASK-60
(control API), TASK-61 (agents over SSH), TASK-62 to TASK-64 (Backlog.md) and TASK-78 (OpenCode).

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
`terminal_text`, `wait_for`, `get_logs`, `screenshot` (returned as an image plus the file path)
and `quit`. It opens no network listener. Run `zig build` first, and restart the client after
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
