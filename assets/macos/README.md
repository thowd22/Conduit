# macOS bundle assets

`zig build bundle` (macOS targets only) stages `Conduit.app` under the install prefix from these
files; see `addMacosBundle` in `build.zig`.

- `Info.plist.in` — the bundle's `Info.plist`. `build.zig` fills `@VERSION@` (the stamped
  `-Dversion`, in `CFBundleGetInfoString`), `@SHORT_VERSION@` (its numeric
  `<major>.<minor>.<patch>` core, which `CFBundleShortVersionString` and `CFBundleVersion`
  require) and `@MIN_MACOS@` (the target's minimum macOS version). The identifier
  `io.github.thowd22.Conduit` matches the Linux desktop entry. `NSHighResolutionCapable` is
  true so the window gets Retina backing.
- `AppIcon.icns` — the application icon, ten PNG renders (16 to 1024 pixels, including every
  `@2x` slot) of the same artwork as the Linux hicolor icons. Every render is embedded byte for
  byte; nothing is re-encoded. `build.zig` checks the container and two of its element types,
  and the macOS workflow decodes it with `iconutil`. Regenerate it with:

  ```sh
  convert assets/linux/io.github.thowd22.Conduit-master.png -background none \
    -resize 1024x1024 -gravity center -extent 1024x1024 -strip PNG32:/tmp/conduit-1024.png
  python3 assets/macos/make-icns.py /tmp/conduit-1024.png assets/macos/AppIcon.icns
  ```

- `make-icns.py` — writes the `.icns` from the hicolor renders plus the 1024 render above.

The bundle's `Contents/Resources` also receives the bundled fonts, the shell integration
scripts and every licence (`Resources/licenses`). The executable embeds the fonts and scripts,
so these copies are the shipped, inspectable payload rather than something read at run time.
