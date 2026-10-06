
I’d like to build a windows, Linux and Mac terminal emulator. I’d like to use libghostty and Zig. It should support wsl and powershell, but that’s a secondary. Your terminal and ssh sessions should be seem less. It should have left hand tabs and a command pallet that pops up like Mac spotlight. Commands for new tabs, remote connections, settings, splitting panes. Kinda like tmux, but easy to use. The main feature is Claude code cli, codex cli and pi cli support. Notifications support for those harnesses, agent views and management/interaction, id like to be able to see agent prompts and edit them, integration with backlog.md for planning. Maybe give a way for the emulator can connect to the supported harnesses and spawn tabs/panes for views of backlog.md and agent interaction/management. Everything should have a terminal look and feel. I’d also like support for popular Linux color schemes. Let’s plan this out.

Worked for 8s
Can we add a scratchpad function also? It could basically be a popup terminal. I’d like 2 different sizes that popup on 2 separate key combos. On see fills about 50% of the screen and the second pops up about 90% of the screen. The scratchpad should popup as an ssh session if it’s invoked in an ssh connoted session. The scratchpad should be persistent and stay running even if it’s in the background. Say I have vim or a notebook application running there. There should be 1 scratchpad per workspace. Maybe the scratchpad connects or starts as a second terminal in the background whenever when a new workspace is opened.
Yes. I’d make the Scratchpad a first-class workspace primitive, not a temporary popup.

Scratchpad model
Every workspace automatically owns one persistent Scratchpad session:

Workspace
├── Tabs
│   ├── Terminal
│   ├── Terminal
│   └── Agent View
│
├── Scratchpad ────────────────┐
│   ├── Persistent PTY         │
│   ├── Local OR Remote        │
│   └── Hidden / 50% / 90%     │
│                              │
├── Agent Manager              │
├── backlog.md                 │
└── Workspace Configuration    │
When a workspace opens, its scratchpad PTY starts immediately in the background. Hiding the scratchpad never terminates the PTY.

So you could open Vim:

vim notes.md
hide the scratchpad, work for an hour, hit the shortcut again, and you're exactly where you left it.

Two presentation modes
I'd give the same scratchpad two presentation sizes rather than creating two scratchpads.

For example:

Cmd/Ctrl + `          → 50% Scratchpad
Cmd/Ctrl + Shift + `  → 90% Scratchpad
We should make the bindings configurable because those combinations will inevitably conflict with something on one platform.

50% mode

┌──────────────────────────────────────────────┐
│ Main workspace                               │
│                                              │
│                                              │
├──────────────────────────────────────────────┤
│ SCRATCHPAD — prod-server                     │
│                                              │
│ $ vim notes.md                               │
│                                              │
└──────────────────────────────────────────────┘
Good for quick commands, notes, Git operations, checking something during an agent run, etc.

90% mode essentially becomes a temporary full-screen terminal:

┌──────────────────────────────────────────────┐
│ SCRATCHPAD — prod-server              [90%]  │
│                                              │
│                                              │
│                   VIM                        │
│                                              │
│                                              │
│                                              │
└──────────────────────────────────────────────┘
This would be excellent for Vim, Lazygit, btop, notebooks/TUIs, database clients, or anything you want temporarily front-and-center.

SSH inheritance
Your SSH idea is particularly important.

I wouldn't implement it as:

scratchpad → run `ssh server`
Instead, the workspace should understand its execution context.

WorkspaceContext
    │
    ├── Local
    │    └── Shell
    │
    └── SSH
         ├── host
         ├── user
         ├── environment
         ├── working directory
         └── connection/session manager
Suppose you're working on:

SSH: dev@build-server
/home/dev/project
Invoking Scratchpad should give you another terminal on build-server, ideally starting around the same working directory.

Main terminal
dev@build-server:/home/dev/project$

        ↓ scratchpad

Scratchpad
dev@build-server:/home/dev/project$
That makes local and remote workspaces feel essentially identical.

We can go further later and maintain an underlying SSH connection using multiplexing so opening tabs, panes, and the scratchpad doesn't require a completely new SSH handshake every time.

This suggests a really useful concept: Workspace Sessions
I think this should become one of the core architectural concepts.

A workspace isn't merely a collection of windows.

