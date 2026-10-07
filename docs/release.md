# Cutting a Conduit release (Linux, TASK-69.1)

This describes the Linux x86_64 release path. macOS and Windows artifacts are
deferred to TASK-69 and nothing below builds, signs or publishes them.

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

## Deferred and unverified

- macOS and Windows packages, signing and notarisation: TASK-69.
- Signing the Linux artifacts (GPG or Sigstore) is not part of this slice;
  `SHA256SUMS` is the only integrity artifact.
- The ReleaseSafe binary keeps its debug information so Zig's safety panics
  print usable stack traces; it is about 55 MB on disk. Stripping would be a
  separate decision.
- Running the whole chain on GitHub Actions (the reusable gate under
  `workflow_call`, the Docker install leg on the runner, the release create
  and `--clobber` rerun) can only be proven by a real tagged run; the local
  evidence covers everything that runs on this machine.
