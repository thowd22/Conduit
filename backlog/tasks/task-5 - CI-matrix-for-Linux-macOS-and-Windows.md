---
id: TASK-5
title: 'CI matrix for Linux, macOS and Windows'
status: To Do
assignee: []
created_date: '2026-10-03 21:38'
updated_date: '2026-10-05 20:34'
labels:
  - infra
  - ci
milestone: m-0
dependencies:
  - TASK-4
modified_files:
  - .github/workflows/ci.yml
  - .gitattributes
priority: medium
ordinal: 5000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
GitHub Actions workflow that installs the pinned Zig version and runs build and unit tests on all three operating systems, with caching of the Zig cache and dependencies.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Workflow runs 'zig build' and 'zig build test' on ubuntu, macos and windows runners
- [x] #2 Zig version in CI comes from one pinned source of truth
- [x] #3 A failing unit test fails the workflow
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Workflow at .github/workflows/ci.yml, matrix ubuntu/macos/windows-latest, steps: resolve pinned Zig from build.zig.zon, setup-zig, cache, zig fmt --check, zig build, zig build test --summary all.
Single source of truth: a 'Resolve the pinned Zig version' step seds .minimum_zig_version out of build.zig.zon into $GITHUB_ENV as ZIG_VERSION; every later step reads ${{ env.ZIG_VERSION }}. A matrix entry was rejected because GitHub evaluates matrix values before any step runs, so a leg cannot be derived from a file; vars.* was rejected because repository variables live in the GitHub UI, not the tree. A further step compares 'zig version' against the pin and fails on mismatch, so a wrong download fails loudly instead of testing on another toolchain. The literal 0.16.0 appears nowhere in the workflow - verified: grep -c '0\.16\.0' returns 0.
Coordinator verification: python3 yaml.safe_load parses the file; jobs=build; matrix.os=[ubuntu-latest, macos-latest, windows-latest]; the seven named steps are present.
Failure path proven by the agent in a throwaway copy of the tree under /tmp (never the shared working tree): a deliberately failing unit test made zig build test exit non-zero. The agent also verified the run/step shell and CRLF-safety choices: shell: bash set explicitly on every step, POSIX ERE sed so BSD and Git-for-Windows behave the same, and the workflow never references an artifact path so there is no path-separator risk.
Added .gitattributes (coordinator) pinning build.zig, build.zig.zon and *.zig to LF, because a CRLF checkout on the Windows runner would break 'zig build' there. The agent flagged that risk and did not own the file.
Not verifiable here: the workflow has never run on GitHub, and nothing about the macOS or Windows legs executed on this headless Ubuntu box. Only a real CI run settles action availability, whether the SDL3 source build completes on those images, and what setup-zig resolves for Apple Silicon macos-latest.

2026-10-05 reconciliation: reopened and AC #1 unchecked. The workflow is configured for ubuntu, macOS and Windows, but this repository has no commits and the workflow has never run; static YAML inspection is not runtime evidence for the three runners.
<!-- SECTION:NOTES:END -->
