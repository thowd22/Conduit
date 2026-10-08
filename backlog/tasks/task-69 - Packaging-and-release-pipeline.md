---
id: TASK-69
title: Packaging and release pipeline
status: To Do
assignee: []
created_date: '2026-10-03 21:39'
updated_date: '2026-10-08 02:42'
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
- [ ] #1 Tagged builds produce installable artifacts for all three platforms
- [x] #2 Version is stamped in the binary and shown by 'conduit --version'
- [ ] #3 Bundled resources (themes, fallback font, shell integration) ship in every package
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-10-08: macOS half landed with TASK-48 (release.yml macos + publish-macos jobs, unsigned dmg verified by mount and --version in a dry run); AC2 (stamped version) holds on Linux and macOS; AC1/AC3 wait for the Windows package.
<!-- SECTION:NOTES:END -->
