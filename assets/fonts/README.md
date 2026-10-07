# Bundled fonts

## JetBrainsMono-Regular.ttf

- **Font:** JetBrains Mono, version 2.304 (upstream release `v2.304`, published 2023-01-14).
- **Licence:** SIL Open Font License 1.1. Full text in
  [`LICENSE-JetBrainsMono-OFL-1.1.txt`](LICENSE-JetBrainsMono-OFL-1.1.txt), taken verbatim from the
  `OFL.txt` in the upstream release archive.
- **Copyright:** Copyright 2020 The JetBrains Mono Project Authors
  (<https://github.com/JetBrains/JetBrainsMono>).
- **Obtained from:** `https://github.com/JetBrains/JetBrainsMono/releases/download/v2.304/JetBrainsMono-2.304.zip`,
  file `fonts/ttf/JetBrainsMono-Regular.ttf`.
- **SHA-256:** `a0bf60ef0f83c5ed4d7a75d45838548b1f6873372dfac88f71804491898d138f`.

This is the face Conduit falls back to when the configured family is not installed. It is
**compiled into the executable**, not opened from disk: `build.zig` copies this file into the
generated directory and `src/font.zig` embeds it through the `bundled-face` module, so a machine
with no fonts installed at all still renders text. The build fails if this file is missing.

Only the Regular face is bundled. `CONDUIT.md` §8 configures bold, italic and bold-italic as
separate faces; when the configured family is missing one (and always for this bundled face), font
manager v2 synthesises it from the Regular face with FreeType emboldening and a shear.

## SymbolsNerdFontMono-Regular.ttf

- **Font:** Nerd Fonts "Symbols Nerd Font Mono", the symbols-only face, from Nerd Fonts release
  `v3.5.1`.
- **Obtained from:** `https://github.com/ryanoasis/nerd-fonts/releases/download/v3.5.1/NerdFontsSymbolsOnly.tar.xz`
  (archive SHA-256 `01172f37db8543edb102e5cb5c64101c9f4686630804d49b419aa07b23a69996`), file
  `SymbolsNerdFontMono-Regular.ttf`.
- **SHA-256:** `fe471e538392f51910faab985fa8e192a39dd3426125edd15b71b3680df0e749`.
- **Licence:** the Nerd Fonts project licence, verbatim from the `v3.5.1` tag, is in
  [`LICENSE-NerdFonts.txt`](LICENSE-NerdFonts.txt): patched fonts and glyph fonts are SIL Open Font
  License 1.1, Copyright (c) 2014 Ryan L McIntyre, and the project's own sources are MIT. The
  glyphs collected into the face come from projects under their own permissive licences — Codicons
  and Font Awesome (CC BY 4.0), Material Design Icons (Apache 2.0), Devicons, Font Awesome
  Extension, Octicons, Seti-UI, IEC Power Symbols and Powerline Extra Symbols (MIT), Pomicons and
  Weather Icons (SIL OFL 1.1), Font Logos (Unlicense) and Powerline Symbols (free licence). The
  project's own per-source audit, verbatim from the `v3.5.1` tag, is
  [`NerdFonts-license-audit.md`](NerdFonts-license-audit.md). All of them permit redistribution with
  attribution, which these two files and this section provide; the face is not sold by itself and
  is unmodified.

It is compiled into the executable like JetBrains Mono (`bundled-symbols` in `build.zig`) and is the
last font-backed link of every fallback chain before the bundled Regular face, so Nerd Font
private-use icons (U+E000–U+F8FF and U+F0000 onwards, for example omp's U+F126 and U+F0068) draw
without a patched font installed. Box drawing, block elements, braille and the Powerline arrow,
rounded and triangle separators are not taken from it: `src/font_sprite.zig` draws those at the
cell size. Its licence files are installed under `share/licenses/conduit/`.

## Other third-party code and fonts

The vendored libraries Conduit builds from source are pinned in `build.zig.zon`, and their licence
texts are kept next to the pins in [`../THIRD-PARTY-LICENSES/`](../THIRD-PARTY-LICENSES/):

| Dependency | Version | Licence | Text |
|---|---|---|---|
| FreeType | 2.13.2 (`1220b81` vendored by Ghostty) | FTL or GPL-2.0, at your option | `FreeType-FTL.txt`, `FreeType-LICENSE.TXT` |
| HarfBuzz | 11.0.0 | Old MIT | `HarfBuzz-COPYING.txt` |
| zlib | 1.3.1 (`1220fed` vendored by Ghostty) | zlib | `zlib-LICENSE.txt` |
| libpng | 1.6.43 (`1220aa0` vendored by Ghostty) | PNG Reference Library v2 | `libpng-LICENSE.txt` |

zlib and libpng are linked into FreeType only so it can decode the PNG strikes colour emoji fonts
use (TASK-39).

No fonts other than JetBrains Mono and Symbols Nerd Font Mono are redistributed. System fonts are
only ever read from where the platform installs them.
