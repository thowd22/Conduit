---
id: decision-12
title: 'Embedded VSCodium editor pane: per-platform hosting strategy'
date: '2026-10-08 05:27'
status: accepted
---
## Context

TASK-79 asks for VSCodium "embedded" in Conduit as a split pane and exposed to harnesses through
the control API. VSCodium is an Electron application with its own native top-level window, while
Conduit draws every pane into one SDL/OpenGL window (decision-2). Neither of Conduit's renderers
can draw VSCodium's content, so "embedded" has to mean hosting a foreign native window over the
pane's rectangle, and that is a different mechanism on every windowing system:

- X11 lets any client reparent another client's window (`XReparentWindow`), the basis of XEmbed
  and of every "swallowing" window manager.
- Wayland deliberately has no cross-client reparenting or global positioning: a client cannot
  place, size or adopt another client's surface.
- macOS and Windows can host another process's window only through native hosting behind
  `platform`: a tracked child window (or an NSView host) on macOS, and `SetParent` on the
  foreign HWND on Windows.

VSCodium is not bundled and must never be installed silently, and every process Conduit starts
goes through the workspace `ExecutionContext` (invariant 5).

## Decision

**Detection and launch (all platforms).**

- `editor.detect` runs `<command> --version` through the workspace `ExecutionContext.run`, trying
  the `editor.command` setting first when it is set and then `codium`. The first line of a
  successful answer is the version. Nothing is downloaded or installed. When neither answers, the
  editor actions are hidden and `editor.*` control requests reply with the `EditorNotInstalled`
  fault, whose fixed message says how to install VSCodium (https://vscodium.com or the
  distribution's package manager) or set `editor.command`.
- Every launch passes a per-workspace `--user-data-dir <conduit state dir>/editor/<id>`, where
  `<id>` is 16 hex digits of SHA-256 over the workspace's name and directory, so a Conduit-owned
  instance never shares a main process, settings, window state or IPC socket with the user's own
  VSCodium. `--extensions-dir` is never passed, so the user's own extensions
  (`~/.vscode-oss/extensions`) stay in use. Conduit writes `User/settings.json` in that directory
  only when it does not exist yet, with a `window.title` carrying a stable marker
  (`conduit-editor-<id>`) that identifies the window to host.
- The first open is `codium --new-window --user-data-dir <dir> --goto <path>:<line>:<col>` (the
  bare path when no line is given). Later requests reuse that window: `--reuse-window --goto ...`,
  `--reuse-window --diff <left> <right>`, and reveal is `-r` (`--reuse-window`) with the path,
  which opens it and lets the explorer's auto-reveal select it. Paths are resolved against the
  requesting session's OSC 7 cwd, lexically, and checked with `statPath` through the context.
  `editor.close` asks the hosted window to close (X11 `WM_DELETE_WINDOW`) and closes the pane.
- The CLI launcher hands off to the detached Electron main process and exits, so a launch is a
  bounded `ExecutionContext.run` on a worker thread, never a PTY session.
- SSH and WSL workspaces refuse the editor with `EditorRemoteUnsupported`, whose fixed message
  names the `vi` fallback (`tab.open` with `["vi", ...]`); the palette offers `vi` in a pane
  there. Driving VSCodium's remote tunnel is later work.

**Hosting, per platform.**

- **X11 (implemented: phase one seam, phase two wiring).** After a launch, `platform` finds the
  editor's top-level client window by the title marker, `_NET_WM_PID` or `WM_CLASS`, creates a
  child "container" window of Conduit's SDL window at the pane's device-pixel rectangle, withdraws
  the client, reparents it into the container with `XReparentWindow`, sizes it to the container
  and maps it. The app moves and resizes the container whenever the pane's rectangle changes
  (window resize, divider drag, zoom, sidebar show/hide/resize, scratchpad), hides it while the
  pane is not presented (another tab or workspace, a zoomed sibling, a modal over it), and on
  close sends `WM_DELETE_WINDOW` or gives the client back to the root window. Xlib is loaded at
  run time with `dlopen("libX11.so.6")`, as SDL itself loads X11, so Conduit gains no link-time
  dependency and still starts on systems without libX11. Every Xlib call runs on the owner thread
  over a private display connection with a temporary error handler, so a vanished client is an
  error value, never a crash.
- **Wayland (fallback, phase two).** The editor stays a separate VSCodium window, launched with
  `--new-window` and placed by the compositor. The pane shows a placeholder Surface with the
  editor's status and file, and every control, palette and context-menu action still works;
  focus and close act on the pane and the editor process.
- **macOS and Windows (later work).** Native child-window hosting behind `platform` as above.
  Until then they use the Wayland fallback; `platform.embedForeignWindow` returns
  `error.Unsupported` there.

**What is implemented now.** Phase one: this decision; the `editor` module (detection, launch
argv, the user-data-dir, path resolution through the context, per-workspace editor state, the
remote refusal and the install hint); the `editor.command` setting; the `editor.open`,
`editor.goto`, `editor.diff`, `editor.reveal` and `editor.close` control methods and their faults;
the `editor_open` and `editor_goto` driver methods, CLI commands and MCP tools (answering
`Unavailable` until phase two); and the X11 `platform` embedding seam with an Xvfb test. Phase two
wires `app`: the editor pane in the layout tree, the palette and context-menu actions, the control
and driver handlers, rectangle tracking, and the deterministic check and e2e scenario.

## Consequences

- A truly embedded editor exists only in X11 sessions; Wayland users get a separate window the
  pane tracks by status. This is what the platforms allow without a compositor protocol of
  Conduit's own.
- A reparented Electron window draws itself. Conduit's screenshots (FBO readback) show the pane's
  placeholder, not VSCodium's pixels, so visual evidence of the hosted window needs an X server
  capture (`import -window root`).
- The per-workspace user-data-dir makes each workspace's editor a separate Electron main process,
  a memory cost paid for never touching the user's own instance.
- Remote workspaces get `vi` until a remote-tunnel integration is decided.
