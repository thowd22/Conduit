# Conduit — Agent Guide

Conduit is a cross-platform (Linux, macOS, Windows) terminal workspace written in Zig on top of
libghostty. It combines tabs, split panes, a command palette and a persistent scratchpad with
first-class support for coding-agent CLIs (Claude Code, Codex, Pi) and Backlog.md planning.
Everything looks and feels like a terminal; mouse and keyboard are equal inputs.

Read this file fully before working. It applies to every agent and every harness.

## Current state

The terminal implementation is present: `zig build run` opens a window with the user's shell over
a PTY, rendered by Conduit's grid renderer, with keyboard, mouse, selection, clipboard, scrollback
and shell integration (cwd and prompt marks). Its thirty-three Linux headless self-checks pass through
their deterministic Linux drivers: `conduit --grid-test`, `--self-test`, `--scroll-test`,
`--mouse-test`, `--clipboard-test`, `--ui-test`, `--ime-test`, `--sidebar-test`, `--tabs-test`,
`--panes-test`, `--palette-test`, `--scratchpad-test`, `--workspaces-test`, `--links-test`,
`--search-test`, `--menu-test`, `--config-test`, `--theme-test`, `--font-test`, `--settings-test`, `--git-test`, `--agent-test`, `--ssh-test`, `--agent-view-test`, `--agent-manager-test`, `--backlog-test`, `--control-test`, `--restore-test`, `--a11y-test`, `--agent-prompts-test`, `--profiles-test`, `--editor-test` and `--driver-test` (each exits non-zero on failure). The real-window checks run
under `xvfb-run -a`; the clipboard check deliberately uses SDL's offscreen driver.

