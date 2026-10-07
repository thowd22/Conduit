# Linux desktop assets

## Desktop entry

`io.github.thowd22.Conduit.desktop` is installed at
`share/applications/io.github.thowd22.Conduit.desktop`. Its `Icon=io.github.thowd22.Conduit`
names the icons below; keep the two identifiers in step.

## Application icon

- `io.github.thowd22.Conduit-source.png` — the original 1254x1254 RGBA artwork exactly as the
  user supplied it. Kept for provenance; it is neither installed nor packaged.
- `io.github.thowd22.Conduit-master.png` — the source with its alpha cleaned: the supplied fill
  tops out at alpha 253-254 and carries faint background-removal dust, so near-opaque pixels
  become fully opaque and near-transparent ones fully transparent, leaving the anti-aliased edge
  untouched. Every render below is generated from this file:

  ```sh
  convert assets/linux/io.github.thowd22.Conduit-source.png \
    -channel A -fx 'a>=240/255 ? 1 : (a<8/255 ? 0 : a)' +channel -strip \
    PNG32:assets/linux/io.github.thowd22.Conduit-master.png
  ```

- `icons/hicolor/<N>x<N>/apps/io.github.thowd22.Conduit.png` for N in 16, 22, 24, 32, 48, 64,
  128, 256 and 512 — installed by `build.zig` at `share/icons/hicolor/<N>x<N>/apps/`, which checks
  each file's PNG signature and IHDR size. The AppImage uses the 256 render as its top-level icon
  and `.DirIcon`.

  ```sh
  for n in 16 22 24 32 48 64 128 256 512; do
    convert assets/linux/io.github.thowd22.Conduit-master.png -background none \
      -resize ${n}x${n} -gravity center -extent ${n}x${n} -strip \
      PNG32:assets/linux/icons/hicolor/${n}x${n}/apps/io.github.thowd22.Conduit.png
  done
  ```

- `io.github.thowd22.Conduit-64.rgba` — the window icon: 64x64 raw RGBA8 (exactly 16384 bytes),
  embedded by `src/platform.zig` and handed to `SDL_SetWindowIcon`, which X11 exposes as
  `_NET_WM_ICON`.

  ```sh
  convert assets/linux/io.github.thowd22.Conduit-master.png -background none \
    -resize 64x64 -depth 8 rgba:assets/linux/io.github.thowd22.Conduit-64.rgba
  ```