Workspace
│
├── Connection Context
│   ├── Local
│   ├── SSH
│   └── WSL
│
├── Working Directory
│
├── Terminals
│   ├── Tab 1
│   ├── Tab 2
│   └── Split panes
│
├── Scratchpad
│   └── Persistent PTY
│
├── Agents
│   ├── Claude Code
│   ├── Codex
│   └── Pi
│
├── Planning
│   └── backlog.md
│
└── State
    ├── Layout
    ├── Theme
    ├── Environment
    └── Session metadata
Then everything inherits the workspace context.

That's powerful because an SSH workspace becomes almost indistinguishable from a local workspace.

If you're SSH'd into a development server:

New Tab
New Pane
Scratchpad
Claude Code
Codex
Pi
Backlog
all operate against that remote environment.

Scratchpad lifecycle
I'd define it very specifically:

Workspace created

create workspace
      ↓
establish execution context
      ↓
create scratchpad PTY
      ↓
start shell
      ↓
scratchpad remains hidden
Then:

shortcut
   ↓
show scratchpad
   ↓
same PTY
and:

shortcut / Escape
   ↓
hide scratchpad
   ↓
PTY KEEPS RUNNING
Closing the workspace is what finally triggers scratchpad termination—or potentially persistence/reconnection if we eventually implement workspace restoration.

There should also be an explicit:

Scratchpad → Restart Session
command if someone wants a clean shell.

Where this starts getting interesting
I think the Scratchpad can become a major part of the agent workflow.

Imagine you're watching Claude Code work:

┌─ Workspace: terminal-project ─────────────────────┐
│                                                  │
│ Claude Code                                      │
│                                                  │
│ Editing src/terminal.zig                         │
│ Running tests...                                 │
│                                                  │
└──────────────────────────────────────────────────┘
Hit the 50% Scratchpad:

┌─ Claude Code ────────────────────────────────────┐
│ Running tests...                                 │
├──────────────────────────────────────────────────┤
│ SCRATCHPAD                                       │
│                                                  │
│ $ git diff                                       │
│ $ zig build test                                 │
│                                                  │
└──────────────────────────────────────────────────┘
You inspect what the agent is doing without disturbing its terminal.

Then hide it and Claude remains visible.

That's considerably nicer than opening another tab every time you want to poke around.

I'd add one more rule
Agents should never own the Scratchpad.

Claude/Codex/Pi can spawn their own managed terminals:

Agent
 ├── Agent PTY
 ├── Task PTY
 └── Subagent PTYs
But Scratchpad belongs to you.

That gives us a clean separation:

Human terminal space
├── Tabs
├── Panes
└── Scratchpad

Agent terminal space
├── Claude
├── Codex
├── Pi
└── Subagents
The UI can expose both, but an agent shouldn't accidentally commandeer the terminal where you have Vim open.

Updated product concept
We're starting to get a fairly distinctive product:

A cross-platform terminal workspace built around persistent local/SSH environments and AI coding agents.

The major pieces now look like:

                    TERMINAL APP
                         │
        ┌────────────────┼────────────────┐
        │                │                │
   Workspaces        Command Palette   Notifications
        │
 ┌──────┼───────────────┐
 │      │       │       │
Tabs   Panes  Scratchpad Agents
 │      │       │       │
PTY    PTY     PTY      Agent Manager
 │      │       │       │
 └──────┴───────┴───────┘
             │
      Execution Context
             │
     ┌───────┼────────┐
     │       │        │
   Local    SSH      WSL
                     │
              Shell / Processes
And then the agent-management layer sits above this and handles Claude Code, Codex, Pi, prompts, subagents, notifications, and backlog.md.

I think our next design step should be to define the workspace + process/session architecture in Zig, because getting that abstraction right will determine whether SSH, Scratchpad, panes, and agents feel seamless or become four unrelated implementations.

We also need first class mouse support. Including ctrl clicking links, copy paste and navigation in agent views, switching tabs and workspaces and everything. I don’t want buttons everywhere, it should still feel like a cli, but elements should be clickable. We also need first class font support to go along with it.
Absolutely. I’d make keyboard and mouse equal first-class inputs, while keeping the visual language unmistakably terminal-first. No conventional desktop-app chrome unless it’s genuinely necessary.

