# Configuration

Conduit reads one human-editable settings file. Everything in it is optional: with no file, or an
empty one, Conduit uses the built-in defaults listed below. Edits apply as soon as the file is
saved; no restart is needed.

## Where the file lives

| Platform | Path |
|---|---|
| Linux and other Unix | `$XDG_CONFIG_HOME/conduit/config`, else `$HOME/.config/conduit/config` |
| macOS | `$HOME/Library/Application Support/conduit/config` |
| Windows | `%APPDATA%\conduit\config` |

A relative `XDG_CONFIG_HOME` is ignored, as the XDG base directory specification requires. A
missing file is not an error.

The palette command **Open config file** (`config.open`; Ctrl+, on Linux and Windows, Cmd+, on
macOS) opens the file in a new tab with `vi -- <path>`, started through the workspace's execution
context exactly like a clicked file reference. When the file does not exist yet it is first created
with a commented copy of every default, so it documents itself. **Reload config**
(`config.reload`) re-reads the file on demand, for example when hot reload is unavailable.

## Format

```
# A comment line.
font.family = "JetBrains Mono"
font.size = 13
scratchpad.size = 40
keybind = ctrl+alt+p=palette.open
```

- One `key = value` per line. Spaces around `=` and at either end of the line are ignored.
- A line whose first non-blank character is `#` is a comment. There are no trailing comments: a
  `#` inside a value is part of the value.
- Blank lines are ignored. Line endings may be LF or CRLF; a leading UTF-8 byte order mark is
  ignored.
- String values may be bare or wrapped in one pair of double quotes. A quote anywhere else is an
  error. An empty string means "the default" for every string key.
- A key may appear more than once; the last valid line wins. `keybind` is repeatable and every
  line applies, in order.
- Limits: the file may be at most 256 KiB, a line at most 1024 bytes, a string value at most 256
  bytes, and there may be at most 256 `keybind` lines.

## Keys

| Key | Value | Default | Effect today |
|---|---|---|---|
| `font.family` | string | `""` (bundled JetBrains Mono) | Applies; a family that is not installed falls back to the bundled face and is reported |
| `font.bold` | string | `""` (derived from the family) | Validated and stored; the font manager does not load configured style faces yet |
| `font.italic` | string | `""` | As `font.bold` |
| `font.bold_italic` | string | `""` | As `font.bold` |
| `font.size` | points, `1` to `72`, decimals allowed | `14` | Applies; the face is rebuilt and the grid re-measured |
| `font.ligatures` | `true` or `false` | `true` | Validated and stored for the font manager |
| `font.nerd_symbols` | `true` or `false` | `true` | Validated and stored for the font manager |
| `theme` | string | `""` | Reserved for the theme engine (TASK-38); no effect yet |
| `scratchpad.size` | whole percent, `10` to `100`, optional `%` | `50` | Height of the scratchpad opened by `scratchpad.toggle-50` |
| `scratchpad.large_size` | whole percent, `10` to `100`, optional `%` | `90` | Height of the scratchpad opened by `scratchpad.toggle-90` |
| `mouse.right_click` | `menu` or `paste` | `menu` | What a right click over a terminal does when the program has not captured the mouse |
| `keybind` | see below | the shipped bindings | Applies |

Command-line flags are a session layer above the file: `--font=<family>` wins over `font.family`
and `--right-click=<menu|paste>` wins over `mouse.right_click`, for that run only.

## Keybindings

```
keybind = <chord>=<action>
keybind = <chord>=<action>:<argument>
keybind = <chord>=unbind
```

The chord is everything before the first `=` of the value. Its parts are separated by `+` and
matched case-insensitively. Every part but the last is a modifier:

| Modifier | Also spelled |
|---|---|
| `ctrl` | `control` |
| `shift` | |
| `alt` | `option`, `opt` |
| `super` | `cmd`, `command` (the Command key on macOS, the Windows key elsewhere) |

The last part is the key:

