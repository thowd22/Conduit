# Cutting a Conduit release (Linux, TASK-69.1; macOS, TASK-48/TASK-69; Windows, TASK-49/TASK-69)

This describes the Linux x86_64 release path and, in [macOS](#macos), the arm64
disk image published beside it, and a Windows portable zip (see the Windows section).

## Tag format

A release is a Git tag `v<major>.<minor>.<patch>[-<prerelease>][+<build>]`,
strictly SemVer 2.0.0: `v1.0.0`, `v0.2.0-rc.1`, `v1.1.0-beta.2+exp.5114f85`.
The `v` is mandatory on the tag and never part of the version; the binary
reports the tag minus `v`. Anything else (`1.0.0`, `v1.0`, `v01.0.0`,
`v1.0.0-01`) fails `release-validate-tag.sh` and no build starts. A tag with a
`-<prerelease>` part becomes a GitHub prerelease.

```sh
git tag -a v0.2.0-rc.1 -m "Conduit 0.2.0-rc.1"
git push origin v0.2.0-rc.1
```

## What the workflow does

`.github/workflows/release.yml` runs on `push` of `v*` tags:

1. `validate-tag` runs `.github/scripts/release-validate-tag.sh` and emits
   `version` and `prerelease`.
2. `linux-gate` calls the reusable `linux-e2e.yml` on the tagged commit: `zig
   fmt --check`, `zig build`, `zig build test`, every built-in headless check
   under Xvfb, the Sway/IBus/X11 platform checks and `zig build e2e`. The build
   job `needs` this job, so a release never ships from a commit that failed
   the complete Linux unit and E2E gate.
3. `build` installs the Zig named by `.minimum_zig_version` in `build.zig.zon`
   (the same single source ci.yml reads), then:
   ```sh
   zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-gnu.2.35 \
     -Dversion=<version> --prefix <stage>
   ```
   `build.zig` rejects a `-Dversion` that is not SemVer, and the generated
   `build_options` module carries the value into `src/version.zig` and the
   application. `release-package.sh` then turns the staged prefix into
   `conduit-<version>-x86_64-linux.tar.gz`, `conduit_<version>_amd64.deb`,
   `Conduit-<version>-x86_64.AppImage` and `SHA256SUMS`, and
   `release-verify.sh` checks them (next section). The artifacts are uploaded
   as a workflow artifact.
4. `publish` (the only job with `contents: write`) runs
   `release-publish.sh`: it creates the GitHub release for the tag with
   generated notes, or reuses an existing one and corrects its prerelease
   flag, then uploads every asset with `gh release upload --clobber`.
   Rerunning the workflow for the same tag therefore replaces the assets and
   never duplicates them or fails because the release exists.

Every package contains the `conduit` binary, the bundled JetBrains Mono
fallback font, the bash/zsh/fish shell integration, the freedesktop desktop
entry and the application icon as PNGs at the hicolor sizes 16, 22, 24, 32,
48, 64, 128, 256 and 512, Conduit's MIT `LICENSE` and the third-party notices
`build.zig` installs under `share/licenses/conduit/` (Ghostty, SDL, zopengl,
FreeType, HarfBuzz, Oniguruma, zlib, libpng, JetBrains Mono OFL, and the Nerd
Fonts licence and audit for the bundled symbols face). The development-only
`conduit-test` driver CLI is deliberately not packaged.

## Runtime baseline

- **Architecture:** x86_64 only (`amd64` in Debian terms).
- **glibc:** 2.35, the glibc of Ubuntu 22.04 LTS. The build targets
  `x86_64-linux-gnu.2.35`, so Zig links against that exact glibc ABI, and the
  verifier fails if the binary's highest `GLIBC_x.y` symbol version exceeds it.
  The baseline is written once, as `GLIBC_BASELINE` in `release.yml`, and
  passed to both the `-Dtarget` and the verifier.
- **Linked libraries:** only `libc.so.6`, `libm.so.6` and
  `ld-linux-x86-64.so.2` (`readelf -d`). SDL3, FreeType, HarfBuzz, Oniguruma
  and the terminal engine are compiled in. SDL `dlopen`s the display and GL
  stacks at runtime, so the Debian package declares
  `Depends: libc6 (>= 2.35), libgl1, libx11-6 | libwayland-client0` (OpenGL
  3.3 and one windowing system are hard requirements) and lists the remaining
  X11/Wayland/xkbcommon/libdecor/dbus libraries as `Recommends`.
  `release-package.sh` derives the `libc6` dependency from the binary's
  `NEEDED` entries and refuses to package if an unmapped library appears.
- **Asset file names keep the SemVer spelling** (`conduit_0.2.0-rc.1_amd64.deb`): GitHub
  release assets cannot contain `~` and are silently renamed on upload, which would break
  `SHA256SUMS` and the `--clobber` match on a rerun. Only the control file's `Version` uses `~`.
- **Debian version:** inside the package, SemVer `-<prerelease>` becomes `~<prerelease>`
  (`0.2.0-rc.1` → `0.2.0~rc.1`) so a prerelease sorts below its release the
  way Debian expects; `+build` metadata is kept as is.
- **AppImage:** built with `appimagetool` 1.9.1 and the type2 runtime
  `20251108`, both downloaded by `release-fetch-appimagetool.sh` and verified
  against SHA-256 pins recorded in that script (checked against the digests
  GitHub publishes for those release assets). `AppRun` is
  `packaging/appimage/AppRun`; the desktop entry and icon come from the staged
  prefix, with the 256x256 PNG copied to the AppDir root as
  `io.github.thowd22.Conduit.png` (what the entry's `Icon=` resolves to there)
  and linked as `.DirIcon`. The tool runs with `--appimage-extract-and-run`, so no FUSE is
  needed on the runner, and `--runtime-file` keeps the runtime pinned.
- **Tooling on the runner:** `dpkg-deb`, `readelf`, `objdump`, `file`, `tar`,
  `gzip`, `sha256sum`, `curl` and `docker`, all present on the ubuntu-24.04
  image; the workflow checks for each by name instead of installing packages.

## What release verification proves

`release-verify.sh <version> <dist> [work]` prints one `PASS`/`FAIL`/`SKIP` line
per check, continues past failures, and exits non-zero if any failed:

- `SHA256SUMS` verifies and names every artifact.
- tar.gz: extracts to a single `conduit-<version>-x86_64-linux/` directory
  with the full payload; `bin/conduit` is an x86-64 ELF (`file`, `readelf -h`),
  links only glibc components, needs at most `GLIBC_<baseline>`, references
  `libGL.so.1` (so the `libgl1` dependency is real) and prints exactly
  `conduit <version>` for `--version`.
- .deb: `Package`, `Architecture: amd64`, `Version` (Debian form), `Depends`
  pinning `libc6 (>= <baseline>)` and `libgl1`, contents including the payload
  and `usr/share/doc/conduit/copyright`; `dpkg-deb -x` extraction and the same
  binary checks; and, when Docker is available, `apt-get install ./pkg.deb`
  inside a pristine `ubuntu:22.04` container followed by `conduit --version`.
  Without Docker the install leg prints `SKIP` and the extraction leg stands.
- AppImage: ELF runtime with the type 2 magic, `--appimage-extract` without
  FUSE, `AppRun`, desktop entry (still naming `Icon=io.github.thowd22.Conduit`),
  PNG icon and a `.DirIcon` that resolves to a PNG at the AppDir root, the
  full payload under `usr/`, the binary checks, and `AppRun --version`.

Binaries run with `HOME` and the `XDG_*` directories pointed into the work
directory and no `DISPLAY`, so the real user's configuration and state are
never read or written. `conduit --version` must therefore exit before any
window-system initialisation.

## Verifying locally

The build box is headless; nothing below needs a display.

```sh
scratch="$(mktemp -d)"
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-gnu.2.35 \
  -Dversion=0.2.0-rc.1 --prefix "$scratch/stage"
bash .github/scripts/release-fetch-appimagetool.sh "$scratch/tools"   # optional
SOURCE_DATE_EPOCH="$(git log -1 --format=%ct)" \
  bash .github/scripts/release-package.sh 0.2.0-rc.1 "$scratch/stage" "$scratch/dist" "$scratch/tools"
bash .github/scripts/release-verify.sh 0.2.0-rc.1 "$scratch/dist" "$scratch/verify"
```

Set `RELEASE_ALLOW_MISSING_APPIMAGE=1` on both scripts to skip the AppImage
leg when the pinned tools cannot be downloaded. Use a private `--prefix`: never
package `./zig-out`, which other builds may be writing to. `zig build
-Dversion=banana` fails at configure time with the SemVer message, which is
the intended behaviour. With the same `SOURCE_DATE_EPOCH` the tar.gz and .deb
are byte-for-byte reproducible.

## macOS

The `macos` job in `release.yml` calls the reusable `.github/workflows/macos.yml`
with the tag's version and `optimize: ReleaseSafe`, after the Linux gate. On a
GitHub arm64 macOS runner (`macos-14`) it:

1. builds and runs the built-in checks that pass on macOS (`--self-test`,
   `--grid-test`, `--ui-test`, `--driver-test`, `--scroll-test`,
   `--mouse-test`, `--ime-test`, `--sidebar-test`, `--scratchpad-test`,
   `--links-test`, `--menu-test`, `--theme-test`, `--font-test`) in real
   Cocoa windows, and reports the rest without gating on them (`--tabs-test`,
   `--panes-test`, `--palette-test`, `--workspaces-test`, `--search-test`,
   `--config-test` and `--settings-test` fail on macOS today; several compare a
   spawned child's cwd with the requested one, and `/tmp` is `/private/tmp`
   there). `--clipboard-test` cannot run: its offscreen SDL driver has no
   OpenGL on macOS;
2. stages `Conduit.app` with `zig build bundle` (`Contents/MacOS/conduit`, a
   generated `Info.plist`, `Resources/AppIcon.icns`, the fonts, shell
   integration and licences; see `assets/macos/README.md`);
3. checks the bundle (`macos-bundle-check.sh`: `Info.plist`, icon, resources,
   `--version`, `codesign --verify`, a Launch Services start with `open`, the
   display's density and a 2x frame), the system clipboard and font discovery;
4. packages `conduit-<version>-macos-arm64.dmg` (the app plus an
   `/Applications` link, UDZO) with `macos-dmg.sh`, mounts it read-only and
   verifies the payload, the signature and that the mounted app prints
   `conduit <version>`, and writes `<dmg>.sha256`;
5. uploads the dmg as the `conduit-macos-arm64-<version>` artifact.

`publish-macos` then uploads the dmg and its `.sha256` to the release with
`--clobber`. It needs `publish`; `publish` does not need it, so a tag whose
macOS leg fails still publishes the Linux assets and the release simply lacks
the dmg until the job is rerun.

**The dmg is unsigned for Gatekeeper.** Without Apple credentials the app is
signed ad hoc, which keeps the bundle's seal intact but is not a Developer ID
signature, and it is not notarized. A downloaded copy is quarantined, so macOS
refuses to open it with a double click. Users open it once with Control-click
▸ Open (or `xattr -dr com.apple.quarantine /Applications/Conduit.app`). To
ship a signed, notarized dmg, add these repository secrets; the steps already
use them and skip themselves when they are absent (this path has not run):

| Secret | What |
|---|---|
| `MACOS_CERTIFICATE_P12_BASE64` | a "Developer ID Application" certificate and key, exported as .p12, base64 |
| `MACOS_CERTIFICATE_PASSWORD` | the .p12's password |
| `MACOS_SIGNING_IDENTITY` | the identity name, `Developer ID Application: <Name> (<TEAM>)` |
| `MACOS_NOTARY_APPLE_ID`, `MACOS_NOTARY_TEAM_ID`, `MACOS_NOTARY_PASSWORD` | an Apple ID, its team and an app-specific password for `notarytool` |

With the first three, `macos-import-identity.sh` imports the identity into a
temporary keychain and `macos-dmg.sh` signs the app with the hardened runtime
and the dmg; with the notary three as well it runs `notarytool submit --wait`,
`stapler staple` and `spctl --assess`.

The minimum macOS version is the runner's (the `LSMinimumSystemVersion` the
build writes is the target's minimum, which for a native build is the host's:
14 on `macos-14`). Building for an older minimum needs a non-native
`-Dtarget` and SDL's `-Dsystem_include_path`/`-Dsystem_framework_path`/
`-Dlibrary_path` pointed at the SDK; not done yet. Only arm64 is built.

### Dry run without a tag

`macos.yml` also runs on `workflow_dispatch` with optional `version` and
`optimize` inputs, which exercises exactly the job the release calls. GitHub
only dispatches a workflow that exists on the default branch, so this works
once `macos.yml` is on `main`:

```sh
gh workflow run macos.yml --ref <branch> -f version=0.2.0-rc.1 -f optimize=ReleaseSafe
```

Before that, pushing a commit to the branch `task-48-macos-release` runs the
same job at ReleaseSafe with the version `0.1.8-macos.dryrun.<run>`.

The `conduit-macos-arm64-<version>` artifact is the dmg the release would
publish; the `conduit-macos-evidence-*` artifact holds the screenshots and logs.

## Windows

The `windows` job in `release.yml` calls the reusable
`.github/workflows/windows.yml` with the tag's version and `optimize:
ReleaseSafe`, after the Linux gate. On GitHub's `windows-latest` runner, which
has an interactive desktop in which SDL creates real Win32 windows, it:

1. builds for the explicit `<arch>-windows-gnu` host target `build.zig` picks
   on Windows. `conduit.exe` embeds `assets/windows/conduit.manifest`
   (per-monitor-v2 DPI awareness, UTF-8 process code page, Windows 10/11
   `supportedOS`, `asInvoker`) and the icon from `assets/windows/conduit.rc`;
2. checks that `conduit.exe --version` prints `conduit <version>`;
3. stages the portable folder with `zig build portable` (`zig-out/Conduit`:
   `conduit.exe`, `conduit-test.exe`, `share/conduit/{fonts,shell-integration,
   themes,licenses}`, no PDBs) and zips it with `windows-package.sh` as
   `conduit-<version>-windows-x86_64.zip` (the folder `Conduit/` inside) plus
   `<zip>.sha256`, then verifies the zip as a user gets it: the checksum, a
   fresh `Expand-Archive`, every payload file, the embedded manifest,
   `--version` from the unpacked `conduit.exe` and that the unpacked
   `conduit-test.exe` runs;
4. uploads the zip as the `conduit-windows-x86_64-<version>` artifact;
5. then, on test fixtures that never reach the zip (Mesa llvmpipe's
   `opengl32.dll` beside the built `conduit.exe`, because the runner's only
   OpenGL is Microsoft's GDI 1.1 implementation; and Git for Windows' `sh` at
   `\bin\sh`, because `--command` children and the built-in checks' fixed
   children run as `/bin/sh -c` until TASK-46 gives Windows its own shells),
   runs the platform checks: `windows-smoke.sh` (cmd.exe and PowerShell under
   ConPTY through `conduit-test`, Unicode text input, frames at scale 1 and
   1.5), `windows-clipboard-check.sh` (Ctrl+Shift+V from and Ctrl+Shift+C to
   the Windows clipboard), `windows-font-check.sh` (Consolas and Cascadia Mono
   from `%WINDIR%\Fonts`, DejaVu Sans Mono installed for the runner's user
   only, and a negative control), `windows-dpi-check.sh` (a real scale change
   through `windows-set-dpi.ps1` while a window is open), the built-in checks,
   and `zig build test`, whose WSL tests use a real distribution if the image
   has one and a scripted `wsl.exe` stand-in otherwise. The workflow makes one
   bounded attempt (`wsl --install -d Ubuntu --no-launch --web-download`); on
   `windows-latest` it succeeds and Ubuntu runs under WSL2, so the WSL context
   tests run against a real distribution there.

The built-in checks that pass on Windows gate the job: `--self-test`,
`--grid-test`, `--ui-test`, `--driver-test`, `--scroll-test`, `--mouse-test`,
`--sidebar-test`, `--scratchpad-test`, `--menu-test`, `--theme-test`,
`--font-test`, `--tabs-test`, `--palette-test` and `--workspaces-test`. Five
are run and reported without gating: `--clipboard-test` (it pins SDL's
offscreen driver, which needs an EGL library on Windows; the Windows clipboard
step is the real proof), `--ime-test` (its fixed child is an MSYS `sh` script
that cannot put a ConPTY console into raw mode; the smoke's Unicode text input
through cmd.exe is the Windows proof of committed text), `--links-test` (it
opens `vi`, which the runner has only as an MSYS script, not `vi.exe`), and
`--panes-test` and `--search-test` (a write that reaches a ConPTY whose child
has just exited fails with `ERROR_NO_DATA`, which `pty.zig` reports as
`SystemError` rather than `Closed`, and the check stops).

`publish-windows` uploads the zip and its `.sha256` to the release with
`--clobber`. Like `publish-macos` it needs `publish` and nothing needs it.

**The zip is unsigned.** Neither executable carries an Authenticode
signature, so SmartScreen may warn on first run of a downloaded copy. Signing
needs a code-signing certificate (not available to the project yet); with one,
`signtool sign /fd sha256 /tr <timestamp-url>` on both executables before
`windows-package.sh` is the whole change. An installer (MSI, MSIX or Inno
Setup) is not built: the portable folder needs no registration, and an
installer adds a toolchain and a signing requirement for no capability the
zip lacks.

### Dry run without a tag

Pushing a commit to `task-49-windows` runs the workflow at Debug; pushing to
`task-49-windows-release` runs it at ReleaseSafe with the version
`0.1.8-windows.dryrun.<run>`. Once `windows.yml` is on `main`:

```sh
gh workflow run windows.yml --ref <branch> -f version=0.2.0-rc.1 -f optimize=ReleaseSafe
```

The `conduit-windows-x86_64-<version>` artifact is the zip the release would
publish; `conduit-windows-evidence-*` holds the screenshots and logs.

## Deferred and unverified

- macOS Developer ID signing and notarisation need the user's Apple
  credentials (above); until then the dmg is ad hoc signed. The Windows zip is
  not Authenticode-signed and has no installer (above).
- Signing the Linux artifacts (GPG or Sigstore) is not part of this slice;
  `SHA256SUMS` is the only integrity artifact.
- The ReleaseSafe binary keeps its debug information so Zig's safety panics
  print usable stack traces; it is about 55 MB on disk. Stripping would be a
  separate decision.
- Running the whole chain on GitHub Actions (the reusable gate under
  `workflow_call`, the Docker install leg on the runner, the release create
  and `--clobber` rerun) can only be proven by a real tagged run; the local
  evidence covers everything that runs on this machine.
