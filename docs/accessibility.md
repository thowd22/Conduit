# Accessibility

TASK-68 exposes Conduit's semantic element tree to platform accessibility APIs so screen readers
and other assistive technologies (AT) can navigate the sidebar, the command palette, settings
and the other views. The tree that drives rendering, hit testing and the test driver is the only
input (invariant 3): the bridge publishes snapshots of it and never keeps a second model.

Linux (AT-SPI2 over D-Bus) is implemented in `src/accessibility.zig` and
`src/accessibility/{dbus,atspi,snapshot}.zig`. macOS and Windows are planned below.

## How it works

```text
 owner (main) thread                         accessibility worker thread
 ───────────────────                         ───────────────────────────
 compose ui.Tree, endFrame
 Bridge.publish(&tree) ── capture into the back buffer (no allocation)
                          fingerprint unchanged? stop
                          swap into the one-slot mailbox ─── wake pipe ──▶ take snapshot
                                                                          diff old → new: Object signals
                                                                          serve AT calls from the current snapshot
 loop tick: Bridge.drainRequests(handler) ◀── bounded queue (32) + Waker ── DoAction / GrabFocus
 handler: click or focus the element by id
```

- **Snapshot.** `Snapshot.capture` copies every element's stable id, product role, label,
  action, window-pixel bounds, parent link, focus and selection into fixed buffers allocated once
  (default 2048 elements, 128 KiB of text). Hover and press are left out: they are pointer
  feedback and would republish on every motion. More elements or text than fit are dropped and
  the snapshot is marked truncated (logged at debug). Labels are cut to 1 KiB on a UTF-8 boundary
  and NUL bytes become spaces, so nothing the tree holds can break the D-Bus wire format.
- **Mailbox.** Four buffers rotate between the owner (back), the mailbox, and the worker (current
  and incoming while it diffs). A newer snapshot replaces one the worker has not taken. `publish`
  allocates nothing and does nothing when the bridge is off.
- **Requests.** An AT's `Action.DoAction(0)` and `Component.GrabFocus()` queue an `activate` or
  `focus` request carrying the element's semantic id (at most 256 bytes; at most 32 queued, more
  are refused and the AT sees `false`), then call the owner's `Waker`. The owner performs each on
  its own thread, so AT input never runs outside the owner and follows the same path as a click.
- **Off states.** The bridge is `off`, and costs nothing per frame, when `Options.enabled` is
  false, there is no `DBUS_SESSION_BUS_ADDRESS`, the platform is not Linux, or discovery fails.
  Failure is logged once at info (`accessibility bridge off: <reason>`). Start-up bus calls are
  bounded by `Options.call_timeout_ms` (2 s each), so `deinit` during start-up waits at most a few
  seconds.

### The setting

The bridge takes `Options.enabled` from the settings key `accessibility.enabled` (boolean,
default `true`, read at startup; [config.md](config.md)). Setting it to `false` starts no thread
and no bus connection.

## What is exposed on Linux

Discovery follows the AT-SPI2 protocol: on the session bus the worker calls
`org.a11y.Bus.GetAddress` on `/org/a11y/bus`, connects to the returned accessibility bus
(SASL EXTERNAL, unique name only), and calls `org.a11y.atspi.Socket.Embed((so))` on
`org.a11y.atspi.Registry` `/org/a11y/atspi/accessible/root` with its own root. The registry's
returned desktop becomes the application's parent.

| Object path | Role | Interfaces |
|---|---|---|
| `/org/a11y/atspi/accessible/root` | `application` | `Accessible`, `Application` (`ToolkitName` `Conduit`, `Version`, `AtspiVersion` `2.1`, writable `Id`) |
| `/org/a11y/atspi/accessible/window` | `frame`, named after the application; extents are the window surface | `Accessible`, `Component` |
| `/org/a11y/atspi/accessible/<16 hex digits>` | one semantic element; the hex is a 64-bit hash of its stable id, so the path survives frames | `Accessible`, `Component`, and `Action` when the element is interactive and has an action |
| `/org/a11y/atspi/cache` | — | `Cache.GetItems` over every object above |

