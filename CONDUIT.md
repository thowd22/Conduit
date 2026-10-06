# CONDUIT.md — Product Specification

Conduit is a cross-platform terminal workspace built around persistent local/SSH environments and
coding agents. This document is the source of truth for **what the product does**.

- Derived from `conversation.md` (the original design conversation). Where the two differ, this
  document wins; `conversation.md` is kept as history, not as spec.
- **What counts as done** lives in `backlog/` tasks and their acceptance criteria.
- **How the code is organised** lives in `AGENTS.md` and, once written, `docs/architecture.md`.
  Those documents may not contradict this one; if they do, stop and resolve it with the user.
- Decisions that were deliberately deferred are listed in [Open questions](#12-open-questions).
  Do not invent answers to them.

---

## 1. The product in one paragraph

Conduit gives you one persistent workspace per project. Inside it: tabs and split panes running
real terminals, a scratchpad terminal that is always alive, connections to remote machines that
behave exactly like local ones, and first-class support for coding-agent harnesses (Claude Code,
Codex, Pi) with notifications, structured agent views and prompt editing. It is driven by keyboard
*and* mouse, it looks like a terminal — not a desktop app with a terminal in it — and it is built
so that an AI agent can drive and test it like a user.

```
                      CONDUIT
                         │
   Workspaces ── Command Palette ── Notifications
        │
   ┌────┼───────┬───────────┬─────────┐
   │    │       │           │         │
  Tabs Panes Scratchpad   Agents  backlog.md
   │    │       │           │         │
  PTY  PTY     PTY         Agent    Board
        │                   Manager  + detail
        │
   ExecutionContext ── Local │ SSH │ WSL
                             │
                    Shells / Processes

  Agent layer: Claude Code, Codex, Pi — adapters, prompts,
  subagents, notifications
```

Kinda like tmux, but easy to use.

**The name.** *Conduit* — one conduit between you, your terminals, your remote machines, your
coding agents and your work. The name deliberately avoids "term", "shell" and "AI": the product
is larger than all three, and a name that names one of them sells it short.

---

## 2. Product principles

These are not preferences. A change that violates one of them is a different product, and needs
the user's explicit agreement plus a decision record in the backlog.

**P1 — Terminal look and feel.** Everything is drawn as text in a monospaced grid with
box-drawing characters and glyphs. No rounded cards, no window title bars, no giant icons, no
native GUI chrome. Conduit's own chrome never uses emoji — a settings screen is a text screen.
Emoji that arrives in terminal or agent *content* are content, and must render (see §8).

**P2 — If it looks actionable, it is actionable; it need not look like a button.** Every tab
label, workspace name, agent name, filename, status glyph, URL and error location can have a hit
target, a hover state and a focus state. Hover may underline or highlight terminal cells
subtly.

**P3 — Keyboard and mouse parity.** Anything doable with the mouse has a keyboard path, and every
interactive element is clickable. Every command is a **named action** in the action registry,
reachable from a keybinding and from the command palette. No hidden mouse-only or keyboard-only
capability.

**P4 — Four UI primitives, no more.** All UI is built from `Text`, `InteractiveText`, `Surface`
and `Input`. Views such as the workspace sidebar, tab list, agent view, command palette,
scratchpad, backlog view, prompt editor, notifications and settings are *compositions* of those
four, not new widget kinds.

**P5 — One semantic tree.** Every UI element registers exactly once with a stable id, role, label,
state, bounds and action. Rendering, mouse hit testing, keyboard focus, the test driver and the
accessibility bridge all read that single tree. A second representation is a bug.

**P6 — Two renderers, one surface.** The terminal engine (libghostty) and the terminal-styled UI
renderer are separate and draw to a shared GPU surface. The UI is **not** ANSI text piped through
the terminal. The UI renderer understands structured objects — Markdown, filenames, prompts,
agents, backlog items — with hit boxes, actions, selection and hover states. This is what lets an
agent view *look* like CLI output while being a `FileReference` with a hit box, instead of a dumb
ANSI stream we regex-hack.

**P7 — Everything spawns through the workspace's ExecutionContext.** Local, SSH or WSL. No feature
may assume the local machine: no direct local process spawn, no local path or file read where the
workspace could be remote.

**P8 — Sessions outlive their views.** A session owns its PTY and terminal state and keeps
running while hidden. **Hiding is never termination.**

**P9 — The scratchpad belongs to the human.** One scratchpad per workspace, started with the
workspace, persistent. Agents and the control API can never own, target or take over the
scratchpad.

**P10 — Never steal terminal input.** Keys not bound by Conduit reach the terminal unmodified, and
Conduit must never unexpectedly swallow a control sequence. Ctrl+C with no selection is always
SIGINT.

**P11 — Harness-neutral agents.** Claude Code, Codex and Pi specifics live only inside their
adapters, behind one common adapter interface. Nothing outside the agent layer may special-case a
harness.

**P12 — Platform code stays behind interfaces.** OS-specific code lives in the platform, PTY and
font-discovery backends. Shared modules contain no OS conditionals beyond selecting a backend.

---

## 3. The product model

A **workspace** is the unit of everything. It is not a window, and not a bag of windows.

```
Workspace  (name, theme, state, layout, session metadata)
├── ExecutionContext        Local │ SSH │ WSL
├── Working Directory        tracked cwd, inherited by new tabs, panes and the scratchpad
├── Tabs
│   ├── Tab → one or more panes (split tree)
│   └── Pane → Session (PTY + terminal state)
├── Scratchpad               one persistent Session, started with the workspace
├── Agents                   Claude Code │ Codex │ Pi, each an Adapter over its own sessions
├── backlog.md               board and task detail for this workspace
└── State                    layout, theme, environment, session metadata
```

Everything inside inherits the workspace's ExecutionContext. In an SSH workspace, new tab, new
pane, scratchpad, agent and backlog view all operate against the remote host, which makes a remote
workspace nearly indistinguishable from a local one.

**Human terminal space vs agent terminal space.** Humans own tabs, panes and the scratchpad.
Agents own their own managed PTYs (agent session, task sessions, subagent sessions). The UI may
show both; an agent must never commandeer the terminal where the human has `vim` open.

---

## 4. Feature catalogue

Priority is a product statement: **Primary** features define Conduit, **Secondary** features are
supported but never at the cost of the primary ones. `v0.1` says whether the feature ships in the
first release (see [§5](#5-v01-scope)).

| # | Area | Feature | Priority | v0.1 | Tasks |
|---|---|---|---|---|---|
| 1 | Terminal | Terminal emulation and grid state (libghostty) | Primary | yes | TASK-2, TASK-9 |
| 2 | Terminal | PTY abstraction with POSIX backend | Primary | yes | TASK-8 |
| 3 | Terminal | Window, GPU surface and event loop | Primary | yes | TASK-7, TASK-3 |
| 4 | Terminal | Terminal grid renderer | Primary | yes | TASK-11 |
| 5 | Terminal | Font manager v1: discovery, loading, shaping, glyph atlas | Primary | yes | TASK-10 |
| 6 | Terminal | Keyboard input encoding and IME | Primary | yes | TASK-12 |
| 7 | Terminal | Mouse reporting and text selection | Primary | yes | TASK-14 |
| 8 | Terminal | Clipboard: native copy/paste and OSC 52 | Primary | yes | TASK-15 |
| 9 | Terminal | Scrollback and viewport scrolling | Primary | yes | TASK-13 |
| 10 | Terminal | Search in scrollback | Primary | yes | TASK-36 |
| 11 | Terminal | Shell integration: cwd tracking and prompt marks | Primary | yes | TASK-17 |
| 12 | Terminal | Windows ConPTY backend | Primary | yes | TASK-16 |
| 13 | Font | Font manager v2: fallback chains, emoji, symbols, ligatures, DPI | Primary | no | TASK-39 |
| 14 | Font | Font picker and font commands (via the palette) | Primary | no | TASK-40 |
| 15 | UI | Primitives: `Text`, `InteractiveText`, `Surface`, `Input` | Primary | yes | TASK-18 |
| 16 | UI | Semantic element tree, hit testing, hover and focus | Primary | yes | TASK-19 |
| 17 | UI | Input routing, action registry and keybinding system | Primary | yes | TASK-20 |
| 18 | UI | Minimal terminal-style context menu | Primary | yes | TASK-35 |
| 19 | Workspace | Workspace, ExecutionContext and Session model | Primary | yes | TASK-27 |
| 20 | Workspace | Left sidebar: workspaces and tabs | Primary | yes | TASK-28 |
| 21 | Workspace | Tabs: create, close, rename, reorder, switch | Primary | yes | TASK-29 |
| 22 | Workspace | Split panes: layout tree, navigation, resize, zoom | Primary | yes | TASK-30 |
| 23 | Workspace | Command palette (Spotlight-style) | Primary | yes | TASK-31 |
| 24 | Workspace | Scratchpad: persistent popup terminal per workspace | Primary | yes | TASK-32 |
| 25 | Workspace | Multiple workspaces: create, switch, close | Primary | yes | TASK-33 |
| 26 | Workspace | Clickable links and file references in terminals | Primary | yes | TASK-34 |
| 27 | Config | Configuration file with hot reload | Primary | no | TASK-37 |
| 28 | Config | Theme engine and popular color schemes | Primary | no | TASK-38 |
| 29 | Config | Terminal-style settings view | Primary | no | TASK-41 |
| 30 | Connections | SSH ExecutionContext (seamless local/remote) | Primary | no | TASK-42, TASK-43 |
| 31 | Connections | Remote scratchpad and cwd inheritance | Primary | no | TASK-45 |
| 32 | Connections | Remote connection manager | Primary | no | TASK-44 |
| 33 | Connections | macOS platform polish | Primary | no | TASK-48 |
| 34 | Connections | Linux platform polish | Primary | no | TASK-50 |
| 35 | Connections | Windows platform port | Primary | no | TASK-49 |
| 36 | Connections | Shell profiles and **PowerShell** support | **Secondary** | no | TASK-46 |
| 37 | Connections | WSL ExecutionContext | **Secondary** | no | TASK-47 |
| 38 | Agents | Agent adapter interface and agent state model | Primary | no | TASK-51, TASK-52 |
| 39 | Agents | Claude Code adapter | Primary | no | TASK-53 |
| 40 | Agents | Codex CLI adapter | Primary | no | TASK-54 |
| 41 | Agents | Pi adapter | Primary | no | TASK-55 |
| 42 | Agents | Agent notifications | Primary | no | TASK-56 |
| 43 | Agents | Agent view: structured, clickable transcript | Primary | no | TASK-57 |
| 44 | Agents | Agent manager view | Primary | no | TASK-58 |
| 45 | Agents | Prompt viewer and editor | Primary | no | TASK-59 |
| 46 | Agents | Control API for harnesses to spawn tabs and panes | Primary | no | TASK-60 |
| 47 | Agents | Agents in SSH workspaces | Primary | no | TASK-61 |
| 48 | Backlog.md | backlog.md data layer | Primary | no | TASK-62 |
| 49 | Backlog.md | Backlog view: board and task detail | Primary | no | TASK-63 |
| 50 | Backlog.md | Link backlog tasks to agents | Primary | no | TASK-64 |
| 51 | Testing | Test driver: in-app automation server | Primary | yes | TASK-21 |
| 52 | Testing | Screenshot capture and headless runs | Primary | yes | TASK-22 |
| 53 | Testing | `conduit-test` CLI | Primary | yes | TASK-23 |
| 54 | Testing | E2E test harness and first scenarios in CI | Primary | yes | TASK-25 |
| 55 | Testing | `conduit-test` MCP server | Primary | yes | TASK-24 |
| 56 | Testing | Documented agent development loop | Primary | yes | TASK-26 |
| 57 | Infra | Zig project scaffold and module layout | Primary | yes | TASK-4 |
| 58 | Infra | CI matrix for Linux, macOS and Windows | Primary | yes | TASK-5 |
| 59 | Infra | Logging and diagnostics infrastructure | Primary | yes | TASK-6 |
| 60 | Ship | Workspace persistence and restore | Primary | no | TASK-65 |
| 61 | Ship | `conduit` CLI and single-instance IPC | Primary | no | TASK-66 |
| 62 | Ship | Performance and latency pass | Primary | no | TASK-67 |
| 63 | Ship | Accessibility bridge from the semantic tree | Primary | no | TASK-68 |
| 64 | Ship | Packaging and release pipeline | Primary | no | TASK-69 |
| 65 | Ship | User documentation and README | Primary | no | TASK-70 |

Rows 36 and 37 are the explicitly secondary features: WSL and PowerShell are supported, not
first-class citizens, and never block a primary feature.

---

## 5. v0.1 scope

**v0.1 = milestones M0–M3.** It is the smallest release in which a person can open the app, get a
real terminal, organise work in tabs and panes, use the scratchpad and the command palette, and
have the whole thing covered by automated end-to-end tests. Conduit is not "an agent IDE" in
v0.1; it is a workspace shell around excellent terminals.

### In scope for v0.1

1. **Foundation.** Zig project scaffold and module layout; CI on Linux, macOS and Windows;
   scoped logging and diagnostics. *(M0: TASK-1 – TASK-6, including the libghostty and
   windowing/GPU spikes)*
2. **Terminal core.** Window, GPU surface and event loop; PTY with a POSIX backend and the Windows
   ConPTY backend; libghostty terminal state wired to the PTY; grid renderer; font manager v1 with
   discovery, shaping and a glyph atlas; keyboard encoding with IME; mouse reporting and text
   selection; clipboard including OSC 52; scrollback; shell integration for cwd tracking and prompt
   marks. *(M1: TASK-7 – TASK-17)*
3. **UI toolkit.** The four primitives; the semantic element tree with hit testing, hover and
   focus; input routing with the action registry and per-platform default keybindings. *(M2:
   TASK-18 – TASK-20)*
4. **Test driver and E2E.** The in-app automation server, screenshots and headless runs, the
   `conduit-test` CLI, the `conduit-test` MCP server, the E2E harness with first scenarios running
   in CI, and the documented agent development loop. *(M2: TASK-21 – TASK-26)*
5. **Workspace shell.** Workspace/ExecutionContext/Session model; left sidebar; tabs; split panes;
   command palette; the scratchpad; multiple workspaces; clickable links and file references;
   search in scrollback; the terminal-style context menu. *(M3: TASK-27 – TASK-36)*

Because v0.1 has no configuration file, every value that an acceptance criterion calls
"configured" — font family, OSC 52 policy, editor command, right-click behaviour — resolves to a
built-in default in v0.1. Keybindings ship as per-platform defaults (TASK-20); user rebinding
arrives with the config system (TASK-37). Likewise the palette lists every action the shipped
features register, and a palette command for a feature that has not landed appears when it lands.

### Explicit non-goals for v0.1

These are out of scope on purpose. Naming them prevents scope drift:

- **No remote connections.** SSH, WSL and PowerShell are not in v0.1. The ExecutionContext
  abstraction must exist and must be local-only, but no SSH transport, connection manager or
  remote scratchpad ships. Shell integration in v0.1 covers bash, zsh and fish (TASK-17).
- **No agent integration.** No Claude Code, Codex or Pi adapter, no agent view, no agent manager,
  no agent notifications, no prompt viewer/editor, no control API. The semantic tree and the test
  driver are what make that layer possible later; the layer itself is not in v0.1.
- **No backlog.md integration.** No data layer, board, task detail or task↔agent linking.
- **No user-facing configuration.** No config file, no hot reload, no theme engine, no settings
  view, no font picker. v0.1 ships with built-in defaults.
- **No font manager v2.** No fallback chains, emoji, symbol coverage, ligatures or DPI scaling
  beyond what v1 provides.
- **No persistence.** Workspaces do not survive a restart of the app.
- **No `conduit` CLI** (the `conduit-test` automation CLI *is* in scope), no single-instance IPC,
  no accessibility bridge, no packaging or release pipeline.

---

## 6. After v0.1

| Milestone | Content | Tasks |
|---|---|---|
| M0 | Product spec, libghostty and windowing/GPU spikes, project scaffold, CI matrix, logging | TASK-1 – TASK-6 |
| M1 | Terminal core: window and event loop, PTY, libghostty state, grid renderer, fonts v1, keyboard and IME, mouse and selection, clipboard, scrollback, ConPTY, shell integration | TASK-7 – TASK-17 |
| M2 | UI toolkit, semantic tree, actions and keybindings, test driver, screenshots, `conduit-test` CLI and MCP server, E2E harness, agent development loop | TASK-18 – TASK-26 |
| M3 | Workspace shell: model, sidebar, tabs, splits, palette, scratchpad, workspaces, clickable links, scrollback search, context menu | TASK-27 – TASK-36 |
| M4 | Configuration with hot reload, theme engine, font manager v2, font picker, settings view | TASK-37 – TASK-41 |
| M5 | SSH ExecutionContext, remote scratchpad and cwd inheritance, connection manager, shell profiles and PowerShell, WSL, macOS/Linux/Windows platform polish | TASK-42 – TASK-50 |
| M6 | Agent adapter interface, Claude Code / Codex / Pi adapters, notifications, agent view, agent manager, prompt viewer and editor, control API, agents over SSH | TASK-51 – TASK-61 |
| M7 | backlog.md data layer, board and task detail, task↔agent linking | TASK-62 – TASK-64 |
| M8 | Workspace persistence and restore, `conduit` CLI and single-instance IPC, performance pass, accessibility bridge, packaging and release, user documentation | TASK-65 – TASK-70 |

The `conduit` CLI surface (TASK-66) is deliberately shaped like the product:

```
conduit                                   open the app
conduit .                                 open a workspace for the current directory
conduit ssh devbox                        open a remote workspace
conduit workspace open semantscript
conduit agent codex
conduit agent claude
```

---

## 7. Interaction model

Sections 7–10 describe the target product. Where a feature is not in v0.1, its milestone is given
in [§4](#4-feature-catalogue) and [§6](#6-after-v01).

### Mouse semantics

These hold in normal terminals **and** in Conduit's structured views (agent views, backlog view,
palette, settings):

| Gesture | Behaviour |
|---|---|
| Click | Select a tab, workspace, agent or item; position the cursor where supported |
| Ctrl+Click (Linux/Windows), Cmd+Click (macOS) | Open a URL; open `src/foo.zig:142` via the configured editor action |
| Drag | Normal terminal text selection; drag a pane divider to resize a split |
| Double / triple click | Select word / line |
| Right click | Configurable, defaulting to the minimal terminal-style context menu |
| Middle click | Unix-style paste where configured |
| Wheel / trackpad | Scroll terminal history or the view |
| Click a label | Switch workspace or tab immediately |
| Drag a tab | Reorder, and move between panes where that is supported |

### Clipboard and the Ctrl+C rule

- Native copy/paste with Ctrl/Cmd+C and Ctrl/Cmd+V, while preserving terminal conventions such as
  Ctrl+Shift+C/V where the shell expects them.
- **If terminal text is selected, copy may be bound separately; otherwise Ctrl+C must remain
  SIGINT.** Conduit must never unexpectedly steal a control sequence from the terminal.

### Command palette

Spotlight-style, opened by keybinding, fuzzy-filtering over every action in the registry, showing
the bound key of each action, ranking recently used actions first, and supporting nested steps
(pick, then input) so a command can collect an argument. Fully keyboard-driven **and** every row
clickable. The same overlay is reused for pickers such as the font family list.

In v0.1 the palette covers what v0.1 ships: new tab, new pane, new workspace, close and switch
tab/workspace, split pane, scratchpad size. Commands whose feature has not landed — settings,
theme, font, remote connect, agent commands — appear when that feature lands (M4, M5, M6).

### Agent views are richer than terminals

An agent response still *looks* like CLI output, but the rows underneath are structured elements:

```
CLAUDE  feature/auth
────────────────────────────────────────────────────────

● Investigating authentication failure

  Read   src/auth/middleware.ts
  Edit   src/auth/session.ts:87

  ┌ prompt ──────────────────────────────────────────
  │ Fix session expiration without changing the
  │ public authentication API.
  └──────────────────────────────────────────────────

  Waiting for permission:
  › Run integration tests
    Allow once   Always allow   Reject
```

- Click `src/auth/session.ts:87` → open or navigate.
- Click the prompt → edit the agent's current prompt where the harness supports it.
- Click the agent → focus it.
- Click a permission choice → answer the harness.
- Click a backlog.md task → inspect it, or associate an agent with it.

Text is the presentation; the interaction model is not text-only.

---

## 8. Fonts

Fonts are a first-class subsystem, not a two-line config key.

```
FontManager
├── Discovery      Linux/macOS directory scan │ Windows DirectWrite │ bundled fallback
├── Shaping        HarfBuzz-quality shaping
├── Glyph atlas    cached rasterised glyphs
├── Fallback chains
├── Emoji
├── Nerd Font symbols (Powerline)
├── Ligatures
└── DPI / scaling
```

Separate faces are configured independently:

```
font.family       = "JetBrains Mono"
font.bold         = "JetBrains Mono Bold"
font.italic       = "JetBrains Mono Italic"
font.bold_italic  = "JetBrains Mono Bold Italic"

font.size         = 14
font.ligatures    = true
font.nerd_symbols = true
```

A missing glyph must never turn a terminal into boxes: a prompt containing Japanese, emoji,
Powerline symbols or mathematical characters has to render. Nerd Font/Powerline support is
effectively mandatory for the target audience — Starship, Powerlevel10k, Neovim and tmux
integrations must work flawlessly — but users are **not** forced to install a Nerd Font; a fallback
symbol font fills missing terminal glyphs where licensing and distribution permit.

The font picker is not a native dialog: it is a command-palette-like overlay, driven from the
keyboard and clickable, listing discovered families and showing previews.

```
> font

  Font: Change Family
  Font: Increase Size
  Font: Decrease Size
  Font: Reset Size
  Font: Toggle Ligatures
  Font: Configure Fallbacks
```

```
FONT
────────────────────────────────────

> JetBrains

  JetBrains Mono
  JetBrains Mono NL
  JetBrainsMono Nerd Font
  JetBrainsMono Nerd Font Mono

────────────────────────────────────
↑↓ navigate   ↵ select   esc cancel
```

The font commands and picker land with the font manager v2 and config work (M4, TASK-39, TASK-40).
Full fallback, emoji and Nerd Font symbol coverage also land there: v0.1 renders what font
manager v1 can cover, and a glyph it cannot resolve is a known v0.1 gap, not a v0.1 promise.

---

## 9. The Scratchpad

The scratchpad is a first-class workspace primitive, not a temporary popup.

```
Workspace
├── Tabs            Terminal │ Terminal │ Agent View
├── Scratchpad      persistent PTY, local or remote, hidden │ 50% │ 90%
├── Agent Manager
├── backlog.md
└── Workspace Configuration
```

### Lifecycle

```
create workspace → establish ExecutionContext → create scratchpad PTY → start shell
                  → scratchpad remains hidden, running

shortcut          → show scratchpad (same PTY, same state)
shortcut / Escape → hide scratchpad (PTY KEEPS RUNNING)
close workspace   → terminate the scratchpad (or reattach it, once workspace restore exists)
```

`vim notes.md`, hide the scratchpad, work for an hour, hit the shortcut again: you are exactly
where you left off. There is an explicit **Scratchpad → Restart Session** command for when a clean
shell is wanted.

### Two presentation modes

One scratchpad, two sizes — not two scratchpads:

| Keybinding (default, configurable) | Result |
|---|---|
| `Ctrl/Cmd` + `` ` `` | 50% scratchpad docked at the bottom; good for quick commands, notes, git, checking on an agent run |
| `Ctrl/Cmd` + `Shift` + `` ` `` | 90% scratchpad; effectively a temporary full-screen terminal for Vim, Lazygit, btop, notebooks/TUIs, database clients |

These bindings must be rebindable, because these combinations inevitably collide with something
on one of the three platforms; v0.1 ships the per-platform defaults and the rebinding surface
arrives with the config system (TASK-37).

### Remote inheritance

The scratchpad does **not** run `ssh server`. It spawns inside the workspace's ExecutionContext,
ideally starting near the same working directory as the session that invoked it, so an SSH
workspace's scratchpad looks and behaves like its tabs. Remote scratchpads and cwd inheritance
land with SSH (M5, TASK-45); in v0.1 the ExecutionContext is local-only.

### Agent workflow

Watch Claude Code work, hit the 50% scratchpad, run `git diff` or `zig build test` *without
disturbing the agent's terminal*, hide it, and the agent is still there. This is the reason the
scratchpad exists, and the reason agents may never own it (P9).

---

## 10. Testing and the agent development loop

The test strategy is designed in from the start, not bolted on later. Conduit is a custom-rendered
native app with no mature cross-platform accessibility-driven test framework, so Conduit provides
its own.

### The Conduit Test Pyramid

```
              ┌───────────────────────┐
              │    Agent exploratory  │
              │        tests          │
              └───────────────────────┘
         ┌───────────────────────────────┐
         │      E2E UI / Test Driver     │
         └───────────────────────────────┘
     ┌────────────────────────────────────┐
     │        Zig integration tests       │
     └────────────────────────────────────┘
┌──────────────────────────────────────────┐
│              Zig unit tests              │
└──────────────────────────────────────────┘
```

| Level | Covers | Milestone |
|---|---|---|
| Unit | Parsers, state machines, layout maths, key encoding, agent adapters | M0+ |
| Integration | Real PTYs and processes; later: SSH against a local sshd container, file watching | M1+ |
| E2E | The real app driven through the test driver, headless | M2+ |
| Exploratory | An agent driving the app with `conduit-test` or its MCP server, deciding what to try next | M2 |

Config parsing (M4), agent adapters (M6) and the SSH integration tests (M5) only enter this table
when those milestones do. v0.1 ships the unit, PTY integration and E2E levels.

### The test driver

A small automation API exposed **by Conduit itself** in development and test builds. It never
bypasses the UI:

Transport: JSON-RPC over a Unix domain socket, or a Windows named pipe. Local only.

```
click("workspace.infrastructure")
    → resolve element in the semantic tree → screen coordinates
    → the same mouse event a human click generates

key("CTRL+SHIFT+P")   type("New SSH Connection")   key("ENTER")
    → the real input system, the same path a human takes
```

Driver methods: `inspect`, `click`, `ctrl_click`, `double_click`, `drag`, `key`, `type`, `scroll`,
`terminal_text`, `wait_for`, `get_logs`, `quit`. Assertions are written by the caller from those
results, so there is no driver-level `assert`.

`inspect` returns the semantic tree — window, workspaces, tabs with their state, scratchpad
visibility and size, palette visibility — plus role, id and bounds per element, so an agent never
needs computer vision to find things. `click` reuses the same hit testing the mouse uses, so
`ctrl_click("link:https://ziglang.org")` works without hardcoded pixels.

Exposed twice, so Claude Code, Codex and Pi share one interface:

```
conduit-test launch | inspect | click <id> | key "CTRL+SHIFT+P" | type "…"
           | screenshot | terminal-text | wait-for | logs | quit

conduit_test.launch | .inspect | .click | .ctrl_click | .key | .type | .scroll
                    | .screenshot | .terminal_text | .wait_for | .get_logs | .quit
```

**Screenshots are the second half.** Semantic assertions prove the right elements exist; they do
not prove the terminal looks right. `screenshot()` catches broken fonts, clipping, wrong pane
sizing, bad colours, overlapping text, missing glyphs, DPI problems, palette placement, scratchpad
sizing and sidebar problems. Any visual claim is verified by looking at a screenshot. Artifacts are
written to a run-scoped directory, e.g. `/tmp/conduit-test/run-182/screenshot.png`, so runs never
overwrite each other.

### Example: testing the scratchpad

```
launch()
key("CTRL+`")            inspect → scratchpad: visible, size 50%
type("echo CONDUIT_TEST"); key("ENTER")
terminal_text("scratchpad") → "$ echo CONDUIT_TEST" / "CONDUIT_TEST"
key("CTRL+`")            hide
key("CTRL+SHIFT+`")     inspect → scratchpad: visible, size 90%
terminal_text("scratchpad") → "CONDUIT_TEST" still there
```

Persistence, keyboard input, rendering and real PTY behaviour are all exercised — not a Zig class
in isolation.

### Determinism rules

No sleeps: `wait_for` takes a condition and a timeout. Fixed window size and scale, isolated config
and state directories, no dependence on the user's shell config, fonts beyond the bundled/test
fonts, no network, no dependence on test order. Tests never touch the real user's config, state,
SSH keys or a running Conduit instance. An external OS-level automation tool may exist as a small
black-box smoke layer, but the driver, the semantic tree, screenshots and real input injection are
the primary test system.

### The agent development loop

```
zig build test  →  zig build  →  launch Conduit  →  inspect UI
                                             →  interact like a user
                                             →  screenshot
                                             →  assert expected state
                                             ├─ FAIL → read logs and the semantic tree dump
                                             │         modify code, retry
                                             └─ PASS
```

On failure the agent reads the logs and the semantic tree dump before changing code — not the other
way round. Documented as TASK-26.

---

## 11. Safety invariants

Conduit handles shells, SSH credentials, clipboard contents and agent prompts. Treat all of them as
sensitive.

- Never log, persist or transmit terminal contents, clipboard data, credentials or prompts above
  debug level.
- The test driver and control API are local-only, disabled in release builds unless explicitly
  enabled, and never reachable over the network.
- Text from terminals, transcripts, backlog files and agent output is **untrusted data**: it must
  not be able to trigger actions — opening files, running commands, answering permission prompts —
  without an explicit user gesture.
- Malformed external input must never crash the app.

---

## 12. Open questions

Deferred on purpose. Each has a backlog spike; the answer goes in a decision record, not in
guesswork.

| Question | Spike |
|---|---|
| Which windowing and GPU stack, and how does it attach to libghostty's renderer? | TASK-3 |
| What exactly is the libghostty integration boundary at the pinned Zig version? | TASK-2 |
| SSH transport and multiplexing: how do tabs, panes and the scratchpad share one connection? | TASK-42 |
| What integration surfaces do Claude Code, Codex and Pi actually expose (state, prompts, permission prompts, events)? | TASK-51 |
| What do harness adapters do when a harness offers no structured surface? | TASK-51 |

---

## 13. Glossary

**Workspace**
The top-level container and unit of work: a named environment with an ExecutionContext, a working
directory, tabs and panes, exactly one scratchpad, agents, backlog state, and its own layout,
theme and session metadata. Created, switched and closed by the user; not persisted in v0.1.

**ExecutionContext**
The environment a workspace runs in, and the only way anything is spawned: `Local`, `SSH` or
`WSL`. It owns the connection and the remote environment, and it spawns processes. The working
directory is *not* part of it: the workspace owns one, shell integration tracks it per session, and
new tabs, panes and the scratchpad inherit the tracked value. Every session, the scratchpad and
every agent adapter spawn through their workspace's ExecutionContext, so nothing may assume the
local machine.

**Session**
One live terminal: a PTY plus its terminal state (grid, scrollback, selection, cursor), belonging
to one ExecutionContext. A session outlives its view — hiding a tab, a pane or the scratchpad
never stops it. Tabs and panes hold sessions; so does the scratchpad, which is why hiding the
scratchpad keeps `vim` alive.

**Scratchpad**
The one persistent, human-owned popup terminal per workspace, started when the workspace opens and
kept running while hidden. Presented in two sizes (50% and 90%), inherits the workspace's
ExecutionContext and working directory, and is terminated only when the workspace closes (or
re-attached once workspace restore exists). Agents and the control API may never own or target it.

**Agent**
A coding agent managed by Conduit — Claude Code, Codex or Pi — together with the state Conduit
tracks for it (status, notifications, prompt, transcript, subagents) and the one or more sessions
and task PTYs it owns. Agents are exposed as structured, clickable views, never as raw ANSI alone.

**Adapter**
The only thing in Conduit that knows about a specific harness. It implements the common adapter
interface — spawn, observe state, read and write the prompt where supported, surface notifications
and permission requests, and expose the transcript as structured elements. Harness-specific
parsing and behaviour live inside the adapter and nowhere else (P11). One adapter per harness:
Claude Code, Codex, Pi.

**Harness**
The external coding-agent CLI that Conduit drives (Claude Code, Codex, Pi). A harness is reached
only through an adapter implementing the common adapter interface; harness-specific behaviour —
its state format, prompt editing, permission prompts, notifications — lives inside that adapter and
nowhere else.

---

## 14. Where to look next

| Question | Source |
|---|---|
| What should the product do? | this file |
| What should I work on, and what counts as done? | `backlog/` tasks and their acceptance criteria |
| Why was a technical choice made? | backlog decision records |
| How is the code organised, and what are the coding rules? | `AGENTS.md`, then `docs/architecture.md` |
| What must an agent keep in sync when behaviour changes? | `AGENTS.md` and `CLAUDE.md` |
| How did we get here? | `conversation.md` |
