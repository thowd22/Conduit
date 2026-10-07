# Conduit — Agent Guide

Conduit is a cross-platform (Linux, macOS, Windows) terminal workspace written in Zig on top of
libghostty. It combines tabs, split panes, a command palette and a persistent scratchpad with
first-class support for coding-agent CLIs (Claude Code, Codex, Pi) and Backlog.md planning.
Everything looks and feels like a terminal; mouse and keyboard are equal inputs.

Read this file fully before working. It applies to every agent and every harness.

## Current state

The terminal implementation is present: `zig build run` opens a window with the user's shell over
a PTY, rendered by Conduit's grid renderer, with keyboard, mouse, selection, clipboard, scrollback
and shell integration (cwd and prompt marks). Its seventeen Linux headless self-checks pass through
their deterministic Linux drivers: `conduit --grid-test`, `--self-test`, `--scroll-test`,
`--mouse-test`, `--clipboard-test`, `--ui-test`, `--ime-test`, `--sidebar-test`, `--tabs-test`,
`--panes-test`, `--palette-test`, `--scratchpad-test`, `--workspaces-test`, `--links-test`,
`--search-test`, `--menu-test` and `--driver-test` (each exits non-zero on failure). The real-window checks run
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
scenarios request an additional current screenshot before shutdown. Its nine declarative scenarios
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
the desktop environment. `zig build
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
tag runs the gate once through the release workflow. macOS and Windows packaging stay in TASK-69.

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
| E2E | Deterministic real-app built-in checks, including `--workspaces-test`, `--links-test` and `--search-test`, and TASK-25's checked-in scripted scenarios through `conduit-test` | `xvfb-run -a zig build run -- --ui-test` / `--ime-test` / `--sidebar-test` / `--tabs-test` / `--panes-test` / `--palette-test` / `--scratchpad-test` / `--workspaces-test` / `--links-test` / `--search-test` / `--menu-test` / `--driver-test`; under a display such as Xvfb, `zig build e2e -- --artifact-dir=<private-dir>` |
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