The window's children are the tree's root elements (sidebar, panes, dialogs); every element's
children are the elements registered with it as parent, in registration (painter and focus)
order. `Accessible` implements `Name` (the element's label), `Description`, `Parent`,
`ChildCount`, `Locale`, `AccessibleId` (the semantic id, the same one `conduit-test inspect`
prints), `HelpText`, `GetChildAtIndex`, `GetChildren`, `GetIndexInParent`, `GetRelationSet`
(empty), `GetRole`, `GetRoleName`, `GetLocalizedRoleName`, `GetState`, `GetAttributes`
(`id`, `conduit-role`), `GetApplication` and `GetInterfaces`. `Component` implements
`GetExtents`, `GetPosition`, `GetSize`, `Contains`, `GetAccessibleAtPoint` (last-painted
descendant), `GetLayer`, `GetMDIZOrder`, `GetAlpha` and `GrabFocus`. `Action` offers one action,
`click`, whose description is the element's named action. Properties are served through
`org.freedesktop.DBus.Properties` `Get`/`GetAll`/`Set`; `Peer.Ping` and `Introspect` are answered.
Anything else is an `UnknownMethod`/`UnknownObject` error reply, and malformed arguments are an
`InvalidArgs` error, never a crash.

### Roles

| Conduit role (`ElementRegistration.role`) | AT-SPI role |
|---|---|
| `sidebar`, `pane`, `region`, `surface`, `presentation`, `agent_view` | panel |
| `dialog` (palette, settings, close prompts) | dialog (state `modal`) |
| `menu` / `menu_item` (context menu) | popup menu / menu item |
| `workspace` | tree item |
| `tab` | page tab |
| `command`, `choice`, `option`, `setting`, `agent_row` | list item |
| `button`, `action`, `palette_hint`, `sidebar_toggle`, `search_control` | button |
| `link`, `terminal_link` | link |
| `terminal` | terminal |
| `heading` | heading |
| `separator` | separator |
| `notification` | notification |
| `error`, `config_error` | alert |
| anything else | by primitive: `Text` label, `InteractiveText` button, `Surface` panel, `Input` entry |

### States

Every element is `enabled`, `sensitive` and `visible`, and `showing` when its bounds are not
empty. Interactive primitives are `focusable`; the tree's keyboard focus is `focused`. Tree items,
page tabs, list items and menu items are `selectable`, and `selected` follows product selection
(the active workspace and tab, the palette's highlighted command, the settings row). Inputs are
`editable` and `single-line`. A stale element path answers `GetState` with `defunct`.

### Events

When a new snapshot differs from the previous one the worker emits
`org.a11y.atspi.Event.Object` signals (`siiva{sv}`), at most 512 per change:

- `ChildrenChanged` `add`/`remove` on the window or an element, with the child's index and
  reference, for each child that appeared or disappeared;
- `StateChanged` `focused` (1/0) when keyboard focus moves, and `selected` when selection changes;
- `PropertyChange` `accessible-name` when an element's label changes.

The new snapshot becomes current before its events are sent, so an AT that reacts to an event
reads the state it describes.

## In the app

`app` owns the bridge (`App.a11y`). It starts after the window exists, on an ordinary run, with
`DBUS_SESSION_BUS_ADDRESS` from the environment, `accessibility.enabled` from the settings, the
product name and stamped version, and a waker that posts a driver wake so a blocked event loop
iterates. Built-in checks and driven (`--test-driver`) runs start no bridge, so automation never
appears on the person's accessibility bus; `--a11y-test` is the one check that does, on a private
bus. Every UI composition publishes the semantic tree right after `endFrame`
(`composeUiTree`); an unchanged tree costs a copy and a fingerprint compare and hands nothing to
the worker. Each loop iteration drains queued requests in `poll`: `activate` becomes
`postDriverClick(.{ .id = .{ .value = id } }, .{})`, the same SDL press and release a mouse
click produces, so palette rows, sidebar rows, context-menu rows and dialog controls behave
exactly as when clicked; `focus` becomes `ui_tree.focus(id)` followed by a redraw. `deinit`
stops the bridge before anything else is taken apart and before the window goes.

The deterministic Linux `--a11y-test` starts a private `dbus-daemon` and the stand-in
`org.a11y.Bus` and registry (`accessibility.check`, the same pieces the module's integration test
uses), starts the app with the bridge pointed at that bus, and from a bus client walks the live
tree: the sidebar (`sidebar` panel, the workspace row as a tree item, its tab as a page tab, the
`Palette` hint as a button) with the tree's labels; the palette opened by its real chord (dialog,
entry, the Settings command as a list item); `DoAction` on that row, which must run Settings
through a real click (the settings dialog opens and the palette closes); six settings rows,
headings included, with the tree's roles and labels; and `GrabFocus` on a setting, which must
move the tree's keyboard focus there. It is skipped (exit 0) when `dbus-daemon` is not installed.

## Inspecting it

The bridge needs the AT-SPI services a desktop session normally provides (`at-spi2-core`:
`at-spi-bus-launcher` and `at-spi2-registryd`, D-Bus activated).

- **accerciser** (`apt install accerciser`) lists `Conduit` under the desktop; selecting a node
  shows its role, name, states, `AccessibleId`, extents and the `click` action, and the event
  monitor shows the `Object` signals above.
- **Orca** (`orca`, or Super+Alt+S on GNOME) announces focused elements' names and roles as
  focus moves through the sidebar, palette and settings.
- **busctl**, with no extra packages:

  ```sh
  A11Y=$(busctl --user call org.a11y.Bus /org/a11y/bus org.a11y.Bus GetAddress | cut -d'"' -f2)
  # The registry's children: one (so) per application; note Conduit's unique name.
  busctl --address="$A11Y" call org.a11y.atspi.Registry /org/a11y/atspi/accessible/root \
    org.a11y.atspi.Accessible GetChildren
  APP=:1.23   # Conduit's unique name from the line above
  busctl --address="$A11Y" call $APP /org/a11y/atspi/accessible/window \
    org.a11y.atspi.Accessible GetChildren
  busctl --address="$A11Y" get-property $APP /org/a11y/atspi/accessible/<hex> \
    org.a11y.atspi.Accessible Name
  busctl --address="$A11Y" call $APP /org/a11y/atspi/cache org.a11y.atspi.Cache GetItems
  ```

### Tests

`zig build test` runs the unit tests (D-Bus marshalling and framing, SASL, snapshot copying and
bounds, role/state mapping, every served method, snapshot diffs, event encoding, the bounded
mailbox and request queue) and an integration test that starts a private `dbus-daemon` under
`/tmp`, runs a fake `org.a11y.Bus` and registry on it so the real discovery and `Embed` path runs,
walks the sidebar, palette and settings fixture over D-Bus as an AT would, observes
`ChildrenChanged` and `StateChanged:focused`, and turns `DoAction` into an owner request. It is
skipped with a warning when `dbus-daemon` is not installed.

An opt-in test runs against the real AT-SPI stack: with `CONDUIT_A11Y_PROBE` set to a shell
command, the bridge serves the same fixture through the real registry while the command runs; the
command must exit 0 and call `DoAction(0)` on `palette.action.0`. The dev box has no at-spi2-core,
so it was run in a throwaway `ubuntu:26.04` container (same glibc as the host) with
`at-spi2-core dbus python3-gi gir1.2-atspi-2.0` installed and a libatspi probe that finds
`Conduit` on the desktop, walks every element, checks role names, names, parents, the focused
query and the `click` action, then calls it:

```sh
docker run --rm -v "$PWD/probe:/work" atspi-probe-image \
  dbus-run-session -- env CONDUIT_A11Y_PROBE="python3 /work/probe.py" /work/accessibility-test
```

The probe's core, which is also the quickest way to dump Conduit's accessible tree from Python
on any desktop with `python3-gi` and `gir1.2-atspi-2.0`:

```python
import gi; gi.require_version("Atspi", "2.0"); from gi.repository import Atspi
desktop = Atspi.get_desktop(0)
app = next(a for a in (desktop.get_child_at_index(i) for i in range(desktop.get_child_count()))
           if a and a.get_name() == "Conduit")
def walk(node, depth=0):
    for i in range(node.get_child_count()):
        c = node.get_child_at_index(i)
        e = c.get_extents(Atspi.CoordType.WINDOW)
        print("  " * depth, c.get_role_name(), repr(c.get_name()), c.get_accessible_id(),
              (e.x, e.y, e.width, e.height),
              "focused" if c.get_state_set().contains(Atspi.StateType.FOCUSED) else "")
        walk(c, depth + 1)
walk(app)
# Activate an element as a click would:
# c.get_action_iface().do_action(0)
```

Its run printed `Conduit application toolkit Conduit`, the `frame`, and every fixture element with
the expected role (`panel`, `tree item`, `page tab`, `button`, `dialog`, `entry`, `list item`,
`heading`), name, parent and window extents, `focused` on the palette query and `selected` on the
active workspace, tab and highlighted command; `DoAction(0)` returned true and reached the owner
queue as `activate palette.action.0`.

## Limits

- **Terminal contents are not exposed.** A terminal pane is one element with role `terminal`
  and its label; there is no `Text` interface over the grid or scrollback, no caret and no
  `text-changed` events. Input fields expose their label, not their text. A later task can add
  the `Text` interface from `term`'s plain-text projection.
- Coordinates are window device pixels. Screen coordinates add an origin the app may set with
  `Bridge.setScreenOrigin` (Wayland has no global position, so it stays 0,0 there); HiDPI
  logical-pixel scaling is not applied.
- No `Selection`, `Value`, `Table`, `Hypertext` or relation sets; actions are a single `click`.
- The app does not consult `org.a11y.Status.IsEnabled`; it embeds whenever an accessibility bus
  is reachable, which is cheap when no AT listens.
- A real screen reader (Orca) was not available on the headless dev box. The real-registry probe
  above exercised libatspi, not speech output.

## Plan for macOS and Windows

Both platforms consume the same `Snapshot` and request queue; nothing in `ui` or `app` changes.
The platform part lives behind `platform`'s window seam (invariant 10), and the worker-side
mailbox becomes a main-thread mailbox where the OS API is main-thread only.

### macOS: NSAccessibility

- `platform`'s Cocoa layer (SDL exposes the `NSWindow` through
  `SDL_GetPointerProperty(SDL_GetWindowProperties(w), SDL_PROP_WINDOW_COCOA_WINDOW_POINTER)`)
  installs an `NSAccessibilityElement` subclass per snapshot node, keyed by the node's stable key
  so element identity survives frames, and returns the window's top-level nodes from the content
  view's `accessibilityChildren`.