- one character, such as `t`, `1`, `[`, `` ` `` or `,` (letters are case-insensitive);
- a named key: `enter` (`return`), `tab`, `backspace`, `escape` (`esc`), `insert` (`ins`),
  `delete` (`del`), `up`, `down`, `left`, `right`, `home`, `end`, `page_up` (`pageup`),
  `page_down` (`pagedown`), `f1` to `f12`;
- a word for a character that cannot be written inside a chord or reads better spelled out:
  `plus` (`+`, required), `equal` (`=`, required), `space`, `minus`, `comma`, `period`, `slash`,
  `backslash`, `semicolon`, `backtick` or `grave`.

Bindings match the unshifted key, so a shifted symbol is written as its unshifted key plus
`shift`: `ctrl+shift+[`, not `ctrl+{`.

The action is a command name from the palette (`tab.new`, `pane.split`, `scratchpad.toggle-50`,
`config.open`, ...), or `palette.open`, which the palette does not list. An action that takes an
argument needs it after a colon, and a fixed-choice argument must be one of its choices:
`pane.split:right`, `pane.focus:left`, `tab.goto:3`, `tab.move:up`. Semantic-only actions that
need a clicked element (such as `tab.activate`) cannot be bound.

A `keybind` line first removes whatever its chord was bound to, so a chord never runs two actions,
then binds the new action. Binding an action to a new chord does **not** remove its shipped
chord; unbind that one explicitly to move a binding:

```
# Move the command palette from Ctrl+Shift+P to Ctrl+Alt+P.
keybind = ctrl+shift+p=unbind
keybind = ctrl+alt+p=palette.open

# Swap the two scratchpad sizes' keys.
keybind = ctrl+`=scratchpad.toggle-90
keybind = ctrl+shift+`=scratchpad.toggle-50
```

A key Conduit does not bind always reaches the terminal unchanged, so an unbound chord becomes
ordinary terminal input again.

### Shipped bindings

The defaults are per platform; the palette shows the live chord for every command. The ones most
often rebound are:

| Action | Linux and Windows | macOS |
|---|---|---|
| `palette.open` | `ctrl+shift+p` | `super+shift+p` |
| `scratchpad.toggle-50` | `` ctrl+` `` | `` super+` `` |
| `scratchpad.toggle-90` | `` ctrl+shift+` `` | `` super+shift+` `` |
| `config.open` | `ctrl+,` | `super+,` |
| `tab.new` | `ctrl+shift+t` | `super+t` |
| `pane.split:right` / `:down` | `ctrl+shift+e` / `ctrl+shift+o` | `super+d` / `super+shift+d` |

Not configurable yet: the search chord (Ctrl+Shift+F, Cmd+F on macOS) and the keys inside modal
UI (palette, search field, context menu, rename and confirmation prompts) are handled by those
surfaces directly. `search.open` itself can still be given an additional chord with `keybind`.

## Errors

Conduit never refuses to start because of the settings file, and a bad line never stops the rest
of the file from applying:

- Each problem is logged at warning level as `<path>:<line>: <message>`. Messages name the key and
  never repeat the value.
- The first problem (lowest line; a whole-file problem first) is shown at the bottom of the
  sidebar as `config:<line>: <message>`, in red, until the file is fixed. It clips at the sidebar
  edge rather than wrapping; the full text is in the log.
- A rejected line leaves that key at its previous value: the value the last successful load
  applied, or the default at startup. A rejected `keybind` line leaves its chord bound as before.
- A file that exists but cannot be read (too large, a directory, permission denied) keeps every
  previous value. Deleting the file returns everything to the defaults.
- A `font.family` that is not installed is drawn with the bundled face and reported. A face that
  cannot be built at all keeps the previous face.

## Hot reload

Conduit watches the file for changes without polling the event loop. On Linux a small watcher
thread uses inotify on the file's directory, so editors that save by writing a temporary file and
renaming it over the original are seen; a burst of writes is coalesced into one reload once the
directory has been quiet for 100 ms. While the directory does not exist, and on other operating
systems, the watcher compares the file's size, modification time and inode once a second. The
watcher thread only notices; reading, validating and applying the file happen on the main thread.

## Testing

`xvfb-run -a zig build run -- --config-test` runs the deterministic check: it writes a settings
file into a private temporary directory (never the real one), starts Conduit, proves a rebound
palette chord and a configured scratchpad size through real SDL key events, rewrites the file with
a malformed line and proves `config.error` names that line while previous and still-valid values
keep working, repairs it with a rename-replace save and proves the error clears and the new
values (including a larger `font.size`) apply, then deletes the file and opens it again through
Ctrl+, and through a clicked palette row. `conduit-test launch` isolates `XDG_CONFIG_HOME`, so an
agent can write `<root>/<run>/config/conduit/config` and observe the reload through `inspect` and
`wait-for element config.error`.
