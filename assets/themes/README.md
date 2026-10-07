# Bundled colour schemes

Conduit compiles its bundled schemes into the binary from `src/theme_schemes.zig`. No theme file is
installed; this file records where every colour value came from and under which licence it is
used.

## Source of the values

Every bundled scheme except `conduit-dark` was copied exactly (16 ANSI colours, background,
foreground, cursor, cursor text, selection background and selection foreground) from its Ghostty
theme file in the iTerm2-Color-Schemes collection, the collection Ghostty itself ships:
<https://github.com/mbadolato/iTerm2-Color-Schemes/tree/master/ghostty>. The values were fetched on
2026-10-07. Each entry in `src/theme_schemes.zig` carries the URL of its file.

`conduit-dark` is Conduit's own default: the palette every release before TASK-38 drew with.

| Conduit id | Collection file | Scheme project | Project licence |
|---|---|---|---|
| `gruvbox-dark` | `Gruvbox Dark` | <https://github.com/morhetz/gruvbox> | MIT/X11 (stated in the project README) |
| `gruvbox-light` | `Gruvbox Light` | <https://github.com/morhetz/gruvbox> | MIT/X11 (stated in the project README) |
| `catppuccin-mocha` | `Catppuccin Mocha` | <https://github.com/catppuccin/catppuccin> | MIT |
| `catppuccin-latte` | `Catppuccin Latte` | <https://github.com/catppuccin/catppuccin> | MIT |
| `dracula` | `Dracula` | <https://github.com/dracula/dracula-theme> | MIT |
| `nord` | `Nord` | <https://github.com/nordtheme/nord> | MIT |
| `tokyo-night` | `TokyoNight` | <https://github.com/folke/tokyonight.nvim> | Apache-2.0 |
| `solarized-dark` | `iTerm2 Solarized Dark` | <https://github.com/altercation/solarized> | MIT |
| `solarized-light` | `iTerm2 Solarized Light` | <https://github.com/altercation/solarized> | MIT |
| `one-dark` | `Atom One Dark` | <https://github.com/atom/one-dark-syntax> | MIT |
| `kanagawa-wave` | `Kanagawa Wave` | <https://github.com/rebelot/kanagawa.nvim> | MIT |
| `everforest-dark` | `Everforest Dark Med` | <https://github.com/sainnhe/everforest> | MIT |
| `rose-pine` | `Rose Pine` | <https://github.com/rose-pine/rose-pine-theme> | MIT |

A colour palette is a short list of numbers; the notices are kept here because the collection
and the projects ask for attribution, and because the values are copied verbatim.

## iTerm2-Color-Schemes licence

```
MIT License

Copyright (c) 2011 to Present Mark Badolato

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

This license covers the iTerm-Color-Schemes repository collection of themes.

The copyright/license for each individual theme belongs to the author of that theme.
```

The collection's licence names each theme's author as its copyright holder; the table above
links every scheme's own project and licence.
