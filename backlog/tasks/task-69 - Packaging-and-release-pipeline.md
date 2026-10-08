---
id: TASK-69
title: Packaging and release pipeline
status: Done
assignee: []
created_date: '2026-10-03 21:39'
updated_date: '2026-10-08 12:55'
labels:
  - release
  - infra
milestone: m-8
dependencies:
  - TASK-5
  - TASK-48
  - TASK-49
  - TASK-50
priority: medium
ordinal: 69000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Release builds and installers: Linux (tarball plus AppImage or Flatpak and deb), macOS (signed and notarized dmg), Windows (installer or portable zip), produced by a tagged CI workflow with version stamping and bundled themes, fonts and shell integration scripts.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Tagged builds produce installable artifacts for all three platforms
- [x] #2 Version is stamped in the binary and shown by 'conduit --version'
- [x] #3 Bundled resources (themes, fallback font, shell integration) ship in every package
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-10-08: macOS half landed with TASK-48 (release.yml macos + publish-macos jobs, unsigned dmg verified by mount and --version in a dry run); AC2 (stamped version) holds on Linux and macOS; AC1/AC3 wait for the Windows package.

Coordinator 2026-10-08: Windows portable zip (zig build portable + windows-package.sh, verified on the runner, ReleaseSafe dry run 37729065903) and macOS dmg (macos.yml) now ship bundled fonts, shell integration (incl. powershell/conduit.ps1) and licences; AC3 checked. AC1 waits for a real tagged release producing all three platforms' artifacts.

Coordinator 2026-10-08: tag v0.1.9 (382afdc) ran release.yml end to end (run 37776779436): tag validation, the reusable Linux gate, Linux tar.gz/deb/AppImage with SHA256SUMS, the macOS arm64 dmg via macos.yml, the Windows x86_64 portable zip via windows.yml, and the three publish jobs. Published at https://github.com/thowd22/Conduit/releases/tag/v0.1.9 with eight assets. The dmg is ad hoc signed, not notarized (needs the Apple MACOS_* secrets), and the zip is unsigned with no installer; both are documented in docs/release.md.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Release packaging for all three platforms: a v* tag runs the gate, builds ReleaseSafe artifacts (Linux tar.gz/deb/AppImage, macOS dmg, Windows portable zip) with stamped versions, bundled fonts, shell integration and licences, verifies them and publishes idempotently; v0.1.9 is the first release carrying all three. Signing/notarization and a Windows installer remain open and documented.
<!-- SECTION:FINAL_SUMMARY:END -->
