# Conduit user guide

This guide covers what Conduit does today. Everything here is implemented and tested on Linux
(X11 and Wayland). The macOS chords are the shipped macOS defaults, but no macOS or Windows build
has been released or verified yet. The settings file grammar and every setting are in
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
  Shift+Tab move between rows, Up and Down move between workspace rows, and Enter activates the
  focused row. Until you focus the sidebar, Tab is ordinary terminal input.

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

Closing a tab whose shell is not sitting idle at a prompt asks first; Tab moves between the two
answers, Enter chooses, Escape keeps the tab. Closing the last tab quits Conduit.

A background tab that prints output is marked `* `; one that rings the bell is marked `! `.
Switching to it clears the mark.

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
[Sessions are restored](#sessions-are-restored). WSL workspaces are planned and not available yet.

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
  the column is recognised but not passed to `vi`. A configurable editor is planned.

The context menu's **open link** does the same for the link under the pointer.

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
outside closes.

When a program has captured the mouse, a plain right click is sent to the program; Shift+right
click still opens the menu. Setting `mouse.right_click = paste` (or starting with
`--right-click=paste`) makes a right click paste instead.

## Agent view

An agent launched with **Agent: launch** runs in its own tab as a real terminal. Ctrl+Shift+A
(Cmd+Shift+A), or **Agent: toggle view** in the palette, replaces that pane's terminal with the
agent view: the same session shown as structured, terminal-styled rows built from the events the
agent's harness reports. The terminal keeps running underneath, and the same chord or command
switches back to it.

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
grouped under Appearance, Fonts, Keys, Scratchpad and Mouse, with the value in effect (`·` marks a
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

## Configuration file

| Platform | Path |
|---|---|
| Linux and other Unix | `$XDG_CONFIG_HOME/conduit/config`, else `~/.config/conduit/config` |
| macOS (unverified) | `~/Library/Application Support/conduit/config` |
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

macOS chords are the shipped defaults for macOS builds; they have not been run on a Mac yet.

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
Built-in Symbols (`font.symbols.toggle`) and Font: Configure Fallbacks (`font.fallbacks`). An
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