Interaction model
The rule should be: if something looks actionable, it is actionable—but it doesn’t need to look like a button.

 DEVBOX / ~/src/semantscript                         ● 3 agents

  1  shell
  2  codex: parser-refactor
  3  claude: tests
  4  logs

────────────────────────────────────────────────────────────

❯ codex

  Working on src/parser.zig

  ✓ Updated tokenizer
  ✓ Added tests
  → Running zig build test

  Modified:
    src/parser.zig
    src/tokenizer.zig
    tests/parser_test.zig

────────────────────────────────────────────────────────────
DEVBOX, every tab, agent name, filename, status item, URL, error location, etc. can have a hit target without borders, raised controls, or GUI-looking buttons.

Mouse hover can subtly underline/highlight actionable terminal cells.

Mouse behavior
I'd define consistent semantics across normal terminals and our custom agent views:

Click — select tab/workspace/agent/item, position cursor where supported.
Ctrl+Click on Windows/Linux and Cmd+Click on macOS — open URLs; clicking src/foo.zig:142 opens that location using the configured editor action.
Drag — normal terminal text selection.
Double/triple click — word/line selection.
Right click — configurable, defaulting to a minimal terminal-style context menu.
Middle click — Unix-style paste where appropriate/configured.
Wheel/trackpad — terminal history or view scrolling.
Drag pane divider — resize splits.
Click workspace/tab labels — switch immediately.
Drag tabs — reorder/move between panes if we decide that's useful.
Clipboard should be native: Ctrl/Cmd+C/V, while preserving terminal conventions such as Ctrl+Shift+C/V where appropriate. We need careful handling of Ctrl+C: if terminal text is selected, copy can be a separate binding; otherwise it must remain SIGINT. We should never unexpectedly steal terminal control sequences.

Agent views should be richer than terminals
This is where mouse support becomes especially valuable.

An agent response might visually remain CLI-like:

CLAUDE  feature/auth
────────────────────────────────────────────────────────

● Investigating authentication failure

  I'll inspect the middleware.

  Read   src/auth/middleware.ts
  Read   src/auth/session.ts
  Edit   src/auth/session.ts:87

  ┌ prompt ──────────────────────────────────────────
  │ Fix session expiration without changing the
  │ public authentication API.
  └──────────────────────────────────────────────────

  Waiting for permission:
  › Run integration tests
    Allow once   Always allow   Reject
But underneath, those are structured elements.

Click src/auth/session.ts:87 → open/navigate.

Click prompt → edit the agent's current prompt/instructions where the harness supports it.

Click an agent → focus it.

Click a permission choice → interact with the harness.

Click a task in backlog.md → inspect it or associate an agent with it.

The visual presentation remains text. The interaction model doesn't have to be text-only.

Font system should also be first-class
I wouldn't make font handling just:

font = "JetBrains Mono"
font_size = 14
We should build an actual FontManager.

FontManager
├── Discovery
│   ├── macOS fonts
│   ├── Windows fonts
│   ├── Linux/fontconfig
│   └── bundled fallback
│
├── Shaping
├── Glyph atlas/cache
├── Fallback chains
├── Emoji
├── Nerd Font symbols
├── Ligatures
└── DPI / scaling
And support separate faces:

font.family       = "JetBrains Mono"
font.bold         = "JetBrains Mono Bold"
font.italic       = "JetBrains Mono Italic"
font.bold_italic  = "JetBrains Mono Bold Italic"

font.size         = 14
font.ligatures    = true
font.nerd_symbols = true
Unicode and fallback are important. A missing glyph shouldn't turn the terminal into boxes because someone's prompt contains Japanese, an emoji, Powerline symbols, or mathematical characters.

Nerd Fonts / Powerline
I'd consider this mandatory for the audience we're targeting.

Things like:

 main  ~/src/project 
need to work flawlessly with Starship, Powerlevel10k, Neovim, tmux applications, Claude/Codex output, etc.

We shouldn't force users to use a Nerd Font, though. A fallback symbol font can fill missing terminal glyphs where licensing/distribution permits.

Font picker — still terminal-like
Even Settings doesn't need to become a conventional GUI.

Command Palette:

> font

  Font: Change Family
  Font: Increase Size
  Font: Decrease Size
  Font: Reset Size
  Font: Toggle Ligatures
  Font: Configure Fallbacks
Selecting family:

FONT
────────────────────────────────────

