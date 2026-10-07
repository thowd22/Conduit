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

## The settings view

**Settings** (`settings.open`; Ctrl+Shift+, on Linux and Windows, Cmd+Shift+, on macOS, or type
`settings` in the command palette) opens a dialog over the window that lists every setting below,
grouped under dim headings: Appearance, Fonts, Keys, Scratchpad, Mouse and Agents. Each row reads
`<setting>  <value>`, the value being the one in effect. A `·` after the value means the settings
file sets it; no mark means the built-in default (or a command-line flag) decides it. The last
row, **Open config file**, closes the dialog and opens the file itself, as `config.open` does.

- **Moving.** Up and Down (or Tab and Shift+Tab) move the highlight, skipping the headings and
  wrapping at either end; Home and End jump to the first and last rows. The list scrolls to keep
  the highlighted row on screen. Escape, or a click outside the dialog, closes it. While it is
  open no key, typed text or click reaches the terminal or anything else beneath it.
- **Editing.** Enter or a click edits a row the way its value needs:
  - `true`/`false` settings (`font.ligatures`, `font.nerd_symbols` and every `notifications.*`
    switch in the Agents group) flip;
  - `mouse.right_click` switches between `menu` and `paste`;
  - `theme` and `font.family` close the dialog and open the palette's theme or family chooser,
    with its live preview;
  - numbers (`font.size`, `scratchpad.size`, `scratchpad.large_size`) and text (`font.bold`,
    `font.italic`, `font.bold_italic`, `font.fallbacks`) open a field on the row holding the
    current value: Enter saves, Escape cancels. An empty style family means "derived from the
    family".

  Left and Right also flip a `true`/`false` row, switch `mouse.right_click`, and step a number by
  one (the size by whole points from 6 to 72, the scratchpad by one percent from 10 to 100).
- **Saving.** Every change is written to the settings file at once, the same way the font and
  theme commands write theirs (creating the file from the defaults when it does not exist, and
  leaving every other line and comment as it was), and applies immediately. A value the file
  would reject is refused before anything is written: the dialog shows the same message a bad
  file line would, such as `font.size: expected 1 to 72 points`, and the setting keeps its value.