- Each element answers `accessibilityRole` (`AXGroup` for panels, `AXSheet`/`AXDialog` for
  dialogs, `AXRow`/`AXCell` or `AXButton` for rows, `AXTextField` for inputs, `AXRadioButton`
  with `AXTabGroup` parent for tabs, `AXStaticText` for text, `AXHeading`), `accessibilityLabel`,
  `accessibilityFrame` (window pixels converted with `convertRectToScreen:` and the backing
  scale), `isAccessibilityFocused`, `isAccessibilitySelected`, `accessibilityParent` and
  `accessibilityChildren`. `accessibilityPerformPress` and `setAccessibilityFocused:` push the
  same `activate`/`focus` requests.
- AppKit's accessibility API is main-thread only, so on macOS `publish` swaps the snapshot in
  directly on the owner thread (no worker) and posts
  `NSAccessibilityFocusedUIElementChangedNotification`, `NSAccessibilityCreatedNotification`/
  `UIElementDestroyedNotification` and `NSAccessibilityTitleChangedNotification` from the same
  snapshot diff `atspi.diff` computes today.
- Needs: macOS CI runner; verification with VoiceOver and Accessibility Inspector.

### Windows: UI Automation

- `platform`'s Win32 layer answers `WM_GETOBJECT` with `UiaReturnRawElementProvider` for a root
  provider implementing `IRawElementProviderSimple` and `IRawElementProviderFragmentRoot`; each
  snapshot node is an `IRawElementProviderFragment` (`Navigate` over parent/first/last/next/
  previous from the snapshot links, `GetRuntimeId` from the stable key, `get_BoundingRectangle`
  from window pixels via `ClientToScreen`, `SetFocus` pushing a `focus` request).
- `GetPropertyValue` maps `UIA_ControlTypePropertyId` (Pane, Window for dialogs, TreeItem for
  workspaces, TabItem for tabs, ListItem for rows, Button, Edit, Text, Hyperlink), `UIA_NamePropertyId`
  (label), `UIA_AutomationIdPropertyId` (the semantic id), `UIA_HasKeyboardFocusPropertyId`,
  `UIA_IsKeyboardFocusablePropertyId` and `UIA_IsEnabledPropertyId`. Interactive nodes implement
  `IInvokeProvider::Invoke` (→ `activate`) and selectable rows `ISelectionItemProvider`.
- Providers are free-threaded, so they read the current snapshot under the bridge mutex like the
  AT-SPI worker; events (`UiaRaiseAutomationEvent(UIA_AutomationFocusChangedEventId)`,
  `UiaRaiseStructureChangedEvent`, `UiaRaiseAutomationPropertyChangedEvent` for names) come from
  the same snapshot diff.
- Needs: Windows CI runner; verification with Narrator and Accessibility Insights.