An evidence audit reopened TASK-5, TASK-10, TASK-11, TASK-12, TASK-15, TASK-16 and TASK-17, so M0
and M1 are not currently complete. The Linux repairs have completed TASK-10, TASK-11 and TASK-17:
the font manager owns four style faces, the grid renderer consumes bold/italic combinations and
conceals all foreground ink, and `Session` owns the terminal/PTY while exposing cwd and prompt
marks. TASK-12 is complete: selected and underlined inline preedit renders at the terminal cursor,
the native candidate area follows the grapheme caret, committed UTF-8 reaches the child exactly
once, and the deterministic Linux `--ime-test` passes. The remaining criteria need external
platform evidence: TASK-5's workflow has never run; TASK-15 needs macOS; and TASK-16 needs Windows.
macOS font discovery is now acceptance in TASK-48 rather than TASK-10. TASK-18 is complete: all
four UI primitives and the deterministic Linux `--ui-test` pass, and `Input` paste normalizes
contiguous CR/LF/tab/U+2028/U+2029 separator runs to one ASCII space while atomically rejecting
other controls and malformed UTF-8. TASK-19 is complete: the fixed-capacity semantic `Tree` is the
single source for all four primitives' paint payloads, queries, JSON, hit testing, hover, focus,
activation and stable IDs. Production IME and the deterministic `--ui-test` `Canvas` derive from
the `Tree`. TASK-20 is complete: named actions dispatch uniformly from keybindings, semantic mouse
activation and palette callers; macOS and Linux/Windows have distinct default clipboard chords;
and stateful binding/UI ownership preserves exact terminal fallback across repeats, releases and
modifier-order changes. Clipboard failures and invalid `Input` paste are non-fatal and atomic. The
TASK-21 test driver is complete: an explicit `--test-driver` flag starts a bounded local JSON-RPC
server over private Unix sockets or protected Windows named pipes, and input requests cross the
real SDL event queue before replying. Read-only terminal text queries target `active` by default
and may explicitly target the permanent `scratchpad`, including while it is hidden; input methods
still route only through the real active presentation and cannot take over the scratchpad. Windows
pipe runtime coverage still requires the Windows CI runner. TASK-22 is complete: hidden runs use
the same real SDL window, GL context and FBO as visible runs; `--width`, `--height` and `--scale`
fix screenshot geometry; and the driver's `screenshot` method forces a current frame, reads it
back on the main thread, then encodes
and exclusively writes a deterministic RGBA8 PNG off-thread. `--test-artifact-dir` selects the
run-scoped output directory, or Conduit generates a unique directory for the run. The Linux
`--driver-test` proves this path under Xvfb; native macOS and Windows rendering remain unverified.
The root build also installs the external `conduit-test` composition-root executable from TASK-23.
Its `launch` command creates a private, isolated run, waits until an `inspect` request proves the
driver is ready, and returns a run id for later commands. Direct commands cover every driver method
and produce agent-friendly plain output or raw JSON-RPC with `--json`. A Linux end-to-end check
launches the app without a display, drives every method from separate client processes, captures a
screenshot and verifies that fake user config/state paths stay untouched. TASK-24 adds a bounded
stdio MCP server at `conduit-test mcp`; its tools mirror every direct CLI method and return
screenshots as viewable PNG image content alongside the private artifact path. It supports current
stateless discovery as well as legacy initialize clients: legacy connections retain the run
selected by `launch`, while current calls name a run explicitly. The checked-in `.mcp.json` defines
the installed executable for compatible project MCP clients. Claude Code can load that entry with
its normal workspace approval; Codex requires
explicit registration because it does not auto-load `.mcp.json`, and Pi requires an MCP extension
or can use the CLI directly. The MCP server is local-only and inherits the CLI's
isolated per-run filesystem boundary; native macOS and Windows runtime behavior has not been
verified. TASK-25 is complete with a checked-in `zig build e2e` composition root. It
launches a fresh isolated app through `conduit-test` for each scenario, reports launch/prompt,
command/output, Input-copy/terminal-paste and terminal-link results individually, and retains a
suite summary plus per-scenario runner log, semantic tree and application log; failed live
scenarios request an additional current screenshot before shutdown. Its twenty-two declarative scenarios
include `terminal-links`, which waits for the stable semantic link id and sends a real
`conduit-test ctrl-click` through the driver and SDL event queue before capturing the frame, and
`terminal-file-reference`, which ctrl-clicks a `path:line` reference and waits for the new tab's
sidebar row and vi's status line in that tab, and `context-menu`, which right-clicks the pane
through `conduit-test right-click` and activates the `search` row. The
checked-in reusable Linux workflow runs
formatting, build, unit/integration tests, the built-in headless checks and these scripted
scenarios, then uploads its private artifact root on failure. GitHub Actions run 37539118525 on
ubuntu-24.04 passed that whole gate, and the two failing runs before it uploaded the failure
artifacts that diagnosed the Sway renderer and IBus fixes. Its Xvfb block pins
`SDL_VIDEODRIVER=x11`, includes `--links-test` and `--search-test`, and rejects any built-in check
whose retained application log does not report the X11 backend. The worked agent loop using
today's CLI and MCP surfaces is documented below. TASK-27 provides the owner beneath the current workspace UI:
`Workspace` copies and owns its name and working directory, owns a type-erased `ExecutionContext`
with the Local implementation, and keeps heap-stable session records under monotonic, non-reused
ids. Each workspace reserves exactly one childless scratchpad session; TASK-32 starts its PTY and
presents it. Human, scratchpad and agent sessions are distinct kinds. The app lends a non-owning
context capability to its spawn worker, retains the initiating session id across that asynchronous
work, then attaches the returned PTY to that session on the owner thread even if selection changed.
Workspace pumping is bounded, two-way and view-independent: the event loop wakes for any attached
PTY, drains output, delivers terminal events synchronously, and preserves terminal replies across
short, zero and failed writes until the child accepts them. Exited PTYs remain serviceable until
their final queued output is drained, then become quiescent;
teardown releases every session before the execution context and reports a PTY signalling failure
only after all owned resources are gone. TASK-28 adds the first workspace shell above that owner:
`Workspace` keeps heap-stable, monotonic records for already-provisioned tabs and their live
non-scratchpad sessions, while the app composes the current workspace and those tabs into a
terminal-styled left sidebar. Product selection is explicit semantic-tree state. The sidebar is a
true inset: showing or resizing it shifts the terminal origin and resizes the terminal grid to the
remaining columns, while the UI overlay retains full-canvas coordinates. Named actions provide
mouse and keyboard tab switching, hide/show, keyboard resizing and divider dragging. The explicit
sidebar-focus chord enters on the active tab while an unbound Tab remains terminal input; the
deterministic Linux `--sidebar-test` exercises those paths through real SDL events. TASK-29
completes the flat tab lifecycle without changing that inset: create snapshots the invoking
session's validated OSC 7 cwd (falling back to the workspace cwd) before the asynchronous context
spawn; rename uses the shared `Input`; switch and stable reorder work by mouse and named keyboard
actions; and closing a live child asks unless a current OSC 133 prompt proves it idle. Background
output prefixes the copied label with `* `, BEL promotes it to `! `, and activation clears either
without conflating terminal attention with TASK-56 agent state. Closing the last tab requests
normal app shutdown so reverse-order teardown releases every session and the scratchpad. The
shipped defaults are Command+T/W, Command+Shift+`[`/`]`, Command+1…9 and Alt+Shift+Up/Down on
macOS; Linux and Windows use Ctrl+Shift+T/W, Ctrl+PageUp/PageDown, Alt+1…9 and
Alt+Shift+Up/Down; F2 renames on all three. TASK-31 supplies the visible command palette over these
actions, TASK-33 owns multiple workspaces, and TASK-56 owns agent state and notifications. TASK-30
is complete: every tab owns a binary pane tree whose leaves each name one workspace-owned session,
with stable pane and divider ids. Right/down
splits inherit the focused pane's tracked cwd, spawn through the workspace `ExecutionContext` and
may nest to arbitrary depth while one-cell dividers and 2x2-cell pane minimums keep the layout
valid. Pane/session creation commits only after validation and allocation, so a refused split
consumes no session, pane or divider id. Click or directional actions move focus; semantic divider
drags and directional keyboard actions resize; zoom fills the tab without replacing or stopping
hidden sessions; and close reuses the conservative running-child confirmation, releases the pane's
session, promotes its sibling, or delegates the final leaf to tab close. An action that would adopt
another live session first flushes and otherwise defers while terminal input or response debt
remains; once the UI claims a pointer press it retains motion and release too. The app retains one
`Grid` per pane and composites one font-metric-aware full-canvas overlay after the visible panes;
the sidebar remains a true inset
whose width reduces and resizes the pane terminals. macOS defaults are Command+D / Command+Shift+D
for split right/down, Command+Alt+Arrow for focus, Command+Ctrl+Arrow for resize,
Command+Shift+Enter for zoom and Command+Shift+X for close. Linux and Windows use
Ctrl+Shift+E/O, Alt+Arrow, Ctrl+Alt+Arrow, Ctrl+Shift+Enter and Ctrl+Shift+X respectively. The
dedicated `--tabs-test` uses real PTYs and SDL events to cover tracked-cwd inheritance, create,
inline rename, click/next/goto switching, pointer/keyboard reorder, background activity and BEL,
modal input isolation, cancel and confirmed
close. Its final screenshot was visually inspected and shows the true terminal inset with the
close-confirmation modal. The deterministic Linux `--panes-test` uses real PTYs and SDL events to
cover nested splits and cwd inheritance, click and directional focus, divider drag and keyboard
resize, zoom with background pumping, conservative close and sibling rebalancing. Native macOS
and Windows tab/pane input and rendering remain runtime-unverified. TASK-31 is complete: the
action registry carries validated palette visibility and optional fixed-choice or free-text
argument metadata, while an allocation-bounded model fuzzy-matches labels and stable command names,
ranks an empty query by run-local recency, and formats every bound chord. Command+Shift+P on macOS
or Ctrl+Shift+P on Linux and Windows opens a centered semantic overlay containing every registered
user-facing command; semantic-only actions remain hidden. Arrow/Tab navigation, Enter, Escape,
clickable command and choice rows, and outside-click close all remain modal so no key or pointer
tail reaches the terminal or UI beneath. Nested argument steps dispatch through the same action
registry. The deterministic Linux `--palette-test` covers filtering, keyboard and mouse execution,
fixed-choice and free-text arguments, recent-command ordering, modal isolation and the centered
rendered frame through real PTYs and SDL events. TASK-32 completes the
workspace scratchpad: it starts an independent interactive shell with the workspace, retains that
permanent session while hidden, and presents it as a full-width bottom dock at 50 or 90 percent of
the window. Command+Backtick/Command+Shift+Backtick on macOS and
Ctrl+Backtick/Ctrl+Shift+Backtick on Linux and Windows toggle those sizes; Escape or the semantic
`scratchpad.hide` control hides only the presentation, while
`scratchpad.restart` atomically replaces the shell without changing the reserved session id. The
read-only test-driver target can inspect or wait for scratchpad text but adds no input-targeting
path: `key` and `type` still follow the real active presentation. The deterministic Linux
`--scratchpad-test` exercises startup, both sizes, hidden process and shell-state survival,
terminal/input isolation, restart, and the clickable restart/hide controls through real PTYs and
SDL events. TASK-33 completes multiple workspaces: `workspace.WorkspaceRegistry` owns ordered, heap-stable
workspace records under monotonic non-reused keys, while `app` owns one presentation bundle per
record and routes terminal, pane, scratchpad and asynchronous spawn state through the active
workspace. The palette exposes named create, rename, switch and confirmed-close
actions (the sidebar's footer control rows were removed by TASK-74); closing tears down that workspace's tabs, sessions and scratchpad, and closing the last
workspace requests normal shutdown. Its checked-in deterministic `--workspaces-test` drives two
real workspaces through SDL events, the action registry, semantic rows and real PTYs, checking
independent terminals, pane layouts, scratchpads, switching, rename, close cancellation and
teardown. Its Linux Xvfb execution passes with zero failures; the inspected screenshot shows the
90 percent scratchpad and close modal, while the semantic checkpoint proves both workspace rows.
TASK-34 is partially implemented for web links. Visible lexical HTTP(S) URLs and valid OSC 8
HTTP(S) spans are copied into bounded app-owned storage and registered once as stable
`terminal_link` semantic elements. OSC 8 metadata is authoritative, including malformed or
non-HTTP targets that mask lexical promotion. Holding Command on macOS or Ctrl on Linux/Windows
adds a decoration-only underline; the same modified click opens the exact target through
`platform.openUrl`, while plain clicks, selection drags and DEC mouse reporting remain terminal
input. Stable ids use a domain-separated 128-bit SHA-256 fingerprint. The deterministic Linux
`--links-test` covers the real SDL gesture path and opener seam. TASK-25's `terminal-links`
scenario independently proves the stable semantic id and `conduit-test ctrl-click` path through a
fresh isolated app. TASK-34 is complete on Linux: lexical file references (`path`, `path:line`,
`path:line:col`) register as `terminal_link` elements under a `.file` fingerprint id, and the
modified click snapshots the source session's OSC 7 cwd (workspace cwd fallback), resolves a
relative path against it without touching the filesystem, creates a new tab named after the file
and spawns shell-free argv `vi +<line> -- <path>` (or `vi -- <path>`) through the workspace
`ExecutionContext` (decision-5; columns are detected but not passed to vi). The job-owned argv is
freed on every spawn-completion path, and `childGone()` no longer ends a `--command` run while a
new tab's spawn worker is in flight. `--links-test` proves the exact argv and cwd through an
observer seam and real vim drawing in the new tab; the `terminal-file-reference` scenario proves
the `conduit-test ctrl-click` route.

TASK-69.1 (Linux tagged release) is complete. Prerelease tags `v0.1.0-rc.1` through `rc.4` each
ran the release workflow for real: tag validation, the reusable Linux gate, a ReleaseSafe build,
packaging, verification and an idempotent publish (the rc.2 workflow was rerun and replaced its
four assets in place). rc.1 exposed that GitHub renames assets containing `~`, so the Debian
package file keeps the SemVer spelling (`conduit_<version>_amd64.deb`) while only its control
`Version` uses the Debian `~` form; rc.3 was failed by a timing-dependent scrollback unit test,
fixed before rc.4. The published rc.2 and rc.4 assets were downloaded and re-verified locally
(checksums, an isolated `ubuntu:22.04` apt install printing the stamped version, AppImage
extraction). `v0.1.0` was tagged from the rc.4 commit and published as the first full Linux release
(https://github.com/thowd22/Conduit/releases/tag/v0.1.0), re-verified locally the same way.
`v0.1.2` (https://github.com/thowd22/Conduit/releases/tag/v0.1.2) ships the application icon in
every package plus the window icon; `v0.1.1` was tagged but never published because its gate hit
the IBus engine-readiness flake fixed in the following commit. `v0.1.3`
(https://github.com/thowd22/Conduit/releases/tag/v0.1.3) carries TASK-72: the ReleaseSafe terminal
engine, bounded draining and frame pacing; `seq 1 200000` takes 0.12 s in that binary. `v0.1.4`
(https://github.com/thowd22/Conduit/releases/tag/v0.1.4) carries TASK-73: Local children inherit
the desktop environment. `v0.1.7` (https://github.com/thowd22/Conduit/releases/tag/v0.1.7) carries
TASK-74 (sidebar Palette hint and version, content-sized palette) and TASK-75 (PTY wakeup fix);
`v0.1.8` (https://github.com/thowd22/Conduit/releases/tag/v0.1.8) carries M4: TASK-37, 38, 39, 40 and
41. `v0.1.9` (https://github.com/thowd22/Conduit/releases/tag/v0.1.9, release run 37776779436) is
the first release with all three platforms: the Linux packages, the macOS arm64 dmg and the
Windows x86_64 portable zip, each with checksums; every asset was downloaded and its checksum
re-verified locally, and the zip's payload inspected. `v0.1.10` (https://github.com/thowd22/Conduit/releases/tag/v0.1.10,
release run 37808087920) carries the TASK-76 follow-ups (branch row on Windows and under
rc files that reset `precmd_functions`), the real-VSCodium verification notes and the new
README; its eight assets were checksum-verified locally. `v0.1.5` and `v0.1.6` were tagged but never published because their release gates hit, in turn,
the `less` wheel test ordering and the IBus bridge race that the following commits fixed. `zig build
-Dversion=<semver>` validates SemVer 2.0.0 at configure time and stamps a `build_options` module
re-exported by `src/version.zig`; `conduit --version` (or `-V`) prints `conduit <version>` before
the log sink or SDL start, and an unstamped build prints `conduit 0.0.0-dev`.
`.github/workflows/release.yml` validates a `v*` tag, reuses `linux-e2e.yml` as the gate, builds
ReleaseSafe `x86_64-linux-gnu.2.35`, packages a tar.gz, Debian package, AppImage (pinned
appimagetool 1.9.1 and type2 runtime, SHA-256 checked) and `SHA256SUMS`, verifies them with
`release-verify.sh` (stamped version, x86-64 ELF, max `GLIBC_2.35`, payload, isolated
`ubuntu:22.04` Docker install), and publishes idempotently with `gh release` plus `--clobber`,
marking prerelease tags. `docs/release.md` documents the procedure. Locally the full dry run
passed 37/37 verifier checks; `ci.yml` and `linux-e2e.yml` now trigger only on branch pushes so a
tag runs the gate once through the release workflow. The macOS dmg and the Windows portable zip
are built and published by the same workflow (TASK-48 and TASK-49 below).

TASK-35 is complete. A right click over the focused terminal pane opens a minimal terminal-style
context menu at the pointer cell: a bordered `Surface` panel (`context-menu`) of `InteractiveText`
rows `context-menu.copy` (only with a selection), `context-menu.paste`, `context-menu.open-link`
(only over a `terminal_link`), `context-menu.split-right`, `context-menu.split-down` and
`context-menu.search`, each dispatching the existing named action (`clipboard.copy`,
`clipboard.paste`, `terminal.open-link` with the link's id as origin, `pane.split` with
`direction`, `search.open`). The menu is modal like the palette: Up/Down/Tab/Shift+Tab move, Enter
activates, Escape closes, a click outside closes, and no key or pointer tail reaches the terminal.
The palette-visible `terminal.context-menu` action (Shift+F10 on all profiles) opens it at the
terminal cursor. When the program has captured the mouse a plain right click is still reported to
it; Shift+right-click opens the menu. The `mouse.right_click` setting (`config.RightClick`)
defaults to `menu`; the v0.1 session layer `--right-click=paste` makes a right click paste
instead. The driver gained `right_click` (`conduit-test right-click <id>`, MCP `right_click`).
The deterministic Linux `--menu-test` covers all of this through real PTYs and SDL events and its
640x360 frame was visually inspected; TASK-25's sixth scenario `context-menu` drives
`conduit-test right-click` on `workspace.1.pane.1` and clicks the `search` row.

TASK-71 fixed real keyboard input, which no test had exercised because every check injected
synthetic SDL events and the dev box is headless. SDL sends a key event and then a matching
text-input echo for every printable key, and SDL 3.4 key events carry the unmodified keycode
(`Shift+h` reports `h`). `platform` now builds `KeyEvent.codepoint` by asking the layout with the
level modifiers applied (Shift, Caps Lock, AltGr/Mode, Level 5; never Ctrl, Alt or Super) while
`unshifted_codepoint` stays the plain key; UI key ownership matches a release to its press by the
named key or `unshifted_codepoint`; and `input.KeyTextEcho` drops SDL's identical text-input echo
after a key that wrote text to the terminal or inserted it into a focused UI `Input`, so one
physical keystroke is delivered once while IME commits and dead-key results still arrive. Synthetic
`postCharacterKey` events add the shift level the layout needs. `.github/scripts/check-x11-keyboard.sh`
types `Hello World`, Alt+x and a shifted search query through real XTest keystrokes under Xvfb and
asserts single delivery to the child (`KEYS_HEX1:48656c6c6f20576f726c64`, `KEYS_HEX2:1b78`) and to
the search Input (`1/1`); it runs in the Linux gate. macOS and Windows AltGr/Option behaviour is
unverified.

Conduit ships the user-supplied application icon. `assets/linux/io.github.thowd22.Conduit-source.png`
is the untouched original; `-master.png` is that file with its alpha cleaned (near-opaque fill
snapped to opaque, background-removal dust below alpha 8 removed; the exact command is in
`assets/linux/README.md`), and it generates the checked-in hicolor PNGs at 16, 22, 24, 32, 48, 64,
128, 256 and 512. `build.zig` installs them at `share/icons/hicolor/<N>x<N>/apps/io.github.thowd22.Conduit.png`
after checking each one's PNG signature and IHDR size; the earlier placeholder SVG and its
scalable install are gone. The AppImage uses the 256 render as its top-level icon and `.DirIcon`,
and `release-verify.sh` and `validate-linux-desktop.sh` check the PNG payload. `platform` embeds a
64x64 RGBA8 fixture and gives every window that icon through `SDL_SetWindowIcon` (failures are
non-fatal); `.github/scripts/check-x11-window-icon.sh` proves under Xvfb that the window's
`_NET_WM_ICON` is 64x64 and matches the fixture pixel for pixel, and it runs in the Linux gate.
Wayland has no window-icon property, so the desktop entry supplies the icon there; native macOS
and Windows window icons are unverified.

TASK-72 is complete. It separates draining from drawing. When a session asks for service,
`App.run` drains child output in a bounded loop of 16 KiB pump passes under
`workspace.DrainBudget.per_wake` (4 MiB or 8 ms, whichever comes first), then decides whether to
draw with `FramePacer`: while output keeps arriving, frames are coalesced to at most one per
max(16 ms, last frame's cost), and the moment output stops an owed frame is drawn at once. The
test driver is polled on every iteration, an owed frame is drawn before the loop exits, and an
idle window still blocks in SDL and draws nothing. A 40 MB carriage-return flood dropped from
12.7 s to 1.4 s in ReleaseSafe, and the scripted `output-flood` E2E scenario covers the path.
The remaining per-linefeed cost came from `build.zig`, not Conduit's code:
`b.dependency("ghostty", .{})` built the `ghostty-vt` module in Ghostty's default Debug mode with
`slow_runtime_safety` on, even inside ReleaseSafe Conduit builds, so every scroll ran
`Screen.assertIntegrity` and the page integrity checks (about 79 µs per linefeed in ReleaseSafe,
1.5 ms in Debug; the shipped v0.1.0 to v0.1.2 binaries had this). `ghosttyDependencyOptions` now
passes Conduit's target and optimize mode to both Ghostty dependency calls and builds the engine at
least ReleaseSafe even for a Debug Conduit. `seq 1 200000` went from 14.6 s to 0.12 s in
ReleaseSafe and from over 260 s to 0.48 s in Debug. `term.zig` reads the engine's mode through
`@FieldType(PageList, "pause_integrity_checks")`; its tests fail any optimised build that links a
slow-checked engine and bound a 200,000-line feed to 5 s. Always pass `optimize` to the Ghostty
dependency.

TASK-73: Local children inherit the environment. `ChildSpec` builds every child's environment for
the spawning workspace's `ExecutionContextKind`. A Local child (interactive shells, `--command`,
new tabs, panes, the scratchpad and the vi editor tab) starts with Conduit's own process
environment, so the desktop session (DISPLAY/WAYLAND_DISPLAY, XDG_RUNTIME_DIR,
DBUS_SESSION_BUS_ADDRESS, SSH_AUTH_SOCK, LC_*) and the user's exports reach it. `TERM`,
`COLORTERM` and `TERM_PROGRAM` are set on top, along with the PATH/HOME/LANG fallbacks when unset.
Only `ChildSpec.inherited_exclusions` is dropped: `CONDUIT_TEST_RUN`/`CONDUIT_TEST_ROOT`,
`CONDUIT_LOG_FILE`, an enclosing Conduit's four shell-integration handshake variables, and
`TERM_PROGRAM_VERSION`. The driver endpoint and artifact directory are flags, never environment,
and `conduit-test launch`'s isolated HOME/XDG_*/TMPDIR still apply to the app and therefore to its
children. SSH and WSL contexts receive only the curated identity-plus-fallback set: "Local
inherits; remote contexts supply their own". The eighth `zig build e2e` scenario,
`child-environment`, sets a probe variable, a stand-in SSH_AUTH_SOCK and both `conduit-test`
addressing variables for `launch` only, and the child must show the probe, the agent socket, a
display, the isolated HOME layout, unset driver addressing and Conduit's identity.

TASK-75 fixed a PTY stall. The POSIX backend's read thread and owner thread used one nonblocking
pipe as the wakeup channel in both directions; after the reader saw a full byte ring but before it
blocked, the owner could take every byte, notify, and then drain that very byte in
`waitUntilPending`, leaving the reader asleep with nobody left to wake it, so the child blocked on
the slave and the session froze until closed. Hosted gate run 37635552480 caught it as the 4 MiB
flood unit test consuming 1.2 MiB and then nothing for its 10 s deadline. `PosixPty` now has two
channels, `owner_wake` (reader to owner, drained only by the owner) and `reader_wake` (owner to
reader, drained only by the read thread), so a wakeup can never be consumed by the thread it was
not meant for; a test-only `ReaderPark` gate parks the reader at the racy point and the new
pty test fails on the single-pipe design. `session.drainChildOutput` now observes the child state
before taking bytes so an end published between the two observations cannot strand the final
queue (fake-backend test). The faster wakeups exposed that the tmux integration test typed F1
within tmux's 1 ms `assume-paste-time`, which treats the key as pasted text and skips bindings;
the test's tmux config sets it to 0, and the `less` wheel test now waits for the pager's first
row to be drawn rather than only for the alternate screen, because the mode switch can now arrive
in its own read ahead of the content.

TASK-37 is complete on Linux. `config` owns a Ghostty-style settings file (`key = value`, `#`
comment lines, repeatable `keybind = <chord>=<action>[:<argument>]` or `<chord>=unbind`) at
`$XDG_CONFIG_HOME/conduit/config` (else `~/.config/conduit/config`), `~/Library/Application
Support/conduit/config` on macOS and `%APPDATA%\conduit\config` on Windows; `docs/config.md` is
the grammar and the default for every key. Parsing is bounded (256 KiB file, 1024-byte lines, 256
keybind lines) and never fails on input: each bad line is logged as `<path>:<line>: <message>` (key
named, value never repeated), the rest of the file applies, and a rejected key or chord keeps its
previous value; an unreadable file keeps every previous value and a missing one is the built-in
layer. The first problem shows in the sidebar as the clipping `config.error` Text (role
`config_error`, `config:<line>: <message>`) above the footer until fixed. `font.family` and
`font.size` rebuild the face (`--font` stays the session layer); `scratchpad.size` and
`scratchpad.large_size` set the two dock heights (default 50/90); `mouse.right_click` applies under
`--right-click`; `theme` is consumed by TASK-38 and the remaining `font.*` keys by TASK-40. `input.parseChord` and
`buildBindings` rebuild the whole binding table from the profile defaults plus the file, so every
bound action, including both scratchpad toggles, is rebindable; the search chord and modal keys are
not yet. A watcher thread (inotify on the parent directory on Linux, catching rename-replace saves
and coalescing bursts after 100 ms; size/mtime/inode polling every second while the directory is
missing and on other OSes) only flags a change and posts an SDL wake; the main thread reads and
applies the file. Palette actions `config.open` (Ctrl+, / Cmd+,; creates the file from the
commented defaults document, then opens `vi -- <path>` in a new tab through the workspace
ExecutionContext) and `config.reload` exist. Built-in checks other than `--config-test` never read a
settings file. The deterministic Linux `--config-test` proves a rebound palette chord and a
configured scratchpad size through SDL, a malformed edit's line-numbered `config.error` with
previous and still-valid values working, a rename-replace repair that clears it and applies new
values including a larger font, return to defaults on deletion, and `config.open` by Ctrl+, and by
a clicked palette row. macOS/Windows locations and the polling watcher backend are
runtime-unverified. Its first hosted run exposed that a child attached after an asynchronous spawn
kept the PTY size from spawn time when the grid had changed meanwhile (here the deletion step's
face reload finished 40 ms after the editor spawned); `Session.syncChildSize` now tells a
late-attached child the current grid when it differs from the requested one.

TASK-39 is complete on Linux. `src/font_sprite.zig` draws box drawing (U+2500–257F), block
elements, braille and the Powerline arrow/rounded/triangle separators (U+E0B0–E0BF, E0D2, E0D4) at
the exact cell size so they tile without a Nerd Font; `Request.builtin_symbols = false` hands them
back to the font. `font.Manager.resolve` walks a per-codepoint chain: sprites, the primary style
face, the primary regular face with synthetic bold (FreeType emboldening) or oblique (12° shear),
`Request.fallbacks` families, installed system faces found through cmap coverage read at scan time
(monospaced regular first, colour faces last or first for emoji presentation, private-use
codepoints preferring the bundled symbols face), the bundled Nerd Fonts v3.5.1 Symbols Nerd Font
Mono face (OFL/MIT, licences in `assets/fonts/`), then the bundled JetBrains Mono. Fallback glyphs
are scaled and pixel-snapped into one or two cells, so the grid never changes. FreeType is built
with the Ghostty-pinned libpng 1.6.43 and zlib 1.3.1, so Noto Color Emoji CBDT glyphs load into a
separate premultiplied RGBA atlas that `render` draws in a third instanced pass.
`Request.ligatures`/`Manager.setLigatures` toggle `liga`/`calt`/`dlig`, and `render` shapes
ligature runs of printable ASCII per row while keeping every glyph in its cluster's cell. HarfBuzz
now shapes through its own OpenType functions rather than `hb-ft`, which had resized the shared
`FT_Face` to upem/64 px on the first shape and so drew text at about 15.6 px at every size and
scale (2x text was half size since v0.1.0). A size or scale change re-creates the manager and
re-rasterises every glyph, sprite and emoji. The tenth `zig build e2e` scenario, `font-coverage`,
prints a Starship-style prompt, box drawing, blocks, braille, CJK, U+273B, a Nerd icon, ligatures
and colour emoji; its 1x and 2x screenshots were inspected. The Linux gate installs
`fonts-noto-color-emoji`, `fonts-noto-cjk` and `fonts-dejavu-core`. The bundled-face Hangul preedit
gap noted under TASK-50 is closed wherever a CJK font is installed. TASK-40 wires the `font.*` settings to these `Request` fields.

TASK-38 is complete. `theme` owns a `Scheme` (16 ANSI colours, foreground, background, cursor,
selection, optional cursor-text and selection-foreground) and `derive`, which maps it onto every
`Role`: the terminal roles are the scheme's own, and the chrome roles (`strong`, `muted`, `accent`,
`border`, `attention`, `danger`, `on_accent`, `field`, `selection`) prefer the conventional ANSI
slot and fall back rule by rule to keep WCAG contrast (4.5:1 text, 3:1 chrome), so light schemes
stay readable; `conduit-dark` derives exactly the palette Conduit shipped before. Fourteen schemes
are bundled as compile-time data in `src/theme_schemes.zig`, copied from the Ghostty theme files of
iTerm2-Color-Schemes with a source URL each and licences in `assets/themes/README.md`: Conduit
Dark, Gruvbox Dark/Light, Catppuccin Mocha/Latte, Dracula, Nord, Tokyo Night, Solarized Dark/Light,
One Dark, Kanagawa Wave, Everforest Dark and Rosé Pine. `theme = <name>` names a bundled scheme or
a Ghostty-format file in `<config dir>/conduit/themes/` (user files win; names ignore case, spaces,
hyphens and underscores); `auto:<dark>,<light>` follows `platform.systemTheme` and SDL's
system-theme event, dark when unknown; an unknown name is a `config.error` line and the previous
theme stays. Themes resolve at startup and on every settings reload (theme files are re-read then,
not watched on their own). The active palette feeds every pane and scratchpad grid, the overlay and
the surface clear, and all chrome uses the derived roles. The palette command `Theme: choose`
(`theme.pick`) lists every theme with the active one first, previews the keyboard-highlighted or
hovered theme live across the whole window, reverts on Escape or an outside click, and on Enter or
click writes `theme = <name>` with `config.writeDocumentValue`, which replaces or appends one key
while preserving every other line. Cursor-text and selection-foreground are parsed but not drawn
yet, so `derive` tones down a selection colour that sits near the foreground. The deterministic
Linux `--theme-test` drives a bundled theme, a dropped user file, keyboard preview and revert,
hover preview, a mouse commit saved to the file, an unknown-name error and the `auto:` pair through
real SDL events and frame readback; its picker frame was visually inspected. Native macOS and
Windows dark-mode reporting is unverified, and under Xvfb SDL reports the preference as unknown.

TASK-40 is complete on Linux. Every `font.*` setting now reaches font manager v2:
`font.bold`/`italic`/`bold_italic` name style-face families (`Request.bold_family` etc.; the
family's exact style face, else its regular face; empty or uninstalled keeps the derived face),
`font.ligatures`, `font.nerd_symbols`, and the new one-line comma-separated `font.fallbacks` (at
most 8 families; an uninstalled one is skipped and shown as `config.error`). `app` owns the
committed settings as one owned `FontSettings` and identifies a face by `FontValues.faceKey`
(everything but ligatures, plus the display scale), so a request for the face already drawn or
being built starts no worker, and a ligature change toggles `Manager.setLigatures` and invalidates
every grid instead of rebuilding. Seven palette commands are registered after `theme.pick`:
`font.pick` "Font: Change Family", `font.size.increase`/`decrease`/`reset` (1 point, 6–72; reset
writes `font.size = 14`), `font.ligatures.toggle`, `font.symbols.toggle` and `font.fallbacks` (free
text, `none` clears). Each commits live state first and then writes its key with
`config.writeDocumentValue`, so the watcher's reload of that write is a no-op. Ctrl+= /
Ctrl+Shift+= / Ctrl+- / Ctrl+0 (Command on macOS) are the size defaults; none collides with a
default or a terminal control code, and Ctrl+Shift+- stays terminal input. The picker lists
"JetBrains Mono (bundled)" plus `font.Catalog.monospaceFamilies` (fixed-width, non-colour, covering
`M` and `0`; sorted, at most 256), current family first; the keyboard highlight or a hover after
real pointer motion previews by rebuilding the manager (a still pointer may not move the preview,
because the previewed face's cell height moves the rows under it), Escape or an outside click
reverts, Enter or a click commits without a second build, and the dialog's `palette.preview` Text
names the drawn family only once the highlighted face has loaded. Palette choice ids are stored
per visible row, so choice lists may exceed the registry size. The deterministic Linux
`--font-test` drives sizes by chord, keyboard palette and clicked row with cell-metric readback,
ligatures with frame readback, symbols, fallbacks, and picker preview/revert/hover/mouse commit,
checking the file after each and that each self-caused reload rebuilt nothing. The eleventh and
twelfth `zig build e2e` scenarios, `theme-picker` and `font-picker`, drive both pickers by keyboard
and by a clicked choice row; the picker frames were inspected. The family list is a fixed-choice
step, not type-to-filter, and macOS and Windows chords and fonts are unverified.

TASK-41 is complete on Linux. `settings.open` ("Settings" in the palette; Ctrl+Shift+, on
Linux/Windows, Cmd+Shift+, on macOS) opens a centred modal `Surface` (`settings.dialog`) built only
from the four primitives. Dim `Text` headings group the rows under Appearance, Fonts, Keys,
Scratchpad and Mouse. Each setting is an `InteractiveText` row `settings.row.<key>` reading
`<key>  <value>`, with `·` when the settings file sets the value. Keys has
`settings.row.keybind.<action>` for every palette command without an argument plus `palette.open`.
The last row, `settings.raw`, dispatches `config.open`. Up/Down/Tab move the highlight over the
headings, Home/End jump, and the list scrolls. Enter or a click edits a row: bools toggle,
`mouse.right_click` cycles, `theme` and `font.family` open the existing choosers, and numbers and
text open the inline `settings.input`. Left/Right toggle, cycle or step by one. Every commit is
checked with `config.checkValue`; a refusal shows the parser's own message in `settings.error` and
writes nothing. Otherwise it writes through `config.writeDocumentValue` and reloads at once, so the
watcher's reload of the same write rebuilds nothing. The view takes every key press before any
binding runs, so the keybinding editor captures the next real chord without triggering it. It
refuses bare text keys (and bare Enter, Tab, Backspace and Escape), names a chord another command
holds (`conflict: <label>`), keeps the old binding on Escape and takes the chord on a second Enter.
It writes through `config.writeActionKeybinds`: the command's old lines go, its remaining shipped
chords are unbound, and `<chord>=<action>` is appended. Pointer and text input are modal like the
palette. The deterministic Linux `--settings-test` drives all of this through real SDL events with
file readback, and its 640x360 frame was inspected. The thirteenth scripted scenario,
`settings-view`, opens the view by keyboard and through `sidebar.palette`, then clicks a bool row.
macOS and Windows are unverified.

TASK-42 is complete: decision-8 chooses the system OpenSSH client, spawned through `pty.spawn`,
with one ControlMaster per SSH workspace on Linux and macOS (tabs, panes, the scratchpad, editor
tabs and agent TUIs run `ssh -tt -o ControlMaster=no` over it; file reads, listings, watches and
command runs use `ssh -T -o BatchMode=yes` exec channels), one `ssh.exe` per session with the
Windows ssh-agent on Windows (WSL transport and libssh2/WinCNG are recorded as later opt-in
upgrades), OpenSSH's own host-key, passphrase, password and 2FA prompts shown verbatim in a
connection session that Conduit never parses, stores or logs, explicit user-driven reconnect, and
remote shell integration installed into a content-addressed cache. `spikes/ssh-controlmaster`
proved one authentication, two independent resizable shells and two exec channels on one master
against a local sshd container; `ControlMaster=no` silently opens a direct connection without a
live master, so every exec uses BatchMode and sessions spawn only while connected. TASK-43
implements it.

TASK-52 is complete. `agent` now holds the harness-neutral core under `src/agent/`, re-exported
from `agent.zig`. `State` (idle, working, waiting_input, waiting_permission, done, errored) has a
`canTransition` table and a `Source` that is either structured or heuristic. `Event` is a typed
union of message, tool_use, file_reference, permission_request (with the harness's own decision
list), permission_resolved (including resolved_elsewhere), status_change, subagent, notification
and exited; its payload text is untrusted and never acted on. Events cross from adapter IO
threads to the owner thread through the bounded, mutex-guarded `EventQueue`, which deep-copies
each event into a fixed slot and refuses rather than grows when full. `Adapter` is a type-erased
vtable (detect, launch, attach, poll, sendInput, respondPermission, readPrompt, updatePrompt,
stop) whose every method is gated by `Capabilities` and returns `error.Unsupported` when
unavailable. `launch` only describes the process (argv plus extra env including
`CONDUIT_AGENT_TOKEN`, which `ChildSpec` now strips from nested children); the workspace spawns it
through its ExecutionContext into an `agent_terminal` session. `Registry` keeps agents per
workspace under monotonic, never-reused `AgentId`s. Owned agents must use agent sessions, observed
(hand-started) agents live in a human terminal the human keeps, and the scratchpad is refused for
both. Pending permissions are tracked by id, heuristic status is ignored once a structured event
arrives, and an exit freezes the record. `Heuristics` maps PTY facts (output, title, BEL, OSC
9/777, OSC 133, human input, quiet, child exit) to heuristic events. The scripted `FakeAdapter`
drives the unit tests through every transition. `Harness` now includes `opencode`, and
`src/agent/{claude_code,codex,pi,opencode}.zig` are stubs for TASK-53/54/55/78; nothing in the app
is wired to the registry yet.

TASK-70 is complete. `README.md` says what Conduit is, lists the features that exist today (agents
and Backlog.md marked as coming), shows four screenshots taken from the real app through
`conduit-test` (`docs/images/main-window.png`, `palette.png`, `theme-picker.png`, `settings.png`),
and covers Linux install from the release deb, AppImage or tarball with `SHA256SUMS`, building from
source with the Zig 0.16.0 pin, the headless checks under Xvfb, the bundled third-party licences,
and `conduit-test`/`.mcp.json` for agents. `docs/user-guide.md` covers the sidebar, terminal
basics, palette, tabs, panes, scratchpad, workspaces, links and file references, search, context
menu, settings view, themes, fonts, config location and flags, plus the full default keybinding
reference for both profiles, generated from `src/input.zig`'s two tables, the fixed search chord
and the modal keys. `docs/agents.md` describes running Claude Code, Codex, Pi and OpenCode inside
Conduit today (environment inheritance, glyph coverage, OSC 52 copies refused), marks the
decision-7 integration as planned, and documents agent access to `conduit-test` through the CLI,
Claude Code's `.mcp.json`, `codex mcp add` and Pi's shell tool. `docs/config.md` stays the settings
reference. Writing the docs found that Claude Code 2.1 rejected `conduit-test mcp`'s tool list
under the 2026-07-28 protocol because the `allOf` wrapper around every non-`launch` schema lacked a
top-level `"type":"object"`; `writeTool` now emits it and the tools/list test asserts the type on
every tool. The install flow was checked against the v0.1.7 assets; macOS and Windows content is
marked unverified.

TASK-62 is complete. The type-erased `ExecutionContext` now carries file, watch and command
capabilities beside `spawn`: `readFile` (caller-bounded buffer), `listDir` (visitor), `statPath`,
`watch` (a `WatchHandle` with no thread and no callback, polled by its owner) and `run` (argv
without a shell, cwd, optional stdin up to 16 KiB, capped stdout and stderr, whole-run timeout that
kills the child). Every entry defaults to `error.Unsupported`, so SSH and WSL contexts implement
them later; Local inherits, remote contexts supply their own. On Linux the Local watch drains a
non-blocking inotify descriptor; elsewhere, and while a directory does not exist yet, it compares a
bounded fingerprint at most once a second. `backlog.Project.load` reads a `backlog/` directory
through a borrowed context: `config.yml`, plus tasks, completed, drafts, milestones, docs and
decisions. Front matter goes through a bounded YAML subset that accepts only what Backlog.md
writes; sections and numbered acceptance criteria are read from the tool's markers, with a heading
fallback. Every malformed file becomes a line-numbered diagnostic and is never fatal. Each file
owns an arena. `Project.watch` and `Project.poll` re-read only files whose size or mtime changed
and return added/updated/removed `Change` records; a `config.yml` rewrite re-parses only when the
statuses change. `backlog.Cli` runs the `backlog` CLI through `ExecutionContext.run` in the project
directory (`setStatus`, `checkAcceptance`, `editTitle`, `addNote`, `setAssignee`, `setPriority`),
passing validated ids and values as single `--option=value` argv entries, and returns
`.failed{exit_code, stderr}` or `error.CliUnavailable`; Conduit never edits backlog markdown
itself. Unit tests parse valid, malformed and empty fixture projects under `test/fixtures/backlog`
and the repository's own `backlog/` (0 diagnostics), cover live update through a temp directory
and the CLI wrappers through a scripted context, and a manual check against the real `backlog`
1.53.0 showed a CLI edit returning through `poll` as one update. There is no view or E2E scenario
yet; that is TASK-63.

TASK-53 is complete at adapter level. `agent/claude_code.zig`'s `ClaudeCodeAdapter` detects
`claude --version` through the ExecutionContext. Its `launch` writes a per-agent sink
(`settings.json` with command hooks for SessionStart, InstructionsLoaded, UserPromptSubmit,
PreToolUse, PermissionRequest, PostToolUse(Failure), Notification, SubagentStart/Stop, Stop,
StopFailure and SessionEnd, plus a POSIX `hook.sh` relay) and returns `claude --settings
<sink>/settings.json --session-id <uuid from the agent token>` with `CONDUIT_AGENT_TOKEN`. The
relay appends each hook input as one wrapped line to `<sink>/events.jsonl`, which `poll` tails
into typed events. Stop maps to `done`, and an observed session's `SessionEnd` maps to `exited`. A
PermissionRequest blocks, for at most 580 s, until `respondPermission` atomically writes
`<sink>/decisions/<id>`; the relay then prints Claude's `hookSpecificOutput.decision.behavior`
allow/deny reply, and answers given in Claude's own dialog resolve as `resolved_elsewhere`.
`TranscriptReader` incrementally parses the session JSONL into messages, tool uses and file
references. `findRunningSession` matches Claude's undocumented `<config>/sessions/<pid>.json`
registry by pid, cwd or session id, so a `claude` started by hand in a terminal can be attached and
followed until it exits. Real 2.1.292 field names differ from the docs (`SessionEnd.reason`,
`StopFailure.error`), and hooks do inherit `CONDUIT_AGENT_TOKEN`. Unit tests cover every hook
event, the transcript and the registry from fixtures recorded with 2.1.292 under
`src/agent/claude_code/fixtures/`. Integration tests run the generated relay through a Local PTY,
an unauthenticated real `claude -p` in an isolated HOME whose hooks reach `poll`, and a real
interactive `claude` found in the registry, attached and seen to exit. The agent view that answers
prompts is TASK-57/58; the sink is interim until TASK-60's endpoint, and remote contexts are
TASK-61. An authenticated live allow/deny was not run (no credentials).

TASK-54 adds the Codex adapter (`src/agent/codex.zig`). `CodexAdapter` speaks Codex's app-server
JSON-RPC over a pluggable `Transport`: a minimal RFC 6455 WebSocket client over
`FdStream.connectUnix` to the shared daemon's `$CODEX_HOME/app-server-control/app-server-control.sock`
(`Mode.daemon`, joining a TUI's thread), or newline-delimited JSON over the pipes of an
owner-spawned `codex app-server --listen stdio://` (`Mode.stdio`, a headless agent). `detect` runs
`codex --version` through `ExecutionContext.run` and feeds the version gate (0.160.0 ≤ v <
0.162.0, also checked against the `initialize` userAgent); outside the range capabilities drop to
heuristics only and `attach` fails with `error.Protocol`. `attach` runs `initialize`/`initialized`
and then resumes a known harness session id, starts a thread (stdio), or finds a hand-started TUI:
the most recently updated loaded thread (`thread/loaded/list` ∩ `thread/list`) whose cwd is the
agent's. `poll` maps `thread/status/changed`, turns, items and `serverRequest/resolved` to events
with only legal state transitions; approval server requests become `permission_request`s
carrying Codex's own `availableDecisions`, and `respondPermission` sends exactly the chosen
decision. `sendInput` is `turn/start`/`turn/steer` and `stop` is `turn/interrupt`.
`RolloutReader` parses rollout JSONL incrementally (approvals are never in rollouts). Unit tests
replay an approval round trip recorded from the real 0.160.1 binary against a local mock provider
(`test/fixtures/agent/codex/`) and drive a fake WebSocket daemon over a real Unix socket; opt-in
runs (`CONDUIT_CODEX_MOCK_HOME`/`_CWD`, `CONDUIT_CODEX_DAEMON_HOME`/`_CWD`) answered a real stdio
approval and a real hand-started TUI's approval on an isolated daemon. No model account was used.
Headless stdio agents still need a piped (socketpair) spawn variant, `FdStream` should move
behind `platform` (invariant 10), and app wiring is TASK-56/60.

TASK-55 adds the Pi adapter (`src/agent/pi.zig`; omp as an unverified `Variant`). Pi has no hooks
or permission prompts, so Conduit ships a dependency-free Pi extension (`src/agent/pi/conduit.js`,
embedded and loaded with `pi -e`). It appends token-tagged JSON lines to
`$CONDUIT_AGENT_SINK/events.jsonl`. With `CONDUIT_AGENT_GATE` it holds bash/write/edit on Pi's own
confirm dialog while also accepting a `yes`/`no` decision file, and whichever answers first wins
(`resolved_elsewhere` when the human answered in Pi). Headless agents use `pi --mode rpc`, where
the confirm is an `extension_ui_request` answered with `extension_ui_response`. All IO goes
through an owner-supplied `Transport`. `detect` runs `pi --version` (or `omp --version`) through
`ExecutionContext.run`. `SessionReader` turns session JSONL v3 into transcript events. Unit tests
use captured fixtures under `src/agent/pi/testdata/`. Two integration tests run the real `pi
--mode rpc` with the extension against a loopback mock model, proving status, the gated confirm
answered over RPC and through the decision file, the tool running and the session file being
written; they skip when `pi` or `python3` is absent, so the hosted Linux gate skips them. A manual
tmux run of the interactive TUI showed both answer paths. Still missing: `LaunchSpec` carrying the
extension file for the owner to write, installing the extension for manual starts (consent,
TASK-60), and registry/owner wiring.

TASK-78 is complete on Linux. OpenCode 1.18.35 was verified live, never installed on the host:
`scripts/opencode-container-check.sh` installs npm `opencode-ai@1.18.35` in a throwaway
ubuntu:24.04 image with a fixed local OpenAI-compatible model (`scripts/opencode-mock-provider.py`,
`permission.bash = "ask"`). The adapter's live test drives a whole turn; Conduit under Xvfb, driven
by `conduit-test`, launches OpenCode through `Agent: launch` (working → waiting_permission → done
from structured SSE events), answers the bash permission by clicking the agent view's `Allow once`
(outcome `allowed`), and observes an `opencode` started by hand in a plain tab. The fixtures
`recorded-turn.sse` and `recorded-messages.json` are scrubbed recordings; the tool part is
`running` before the ask. Live testing fixed two bugs: agents' capabilities now follow their
adapter after registration (`Registry.setCapabilities`), and an event-stream head that never
arrives is redialled. `agent/opencode.zig`'s `OpenCodeAdapter` uses the HTTP server OpenCode's TUI
starts with `--port`: `detect` runs `opencode --version` through the context; `launch` describes
`opencode --port P --hostname 127.0.0.1 [--prompt …]` (or `opencode serve …` headless) with
`CONDUIT_AGENT_TOKEN` and the token as the server's basic-auth password; a bounded HTTP/1.1 + SSE
client reads `GET /event` and maps `session.status`/`session.idle`/`session.error`,
`permission.asked`/`permission.replied`, `question.asked`, message parts and child sessions onto
`agent.Event`; `respondPermission` posts `{"reply":"once|always|reject"}` to
`/permission/:id/reply`, `sendInput` uses `prompt_async`, `stop` uses `abort`, and attach replays
`GET /session/:id/message`. Not seen live: `question.asked`, child sessions, `session.error`,
aborts and the v1 shapes; OpenCode has no Windows read path (no timed socket receive in Zig 0.16)
and stays terminal-only in SSH workspaces.

Observed agents (TASK-56 follow-up) are harness-neutral: `pty.Pty.foregroundProcess` (Linux
`TIOCGPGRP` plus `/proc`; macOS and Windows return null) is checked after terminal activity at
most every 2 s, `agent.recognize` asks each adapter's `recognizeCommand` (`claude`, `codex`,
`pi`/`omp`, `opencode`, the fake's `conduit-fake-agent` under checks), and a recognised program
becomes an observed agent on that human tab. Claude Code attaches by registry pid or cwd, Codex by
daemon thread cwd, and Pi, OpenCode and the fake keep the PTY baseline. The agent ends as done
when the program leaves the foreground, and `agent.stop` on an observed agent ignores that pid
while it stays in front. The scratchpad, agent and connection terminals and remote workspaces are
never observed. `--agent-test` proves this with a hand-started `conduit-fake-agent`.

TASK-76 is complete on Linux. A tab whose focused session's OSC 7 cwd is inside a git work tree
shows its branch on a second, non-interactive sidebar row, `workspace.<k>.tab.<n>.branch` (role
`branch`, label = full branch name or the 8-digit short commit of a detached HEAD), drawn in the
`muted` role with `ui.TextStyle.small`. That style uses a second `font.Manager` at 0.6 of the
point size, rebuilt with the main face, centred in a normal one-cell row and drawn in its own
overlay pass over its own atlas (decision-10). A name too long for the row is painted with a
trailing `…`. A tab outside a repository has no branch row and the list reclaims it; rename,
reorder (a drop on the branch row targets its tab), close and sidebar resize are unchanged.
`src/git.zig` resolves the repository only through the workspace `ExecutionContext`
(`statPath`/`readFile`): it walks up at most 32 directories, follows `gitdir:` files, reads `HEAD`
(at most 4 KiB) and validates the name. Malformed input means "no repository", and no git process
is ever started. The app refreshes a session's branch on an OSC 7 cwd, an OSC 133 prompt start or
a reset, plus a Local-only `watch` on the git directory, each refresh as one `git.Lookup` worker
polled on the loop, never per frame. The deterministic Linux `--git-test` builds two real
repositories in a private temporary directory and, through real PTYs and SDL input, covers
checkout, a watched HEAD rewrite with no prompt, a cwd change to another repository, leaving the
repository, a detached HEAD and the two-row tab behaviours. The fourteenth scripted scenario
`sidebar-branch` drives the same path through `conduit-test`. Remote (SSH/WSL) resolution and
macOS/Windows rendering are unverified.

TASK-77 is complete on Linux. Each workspace after the first listed one, and every row of its
group, sits 5 logical pixels further down (5, 10, …), scaled by the window scale, while rows inside
a group keep whole-cell spacing (decision-11). `ui.ElementRegistration.offset_px` is converted once
by `Geometry.pixel_scale` into the element's device-pixel bounds and into every canvas cell it
paints (`render.OverlayCell.offset_y_px`). Painting, hit testing, hover, focus and the driver's
`inspect` bounds therefore all agree, and the driver reports the shifted pixel bounds. Pixels in
the gap belong to no element. The list limit above the footer drops each group's shift rounded up
to whole rows, so no shifted row reaches the Palette hint or version line. `--workspaces-test`
asserts the gap through semantic bounds and, with real SDL events, a no-op click in the gap, a
drag reorder of shifted tabs, a bottom-edge click selecting the right shifted tab, and keyboard
focus over the shifted rows. Screenshots at scale 1 and 1.25 were inspected.

TASK-56 is complete on Linux. `src/app_agents.zig` (part of `app`) owns the one `agent.Registry`,
a `Runner` per launched agent (adapter, owner-side transport, `EventQueue`, poll worker),
per-agent `Heuristics`, a bounded notification list and the OS notification seam. `term`
surfaces OSC 9 and OSC 777 as a cleaned, bounded `notification` event. Agent: launch
(`agent.launch`) offers the scripted fake when a check enables it, then the harnesses whose
`detect` answered in the workspace's context, followed by an optional prompt step
(`agent.launch-prompt`). It creates an `agent_terminal` tab, registers the agent as owned, and
spawns the adapter's `LaunchSpec` through the workspace ExecutionContext; before the spawn, the
spawn worker's `Runner.prepare` writes every `LaunchSpec.files` entry into a private 0700 sink
under `$XDG_STATE_HOME/conduit/agents/<run>`. Claude uses its hook sink, Pi an owner sink
transport plus `conduit.js`, Codex a lazily connected daemon WebSocket, and OpenCode a bind-0
loopback port; sink harnesses are Local-only until TASK-61. Every session's terminal events feed
its agent's heuristics. The sidebar leads agent tabs with `·` idle, `▸` working, `?` input, `!`
permission, `✓` done and `×` errored, and the workspace row with its most urgent agent's glyph;
each glyph is also a semantic `<row>.agent.<state>` element. New waits, outcomes, harness
notifications, OSC 9/777 and background bells fill the list (Notifications, Ctrl+Shift+N /
Cmd+Shift+N, a modal `Surface` of `notification.<n>` rows); Enter or a click on a row focuses that
workspace, tab and pane. While the window is unfocused, entries also go to `platform.notify`
(`notify-send` on Linux; macOS and Windows return Unsupported). `notifications.*` switches
filter by kind and harness, hot-reload, and live in the settings view's Agents group. Agent: stop
hangs up an owned agent's PTY; Agent: focus shows its tab. The deterministic Linux `--agent-test`
and the fifteenth scenario `agent-notifications` drive the fake adapter through real PTYs and
SDL input (`CONDUIT_TEST_FAKE_AGENT=1` offers the fake only together with `--test-driver`). A
real Claude Code launch through the palette spawned the hooked command into its sink but stopped
at onboarding in the isolated HOME, so the structured hook path is unverified end to end;
observed (hand-started) agents wait for a foreground-process query in `pty`.

TASK-43 is complete on Linux. `SshContext` is created with the local `ssh` client's inherited
environment (`ChildSpec.buildSshClient`: Conduit's environment minus `inherited_exclusions`) and
control sockets under `$XDG_RUNTIME_DIR`. SSH sessions get only the remote overlay
(`ChildSpec.buildRemote`: TERM, COLORTERM, TERM_PROGRAM and a LANG fallback, never local PATH or
HOME) and an empty argv, which means the remote login shell. Each SSH workspace has a `connection`
session (a new `session.Kind`) whose PTY is the master's terminal. It replaces the panes, under a
`workspace.<k>.connection` header, until the state is `connected`, so OpenSSH's own host-key,
passphrase, password and 2FA prompts are typed there; `remote.show-connection` brings it back
later. The sidebar row shows `↕` connecting, `⚠` lost, `✗` failed or `○` disconnected, and
registers `workspace.<k>.ssh.<state>`; `workspace.status` names each transition. When the
workspace connects, one exec learns the remote host name for OSC 7
(`term.Terminal.setWorkingDirectoryHost`), and then the first tab and the scratchpad start.
`remote.reconnect` (palette, or the view's clickable `reconnect`) starts a new master; once it
connects, every session whose client ended as `ssh.sessionEnd(...) == .disconnected` is respawned
under its id at its last OSC 7 cwd (`Workspace.respawnRequest`/`replaceSessionChild`).
`remote.disconnect` is the non-blocking `SshContext.hangUp`. Spawns are refused until the
connection is ready. The deterministic `--ssh-test` drives all of this through real SDL input
against the `test/fixtures/ssh` container (one authentication for the first tab, a split, a tab
and the scratchpad; the host-key and passphrase prompts; simulated loss by killing sshd's
per-connection processes; reconnect restoring all four sessions) and is skipped (exit 0) without
Docker. Password, 2FA and changed-host-key prompts, remote shell integration (`.auto` still
behaves as `.off`, so a remote cwd exists only when the remote shell sends OSC 7) and macOS/Windows
are unverified.

TASK-44 is complete on Linux. Remote: connect (`remote.connect`) lists concrete `Host` aliases
from `~/.ssh/config` and its `Include` files, read one level deep through a Local context and
never reading key files, plus `remote.profile = <name> = <[user@]host[:port]>` profiles
(repeatable, at most 32), the `remote.recent` destinations (at most 10, rewritten through
`config.writeDocumentValue`), and "Enter user@host…"; this is the one palette choice step with a
fuzzy filter field (`palette.filter`). The ad hoc path is validated by `config.parseDestination`
(no leading `-`, no whitespace, optional port) and is followed by a Save as profile step.
Connecting opens an SSH workspace named after the alias, profile or host, at the remote home. The
grammar is in `docs/config.md`.

TASK-45 is complete on Linux. In an SSH workspace the scratchpad is a remote login shell started
over the shared master once connected. It stays hidden until shown, survives hide and show, and
`scratchpad.restart` replaces it over the same master. New tabs and panes snapshot the
originating session's remote OSC 7 cwd, which is believed because each SSH terminal accepts the
remote host's own name, and the context's session script does the remote `cd`. After a reconnect
the scratchpad is restored in place: same id, a fresh shell in its last remote cwd.

TASK-5 is complete: CI run 37715423153 passed `zig fmt --check`, `zig build` and `zig build test`
on ubuntu-latest (904 tests), macos-latest (892) and windows-latest (848, with the platform
skips), and a started matrix is never cancelled by a later push (only the newest push queues;
75-minute job and 40-minute test timeouts; per-binary diagnostics with a 240 s alarm on a failed
non-Linux leg). On a Windows host `build.zig` defaults to an explicit `<arch>-windows-gnu` target
with the native CPU, because Zig 0.16's fully native Windows target fails every C source in the
tree. The macOS PTY ioctl numbers (TIOCSWINSZ `0x80087467`, TIOCSCTTY `0x20007461`, `c_ulong`
requests), `O_NONBLOCK` (`0x4`) and the driver transport's and control server's stop (Darwin's
`shutdown` does not wake `accept`, so both connect once to their own endpoint) are fixed; the
Codex daemon socket sets close-on-exec with `fcntl` on Darwin because raw `socket(2)` rejects
Zig's shim `SOCK.CLOEXEC`; the agent layer asks the OS about descriptors only through
`agent/poll.zig` (poll(2) on POSIX, PeekNamedPipe on Windows pipes); backlog files with CRLF line
endings parse as LF and the fixtures are pinned to LF; a Local context's polling watch (the
backend off Linux) rescans once a second and tests pass 0 through
`ExecutionContext.localWithWatchInterval`; OS-dependent test expectations name their platform.
On Windows the Claude Code relay tests and the OpenCode TCP test skip: Zig 0.16 has no timed
socket receive there, so the OpenCode adapter has no Windows read path yet. The term editor test
runs vim with `-n` because killed test editors left unnamed-buffer swap files in `/tmp` until vim
refused to start with "E326: Too many swap files found".

TASK-57 is complete on Linux. `agent.view` (Ctrl+Shift+A / Cmd+Shift+A, an app default beside
the notifications chord, and palette "Agent: toggle view") replaces an agent pane's terminal with
an opaque `Surface` `agent.view.<agent id>` whose rows are built from the agent's structured
events using only `Text` and `InteractiveText`: messages start with `you ›`, the harness name
(`claude ›`) or `system ›` and wrap at the pane width (the one place UI text wraps, because a
transcript is content); tool uses read `⚙ <tool> <summary>`; `↳ path:line` references
(`agent.view.<a>.ref.<seq>`) open `vi +<line> -- <path>` through the workspace ExecutionContext
like a terminal file reference, resolving relative paths against the agent session's cwd;
permission requests show one `InteractiveText` per harness decision
(`agent.view.<a>.perm.<request>.<decision>`), answered by click or by Tab/Left/Right and Enter,
queued on the runner and sent by its worker (the adapter's one caller), after which the row shows
the outcome (`...perm.<request>.outcome`) instead of its controls; subagents, notifications, state
changes and the exit are dim lines. Each `app_agents.Runner` owns an `agent_view.View`: a log of
at most 4,096 events or 4 MiB filled as the owner thread drains events, plus rows rebuilt only
when the log or the width changes. Up/Down/PageUp/PageDown/Home/End and the wheel scroll it, and
it follows new events while at the bottom. A drag or Shift+arrows selects across rows, painted as
selection-background runs; `clipboard.copy` copies newline-joined text; `search.open` searches
the view's rows (literal only) with the usual field and `search.match.*` highlights. Other keys
and text over the view reach nobody, except Ctrl+C without a view selection, which still
interrupts the agent; the terminal keeps running underneath. The deterministic Linux
`--agent-view-test` and the sixteenth scenario `agent-view` cover it through real PTYs and SDL
events with the fake adapter. Answers were proved against the fake only; native macOS and
Windows behaviour is unverified.

TASK-58 is complete on Linux. `agents.open` (Ctrl+Shift+G, Cmd+Shift+G on macOS; palette
"Agents") opens a modal `Surface` `agents.dialog` listing every agent from the registry across
workspaces, never the scratchpad: one `InteractiveText` row `agents.row.<agent id>` reading
`<glyph> <harness>  <workspace> › <tab>  <task>  <state>  <age>` (the task column is TASK-64's
slot, `–` for now), sorted in sidebar order and rebuilt from the registry every frame so states
and ages are live. Up/Down/Tab/Home/End move the highlight; every action has a key and a clickable
control dispatching `agents.activate`: focus (Enter or a click on the row closes the manager and
shows the agent's workspace, tab and pane), stop (`s` or `.stop`, hangs up an owned agent's PTY;
refused for observed agents with a status line), restart (`r` or `.restart`, restarts an exited or
failed owned agent in the same tab with the same harness, cwd and prompt under a new agent id via
`Runtime.replaceRunner`), message (`m` or `.message`, an inline `Input` `agents.input` whose text is
queued with `Runner.sendMessage` into the same worker ring as permission answers and handed to
`adapter.sendInput`; "unsupported" when the capability is off), and new (`n` or `agents.new`, then
`agents.new.harness.<n>`, `agents.new.workspace.<n>`, an optional prompt and `agents.new.launch`).
The manager is modal like the settings view, and Escape closes it or goes back a step. The
deterministic Linux `--agent-manager-test` covers two workspaces and two fake agents through real
PTYs and SDL events; the seventeenth scenario `agent-manager` opens it by chord and clicks a row.
Ages refresh only on redraws; a real harness's `sendInput` and macOS/Windows are unverified.

TASK-67 adds `zig build bench` (ReleaseSafe by default; four benchmark processes run by
`bench/runner.zig`: throughput through `term` alone and with grid frames at the `FramePacer`
cadence, frame time for 1/4/9 panes at 1920x1080 scale 1 and 2, idle-session memory with a full
scrollback, and `conduit-test` launch-to-prompt startup) and `zig build bench-check`, which
enforces `bench/budgets.zig`; the method, reference numbers (Ryzen 7 5700G, llvmpipe, indicative
GPU numbers) and budgets are in `docs/performance.md`. Profiling found the glyph atlas scanning
every slot per lookup and its allocator narrowing free columns, which evicted and even failed CJK
glyphs at scale 2 with most of the atlas free; the atlas now has a key index and cuts along the
shorter leftover (CJK full frame 7.6 → 5.0 ms; 1,800 CJK glyphs at scale 2 into a 1024² atlas
went from 738 failed insertions to 1). A workspace test floods 64 MiB through a real PTY while
typing a sentinel every 100 ms and proves every sentinel arrives in order with the allocator peak
under 1 MiB and RSS growth under 32 MiB, and the `output-flood` e2e scenario types a command
during its flood. `bench-check` is not yet in CI (hosted runners are not the reference machine).
Follow-ups noted for `app`: a 2048² atlas at scale ≥ 1.5, a driver wake when a `Load` finishes
instead of waiting for the 16 ms poll, and region-only atlas uploads.

TASK-63 is complete on Linux. `backlog.open` (Ctrl+Shift+K on Linux/Windows, Cmd+Shift+K on
macOS, because Ctrl+Shift+B is the sidebar toggle; palette "Backlog") toggles a per-workspace
view that covers the active tab's panes with an opaque `Surface` `backlog.view` over the
workspace's Backlog.md project: `<focused session's OSC 7 cwd>/backlog`, else the workspace
directory's, read through the workspace ExecutionContext and watched. Local workspaces only for
now (loads and polls run on the owner thread; another context shows a problem row); a missing
directory shows `no backlog/ here`. The model is in `src/backlog_view.zig` (`Board`, `State`,
`detailRows`, `parseElement`, `CliJob`, `Panel`). The board has a column per configured status
(`backlog.column.<n>`) of `InteractiveText` cards `backlog.task.<id>`, each with a small muted
`.meta` row; list mode (`l`/`b`, `backlog.mode.list`/`.board`) shows every active task in ordinal
order with its status. Arrows, Home/End, PageUp/PageDown and the wheel move and scroll; hover
appears only after real pointer motion; Escape or `backlog.close` closes. Enter or a click on a
card opens the modal detail `backlog.detail.<id>` with the task's fields, description, criteria
(`.ac.<n>`) and notes; the status (`s`, Enter or a click on `.status`) cycles through the
configured statuses and a criterion toggles, both through `backlog.Cli` on a worker with a
bounded queue of 4, the view reloads the rewritten file through `Project.poll`, CLI errors appear
in `backlog.message`, and `▶ open in vi` (`v`, `.raw`) opens the markdown through
`openEditorTab`. Keys the view does not use still reach their bindings, never the hidden
terminal; task text is only displayed. `--backlog-test` drives a copied
`test/fixtures/backlog/valid` and a fake `backlog` CLI through real SDL events, and the eighteenth
scenario `backlog-board` opens the view by chord, clicks a card and moves the task with a stand-in
CLI that only a driven run accepts (`CONDUIT_TEST_BACKLOG_CLI`, never inherited by children). The
board and detail frames were inspected. The real `backlog` CLI was never run by a check; remote
backlogs and macOS/Windows are unverified.

TASK-64 is complete on Linux. The detail's `▶ start agent` (`a`, `.agent`) lists the
`agent.launch` harnesses (`.harness.<n>`) and starts the chosen one through `launchAgentWith` in
the project directory with the initial prompt `backlog.taskPrompt` (`TASK-N: <title>`, the
description and `Acceptance criteria:` items, controls stripped, at most 16 KiB, cut with a
marker). `LaunchRequest.task_id` is kept on the `app_agents.Runner` (`taskId()`) across a manager
restart; cards, list rows and the detail show that agent's glyph, harness and state live
(semantic `backlog.task.<id>.agent.<state>`), and the agent manager's task column names the
task. Changes an agent makes through the backlog CLI appear through the same watch.

TASK-16 is complete on the hosted Windows runner. The ConPTY backend hands `CreatePseudoConsole`
the read end of an anonymous input pipe (Conduit keeps the write end) and the write-only client
end of a one-instance, remote-rejecting named output pipe; Conduit reads its server end with
overlapped IO so the `stop` event can wake the read thread. Conduit closes its copies of the
console's ends at once, and children get `STARTF_USESTDHANDLES` with null handles so a Conduit
with redirected stdio cannot hand them its own handles. An exit-watcher thread closes the
pseudoconsole when the child's process handle signals, under an SRW lock shared with resize; the
read thread drains to `BROKEN_PIPE` before publishing the exit code, so a program's last output is
never lost; `destroy` joins both threads and closes Conduit's output end before
`ClosePseudoConsole`, which avoids the pre-24H2 deadlock. CI run 37706523144 on windows-latest
(build 26100) passes every ConPTY test: cmd.exe round trip, PowerShell-observed resize 80x24 to
100x40, exit code, final output, kill, and a `GetProcessHandleCount` release check. The Windows
leg still fails outside `pty` (agent modules use `std.posix.pollfd`; backlog CRLF checkout and
live watch), and the macOS leg times out in the agent codex websocket test and fails the tmux
keys, `/private/tmp` and backlog watch tests; closing those is what remains of TASK-5.

TASK-60 is complete on Linux. When `control.enabled` resolves on (on in Debug, off in release;
`--control` / `--no-control` override it for one run), the app runs the token-scoped control
endpoint at `$XDG_RUNTIME_DIR/conduit/r-<hex>.sock` (fallback `/tmp/conduit-<uid>`); built-in
checks other than `--control-test` never start it. Local human and agent terminals get
`CONDUIT_CONTROL_ENDPOINT`, `CONDUIT_CONTROL_TOKEN` and `CONDUIT_CONTROL_SESSION` per spawn; the
scratchpad, SSH connection terminals and remote children never do, and an enclosing Conduit's are
never inherited. `App` handles `tab.open`, `pane.split`, `view.agent`, `view.backlog`, `tab.status`
(sidebar `! busy api`), `notify` and `agent.event` (`Runtime.ingestControlEvent` appends to the
adapter's event line file) through the workspace's ExecutionContext. Spawning requests reply when
the child starts; requests that would move focus under held input or a modal wait up to 4 s, then
reply `Unavailable`. Claude Code agents with a local sink get hooks that run `conduit control
agent.event --event=<Hook>`, falling back to `CONDUIT_AGENT_SINK`; remote sinks keep the relay.
`conduit control <method> [json]` is the shell and hook client. The deterministic Linux
`--control-test` covers every method from real tab shells, the scratchpad's exclusion and a
refused stolen token; the nineteenth scenario `control-api` types `conduit control tab.open`,
`pane.split` and `tab.status` into the terminal and switches tabs by mouse. `conduit-test` does
not forward control requests (tokens exist only inside the app; documented in
`docs/control-api.md`). Windows has no control transport.

TASK-66 is complete on Linux. `conduit .`/`<dir>`, `conduit ssh <host>`, `conduit workspace open
<name>` and `conduit agent <harness> [prompt...]` forward `instance.*` requests. Inside a Conduit
terminal they go to that terminal's own endpoint, so `agent` launches in that workspace; otherwise
they go to the per-user `$XDG_RUNTIME_DIR/conduit/instance.sock`, whose token is written 0600 to
`<state dir>/instance.token` at startup and removed at exit, and the instance token accepts only
`ping` and `instance.*`. When nothing answers, the command starts Conduit and runs at startup;
plain `conduit` always starts a new window. `conduit-test launch` now sets `XDG_RUNTIME_DIR` to the
run directory, so test runs never reach the person's instance. `--control-test` proves all four
commands as separate processes against a private instance endpoint (each exits 0 in under 100 ms)
and that a bad token exits non-zero. macOS is unverified; Windows always starts a new window.

TASK-65 is complete on Linux. `app` persists through `Persistence`: a plain run with
`restore.enabled` on (default) saves to `state.statePath` two seconds after `layoutFingerprint`
(registry layout and tracked cwds, theme, window size, scratchpad presentations) last changed and
again in `deinit`, encoding on the owner thread and writing with `state.save` on a worker. Checks,
`--command` runs and driven runs never save or restore. On launch, unless `--no-restore`,
`restoreAtLaunch` loads the file; a corrupt, unreadable or newer one is quarantined to
`state.json.corrupt-<unix>` with the status line `previous state was unreadable; starting clean`.
`executeRestore` replays the plan before anything spawns: empty workspaces, then
`Workspace.applyRestoreStep` per tab step, a renderer and a `restore_queue` entry per session, the
saved selection, and the default workspace closed. `driveRestoreQueues` starts one shell per
workspace slot in its saved directory, falling back to the workspace's with a status line when it
is gone. SSH workspaces come back with target and `-o` options but no master: the view reads
`ssh <host> ─ saved session; press Enter or click reconnect to connect`, Enter or `reconnect`
connects, then the queue starts the remote shells. The saved theme applies while the settings
file names none, and the size while no `--width`/`--height` is given; position and maximized
state are not applied because `platform` has no placement calls yet. The deterministic
`--restore-test` runs two apps on one window and proves workspaces, tab names, pane bounds and
ratios, focus, zoom, selection, theme, `pwd` per pane, the saved SSH view, and clean starts for
corrupt and newer files; its restored frame was inspected. Restore has no e2e scenario because a
scenario is one launch; the restored-SSH reconnect path is covered only by `--ssh-test`'s
reconnect machinery.

TASK-68 is complete on Linux. `App.a11y` is started after the window with
`DBUS_SESSION_BUS_ADDRESS`, `accessibility.enabled` (default true) and a driver-wake waker; checks
and driven runs start none. `composeUiTree` publishes after `endFrame`; `poll` maps `activate` to
a real `postDriverClick` and `focus` to `ui_tree.focus`; `deinit` stops it first.
`accessibility.check` (private `dbus-daemon`, stand-in registry, bus client) backs both the module
test and the deterministic `--a11y-test`, which walks the sidebar, palette and settings over
D-Bus, runs Settings by `DoAction`, and moves focus by `GrabFocus`; it is skipped without
`dbus-daemon`. The module itself (`src/accessibility.zig`, `src/accessibility/{dbus,atspi,
snapshot}.zig`, no C dependency) was also verified against at-spi2-core and libatspi in an
`ubuntu:26.04` container. Terminal contents are not exposed as text; macOS NSAccessibility and
Windows UI Automation are planned in `docs/accessibility.md`; no real screen reader was run.

TASK-67's app follow-ups landed: `Load` jobs post a driver wake when done, the atlas is 2048²
from display scale 1.5 (`atlasSizeFor`, `App.atlas`), and debug logs `startup: window|fonts|theme|
first frame|first child after <ms>`. Launch-to-prompt median went 242 → 240 ms, within noise.
Region-only atlas uploads remain open.

TASK-61 is complete on Linux. An agent launched in an SSH workspace runs on the remote host
through the normal `agent.launch` flow. The workspace's detection worker resolves the remote
`ExecutionContext.stateDir` and Claude Code's remote config directory
(`claude_code.resolveConfigDir`); remote sinks live at `<remote state>/conduit/agents/<run>/<token16>`,
and `createRunner` refuses with `NoSinkRoot` until that is resolved. `Runner.prepare`, Claude's
hooks, Pi's `SinkTransport`, and the fake's steps and decisions all go through the runner's
`agent.SinkIo` (TASK-61 part one: `ExecutionContext.readFileAt`/`writeFile`/`makePrivateDir`/
`stateDir` with Local and SSH implementations, `agent/sink_io.zig` with 500 ms idle read
throttling for remote tails). A closed agent's remote sink is removed by a `Cleanup` worker (`rm
-rf --` through the context, guarded by `removableSinkPath`), and the run root is removed when the
workspace closes or the app exits (a bounded 5 s wait). Codex and OpenCode run remotely as plain
TUIs on the PTY baseline, labelled `(terminal only here)`; remote hooks keep the relay, and
`ingestControlEvent` refuses remote agents. `--ssh-test` launches the fake remotely (its script
staged as a remote launch file) and proves the remote host, the remote sink and no local one,
glyphs, a notification, the agent view, a remote decision file, and cleanup at workspace close;
part one's Docker tests ran the real Claude relay remotely. A real remote Claude Code or Pi was
not run.

TASK-59 is complete on Linux. Each adapter publishes an `InstructionProfile`
(`agent.instructionProfile(harness)`). `src/agent_prompts.zig` discovers the profile's files
through the workspace ExecutionContext on a `Job` worker: project files up the tree, home files,
subagent `*.md` listings, and harness-owned settings; it adds the unexposed system prompt, the
launch prompt and the human's sent prompts as read-only rows with reasons. `agent.prompts`
(palette "Agent: prompts and instructions", or the `agent.view.<a>.prompts` row leading every
agent view) opens a modal `Surface` `agent.prompts.<a>` with `item.<n>` rows, `refresh`, a
preview, `apply`, a status line and a hint. Enter or a click opens `vi -- <path>` (or `vi -R` for
harness-owned files) in a new tab via `openEditorTab`, so an SSH workspace edits on its host, and
the list is re-read when the editor exits. Claude Code offers "restart with updated
instructions" through the manager's restart (`App.relaunchAgent`); other harnesses say edits
take effect on the next session. Discovery uses `~` paths, not `$CODEX_HOME`, `PI_CODING_AGENT_DIR`
or `CLAUDE_CONFIG_DIR`. `--agent-prompts-test` and the twentieth scenario `agent-prompts` cover
it; the frame was inspected.

TASK-48 is complete on a GitHub macos-14 arm64 runner (`.github/workflows/macos.yml`; release
dry run 37710508109 and, after the rebase, run 37717765398 green on every gating step). `zig
build bundle` stages `Conduit.app` (generated Info.plist, `assets/macos/AppIcon.icns`, fonts, shell
integration, licences). The bundle starts through Launch Services, passes `codesign --verify` (ad
hoc), and a 640x360 window at scale 2 draws a crisp 1280x720 frame; the runner's display itself is
1x, so a real Retina display is unverified. The macOS defaults are pinned to the user-guide table
by a unit test. `platform` takes Command+W off SDL's Window ▸ Close menu item, which otherwise
closed the window as well as the tab. `macos.option_as_alt = false|true|left|right` (default
false) sets SDL's Option-as-Alt hint and marks composing Option keys, so `input` sends nothing and
the composed character arrives as text; real keystrokes on the runner proved ≈ once by default
and ESC x once with `true`. Font discovery reads every face of `.ttc`/`.otc` collections; DejaVu
from `~/Library/Fonts` and Menlo from `/System/Library/Fonts` load. TASK-15's last criterion is
met: Cmd+V from and Cmd+C to the system pasteboard pass on the runner; `--clipboard-test` cannot
run on macOS (the offscreen driver has no OpenGL there). TASK-69's macOS half adds `macos` and
`publish-macos` jobs to `release.yml`; the dmg is ad hoc signed, not notarized, until the
`MACOS_*` secrets exist, and minimum macOS is 14. On macOS, 13 built-in checks pass; `--tabs-test`,
`--panes-test`, `--palette-test`, `--workspaces-test`, `--search-test`, `--config-test` and
`--settings-test` still fail (spawned-child cwd checks under `/private/tmp`, Ctrl-chord capture,
search paging) and are reported, not gating; `window.fullscreen` and a settings row for the
Option setting are still to do.

TASK-49 is complete on the hosted Windows runner. `conduit.exe` embeds `assets/windows/conduit.manifest`
(per-monitor-v2 DPI awareness, UTF-8 code page, Windows 10/11 supportedOS, asInvoker) and the
icon from `conduit.rc`. `Window.create` sets a dark DWM title bar, and `setTitleBarDark` follows the
theme's background at startup and in `applyPalette`, logs the DPI awareness, and frees a console Windows created only for
this process. `font.discoverCatalog` lists fonts through DirectWrite and catalogues each file with
FreeType; without DirectWrite it walks `%WINDIR%\Fonts` and the per-user font directory. Every
Windows argument is copied out of the iterator's buffer, which `deinit` frees (before that fix
`--version` and every flag read freed memory). `.github/workflows/windows.yml` (run 37731052008)
proves on windows-latest, using Mesa llvmpipe as the OpenGL driver because the runner's GDI
OpenGL is 1.1, and Git's `sh` as `\bin\sh` for `--command` children: cmd.exe and PowerShell typed
and drawn at scale 1 and 1.5; Unicode text input; Ctrl+Shift+V/C through the Windows clipboard;
Consolas, Cascadia Mono and a per-user DejaVu Sans Mono; a live display-scale change from 100%
to 125% re-rendering at 800x450; and 14 gating built-in checks. `--clipboard-test` (needs EGL),
`--ime-test` (an MSYS child cannot enter raw mode), `--links-test` (no `vi.exe`) and
`--panes-test`/`--search-test` were reported only until the ConPTY follow-up below. The smoke opens cmd.exe through
New tab with profile because pwsh is the default shell since TASK-46. Local process runs use `create_no_window`, and
`build.zig` translates the C header seams as Debug on Windows because MinGW's `_FORTIFY_SOURCE`
breaks translate-c at ReleaseSafe. A real GPU driver, a second monitor and real IME composition
are unverified.

TASK-47 is complete on the hosted Windows runner. `workspace.wsl.WslContext` runs every process
through `wsl.exe -d <distro> --cd ~ -e /bin/sh -c <script>`: sessions under ConPTY, and files,
run, stateDir and watch over pipes with the SSH helper scripts; distributions come from HKCU
`Lxss` or `wsl --list --quiet` (UTF-16LE decoded), and `link.WslPaths` translates drive and
`\\wsl.localhost` paths using the mount root learned from `wslpath`. On Windows, Remote: connect
lists each registered distribution as `<name>  WSL`, read from the registry so no process runs
on the UI thread. Choosing one opens a workspace named after the distribution, backed by
`WslContext`, with no connection phase: its first tab, every pane and its scratchpad run the
distribution's login shell with the remote overlay (SSH and WSL share `processFor`'s remote
path), starting in its home directory, and the first spawn worker learns the drive mount root
from `wslpath`. A ctrl-clicked Windows file reference (`C:\x:12`, `\\wsl.localhost\<distro>\x`)
opens `vi +12 -- /mnt/c/x` inside the distribution. A driven run can name a `wsl.exe` stand-in
with `CONDUIT_TEST_WSL_LAUNCHER`, which is ignored without `--test-driver` and never inherited by
children; the stand-in test runs on Linux and Windows. windows.yml installs Ubuntu under WSL2 and
gates on `windows-wsl-check.sh`, which drives Remote: connect, the first tab, a split pane, the
scratchpad and the file reference through `conduit-test`; run 37737271998 passed it and its
screenshots were inspected. Still open: WSL workspaces are not saved or restored
(`createRestoredPresentation` refuses `.wsl`); OSC 7 from a WSL shell is accepted only as
`localhost`, so cwd inheritance for splits depends on the shell; a non-root default user and
distributions other than Ubuntu have not been tried.

TASK-69 (Windows): `zig build portable` and `windows-package.sh` produce
`conduit-<v>-windows-x86_64.zip` plus `.sha256`, verified on the runner (checksum, fresh unpack,
payload, forward-slash entry names, embedded manifest, `--version` from the unpacked copy).
`release.yml`'s `windows`/`publish-windows` jobs upload them beside the Linux release; nothing
waits for them. The ReleaseSafe dry run 37729065903 passed. The zip is unsigned and there is no
installer; `docs/release.md` says why.

TASK-79 phase one is on main (decision-12 records the editor pane's hosting strategy: X11
reparents the VSCodium window into a container child that tracks the pane; Wayland keeps a
separate window behind a placeholder pane; macOS and Windows native hosting are later work;
VSCodium is detected, never bundled or installed, and launched through the workspace
ExecutionContext with a per-workspace `--user-data-dir` under the state directory).
`src/editor.zig` (depends only on `workspace`) has `detect` (`editor.command`, then `codium`,
through `ExecutionContext.run`), `userDataDir`/`seedSettings` (the seeded window title carries
the marker `conduit-editor-<id>`), lexical `resolvePath`, `checkTarget`, `buildLaunch`
(`--new-window`/`--reuse-window`, `--goto p:l:c`, `--diff`, `-r`), the per-workspace `Editor`
model that reuses one editor pane, and `elementId` (`workspace.<k>.pane.<n>.editor`). The
control protocol has `editor.open {path, line?, column?, split?}`, `editor.goto`, `editor.diff
{left, right}`, `editor.reveal {path}` and `editor.close` with bounded validated params and the
faults `EditorNotInstalled` (-32005, install hint in `error.data.hint`) and
`EditorRemoteUnsupported` (-32006, names the vi fallback); `conduit-test editor-open|editor-goto`
and the MCP tools `editor_open`/`editor_goto` mirror them; `docs/control-api.md` has per-harness
snippets (unrun against live harnesses). `platform.Window.embedForeignWindow(match, rect)`,
`moveEmbedded`, `showEmbedded`, `closeEmbedded` and `unembed` host a foreign X11 window through
a `dlopen`ed `libX11.so.6` on a private display connection (no link-time X11 dependency; tested
under Xvfb with a real `xlogo`), and answer `error.Unsupported` elsewhere. The app still answers
`Unavailable` to every editor request until phase two.

TASK-79 phase two is complete on Linux/X11. Each workspace presentation owns an
`EditorPresentation`: the `editor.Editor` model, availability from a detection worker (run when
the workspace becomes active and when `editor.command` changes; built-in checks other than
`--editor-test` never detect), and one launch worker that seeds the user-data-dir under
`<state>/conduit/editor/<id>` and runs the `buildLaunch` argv through the workspace
ExecutionContext. The editor pane is an ordinary layout leaf whose `human_terminal` session never
gets a child, so focus, resize, zoom and close are the pane chords (`childGone` ignores the
placeholder). An opaque `Surface` `workspace.<k>.pane.<n>.editor` carries the status line, a
`.status` Text and a clickable `.close`, and an `editor.placeholder` line shows while VSCodium's
window is not hosted. Escape over the focused pane, `× close`, `Editor: close` and
`editor.close` give the space back. `performEditor` is the single path for
`editor.open/goto/diff/reveal/close` from the control API, the driver's `editor_open`/`editor_goto`
(which reply `{}`; `testdriver.Result` has no opened variant yet), the palette's `Editor: open
file…` (`path[:line[:col]]`, shown only where VSCodium was found; in SSH workspaces it opens `vi`
in a new tab and says why) and the context menu's `open in editor` over a file reference (the
menu is 18 columns wide now). Paths resolve against the requesting terminal's OSC 7 cwd and are
checked with a local `stat` (the editor is Local-only); later requests reuse the pane; harness
requests keep focus on their terminal; a request during a running launch gets `wait`. On X11 the
window is found by its title marker (for up to 20 s), hosted over the pane below its header,
moved on every layout change and hidden while the pane is not presented or covered; a closed
window stays hidden in its container until its client has gone, so it is never re-hosted, and a
window found mid-frame recomposes that frame. The settings view has an Editor group with
`editor.command`. The deterministic `--editor-test` (in the CI Xvfb block, which now installs
`x11-apps` for `xlogo`) and the twenty-second scenario `editor-pane` use a stand-in `codium` that
maps a real `xlogo` window; they cover the not-installed path (no palette row, `conduit control
editor.open` exits non-zero with the vscodium.com hint), palette by keyboard, context menu by
mouse, every control method typed into a real tab shell, reuse, resize, zoom, Escape and click
close; X root captures of a visible run show the xlogo hosted beside the terminal pane. Real
VSCodium 1.135.06055 was then verified by hand under Xvfb (the user approved a private tarball
install under `.zig-cache/vscodium`, no system change): a `conduit-test launch --visible` run,
`conduit control editor.open` from a tab shell, the window found by its title marker and hosted
over the pane 1.6 s after the launch, the real five-line file shown, `editor.goto` moving the
cursor to line 4 and the header to `notes.txt:4:1`, XTest typing inserted at that cursor, and
`editor.close` ending the process; root captures were inspected. Two findings: the tarball's
`chrome-sandbox` is not setuid and this kernel restricts unprivileged user namespaces, so a plain
`codium` dies with the SUID sandbox error and needs either a package-manager install or an
`editor.command` wrapper adding `--no-sandbox`; and a relative path from a shell without OSC 7
resolves against the workspace directory, where VSCodium opens a new empty file while `goto`
answers NotFound. VSCodium shows its Restricted Mode banner in the fresh user-data-dir. Known
limits: session restore saves the editor pane as a terminal pane; quitting leaves a hosted editor
window on the desktop; closing the last tab's only editor pane quits. The Wayland fallback and
macOS/Windows hosting are unverified.

TASK-49 ConPTY follow-up: `--panes-test` and `--search-test` stopped on Windows with `conduit
stopped: Closed` because their fixed child, a `while IFS= read -r line` loop under Git for
Windows' `sh` (bash in POSIX mode), ends when MSYS turns a pseudoconsole resize into SIGWINCH and
`read` returns 128; the pane's shell exits 0, the exit watcher closes its pseudoconsole, and owed
input or the next layout resize met a closed terminal. It was not handle confusion between
consoles: a `pty` test destroys one of two ConPTYs and the other keeps taking input and resizes.
The ConPTY backend now takes a resize of a terminal whose child has ended without error, as a
POSIX master does (a test failed first on windows-latest with `Closed`); owed input to a closed
terminal is dropped with a debug line instead of stopping the app; and both fixtures run `trap ''
WINCH`. With that, both checks get past the resize but fail on something else on windows-latest
(run 37773403721): `--panes-test` at its pane-close confirmation steps and `--search-test` with
`OutOfMemory` from the engine's search reload of the active area, so they stay reported rather
than gating until each has had its own runner iteration.

TASK-76 follow-ups (2026-10-08): the branch row had two ways to stay empty on real machines. On
Windows the shell reports `/C:/Users/...` and every tracked-cwd consumer (the git lookup, the
Backlog.md view, prompt discovery) handed that form to the Local context, which cannot open it;
`LocalExecutionContext` now maps a leading `/X:/` to `X:/` (`trackedToNative`, unit-tested
everywhere, exercised against `C:\Windows` on the Windows matrix leg). On any platform a `.zshrc`
that assigns `precmd_functions=(...)` outright removed Conduit's zsh hooks, because they were
installed from `.zshenv` before the user's rc; the zsh integration now keeps `ZDOTDIR` on its own
directory through startup with `.zprofile`, `.zshrc` and `.zlogin` wrappers that source the user's
files with the user's ZDOTDIR in place, load `conduit.zsh` after the user's `.zshrc`, and restore
ZDOTDIR for good at the end (non-interactive shells restore it at once). A real-zsh test with such
an rc fails on the old scripts; login, non-login, non-interactive and user-ZDOTDIR startups were
traced by hand. Bash was already robust (it sources the user's rc first, then prepends its hook).

TASK-80 is complete on Linux. Every agent record has a row of its own in the sidebar, nested one
column under the tab it runs in, after the tab's branch row, drawn in the normal face so it is as
tall as the tab row (the user's direction). It is an `InteractiveText`
`workspace.<k>.tab.<n>.agent-row.<agent id>` (role `agent_row`, semantic-only action `agent.row`)
reading `<glyph> <harness> <state>`: `· … idle`, `▸ … working`, `? … input`, `! … permission`,
`✓ … done`, `× … errored`, with the harness as its tag up to the first `_` (`claude`, `codex`,
`pi`, `opencode`; `fake` for the scripted fake). The row is rebuilt from the registry every frame,
so it changes in the frame the tab glyph does. Observed (hand-started) agents get one as soon as
they are recognised, and a finished agent keeps its row until its record is forgotten. A click, or
Enter after reaching it with the sidebar keys (Up/Down now step between workspace, tab and agent
rows when a tab or agent row is focused, instead of falling through to the terminal), shows the
agent's workspace, tab and pane and opens its agent view; activating it again while that view
shows closes it. A drop on an agent row targets its tab, and the rows count against the list limit
like branch rows. `sidebar.agents = false` (hot-reloaded; a toggle in the settings view's Agents
group) keeps only the glyphs, and the `<row>.agent.<state>` glyph elements are unchanged. The
fake's script gained a sixth step ending in waiting for input. `--agent-test` covers launched and
observed rows through every state, mouse and keyboard activation, drag, the list limit and the
switch; the agent-notifications scenario clicks and keys both a launched and an observed agent's
row, and its frames were inspected. On this box a real hand-started `claude` showed `· claude
idle`, and earlier the same day real Claude Code was verified launched (working → done, transcript
and reply in the view, a notification) and hand-started (observed within 3 s, a turn, done on
`/exit`), with hand-started `codex` and `omp` observed too. macOS and Windows are unverified.

TASK-46 is complete. `config` reads repeatable `profile = <name> = <command> [arguments...]`
lines (shell-style quoting, literal backslashes outside `\"`/`\\`), `profile.<name>.env|cwd|login`
attributes in any order, and `shell = <name>` for the default (32 profiles, 32 arguments and 32
variables at most). Built-in profiles are detected through the workspace context: `login` (the
user's `$SHELL`, else passwd, else `/bin/sh`, as a login shell) on POSIX; `pwsh`, `powershell` and
`cmd` (whichever exist, the first being the default and now the default local shell) on Windows;
the remote login shell in SSH workspaces. The palette's New tab with profile and Split with
profile list them; the chosen argv, variables and cwd flow through `ChildSpec.buildProfile` and
the workspace `ExecutionContext`, and `tab.new`, `pane.split` and an interactive run's first tab
follow `shell`. Login uses `-l` (`--login` for bash, whose integration script now replays the
login startup files because POSIX-mode bash reads only `ENV`).
`assets/shell-integration/powershell/conduit.ps1` emits OSC 7 (`file://localhost/C%3A/...`,
mapped back to `C:\...` for Windows spawns) and OSC 133 A/B/C/D, and is injected with `-NoExit
-Command` dot-sourcing a script block after the user's profile, so no execution policy blocks it.
The settings view has a Shells group. The deterministic Linux `--profiles-test` and the
twenty-first scenario `profile-tab` cover keyboard and mouse paths. CI runs 37720295115 and
37721316005 proved on the hosted Windows runner that PowerShell 7 under ConPTY delivers OSC 7
after `cd`, OSC 133 marks, SGR red (`palette(9)`) and a 100x40 resize seen by
`$Host.UI.RawUI.WindowSize`; Windows PowerShell 5.1 and a real remote profile spawn are
unverified.

TASK-74 replaced the sidebar footer. The thirteen dim per-action control rows (`workspaces.*`,
`tabs.*`, `panes.*`) are gone; the footer is now a centred clickable `sidebar.palette` hint reading
`Palette  <chord>` (the live `palette.open` binding formatted for the profile: Ctrl+Shift+P on
Linux/Windows, Cmd+Shift+P on macOS) that dispatches `palette.open`, with the stamped version
(`sidebar.version`, `v<semver>` or `v0.0.0-dev`) centred on the row beneath it. A label wider than
the sidebar clips from the first column and never wraps. The transient `workspace.status` line, when
present, sits above the hint. The palette is the mouse path to every command the controls listed,
so the `--tabs-test`, `--panes-test` and `--workspaces-test` mouse paths click the hint and then a
`palette.action.<n>` (and `palette.choice.<n>.<c>`) row, and their modal-isolation checks click the
hint behind the modal and assert the palette stayed closed. The palette dialog no longer has a
fixed 64-column width: `openPalette` measures the widest row it can show (title, every
palette-visible label plus its chords, every prompt and choice label, in display cells) and the
dialog is that width plus four, at least 40 columns, clamped to the window; rows clip only when the
window itself is too narrow. The ninth scripted scenario `sidebar-palette` clicks the hint through
`conduit-test click` and waits for `palette.dialog` and the focused `palette.query`.

TASK-36 is complete. Command+F on macOS or Ctrl+Shift+F on Linux/Windows opens an inline semantic
`Input`; named actions and clickable controls provide next/previous navigation plus case and regex
toggles. Literal and regex scans are bounded and incremental across retained scrollback, with
viewport reveal, semantic match decorations, adjacent 128-result pages and generation-based
resynchronisation after output or resize. Regex uses the exact Oniguruma 6.9.9 source already
pinned by Ghostty, built statically with bounded pattern size, nesting, retry and match-stack
limits; its license is installed with Conduit and no distro `libonig` runtime is required. The
deterministic Linux `--search-test` exercises keyboard, palette and mouse paths, malformed-regex
recovery, real PTY resynchronisation and more-than-128-match paging through SDL; its final 640x360
frame was visually inspected.

TASK-50 is complete. X11 runs report the X11 backend, and Weston and Sway headless sessions run
SDL's Wayland backend over the same SDL/OpenGL path. An isolated `zig build --prefix` stages the
binary, fallback font, shell integration, licenses, desktop entry and hicolor PNG icons at their
standard freedesktop paths, and the installed payload passes desktop-file validation in CI. The
hosted Linux gate supplies the external evidence: `check-sway-fractional.sh` runs Sway 1.9
headless (GLES2 where a DRM render node exists, pixman otherwise, because hosted runners have no
`/dev/dri`) at compositor scale 1.25 and Conduit reports an 800x450 surface for 640x360 logical
geometry with a crisp frame; `check-ibus-hangul.sh` runs a real `ibus-daemon` with `ibus-hangul` as the only preloaded
global engine started in Hangul mode (its default is Latin), all written to gsettings before the
daemon starts because changing them afterwards races the first context; SDL 3.4's X11 backend
reaches input methods only through XIM (its D-Bus IBus client serves Wayland), so `XMODIFIERS`
must name IBus. The script starts the XIM bridge `ibus-x11` itself once the daemon answers an
engine query and waits for the root window's `XIM_SERVERS` to name it, because the bridge the
daemon spawns with `--xim` can race the daemon's own bus and die with "Not connected to the ibus
bus" (release gate run 37642511355); its stdout/stderr are retained with the check's artifacts. XTest Dubeolsik keys then produce a semantic preedit and exactly one committed
`한글`;
`check-x11-primary.sh` proves PRIMARY interoperability with `xclip`. Neither IBus nor Sway is
installed on the dev box, so those checks are reproduced locally in an `ubuntu:24.04` container.
The bundled fallback face has no Hangul glyphs, so the preedit cell renders as a missing-glyph box
until TASK-39.

- `CONDUIT.md` — the product specification. Source of truth for what the product does.
- `conversation.md` — the original design conversation. Kept as history; CONDUIT.md supersedes it.
- `backlog/` — the plan: 9 milestones (M0–M8), 70 tasks with acceptance criteria and dependencies.
- Sections below marked **(planned)** describe commands and layout that tasks will create. If a
  planned command does not exist yet, it is not broken; its task has not been done. When you
  build one of these, update this file in the same change so it stays true.

## Where truth lives

| Question | Source |
|---|---|
| What should the product do? | `CONDUIT.md` |
| What should I work on, and what counts as done? | Backlog tasks and their acceptance criteria |
| Why was a technical choice made? | Backlog decisions (`backlog decision ...`) |
| How is the code organised? | `docs/architecture.md` |

Do not invent product behaviour. If a task and the spec disagree, or something is unspecified
and the choice is not obvious, stop and ask the user rather than guessing.

## Toolchain and environment

- **Zig 0.16.0**, pinned, and confirmed by TASK-2: it is the `.minimum_zig_version` declared in the
  pinned Ghostty tree. Do not upgrade Zig or the Ghostty dependency casually; a version bump is its
  own task and decision record.
- **Ghostty `5dc28bb8eebaf57a6c793a406bfea8c632d4fa94`**, pinned, consumed as the **Zig module
  `ghostty-vt`** (root `src/lib_vt.zig`). There is no `libghostty-vt/` directory; that name only
  refers to built artifacts. Wire it up as `b.dependency("ghostty", .{})` plus
  `addImport("ghostty-vt", ghostty.module("ghostty-vt"))` — see `decision-1` and `doc-1` for the
  evidence, the API mapping with source lines, and the known `Style` formatting sharp edge under
  Zig 0.16. The macOS embedding library is explicitly not for external use; never depend on it.
  Ghostty is MIT: retain the copyright and permission notice in copies.
- Zig's standard library and build API change between releases. Do not write Zig from memory of
  older versions: check the installed std source (`zig env` shows `std_dir`) or let the compiler
  tell you. ZLS 0.16.0 is installed.
- The dev machine is Ubuntu, headless (no display session). Anything that opens a window must
  run under `xvfb-run -a ...` or the app's headless mode. GPU is software (llvmpipe), so do not
  draw performance conclusions from this machine.
- **SDL3 for window and input, OpenGL 3.3 core for GPU**, decided by TASK-3 and recorded in
  `decision-2`. SDL3 arrives through the `castholm/SDL` build package plus a thin extern seam
  Conduit owns; there is no maintained SDL3 Zig binding. `zopengl` is the OpenGL binding and
  builds on 0.16. GLFW + `zig-gamedev/zglfw` is the documented fallback. Every OS call stays behind
  `platform` and `render`. Full evidence, including the headless/FBO screenshot contract that
  TASK-7, TASK-21 and TASK-22 implement, is in `doc-2`.
- Installed for you: SDL3 and GLFW dev packages, fontconfig, freetype, harfbuzz, Wayland/X11 dev
  libs, Vulkan/GL, weston, xdotool, xclip, wl-clipboard, imagemagick, ripgrep, docker, and the
  `claude`, `codex` and `pi` CLIs. Test fonts: JetBrains Mono, Noto Color Emoji, Noto CJK, DejaVu.
- Zig 0.16 facts that have already cost time here: `std.Build.Step.TranslateC.create(...).createModule()`
  replaces `b.addTranslateC`; `std.zig.allocator` is gone and `main` takes `std.process.Init`;
  `glVertexAttribPointer`'s last argument is a byte offset into the bound buffer, not a pointer,
  and offset 0 must be passed as `null`; `glReadPixels` must precede `glfwSwapBuffers`.
- Never add a system dependency silently. If a task needs a new package or library, say so,
  and record it in the build docs.

## Architecture invariants

These came out of the design and are not up for renegotiation inside an unrelated task. Changing
one needs the user's agreement and a decision record.

1. **Two renderers, one surface.** The terminal engine (libghostty) and the terminal-styled UI
   renderer are separate and draw to a shared GPU surface. The UI is not ANSI text piped through
   the terminal.
2. **Four UI primitives.** All UI is built from `Text`, `InteractiveText`, `Surface` and
   `Input`. Do not add new widget kinds, buttons, icons or native GUI chrome. If something is
   actionable it is clickable text.
3. **One semantic tree.** Every UI element registers once (stable id, role, label, state,
   bounds, action). Rendering, mouse hit testing, keyboard focus, the test driver and
   accessibility all read that single tree. Never keep a second representation.
4. **Keyboard and mouse parity.** Anything doable with the mouse has a keyboard path, and every
   interactive element is clickable. Every command is a named action in the action registry,
   reachable from keybindings and the command palette.
5. **Everything spawns through the workspace's ExecutionContext** (Local, SSH, WSL). No feature
   may assume the local machine: no direct local process spawn, path or file read where the
   workspace could be remote.
6. **Sessions outlive their views.** A session owns its PTY and terminal state and keeps running
   when hidden. Hiding is never termination.
7. **The scratchpad belongs to the human.** One per workspace, started with the workspace,
   persistent. Agents and the control API can never own, target or take over it.
8. **Never steal terminal input.** Keys not bound by Conduit reach the terminal unmodified.
   Ctrl+C without a selection is always SIGINT.
9. **Harness-neutral agents.** Claude Code, Codex and Pi specifics live only inside their
   adapters, behind the common adapter interface. Nothing outside `agent/` may special-case a
   harness.
10. **Platform code stays behind interfaces.** OS-specific code lives in the platform, PTY and
    font-discovery backends. Shared modules contain no OS conditionals beyond selecting a backend.

## Module layout (planned, TASK-4)

`app`, `platform` (window, clipboard), `pty`, `term` (libghostty wrapper), `render`, `font`,
`ui` (four primitives, semantic tree), `input`, `workspace`, `session`, `config`, `theme`, `agent`,
`backlog`, `palette`, `testdriver`.
Dependencies point downward: `ui` and `workspace` may use `term` and `render`; `term`, `pty`
and `font` know nothing about workspaces, agents or UI.

## Coding standards

- Run `zig fmt` on everything. CI rejects unformatted code. Follow the Zig style guide:
  `TitleCase` types, `camelCase` functions, `snake_case` variables, fields and file names.
- **Memory:** pass allocators explicitly; no hidden global allocator. Every allocation has an
  obvious owner, and ownership transfer is stated in the doc comment. Pair acquisition with
  `defer`/`errdefer` on the next line. Use arenas for per-frame and per-request data.
- **Errors:** return errors, do not swallow them. No `catch unreachable` and no `catch {}`
  unless a comment proves why it cannot fail or why ignoring is correct. `unreachable` and
  asserts are for programmer invariants only, never for input from PTYs, files, the network,
  config or agent harnesses. Malformed external input must never crash the app.
- **Threads:** the render/UI thread never blocks on IO. PTY, SSH and harness IO run off-thread
  and hand results over through defined queues. Document which thread owns each piece of state.
- **Rendering:** render on demand when state is dirty. No busy loops, no per-frame heap
  allocation on the hot path.
- **Logging:** use scoped `std.log`. No stray `std.debug.print` in committed code. Never log
  terminal contents, clipboard data, credentials or prompts above debug level.
- **Comments:** explain why, not what. Public declarations get a doc comment. No commented-out
  code, and no TODO without a backlog task id.
- **Scope:** do what the task says. No drive-by refactors, speculative abstractions or new
  dependencies. Prefer the smallest change that meets the acceptance criteria, and match the
  style of the code around you.
- **User-facing text** is terse and terminal-like. Use box-drawing characters and glyphs, not
  emoji, in the UI.

## Testing standards

Four levels. Use the lowest level that can actually prove the behaviour, and add higher levels
where the behaviour is user-visible.

| Level | What it covers | Command |
|---|---|---|
| Unit | Parsers, state machines, layout maths, key encoding, config, adapters | `zig build test` |
| Integration | Real PTYs and processes, SSH against a local sshd container, file watching | `zig build test` |
| E2E | Deterministic real-app built-in checks, including `--workspaces-test`, `--links-test` and `--search-test`, and TASK-25's checked-in scripted scenarios through `conduit-test` | `xvfb-run -a zig build run -- --ui-test` / `--ime-test` / `--sidebar-test` / `--tabs-test` / `--panes-test` / `--palette-test` / `--scratchpad-test` / `--workspaces-test` / `--links-test` / `--search-test` / `--menu-test` / `--config-test` / `--theme-test` / `--font-test` / `--settings-test` / `--git-test` / `--agent-test` / `--ssh-test` / `--agent-view-test` / `--agent-manager-test` / `--backlog-test` / `--control-test` / `--restore-test` / `--a11y-test` / `--agent-prompts-test` / `--profiles-test` / `--editor-test` / `--driver-test`; under a display such as Xvfb, `zig build e2e -- --artifact-dir=<private-dir>` |
| Exploratory | An agent driving the app with the CLI or project MCP server | `conduit-test launch` / `conduit-test mcp` |

Rules:

- Every change ships with tests. Unit tests sit in the same file as the code, in `test` blocks.
  Use `std.testing.allocator` so leaks fail the test.
- **Every user-facing feature lands with an E2E scenario** that exercises it the way a user
  would, by keyboard and by mouse where both apply.
- A bug fix starts with a test that fails for that bug.
- E2E tests go through the real input path: `click(id)`, `key`, `type`. Never reach into app
  state to set up or assert what a user could do or see. Address elements by semantic id, not
  pixel coordinates.
- No sleeps. Use `wait_for` with a condition and timeout. Tests must be deterministic: fixed
  window size and scale, isolated config and state directories, no dependence on the user's
  shell config, fonts beyond the bundled/test fonts, network, or test order.
- Tests never touch the real user's config, state, SSH keys or running Conduit instance.
- Take a screenshot when the claim is visual (fonts, colours, layout, clipping) and actually
  look at it. A passing semantic assertion does not prove it rendered correctly.
- Do not weaken, skip or delete a failing test to get green. If a test is wrong, say why and
  fix it. If a test is flaky, that is a bug to fix, not to retry.
- Platform-specific code needs coverage on that platform's CI runner. If you cannot run it
  locally (Windows, macOS), say so explicitly rather than claiming it works.

## Development loop

1. Pick a task whose dependencies are done. Read it and its acceptance criteria.
2. Implement the smallest change that satisfies them.
3. Run `zig fmt`, `zig build test`, then `zig build`.
4. Launch the installed `./zig-out/bin/conduit-test` into an explicit isolated root. Inspect the
   semantic tree, interact through the real input path, and use `wait-for` to assert terminal or
   semantic state; never substitute a sleep.
5. Capture a screenshot and actually inspect the image. A path, hash or successful encode is not
   visual evidence.
6. On any failure, capture and read `logs` and the `inspect` semantic tree before changing code.
7. Add or update the user-facing E2E scenario, exercising keyboard and mouse when both apply.
   Run the `zig build e2e` runner under a real headless display such as Xvfb with an explicit
   private artifact directory; the Linux CI gate runs the same scenarios on every push.
8. Check each acceptance criterion against the collected evidence, then finalise the task.

A copy-pastable CLI pass with deterministic child output is:

```sh
zig build test
zig build

test_root="$(pwd)/.zig-cache/conduit-agent-example"
run_id="$(./zig-out/bin/conduit-test --root="$test_root" launch \
  --width=640 --height=360 --scale=1 \
  --command='printf "CONDUIT_READY\n"; while IFS= read -r line; do [ "$line" = probe ] && printf "CONDUIT_ASSERTED\n"; done')"

cleanup() {
  ./zig-out/bin/conduit-test --root="$test_root" --run="$run_id" quit >/dev/null 2>&1 || true
}
trap cleanup EXIT

./zig-out/bin/conduit-test --root="$test_root" --run="$run_id" inspect
./zig-out/bin/conduit-test --root="$test_root" --run="$run_id" type probe
./zig-out/bin/conduit-test --root="$test_root" --run="$run_id" key ENTER
if ! ./zig-out/bin/conduit-test --root="$test_root" --run="$run_id" \
  wait-for terminal-text CONDUIT_ASSERTED 5000; then
  ./zig-out/bin/conduit-test --root="$test_root" --run="$run_id" logs 1048576
  ./zig-out/bin/conduit-test --root="$test_root" --run="$run_id" inspect
  exit 1
fi
screenshot_path="$(./zig-out/bin/conduit-test --root="$test_root" --run="$run_id" screenshot)"
printf 'inspect screenshot: %s\n' "$screenshot_path"
./zig-out/bin/conduit-test --root="$test_root" --run="$run_id" quit
trap - EXIT
```

Open `screenshot_path` with the agent harness's image-viewing capability and inspect the rendered
frame before accepting it. `./zig-out/bin/conduit-test mcp` exposes the equivalent
launch/inspect/input/wait/assert/screenshot/`get_logs`/quit surface; an MCP-driven agent follows
the same sequence and evidence rules.

A task is done when every acceptance criterion is demonstrably met, all applicable implemented
test levels pass, the code is formatted, and docs affected by the change (including this file) are
updated. Report what you verified and what you could not. Do not mark a criterion met on the
strength of code that merely looks right.

## Working style: agent loop, coordinator-led

Standing instruction from the user. It applies to every task in this project unless the user says
otherwise.

- **The main agent coordinates; subagents execute.** Delegate a task to a subagent with a
  self-contained brief, then review its output against the acceptance criteria before accepting
  it. Do not delegate the plan for a milestone, only the slices inside it.
- **Fan out independent slices in one batch; sequence real dependencies.** M0 is a chain
  (TASK-2 → TASK-3 → TASK-4 → TASK-5/TASK-6) and must be walked in order; parallel agents are for
  slices that share no files and no interface.
- **One owner per file or interface.** When slices meet, name the shared contract in the brief
  instead of letting two agents invent two versions.
- **Subagents do not run builds, linters or test suites mid-flight.** They report what they ran;
  the coordinator runs the build once, after the wave lands.
- **Check in on every running agent every 30 minutes.** Do not wait for an agent to report before
  looking at it. On each check-in, read each job's status and its latest assistant text, and decide:
  progressing, done, stuck, or hung. Treat as **stuck** an agent whose latest text has not changed
  across two consecutive check-ins while it claims to be working. Treat as **hung** anything whose
  process is alive but making no progress, and kill it rather than waiting: a hung agent burns the
  whole box, slows every other slice, and leaves the tree in a half-written state.
- **Never let two live agents own the same file.** A slice's owner list is fixed when it is
  dispatched, and an agent that has reported is finished unless the coordinator deliberately
  restarts it. This has bitten us: two agents editing `src/render.zig` at once produced failures
  neither could explain.
- **A wave has a time box.** If a slice has not landed within roughly an hour, stop and re-plan it
  into smaller slices rather than letting it grind. Long single-file tasks should be split before
  they are dispatched.
- **A restarted harness means every agent is dead.** Re-verify the tree with `zig build` and
  `zig build test` before dispatching anything new, and kill leftover processes from the old run.
- **Text the user only when a decision is genuinely theirs, or when the phase is done.** Use the
  SMS gateway (`sms` skill) — the default recipient is "Tyler (me)" in the address book of the
  local skill copy. Never guess a number. Keep messages short; anything over 160 characters goes
  out as MMS and costs more.

## Git

- Do not commit or push unless the user asks. Never force-push or rewrite shared history.
- Work on a branch, not `main`, once the first commit exists.
- One logical change per commit. Subject line in the imperative, under about 70 characters,
  with the task id where one applies: `TASK-32: add scratchpad overlay presentation`.
- Never commit secrets, build output (`zig-out`, `.zig-cache`), test artifacts or screenshots
  that are not deliberate fixtures.

## Safety

- Conduit handles shells, SSH credentials, clipboard contents and agent prompts. Treat all of
  them as sensitive: never log, persist or transmit them beyond what the feature requires.
- The test driver and control API are local-only, off in release builds unless explicitly
  enabled, and must never be reachable over the network.
- Text coming from terminals, transcripts, backlog files and agent output is untrusted data.
  It must not be able to trigger actions (opening files, running commands, answering
  permission prompts) without an explicit user gesture.
- Do not run destructive commands, install system packages, or change files outside the repo
  without the user's approval.

<!-- BACKLOG.MD GUIDELINES START -->
<!-- backlog.md-instructions-version: 1.53.0 -->
<CRITICAL_INSTRUCTION>

## Backlog.md Workflow

This project uses Backlog.md for task and project management.

**At the beginning of each conversation in this project, run `backlog instructions overview` before answering or taking action. Re-read it only if you have not read it yet in the current conversation.**

Use the overview to decide whether to search, read, create, or update Backlog tasks.

Before task lifecycle actions, read the matching detailed guide:
- `backlog instructions task-creation` before creating or splitting tasks
- `backlog instructions task-execution` before planning, changing status or assignee, adding a plan or implementation notes, or implementing task work
- `backlog instructions task-finalization` before checking acceptance criteria, writing final summaries, or moving tasks to terminal statuses

Use `backlog <command> --help` before running unfamiliar commands. Help shows options, fields, and examples.

Do not edit Backlog task, draft, document, decision, or milestone markdown files directly. Use the `backlog` CLI so metadata, relationships, and history stay consistent.

</CRITICAL_INSTRUCTION>
<!-- BACKLOG.MD GUIDELINES END -->