- **Keys.** The Keys group has a row for every palette command that takes no argument, plus
  Open command palette, showing its chords (or `unbound`). Enter or a click on one waits for a
  chord (`press a chord…`): the next key you press, with its modifiers, becomes that command's
  only chord. Escape cancels; Backspace leaves the command unbound. A bare key that would type
  text (a letter, or Shift and a letter) and bare Enter, Tab, Backspace or Escape are refused,
  because they would stop reaching the terminal. If another command already has the chord, the
  dialog says `conflict: <that command>`: Enter gives the chord to this command (the other loses
  it), Escape keeps things as they were. The chord you press never runs its current command.

  A key change rewrites only that command's `keybind` lines: its earlier lines are removed, each
  shipped chord it still has gets a `keybind = <chord>=unbind` line, and
  `keybind = <chord>=<command>` is appended. Taking a chord from another command needs no extra
  line, because a later `keybind` line always replaces what its chord was bound to. Commands that
  take an argument (`pane.split:right`, `tab.goto:3`, ...) are bound in the file directly.

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
| `font.bold` | family name | `""` (derived from the family) | Applies; bold text uses this family's bold face (else its regular face). Empty uses the family's own bold face, or emboldens its regular face. A family that is not installed keeps the derived face |
| `font.italic` | family name | `""` | As `font.bold`, for italic (a missing italic face is slanted) |
| `font.bold_italic` | family name | `""` | As `font.bold`, for bold italic |
| `font.size` | points, `1` to `72`, decimals allowed | `14` | Applies; the face is rebuilt and the grid re-measured |
| `font.ligatures` | `true` or `false` | `true` | Applies at once; programming ligatures (`=>`, `!=`, `->`) form only when `true` |
| `font.nerd_symbols` | `true` or `false` | `true` | Applies; `true` draws box drawing, blocks, braille and Powerline separators at the exact cell size, `false` takes them from the fonts |
| `font.fallbacks` | comma-separated family names, at most 8 | `""` (none) | Applies; these families are tried, in order, for a character the family lacks, before any other installed font. A family that is not installed is skipped and reported |
| `theme` | theme name or `auto:<dark>,<light>` | `""` (`conduit-dark`) | Applies to the terminal and every UI colour; see [Themes](#themes) |
| `scratchpad.size` | whole percent, `10` to `100`, optional `%` | `50` | Height of the scratchpad opened by `scratchpad.toggle-50` |
| `scratchpad.large_size` | whole percent, `10` to `100`, optional `%` | `90` | Height of the scratchpad opened by `scratchpad.toggle-90` |
| `mouse.right_click` | `menu` or `paste` | `menu` | What a right click over a terminal does when the program has not captured the mouse |
| `notifications.enabled` | `true` or `false` | `true` | Applies to the next notification; `false` lists and raises none (see [Notifications](#notifications)) |
| `notifications.os` | `true` or `false` | `true` | Applies; `false` keeps notifications in the in-app list only, never the desktop |
| `notifications.permission` | `true` or `false` | `true` | An agent waiting for permission |
| `notifications.input` | `true` or `false` | `true` | An agent waiting for input, or a harness's own notification |
| `notifications.done` | `true` or `false` | `true` | An agent's turn finished |
| `notifications.error` | `true` or `false` | `true` | An agent's turn (or launch) failed |
| `notifications.terminal` | `true` or `false` | `true` | OSC 9 / OSC 777 from a terminal without an agent, and a bell from a tab you are not looking at |
| `notifications.claude_code` | `true` or `false` | `true` | Every notification from Claude Code agents |
| `notifications.codex` | `true` or `false` | `true` | Every notification from Codex agents |
| `notifications.pi` | `true` or `false` | `true` | Every notification from Pi agents |
| `notifications.opencode` | `true` or `false` | `true` | Every notification from OpenCode agents |
| `keybind` | see below | the shipped bindings | Applies |

Command-line flags are a session layer above the file: `--font=<family>` wins over `font.family`
and `--right-click=<menu|paste>` wins over `mouse.right_click`, for that run only.

## Fonts

`font.fallbacks` is one line holding a comma-separated list, for example
`font.fallbacks = Noto Sans Mono CJK SC, Symbols Nerd Font Mono`. Spaces around each name are
ignored and empty entries are skipped; more than 8 names is reported and the previous list stays.
Characters no configured family has still reach every other installed font and, last, Conduit's
bundled symbols and JetBrains Mono faces, so a missing glyph does not become a box.

Every font setting can also be changed from the command palette, and each change is written to the
settings file at once (creating it from the defaults when it does not exist, and leaving every other
line and comment as it was), so the file and the window always agree:

| Command | Action | Writes |
|---|---|---|
| Font: Change Family | `font.pick` | `font.family` |
| Font: Increase Size | `font.size.increase` | `font.size` |
| Font: Decrease Size | `font.size.decrease` | `font.size` |
| Font: Reset Size | `font.size.reset` | `font.size = 14` |
| Font: Toggle Ligatures | `font.ligatures.toggle` | `font.ligatures` |
| Font: Toggle Built-in Symbols | `font.symbols.toggle` | `font.nerd_symbols` |
| Font: Configure Fallbacks | `font.fallbacks` | `font.fallbacks` |

- **Change Family** lists the bundled JetBrains Mono and every installed monospace family (up to
  255, sorted, the one in use first). Moving the highlight with the arrow keys, or moving the
  pointer over a row, redraws the whole window in that family; the line under the list names the
  family on screen once it has loaded. Enter or a click keeps it; Escape or a click outside goes
  back to the family you had. Choosing the bundled entry writes `font.family = ""`.
- **Size** steps one point at a time between 6 and 72. **Reset** returns to the built-in 14 points
  and writes `font.size = 14` rather than removing the line, so the file says what is on screen.
  The shipped chords are Ctrl+= (or Ctrl+Plus), Ctrl+- and Ctrl+0 on Linux and Windows, and
  Command with the same keys on macOS.
- **Configure Fallbacks** asks for the comma-separated list; `none` clears it.
- With `--font=<family>` on the command line, a chosen family is still saved to the file, but the
  flag keeps deciding the family for that run.

## Themes

`theme` names one colour scheme. It colours the terminal (the 16 ANSI colours, foreground,
background, cursor and selection) and every piece of Conduit's own UI, whose colours are derived
from the same scheme so they stay readable on dark and light schemes alike.

- **Bundled schemes.** `conduit-dark` (the default), `gruvbox-dark`, `gruvbox-light`,
  `catppuccin-mocha`, `catppuccin-latte`, `dracula`, `nord`, `tokyo-night`, `solarized-dark`,
  `solarized-light`, `one-dark`, `kanagawa-wave`, `everforest-dark` and `rose-pine`. Names are
  matched ignoring case, spaces, hyphens and underscores, so `Tokyo Night`, `tokyo-night` and
  `TokyoNight` are the same theme; the display names (`Rosé Pine`) also match.
- **Your own themes.** Drop a theme file in Ghostty's format into the `themes` directory beside
  the settings file (`$XDG_CONFIG_HOME/conduit/themes/`, else `~/.config/conduit/themes/`, on
  Linux, `~/Library/Application Support/conduit/themes/` on macOS, `%APPDATA%\conduit\themes\`
  on Windows) and name it in
  `theme`, by its file name. A user file wins over a bundled scheme of the same name. Files from
  Ghostty's own theme collection work as they are:

  ```
  palette = 0=#21222c
  palette = 4=#bd93f9
  background = #282a36
  foreground = #f8f8f2
  cursor-color = #f8f8f2
  cursor-text = #282a36
  selection-background = #44475a
  selection-foreground = #ffffff
  ```

  `palette = N=` sets ANSI colour N (0 to 15); colours are `#rrggbb` or `rrggbb`. A file may set
  only some colours; the rest come from `conduit-dark`. A line Conduit cannot use (another key,
  a named colour, a palette index above 15) is reported in the sidebar and skipped. Files are at
  most 64 KiB; names must be one line of printable text without `"` or `,`, not starting with
  `.`, at most 64 bytes, and at most 32 files are listed.
- **Light and dark.** `theme = auto:<dark>,<light>` (for example
  `auto:gruvbox-dark,gruvbox-light`) follows the desktop's light/dark preference when the
  platform reports one and the dark theme when it does not. A preference change while Conduit
  runs is applied at once where SDL reports it.
- **Choosing from the palette.** `Theme: choose` (`theme.pick`) lists every bundled and user
  theme, the active one first. Moving the highlight with the arrow keys or the pointer shows the
  highlighted theme across the whole window at once; Enter or a click keeps it and writes
  `theme = <name>` into the settings file (creating the file from the defaults when it does not
  exist, and leaving every other line and comment as it was); Escape or a click outside goes back
  to the theme you had.
- **Problems.** A name that is neither bundled nor a file in the themes directory shows
  `config:<line>: theme: no bundled or user theme named ...` and the previous theme stays.
- **Reloading.** The theme directory is read at startup and on every settings reload. Editing a
  theme file is not watched by itself: save the settings file or run `Reload config` to pick up
  a changed or newly added theme file.

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

The defaults are per platform; the palette shows the live chord for every command, and
[the user guide](user-guide.md#keybinding-reference) lists every default for both profiles. The
ones most often rebound are:

| Action | Linux and Windows | macOS |
|---|---|---|
| `palette.open` | `ctrl+shift+p` | `super+shift+p` |
| `scratchpad.toggle-50` | `` ctrl+` `` | `` super+` `` |
| `scratchpad.toggle-90` | `` ctrl+shift+` `` | `` super+shift+` `` |
| `config.open` | `ctrl+,` | `super+,` |
| `settings.open` | `ctrl+shift+,` | `super+shift+,` |
| `tab.new` | `ctrl+shift+t` | `super+t` |
| `pane.split:right` / `:down` | `ctrl+shift+e` / `ctrl+shift+o` | `super+d` / `super+shift+d` |
| `font.size.increase` | `ctrl+equal`, `ctrl+shift+equal` | `super+equal`, `super+shift+equal` |
| `font.size.decrease` / `font.size.reset` | `ctrl+minus` / `ctrl+0` | `super+minus` / `super+0` |
| `notifications.open` | `ctrl+shift+n` | `super+shift+n` |

Not configurable yet: the search chord (Ctrl+Shift+F, Cmd+F on macOS) and the keys inside modal
UI (palette, settings view, search field, context menu, rename and confirmation prompts) are
handled by those surfaces directly. `search.open` itself can still be given an additional chord with `keybind`.

## Notifications

An agent's state changes and terminal notification sequences become entries in the in-app list
(**Notifications**, `notifications.open`: Ctrl+Shift+N on Linux and Windows, Cmd+Shift+N on
macOS, or the palette). Each entry is raised only when `notifications.enabled`, its kind's switch
and, for an agent, its harness's switch are all `true`; a switch turned off applies to the next
notification and leaves entries already listed. When the window does not have keyboard focus an
entry is also sent to the desktop, unless `notifications.os` is `false`. On Linux that is
`notify-send` (absent: nothing is shown, logged once at debug); macOS and Windows have no desktop
notifications yet. A hidden (`--hidden`, headless) run never notifies the desktop.

| Kind | Raised when |
|---|---|
| `permission` | an agent starts waiting for permission |
| `input` | an agent starts waiting for input, or its harness raises a notification of its own |
| `done` | an agent's turn finishes |
| `error` | an agent's turn, or its launch, fails |
| `terminal` | a session without an agent sends OSC 9 or OSC 777, or rings the bell while its tab is not the one shown |

The list keeps the newest 32 entries. **Notifications: clear** empties it.

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
Ctrl+, and through a clicked palette row. `xvfb-run -a zig build run -- --font-test` drives the font commands the same way, against its own
private settings file: the size chords, the palette's size commands by keyboard and by a clicked
row with the cell height and the file checked after each, ligatures toggled in place with frame
readback, built-in symbols, fallbacks typed into the palette (an uninstalled one reported in the
sidebar), and the family picker's keyboard preview, Escape revert, hover preview and clicked
choice saved as `font.family`. Each command's own write is shown to reload without building the
face a second time. `xvfb-run -a zig build run -- --settings-test` drives the settings view the
same way, against its own private file: it opens the view from the palette and by its chord,
moves over the headings, flips `font.ligatures` by Enter and by a click, types a scratchpad size
into the row's field and opens a dock of that height, steps `font.size` with Right and measures
the cells, has `99` points refused with its message and the file unchanged, cycles
`mouse.right_click`, captures a new palette chord and uses it, has a taken chord reported,
kept on Escape and taken on Enter, opens the raw file from its row, and proves keys, text and
clicks behind the dialog do nothing, reading the file back after every change.
`xvfb-run -a zig build run -- --agent-test` writes its own private settings file too: it turns
`notifications.permission` off by a rewrite and proves the next permission wait is neither listed
nor sent to the desktop, then turns it back on through the settings view's Agents row. `conduit-test launch` isolates `XDG_CONFIG_HOME`, so an
agent can write `<root>/<run>/config/conduit/config` and observe the reload through `inspect` and
`wait-for element config.error`.