> JetBrains

  JetBrains Mono
  JetBrains Mono NL
  JetBrainsMono Nerd Font
  JetBrainsMono Nerd Font Mono

────────────────────────────────────
↑↓ navigate   ↵ select   esc cancel
And everything there is also clickable.

That duality should be a fundamental design principle:

Anything you can do with the mouse should have a keyboard path, and nearly anything presented as an interactive terminal element should be clickable.

This gives us four UI primitives
Rather than building dozens of widgets, I'd keep the custom UI toolkit deliberately tiny:

Text
InteractiveText
Surface
Input
From those we construct things such as:

WorkspaceList
TabList
Terminal
AgentView
CommandPalette
Scratchpad
BacklogView
PromptEditor
Notification
SettingsView
For example, the workspace sidebar could simply be:

WORKSPACES

● semantscript
    shell
    claude  ●
    codex   ◐

○ infrastructure
    prod
    staging

○ personal
No [OPEN], [CLOSE], hamburger menus, cards, giant icons, etc.

You click infrastructure, or keyboard-focus it and hit Enter.

One architectural decision I'd make now
We should not treat the terminal renderer as the application's UI renderer.

Instead:

                    Zig Application
                          │
                 ┌────────┴─────────┐
                 │                  │
            UI Renderer       Terminal Engine
                 │                  │
        ┌────────┼────────┐     libghostty
        │        │        │          │
     Sidebar  Palette  Agent      VT / Terminal
       UI       UI      UI
        │        │        │
        └────────┴────────┘
                 │
           Shared GPU Surface
The UI renderer deliberately looks like a terminal, but it understands structured objects, hit-testing, selection, hover states, Markdown, filenames, prompts, agents, backlog items, etc.

The actual terminal surface remains a real terminal.

That distinction gives us something extremely important: Agent Views can look exactly like terminal output without being dumb streams of ANSI text.

Then clicking a Claude file reference isn't us regex-hacking coordinates out of terminal output. It's an actual FileReference object with a mouse hitbox and action.

This also opens the door later for accessibility, proper text selection, search, command-palette navigation, richer notifications, and potentially agent APIs without compromising the CLI aesthetic.

At this point I think we've defined enough product behavior that the next useful artifact is an actual v0.1 architecture/spec: Zig modules, renderer/windowing choice, libghostty boundary, PTY abstraction for Windows/macOS/Linux, SSH session architecture, workspace persistence, scratchpad lifecycle, font/rendering stack, mouse/input system, and the Claude/Codex/Pi adapter interface. That will tell us what we can build directly versus where we need platform-specific implementations.

Final thing before we start. I need a name. Something unique
Because this is more than a terminal—it's a persistent workspace for shells, SSH, agents, scratchpads, and planning—I’d avoid names containing term, shell, or AI. They make the product sound smaller than it is.

Here are the names I think fit best:

Name	Why it fits
Veyra	Short, technical, brandable; feels like a serious developer tool.
Muxen	Subtle nod to multiplexing/tmux without being derivative.
Relay	Local ↔ SSH ↔ agents; everything flows through it.
Locus	Your workspace becomes the place where all development happens.
Tether	Connects shells, remote machines, agents, and tasks.
Conduit	The interface between you, machines, and coding agents.
Glyph	Strong terminal/font connection; short and developer-oriented.
Vanta	Dark/terminal aesthetic and memorable, though existing uses would need checking.
Riven	Splits/panes/workspaces; strong CLI-tool feel.
Nexus	Conceptually excellent—everything connected—but likely far too crowded as a brand.
Mux	Almost perfect conceptually, but probably too generic.
Arc	Short and polished, but similarly crowded.
My favorites
Veyra is probably my favorite as a product name.

VEYRA

Workspace: semantscript
─────────────────────────────────────────
  shell
  claude ●
  codex
  backlog.md

❯
It doesn't constrain what the application eventually becomes.

Muxen is my favorite if you want the name to have a hidden technical meaning:

MUX — multiplex terminals, agents, connections, and workspaces.

MUXEN

devbox
├─ shell
├─ ssh:prod
├─ claude ●
├─ codex
└─ backlog.md
And Conduit probably describes the philosophy best:

One conduit between you, your machines, and your agents.

