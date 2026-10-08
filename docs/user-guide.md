# Conduit user guide

This guide covers what Conduit does today. Everything here is implemented and tested on Linux
(X11 and Wayland). macOS (Apple silicon) is built as `Conduit.app` and checked on GitHub's macOS
runners — see [macOS](#macos) for what has and has not been verified there. No Windows build has
been released or verified yet. The settings file grammar and every setting are in
[`config.md`](config.md); this guide links there rather than repeating it.

Chords are written for Linux and Windows first, macOS second: "Ctrl+Shift+P (Cmd+Shift+P)". The
[keybinding reference](#keybinding-reference) at the end lists every default.

## The window

```
┌ sidebar ─────────┬ panes of the active tab ─────────────────────┐
│ workspace        │                                               │
│   Terminal 1     │                                               │
│   tests          │                                               │
│                  │                                               │
│ Palette  Ctrl+…  │                                               │
│ v0.1.8           │                                               │
└──────────────────┴───────────────────────────────────────────────┘
```

The sidebar on the left lists every workspace and, under each, its tabs. Its footer is a clickable
`Palette  <chord>` hint that opens the command palette, and the version. The rest of the window
shows the active tab's panes. Conduit's own interface is drawn in the terminal's cell grid and
colours; anything you can act on is clickable text.

The sidebar is an inset, not an overlay: showing, hiding or resizing it resizes the terminals.

- **Toggle**: Ctrl+Shift+B (Cmd+Shift+B), or click `‹` at its top right.
- **Resize**: drag its right edge, or Ctrl+Shift+Left/Right (Cmd+Shift+Left/Right).
- **Keyboard focus**: Ctrl+Shift+Down (Cmd+Shift+Down) focuses the active tab's row. Tab and
  Shift+Tab move between rows, Up and Down move between workspace rows (on a workspace row) or
  between tab and agent rows (on a tab or agent row), and Enter activates the focused row. Until
  you focus the sidebar, Tab is ordinary terminal input.

### Agent rows

Every agent gets a row of its own, nested one level under the tab it runs in, at the same size as
the tab rows (below the tab's branch row when it has one):

```
│ ! workspace        │
│   Terminal 1       │
│     ✓ claude done  │
│   ! Fake agent     │
│     ! codex permission
```

A row reads `<glyph> <harness> <state>` and changes the moment the agent's state does: `·` idle,
`▸ … working`, `? … input` (waiting for input), `! … permission` (waiting for permission), `✓ … done`,
`× … errored`. The row
appears as soon as the agent registers, whether you started it with **Agent: launch** or by
typing `claude`, `codex`, `pi`/`omp` or `opencode` in a tab yourself (a hand-started agent shows
its harness name before it reports anything). A finished agent keeps its row, showing `✓` or `×`,
until the tab closes or the agent is restarted.

Click a row, or focus it with the sidebar keys and press Enter, to bring the agent's workspace,
tab and pane forward and open its [agent view](#agent-view); activating the row again while that
view is showing closes it. A tab dragged onto an agent row moves to that row's tab. The glyph in
front of the tab name stays. Set `sidebar.agents = false` (or turn it off in the settings view's
Agents group) to keep only the glyphs.

Configuration problems appear in red at the bottom of the sidebar as `config:<line>: <message>`
(see [config.md, Errors](config.md#errors)).

## Terminal basics

Each pane runs a real PTY. Conduit starts `$SHELL` (else `/bin/sh`) with `TERM=xterm-256color`,
`COLORTERM=truecolor` and `TERM_PROGRAM=conduit`, and otherwise passes on its own environment, so
`DISPLAY`/`WAYLAND_DISPLAY`, `SSH_AUTH_SOCK`, `DBUS_SESSION_BUS_ADDRESS` and your exports reach
every shell. For bash, zsh and fish, Conduit injects shell integration without editing your files,
so it knows each shell's working directory (OSC 7) and where prompts start (OSC 133);
`--no-shell-integration` turns that off. See `assets/shell-integration/README.md`.

- **Selecting**: drag to select, double-click a word, triple-click a line. When a program has
  captured the mouse (vim, less, tmux), hold Shift to select anyway.
- **Copy and paste**: Ctrl+Shift+C / Ctrl+Shift+V (Cmd+C / Cmd+V). Ctrl+C is always sent to the
  program (SIGINT); Conduit never takes it. On Linux a middle click pastes the primary selection.
- **Scrollback**: the mouse wheel scrolls history; in full-screen programs such as less or vim
  the wheel goes to the program.
- **Programs copying to the clipboard (OSC 52)**: refused for now. Conduit's policy is to ask,
  and the prompt to ask with does not exist yet, so a program's `OSC 52` read or write is logged
  and ignored.

## Command palette

Ctrl+Shift+P (Cmd+Shift+P), or click the `Palette` hint in the sidebar. The palette lists every
command with its chord; typing fuzzy-filters by label and command name, and with an empty query
recently used commands come first.

- Up/Down or Tab/Shift+Tab move the highlight, Enter runs it, Escape or a click outside closes.
  Every row is also clickable.
- Commands that need an argument ask for it in a second step: a list of choices (Split pane:
  Right/Down) or a text prompt (Go to tab: a number). Escape backs out.
- While the palette is open no key or click reaches the terminal underneath.

The palette is the mouse path to every command; most have no other button.

## Tabs

Tabs belong to the current workspace and are listed in the sidebar. A new tab starts in the
directory its creator's shell last reported (else the workspace's directory) and is named
`Terminal <n>`.

| Do | Keyboard | Mouse |
|---|---|---|
| New tab | Ctrl+Shift+T (Cmd+T) | palette: New tab |
| Switch | Ctrl+PageUp/PageDown (Cmd+Shift+`[`/`]`), Alt+1..9 (Cmd+1..9) | click its row |
| Rename | F2, type, Enter (Escape cancels) | palette: Rename tab |
| Reorder | Alt+Shift+Up/Down | drag its row |
| Close | Ctrl+Shift+W (Cmd+W) | palette: Close tab |

**New tab with profile** in the palette lists your shell profiles and starts the one you pick
in a new tab named after it; see [Shell profiles](#shell-profiles).

Closing a tab whose shell is not sitting idle at a prompt asks first; Tab moves between the two
answers, Enter chooses, Escape keeps the tab. Closing the last tab quits Conduit.

A background tab that prints output is marked `* `; one that rings the bell is marked `! `.
Switching to it clears the mark.

When the focused pane's shell sits inside a git work tree, a small dim row under the tab's name
shows the branch (or the short commit of a detached HEAD). It follows the directory the shell
reports through shell integration (bash, zsh, fish and PowerShell), so a shell without it never
shows one; it is read from `.git/HEAD` through the workspace, and no `git` process runs.

## Panes

Every tab can be split into panes, to any depth. A new pane starts in the focused pane's
directory.

| Do | Linux and Windows | macOS |
|---|---|---|
| Split right / down | Ctrl+Shift+E / Ctrl+Shift+O | Cmd+D / Cmd+Shift+D |
| Focus left/right/up/down | Alt+Arrow | Cmd+Alt+Arrow |
| Resize toward a direction | Ctrl+Alt+Arrow | Cmd+Ctrl+Arrow |
| Zoom (fill the tab) / unzoom | Ctrl+Shift+Enter | Cmd+Shift+Enter |
| Close | Ctrl+Shift+X | Cmd+Shift+X |

With the mouse: click a pane to focus it, drag the divider between two panes to resize, and use
the context menu or palette to split. A zoomed pane's siblings keep running. Closing a pane gives
its space to its sibling; closing a tab's last pane closes the tab, with the same running-program
prompt as tab close.

## Shell profiles

A shell profile is a named command a new tab or pane runs, with its own environment variables,
starting directory and login mode. **New tab with profile** and **Split with profile** (which
splits the focused pane to the right) in the palette list them; Up/Down and Enter, or a click,
start one.

The list always begins with the built-in profiles, which need no setup:

| Platform | Built-in profiles |
|---|---|
| Linux, macOS | `login`: your `$SHELL` as a login shell |
| Windows | `pwsh` (PowerShell 7), `powershell` (Windows PowerShell) and `cmd`, whichever are installed |
| SSH workspace | `login`: the remote user's login shell |

Your own profiles come after them, from the settings file:

```
profile = work = /bin/zsh
profile.work.cwd = /home/me/src
profile.work.env = EDITOR=nvim
profile = py = python3 -q
shell = work
```

`shell` names the profile a plain **New tab** (Ctrl+Shift+T, Cmd+T), a split and the first tab
run. Without it, Conduit starts your `$SHELL` on Linux and macOS and, on Windows, the first of
PowerShell 7, Windows PowerShell and cmd that is installed. The settings view's Shells group shows
`shell` (editable) and one row per profile; a profile row opens the settings file, where profiles
are edited. [config.md, Shell profiles](config.md#shell-profiles) has the full grammar, including
quoting and binding a profile to a key.

PowerShell gets the same shell integration as bash, zsh and fish: Conduit adds
`-NoExit -Command` with its script after your own PowerShell profile has loaded, so new tabs open
in PowerShell's current directory and a tab at an idle prompt closes without asking.

## Scratchpad

Every workspace has one scratchpad: a separate shell started with the workspace and kept running
whether or not it is shown.

- Ctrl+`` ` `` (Cmd+`` ` ``) shows or hides it as a bottom dock at 50% of the window;
  Ctrl+Shift+`` ` `` (Cmd+Shift+`` ` ``) at 90%. The heights are the `scratchpad.size` and
  `scratchpad.large_size` settings.
- Escape, or the `hide` control on its border, hides it. Hiding never stops the shell; its
  history and running programs are there next time.
- `restart` on its border (or the palette's Scratchpad: Restart Session) replaces the shell with
  a fresh one.

## Workspaces

A workspace is a named set of tabs, panes and a scratchpad with its own working directory.
Conduit starts with one workspace named `default` in the directory it was launched from.
Workspaces are managed from the palette:

- **Create workspace** asks for a working directory; **Rename workspace** asks for a name;
  **Switch workspace** asks for the exact name. Clicking a workspace row in the sidebar also
  switches.
- **Close workspace** asks for confirmation, then ends every shell in it, scratchpad included.
  Closing the last workspace quits Conduit.

Quitting Conduit ends every shell, but the layout comes back next time: see
[Sessions are restored](#sessions-are-restored). WSL workspaces (Windows) are not restored yet.

## Sessions are restored

Conduit remembers your workspaces and puts them back when it starts again:

- every workspace with its name and directory, in sidebar order, and which one was selected;
- every tab in order, with the names you gave them (others get a fresh `Terminal N`), and which
  tab was selected;
- each tab's pane layout: the splits, where you dragged the dividers, which pane had focus and
  whether it was zoomed;
- the directory each shell was last in (as the shell reports it), where a fresh shell starts;
- the theme (unless the settings file names one, which always wins) and the window size.

Terminal contents, scrollback, running programs, environment variables, clipboard contents and
credentials are never saved: each restored pane starts a new shell in its directory. If that
directory no longer exists, the shell starts in the workspace's directory and the sidebar's status
line says which one moved. Agent tabs come back as plain shells.

An SSH workspace comes back with its host and tabs but does not connect on its own, so no
password, passphrase or host-key prompt appears before you ask for one. Its view reads
`ssh <host> ─ saved session; press Enter or click reconnect to connect`; Enter, a click on
`reconnect` or the palette's **Remote: reconnect** connects it, and every saved tab and pane then
starts in its remote directory.

The state is saved two seconds after the layout last changed and when Conduit quits, to
`$XDG_STATE_HOME/conduit/state.json` (else `~/.local/state/conduit/state.json`;
`~/Library/Application Support/conduit/state.json` on macOS, `%LOCALAPPDATA%\conduit\state.json`
on Windows), readable only by you. If the file is damaged, or was written by a newer Conduit,
Conduit starts clean, moves it aside as `state.json.corrupt-<time>`, and the status line reads
`previous state was unreadable; starting clean`.

To start clean once, run `conduit --no-restore` (that run still saves its own layout). To stop
saving and restoring altogether, set `restore.enabled = false` in the settings file. Runs with
`--command`, built-in checks and runs driven by `conduit-test` neither save nor restore.

## Links and file references

Hold Ctrl (Cmd on macOS) over terminal text to underline what Conduit recognises, and Ctrl+click
(Cmd+click) to open it. A plain click, a drag and a program's own mouse handling are unaffected.

- **Web links**: `http://` and `https://` URLs in the text, and OSC 8 hyperlinks a program
  emits, open in the system's default browser. An OSC 8 link's target is what opens, whatever
  text it is drawn over.
- **File references**: `path`, `path:line` and `path:line:col` (for example compiler errors such
  as `src/main.zig:142:7`) open in a new tab named after the file, running `vi +<line> -- <path>`.
  A relative path is resolved against the directory the shell reported. `vi` must be on `PATH`;
  the column is recognised but not passed to `vi`. With VSCodium installed, the context menu's
  **open in editor** opens the reference in the editor pane instead (see Editor pane).

The context menu's **open link** does the same for the link under the pointer.

## Editor pane (VSCodium)

When VSCodium is installed, a file can open in an editor pane split beside the terminal instead
of `vi` in a new tab. Conduit never installs VSCodium: it looks for `codium` on `PATH` (or the
command named by the `editor.command` setting, also in the settings view's Editor group) when a
workspace opens and whenever that setting changes. Until it is found, the commands below are not
offered, and a harness asking for the editor is told how to install it.

- **Palette**: `Editor: open file…` asks for `path`, `path:line` or `path:line:col`; a relative
  path is resolved against the directory the focused terminal reported.
- **Context menu**: right-click a file reference and choose **open in editor**.
- **Harnesses** use `conduit control editor.open` and friends (see `docs/agents.md`).

A workspace has one editor pane: the first open splits the current pane (focus moves to the new
pane), and later opens reuse it. The pane is a normal pane for Alt+Arrow focus, Ctrl+Alt+Arrow
resize, Ctrl+Shift+Enter zoom and Ctrl+Shift+X close. Its top row shows `editor ─ <file>:<line>`
and a clickable `× close`; Escape while the pane is focused, `× close` and `Editor: close` all
close it and give the space back to the neighbouring pane. Keys typed while the pane itself is
focused in Conduit do not reach any terminal.

On X11 the VSCodium window is hosted inside the pane and follows it as it moves, resizes, zooms,
or is hidden by another tab, workspace, the scratchpad or a dialog. On Wayland, macOS and Windows
VSCodium stays in its own window and the pane says so. Conduit runs its own VSCodium instance per
workspace with a separate `--user-data-dir` under Conduit's state directory, so your usual
VSCodium windows and settings are untouched (your extensions are shared), which is why VSCodium
shows its Restricted Mode banner the first time; trust the folder there if you want extensions
to run. In SSH workspaces `Editor: open file…` opens the file in `vi` in a new tab instead and
says why. Quitting Conduit leaves a hosted editor window running on the desktop, so unsaved work
is never lost.

Two things to know about the VSCodium install itself. A tarball install does not set up
VSCodium's `chrome-sandbox` helper, and on kernels that restrict unprivileged user namespaces
(Ubuntu 24.04 and later by default) a plain `codium` then exits at once with "The SUID sandbox
helper binary was found, but is not configured correctly"; either install VSCodium from its
package repository, which sets the helper up, or point `editor.command` at a wrapper script
that runs `codium --no-sandbox "$@"`. And a relative path is resolved against the directory the
terminal reported through shell integration; from a shell without it, the path is taken relative
to the workspace directory, where VSCodium opens a missing file as a new empty one.

## Search

Ctrl+Shift+F (Cmd+F) opens a search field over the focused pane. Matches in the screen and the
whole scrollback are highlighted as you type and the view scrolls to the current one.

- Enter or F3: next match. Shift+Enter or Shift+F3: previous.
- Alt+C toggles case sensitivity; Alt+R toggles regular expressions (Oniguruma syntax).
- Escape closes the field.
- The `prev`, `next`, `case`, `regex` and `close` controls beside the field do the same by mouse,
  and the palette has Search: Next match / Previous match / Toggle case sensitivity / Toggle
  regex.

The search chord is fixed for now: `keybind` can give `search.open` another chord but cannot
remove Ctrl+Shift+F (Cmd+F), and the keys inside the field are not rebindable.

## Context menu

Right-click a terminal pane, or press Shift+F10 to open the menu at the cursor. It offers, as they
apply: **copy** (only with a selection), **paste**, **open link** (only over a link), **split
right**, **split down** and **search**. Up/Down or Tab move, Enter chooses, Escape or a click
outside closes. Over a file reference in a workspace with VSCodium, **open in editor**
follows **open link**.

When a program has captured the mouse, a plain right click is sent to the program; Shift+right
click still opens the menu. Setting `mouse.right_click = paste` (or starting with
`--right-click=paste`) makes a right click paste instead.

## Agent view

An agent launched with **Agent: launch** runs in its own tab as a real terminal. Ctrl+Shift+A
(Cmd+Shift+A), or **Agent: toggle view** in the palette, replaces that pane's terminal with the
agent view: the same session shown as structured, terminal-styled rows built from the events the
agent's harness reports. The terminal keeps running underneath, and the same chord or command
switches back to it. A click on the agent's row in the sidebar ([Agent rows](#agent-rows)) opens
the view from anywhere.

- **Messages** start with who wrote them (`you ›`, the harness's name such as `claude ›`, or
  `system ›`) and wrap at the pane width; this is the one place Conduit wraps text. **Tool uses**
  read `⚙ <tool> <summary>`; subagents starting and finishing, notifications (`▪`), state
  changes (`· working`) and the agent's exit are dim lines.
- **File references** (`↳ path:line`) open in a new tab at that line, like a terminal file
  reference (`vi +<line> -- <path>`); click one, or Tab to it and press Enter. A relative path
  is resolved against the agent's directory.
- **Permission requests** show the request (`? Run: …`) and one clickable choice per answer the
  harness offers (for example **Allow once** and **Reject**). Click one, or press Tab to reach the
  first choice of the oldest open request, Left/Right or Tab to move, and Enter to answer. The
  answer goes to the harness; the row then shows what was sent and, once the harness reports it,
  the outcome (`✓ allowed`, `× rejected`, `↷ answered in the terminal`). A request answered in
  the agent's own terminal first loses its choices the same way. A harness that cannot take
  answers from Conduit shows its choices as plain text; answer it in the terminal.
- **Scrolling**: Up/Down by a row, PageUp/PageDown by a screen, Home/End to the ends, or the
  mouse wheel. The view follows new events while it is at the bottom.
- **Selecting and copying**: drag across rows, or Shift+arrows from the top visible row, then
  Ctrl+Shift+C (Cmd+C) or Ctrl+C. Rows are copied as plain text joined by newlines. Escape clears
  the selection.
- **Search**: Ctrl+Shift+F (Cmd+F) searches the view's rows instead of the terminal, with the
  same field, next/previous keys and controls. Matches are literal and do not span wrapped rows;
  regular expressions search the raw terminal only.

The view is not a terminal: other keys and typed text over it reach nobody, except Ctrl+C with
nothing selected, which still interrupts the agent. Paste into the raw terminal after switching
back. The view keeps the agent's most recent 4,096 events (4 MiB of text); older ones are dropped
with a note at the top. Transcript text is display only: nothing in it can open a file or answer a
request without your click or key.

Every view leads with a **▤ prompts and instructions** row: click it, or Tab to it and press
Enter, to open the [prompts view](#prompts-and-instructions) for that agent.

## Prompts and instructions

**Agent: prompts and instructions** in the palette, or the **▤ prompts and instructions** row at
the top of an agent view, opens a list of what the agent's instructions are made of. From the
palette it shows the agent in the presented pane (else the last one shown). Each row reads
`<name>  <size>  editable` or `<name>  <size>  read-only · <why>`:

- **Instruction files** the agent's harness reads for its directory, found through the
  workspace (so in an SSH workspace they are the remote host's files). Claude Code: `CLAUDE.md`,
  `.claude/CLAUDE.md` and `CLAUDE.local.md` in the agent's directory and every directory above
  it, `~/.claude/CLAUDE.md`, subagent definitions in `.claude/agents/*.md` and
  `~/.claude/agents/*.md` (`◆`), and its settings files (`⚙`). Codex: `AGENTS.md` and
  `AGENTS.override.md` up the tree, `~/.codex/AGENTS.md`, `~/.codex/config.toml`. Pi: `AGENTS.md`
  and `CLAUDE.md` up the tree, `~/.pi/agent/AGENTS.md`. OpenCode: `AGENTS.md` up the tree,
  `~/.config/opencode/AGENTS.md`, `.opencode/agent/*.md`, `opencode.json`. The harness's main file
  in the agent's own directory is listed even when it does not exist yet (`new`), so you can create
  it. Only files that exist are listed otherwise.
- **The system prompt**, which no harness lets Conduit read: `read-only · not exposed by this
  harness`.
- **The initial prompt** the agent was launched with (`launch ›`) and **the prompts you sent** in
  this session (`you ›`), from the agent's structured events: `read-only · sent`. The highlighted
  prompt's text is shown under the list.

Enter or a click on an editable file opens it in `vi` in a new tab of the agent's workspace (an
SSH workspace edits it on the remote host). A settings file the harness owns opens read-only
(`vi -R`, `read-only · harness-owned`). When the editor exits the list is read again, so the
row's size follows your edit. A file the workspace cannot read says `read-only on this host`.

Claude Code reads its instruction files when a session starts, so the view offers **restart with
updated instructions** (`a`, or click it): a running agent Conduit started is stopped and started
again in the same tab with the same harness, directory, initial prompt and task, as a new agent
(the [agent manager](#agent-manager)'s restart). For the other harnesses the row says edits take
effect on the next session. `r` or `refresh` reads the list again; Up/Down, Tab and Home/End move;
Escape or a click outside closes it. Keys and text over the view never reach the terminal beneath,
and nothing in a file or prompt runs: an editor opens only from your click or key.

## Agent manager

Ctrl+Shift+G (Cmd+Shift+G), or **Agents** in the palette, opens one list of every agent in every
workspace: Conduit's own launches and harnesses it noticed you start in a terminal. The
scratchpad never appears. Each row reads `<glyph> <harness>  <workspace> › <tab>  <task>  <state>
<last activity>`, ordered like the sidebar (workspace, then tab); states and ages update live while
the list is open. The task column names the backlog task an agent was started on from the
[backlog view](#backlog-view), or shows `–`.

| Key | Click | Does |
|---|---|---|
| Up/Down, Tab, Home/End | — | move the highlight |
| Enter | the row | close the list and show the agent's workspace and tab (its agent view if that tab shows one) |
| s | `stop` | hang up an agent Conduit started; one you started yourself is stopped in its own terminal |
| r | `restart` | start an exited or failed agent again in the same tab: same harness, directory and initial prompt, as a new agent |
| m | `message` | type a message in the field under the row; Enter or `send` sends it, Escape cancels |
| n | `new` | choose a harness, then a workspace, then an optional initial prompt; Enter or `launch` starts it in a new tab of that workspace |
| Escape | outside the list | close it (in a step, Escape or `back` returns to the list) |

A message goes to the harness's structured channel without leaving the list. A harness that has
none (Claude Code today) says `message unsupported` in the status line; type into its tab instead.
Keys and text over the list never reach the terminal beneath it.

## Agents in SSH workspaces

**Agent: launch** in an [SSH workspace](#workspaces) starts the agent on the remote host, over the
workspace's connection, in the directory of the pane you launched from. What Conduit needs to
follow it (Claude Code's hook relay and settings, Conduit's Pi extension) is written into a
private directory under the remote user's state directory
(`$XDG_STATE_HOME/conduit/agents/<run>`, else `~/.local/state/conduit/agents/<run>`), and Conduit
reads the agent's events and transcript, and writes your permission answers, there through the
same connection. Sidebar glyphs, notifications, the agent view, the agent manager and the prompts
view therefore work as they do locally.

- **Claude Code and Pi** report structured status, permission requests and transcripts.
- **Codex and OpenCode** run as plain terminal programs with the terminal-level status (activity,
  title, bell, OSC 9/777, exit) only; the launch list says `(terminal only here)`. Their
  structured channels (Codex's daemon socket, OpenCode's local port) are on the remote host and
  are not forwarded.
- The harness must be installed on the remote host; the launch list shows the ones found there.
- A remote agent's sink is removed when its tab closes, and the run's whole remote directory when
  the workspace closes or Conduit exits.
- Conduit's local control endpoint is not reachable from the remote host, so `conduit control`
  does not work in remote terminals.

## Backlog view

Ctrl+Shift+K (Cmd+Shift+K), or **Backlog** in the palette, covers the active tab's panes with the
workspace's [Backlog.md](https://github.com/MrLesk/Backlog.md) project: the `backlog/` directory in
the focused terminal's current directory (as its shell reports it), else the workspace's directory.
The view belongs to its workspace and stays open while you switch away; the sidebar, the palette and
every chord keep working, and the terminals beneath keep running. A directory without `backlog/`
says `no backlog/ here`. Only Local workspaces are read for now.

The **board** has a column per status in `config.yml`, each card `<id> <title>` over a dim row with
the agent working on it (glyph, harness, state), labels and assignees. The **list** has every task
in ordinal order with its status. Completed and draft tasks are not shown. Changes to the files —
from the `backlog` CLI, an agent, an editor or `git` — appear on their own.

| Key | Click | Does |
|---|---|---|
| Left/Right, Up/Down | — | move between columns and cards (Up/Down in the list) |
| Home/End, PageUp/PageDown | the wheel | first/last card, a page (the wheel scrolls the column under it) |
| l / b | `list` / `board` | switch mode |
| Enter | a card | open the task's detail |
| Escape | `close` | close the view |

The **detail** shows the title, status, priority, assignees, labels, milestone, dependencies, the
agent working on it, description, acceptance criteria and notes.

| Key | Click | Does |
|---|---|---|
| Up/Down, Tab, Home/End, PageUp/PageDown | the wheel | move the cursor between the status and the criteria (and scroll) |
| s, or Enter on the status | the status row | move the task to the next configured status |
| Enter or Space on a criterion | the criterion | check or uncheck it |
| a | `▶ start agent` | choose a harness, then start it on the task (below) |
| v | `▶ open in vi` | open the task's markdown in `vi` in a new tab and close the view |
| Escape | `close`, or outside the detail | close the detail |

Status and criteria change through the `backlog` CLI (`backlog task edit`), run in the project
directory on a worker; the view then reloads the file it rewrote. A CLI error appears in the
detail's message line; without the CLI the view is read-only (`backlog CLI not found`).

**Start agent** offers the harnesses `agent.launch` would (Enter or a click starts one, Escape or
`back` returns). The agent opens in a new tab of the workspace, in the project directory, with the
task as its initial prompt: `TASK-7: <title>`, the description and the acceptance criteria (at most
16 KiB; longer tasks are cut and marked). Its card, list row and detail then show its glyph, harness
and state live, and the [agent manager](#agent-manager) names the task in its task column.

## Settings view

Ctrl+Shift+, (Cmd+Shift+,) or the palette's **Settings** opens a dialog listing every setting,
grouped under Appearance, Fonts, Keys, Scratchpad, Mouse, Agents and Shells, with the value in effect (`·` marks a
value the settings file sets). Enter or a click edits a row: true/false values flip, `theme` and
`font.family` open their pickers, numbers and names open a field. Left/Right flip or step a value.
Every change is written to the settings file immediately and applies at once.

The Keys group lists every command without an argument with its chords. Choosing one waits for
the next chord you press and makes it that command's chord; a chord another command holds is
reported (`conflict: …`) and needs a second Enter to take. [config.md, The settings
view](config.md#the-settings-view) has the full behaviour.

**Open config file** (Ctrl+, / Cmd+,) opens the settings file itself in `vi` in a new tab,
creating it first with every default written out as comments. **Reload config** re-reads it.

## Themes

`theme` in the settings file, or the palette's **Theme: choose**, sets one colour scheme for the
terminals and for Conduit's interface. The picker previews the highlighted (or hovered) theme
across the whole window; Enter or a click keeps it and writes `theme = <name>` to the settings
file, Escape goes back.

Bundled: `conduit-dark` (default), `gruvbox-dark`, `gruvbox-light`, `catppuccin-mocha`,
`catppuccin-latte`, `dracula`, `nord`, `tokyo-night`, `solarized-dark`, `solarized-light`,
`one-dark`, `kanagawa-wave`, `everforest-dark`, `rose-pine`.

Your own themes are files in Ghostty's theme format in a `themes` directory beside the settings
file (`~/.config/conduit/themes/` on Linux by default), named in `theme` by file name. Theme files
from Ghostty's collection work unchanged. `theme = auto:<dark>,<light>` follows the desktop's
light/dark preference where the platform reports one. [config.md, Themes](config.md#themes)
covers the format and limits.

## Fonts

Conduit draws with the bundled JetBrains Mono unless `font.family` (or `--font=<family>`) names an
installed monospace family. **Font: Change Family** in the palette lists the installed monospace
families and previews each as you move over it.

- **Size**: Ctrl+= or Ctrl+Plus to grow, Ctrl+- to shrink, Ctrl+0 to reset to 14 points (Cmd with
  the same keys on macOS), one point at a time between 6 and 72. Each change is saved to
  `font.size`.
- **Bold and italic**: taken from the family's own faces, or from `font.bold`, `font.italic` and
  `font.bold_italic`; a family without them is emboldened or slanted.
- **Missing characters**: looked up in `font.fallbacks` (up to eight families, in order), then
  in every installed font, then in the bundled Symbols Nerd Font Mono (Nerd Font and Powerline
  icons) and JetBrains Mono. Colour emoji draw where an emoji font such as Noto Color Emoji is
  installed; CJK needs a CJK font such as Noto Sans CJK.
- **Box drawing, blocks, braille and Powerline separators** are drawn by Conduit at the exact
  cell size, so they join seamlessly in any font. `font.nerd_symbols = false` takes them from the
  fonts instead.
- **Ligatures** (`=>`, `!=`, `->`) form when the font has them and `font.ligatures` is `true`
  (the default); Font: Toggle Ligatures switches them.

## macOS

Conduit for macOS is an app bundle, `Conduit.app`, shipped in a disk image
(`conduit-<version>-macos-arm64.dmg`, Apple silicon) beside the Linux packages. Drag it to
Applications. The image is not signed with an Apple Developer ID or notarized yet, so the first
launch of a downloaded copy is refused; Control-click the app and choose **Open** once (or run
`xattr -dr com.apple.quarantine /Applications/Conduit.app`).

- **Keys** follow macOS: Command takes the place of Ctrl+Shift (Cmd+C / Cmd+V, Cmd+T, Cmd+W,
  Cmd+D, Cmd+F, Cmd+Shift+P; the [macOS table](#macos-1) lists them all). Control+letter always
  goes to the terminal, so Ctrl+C is SIGINT.
- **The menu bar** has the standard Quit (Cmd+Q), Hide (Cmd+H), Minimize (Cmd+M) and Toggle Full
  Screen (Ctrl+Cmd+F, also the green window button). Window ▸ Close closes the window but has no
  key: Cmd+W closes the tab.
- **Option** types accented and special characters, as in every Mac app. To use it as Alt (Meta)
  for Emacs, readline or tmux, set `macos.option_as_alt` to `true`, `left` or `right`
  ([config.md](config.md#macos-option-key)).
- **Retina**: the window draws at the display's pixel density; text is rendered at 2x on a 2x
  display.
- **Fonts**: `font.family` finds families in `/System/Library/Fonts`, `/Library/Fonts` and
  `~/Library/Fonts`, including the faces inside `.ttc` collections such as Menlo.
- **Settings file**: `~/Library/Application Support/conduit/config`.

Verified on a GitHub macOS 14 arm64 runner: the bundle and its icon, Launch Services start, a 2x
frame, Cmd+V and Cmd+C through the system pasteboard, per-user and system font discovery, Option+x
typed through the system's keyboard event tap (`≈` by default, ESC x with
`macos.option_as_alt = true`), and the built-in checks listed in `docs/release.md`. Not verified:
dead keys (Option+e then e), a real Retina display (the runner's display reports 1x; 2x was
proved with a fixed scale), desktop notifications (not implemented on macOS), clicking the menu
items, and the tab, pane, palette, workspace, search, config and settings checks, which still
fail on macOS (see `docs/release.md`).

## Windows

Conduit for Windows is a portable folder, shipped as `conduit-<version>-windows-x86_64.zip` beside
the Linux and macOS packages. Unzip it anywhere and run `Conduit\conduit.exe`; nothing is installed
or registered. The executables are not code-signed yet, so SmartScreen may warn on first launch
(**More info ▸ Run anyway**). Windows 10 1809 or later (ConPTY) on x86-64 is required.

- **Keys** are the Linux ones (Ctrl+Shift+C / Ctrl+Shift+V, Ctrl+Shift+T, Ctrl+Shift+P; the
  [Linux and Windows table](#linux-and-windows)). Ctrl+C without a selection is always the
  interrupt.
- **Shell**: the terminal runs your shell under ConPTY. Until shell profiles land (TASK-46), the
  shell is the program `SHELL` names (for example `set SHELL=C:\Windows\System32\cmd.exe` or the
  path to `pwsh.exe`).
- **High DPI**: Conduit is per-monitor DPI aware. Moving the window to a monitor with a different
  scale, or changing **Settings ▸ Display ▸ Scale**, re-renders text at the new density instead of
  stretching a blurry bitmap.
- **Title bar**: dark, to match the default theme.
- **Fonts**: `font.family` finds every font Windows lists (through DirectWrite): the fonts in
  `C:\Windows\Fonts` (Consolas, Cascadia Mono) and fonts installed **for one user**
  (`%LOCALAPPDATA%\Microsoft\Windows\Fonts`).
- **Clipboard**: copy and paste go through the Windows clipboard.
- **OpenGL**: Conduit draws with OpenGL 3.3, which every Windows display driver provides. A
  virtual machine with only Microsoft's basic display adapter has no OpenGL 3.3; there,
  Mesa's `opengl32.dll` (llvmpipe) placed beside `conduit.exe` works.
- **Settings file**: `%APPDATA%\conduit\config`.

### WSL

**Remote: Connect** on Windows lists the installed WSL distributions (`<name>  WSL`) after the SSH
hosts, profiles and recent destinations; click one or filter to it and press Enter. That opens a
workspace named after the distribution whose tabs, panes and scratchpad all run the
distribution's login shell through `wsl.exe`, starting in its home directory. There is no
connection step: the distribution boots with the first terminal. A WSL workspace is not saved
for the next start yet. File references in a WSL terminal may be spelled either
way: a Windows path such as `C:\Users\me\notes.txt:12` opens as `/mnt/c/Users/me/notes.txt` inside
the distribution, and a distribution path translates to `\\wsl.localhost\<distro>\...` where
Windows needs it. The drive mount root is read from the distribution's own `wslpath`, so a custom
`[automount] root` in `/etc/wsl.conf` is honoured.

Verified on a GitHub `windows-latest` runner (Windows Server 2025, build 26100, with Mesa's
llvmpipe standing in for a display driver): cmd.exe and PowerShell 7 typed into and drawn at scale
1 and 1.5, Unicode text input, Ctrl+Shift+V from and Ctrl+Shift+C to the Windows clipboard,
Consolas, Cascadia Mono and a per-user DejaVu Sans Mono found through DirectWrite, a live change
of the display scale from 100% to 125% re-rendering the open window at 800x450, the portable zip,
and the built-in checks listed in `docs/release.md`. The WSL context was proved against a real
Ubuntu (WSL2) the workflow installs on the runner, and against a scripted `wsl.exe` stand-in:
commands, file reads and atomic writes, a directory watch, three concurrent sessions in their own
directories inside the distribution, and path translation that agrees with the distribution's
`wslpath`. The app's WSL workspace was driven through `conduit-test` against that Ubuntu: Remote:
Connect listing it, its first tab, a split pane and the scratchpad running inside it, and a
ctrl-clicked `C:\Windows\win.ini:3` opening vi on `/mnt/c/Windows/win.ini`. Not verified: a real GPU driver, a second monitor, and IME composition with a real input method.

## Configuration file

| Platform | Path |
|---|---|
| Linux and other Unix | `$XDG_CONFIG_HOME/conduit/config`, else `~/.config/conduit/config` |
| macOS | `~/Library/Application Support/conduit/config` |
| Windows (unverified) | `%APPDATA%\conduit\config` |

The file is optional. Saving it applies the change at once: on Linux a watcher sees the save
(including editors that write a temporary file and rename it), elsewhere the file is checked once
a second. A bad line is reported and skipped; the rest of the file still applies. Every key, the
`keybind` syntax and the error rules are in [config.md](config.md).

```
theme = auto:gruvbox-dark,gruvbox-light
font.family = JetBrains Mono
font.size = 13
scratchpad.size = 40
keybind = ctrl+shift+p=unbind
keybind = ctrl+alt+p=palette.open
keybind = ctrl+alt+1=tab.goto:1
```

## Command line

From any terminal, the `conduit` command reuses a Conduit that is already running, or starts one
when none answers:

| Command | Effect |
|---|---|
| `conduit` | Start a new Conduit window |
| `conduit .` or `conduit <dir>` | Open a workspace in that directory, or switch to the one already open there |
| `conduit ssh <host>` | Open an SSH workspace for `[user@]host[:port]` or an `~/.ssh/config` alias, as **Remote: connect** does |
| `conduit workspace open <name>` | Switch to the workspace with that name, or open one of that name in the current directory |
| `conduit agent <harness> [prompt...]` | Launch `claude`, `codex`, `pi` or `opencode` in a new tab, with an optional first prompt |

Typed inside a Conduit terminal, these act on that Conduit, and `conduit agent` launches in that
terminal's workspace; from anywhere else they act on the running Conduit's active workspace. A
command prints nothing and exits 0 when it was carried out, or prints why and exits 1. A directory
is resolved against the current directory. Use `./ssh` for a directory that is called `ssh`.

Inside a Conduit terminal, `conduit control <method> [<json>]` also lets a script or a
coding-agent harness open a tab or pane in its own workspace, set its tab's status (shown in the
sidebar as `! busy api`), raise a notification, or show the agent or backlog view. The
scratchpad cannot be addressed this way. The methods, their parameters and harness hook examples
are in [control-api.md](control-api.md).

Both rely on local sockets that run when the `control.enabled` setting is on: by default in
development builds, and off in release builds until you turn it on (or pass `--control`). See
[config.md](config.md#keys).

## Command-line options

`conduit --help` lists every flag. The ones for everyday use:

| Flag | Effect |
|---|---|
| `--font=<family>` | Use this font family for this run, overriding `font.family` |
| `--right-click=<menu\|paste>` | Right-click behaviour for this run, overriding `mouse.right_click` |
| `--command=<line>` | Run this line with `/bin/sh -c` instead of an interactive shell, and quit when it ends |
| `--width=<px> --height=<px>` | Initial window size in logical pixels (default 960x640, or the restored size); either flag keeps the restored size from applying |
| `--no-restore` | Start with one clean workspace instead of the saved ones; this run still saves |
| `--scale=<factor>` | Fix the display scale instead of following the display |
| `--no-shell-integration` | Start shells exactly as they would start outside Conduit |
| `--log-level=<err\|warn\|info\|debug>`, `--log-dir=<dir>`, `--log-file=<path>` | Logging; `--print-log-path` prints where the log goes |
| `--version` | Print `conduit <version>` and exit |
| `--control`, `--no-control` | Run, or do not run, the control and single-instance endpoints this run, overriding `control.enabled` |

The `--*-test`, `--test-driver`, `--hidden` and `--screenshot` flags are for the test suite and
the agent tooling described in [agents.md](agents.md).

## Keybinding reference

These are the shipped defaults, read from `src/input.zig` (`linux_windows_default_bindings` and
`macos_default_bindings`) plus the chords handled directly by the search field and modal
surfaces. The palette and the settings view always show the chords actually in effect. Any
command except the fixed ones at the end can be rebound or unbound with `keybind` lines
([config.md, Keybindings](config.md#keybindings)) or in the settings view.

### Linux and Windows

| Command | Name | Chord |
|---|---|---|
| Copy (with a selection) | `clipboard.copy` | Ctrl+Shift+C |
| Paste | `clipboard.paste` | Ctrl+Shift+V |
| Open command palette | `palette.open` | Ctrl+Shift+P |
| Settings | `settings.open` | Ctrl+Shift+, |
| Open config file | `config.open` | Ctrl+, |
| Toggle sidebar | `sidebar.toggle` | Ctrl+Shift+B |
| Narrow sidebar | `sidebar.narrow` | Ctrl+Shift+Left |
| Widen sidebar | `sidebar.widen` | Ctrl+Shift+Right |
| Focus sidebar | `sidebar.focus` | Ctrl+Shift+Down |
| New tab | `tab.new` | Ctrl+Shift+T |
| Close tab | `tab.close` | Ctrl+Shift+W |
| Rename tab | `tab.rename` | F2 |
| Previous tab | `tab.previous` | Ctrl+PageUp |
| Next tab | `tab.next` | Ctrl+PageDown |
| Go to tab 1 to 9 | `tab.goto:1` … `tab.goto:9` | Alt+1 … Alt+9 |
| Move tab up / down | `tab.move:up` / `tab.move:down` | Alt+Shift+Up / Alt+Shift+Down |
| Split pane right / down | `pane.split:right` / `pane.split:down` | Ctrl+Shift+E / Ctrl+Shift+O |
| Focus pane | `pane.focus:left` … `:down` | Alt+Left / Alt+Right / Alt+Up / Alt+Down |
| Resize pane | `pane.resize:left` … `:down` | Ctrl+Alt+Left / Right / Up / Down |
| Zoom pane | `pane.zoom` | Ctrl+Shift+Enter |
| Close pane | `pane.close` | Ctrl+Shift+X |
| Scratchpad: Toggle 50% | `scratchpad.toggle-50` | Ctrl+`` ` `` |
| Scratchpad: Toggle 90% | `scratchpad.toggle-90` | Ctrl+Shift+`` ` `` |
| Open terminal context menu | `terminal.context-menu` | Shift+F10 |
| Font: Increase Size | `font.size.increase` | Ctrl+=, Ctrl+Shift+= (Ctrl+Plus) |
| Font: Decrease Size | `font.size.decrease` | Ctrl+- |
| Font: Reset Size | `font.size.reset` | Ctrl+0 |
| Open terminal search (fixed) | `search.open` | Ctrl+Shift+F |
| Agent: toggle view | `agent.view` | Ctrl+Shift+A |
| Agents | `agents.open` | Ctrl+Shift+G |
| Backlog | `backlog.open` | Ctrl+Shift+K |

### macOS

macOS chords are the shipped defaults for macOS builds. A unit test in `src/input.zig` holds this
table to the shipped one, row for row, and checks that every Linux/Windows Ctrl chord is a Command
chord here.

| Command | Name | Chord |
|---|---|---|
| Copy (with a selection) | `clipboard.copy` | Cmd+C |
| Paste | `clipboard.paste` | Cmd+V |
| Open command palette | `palette.open` | Cmd+Shift+P |
| Settings | `settings.open` | Cmd+Shift+, |
| Open config file | `config.open` | Cmd+, |
| Toggle sidebar | `sidebar.toggle` | Cmd+Shift+B |
| Narrow sidebar | `sidebar.narrow` | Cmd+Shift+Left |
| Widen sidebar | `sidebar.widen` | Cmd+Shift+Right |
| Focus sidebar | `sidebar.focus` | Cmd+Shift+Down |
| New tab | `tab.new` | Cmd+T |
| Close tab | `tab.close` | Cmd+W |
| Rename tab | `tab.rename` | F2 |
| Previous tab | `tab.previous` | Cmd+Shift+`[` |
| Next tab | `tab.next` | Cmd+Shift+`]` |
| Go to tab 1 to 9 | `tab.goto:1` … `tab.goto:9` | Cmd+1 … Cmd+9 |
| Move tab up / down | `tab.move:up` / `tab.move:down` | Option+Shift+Up / Option+Shift+Down |
| Split pane right / down | `pane.split:right` / `pane.split:down` | Cmd+D / Cmd+Shift+D |
| Focus pane | `pane.focus:left` … `:down` | Cmd+Option+Left / Right / Up / Down |
| Resize pane | `pane.resize:left` … `:down` | Cmd+Ctrl+Left / Right / Up / Down |
| Zoom pane | `pane.zoom` | Cmd+Shift+Enter |
| Close pane | `pane.close` | Cmd+Shift+X |
| Scratchpad: Toggle 50% | `scratchpad.toggle-50` | Cmd+`` ` `` |
| Scratchpad: Toggle 90% | `scratchpad.toggle-90` | Cmd+Shift+`` ` `` |
| Open terminal context menu | `terminal.context-menu` | Shift+F10 |
| Font: Increase Size | `font.size.increase` | Cmd+=, Cmd+Shift+= (Cmd+Plus) |
| Font: Decrease Size | `font.size.decrease` | Cmd+- |
| Font: Reset Size | `font.size.reset` | Cmd+0 |
| Open terminal search (fixed) | `search.open` | Cmd+F |
| Agent: toggle view | `agent.view` | Cmd+Shift+A |
| Agents | `agents.open` | Cmd+Shift+G |
| Backlog | `backlog.open` | Cmd+Shift+K |

### Commands with no default chord

Reachable from the palette, and bindable with `keybind`: Create workspace (`workspace.create`),
Rename workspace (`workspace.rename`), Switch workspace (`workspace.switch`), Close workspace
(`workspace.close`), Scratchpad: Restart Session (`scratchpad.restart`), Scratchpad: Hide
(`scratchpad.hide`), Search: Next match (`search.next`), Search: Previous match
(`search.previous`), Search: Toggle case sensitivity (`search.toggle-case`), Search: Toggle regex
(`search.toggle-regex`), Reload config (`config.reload`), Theme: choose (`theme.pick`), Font:
Change Family (`font.pick`), Font: Toggle Ligatures (`font.ligatures.toggle`), Font: Toggle
Built-in Symbols (`font.symbols.toggle`), Font: Configure Fallbacks (`font.fallbacks`), and,
where VSCodium was found, Editor: open file… (`editor.open`) and Editor: close (`editor.close`). An
argument-taking command needs its argument in a `keybind` line, for example
`keybind = ctrl+alt+w=workspace.switch:work`.

### Fixed keys inside Conduit's surfaces

These belong to the surface that has focus and are not rebindable yet. All platforms.

| Surface | Keys |
|---|---|
| Command palette | Up/Down, Tab/Shift+Tab move; Enter runs; Escape closes |
| Search field | Enter or F3 next; Shift+Enter or Shift+F3 previous; Alt+C case; Alt+R regex; Escape closes |
| Context menu | Up/Down, Tab/Shift+Tab move; Enter chooses; Escape closes |
| Settings view | Up/Down, Tab/Shift+Tab move; Home/End jump; Enter edits; Left/Right flip or step; Escape closes |
| Close and confirm prompts | Tab/Shift+Tab switch answer; Enter chooses; Escape cancels |
| Tab rename field | Enter saves; Escape cancels |
| Sidebar (once focused) | Tab/Shift+Tab move; Up/Down between workspaces; Enter activates |
| Scratchpad (shown) | Escape hides it |
| Agent view | Up/Down, PageUp/PageDown, Home/End scroll; Tab/Shift+Tab move between references and choices; Left/Right between a request's choices; Enter opens or answers; Shift+arrows select; Escape clears |
| Agent manager | Up/Down, Tab/Shift+Tab, Home/End move; Enter focuses; s stop; r restart; m message; n new; Escape closes or goes back |
| Prompts view | Up/Down, Tab/Shift+Tab, Home/End move; Enter opens the file in vi (read-only for harness-owned files); a restart with updated instructions (Claude Code); r refresh; Escape closes |
| Backlog view | arrows, Home/End, PageUp/PageDown move; l list; b board; Enter opens a task; Escape closes |
| Backlog task detail | Up/Down, Tab, Home/End, PageUp/PageDown move; Enter or Space toggles; s status; a start agent; v open in vi; Escape closes (or leaves the harness choice) |
| Any text field | Left/Right/Home/End (Shift extends the selection), Backspace, Delete; Ctrl+A / Ctrl+C / Ctrl+V (Cmd on macOS) select all, copy, paste |
