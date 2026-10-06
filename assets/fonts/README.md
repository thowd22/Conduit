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
separate faces, and font manager v1 loads one face; every style falls back to this Regular face
until that changes.

## Other third-party code and fonts

The vendored libraries Conduit builds from source are pinned in `build.zig.zon`, and their licence
texts are kept next to the pins in [`../THIRD-PARTY-LICENSES/`](../THIRD-PARTY-LICENSES/):

| Dependency | Version | Licence | Text |
|---|---|---|---|
| FreeType | 2.13.2 (`1220b81` vendored by Ghostty) | FTL or GPL-2.0, at your option | `FreeType-FTL.txt`, `FreeType-LICENSE.TXT` |
| HarfBuzz | 11.0.0 | Old MIT | `HarfBuzz-COPYING.txt` |

No font other than JetBrains Mono is redistributed. System fonts are only ever read from where the
platform installs them.
