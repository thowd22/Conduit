---
id: TASK-69.1
title: Linux tagged release and installers
status: In Progress
assignee:
  - '@claude'
created_date: '2026-10-06 16:07'
updated_date: '2026-10-06 21:14'
labels:
  - release
  - infra
  - linux
milestone: m-8
dependencies:
  - TASK-25
  - TASK-31
  - TASK-32
  - TASK-33
  - TASK-34
  - TASK-35
  - TASK-36
  - TASK-50
parent_task_id: TASK-69
priority: high
type: feature
ordinal: 71000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Ship the verified Linux MVP without waiting for macOS and Windows packaging. This is a Linux-only delivery slice of TASK-69; the parent retains its full three-platform promise for later work.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A validated SemVer tag triggers a ReleaseSafe x86_64 Linux build only after the complete Linux unit and E2E gate passes, and the exact tag version is reported by conduit --version
- [ ] #2 The workflow publishes a tar.gz, Debian package, AppImage and SHA-256 checksums containing the Conduit binary, fallback font, shell integration, desktop metadata and required license notices
- [ ] #3 Release verification proves each package reports the stamped version, has the intended architecture and glibc/runtime dependency baseline, and can be extracted or installed in an isolated Linux environment
- [ ] #4 Prerelease tags create GitHub prereleases and rerunning the same tag is safe; Windows and macOS artifacts remain explicitly deferred to TASK-69
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Stamp a build-time version option into the binary and expose conduit --version.
2. Add a tag-triggered release workflow that validates SemVer, reuses the Linux unit/E2E gate, builds ReleaseSafe x86_64 and packages tar.gz, deb, AppImage and SHA-256 checksums.
3. Add release verification scripts proving stamped version, architecture, glibc baseline and isolated extract/install.
4. Handle prerelease tags and idempotent reruns; defer macOS/Windows to TASK-69.
5. Verify locally what the headless box allows; leave the remote Actions evidence as an explicit external check.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-10-06 slice landed: build.zig -Dversion SemVer validation and build_options module, src/version.zig, .github/workflows/release.yml (validate-tag -> reusable linux-e2e gate -> ReleaseSafe x86_64-linux-gnu.2.35 build/package/verify -> idempotent publish), release-* scripts (tag validation, pinned appimagetool 1.9.1 + type2 runtime with SHA-256, deterministic tar.gz/deb/AppImage packaging, verifier with Docker ubuntu:22.04 install leg, gh release create/edit + upload --clobber), packaging/debian + packaging/appimage templates, docs/release.md. Local evidence: version option accepts 0.1.0-rc.1 and rejects banana/v1.2.3; ReleaseSafe baseline build has max GLIBC_2.35 and NEEDED only libm/libc/ld-linux; packaging produced byte-identical tar.gz/deb on rerun; verifier 33 PASS / 4 FAIL where every FAIL is the not-yet-wired --version flag. Depends: libc6 (>= 2.35), libgl1, libx11-6 | libwayland-client0 from readelf NEEDED plus SDL3 dlopen strings. Branch-only push triggers added to ci.yml and linux-e2e.yml so a tag runs the gate once via release.yml.

2026-10-06 coordinator wired conduit --version (-V): parsed before the log sink and SDL, prints 'conduit <version>' from the build_options module; default build prints 'conduit 0.0.0-dev'. Local release dry run: ReleaseSafe -Dtarget=x86_64-linux-gnu.2.35 -Dversion=0.1.0-rc.1 build, release-package.sh produced tar.gz, deb, AppImage and SHA256SUMS with the pinned appimagetool, and release-verify.sh reported 37 PASS / 0 FAIL / 0 SKIP including the pristine ubuntu:22.04 Docker apt install printing 'conduit 0.1.0-rc.1'. Remaining: a real tagged GitHub Actions run (first commit/push required).
<!-- SECTION:NOTES:END -->

## Comments

<!-- COMMENTS:BEGIN -->
created: 2026-10-06 19:53
---
User selected MIT for Conduit's first-party project license. Recorded as decision-6; required third-party notices remain separate.
---
<!-- COMMENTS:END -->