Before settling on one, though, we should actually check GitHub, package registries, domains, trademarks, and existing developer products. A name that sounds unique isn't necessarily commercially usable.

If you want something really distinctive, I can also generate 30–50 invented names in the Veyra / Kubernetes / Vercel / Zig / Neovim style and then web-search the strongest 5–10 for collisions.

I like Conduit
Conduit fits the concept very well. It captures the idea that the application is the conduit between you → terminals → remote systems → coding agents → work without tying the name specifically to AI or terminals.

It also gives us clean terminology inside the product:

CONDUIT

Workspace
├── Terminals
├── Scratchpad
├── Connections
│   ├── Local
│   ├── SSH
│   └── WSL
├── Agents
│   ├── Claude Code
│   ├── Codex
│   └── Pi
└── backlog.md
And the CLI could eventually feel natural:

conduit

conduit .
conduit ssh devbox
conduit workspace open semantscript
conduit agent codex
conduit agent claude

I'd use Conduit as the working project name and move into the architecture/design phase next. The first thing I'd define is a CONDUIT.md product specification, followed by the Zig module architecture and a realistic v0.1 milestone so we don't try to build terminal emulation, SSH, agent orchestration, and a UI framework simultaneously.

I was thinking. We need an effective way to test as we go along. Using the standard Zig testing framework is great and we should use it. But I’d like the agents to actually be able to run the application, click and navigate with the keyboard, run as if a user was testing. We need to find a tool that can help us do this. That way our agent loops are effective.
Yes. For Conduit, I think this is important enough that we should design agent-driven end-to-end testing into the application from the beginning, rather than bolt it on later.

The difficulty is that Conduit will be a custom-rendered native application. Traditional web testing tools won't help much, and there isn't one mature accessibility-driven framework that cleanly covers Windows + macOS + Linux. Appium, for example, has an official Mac2 driver and Windows driver, but its Windows backend still depends on Microsoft's WinAppDriver, whose server hasn't been maintained since 2022. 
 Cross-platform tools such as PyAutoGUI and SikuliX can drive real mouse/keyboard input, but they're primarily coordinate/image based, which tends to be more fragile. 

So I think there's a better solution for Conduit specifically.

Build a Conduit Test Driver
We expose a small automation API from Conduit itself in development/test builds.

Conceptually:

Claude / Codex
      │
      │ MCP / CLI / JSON-RPC
      ▼
┌─────────────────────────┐
│  Conduit Test Driver    │
├─────────────────────────┤
│ launch                  │
│ inspect                 │
│ click                   │
│ type                    │
│ key                     │
│ screenshot              │
│ wait                    │
│ assert                  │
└───────────┬─────────────┘
            │
            ▼
     REAL Conduit app
            │
     ┌──────┴──────┐
     │ Input system │
     │ UI renderer  │
     │ PTYs         │
     │ Agents       │
     │ Workspaces   │
     └──────────────┘
The critical distinction is that this doesn't bypass the UI.

If the agent says:

click("workspace.infrastructure")
Conduit resolves that element to screen coordinates and generates the same mouse event a human click would generate.

Likewise:

key("CTRL+SHIFT+P")
type("New SSH Connection")
key("ENTER")
travels through the real input system.

That lets agents actually test the application.

Give the agent an accessibility-style UI tree
Remember our earlier idea that Conduit's terminal-looking UI should actually contain structured elements?

That becomes incredibly useful here.

An agent could ask:

conduit-test inspect
and receive something like:

window:
  title: Conduit

workspace:
  id: semantscript
  selected: true

tabs:
  - id: shell
    title: shell
    selected: true

  - id: claude-1
    title: "claude: parser"
    selected: false
    status: working

scratchpad:
  visible: false

command_palette:
  visible: false

The agent doesn't need computer vision to figure out where everything is.

It understands Conduit's semantic UI.

But it can still take screenshots whenever visual verification matters.

Agent test loop
This is the workflow I want:

Codex
  │
  ├─ modifies code
  │
  ▼
zig build test
  │
  ✓
  │
  ▼
zig build
  │
  ✓
  │
  ▼
launch Conduit
  │
  ▼
inspect UI
  │
  ▼
interact like user
  │
  ▼
take screenshot
  │
  ▼
assert expected state
  │
  ├─ FAIL → inspect logs/state
  │          modify code
  │          retry
  │
  └─ PASS
That is a very powerful coding-agent loop.

Example: testing the Scratchpad
Suppose an agent implements our Scratchpad feature.

The agent could execute:

launch()
Then:

key("CTRL+`")
Inspect:

scratchpad:
  visible: true
  size: 50%
Then type:

type("echo CONDUIT_TEST")
key("ENTER")
Read terminal state:

terminal_text("scratchpad")
Expected:

$ echo CONDUIT_TEST
CONDUIT_TEST
Hide it:

key("CTRL+`")
Open 90% mode:

key("CTRL+SHIFT+`")
Assert:

scratchpad:
  visible: true
  size: 90%
And verify:

CONDUIT_TEST
is still there.

We've now tested persistence + keyboard input + rendering + actual PTY behavior, not merely the Scratchpad Zig class.

Mouse testing becomes especially good
Because Conduit already needs hit testing for first-class mouse support, the test driver can reuse it.

For example:

inspect
might expose:

- role: workspace
  id: workspace.dev
  bounds: [0, 84, 210, 28]

- role: tab
  id: tab.shell
  bounds: [0, 142, 210, 28]

- role: link
  text: https://ziglang.org
  bounds: [422, 517, 143, 18]

Then:

click("workspace.dev")
really means:

mouse_move(center(workspace.dev.bounds))
mouse_down(left)
mouse_up(left)
Therefore we're testing the actual mouse path.

We can even test:

ctrl_click("link:https://ziglang.org")
without hardcoding pixel coordinates.

Screenshots are the second half
Semantic testing tells us:

The correct elements exist.

It doesn't tell us:

The terminal actually looks correct.

So:

screenshot()
should be fundamental.

An agent can inspect:

/tmp/conduit-test/run-182/screenshot.png
That catches:

broken fonts
clipping
incorrect pane sizing
bad colors
overlapping text
missing glyphs
DPI issues
command palette placement
scratchpad sizing
sidebar problems
This is particularly important for a GPU-rendered terminal.

Three levels of testing
I'd establish this hierarchy immediately:

                 Conduit Test Pyramid

              ┌──────────────────┐
              │ Agent Exploratory│
              │      Tests       │
              └──────────────────┘

           ┌────────────────────────┐
           │   E2E UI / Test Driver │
           └────────────────────────┘

       ┌────────────────────────────────┐
       │       Zig Integration Tests    │
       └────────────────────────────────┘

   ┌────────────────────────────────────────┐
   │             Zig Unit Tests             │
   └────────────────────────────────────────┘
Unit tests cover parsers, state machines, workspace logic, configuration, agent adapters, etc.

Integration tests use real PTYs/processes and test things like session persistence and SSH behavior.

E2E tests launch Conduit and interact with the actual application.

And then agent exploratory tests allow Claude/Codex to inspect the application and decide what to try next.

We should expose it as both CLI and MCP
This could be especially nice.

CLI:

conduit-test launch
conduit-test inspect
conduit-test click workspace.dev
conduit-test key "CTRL+SHIFT+P"
conduit-test type "New Workspace"
conduit-test screenshot

And an MCP server:

conduit_test.launch
conduit_test.inspect
conduit_test.click
conduit_test.key
conduit_test.type
conduit_test.screenshot
conduit_test.terminal_text
conduit_test.wait_for
Then Claude Code, Codex, and Pi can all use the same testing interface.

That aligns extremely well with Conduit's entire architecture.

One important additional benefit
We would essentially be forced to maintain a good semantic/accessibility tree for Conduit.

That's good engineering anyway.

Instead of drawing:

"Claude"
at (32, 164), internally we'd know:

InteractiveText{
    .id = "agent.claude.parser",
    .role = .agent,
    .label = "Claude",
    .bounds = ...,
    .action = .focus_agent,
}
The renderer uses it.

The mouse system uses it.

Accessibility uses it.

The test system uses it.

That's much cleaner than maintaining four separate representations.

So I wouldn't choose PyAutoGUI/Appium/SikuliX as Conduit's primary test framework. I'd keep an external OS-level automation tool as a small black-box smoke-test layer, but make Conduit Test Driver + semantic tree + screenshots + real input injection the main agent testing system. That gives us deterministic tests while still exercising the real application—and it makes the agent development loop we're envisioning genuinely practical.